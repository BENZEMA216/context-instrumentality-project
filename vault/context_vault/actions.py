"""Single-use authorizations and a fixed-destination HTTPS transport.

There is no generic outbound HTTP tool. The owner chooses the endpoint in the
vault item, and only a successful/failed delivery receipt returns to the agent.
"""

import base64
import ipaddress
import queue
import re
import secrets
import socket
import ssl
import threading
import time
from urllib.parse import unquote_to_bytes, urlsplit


OPERATIONS = {
    "key": "use_key",
    "document": "deliver_document",
    "profile": "fill_profile",
}
DNS_SLOTS = threading.BoundedSemaphore(8)
TLS_TIMEOUT = 15.0
DNS_NAME = re.compile(
    r"(?=.{1,253}\Z)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\Z"
)
MIME = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*\Z"
)
GRANT_SECONDS = 300
MAX_REQUESTS = 256


class BrokerError(ValueError):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def _public_ip(address):
    ip = ipaddress.ip_address(address)
    if not ip.is_global or ip.is_multicast or ip.is_reserved:
        return False
    if ip.version == 6:
        # These prefixes can tunnel to an IPv4 address with a different scope.
        return not (
            ip.ipv4_mapped
            or ip.sixtofour
            or ip.teredo
            or ip in ipaddress.ip_network("64:ff9b::/96")
            or ip in ipaddress.ip_network("64:ff9b:1::/48")
        )
    return True


def validate_target(target):
    """Validate the owner-pinned destination without performing network I/O."""
    bad = BrokerError(
        "Target must be an exact public HTTPS URL on port 443, without a query or fragment."
    )
    if (
        not isinstance(target, str)
        or not target
        or len(target) > 2048
        or not target.isascii()
        or not all(33 <= ord(c) <= 126 for c in target)
        or any(c in target for c in ("\\", "?", "#"))
    ):
        raise bad
    try:
        parsed = urlsplit(target)
        host = parsed.hostname
        if (
            parsed.scheme != "https"
            or not host
            or parsed.port not in (None, 443)
            or parsed.username is not None
            or parsed.password is not None
            or "%" in host
            or parsed.netloc.endswith(":")
        ):
            raise bad
        if parsed.path.startswith("//") or re.search(
            r"%(?![0-9a-fA-F]{2})", parsed.path
        ):
            raise bad
        path_bytes = unquote_to_bytes(parsed.path)
        if any(c < 32 or c == 127 or c == 92 for c in path_bytes):
            raise bad
        try:
            ipaddress.ip_address(host)
        except ValueError:
            if not DNS_NAME.fullmatch(host) or host.endswith(
                (".local", ".localhost", ".internal", ".localdomain")
            ):
                raise bad
        else:
            if not _public_ip(host):
                raise bad
    except (ValueError, UnicodeError):
        raise bad from None
    return parsed


def _resolve(host, timeout):
    # System DNS can outlive socket timeouts. Bound both the caller's wait and
    # the number of unfinished resolver threads; nothing secret is sent to DNS.
    if not DNS_SLOTS.acquire(blocking=False):
        raise OSError("Resolver busy")
    result = queue.Queue(maxsize=1)

    def resolve():
        try:
            addresses = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
            result.put([item[4][0] for item in addresses])
        except OSError:
            result.put([])
        finally:
            DNS_SLOTS.release()

    threading.Thread(target=resolve, daemon=True).start()
    try:
        answers = result.get(timeout=timeout)
    except queue.Empty:
        raise TimeoutError from None
    if not answers or not all(_public_ip(address) for address in answers):
        raise OSError("Destination unavailable")
    return answers[0]


def _wire_parts(item, target):
    kind, value = item["kind"], item["value"]
    host_header = target.netloc
    method = "GET" if kind == "key" else "POST"
    headers = [
        f"{method} {target.path or '/'} HTTP/1.1",
        f"Host: {host_header}",
        "Connection: close",
    ]
    body = b""
    if kind == "key":
        if not re.fullmatch(r"[!-~]{1,16384}", value):
            raise ValueError("Unsupported bearer format")
        headers.append("Authorization: Bearer " + value)
    else:
        if kind == "document":
            body = base64.b64decode(value, validate=True)
            mime = item.get("mime") or "application/octet-stream"
            if not MIME.fullmatch(mime):
                raise ValueError("Unsupported media type")
        else:
            body = value.encode("utf-8")
            mime = "text/plain; charset=utf-8"
        headers.extend([f"Content-Length: {len(body)}", f"Content-Type: {mime}"])
    return ("\r\n".join(headers) + "\r\n\r\n").encode("ascii"), body


def deliver(item):
    """Send once, with TLS hostname verification, no redirects and no response body processing."""
    target = validate_target(item["target"])
    head, body = _wire_parts(item, target)
    deadline = time.monotonic() + TLS_TIMEOUT

    def remaining():
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError
        return left

    ip = _resolve(target.hostname, remaining())
    family = socket.AF_INET6 if ":" in ip else socket.AF_INET
    context = ssl.create_default_context()
    with socket.socket(family, socket.SOCK_STREAM) as tcp:
        tcp.settimeout(remaining())
        tcp.connect((ip, 443))
        tcp.settimeout(remaining())
        with context.wrap_socket(tcp, server_hostname=target.hostname) as channel:
            channel.settimeout(remaining())
            channel.sendall(head)
            if body:
                channel.settimeout(remaining())
                channel.sendall(body)
            # Only inspect the HTTP status line. A destination may echo requests
            # in any response header or body; never return remote content.
            status_line = bytearray()
            while b"\n" not in status_line and len(status_line) < 8192:
                channel.settimeout(remaining())
                chunk = channel.recv(256)
                if not chunk:
                    break
                status_line.extend(chunk)
            first_line = bytes(status_line).partition(b"\n")[0].rstrip(b"\r")
            status = re.fullmatch(rb"HTTP/1\.[01] ([0-9]{3})(?: [^\r\n]*)?", first_line)
            if b"\n" not in status_line or not status:
                raise OSError("Invalid upstream response")
            return int(status.group(1))


class Broker:
    def __init__(self, store, *, transport=deliver, clock=time.time):
        self.store = store
        self._transport = transport
        self._clock = clock
        self._lock = threading.RLock()
        self._records = {}

    def _expire(self):
        now = self._clock()
        for record in self._records.values():
            if (
                record["state"] in {"pending", "approved"}
                and record["expires_at"] <= now
            ):
                record["state"] = "expired"

    def _lookup(self, request_id, agent=None):
        self._expire()
        record = self._records.get(request_id)
        if not record or (agent is not None and record["agent"] != agent):
            raise BrokerError("Request not found.", 404)
        return record

    def request(self, agent, asset_id, purpose):
        if (
            not isinstance(asset_id, str)
            or not asset_id
            or len(asset_id) > 128
            or not asset_id.isprintable()
        ):
            raise BrokerError("A valid asset identifier is required.")
        if (
            not isinstance(purpose, str)
            or not purpose.strip()
            or len(purpose) > 256
            or not purpose.isprintable()
        ):
            raise BrokerError("A short, printable purpose is required.")
        with self._lock:
            self._expire()
            if len(self._records) >= MAX_REQUESTS:
                retired = next(
                    (
                        k
                        for k, r in self._records.items()
                        if r["state"]
                        in {"expired", "failed", "used", "denied", "revoked"}
                    ),
                    None,
                )
                if retired is None:
                    raise BrokerError("Too many open requests.", 429)
                del self._records[retired]
            item = self.store.get_item(asset_id)
            operation = OPERATIONS.get(item["kind"])
            if operation is None:
                raise BrokerError("This reference has no delivery operation.")
            validate_target(item.get("target"))
            now = int(self._clock())
            record = {
                "id": secrets.token_urlsafe(24),
                "asset_id": item["id"],
                "label": item["label"],
                "asset_revision": item["revision"],
                "kind": item["kind"],
                "agent": agent,
                "purpose": purpose.strip(),
                "target": item["target"],
                "operation": operation,
                "state": "pending",
                "created_at": now,
                "expires_at": now + GRANT_SECONDS,
            }
            self._records[record["id"]] = record
            return dict(record)

    def list(self, agent=None):
        with self._lock:
            self._expire()
            return [
                dict(record)
                for record in reversed(self._records.values())
                if agent is None or record["agent"] == agent
            ]

    def get(self, agent, request_id):
        with self._lock:
            return dict(self._lookup(request_id, agent))

    def _current_item(self, record):
        try:
            item = self.store.get_item(record["asset_id"])
        except (KeyError, ValueError):
            item = None
        if (
            not item
            or item["revision"] != record["asset_revision"]
            or item["target"] != record["target"]
            or item["kind"] != record["kind"]
        ):
            record["state"] = "revoked"
            raise BrokerError(
                "The item changed or is unavailable. A new request is required.", 409
            )
        return item

    def decision(self, request_id, action):
        with self._lock:
            record = self._lookup(request_id)
            if action == "revoke" and record["state"] in {"pending", "approved"}:
                record["state"] = "revoked"
            elif action in {"approve", "deny"} and record["state"] == "pending":
                if action == "approve":
                    self._current_item(record)
                record["state"] = "approved" if action == "approve" else "denied"
            else:
                raise BrokerError("This request cannot accept that decision.", 409)
            return dict(record)

    def execute(self, agent, request_id):
        with self._lock:
            record = self._lookup(request_id, agent)
            if record["state"] != "approved":
                raise BrokerError("A current approved request is required.", 409)
            item = self._current_item(record)
            record["state"] = "executing"
        # Mark consumed before any side effect. Timeout after remote processing
        # has unknown outcome, so a failed receipt must not trigger a retry.
        try:
            status = self._transport(item)
            success = isinstance(status, int) and 200 <= status < 300
        except (OSError, ValueError):
            success = False
        with self._lock:
            record["state"] = "used" if success else "failed"
            return dict(record)

    def clear(self):
        with self._lock:
            self._records.clear()
