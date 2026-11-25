"""Isolated encrypted SQLite store, encrypted document attachments, autofill engine & receipts."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import sqlite3
import subprocess
from collections import defaultdict
from collections.abc import Sequence
from contextlib import contextmanager, suppress
from pathlib import Path
from typing import Any, Literal

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from context_hub.models import RawEventIn, new_ulid, now_ms
from context_hub.store import HubStore

from .crypto import (
    NONCE_LEN,
    VaultAuthError,
    decrypt_payload,
    derive_master_key,
    encrypt_payload,
    generate_salt,
    make_verifier,
    verify_key,
)
from .entities import merge_autofill_bundle

VaultRecordKind = Literal[
    "person_profile",
    "company_entity",
    "identity_doc",
    "business_license",
    "api_key",
    "credential",
    "address",
    "payment_card",
    "note",
]

_VAULT_SCHEMA = """
CREATE TABLE IF NOT EXISTS vault_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS vault_records (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    subject_id TEXT NOT NULL DEFAULT 'self',
    label TEXT NOT NULL,
    project TEXT,
    tags_json TEXT NOT NULL DEFAULT '[]',
    allowed_commands_json TEXT NOT NULL DEFAULT '[]',
    allowed_hosts_json TEXT NOT NULL DEFAULT '[]',
    nonce_b64 TEXT NOT NULL,
    ciphertext_b64 TEXT NOT NULL,
    version INTEGER NOT NULL DEFAULT 1,
    deleted INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_vault_subject ON vault_records(subject_id, deleted, updated_at DESC);

CREATE TABLE IF NOT EXISTS vault_attachments (
    id TEXT PRIMARY KEY,
    record_id TEXT NOT NULL REFERENCES vault_records(id) ON DELETE CASCADE,
    filename TEXT NOT NULL,
    mime_type TEXT NOT NULL DEFAULT 'application/octet-stream',
    byte_size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    nonce_b64 TEXT NOT NULL,
    blob_relpath TEXT NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_vault_att_rec ON vault_attachments(record_id, deleted);

CREATE TABLE IF NOT EXISTS vault_audit (
    id TEXT PRIMARY KEY,
    record_id TEXT,
    action TEXT NOT NULL,
    actor TEXT NOT NULL,
    detail TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL
);
"""


def default_vault_dir(data_dir: Path | None = None) -> Path:
    root = Path(data_dir) if data_dir else (Path.home() / ".local" / "share" / "context-hub-v2")
    return root.expanduser() / "vault"


def redact_secrets(text: str, secrets_values: Sequence[str]) -> str:
    """Replace any literal occurrence of injected secret values in output streams."""
    out = text
    for val in sorted({v for v in secrets_values if v and len(v) >= 4}, key=len, reverse=True):
        out = out.replace(val, "***VAULT_REDACTED***")
    return out


class VaultStore:
    """Per-record AES-256-GCM encrypted personal & company identity/document/secret vault."""

    def __init__(self, vault_dir: Path | None = None):
        self.vault_dir = Path(vault_dir or default_vault_dir()).expanduser()
        self.vault_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.blobs_dir = self.vault_dir / "blobs"
        self.blobs_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db_path = self.vault_dir / "vault.sqlite3"
        conn = sqlite3.connect(str(self.db_path), timeout=15, isolation_level=None)
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=FULL")
            conn.execute("PRAGMA foreign_keys=ON")
            conn.executescript(_VAULT_SCHEMA)
            self._migrate(conn)
        finally:
            conn.close()
        with suppress(OSError):
            self.db_path.chmod(0o600)

    @staticmethod
    def _migrate(conn: sqlite3.Connection) -> None:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(vault_records)").fetchall()}
        if "subject_id" not in cols:
            conn.execute("ALTER TABLE vault_records ADD COLUMN subject_id TEXT NOT NULL DEFAULT 'self'")

    @contextmanager
    def _tx(self, write: bool = False):
        conn = sqlite3.connect(str(self.db_path), timeout=15, isolation_level=None)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute("PRAGMA foreign_keys=ON")
            conn.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            yield conn
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
        finally:
            conn.close()

    def is_initialized(self) -> bool:
        with self._tx(False) as conn:
            row = conn.execute("SELECT value FROM vault_meta WHERE key='salt_b64'").fetchone()
            return row is not None

    def init_vault(self, passphrase: str) -> dict[str, Any]:
        if self.is_initialized():
            raise ValueError("Vault is already initialized")
        salt = generate_salt()
        key = derive_master_key(passphrase, salt)
        verifier = make_verifier(key)
        now = now_ms()
        with self._tx(True) as conn:
            conn.execute(
                "INSERT INTO vault_meta(key, value) VALUES ('salt_b64', ?)",
                (base64.b64encode(salt).decode("ascii"),),
            )
            conn.execute(
                "INSERT INTO vault_meta(key, value) VALUES ('verifier_b64', ?)",
                (verifier,),
            )
            conn.execute(
                "INSERT INTO vault_meta(key, value) VALUES ('created_at', ?)",
                (str(now),),
            )
            self._audit(conn, None, "init", "owner", "Initialized AES-256-GCM vault", now)
        return {"initialized": True, "vault_path": str(self.db_path)}

    def unlock_key(self, passphrase: str) -> bytes:
        with self._tx(False) as conn:
            salt_row = conn.execute("SELECT value FROM vault_meta WHERE key='salt_b64'").fetchone()
            ver_row = conn.execute(
                "SELECT value FROM vault_meta WHERE key='verifier_b64'"
            ).fetchone()
        if salt_row is None or ver_row is None:
            raise VaultAuthError("Vault is not initialized. Run `raw-vault init` first.")
        salt = base64.b64decode(salt_row["value"].encode("ascii"))
        key = derive_master_key(passphrase, salt)
        verify_key(key, ver_row["value"])
        return key

    @staticmethod
    def _audit(
        conn: sqlite3.Connection,
        record_id: str | None,
        action: str,
        actor: str,
        detail: str,
        ts: int,
    ) -> None:
        conn.execute(
            """INSERT INTO vault_audit(id, record_id, action, actor, detail, created_at)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (new_ulid("va_"), record_id, action, actor, detail[:500], ts),
        )

    @staticmethod
    def _att_dict(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "record_id": row["record_id"],
            "filename": row["filename"],
            "mime_type": row["mime_type"],
            "byte_size": row["byte_size"],
            "sha256": row["sha256"],
            "created_at": row["created_at"],
        }

    def _meta_dict(self, conn: sqlite3.Connection, row: sqlite3.Row) -> dict[str, Any]:
        atts = [
            self._att_dict(a)
            for a in conn.execute(
                "SELECT * FROM vault_attachments WHERE record_id=? AND deleted=0 ORDER BY created_at ASC",
                (row["id"],),
            ).fetchall()
        ]
        return {
            "id": row["id"],
            "kind": row["kind"],
            "subject_id": row["subject_id"] or "self",
            "label": row["label"],
            "project": row["project"],
            "tags": json.loads(row["tags_json"] or "[]"),
            "allowed_commands": json.loads(row["allowed_commands_json"] or "[]"),
            "allowed_hosts": json.loads(row["allowed_hosts_json"] or "[]"),
            "attachments": atts,
            "version": row["version"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def put_record(
        self,
        passphrase: str,
        *,
        kind: VaultRecordKind,
        label: str,
        secret_payload: dict[str, Any],
        subject_id: str = "self",
        record_id: str | None = None,
        project: str | None = None,
        tags: list[str] | None = None,
        allowed_commands: list[str] | None = None,
        allowed_hosts: list[str] | None = None,
    ) -> dict[str, Any]:
        """Encrypt and store (or update) a secret/entity/document record; returns metadata only."""
        key = self.unlock_key(passphrase)
        now = now_ms()
        rid = record_id or new_ulid("vault_")
        subj = (subject_id or "self").strip()

        with self._tx(True) as conn:
            existing = conn.execute(
                "SELECT version FROM vault_records WHERE id=? AND deleted=0", (rid,)
            ).fetchone()
            version = (int(existing["version"]) + 1) if existing else 1
            aad = f"{rid}:{kind}:v{version}"
            nonce, ct = encrypt_payload(key, secret_payload, aad=aad)
            nonce_b64 = base64.b64encode(nonce).decode("ascii")
            ct_b64 = base64.b64encode(ct).decode("ascii")
            if existing:
                conn.execute(
                    """UPDATE vault_records
                       SET kind=?, subject_id=?, label=?, project=?, tags_json=?,
                           allowed_commands_json=?, allowed_hosts_json=?, nonce_b64=?,
                           ciphertext_b64=?, version=?, updated_at=?
                       WHERE id=?""",
                    (
                        kind,
                        subj,
                        label.strip(),
                        project,
                        json.dumps(tags or [], ensure_ascii=False),
                        json.dumps(allowed_commands or [], ensure_ascii=False),
                        json.dumps(allowed_hosts or [], ensure_ascii=False),
                        nonce_b64,
                        ct_b64,
                        version,
                        now,
                        rid,
                    ),
                )
            else:
                conn.execute(
                    """INSERT INTO vault_records
                       (id, kind, subject_id, label, project, tags_json, allowed_commands_json,
                        allowed_hosts_json, nonce_b64, ciphertext_b64, version, deleted,
                        created_at, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)""",
                    (
                        rid,
                        kind,
                        subj,
                        label.strip(),
                        project,
                        json.dumps(tags or [], ensure_ascii=False),
                        json.dumps(allowed_commands or [], ensure_ascii=False),
                        json.dumps(allowed_hosts or [], ensure_ascii=False),
                        nonce_b64,
                        ct_b64,
                        version,
                        now,
                        now,
                    ),
                )
            self._audit(
                conn, rid, "set", "owner", f"Saved {kind} [{subj}] ({label.strip()}) v{version}", now
            )
            row = conn.execute("SELECT * FROM vault_records WHERE id=?", (rid,)).fetchone()
            return self._meta_dict(conn, row)

    def list_records(
        self,
        *,
        subject_id: str | None = None,
        project: str | None = None,
        kind: str | None = None,
    ) -> list[dict[str, Any]]:
        """List non-secret metadata only (works without unlocking passphrase)."""
        where = ["deleted = 0"]
        params: list[Any] = []
        if subject_id:
            where.append("subject_id = ?")
            params.append(subject_id)
        if project:
            where.append("project = ?")
            params.append(project)
        if kind:
            where.append("kind = ?")
            params.append(kind)
        with self._tx(False) as conn:
            rows = conn.execute(
                f"SELECT * FROM vault_records WHERE {' AND '.join(where)} ORDER BY updated_at DESC",
                params,
            ).fetchall()
            return [self._meta_dict(conn, r) for r in rows]

    def list_subjects(self) -> list[dict[str, Any]]:
        """Summarize subjects (`self`, `partner:*`, `company:*`) without decrypting PII."""
        records = self.list_records()
        grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for r in records:
            grouped[r["subject_id"]].append(r)
        out: list[dict[str, Any]] = []
        for sid, items in sorted(grouped.items()):
            kinds = sorted({i["kind"] for i in items})
            att_count = sum(len(i["attachments"]) for i in items)
            out.append(
                {
                    "subject_id": sid,
                    "record_count": len(items),
                    "attachment_count": att_count,
                    "kinds": kinds,
                    "labels": [i["label"] for i in items],
                    "updated_at": max(i["updated_at"] for i in items),
                }
            )
        return out

    def get_record(
        self,
        passphrase: str,
        record_id: str,
        *,
        actor: str = "owner",
    ) -> dict[str, Any]:
        """Decrypt and return a single secret/entity/document record with audit logging."""
        key = self.unlock_key(passphrase)
        now = now_ms()
        with self._tx(True) as conn:
            row = conn.execute(
                "SELECT * FROM vault_records WHERE id=? AND deleted=0", (record_id,)
            ).fetchone()
            if row is None:
                raise KeyError(f"Vault record not found: {record_id}")
            aad = f"{row['id']}:{row['kind']}:v{row['version']}"
            payload = decrypt_payload(
                key,
                base64.b64decode(row["nonce_b64"].encode("ascii")),
                base64.b64decode(row["ciphertext_b64"].encode("ascii")),
                aad=aad,
            )
            self._audit(conn, record_id, "get", actor, f"Decrypted {row['label']}", now)
            return {**self._meta_dict(conn, row), "secret": payload}

    def delete_record(self, record_id: str, *, actor: str = "owner") -> dict[str, Any]:
        now = now_ms()
        with self._tx(True) as conn:
            row = conn.execute(
                "SELECT id, label FROM vault_records WHERE id=? AND deleted=0", (record_id,)
            ).fetchone()
            if row is None:
                raise KeyError(f"Vault record not found: {record_id}")
            atts = conn.execute(
                "SELECT id, blob_relpath FROM vault_attachments WHERE record_id=? AND deleted=0",
                (record_id,),
            ).fetchall()
            for a in atts:
                blob = self.vault_dir / a["blob_relpath"]
                with suppress(OSError):
                    blob.unlink(missing_ok=True)
            conn.execute(
                "UPDATE vault_attachments SET deleted=1 WHERE record_id=?", (record_id,)
            )
            conn.execute(
                "UPDATE vault_records SET deleted=1, ciphertext_b64='', nonce_b64='', updated_at=? WHERE id=?",
                (now, record_id),
            )
            self._audit(conn, record_id, "delete", actor, f"Deleted {row['label']}", now)
        return {"id": record_id, "deleted": True}

    # ------------------------------------------------------------------
    # Encrypted Binary Document Attachments (营业执照 / 身份证 / 护照扫描件)
    # ------------------------------------------------------------------
    def add_attachment(
        self,
        passphrase: str,
        *,
        record_id: str,
        filename: str,
        data: bytes,
        mime_type: str = "application/octet-stream",
    ) -> dict[str, Any]:
        """Encrypt and attach a binary scan/PDF/photo to a vault record."""
        key = self.unlock_key(passphrase)
        now = now_ms()
        att_id = new_ulid("vatt_")
        safe_name = Path(filename).name[:180] or "attachment.bin"
        nonce = os.urandom(NONCE_LEN)
        aad = f"{att_id}:{record_id}:{safe_name}".encode()
        ciphertext = AESGCM(key).encrypt(nonce, data, aad)
        sha256 = hashlib.sha256(data).hexdigest()
        relpath = f"blobs/{att_id}.enc"
        blob_path = self.vault_dir / relpath
        blob_path.write_bytes(ciphertext)
        with suppress(OSError):
            blob_path.chmod(0o600)

        with self._tx(True) as conn:
            rec = conn.execute(
                "SELECT id FROM vault_records WHERE id=? AND deleted=0", (record_id,)
            ).fetchone()
            if rec is None:
                blob_path.unlink(missing_ok=True)
                raise KeyError(f"Vault record not found: {record_id}")
            conn.execute(
                """INSERT INTO vault_attachments
                   (id, record_id, filename, mime_type, byte_size, sha256, nonce_b64,
                    blob_relpath, deleted, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)""",
                (
                    att_id,
                    record_id,
                    safe_name,
                    mime_type,
                    len(data),
                    sha256,
                    base64.b64encode(nonce).decode("ascii"),
                    relpath,
                    now,
                ),
            )
            self._audit(
                conn,
                record_id,
                "attach",
                "owner",
                f"Attached encrypted file {safe_name} ({len(data)} bytes)",
                now,
            )
            row = conn.execute("SELECT * FROM vault_attachments WHERE id=?", (att_id,)).fetchone()
            return self._att_dict(row)

    def get_attachment_bytes(
        self,
        passphrase: str,
        attachment_id: str,
        *,
        actor: str = "owner",
    ) -> tuple[dict[str, Any], bytes]:
        """Decrypt and return `(metadata, raw_bytes)` for a vault attachment."""
        key = self.unlock_key(passphrase)
        now = now_ms()
        with self._tx(True) as conn:
            row = conn.execute(
                "SELECT * FROM vault_attachments WHERE id=? AND deleted=0", (attachment_id,)
            ).fetchone()
            if row is None:
                raise KeyError(f"Vault attachment not found: {attachment_id}")
            blob_path = self.vault_dir / row["blob_relpath"]
            ciphertext = blob_path.read_bytes()
            nonce = base64.b64decode(row["nonce_b64"].encode("ascii"))
            aad = f"{row['id']}:{row['record_id']}:{row['filename']}".encode()
            try:
                raw = AESGCM(key).decrypt(nonce, ciphertext, aad)
            except InvalidTag as exc:
                raise VaultAuthError("Attachment authentication failed") from exc
            self._audit(
                conn,
                row["record_id"],
                "download_att",
                actor,
                f"Decrypted attachment {row['filename']}",
                now,
            )
            return self._att_dict(row), raw

    # ------------------------------------------------------------------
    # Unified Form-Fill Bundle (Base Profile + Extracted Document Fields)
    # ------------------------------------------------------------------
    def build_autofill_bundle(
        self,
        passphrase: str,
        subject_id: str = "self",
        *,
        masked: bool = False,
        actor: str = "owner",
    ) -> dict[str, Any]:
        """Decrypt all records for `subject_id` and synthesize a unified Form-Fill bundle."""
        key = self.unlock_key(passphrase)
        now = now_ms()
        decrypted: list[dict[str, Any]] = []
        with self._tx(True) as conn:
            rows = conn.execute(
                "SELECT * FROM vault_records WHERE subject_id=? AND deleted=0 ORDER BY updated_at ASC",
                (subject_id,),
            ).fetchall()
            for row in rows:
                aad = f"{row['id']}:{row['kind']}:v{row['version']}"
                payload = decrypt_payload(
                    key,
                    base64.b64decode(row["nonce_b64"].encode("ascii")),
                    base64.b64decode(row["ciphertext_b64"].encode("ascii")),
                    aad=aad,
                )
                decrypted.append({**self._meta_dict(conn, row), "secret": payload})
            self._audit(
                conn,
                None,
                "autofill_read",
                actor,
                f"Built autofill bundle for {subject_id} (masked={masked}, records={len(decrypted)})",
                now,
            )
        return merge_autofill_bundle(subject_id, decrypted, masked=masked)

    def list_audit_log(self, *, limit: int = 50) -> list[dict[str, Any]]:
        with self._tx(False) as conn:
            rows = conn.execute(
                "SELECT * FROM vault_audit ORDER BY created_at DESC LIMIT ?", (limit,)
            ).fetchall()
            return [dict(r) for r in rows]

    def run_with_injected_secrets(
        self,
        passphrase: str,
        *,
        env_bindings: dict[str, str],
        command: Sequence[str],
        actor: str = "agent",
    ) -> dict[str, Any]:
        """Inject decrypted vault secrets into a subprocess env and redact any echo from output."""
        if not command:
            raise ValueError("Command must not be empty")
        cmd_bin = Path(command[0]).name
        key = self.unlock_key(passphrase)
        now = now_ms()
        injected: dict[str, str] = {}
        secret_values: list[str] = []

        with self._tx(True) as conn:
            for env_name, spec in env_bindings.items():
                rid, field = (spec.split(":", 1) if ":" in spec else (spec, "value"))
                row = conn.execute(
                    "SELECT * FROM vault_records WHERE id=? AND deleted=0", (rid,)
                ).fetchone()
                if row is None:
                    raise KeyError(f"Vault record not found: {rid}")
                allowed_cmds = json.loads(row["allowed_commands_json"] or "[]")
                if allowed_cmds and cmd_bin not in allowed_cmds and command[0] not in allowed_cmds:
                    self._audit(
                        conn,
                        rid,
                        "run_denied",
                        actor,
                        f"Denied command `{cmd_bin}` (allowed={allowed_cmds})",
                        now,
                    )
                    raise PermissionError(
                        f"Command '{cmd_bin}' is not allowlisted for vault record {rid} ({allowed_cmds})"
                    )
                aad = f"{row['id']}:{row['kind']}:v{row['version']}"
                payload = decrypt_payload(
                    key,
                    base64.b64decode(row["nonce_b64"].encode("ascii")),
                    base64.b64decode(row["ciphertext_b64"].encode("ascii")),
                    aad=aad,
                )
                if field not in payload:
                    raise KeyError(f"Field '{field}' not present in vault record {rid}")
                val = str(payload[field])
                injected[env_name] = val
                secret_values.append(val)
                self._audit(
                    conn,
                    rid,
                    "run_inject",
                    actor,
                    f"Injected {env_name} into `{cmd_bin}`",
                    now,
                )

        child_env = {**os.environ, **injected}
        proc = subprocess.run(
            list(command),
            env=child_env,
            capture_output=True,
            text=True,
            check=False,
        )
        return {
            "returncode": proc.returncode,
            "stdout": redact_secrets(proc.stdout, secret_values),
            "stderr": redact_secrets(proc.stderr, secret_values),
            "injected_env_vars": sorted(injected.keys()),
        }

    def sync_masked_receipts_to_hub(self, hub_store: HubStore) -> dict[str, int]:
        """Sync non-secret structural pointer receipts into Raw Memory (zero plaintext PII/secrets)."""
        records = self.list_records()
        events: list[RawEventIn] = []
        for rec in records:
            rid = rec["id"]
            label = rec["label"]
            kind = rec["kind"]
            subj = rec["subject_id"]
            att_names = [a["filename"] for a in rec["attachments"]]
            if kind in {"person_profile", "company_entity", "identity_doc", "business_license"}:
                body = (
                    f"Encrypted {kind} `{rid}` for subject `{subj}` ({label}) is stored in Vault for Agent"
                    + (f" with encrypted attachments: {', '.join(att_names)}." if att_names else ".")
                    + " Plaintext PII/documents never enter Raw Memory; request owner unlock in Vault for authorized form-fill."
                )
            else:
                body = (
                    f"Encrypted record `{rid}` ({kind}: {label}, subject={subj}) is stored in Vault for Agent. "
                    f"Plaintext never enters Raw Memory. Use `raw-vault run --secret SECRET_VAR={rid} -- <cmd>` for authorized execution."
                )
            events.append(
                RawEventIn(
                    source="vault",
                    kind="vault_receipt",
                    t_start=int(rec["updated_at"]),
                    t_end=int(rec["updated_at"]),
                    actor="self",
                    project=rec.get("project"),
                    content={
                        "title": f"Vault Pointer [{subj}]: {label} ({kind})",
                        "text": body,
                    },
                    context={
                        "vault_record_id": rid,
                        "vault_kind": kind,
                        "subject_id": subj,
                        "attachment_count": len(att_names),
                        "allowed_commands": rec["allowed_commands"],
                        "allowed_hosts": rec["allowed_hosts"],
                        "tags": rec["tags"],
                    },
                    provenance={
                        "connector": "vault-for-agent",
                        "source_id": f"receipt:{rid}:v{rec['version']}:a{len(att_names)}",
                        "locator": f"vault://{subj}/{rid}",
                    },
                    privacy={"tier": "redacted", "pii_tags": []},
                )
            )
        if not events:
            return {"synced": 0, "created": 0, "existing": 0}
        res = hub_store.ingest_batch(events, write_l0=True)
        return {
            "synced": len(events),
            "created": int(res.get("created", 0)),
            "existing": int(res.get("existing", 0)),
        }
