"""An authenticated, portable vault and local single-writer file transactions.

CVLT v1 encodes MAGIC, Scrypt (N as uint32 big-endian, r and p as bytes),
a 16-byte per-vault salt, a fresh 12-byte nonce, and AES-256-GCM ciphertext
with the 16-byte tag appended. All bytes preceding the ciphertext are AAD.
The UTF-8 JSON plaintext contains items keyed by ID and optional internal pairing metadata.
"""

import base64
import binascii
import contextlib
import datetime
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import struct
import threading
import uuid
from urllib.parse import urlsplit

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt


N, R, P = 1 << 17, 8, 1
MAGIC = b"CTXVAULT\x00\x01"
PREFIX = MAGIC + struct.pack(">IBB", N, R, P)
SALT_LENGTH, NONCE_LENGTH = 16, 12
HEADER_SIZE = len(PREFIX) + SALT_LENGTH + NONCE_LENGTH
FILENAME = "vault.cvault"
MAX_ATTACHMENT = 8 * 1024 * 1024
MAX_FILE = 64 * 1024 * 1024
MAX_ITEMS = 2000
DOC_TYPES = {
    "image/jpeg",
    "image/png",
    "image/webp",
    "image/heic",
    "image/heif",
    "application/pdf",
    "application/octet-stream",
}
KINDS = {"document", "profile", "key", "payment", "ssh"}


class VaultError(ValueError):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def _directory(directory, create=False):
    directory = Path(directory)
    if create:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    return os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


def _read(fd, name):
    flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
    try:
        with os.fdopen(os.open(name, flags, dir_fd=fd), "rb") as source:
            info = os.fstat(source.fileno())
            if (
                not stat.S_ISREG(info.st_mode)
                or not HEADER_SIZE + 16 <= info.st_size <= MAX_FILE
            ):
                raise VaultError("Invalid or oversized vault file")
            data = source.read(MAX_FILE + 1)
    except FileNotFoundError:
        raise VaultError("Vault file not found", 404) from None
    if len(data) != info.st_size or not data.startswith(PREFIX):
        raise VaultError("Unsupported or damaged vault envelope")
    return data


def _write(fd, name, data):
    temp = ".pending-" + uuid.uuid4().hex
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    with os.fdopen(os.open(temp, flags, 0o600, dir_fd=fd), "wb") as out:
        try:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
            os.replace(temp, name, src_dir_fd=fd, dst_dir_fd=fd)
            try:
                os.fsync(fd)
            except OSError as exc:
                if exc.errno not in (errno.EINVAL, errno.ENOTSUP):
                    raise
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temp, dir_fd=fd)


def _derive(password, salt, creating=False):
    if not isinstance(password, str) or not password or len(password) > 1024:
        raise VaultError("Enter a valid vault passphrase")
    try:
        encoded = password.encode("utf-8")
    except UnicodeEncodeError:
        raise VaultError("Invalid UTF-8 passphrase") from None
    if len(encoded) > 1024 or (creating and len(password) < 12):
        raise VaultError("Use at least 12 characters and at most 1024 UTF-8 bytes")
    return bytearray(Scrypt(salt=salt, length=32, n=N, r=R, p=P).derive(encoded))


def _salt(data):
    return data[len(PREFIX) : len(PREFIX) + SALT_LENGTH]


def _decrypt(data, key):
    header = data[:HEADER_SIZE]
    try:
        clear = AESGCM(key).decrypt(header[-NONCE_LENGTH:], data[HEADER_SIZE:], header)
    except InvalidTag:
        raise VaultError("Incorrect passphrase or damaged vault", 403) from None
    try:
        payload = json.loads(clear)
        items = payload["items"]
        if not isinstance(items, dict) or len(items) > MAX_ITEMS:
            raise ValueError()
        for record_id, item in items.items():
            if (
                item["id"] != record_id
                or not isinstance(item["revision"], int)
                or item["revision"] < 1
            ):
                raise ValueError()
            if (
                item["kind"] not in KINDS
                or not isinstance(item["label"], str)
                or not isinstance(item["value"], str)
            ):
                raise ValueError()
    except (ValueError, TypeError, KeyError, RecursionError):
        raise VaultError("Unsupported vault payload") from None
    return payload


def _encrypt(payload, key, salt):
    nonce = os.urandom(NONCE_LENGTH)
    header = PREFIX + salt + nonce
    clear = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(
        "utf-8"
    )
    if len(clear) + HEADER_SIZE + 16 > MAX_FILE:
        raise VaultError("Vault exceeds its 64 MiB size limit", 413)
    return header + AESGCM(key).encrypt(nonce, clear, header)


def _summary(item):
    return {
        k: item[k] for k in ("id", "kind", "label", "revision", "target") if k in item
    }


def _erase(key):
    if key is not None:
        key[:] = bytes(len(key))


def _target(target):
    if not isinstance(target, str) or not target.isascii() or len(target) > 2048:
        raise VaultError("Expected an HTTPS destination")
    if any(ord(c) <= 32 or ord(c) == 127 for c in target) or any(
        c in target for c in "\\?#"
    ):
        raise VaultError(
            "Use an exact HTTPS URL without credentials, query, or fragment"
        )
    try:
        parts = urlsplit(target)
        if (
            parts.scheme != "https"
            or not parts.hostname
            or parts.username is not None
            or parts.password is not None
            or parts.port not in (None, 443)
        ):
            raise ValueError()
    except ValueError:
        raise VaultError("Expected an HTTPS destination on the standard port") from None
    return target


def _validate_item(item):
    if not isinstance(item, dict) or set(item) - {
        "kind",
        "label",
        "value",
        "target",
        "mime",
        "id",
        "revision",
    }:
        raise VaultError("Invalid item fields")
    kind, label, value = item.get("kind"), item.get("label"), item.get("value", "")
    if not isinstance(kind, str) or kind not in KINDS:
        raise VaultError("Unknown item kind")
    if (
        not isinstance(label, str)
        or not 1 <= len(label.strip()) <= 120
        or not label.strip().isprintable()
        or not isinstance(value, str)
    ):
        raise VaultError("Enter an item name and a valid value")
    clean = {"kind": kind, "label": label.strip(), "value": value}
    target, mime = item.get("target", ""), item.get("mime", "")
    if target != "":
        if kind in ("payment", "ssh"):
            raise VaultError("This item kind does not accept a target")
        clean["target"] = _target(target)
    if mime != "" and kind != "document":
        raise VaultError("Only documents have a MIME type")
    if kind == "document":
        if not isinstance(mime, str) or (mime and mime not in DOC_TYPES):
            raise VaultError("Unsupported document MIME type")
        if not value or len(value) > ((MAX_ATTACHMENT + 2) // 3) * 4:
            raise VaultError("Documents must contain 1 byte to 8 MiB", 413)
        try:
            size = len(base64.b64decode(value, validate=True))
        except (binascii.Error, ValueError):
            raise VaultError("Document value must be standard base64") from None
        if not 1 <= size <= MAX_ATTACHMENT:
            raise VaultError("Documents must contain 1 byte to 8 MiB", 413)
        clean["mime"] = mime or "application/octet-stream"
    elif kind == "payment":
        if value not in ("", "apple-pay", "link", "other") or re.search(
            r"(?:\d[\s-]*){12,19}", label
        ):
            raise VaultError("Payment items only store an alias and wallet provider")
    elif kind == "ssh":
        if not re.fullmatch(
            r"(?:[A-Za-z0-9][A-Za-z0-9._-]{0,63}|SHA256:[A-Za-z0-9+/]{43}=?)", value
        ):
            raise VaultError(
                "SSH items only store an SSH host alias or SHA256 public fingerprint"
            )
    elif kind == "key":
        if not re.fullmatch(r"[!-~]{1,8192}", value):
            raise VaultError("API keys must contain printable ASCII without spaces")
    elif not value.strip() or len(value) > 32768:
        raise VaultError("Profile value must contain 1 to 32768 characters")
    try:
        json.dumps(clean, ensure_ascii=False).encode("utf-8")
    except UnicodeEncodeError:
        raise VaultError("Invalid UTF-8 item") from None
    return clean


class Store:
    def __init__(self, directory):
        self.directory = Path(directory)
        self._guard = threading.RLock()
        self._key = self._salt = None
        fd = _directory(self.directory, create=True)
        try:
            if os.fstat(fd).st_mode & 0o022:
                raise VaultError(
                    "Use a private vault directory without group or public write permission"
                )
        finally:
            os.close(fd)

    @contextlib.contextmanager
    def _transaction(self, exclusive=False):
        with self._guard:
            fd = _directory(self.directory)
            try:
                flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK
                with os.fdopen(
                    os.open(".vault.lock", flags, 0o600, dir_fd=fd), "rb+"
                ) as guard:
                    if not stat.S_ISREG(os.fstat(guard.fileno()).st_mode):
                        raise VaultError("Invalid vault lock file")
                    fcntl.flock(guard, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
                    yield fd
            finally:
                os.close(fd)

    @staticmethod
    def _exists(fd):
        try:
            info = os.stat(FILENAME, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            return False
        if not stat.S_ISREG(info.st_mode):
            raise VaultError("Invalid vault file")
        return True

    @property
    def initialized(self):
        with self._transaction() as fd:
            return self._exists(fd)

    @property
    def unlocked(self):
        with self._guard:
            return self._key is not None

    def _install_key(self, key, salt):
        _erase(self._key)
        self._key = key
        self._salt = salt

    def lock(self):
        with self._guard:
            self._install_key(None, None)

    def create(self, password):
        with self._transaction(exclusive=True) as fd:
            if self._exists(fd):
                raise VaultError("A vault already exists", 409)
            salt = os.urandom(SALT_LENGTH)
            key = _derive(password, salt, creating=True)
            try:
                _write(fd, FILENAME, _encrypt({"items": {}}, key, salt))
            except BaseException:
                _erase(key)
                raise
            self._install_key(key, salt)

    def unlock(self, password):
        with self._transaction() as fd:
            self.lock()
            data = _read(fd, FILENAME)
            salt = _salt(data)
            key = _derive(password, salt)
            try:
                _decrypt(data, key)
            except BaseException:
                _erase(key)
                raise
            self._install_key(key, salt)

    def _payload(self, fd):
        if self._key is None:
            raise VaultError("Vault is locked", 423)
        data = _read(fd, FILENAME)
        if self._salt != _salt(data):
            self.lock()
            raise VaultError("Vault has been replaced; unlock again", 423)
        return _decrypt(data, self._key)

    def intake_private_key(self):
        """Return this vault's device-intake key only to the trusted owner bridge."""
        with self._transaction(exclusive=True) as fd:
            payload = self._payload(fd)
            if "intake_key" in payload:
                try:
                    scalar = bytes.fromhex(payload["intake_key"])
                    if len(scalar) != 32:
                        raise ValueError()
                    ec.derive_private_key(int.from_bytes(scalar, "big"), ec.SECP256R1())
                except (TypeError, ValueError):
                    raise VaultError("Invalid device pairing key") from None
                return scalar
            key = ec.generate_private_key(ec.SECP256R1())
            scalar = key.private_numbers().private_value.to_bytes(32, "big")
            payload["intake_key"] = scalar.hex()
            _write(fd, FILENAME, _encrypt(payload, self._key, self._salt))
            return scalar

    def list_items(self):
        with self._transaction() as fd:
            return [_summary(item) for item in self._payload(fd)["items"].values()]

    def get_item(self, id):
        with self._transaction() as fd:
            item = self._payload(fd)["items"].get(id)
            if item is None:
                raise VaultError("Item not found", 404)
            return item

    @staticmethod
    def _current(items, id, expected):
        if not isinstance(id, str) or id not in items:
            raise VaultError("Item not found", 404)
        item = items[id]
        if type(expected) is not int or item["revision"] != expected:
            raise VaultError("Item has changed; refresh and try again", 409)
        return item

    def save_item(self, item, expected=None):
        with self._transaction(exclusive=True) as fd:
            payload = self._payload(fd)
            items = payload["items"]
            clean = _validate_item(item)
            if "id" in item or expected is not None:
                current = self._current(items, item.get("id"), expected)
                if clean["kind"] != current["kind"]:
                    raise VaultError("Cannot change item kind")
                clean.update(id=current["id"], revision=expected + 1)
            else:
                if len(items) >= MAX_ITEMS:
                    raise VaultError("Vault item limit reached", 413)
                clean.update(id=uuid.uuid4().hex, revision=1)
            items[clean["id"]] = clean
            _write(fd, FILENAME, _encrypt(payload, self._key, self._salt))
            return _summary(clean)

    def import_item(self, item, source_id):
        """Import one authenticated intake message at most once across restarts."""
        if not isinstance(source_id, str) or not re.fullmatch(
            r"[0-9a-f]{64}", source_id
        ):
            raise VaultError("Expected a lowercase SHA-256 digest for the import ID")
        with self._transaction(exclusive=True) as fd:
            payload = self._payload(fd)
            items = payload["items"]
            imports = payload.setdefault("imports", {})
            if source_id in imports:
                existing = items.get(imports[source_id])
                if existing is None:
                    raise VaultError("This imported item was removed", 410)
                return _summary(existing)
            clean = _validate_item(item)
            if "id" in item or "revision" in item:
                raise VaultError("An imported item cannot supply its own identity")
            if len(items) >= MAX_ITEMS:
                raise VaultError("Vault item limit reached", 413)
            clean.update(id=uuid.uuid4().hex, revision=1)
            items[clean["id"]] = clean
            imports[source_id] = clean["id"]
            _write(fd, FILENAME, _encrypt(payload, self._key, self._salt))
            return _summary(clean)

    def delete_item(self, id, expected):
        with self._transaction(exclusive=True) as fd:
            payload = self._payload(fd)
            items = payload["items"]
            self._current(items, id, expected)
            del items[id]
            _write(fd, FILENAME, _encrypt(payload, self._key, self._salt))

    def backup(self, folder):
        with self._transaction() as fd:
            data = _read(fd, FILENAME)
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime(
                "%Y%m%dT%H%M%SZ"
            )
            filename = f"{stamp}-{uuid.uuid4().hex}.cvault"
            out = _directory(folder, create=True)
            try:
                _write(out, filename, data)
            finally:
                os.close(out)
            return filename

    def restore(self, snapshot, password):
        snapshot = Path(snapshot)
        with self._transaction(exclusive=True) as fd:
            if self._exists(fd):
                raise VaultError("Restore requires an empty vault directory", 409)
            source = _directory(snapshot.parent)
            try:
                data = _read(source, snapshot.name)
            finally:
                os.close(source)
            salt = _salt(data)
            key = _derive(password, salt)
            try:
                _decrypt(data, key)
                _write(fd, FILENAME, data)
            except BaseException:
                _erase(key)
                raise
            self._install_key(key, salt)
