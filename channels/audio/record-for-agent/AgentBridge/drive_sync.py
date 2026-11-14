#!/usr/bin/env python3
"""Private Library -> the owner's Google Drive, without an intermediary server.

No service is installed and no Agent is contacted. Remote writes use previously
persisted, Google-generated IDs. Binary CAF/JSON/TXT files are never converted to
Google Docs, because Drive does not support pre-generated IDs for that conversion.
"""

import argparse
import base64
import contextlib
import fcntl
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import math
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import uuid
import webbrowser

from library import BridgeError, DB_NAME, Library, canonical_json, parse_json


DRIVE = "https://www.googleapis.com/drive/v3/"
UPLOAD = "https://www.googleapis.com/upload/drive/v3/files"
TOKEN_URL = "https://oauth2.googleapis.com/token"
AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
SCOPE = "https://www.googleapis.com/auth/drive.file"
FOLDER = "application/vnd.google-apps.folder"
FIELDS = "id,name,mimeType,parents,ownedByMe,owners(emailAddress),trashed,driveId,appProperties,size,md5Checksum,sha256Checksum"
CHUNK = 4 * 1024 * 1024  # Google requires non-final chunks to be multiples of 256 KiB.


class DriveError(BridgeError):
    def __init__(self, code, message="Google Drive synchronization did not complete."):
        super().__init__(code, message)


def safe_path(value):
    path = Path(value).expanduser().absolute()
    for part in reversed((path,) + tuple(path.parents)):
        if part.is_symlink():
            raise DriveError("unsafe_path", "Symbolic links are not allowed in sync paths.")
    return path


def private_directory(value, create=False):
    path = safe_path(value)
    if create:
        missing, ancestor = [], path
        while not ancestor.exists():
            missing.append(ancestor)
            ancestor = ancestor.parent
        for part in reversed(missing):
            part.mkdir(mode=0o700)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise DriveError("unsafe_permissions", "Sync directories must be owned by this user with mode 0700.")
    return path


def private_file(value):
    path = safe_path(value)
    info = path.stat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
        raise DriveError("unsafe_permissions", "Sync and credential files must be private regular files (0600).")
    return path


def fsync_directory(path):
    descriptor = os.open(str(path), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_private(path, content):
    path = safe_path(path)
    private_directory(path.parent)
    if path.exists():
        private_file(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".drive-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextlib.contextmanager
def exclusive(path):
    path = safe_path(path)
    descriptor = os.open(str(path), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        private_file(path)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise DriveError("queue_busy", "Another sync operation owns this queue.") from error
        yield
    finally:
        os.close(descriptor)


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,256}", value):
        raise DriveError("invalid_arguments", "A valid Drive file identifier is required.")
    return value


def account(value):
    if not isinstance(value, str) or not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", value) or len(value) > 254:
        raise DriveError("invalid_arguments", "An explicit Google account email is required.")
    return value.lower()


def hashes(path):
    path = private_file(path)
    before = path.stat()
    sha, md5, size = hashlib.sha256(), hashlib.md5(), 0
    with path.open("rb") as source:
        for data in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(data); md5.update(data); size += len(data)
    after = path.stat()
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise DriveError("source_changed")
    return {"sha256": sha.hexdigest(), "md5": md5.hexdigest(), "size": size}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


class GoogleHTTP:
    """Fixed Google HTTPS endpoints; redirects never forward Authorization."""
    def __init__(self):
        self.opener = build_opener(NoRedirect())

    @staticmethod
    def validate_url(url, token=False):
        try:
            parsed = urlsplit(url)
            port = parsed.port
        except (ValueError, TypeError):
            raise DriveError("unsafe_remote_url") from None
        if (parsed.scheme != "https" or parsed.username or parsed.password or parsed.fragment
                or port not in (None, 443)):
            raise DriveError("unsafe_remote_url")
        if token:
            if url != TOKEN_URL:
                raise DriveError("unsafe_remote_url")
        elif (parsed.hostname != "www.googleapis.com"
              or not (parsed.path.startswith("/drive/v3/")
                      or re.fullmatch(r"/upload/drive/v3/files(?:/[A-Za-z0-9_-]+)?", parsed.path))):
            raise DriveError("unsafe_remote_url")
        return url

    def request(self, method, url, *, headers=None, body=None, token=False, sink=None):
        self.validate_url(url, token=token)
        request = Request(url, data=body, headers=headers or {}, method=method)
        try:
            try:
                response = self.opener.open(request, timeout=60)
            except HTTPError as error:
                response = error
            with response:
                status, response_headers = response.code, {k.lower(): v for k, v in response.headers.items()}
                if sink is not None and status == 200:
                    while True:
                        data = response.read(1024 * 1024)
                        if not data: break
                        sink(data)
                    return status, response_headers, b""
                content = response.read(2 * 1024 * 1024 + 1)
                if len(content) > 2 * 1024 * 1024:
                    raise DriveError("response_too_large")
                return status, response_headers, content
        except (URLError, TimeoutError, OSError) as error:
            # Never expose a URL, token, response body, or arbitrary network error.
            raise DriveError("network_unavailable") from error


def client_configuration(path):
    if not Path(path).expanduser().exists():
        raise DriveError("setup_required", "Install your own desktop OAuth client JSON first.")
    value = parse_json(private_file(path).read_bytes())
    installed = value.get("installed") if isinstance(value, dict) else None
    if (not isinstance(installed, dict)
            or not isinstance(installed.get("client_id"), str)
            or not re.fullmatch(r"[A-Za-z0-9_.-]+\.apps\.googleusercontent\.com", installed.get("client_id", ""))
            or installed.get("auth_uri", AUTH_URL) != AUTH_URL
            or installed.get("token_uri", TOKEN_URL) != TOKEN_URL
            or ("client_secret" in installed and not valid_secret(installed["client_secret"]))):
        raise DriveError("setup_required", "A Google desktop installed-app OAuth client is required.")
    return installed


def valid_secret(value):
    return isinstance(value, str) and 0 < len(value) <= 8192 and not any(ord(c) < 33 or ord(c) > 126 for c in value)


def token_result(value, *, refresh_required=False):
    if (not isinstance(value, dict) or not valid_secret(value.get("access_token"))
            or type(value.get("expires_in")) is not int or not 1 <= value["expires_in"] <= 86400
            or (refresh_required and not valid_secret(value.get("refresh_token")))
            or ("refresh_token" in value and not valid_secret(value["refresh_token"]))):
        raise DriveError("invalid_google_response")
    if "scope" in value and (not isinstance(value["scope"], str) or SCOPE not in value["scope"].split()):
        raise DriveError("credential_scope_mismatch")
    return value


class FileTokenProvider:
    """Separate replaceable token provider; never accesses chat-plugin credentials."""
    def __init__(self, client_config, token_file, expected_account, http=None):
        self.client = client_configuration(client_config)
        self.path = safe_path(token_file)
        self.expected_account = account(expected_account)
        self.http = http or GoogleHTTP()

    def __call__(self):
        if not self.path.exists():
            raise DriveError("setup_required", "Complete the explicit desktop OAuth authorization first.")
        private_directory(self.path.parent)
        with exclusive(self.path.with_suffix(self.path.suffix + ".lock")):
            saved = parse_json(private_file(self.path).read_bytes())
            if (not isinstance(saved, dict) or saved.get("account") != self.expected_account
                    or saved.get("clientID") != self.client["client_id"]
                    or not isinstance(saved.get("scopes"), list) or SCOPE not in saved["scopes"]):
                raise DriveError("credential_scope_mismatch")
            if type(saved.get("expiresAt")) not in (int, float) or not math.isfinite(saved["expiresAt"]):
                raise DriveError("credential_scope_mismatch")
            if saved["expiresAt"] > time.time() + 60 and valid_secret(saved.get("accessToken")):
                return saved["accessToken"]
            if not valid_secret(saved.get("refreshToken")):
                raise DriveError("setup_required", "Renew desktop OAuth authorization.")
            form = {"client_id": self.client["client_id"], "refresh_token": saved["refreshToken"], "grant_type": "refresh_token"}
            if self.client.get("client_secret"): form["client_secret"] = self.client["client_secret"]
            status, _, content = self.http.request("POST", TOKEN_URL, token=True,
                headers={"Content-Type": "application/x-www-form-urlencoded"}, body=urlencode(form).encode())
            if status != 200: raise DriveError("setup_required", "Google authorization must be renewed.")
            result = token_result(parse_json(content))
            saved.update(accessToken=result["access_token"], expiresAt=time.time() + int(result["expires_in"]))
            if result.get("refresh_token"): saved["refreshToken"] = result["refresh_token"]
            atomic_private(self.path, canonical_json(saved).encode())
            return saved["accessToken"]


def authorize(client_config, token_file, expected_account, *, http=None, open_browser=webbrowser.open, timeout=300):
    """Explicit, bounded PKCE + random-port loopback installation step."""
    client, expected = client_configuration(client_config), account(expected_account)
    path = safe_path(token_file)
    private_directory(path.parent, create=True)
    if path.exists():
        raise DriveError("credentials_exist", "Existing credentials are retained; use their token provider.")
    http = http or GoogleHTTP()
    state, verifier, result = secrets.token_urlsafe(32), secrets.token_urlsafe(64), {}
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    class Callback(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def setup(self):
            super().setup()
            self.connection.settimeout(2)
        def do_GET(self):
            parsed = urlsplit(self.path)
            query = parse_qs(parsed.query, keep_blank_values=True)
            valid = (self.headers.get("Host") == "127.0.0.1:%d" % self.server.server_port
                     and parsed.path == "/callback" and query.get("state") == [state]
                     and not result and ((len(query.get("code", [])) == 1 and not query.get("error")
                                         and valid_secret(query["code"][0]))
                                        or (len(query.get("error", [])) == 1 and not query.get("code"))))
            if valid:
                if query.get("code"): result["code"] = query["code"][0]
                else: result["error"] = True
            self.send_response(200 if valid else 400)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Security-Policy", "default-src 'none'")
            self.end_headers(); self.wfile.write(b"Return to Record for Agent. No recording was uploaded by this step.")
    with exclusive(path.with_suffix(path.suffix + ".lock")):
        if path.exists(): raise DriveError("credentials_exist")
        with HTTPServer(("127.0.0.1", 0), Callback) as server:
            server.timeout = 1
            redirect = "http://127.0.0.1:%d/callback" % server.server_port
            url = AUTH_URL + "?" + urlencode({"client_id": client["client_id"], "response_type": "code",
                "redirect_uri": redirect, "scope": SCOPE, "access_type": "offline", "prompt": "consent",
                "state": state, "code_challenge": challenge, "code_challenge_method": "S256", "login_hint": expected})
            if not open_browser(url): raise DriveError("browser_required")
            deadline = time.monotonic() + timeout
            while not result and time.monotonic() < deadline: server.handle_request()
        if "code" not in result: raise DriveError("authorization_not_completed")
        form = {"client_id": client["client_id"], "code": result["code"], "code_verifier": verifier,
                "redirect_uri": redirect, "grant_type": "authorization_code"}
        if client.get("client_secret"): form["client_secret"] = client["client_secret"]
        status, _, content = http.request("POST", TOKEN_URL, token=True,
            headers={"Content-Type": "application/x-www-form-urlencoded"}, body=urlencode(form).encode())
        if status != 200: raise DriveError("authorization_not_completed")
        tokens = token_result(parse_json(content), refresh_required=True)
        scopes = tokens.get("scope", "").split()
        if SCOPE not in scopes or not tokens.get("refresh_token"):
            raise DriveError("setup_required", "Offline drive.file consent is required.")
        api = DriveClient(lambda: tokens["access_token"], http=http)
        if api.current_account() != expected: raise DriveError("account_mismatch")
        saved = {"account": expected, "clientID": client["client_id"], "scopes": scopes,
            "accessToken": tokens["access_token"], "refreshToken": tokens["refresh_token"],
            "expiresAt": time.time() + int(tokens["expires_in"])}
        atomic_private(path, canonical_json(saved).encode())
    return {"status": "authorized", "scope": "drive.file", "recordingsUploaded": 0}


class DriveClient:
    def __init__(self, token_provider, http=None):
        self.token_provider, self.http = token_provider, http or GoogleHTTP()

    def request(self, method, url, *, body=None, headers=None, sink=None):
        self.http.validate_url(url)  # Validate before loading or attaching credentials.
        token = self.token_provider()
        if not valid_secret(token): raise DriveError("credential_scope_mismatch")
        merged = {"Authorization": "Bearer " + token}
        merged.update(headers or {})
        return self.http.request(method, url, headers=merged, body=body, sink=sink)

    def json(self, method, path, body=None, query=None, missing=False):
        url = DRIVE + path + ("?" + urlencode(query) if query else "")
        status, _, content = self.request(method, url, body=canonical_json(body).encode() if body is not None else None,
                                          headers={"Content-Type": "application/json"})
        if status == 404 and missing: return None
        if status not in (200, 201): raise DriveError("google_http_%d" % status)
        return parse_json(content)

    def current_account(self):
        return account(self.json("GET", "about", query={"fields": "user(emailAddress)"})["user"]["emailAddress"])

    def generate_id(self):
        value = self.json("GET", "files/generateIds", query={"count": 1, "space": "drive", "type": "files"})
        if len(value.get("ids", [])) != 1: raise DriveError("invalid_google_response")
        return identifier(value["ids"][0])

    def metadata(self, file_id):
        return self.json("GET", "files/" + identifier(file_id), query={"fields": FIELDS}, missing=True)

    def assert_private(self, metadata, expected_account, folder_id=None):
        if (not isinstance(metadata, dict) or metadata.get("ownedByMe") is not True or metadata.get("trashed") is not False
                or metadata.get("driveId") or metadata.get("owners") != [{"emailAddress": expected_account}]
                or (folder_id is not None and metadata.get("parents") != [folder_id])):
            raise DriveError("destination_not_private_owned")
        cursor, seen = None, set()
        while True:
            query = {"fields": "nextPageToken,permissions(type,role,emailAddress,deleted)", "pageSize": 100}
            if cursor: query["pageToken"] = cursor
            permissions = self.json("GET", "files/" + identifier(metadata["id"]) + "/permissions", query=query)
            if not permissions.get("permissions"):
                raise DriveError("destination_permissions_unverified")
            for permission in permissions["permissions"]:
                if (permission.get("deleted") is True or permission.get("type") != "user"
                        or permission.get("role") != "owner" or permission.get("emailAddress") != expected_account):
                    raise DriveError("destination_not_private_owned")
            cursor = permissions.get("nextPageToken")
            if not cursor: break
            if not isinstance(cursor, str) or cursor in seen or len(seen) >= 100:
                raise DriveError("invalid_google_response")
            seen.add(cursor)

    def create_folder(self, file_id, name, queue_id):
        # If a timeout makes the result uncertain, the same ID is used next time.
        return self.json("POST", "files", {"id": file_id, "name": name, "mimeType": FOLDER,
            "appProperties": {"rfaQueue": queue_id}}, query={"fields": FIELDS})

    def start_upload(self, row, folder_id, queue_id):
        metadata = {"id": row["file_id"], "name": row["name"], "mimeType": row["mime"], "parents": [folder_id],
            "appProperties": {"rfaQueue": queue_id, "rfaObject": row["key"]}}
        status, headers, _ = self.request("POST", UPLOAD + "?" + urlencode({"uploadType": "resumable", "fields": FIELDS}),
            headers={"Content-Type": "application/json", "X-Upload-Content-Type": row["mime"],
                     "X-Upload-Content-Length": str(row["size"])}, body=canonical_json(metadata).encode())
        if status not in (200, 201): raise DriveError("google_http_%d" % status)
        session = headers.get("location")
        if not isinstance(session, str): raise DriveError("invalid_google_response")
        self.http.validate_url(session)
        if not urlsplit(session).path.startswith("/upload/drive/v3/files"):
            raise DriveError("unsafe_remote_url")
        return session

    def upload_status(self, session, size):
        self.validate_session(session)
        return self.request("PUT", session, headers={"Content-Range": "bytes */%d" % size,
                                                      "Content-Length": "0"}, body=b"")

    def upload_chunk(self, session, data, offset, size, mime):
        self.validate_session(session)
        return self.request("PUT", session, body=data, headers={"Content-Type": mime,
            "Content-Length": str(len(data)), "Content-Range": "bytes %d-%d/%d" % (offset, offset + len(data) - 1, size)})

    def validate_session(self, session):
        self.http.validate_url(session)
        if not re.fullmatch(r"/upload/drive/v3/files(?:/[A-Za-z0-9_-]+)?", urlsplit(session).path):
            raise DriveError("unsafe_remote_url")

    def download_hash(self, file_id, expected_size):
        digest, size = hashlib.sha256(), 0
        def sink(data):
            nonlocal size
            size += len(data)
            if size > expected_size: raise DriveError("remote_integrity_mismatch")
            digest.update(data)
        status, _, _ = self.request("GET", DRIVE + "files/" + identifier(file_id) + "?alt=media", sink=sink)
        if status != 200 or size != expected_size: raise DriveError("remote_integrity_mismatch")
        return digest.hexdigest()


class DriveSync:
    @classmethod
    def initialize(cls, state, library, expected_account, folder_id, *, scope, since_ms=None, folder_name="Record for Agent"):
        root, library = private_directory(state, create=True), safe_path(library)
        if not library.is_dir(): raise DriveError("library_unavailable")
        if scope not in ("all", "future") or (scope == "future" and (type(since_ms) is not int or since_ms < 0)) or (scope == "all" and since_ms is not None):
            raise DriveError("invalid_scope")
        if not isinstance(folder_name, str) or not 1 <= len(folder_name) <= 128 or any(ord(c) < 32 for c in folder_name):
            raise DriveError("invalid_arguments")
        configuration = {"library": str(library), "account": account(expected_account),
            "folderID": None if folder_id == "new" else identifier(folder_id), "createFolder": folder_id == "new",
            "folderName": folder_name, "scope": scope, "sinceMS": since_ms}
        database = root / "drive-sync.sqlite3"
        with exclusive(root / "queue.lock"):
            if database.exists():
                queue = cls(root)
                existing = dict(queue.configuration)
                if configuration["createFolder"]: existing["folderID"] = None
                if existing != configuration: raise DriveError("configuration_conflict")
                return queue
            descriptor = os.open(str(database), os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            os.close(descriptor)
            connection = sqlite3.connect(str(database))
            try:
                connection.execute("PRAGMA synchronous=FULL")
                connection.executescript("""
                  BEGIN IMMEDIATE;
                  CREATE TABLE configuration (singleton INTEGER PRIMARY KEY CHECK(singleton=1),value TEXT NOT NULL,queue_id TEXT NOT NULL);
                  CREATE TABLE objects (sequence INTEGER PRIMARY KEY AUTOINCREMENT,key TEXT UNIQUE NOT NULL,recording_id TEXT,
                    kind TEXT NOT NULL,local_name TEXT NOT NULL,name TEXT NOT NULL,mime TEXT NOT NULL,size INTEGER NOT NULL,
                    sha256 TEXT NOT NULL,md5 TEXT NOT NULL,source_json TEXT NOT NULL,file_id TEXT UNIQUE,session_url TEXT,status TEXT NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0,retry_at REAL NOT NULL DEFAULT 0,error TEXT);
                  CREATE TABLE changes (sequence INTEGER PRIMARY KEY AUTOINCREMENT,object_key TEXT UNIQUE NOT NULL,event TEXT NOT NULL);
                  CREATE TABLE publications (last_planned INTEGER NOT NULL);
                  INSERT INTO publications VALUES (0);
                  PRAGMA user_version=1;
                """)
                connection.execute("INSERT INTO configuration VALUES (1,?,?)", (canonical_json(configuration), str(uuid.uuid4())))
                connection.commit()
            finally: connection.close()
            fsync_directory(root)
        return cls(root)

    def __init__(self, state):
        self.root = private_directory(state)
        self.database = private_file(self.root / "drive-sync.sqlite3")
        self.snapshots = private_directory(self.root / "snapshots", create=True)
        with self.connection() as connection:
            if connection.execute("PRAGMA user_version").fetchone()[0] != 1: raise DriveError("invalid_schema")
            row = connection.execute("SELECT value,queue_id FROM configuration WHERE singleton=1").fetchone()
            self.configuration, self.queue_id = parse_json(row["value"]), row["queue_id"]
        config = self.configuration
        if (not isinstance(config, dict)
                or set(config) != {"library", "account", "folderID", "createFolder", "folderName", "scope", "sinceMS"}
                or config["scope"] not in ("all", "future")
                or (config["scope"] == "future" and (type(config["sinceMS"]) is not int or config["sinceMS"] < 0))
                or (config["scope"] == "all" and config["sinceMS"] is not None)
                or type(config["createFolder"]) is not bool
                or (config["folderID"] is None and not config["createFolder"])
                or (config["folderID"] is not None and identifier(config["folderID"]) != config["folderID"])
                or not isinstance(config["folderName"], str) or not 1 <= len(config["folderName"]) <= 128
                or not isinstance(config["library"], str) or not Path(config["library"]).is_absolute()
                or account(config["account"]) != config["account"]): raise DriveError("invalid_configuration")
        try: uuid.UUID(self.queue_id)
        except (ValueError, TypeError): raise DriveError("invalid_configuration") from None
        self.library = Library(safe_path(self.configuration["library"]))

    @contextlib.contextmanager
    def connection(self):
        private_file(self.database)
        for suffix in ("-journal", "-wal", "-shm"):
            path = Path(str(self.database) + suffix)
            if path.exists(): private_file(path)
        connection = sqlite3.connect(str(self.database), timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA synchronous=FULL")
        try:
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback(); raise
        finally: connection.close()

    def status(self):
        with self.connection() as connection:
            states = dict(connection.execute("SELECT status,count(*) FROM objects GROUP BY status"))
            errors = dict(connection.execute("SELECT error,count(*) FROM objects WHERE error IS NOT NULL GROUP BY error"))
            ready = connection.execute("SELECT count(*) FROM objects WHERE kind='audio' AND status='verified'").fetchone()[0]
            cursor = connection.execute("SELECT max(sequence) FROM changes").fetchone()[0] or 0
        return {"status": "configured", "scope": self.configuration["scope"], "folderConfigured": bool(self.configuration["folderID"]),
                "objects": states, "errors": errors, "verifiedAudioFiles": ready, "changeSequence": cursor,
                "agentsNotified": 0, "sourceModified": False}

    def _object(self, key):
        with self.connection() as connection:
            row = connection.execute("SELECT * FROM objects WHERE key=?", (key,)).fetchone()
        return dict(row) if row else None

    def _add(self, key, recording_id, kind, name, mime, *, content=None, source=None, expected=None, source_identity=None):
        if self._object(key): return False
        local_name = hashlib.sha256(key.encode()).hexdigest()
        target = self.snapshots / local_name
        if source is None:
            atomic_private(target, content)
        else:
            source = safe_path(source)
            before = source.stat()
            if not stat.S_ISREG(before.st_mode): raise DriveError("unsafe_path")
            descriptor, temporary = tempfile.mkstemp(prefix=".snapshot-", dir=self.snapshots)
            try:
                with os.fdopen(descriptor, "wb") as output, source.open("rb") as input_file:
                    for data in iter(lambda: input_file.read(1024 * 1024), b""): output.write(data)
                    output.flush(); os.fsync(output.fileno())
                after = source.stat()
                if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                    raise DriveError("source_changed")
                os.replace(temporary, target); fsync_directory(self.snapshots)
            finally:
                if os.path.exists(temporary): os.unlink(temporary)
        digest = hashes(target)
        if expected and (digest["sha256"] != expected["sha256"] or digest["size"] != expected["byteCount"]):
            raise DriveError("source_integrity_mismatch")
        with self.connection() as connection:
            connection.execute("INSERT INTO objects(key,recording_id,kind,local_name,name,mime,size,sha256,md5,source_json,status) VALUES (?,?,?,?,?,?,?,?,?,?,'pending')",
                (key, recording_id, kind, local_name, name, mime, digest["size"], digest["sha256"], digest["md5"], canonical_json(source_identity)))
        return True

    def plan(self):
        with exclusive(self.root / "queue.lock"):
            self._refresh_configuration()
            return self._plan()

    def _refresh_configuration(self):
        # Two CLI instances can be constructed before either acquires the lock.
        # Reload a folder ID reserved by the other process before making writes.
        latest = DriveSync(self.root)
        before, after = dict(self.configuration), dict(latest.configuration)
        old_folder = before.pop("folderID")
        new_folder = after.pop("folderID")
        if (before != after or self.queue_id != latest.queue_id
                or (old_folder is not None and old_folder != new_folder)):
            raise DriveError("configuration_conflict")
        self.configuration = latest.configuration

    def _plan(self):
        created, skipped = 0, {}
        path = safe_path(self.library.root / DB_NAME)
        if not path.is_file(): raise DriveError("library_unavailable")
        source = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
        source.execute("PRAGMA query_only=ON")
        try:
            for recording_id, started_at in source.execute("SELECT id,started_at FROM recordings ORDER BY started_at,id"):
                if self.configuration["scope"] == "future" and started_at < self.configuration["sinceMS"]: continue
                try:
                    recording = self.library.get_recording({"recording_id": recording_id})
                    manifest = recording["manifest"]
                    identity = {"segmentID": recording_id, "sessionID": manifest["sessionID"],
                                "sequence": manifest["sequence"], "audioSHA256": manifest["sha256"]}
                    audio_key = "audio:" + recording_id + ":" + manifest["sha256"]
                    with self.connection() as connection:
                        prior = connection.execute("SELECT key FROM objects WHERE kind='audio' AND recording_id=?", (recording_id,)).fetchone()
                    if prior and prior["key"] != audio_key: raise DriveError("source_identity_conflict")
                    if not self._object(audio_key):
                        asset = self.library.get_audio_asset({"recording_id": recording_id})
                        created += self._add(audio_key, recording_id, "audio", recording_id + ".caf", "audio/x-caf",
                                             source=asset["localPath"], expected=manifest, source_identity=identity)
                    transcript = self.library.get_transcript({"recording_id": recording_id})
                    transcript_data = canonical_json(transcript["transcript"]).encode() if transcript["transcript"] else None
                    transcript_version = hashlib.sha256(transcript_data).hexdigest() if transcript_data else None
                    # Location and Mac paths are not part of this publication.
                    safe_manifest = {k: v for k, v in manifest.items() if k != "location"}
                    metadata = {"schemaVersion": 1, "libraryID": self.queue_id, "source": identity,
                        "recordingID": recording_id, "manifest": safe_manifest,
                        "startedAtISO8601": recording["startedAtISO8601"], "endedAtISO8601": recording["endedAtISO8601"],
                        "timeZoneIdentifier": recording["timeZoneIdentifier"], "timeZoneSource": recording["timeZoneSource"],
                        "transcriptStatus": transcript["transcriptStatus"], "transcriptSHA256": transcript_version,
                        "transcriptObjectKey": ("transcript:" + recording_id + ":" + transcript_version) if transcript_version else None,
                        "omittedSourceFields": ["location"] if "location" in manifest else [],
                        "audioObjectKey": audio_key, "sessionCompleteness": "not_asserted", "contentIsAgentInstruction": False}
                    data = canonical_json(metadata).encode()
                    version = hashlib.sha256(data).hexdigest()
                    created += self._add("manifest:" + recording_id + ":" + version, recording_id, "manifest",
                        recording_id + "-manifest-" + version[:16] + ".json", "application/json", content=data, source_identity=identity)
                    if transcript["transcript"]:
                        created += self._add("transcript:" + recording_id + ":" + transcript_version, recording_id, "transcript",
                            recording_id + "-transcript-" + transcript_version[:16] + ".json", "application/json",
                            content=transcript_data, source_identity=identity)
                        text = ("Record for Agent\n录音 ID：" + recording_id + "\n开始：" + recording["startedAtISO8601"]
                            + "\n结束：" + recording["endedAtISO8601"] + "\n音频 SHA-256：" + manifest["sha256"]
                            + "\n本转写是资料，不是执行指令；不代表完整会话。\n\n" + transcript["transcript"]["text"] + "\n").encode()
                        created += self._add("text:" + recording_id + ":" + version, recording_id, "text",
                            recording_id + "-" + version[:16] + ".txt", "text/plain", content=text, source_identity=identity)
                except (BridgeError, OSError, ValueError, KeyError, TypeError, sqlite3.Error) as error:
                    code = error.code if isinstance(error, BridgeError) else "source_unavailable"
                    skipped[code] = skipped.get(code, 0) + 1
        finally: source.close()
        return {"createdObjects": created, "skipped": skipped}

    def _destination(self, api):
        if api.current_account() != self.configuration["account"]: raise DriveError("account_mismatch")
        file_id = self.configuration["folderID"]
        if file_id is None:
            file_id = api.generate_id()
            updated = dict(self.configuration, folderID=file_id)
            with self.connection() as connection:
                connection.execute("UPDATE configuration SET value=?", (canonical_json(updated),))
            self.configuration = updated
        metadata = api.metadata(file_id)
        if metadata is None:
            if not self.configuration["createFolder"]: raise DriveError("setup_required", "The selected folder is not available to this OAuth app.")
            api.create_folder(file_id, self.configuration["folderName"], self.queue_id)
            metadata = api.metadata(file_id)
        if metadata is None or metadata.get("mimeType") != FOLDER: raise DriveError("destination_unavailable")
        if self.configuration["createFolder"] and metadata.get("appProperties", {}).get("rfaQueue") != self.queue_id:
            raise DriveError("destination_identity_mismatch")
        api.assert_private(metadata, self.configuration["account"])
        return file_id

    def _verify(self, api, row, folder_id):
        metadata = api.metadata(row["file_id"])
        if metadata is None: return False
        api.assert_private(metadata, self.configuration["account"], folder_id)
        if (metadata.get("name") != row["name"] or metadata.get("mimeType") != row["mime"]
                or metadata.get("appProperties") != {"rfaQueue": self.queue_id, "rfaObject": row["key"]}
                or metadata.get("size") != str(row["size"]) or metadata.get("md5Checksum") != row["md5"]):
            raise DriveError("remote_integrity_mismatch")
        sha = metadata.get("sha256Checksum") or api.download_hash(row["file_id"], row["size"])
        if sha != row["sha256"]: raise DriveError("remote_integrity_mismatch")
        event = {"recordingID": row["recording_id"], "kind": row["kind"], "objectKey": row["key"],
            "source": parse_json(row["source_json"]),
            "fileID": row["file_id"], "sha256": row["sha256"], "byteCount": row["size"],
            "url": "https://drive.google.com/file/d/" + row["file_id"] + "/view"}
        with self.connection() as connection:
            connection.execute("UPDATE objects SET status='verified',session_url=NULL,error=NULL,retry_at=0 WHERE key=?", (row["key"],))
            if row["kind"] != "changes":
                connection.execute("INSERT OR IGNORE INTO changes(object_key,event) VALUES (?,?)", (row["key"], canonical_json(event)))
        return True

    @staticmethod
    def _offset(headers, size):
        value = headers.get("range")
        if value is None: return 0
        match = re.fullmatch(r"bytes=0-([0-9]+)", value)
        if not match or not 0 < int(match[1]) + 1 <= size: raise DriveError("invalid_upload_range")
        return int(match[1]) + 1

    def _upload(self, api, row, folder_id):
        if row["local_name"] != hashlib.sha256(row["key"].encode()).hexdigest():
            raise DriveError("invalid_local_state")
        path = self.snapshots / row["local_name"]
        if hashes(path) != {"sha256": row["sha256"], "md5": row["md5"], "size": row["size"]}:
            raise DriveError("snapshot_integrity_mismatch")
        if row["file_id"] is None:
            file_id = api.generate_id()
            with self.connection() as connection:
                connection.execute("UPDATE objects SET file_id=? WHERE key=?", (file_id, row["key"]))
            row["file_id"] = file_id
        if self._verify(api, row, folder_id): return
        session = row["session_url"]
        if session is None:
            session = api.start_upload(row, folder_id, self.queue_id)
            with self.connection() as connection:
                connection.execute("UPDATE objects SET session_url=? WHERE key=?", (session, row["key"]))
        status, headers, _ = api.upload_status(session, row["size"])
        if status in (404, 410):
            with self.connection() as connection:
                connection.execute("UPDATE objects SET session_url=NULL WHERE key=?", (row["key"],))
            raise DriveError("upload_session_expired")
        if status in (200, 201):
            if not self._verify(api, row, folder_id): raise DriveError("remote_result_pending")
            return
        if status != 308: raise DriveError("google_http_%d" % status)
        offset = self._offset(headers, row["size"])
        with path.open("rb") as source:
            while offset < row["size"]:
                source.seek(offset); data = source.read(min(CHUNK, row["size"] - offset))
                if not data: raise DriveError("snapshot_integrity_mismatch")
                status, headers, _ = api.upload_chunk(session, data, offset, row["size"], row["mime"])
                if status in (200, 201):
                    if not self._verify(api, row, folder_id): raise DriveError("remote_result_pending")
                    return
                if status != 308: raise DriveError("google_http_%d" % status)
                next_offset = self._offset(headers, row["size"])
                if not offset < next_offset <= offset + len(data): raise DriveError("invalid_upload_range")
                offset = next_offset
        raise DriveError("remote_result_pending")

    def _plan_changes(self):
        with self.connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            after = connection.execute("SELECT last_planned FROM publications").fetchone()[0]
            rows = connection.execute("SELECT sequence,event FROM changes WHERE sequence>? ORDER BY sequence LIMIT 100", (after,)).fetchall()
            if not rows: return
            start, end = rows[0]["sequence"], rows[-1]["sequence"]
            payload = {"schemaVersion": 1, "libraryID": self.queue_id, "fromSequence": start, "toSequence": end,
                       "completeSession": False, "changes": [{"sequence": r["sequence"], **parse_json(r["event"])} for r in rows]}
            key = "changes:%d:%d" % (start, end)
            local_name = hashlib.sha256(key.encode()).hexdigest()
            target = self.snapshots / local_name
            atomic_private(target, canonical_json(payload).encode())
            digest = hashes(target)
            # Object admission and cursor advancement commit together, including after a crash.
            connection.execute("INSERT INTO objects(key,kind,local_name,name,mime,size,sha256,md5,source_json,status) VALUES (?,'changes',?,?, 'application/json',?,?,?,'null','pending')",
                (key, local_name, "changes-%012d-%012d.json" % (start, end), digest["size"], digest["sha256"], digest["md5"]))
            connection.execute("UPDATE publications SET last_planned=?", (end,))

    def sync(self, api, max_files=20):
        if type(max_files) is not int or not 1 <= max_files <= 100: raise DriveError("invalid_arguments")
        with exclusive(self.root / "queue.lock"):
            self._refresh_configuration()
            folder_id = self._destination(api)
            planned = self._plan()
            self._plan_changes()
            verified, failed = 0, {}
            with self.connection() as connection:
                rows = [dict(r) for r in connection.execute("SELECT * FROM objects WHERE status!='verified' AND retry_at<=? ORDER BY sequence LIMIT ?", (time.time(), max_files))]
            for row in rows:
                try:
                    # Recheck the destination before each publication; never expand permissions.
                    api.assert_private(api.metadata(folder_id), self.configuration["account"])
                    self._upload(api, row, folder_id); verified += 1
                except (BridgeError, OSError, ValueError, KeyError, TypeError) as error:
                    code = error.code if isinstance(error, BridgeError) else "sync_unavailable"
                    failed[code] = failed.get(code, 0) + 1
                    with self.connection() as connection:
                        connection.execute("UPDATE objects SET attempts=attempts+1,error=?,retry_at=? WHERE key=?",
                            (code, time.time() + min(3600, 15 * 2 ** min(row["attempts"], 8)), row["key"]))
                    if code in ("account_mismatch", "destination_not_private_owned", "setup_required", "credential_scope_mismatch"):
                        break
            self._plan_changes()
            return {**planned, "verifiedThisRun": verified, "failed": failed, **self.status()}

    def watch(self, api, *, interval=30, max_files=20, cycles=None, emit=print, sleeper=time.sleep):
        """Explicit foreground runner; never installs or schedules a service."""
        if type(interval) is not int or not 5 <= interval <= 86400 or (cycles is not None and (type(cycles) is not int or cycles < 1)):
            raise DriveError("invalid_arguments")
        iteration = 0
        while cycles is None or iteration < cycles:
            try:
                emit(canonical_json(self.sync(api, max_files)))
            except DriveError as error:
                if error.code not in ("network_unavailable", "google_http_429", "google_http_500", "google_http_502", "google_http_503", "google_http_504"):
                    raise
                emit(canonical_json({"error": {"code": error.code}, "sourceModified": False}))
            iteration += 1
            if cycles is None or iteration < cycles: sleeper(interval)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    auth = commands.add_parser("auth", help="Explicit browser PKCE consent; uploads no recordings.")
    auth.add_argument("--client-config", required=True); auth.add_argument("--token-file", required=True); auth.add_argument("--account", required=True)
    initialize = commands.add_parser("init")
    initialize.add_argument("--state", required=True); initialize.add_argument("--library", required=True); initialize.add_argument("--account", required=True)
    initialize.add_argument("--folder-id", required=True, help="An app-accessible private folder ID, or new.")
    initialize.add_argument("--folder-name", default="Record for Agent")
    initialize.add_argument("--scope", choices=("all", "future"), required=True); initialize.add_argument("--since-ms", type=int)
    for name in ("status", "plan", "sync", "watch"):
        command = commands.add_parser(name); command.add_argument("--state", required=True)
        if name in ("sync", "watch"):
            command.add_argument("--client-config", required=True); command.add_argument("--token-file", required=True)
            command.add_argument("--max-files", type=int, default=20)
            if name == "watch":
                command.add_argument("--interval", type=int, default=30)
                command.add_argument("--cycles", type=int, help="Optional finite foreground runs.")
    args = parser.parse_args(argv)
    try:
        if args.command == "auth": result = authorize(args.client_config, args.token_file, args.account)
        elif args.command == "init":
            result = DriveSync.initialize(args.state, args.library, args.account, args.folder_id,
                scope=args.scope, since_ms=args.since_ms, folder_name=args.folder_name).status()
        else:
            queue = DriveSync(args.state)
            if args.command in ("sync", "watch"):
                provider = FileTokenProvider(args.client_config, args.token_file, queue.configuration["account"])
                if args.command == "watch":
                    queue.watch(DriveClient(provider), interval=args.interval, max_files=args.max_files, cycles=args.cycles)
                    return 0
                result = queue.sync(DriveClient(provider), args.max_files)
            elif args.command == "plan": result = queue.plan()
            else: result = queue.status()
        print(canonical_json(result))
        return 2 if result.get("failed") or result.get("skipped") else 0
    except KeyboardInterrupt:
        return 130
    except (BridgeError, OSError, ValueError, KeyError, TypeError, sqlite3.Error) as error:
        code = error.code if isinstance(error, BridgeError) else "local_state_unavailable"
        print(canonical_json({"error": {"code": code}, "sourceModified": False})); return 1


if __name__ == "__main__":
    raise SystemExit(main())
