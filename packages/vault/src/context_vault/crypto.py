"""Per-record AES-256-GCM authenticated encryption & Scrypt KDF for Vault for Agent."""

from __future__ import annotations

import base64
import hashlib
import json
import os
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

SCRYPT_N = 2**14
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_MAXMEM = 64 * 1024 * 1024
KEY_LEN = 32
NONCE_LEN = 12
SALT_LEN = 16


class VaultAuthError(ValueError):
    """Raised when a vault passphrase is invalid or ciphertext authentication fails."""


def generate_salt() -> bytes:
    return os.urandom(SALT_LEN)


def derive_master_key(passphrase: str, salt: bytes) -> bytes:
    if not passphrase:
        raise VaultAuthError("Vault passphrase must not be empty")
    return hashlib.scrypt(
        passphrase.encode("utf-8"),
        salt=salt,
        n=SCRYPT_N,
        r=SCRYPT_R,
        p=SCRYPT_P,
        maxmem=SCRYPT_MAXMEM,
        dklen=KEY_LEN,
    )


def encrypt_payload(key: bytes, payload: dict[str, Any], *, aad: str) -> tuple[bytes, bytes]:
    """Encrypt a JSON-serializable secret payload with fresh 96-bit nonce and AAD."""
    nonce = os.urandom(NONCE_LEN)
    plaintext = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ct = AESGCM(key).encrypt(nonce, plaintext, aad.encode("utf-8"))
    return nonce, ct


def decrypt_payload(key: bytes, nonce: bytes, ciphertext: bytes, *, aad: str) -> dict[str, Any]:
    """Authenticate and decrypt a secret payload; raises VaultAuthError on mismatch."""
    try:
        pt = AESGCM(key).decrypt(nonce, ciphertext, aad.encode("utf-8"))
    except InvalidTag as exc:
        raise VaultAuthError("Invalid vault passphrase or tampered ciphertext") from exc
    data = json.loads(pt.decode("utf-8"))
    if not isinstance(data, dict):
        raise VaultAuthError("Corrupted vault payload")
    return data


def make_verifier(key: bytes) -> str:
    nonce, ct = encrypt_payload(key, {"ok": True, "v": 1}, aad="vault:verifier:v1")
    return base64.b64encode(nonce + ct).decode("ascii")


def verify_key(key: bytes, verifier_b64: str) -> None:
    raw = base64.b64decode(verifier_b64.encode("ascii"))
    if len(raw) <= NONCE_LEN:
        raise VaultAuthError("Corrupted vault verifier")
    nonce, ct = raw[:NONCE_LEN], raw[NONCE_LEN:]
    data = decrypt_payload(key, nonce, ct, aad="vault:verifier:v1")
    if data.get("ok") is not True:
        raise VaultAuthError("Vault key verification failed")
