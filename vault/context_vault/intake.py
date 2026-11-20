"""RFC 9180 one-way document intake. Files and labels are encrypted before transport."""

import base64
import binascii
import hashlib
import json
import os
import re
import stat
import tempfile
import uuid
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from pyhpke import AEADId, CipherSuite, KDFId, KEMId

from .storage import VaultError

INFO = b"context-vault/inbox/v1"
SUITE = CipherSuite.new(
    KEMId.DHKEM_P256_HKDF_SHA256, KDFId.HKDF_SHA256, AEADId.AES256_GCM
)
MAX_DROP = 16 * 1024 * 1024


def _encode(data):
    return base64.b64encode(data).decode("ascii")


def _decode(value):
    if not isinstance(value, str) or len(value) > MAX_DROP:
        raise ValueError("Invalid package")
    return base64.b64decode(value, validate=True)


def _publish(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
        tmp = Path(out.name)
        try:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise
    try:
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def pairing(store, directory):
    scalar = store.intake_private_key()
    key = ec.derive_private_key(
        int.from_bytes(scalar, "big"), ec.SECP256R1()
    ).public_key()
    point = key.public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )
    value = "CV1." + _encode(point)
    _publish(Path(directory) / "recipient.pub", value.encode("ascii"))
    return {"pairing": value, "fingerprint": hashlib.sha256(point).hexdigest()[:16]}


def seal_item(public, item):
    if not public.startswith("CV1."):
        raise VaultError("Invalid intake pairing")
    key = SUITE.kem.deserialize_public_key(_decode(public[4:]))
    enc, ctx = SUITE.create_sender_context(key, INFO)
    clear = json.dumps(item, ensure_ascii=False, separators=(",", ":")).encode()
    if len(clear) > 12 * 1024 * 1024:
        raise VaultError("Item exceeds intake limit")
    return {"v": 1, "enc": _encode(enc), "ct": _encode(ctx.seal(clear))}


def stage_item(directory, item):
    directory = Path(directory)
    path = directory / "recipient.pub"
    if not path.is_file() or path.is_symlink():
        raise VaultError("Open the unlocked Vault and pair the intake key first.")
    drop = seal_item(path.read_text(encoding="ascii").strip(), item)
    inbox = directory / "inbox"
    if inbox.is_symlink():
        raise VaultError("Invalid inbox directory")
    inbox.mkdir(mode=0o700, exist_ok=True)
    identifier = uuid.uuid4().hex
    _publish(inbox / (identifier + ".cvdrop"), json.dumps(drop).encode("ascii"))
    return identifier


def open_drop(store, package):
    scalar = store.intake_private_key()
    try:
        if (
            not isinstance(package, dict)
            or type(package.get("v")) is not int
            or package["v"] != 1
        ):
            raise ValueError()
        enc, ct = _decode(package["enc"]), _decode(package["ct"])
        if len(enc) != 65 or len(ct) < 16:
            raise ValueError()
        ctx = SUITE.create_recipient_context(
            enc, SUITE.kem.deserialize_private_key(scalar), INFO
        )
        item = json.loads(ctx.open(ct))
        if (
            not isinstance(item, dict)
            or item.get("kind") not in {"document", "ssh", "profile"}
            or not isinstance(item.get("label"), str)
            or not isinstance(item.get("value"), str)
        ):
            raise ValueError()
        # Intake senders can submit documents but cannot prescribe a disclosure destination.
        return {
            key: item[key] for key in ("kind", "label", "value", "mime") if key in item
        }
    except Exception:
        raise VaultError(
            "Cannot read package. Check pairing, format and size."
        ) from None


def import_drop(store, package):
    item = open_drop(store, package)
    data = item["value"].encode()
    if item["kind"] == "document":
        try:
            data = base64.b64decode(data, validate=True)
        except (ValueError, binascii.Error):
            raise VaultError("Invalid document encoding") from None
    identity = hashlib.sha256(item["kind"].encode() + b"\0" + data).hexdigest()
    return store.import_item(item, identity)


def inbox_path(directory, identifier):
    if not re.fullmatch("[0-9a-f]{32}", identifier):
        raise VaultError("Unknown inbox item", 404)
    folder = Path(directory) / "inbox"
    path = folder / (identifier + ".cvdrop")
    if folder.is_symlink() or path.is_symlink() or not path.is_file():
        raise VaultError("Unknown inbox item", 404)
    return path


def read_package_bytes(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as file:
        info = os.fstat(file.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_DROP:
            raise VaultError("Invalid or oversized intake package")
        data = file.read(MAX_DROP + 1)
    if len(data) > MAX_DROP:
        raise VaultError("Oversized intake package")
    return data


def parse_package(data):
    try:
        return json.loads(data)
    except (ValueError, UnicodeError):
        raise VaultError("Invalid intake package") from None


def load_package(path):
    return parse_package(read_package_bytes(path))


def pending(store, directory):
    folder = Path(directory) / "inbox"
    if not folder.is_dir() or folder.is_symlink():
        return []
    rows = []
    for path in sorted(folder.glob("*.cvdrop"))[:100]:
        if not re.fullmatch("[0-9a-f]{32}", path.stem):
            continue
        try:
            item = open_drop(store, load_package(path))
            rows.append(
                {"id": path.stem, "kind": item["kind"], "label": item["label"][:160]}
            )
        except (VaultError, OSError):
            rows.append({"id": path.stem, "kind": "invalid", "label": "无法解密的收件"})
    return rows
