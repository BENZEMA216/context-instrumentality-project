"""HTTP API and static management page for one personal Hub."""
import hmac
import json
import logging
import re
import secrets
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

from .store import StoreError

HERE = Path(__file__).resolve().parent
MAX_BODY = 16 * 1024 * 1024
ASSETS = {"/": ("index.html", "text/html"),
          "/static/style.css": ("style.css", "text/css"),
          "/static/app.js": ("app.js", "text/javascript")}
ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def event_id():
    value = (int(time.time() * 1000) << 80) | secrets.randbits(80)
    return "".join(ALPHABET[(value >> shift) & 31] for shift in range(125, -1, -5))


class HTTPError(ValueError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class HubHTTP(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, store, owner_token, agent_token, mode="local"):
        if not owner_token or not agent_token or owner_token == agent_token:
            raise ValueError("Two distinct, nonempty owner and agent credentials are required")
        self.store = store
        self.owner = owner_token.encode()
        self.agent = agent_token.encode()
        self.mode = mode
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    server_version = "ContextHub"
    sys_version = ""
    timeout = 15

    def log_request(self, code="-", size="-"):
        # Queries and URL paths can contain personal context. Do not access-log them.
        pass

    def send_body(self, status, body, mime):
        self.send_response(status)
        self.send_header("Content-Type", mime + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; script-src 'self'; style-src 'self'; "
                         "connect-src 'self'; img-src 'self' data:; object-src 'none'; "
                         "base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
        self.end_headers()
        self.wfile.write(body)

    def json_reply(self, status, obj):
        self.send_body(status, json.dumps(obj, ensure_ascii=False, allow_nan=False).encode(), "application/json")

    def is_agent(self):
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            token = auth[7:].encode()
            if hmac.compare_digest(token, self.server.owner):
                return False
            if hmac.compare_digest(token, self.server.agent):
                return True
        raise HTTPError(401, "请连接有效的 Hub 凭据")

    def body(self):
        if self.headers.get_content_type() != "application/json":
            raise HTTPError(415, "Expected application/json")
        try:
            size = int(self.headers.get("Content-Length", ""))
        except ValueError:
            raise HTTPError(411, "Content-Length required")
        if not 0 < size <= MAX_BODY:
            raise HTTPError(413, "Request body must be between 1 byte and 16 MiB")
        def reject_constant(_):
            raise ValueError("Non-finite JSON number")
        try:
            data = json.loads(self.rfile.read(size), parse_constant=reject_constant)
        except (ValueError, RecursionError):
            raise HTTPError(400, "Invalid JSON")
        if not isinstance(data, dict):
            raise HTTPError(400, "Expected a JSON object")
        return data

    def route(self):
        uri = urlsplit(self.path)
        if self.command == "GET" and uri.path == "/health":
            return self.json_reply(200, {"status": "ok", "mode": self.server.mode})
        if self.command == "GET" and uri.path in ASSETS:
            name, mime = ASSETS[uri.path]
            return self.send_body(200, (HERE / "static" / name).read_bytes(), mime)
        if not uri.path.startswith("/api/"):
            raise HTTPError(404, "Unknown endpoint")
        agent = self.is_agent()
        store = self.server.store
        if uri.path == "/api/extract" and self.command == "POST":
            if agent:
                raise HTTPError(403, "Only the owner can run extraction")
            self.body()
            return self.json_reply(200, store.extract())
        match = re.fullmatch(r"/api/(raw|memory)(?:/([^/]+))?", uri.path)
        if not match:
            raise HTTPError(404, "Unknown endpoint")
        raw = match[1] == "raw"
        ident = unquote(match[2]) if match[2] else None
        if self.command == "GET":
            if ident is not None:
                get = store.get_raw if raw else store.get_memory
                return self.json_reply(200, get(ident, agent=agent))
            params = parse_qs(uri.query, max_num_fields=8)
            q = params.get("q", [""])[0]
            limit = int(params.get("limit", ["50"])[0])
            offset = int(params.get("offset", ["0"])[0])
            if not 1 <= limit <= 200 or offset < 0 or len(q) > 2000:
                raise HTTPError(400, "Invalid search or pagination")
            find = store.list_raw if raw else store.list_memory
            return self.json_reply(200, {"items": find(q=q, limit=limit, offset=offset, agent=agent)})
        create = self.command == "POST" and ident is None
        if not create and not (ident and self.command in ("PUT", "DELETE")):
            raise HTTPError(405, "Method not available on this endpoint")
        body = self.body()
        revision = body.pop("revision", None)
        if not create and (type(revision) is not int or revision < 1):
            raise HTTPError(400, "Submit the revision from the last read")
        if create and revision is not None:
            raise HTTPError(400, "Use PUT with a revision to edit an existing record")
        if self.command == "DELETE":
            delete = store.delete_raw if raw else store.delete_memory
            return self.json_reply(200, delete(ident, revision, agent=agent))
        if ident is not None:
            if "id" in body and body["id"] != ident:
                raise HTTPError(400, "Body ID differs from the URL")
            body["id"] = ident
        if raw:
            body.setdefault("id", event_id())
            privacy = body.get("privacy")
            if self.server.mode == "cloud" and isinstance(privacy, dict) and privacy.get("tier") == "local_only":
                raise HTTPError(403, "local_only records belong on a local Hub")
            result = store.put_raw(body, expected_revision=revision, agent=agent)
        else:
            result = store.save_memory(body, expected_revision=revision, agent=agent)
        return self.json_reply(201 if create else 200, result)

    def dispatch(self):
        try:
            self.route()
        except (HTTPError, StoreError) as exc:
            self.json_reply(exc.status, {"error": str(exc)})
        except (ValueError, OverflowError, RecursionError):
            self.json_reply(400, {"error": "Invalid request value"})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            return
        except sqlite3.Error:
            logging.exception("Hub database error")
            self.json_reply(503, {"error": "Database unavailable; retry after reading the current revision"})

    do_GET = do_POST = do_PUT = do_DELETE = dispatch


def run_worker(store, interval, stopped):
    while not stopped.is_set():
        try:
            store.extract()
        except Exception:
            # A transient failure must not silently disable future extraction cycles.
            logging.exception("Memory extraction failed; retrying next interval")
        stopped.wait(interval)
