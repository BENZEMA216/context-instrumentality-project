"""Adapters for verified public client protocols; never configure or create chats.

Codex's installed app-server schema supplies thread/resume and turn/start.
WorkBuddy's bundled public HTTP API supplies ACP session/resume + session/prompt.
Neither adapter creates a session, changes model/permissions, or interprets output.
"""

import http.client
import ipaddress
import os
from pathlib import Path
import select
import subprocess
import time
import uuid
from urllib.parse import urlsplit

from automatic import event_message, private_file
from library import BridgeError, canonical_json, canonical_uuid, parse_json


MAX_RESPONSE = 16 * 1024 * 1024
MAX_NOTIFICATION_BYTES = 256 * 1024


def batch_id(events):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "record-for-agent:batch:" + "\n".join(sorted(event["eventID"] for event in events))))


class DeliveryError(Exception):
    def __init__(self, code, uncertain=False):
        super().__init__(code)
        self.code = code
        self.uncertain = uncertain


def _bounded_identity(value, name):
    if not isinstance(value, str) or not value or len(value) > 128 or any(ord(c) < 32 for c in value):
        raise BridgeError("invalid_arguments", name + " must be an explicit bounded client identity.")
    return value


class CodexClient:
    def __init__(self, executable, thread_id, cwd, timeout=30):
        if not isinstance(executable, str) or not Path(executable).is_absolute():
            raise BridgeError("invalid_arguments", "Codex requires the absolute path of its installed CLI executable.")
        if not isinstance(cwd, str) or not Path(cwd).is_absolute():
            raise BridgeError("invalid_arguments", "Codex requires an explicit absolute working directory.")
        self.executable = executable
        self.cwd = cwd
        self.thread_id = canonical_uuid(thread_id, "threadID")
        self.target = "codex:" + self.thread_id
        self.timeout = timeout

    def send(self, events, on_accepted=None):
        process, sent = None, False
        try:
            process = subprocess.Popen([self.executable, "app-server", "--stdio"], cwd=self.cwd,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
            buffered = bytearray()
            def read_line(timeout):
                deadline = time.monotonic() + timeout if timeout is not None else None
                while b"\n" not in buffered:
                    remaining = max(0, deadline - time.monotonic()) if deadline is not None else None
                    if not select.select([process.stdout], [], [], remaining)[0]:
                        raise DeliveryError("codex_response_timeout", uncertain=sent)
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        return b""
                    buffered.extend(chunk)
                    if len(buffered) > MAX_RESPONSE:
                        raise DeliveryError("codex_response_too_large", uncertain=sent)
                line, _, rest = buffered.partition(b"\n")
                buffered[:] = rest
                return bytes(line)
            try:
                def write(value):
                    # Pipe writes may be partial with an unbuffered Popen stream.
                    content = memoryview((canonical_json(value) + "\n").encode())
                    while content:
                        written = process.stdin.write(content)
                        if not written:
                            raise BrokenPipeError()
                        content = content[written:]

                def request(identifier, method, params):
                    write({"id": identifier, "method": method, "params": params})
                    while True:
                        line = read_line(self.timeout)
                        if not line or len(line) > MAX_RESPONSE:
                            raise DeliveryError("codex_incomplete_response", uncertain=sent)
                        response = parse_json(line)
                        if response.get("id") != identifier:
                            # Notifications may contain model output; intentionally
                            # discard them. Processing and results belong to Codex.
                            if "id" in response and "method" in response:
                                write({"id": response["id"], "error": {"code": -32601, "message": "This notification adapter cannot approve tool actions."}})
                            continue
                        if "error" in response:
                            raise DeliveryError("codex_request_rejected")
                        if not isinstance(response.get("result"), dict):
                            raise DeliveryError("codex_invalid_response", uncertain=sent)
                        return response["result"]

                request(1, "initialize", {"clientInfo": {"name": "record-for-agent-delivery", "version": "0.1.0"}})
                write({"method": "initialized"})
                request(2, "thread/resume", {"threadId": self.thread_id, "excludeTurns": True})
                sent = True
                result = request(3, "turn/start", {"threadId": self.thread_id,
                                 "clientUserMessageId": batch_id(events),
                                 "input": [{"type": "text", "text": event_message(events)}]})
                turn = result.get("turn")
                if not isinstance(turn, dict) or not isinstance(turn.get("id"), str) or not turn["id"]:
                    raise DeliveryError("codex_missing_turn_id", uncertain=True)
                acknowledgement = {"kind": "codex_turn_accepted", "threadID": self.thread_id, "turnID": turn["id"]}
                if on_accepted:
                    on_accepted(acknowledgement)
                # Retain the client attachment during execution. We do not assume
                # disconnecting immediately after turn/start preserves the run.
                while True:
                    line = read_line(None)
                    if not line or len(line) > MAX_RESPONSE:
                        return dict(acknowledgement, executionObservation="connection_ended")
                    message = parse_json(line)
                    if "id" in message and "method" in message:
                        write({"id": message["id"], "error": {"code": -32601, "message": "This notification adapter cannot approve tool actions."}})
                    params = message.get("params", {})
                    if (message.get("method") == "turn/completed" and params.get("threadId") == self.thread_id
                            and params.get("turn", {}).get("id") == turn["id"]):
                        return dict(acknowledgement, executionObservation="turn_completed")
            finally:
                if process.stdin:
                    process.stdin.close()
                if process.stdout:
                    process.stdout.close()
        except DeliveryError:
            raise
        except (OSError, subprocess.SubprocessError, BridgeError, ValueError, AttributeError) as error:
            raise DeliveryError("codex_transport_failed", uncertain=sent) from error
        finally:
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


class WorkBuddyACPClient:
    def __init__(self, endpoint, session_id, cwd, token_file=None, timeout=30):
        value = urlsplit(endpoint)
        try:
            loopback = value.hostname == "localhost" or ipaddress.ip_address(value.hostname).is_loopback
        except (ValueError, TypeError):
            loopback = False
        if (value.scheme not in {"http", "https"} or not value.hostname or value.username or value.password
                or value.path not in {"", "/"} or value.query or value.fragment or (value.scheme == "http" and not loopback)):
            raise BridgeError("invalid_arguments", "WorkBuddy requires an explicit HTTPS ACP origin or loopback HTTP origin.")
        if not isinstance(cwd, str) or not Path(cwd).is_absolute():
            raise BridgeError("invalid_arguments", "WorkBuddy requires the intended session's absolute working directory.")
        self.endpoint = value
        self.session_id = _bounded_identity(session_id, "sessionID")
        self.cwd = cwd
        self.target = "workbuddy:" + self.session_id
        self.token_file = token_file
        self.timeout = timeout

    def _request(self, path, payload, extra_headers=None, method="POST", timeout=None):
        connection_type = http.client.HTTPSConnection if self.endpoint.scheme == "https" else http.client.HTTPConnection
        connection = connection_type(self.endpoint.hostname, self.endpoint.port, timeout=timeout or self.timeout)
        headers = {"Content-Type": "application/json", "X-CodeBuddy-Request": "1", "Accept": "application/json, text/event-stream"}
        if self.token_file:
            token = private_file(self.token_file).read_text().strip()
            if not token or "\r" in token or "\n" in token:
                raise DeliveryError("workbuddy_invalid_token")
            headers["Authorization"] = "Bearer " + token
        headers.update(extra_headers or {})
        try:
            connection.connect()
            connection.request(method, path, canonical_json(payload).encode() if payload is not None else None, headers)
            response = connection.getresponse()
            if 300 <= response.status < 400:
                raise DeliveryError("workbuddy_redirect_rejected")
            if not 200 <= response.status < 300:
                raise DeliveryError("workbuddy_request_rejected", uncertain=response.status >= 500)
            return connection, response
        except BaseException:
            connection.close()
            raise

    def send(self, events, on_accepted=None):
        headers, started, completed = {}, False, False
        try:
            connection, response = self._request("/api/v1/acp/connect", {})
            try:
                body = response.read(MAX_RESPONSE + 1)
                if len(body) > MAX_RESPONSE:
                    raise DeliveryError("workbuddy_response_too_large")
                binding = parse_json(body)
                headers["acp-connection-id"] = _bounded_identity(binding.get("connectionId"), "connectionId")
                if binding.get("sessionToken"):
                    headers["acp-session-token"] = _bounded_identity(binding["sessionToken"], "sessionToken")
            finally:
                connection.close()

            def request(identifier, method, params):
                connection, response = self._request("/api/v1/acp", {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params},
                                                     headers, timeout=3600 if method == "session/prompt" else self.timeout)
                try:
                    while True:
                        line = response.readline(MAX_RESPONSE + 1)
                        if not line or len(line) > MAX_RESPONSE:
                            raise DeliveryError("workbuddy_incomplete_response", uncertain=started)
                        if line.startswith(b"data:"):
                            line = line[5:].strip()
                        elif not line.lstrip().startswith(b"{"):
                            continue  # SSE event names, keepalives and blank lines.
                        message = parse_json(line)
                        if "id" in message and message.get("method") == "session/request_permission":
                            # This adapter cannot grant permissions for a background
                            # turn. Explicit cancellation preserves the user's policy.
                            reply, acknowledgement = self._request("/api/v1/acp", {"jsonrpc": "2.0", "id": message["id"],
                                "result": {"outcome": {"outcome": "cancelled"}}}, headers)
                            acknowledgement.close()
                            reply.close()
                            continue
                        if message.get("id") != identifier:
                            continue  # Discard model output and unrelated notifications.
                        if "error" in message:
                            raise DeliveryError("workbuddy_rpc_rejected")
                        if not isinstance(message.get("result"), dict):
                            raise DeliveryError("workbuddy_invalid_response", uncertain=started)
                        return message["result"]
                finally:
                    connection.close()

            request("initialize", "initialize", {"protocolVersion": 1, "clientCapabilities": {},
                                                  "clientInfo": {"name": "record-for-agent-delivery", "version": "0.1.0"}})
            # session/resume is explicitly published in the installed server's
            # OpenAPI ACP description. It restores the chosen session without replay.
            request("resume", "session/resume", {"sessionId": self.session_id, "cwd": self.cwd, "mcpServers": []})
            started = True
            result = request(batch_id(events), "session/prompt", {"sessionId": self.session_id,
                              "prompt": [{"type": "text", "text": event_message(events)}]})
            if not isinstance(result.get("stopReason"), str):
                raise DeliveryError("workbuddy_missing_stop_reason", uncertain=True)
            completed = True
            acknowledgement = {"kind": "workbuddy_prompt_returned", "sessionID": self.session_id,
                               "stopReason": result["stopReason"], "desktopVisibility": "not_verified"}
            if on_accepted:
                on_accepted(acknowledgement)
            return acknowledgement
        except DeliveryError:
            raise
        except (OSError, http.client.HTTPException, BridgeError, ValueError, AttributeError) as error:
            raise DeliveryError("workbuddy_transport_failed", uncertain=started) from error
        finally:
            if headers and (completed or not started):
                try:
                    connection, response = self._request("/api/v1/acp", None, headers, method="DELETE")
                    response.close()
                    connection.close()
                except (DeliveryError, OSError, http.client.HTTPException, BridgeError):
                    pass


def configured_client(value):
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int or value["schemaVersion"] != 1:
        raise BridgeError("invalid_arguments", "Client config schemaVersion must be 1.")
    if value.get("kind") == "codex-stdio" and set(value) == {"schemaVersion", "kind", "executable", "threadID", "cwd"}:
        return CodexClient(value["executable"], value["threadID"], value["cwd"])
    if (value.get("kind") == "workbuddy-acp" and
            set(value) in ({"schemaVersion", "kind", "endpoint", "sessionID", "cwd"}, {"schemaVersion", "kind", "endpoint", "sessionID", "cwd", "tokenFile"})):
        return WorkBuddyACPClient(value["endpoint"], value["sessionID"], value["cwd"], value.get("tokenFile"))
    raise BridgeError("invalid_arguments", "Client config fields do not match a supported explicit target.")


def dispatch_once(store, client):
    events = []
    for event in store.pending(client.target):
        if len(event_message(events + [event]).encode()) > MAX_NOTIFICATION_BYTES:
            break
        if store.claim(client.target, event["eventID"]):
            events.append(event)
    accepted, retry, uncertain = 0, 0, 0
    def acknowledge(acknowledgement):
        nonlocal accepted
        for event in events:
            store.accepted(client.target, event["eventID"], acknowledgement)
        accepted = len(events)
    if events:
        try:
            acknowledgement = client.send(events, on_accepted=acknowledge)
            if not accepted:
                acknowledge(acknowledgement)
        except DeliveryError as error:
            if not accepted:
                for event in events:
                    store.failed(client.target, event["eventID"], error.uncertain)
                uncertain = len(events) if error.uncertain else 0
                retry = len(events) if not error.uncertain else 0
    return {"target": client.target, "accepted": accepted, "retry": retry, "uncertain": uncertain,
            "processingCompletion": "owned_by_agent"}
