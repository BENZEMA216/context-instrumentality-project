"""Loopback owner UI and separate agent interface. Private contents are never logged."""

import hashlib
import hmac
import json
import secrets
import sys
import threading
import time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from . import intake
from .cloud import CloudFiles
from .actions import Broker, BrokerError, validate_target
from .storage import Store, VaultError

ASSETS = {
    "/": ("index.html", "text/html"),
    "/static/app.js": ("app.js", "text/javascript"),
    "/static/style.css": ("style.css", "text/css"),
}
MAX_REQUEST = 17 * 1024 * 1024
COOKIE = "cvault_session"


def icloud_folder():
    root = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs"
    return (
        root / "Context Vault" if sys.platform == "darwin" and root.is_dir() else None
    )


class Service:
    def __init__(
        self, directory, owner, agent, idle_seconds=300, backups=None, transport=None
    ):
        if not owner or not agent or hmac.compare_digest(owner, agent):
            raise ValueError("Separate owner and agent tokens are required")
        self.directory = Path(directory)
        self.store = Store(directory)
        self.broker = (
            Broker(self.store)
            if transport is None
            else Broker(self.store, transport=transport)
        )
        self.owner = owner.encode()
        self.agent = agent.encode()
        self.agent_id = "agent-" + hashlib.sha256(self.agent).hexdigest()[:8]
        self.mutex = threading.RLock()
        self.idle = idle_seconds
        self.deadline = 0
        self.session = ""
        self.backups = backups
        self.failed = []
        self.cloud = CloudFiles(directory, backups)

    def lock(self):
        self.broker.clear()
        self.store.lock()
        self.session = ""
        self.deadline = 0

    def expire(self):
        if self.store.unlocked and time.monotonic() >= self.deadline:
            self.lock()

    def role(self, header):
        key = (
            header.removeprefix("Bearer ").encode()
            if header.startswith("Bearer ")
            else b""
        )
        if hmac.compare_digest(self.owner, key):
            return "owner"
        if hmac.compare_digest(self.agent, key):
            return "agent"
        raise VaultError("Invalid credential", 401)

    def dispatch(self, method, path, role, session, body):
        self.expire()
        parts = path.strip("/").split("/")
        if path == "/health" and method == "GET":
            return {
                "initialized": self.store.initialized,
                "unlocked": self.store.unlocked,
                "icloud_available": self.backups is not None,
            }
        if (
            role == "owner"
            and method == "POST"
            and path in ("/api/setup", "/api/unlock")
        ):
            now = time.monotonic()
            self.failed = [t for t in self.failed if now - t < 60]
            if len(self.failed) >= 5:
                raise VaultError(
                    "Too many unlock attempts. Try again in one minute.", 429
                )
            try:
                if path.endswith("/setup"):
                    self.store.create(body.get("password"))
                else:
                    self.store.unlock(body.get("password"))
            except VaultError:
                if not self.store.unlocked:
                    self.lock()
                self.failed.append(now)
                raise
            self.failed.clear()
            self.session = secrets.token_urlsafe(32)
            self.deadline = now + self.idle
            intake.pairing(self.store, self.directory)
            return {"unlocked": True}
        if not self.store.unlocked:
            raise VaultError("Vault locked", 423)
        if role == "owner" and not (
            self.session
            and hmac.compare_digest(self.session.encode(), session.encode())
        ):
            raise VaultError("owner_session_required", 403)
        if role == "owner" and (
            method != "GET" or (parts[:2] == ["api", "items"] and len(parts) == 3)
        ):
            self.deadline = time.monotonic() + self.idle
        if role == "owner":
            if method == "POST" and path == "/api/lock":
                self.lock()
                return {"unlocked": False}
            if method == "GET" and path == "/api/items":
                return {"items": self.store.list_items()}
            if method == "POST" and path == "/api/items":
                if body.get("target"):
                    validate_target(body["target"])
                return self.store.save_item(body)
            if parts[:2] == ["api", "items"] and len(parts) == 3:
                if method == "GET":
                    return self.store.get_item(parts[2])
                if method == "PUT":
                    if body.get("target"):
                        validate_target(body["target"])
                    return self.store.save_item(
                        {**body, "id": parts[2]}, expected=body.get("revision")
                    )
                if method == "DELETE":
                    self.store.delete_item(parts[2], body.get("revision"))
                    return {"deleted": True}
            if path == "/api/cloud" and method == "GET":
                return self.cloud.status()
            if path == "/api/cloud" and method == "POST":
                return self.cloud.set_enabled(body.get("enabled"), self.store)
            if method == "POST" and path == "/api/backup":
                if self.backups is None:
                    raise VaultError("iCloud Drive is unavailable", 409)
                return {"name": self.store.backup(self.backups)}
            if method == "GET" and path == "/api/phone-key":
                return intake.pairing(self.store, self.directory)
            if method == "POST" and path == "/api/phone-import":
                return intake.import_drop(self.store, body.get("package"))
            if method == "GET" and path == "/api/inbox":
                return {
                    "items": intake.pending(self.store, self.directory)
                    + self.cloud.list(self.store)
                }
            if parts[:2] == ["api", "inbox"] and len(parts) in (3, 4):
                if parts[2].startswith("cloud-"):
                    if method == "POST" and parts[3:] == ["import"]:
                        result = intake.import_drop(
                            self.store, self.cloud.package(parts[2])
                        )
                        self.cloud.dismiss(parts[2])
                        return result
                    if method == "DELETE" and len(parts) == 3:
                        self.cloud.dismiss(parts[2])
                        return {"dismissed": True}
                    raise VaultError("Unavailable request", 403)
                p = intake.inbox_path(self.directory, parts[2])
                if method == "POST" and parts[3:] == ["import"]:
                    item = intake.import_drop(self.store, intake.load_package(p))
                    p.unlink()
                    return item
                if method == "DELETE" and len(parts) == 3:
                    p.unlink()
                    return {"dismissed": True}
            if path == "/api/requests" and method == "GET":
                return {"items": self.broker.list()}
            if (
                parts[:2] == ["api", "requests"]
                and len(parts) == 4
                and method == "POST"
            ):
                if parts[3] == "share":
                    from .hub_link import share_receipt

                    return share_receipt(self.broker.get(None, parts[2]))
                if parts[3] in ("approve", "deny", "revoke"):
                    return self.broker.decision(parts[2], parts[3])
        elif role == "agent":
            if method == "GET" and path == "/api/catalog":
                return {
                    "items": [
                        {k: row[k] for k in ("id", "label", "kind")}
                        for row in self.store.list_items()
                        if row["kind"] in ("key", "profile", "document")
                        and row.get("target")
                    ]
                }
            if method == "POST" and path == "/api/requests":
                return self.broker.request(
                    self.agent_id, body.get("asset_id"), body.get("purpose")
                )
            if parts[:2] == ["api", "requests"] and len(parts) == 3 and method == "GET":
                return self.broker.get(self.agent_id, parts[2])
            if (
                parts[:2] == ["api", "requests"]
                and len(parts) == 4
                and parts[3] == "use"
                and method == "POST"
            ):
                return self.broker.execute(self.agent_id, parts[2])
        raise VaultError("Unavailable operation", 403)


class VaultHTTP(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, service):
        self.service = service
        super().__init__(address, Handler)

    def service_actions(self):
        with self.service.mutex:
            self.service.expire()
            self.service.cloud.tick(self.service.store)


class Handler(BaseHTTPRequestHandler):
    timeout = 15
    server_version = "ContextVault"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    def respond(self, status, data, mime="application/json", cookie=None):
        payload = (
            data
            if isinstance(data, bytes)
            else json.dumps(data, ensure_ascii=False).encode()
        )
        self.send_response(status)
        self.send_header("Content-Type", mime + "; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'",
        )
        if cookie is not None:
            self.send_header(
                "Set-Cookie", f"{COOKIE}={cookie}; HttpOnly; SameSite=Strict; Path=/api"
            )
        self.end_headers()
        self.wfile.write(payload)

    def handle_api(self):
        service = self.server.service
        try:
            host = self.headers.get("Host", "")
            # The service is only used directly on loopback or through a loopback SSH forward.
            try:
                parsed = urlsplit("//" + host)
                if (
                    parsed.hostname not in ("localhost", "127.0.0.1", "::1")
                    or parsed.username
                    or parsed.path
                ):
                    raise ValueError()
                _ = parsed.port
            except ValueError:
                raise VaultError("Invalid local host", 403) from None
            origin = self.headers.get("Origin")
            if origin and origin not in ("http://" + host, "https://" + host):
                raise VaultError("Origin not permitted", 403)
            path = self.path
            if self.command == "GET" and path in ASSETS:
                name, mime = ASSETS[path]
                return self.respond(
                    200, (Path(__file__).parent / "static" / name).read_bytes(), mime
                )
            role = (
                None
                if self.command == "GET" and path == "/health"
                else service.role(self.headers.get("Authorization", ""))
            )
            if self.headers.get("Transfer-Encoding"):
                raise VaultError("Unsupported request encoding")
            body = {}
            if self.command != "GET":
                if self.headers.get_content_type() != "application/json":
                    raise VaultError("JSON required", 415)
                n = int(self.headers.get("Content-Length", "0"))
                if not 1 <= n <= MAX_REQUEST:
                    raise VaultError("Invalid payload size", 413)
                body = json.loads(self.rfile.read(n))
                if not isinstance(body, dict):
                    raise VaultError("Expected JSON object")
            cookies = SimpleCookie()
            cookies.load(self.headers.get("Cookie", ""))
            session = cookies[COOKIE].value if COOKIE in cookies else ""
            with service.mutex:
                data = service.dispatch(self.command, path, role, session, body)
                cookie = (
                    service.session
                    if self.command == "POST"
                    and path in ("/api/unlock", "/api/setup", "/api/lock")
                    else None
                )
            self.respond(200, data, cookie=cookie)
        except (VaultError, BrokerError) as exc:
            self.respond(exc.status, {"error": str(exc)})
        except (ValueError, TypeError, KeyError, RecursionError):
            self.respond(400, {"error": "Malformed request"})
        except (OSError, RuntimeError):
            self.respond(503, {"error": "Vault operation unavailable"})

    do_GET = do_POST = do_PUT = do_DELETE = handle_api
