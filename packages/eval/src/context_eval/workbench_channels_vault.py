"""FastAPI routers for Channel Control (Browser / IM / Focus / Registry) and Encrypted Vault Studio."""

from __future__ import annotations

import base64
import json
import re
import sqlite3
from pathlib import Path
from typing import Any
from urllib.parse import quote

from fastapi import APIRouter, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel, Field

from context_collectors.browser import BrowserHistoryCollector
from context_collectors.chat import (
    ChatInboxCollector,
    default_chat_inbox_dir,
    load_chat_allowlist,
    save_chat_allowlist,
)
from context_collectors.clipcontext import ClipContextCollector
from context_collectors.lark_im import LarkIMCollector
from context_collectors.registry import list_channel_specs
from context_collectors.runtime import DirectHubSink, HubCheckpointStore, run_collector
from context_collectors.window import WindowFocusCollector
from context_hub.store import HubStore
from context_vault import VaultAuthError, VaultStore, default_vault_dir


class SyncChannelIn(BaseModel):
    collector: str
    since_days: float = 14.0


class ChatUploadIn(BaseModel):
    filename: str = Field(..., min_length=1, max_length=180)
    content: str = Field(..., min_length=1)


class ChatAllowlistUpdateIn(BaseModel):
    session_id: str
    allow: bool
    project: str | None = None
    tier: str = "shareable"


class VaultPassphraseIn(BaseModel):
    passphrase: str = Field(..., min_length=1, max_length=256)


class VaultRecordIn(BaseModel):
    kind: str
    subject_id: str = "self"
    label: str = Field(..., min_length=1, max_length=200)
    record_id: str | None = None
    project: str | None = None
    tags: list[str] = Field(default_factory=list)
    allowed_commands: list[str] = Field(default_factory=list)
    payload: dict[str, Any] = Field(default_factory=dict)


class VaultAttachmentIn(BaseModel):
    filename: str = Field(..., min_length=1, max_length=180)
    mime_type: str = "application/octet-stream"
    content_b64: str = Field(..., min_length=1)


def _inventory_by_source(db_path: Path) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    if not db_path.is_file():
        return out
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            """SELECT source,
                      COUNT(*) AS total,
                      SUM(CASE WHEN privacy_tier != 'local_only' THEN 1 ELSE 0 END) AS shareable,
                      SUM(CASE WHEN privacy_tier = 'local_only' THEN 1 ELSE 0 END) AS local_only,
                      MAX(t_start) AS last_t_start
               FROM raw_events WHERE deleted = 0
               GROUP BY source"""
        ).fetchall()
        for r in rows:
            out[str(r["source"])] = {
                "total": int(r["total"]),
                "shareable": int(r["shareable"] or 0),
                "local_only": int(r["local_only"] or 0),
                "last_t_start": int(r["last_t_start"] or 0),
            }
    finally:
        conn.close()
    return out


def _list_im_sessions(db_path: Path) -> list[dict[str, Any]]:
    if not db_path.is_file():
        return []
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    sessions: dict[str, dict[str, Any]] = {}
    try:
        rows = conn.execute(
            """SELECT source, project, privacy_tier, t_start, event_json
               FROM raw_events
               WHERE deleted = 0 AND (source = 'wechat' OR source LIKE 'im.%')
               ORDER BY t_start DESC LIMIT 2000"""
        ).fetchall()
        for r in rows:
            ctx = (json.loads(r["event_json"] or "{}")).get("context") or {}
            sid = str(ctx.get("session_id") or "")
            if not sid:
                continue
            sname = str(ctx.get("session_name") or sid)
            cur = sessions.get(sid)
            if cur is None:
                sessions[sid] = {
                    "session_id": sid,
                    "session_name": sname,
                    "source": str(r["source"]),
                    "project": r["project"],
                    "privacy_tier": str(r["privacy_tier"]),
                    "message_count": 1,
                    "last_t_start": int(r["t_start"] or 0),
                }
            else:
                cur["message_count"] += 1
                if r["privacy_tier"] != "local_only":
                    cur["privacy_tier"] = str(r["privacy_tier"])
                if r["project"] and not cur["project"]:
                    cur["project"] = r["project"]
    finally:
        conn.close()
    return sorted(sessions.values(), key=lambda x: x["last_t_start"], reverse=True)


def build_channels_and_vault_router(root: Path, store: HubStore) -> APIRouter:
    """Build `/api/channels/*` and `/api/vault/*` routes bound to localhost Workbench."""
    router = APIRouter()
    vault = VaultStore(default_vault_dir(root))
    inbox_dir = default_chat_inbox_dir(root)
    allowlist_path = inbox_dir / "chat_allowlist.json"
    # In-memory-only unlock state; NEVER persisted to disk
    session_state: dict[str, str | None] = {"passphrase": None}

    def _require_unlocked() -> str:
        pw = session_state["passphrase"]
        if not pw:
            raise HTTPException(status_code=403, detail="Vault is locked. Unlock with passphrase first.")
        return pw

    # ---------------- Channels Control ----------------
    @router.get("/api/channels/status")
    def channels_status() -> dict[str, Any]:
        inv = _inventory_by_source(root / "hub.sqlite3")
        specs = list_channel_specs()
        enriched: list[dict[str, Any]] = []
        for sp in specs:
            counts = inv.get(sp["source"], {"total": 0, "shareable": 0, "local_only": 0, "last_t_start": 0})
            enriched.append({**sp, "counts": counts})
        doctors = {
            "browser": BrowserHistoryCollector().doctor(),
            "window": WindowFocusCollector().doctor(),
            "chat": ChatInboxCollector(data_dir=root).doctor(),
            "lark_im": LarkIMCollector(data_dir=root).doctor(),
        }
        return {
            "channels": enriched,
            "doctors": doctors,
            "chat_inbox_dir": str(inbox_dir),
            "chat_allowlist": load_chat_allowlist(allowlist_path),
            "im_sessions": _list_im_sessions(root / "hub.sqlite3"),
        }

    @router.post("/api/channels/sync")
    def channels_sync(body: SyncChannelIn) -> dict[str, Any]:
        sink = DirectHubSink(store)
        cps = HubCheckpointStore(store)
        mapping: dict[str, Any] = {
            "browser": BrowserHistoryCollector(since_days=body.since_days),
            "clipcontext": ClipContextCollector(),
            "window": WindowFocusCollector(),
            "chat": ChatInboxCollector(data_dir=root),
            "lark_im": LarkIMCollector(data_dir=root),
        }
        col = mapping.get(body.collector)
        if col is None:
            raise HTTPException(status_code=400, detail=f"Unsupported collector: {body.collector}")
        rep = run_collector(col, sink, cps)
        return {"report": rep.to_dict()}

    @router.post("/api/channels/chat/upload")
    def chat_upload(body: ChatUploadIn) -> dict[str, Any]:
        safe_name = Path(body.filename).name
        if not safe_name.lower().endswith((".json", ".jsonl", ".csv")):
            raise HTTPException(status_code=400, detail="Only .json, .jsonl, or .csv exports are supported")
        inbox_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        dest = inbox_dir / safe_name
        dest.write_text(body.content, encoding="utf-8")
        col = ChatInboxCollector(data_dir=root)
        rep = run_collector(col, DirectHubSink(store), HubCheckpointStore(store))
        return {"saved_path": str(dest), "report": rep.to_dict()}

    @router.post("/api/channels/chat/allowlist")
    def chat_allowlist_update(body: ChatAllowlistUpdateIn) -> dict[str, Any]:
        cur = load_chat_allowlist(allowlist_path)
        allowed = set(cur.get("allow_sessions") or [])
        pmap = dict(cur.get("project_map") or {})
        if body.allow:
            allowed.add(body.session_id)
        else:
            allowed.discard(body.session_id)
        if body.project:
            pmap[body.session_id] = body.project.strip()
        elif body.session_id in pmap and not body.allow:
            pmap.pop(body.session_id, None)
        saved = save_chat_allowlist(
            allowlist_path,
            {
                "allow_sessions": sorted(allowed),
                "default_allowed_tier": body.tier if body.tier in {"shareable", "redacted"} else "shareable",
                "project_map": pmap,
            },
        )
        # Apply privacy & project update immediately to existing imported messages of this session
        new_tier = saved["default_allowed_tier"] if body.allow else "local_only"
        updated = 0
        with store._tx(True) as conn:
            rows = conn.execute(
                "SELECT id, event_json FROM raw_events WHERE deleted=0 AND (source='wechat' OR source LIKE 'im.%')"
            ).fetchall()
            for r in rows:
                payload = json.loads(r["event_json"] or "{}")
                ctx = payload.get("context") or {}
                if str(ctx.get("session_id") or "") != body.session_id:
                    continue
                payload["privacy"] = {**(payload.get("privacy") or {}), "tier": new_tier}
                proj = pmap.get(body.session_id)
                if proj:
                    payload["project"] = proj
                conn.execute(
                    "UPDATE raw_events SET privacy_tier=?, project=COALESCE(?, project), event_json=? WHERE id=?",
                    (
                        new_tier,
                        proj,
                        json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
                        r["id"],
                    ),
                )
                updated += 1
        return {"allowlist": saved, "updated_messages": updated}

    # ---------------- Vault for Agent (Encrypted Entities, Docs & Form-Fill) ----------------
    @router.get("/api/vault/status")
    def vault_status() -> dict[str, Any]:
        return {
            "initialized": vault.is_initialized(),
            "unlocked": session_state["passphrase"] is not None,
            "vault_path": str(vault.db_path),
            "subjects": vault.list_subjects() if vault.is_initialized() else [],
            "records": vault.list_records() if vault.is_initialized() else [],
        }

    @router.post("/api/vault/init")
    def vault_init(body: VaultPassphraseIn) -> dict[str, Any]:
        try:
            res = vault.init_vault(body.passphrase)
        except (ValueError, VaultAuthError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from None
        session_state["passphrase"] = body.passphrase
        return {**res, "unlocked": True}

    @router.post("/api/vault/unlock")
    def vault_unlock(body: VaultPassphraseIn) -> dict[str, Any]:
        try:
            vault.unlock_key(body.passphrase)
        except VaultAuthError as exc:
            raise HTTPException(status_code=401, detail=str(exc)) from None
        session_state["passphrase"] = body.passphrase
        return {"unlocked": True, "subjects": vault.list_subjects(), "records": vault.list_records()}

    @router.post("/api/vault/lock")
    def vault_lock() -> dict[str, Any]:
        session_state["passphrase"] = None
        return {"unlocked": False}

    @router.post("/api/vault/record")
    def vault_save_record(body: VaultRecordIn) -> dict[str, Any]:
        pw = _require_unlocked()
        try:
            meta = vault.put_record(
                pw,
                kind=body.kind,  # type: ignore[arg-type]
                subject_id=body.subject_id,
                label=body.label,
                secret_payload=body.payload,
                record_id=body.record_id,
                project=body.project,
                tags=body.tags,
                allowed_commands=body.allowed_commands,
            )
            return {"record": meta}
        except (ValueError, VaultAuthError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from None

    @router.get("/api/vault/record/{record_id}")
    def vault_get_record(record_id: str) -> dict[str, Any]:
        pw = _require_unlocked()
        try:
            return {"record": vault.get_record(pw, record_id, actor="workbench_owner")}
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from None

    @router.delete("/api/vault/record/{record_id}")
    def vault_delete_record(record_id: str) -> dict[str, Any]:
        _require_unlocked()
        try:
            return vault.delete_record(record_id, actor="workbench_owner")
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from None

    @router.post("/api/vault/record/{record_id}/attach")
    def vault_attach(record_id: str, body: VaultAttachmentIn) -> dict[str, Any]:
        pw = _require_unlocked()
        try:
            raw_bytes = base64.b64decode(body.content_b64.encode("ascii"))
            att = vault.add_attachment(
                pw,
                record_id=record_id,
                filename=body.filename,
                data=raw_bytes,
                mime_type=body.mime_type,
            )
            return {"attachment": att}
        except (KeyError, ValueError, VaultAuthError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from None

    @router.get("/api/vault/attachment/{att_id}")
    def vault_download_attachment(att_id: str) -> Response:
        pw = _require_unlocked()
        try:
            meta, data = vault.get_attachment_bytes(pw, att_id, actor="workbench_owner")
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from None
        raw_name = Path(str(meta.get("filename") or "attachment")).name
        suffix = Path(raw_name).suffix
        ascii_stem = re.sub(r"[^A-Za-z0-9._-]+", "_", Path(raw_name).stem).strip("._-") or "attachment"
        ascii_suffix = re.sub(r"[^A-Za-z0-9.]+", "", suffix)
        fallback = f"{ascii_stem}{ascii_suffix}"
        encoded = quote(raw_name, safe="")
        return Response(
            content=data,
            media_type=meta["mime_type"],
            headers={
                "Content-Disposition": f"inline; filename=\"{fallback}\"; filename*=UTF-8''{encoded}",
                "Cache-Control": "no-store, private",
                "X-Content-Type-Options": "nosniff",
            },
        )

    @router.get("/api/vault/autofill/{subject_id:path}")
    def vault_autofill(subject_id: str, masked: bool = True) -> dict[str, Any]:
        pw = _require_unlocked()
        return vault.build_autofill_bundle(pw, subject_id, masked=masked, actor="workbench_owner")

    @router.post("/api/vault/sync-receipts")
    def vault_sync_receipts() -> dict[str, Any]:
        _require_unlocked()
        return vault.sync_masked_receipts_to_hub(store)

    return router
