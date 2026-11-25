"""Chat for Agent · Lark / Feishu Compliant IM Collector (via official `lark-cli`).

Strictly uses official `lark-cli` OpenAPI shortcuts (`im +chat-list`, `im +chat-messages-list`),
never scraping or bypassing auth. Enforces the same privacy-by-default boundary as WeChat:
every synced chat defaults to `local_only` unless explicitly allowlisted in `chat_allowlist.json`.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

from context_hub.models import RawEventIn

from .chat import (
    _is_chat_noise,
    _parse_ts_ms,
    _resolve_session_policy,
    default_chat_inbox_dir,
    load_chat_allowlist,
)
from .runtime import CheckpointBackend, HubSink, SyncReport, default_device_id


def _lark_env() -> dict[str, str]:
    return {
        **os.environ,
        "LARKSUITE_CLI_NO_UPDATE_NOTIFIER": "1",
        "LARKSUITE_CLI_NO_SKILLS_NOTIFIER": "1",
    }


def _run_lark_json(args: list[str], *, timeout: float = 15.0) -> dict[str, Any] | None:
    if not shutil.which("lark-cli"):
        return None
    try:
        proc = subprocess.run(
            ["lark-cli", *args],
            env=_lark_env(),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    raw = (proc.stdout or "").strip()
    if not raw:
        return None
    try:
        data = json.loads(raw)
        return data if isinstance(data, dict) else {"items": data}
    except ValueError:
        return None


def parse_lark_messages(
    chat_id: str,
    chat_name: str,
    messages: list[dict[str, Any]],
    *,
    self_open_id: str | None = None,
    allowlist: dict[str, Any] | None = None,
) -> list[RawEventIn]:
    """Convert Lark/Feishu message payloads into `RawEventIn` with strict privacy gating."""
    policy = allowlist or {"allow_sessions": [], "default_allowed_tier": "shareable", "project_map": {}}
    tier, resolved_proj = _resolve_session_policy(
        session_id=chat_id,
        session_name=chat_name,
        allowlist=policy,
    )
    device_id = default_device_id()
    events: list[RawEventIn] = []

    for msg in messages:
        if not isinstance(msg, dict):
            continue
        msg_id = str(msg.get("message_id") or msg.get("id") or "").strip()
        if not msg_id:
            continue
        t_start = _parse_ts_ms(msg.get("create_time") or msg.get("timestamp"))
        if t_start <= 0:
            continue

        body = msg.get("content") or msg.get("body") or ""
        if isinstance(body, dict):
            body = body.get("content") or body.get("text") or json.dumps(body, ensure_ascii=False)
        text = str(body).strip()
        if text.startswith("{") and text.endswith("}"):
            try:
                parsed_body = json.loads(text)
                if isinstance(parsed_body, dict) and parsed_body.get("text"):
                    text = str(parsed_body["text"]).strip()
            except ValueError:
                pass
        if _is_chat_noise(text):
            continue

        sender = msg.get("sender") or {}
        if isinstance(sender, dict):
            sender_id = str(sender.get("id") or sender.get("open_id") or "")
            sender_name = str(sender.get("name") or sender_id or "unknown")
        else:
            sender_id = str(sender)
            sender_name = sender_id or "unknown"
        actor = "self" if (self_open_id and sender_id == self_open_id) else sender_name

        day_str = datetime.datetime.fromtimestamp(t_start / 1000.0, tz=datetime.UTC).strftime("%Y%m%d")
        ep_hash = hashlib.sha1(f"lark:{chat_id}:{day_str}".encode()).hexdigest()[:14]

        events.append(
            RawEventIn(
                source="im.lark",
                kind="message",
                t_start=t_start,
                t_end=t_start,
                actor=actor,
                device_id=device_id,
                project=resolved_proj,
                episode_id=f"ep_lark_{ep_hash}",
                content={
                    "title": f"{chat_name} · {actor}",
                    "text": text,
                },
                context={
                    "platform": "lark",
                    "session_id": chat_id,
                    "session_name": chat_name,
                    "thread_id": msg.get("thread_id"),
                    "parent_id": msg.get("parent_id"),
                },
                provenance={
                    "connector": "chat-for-agent/lark",
                    "source_id": f"lark:{chat_id}:{msg_id}",
                    "locator": f"lark://chat/{chat_id}#{msg_id}",
                },
                privacy={
                    "tier": tier,
                    "pii_tags": [] if tier != "local_only" else ["unlisted_im_chat"],
                },
            )
        )
    return events


class LarkIMCollector:
    """Official `lark-cli` compliant Feishu/Lark IM collector."""

    name = "lark_im"
    source = "im.lark"

    def __init__(
        self,
        *,
        allowlist_path: Path | None = None,
        data_dir: Path | None = None,
        max_chats: int = 20,
        messages_per_chat: int = 50,
    ):
        self.allowlist_path = (
            Path(allowlist_path).expanduser()
            if allowlist_path
            else (default_chat_inbox_dir(data_dir) / "chat_allowlist.json")
        )
        self.max_chats = max(1, max_chats)
        self.messages_per_chat = max(1, messages_per_chat)

    def doctor(self) -> dict[str, Any]:
        cli_path = shutil.which("lark-cli")
        if not cli_path:
            return {
                "collector": self.name,
                "source": self.source,
                "available": False,
                "reason": "lark-cli not installed",
            }
        status = _run_lark_json(["auth", "status", "--json"])
        user_info = ((status or {}).get("identities") or {}).get("user") or {}
        bot_info = ((status or {}).get("identities") or {}).get("bot") or {}
        user_ready = bool(user_info.get("available"))
        return {
            "collector": self.name,
            "source": self.source,
            "available": user_ready,
            "lark_cli": cli_path,
            "brand": (status or {}).get("brand"),
            "user_ready": user_ready,
            "bot_ready": bool(bot_info.get("available")),
            "hint": None
            if user_ready
            else "Run `lark-cli auth login --domain im` to enable personal Feishu/Lark IM sync",
            "privacy_default": "local_only",
        }

    def sync(self, sink: HubSink, checkpoints: CheckpointBackend) -> SyncReport:
        report = SyncReport(collector=self.name, source=self.source)
        doc = self.doctor()
        if not doc.get("available"):
            report.status = "unconfigured"
            report.message = str(doc.get("hint") or doc.get("reason") or "lark-cli user auth required")
            return report

        status = _run_lark_json(["auth", "status", "--json"]) or {}
        self_open_id = ((status.get("identities") or {}).get("user") or {}).get("openId")
        allowlist = load_chat_allowlist(self.allowlist_path)
        chats_resp = _run_lark_json(
            ["im", "+chat-list", "--as", "user", "--page-size", str(self.max_chats), "--json"]
        )
        chats = (chats_resp or {}).get("items") or (chats_resp or {}).get("chats") or []
        if not isinstance(chats, list):
            report.status = "degraded"
            report.message = "Unable to list Lark chats"
            return report

        for chat in chats[: self.max_chats]:
            if not isinstance(chat, dict):
                continue
            cid = str(chat.get("chat_id") or "").strip()
            cname = str(chat.get("name") or cid)
            if not cid:
                continue
            report.sources_scanned += 1
            msg_resp = _run_lark_json(
                [
                    "im",
                    "+chat-messages-list",
                    "--as",
                    "user",
                    "--chat-id",
                    cid,
                    "--page-size",
                    str(self.messages_per_chat),
                    "--no-reactions",
                    "--json",
                ]
            )
            msgs = (msg_resp or {}).get("items") or (msg_resp or {}).get("messages") or []
            if not isinstance(msgs, list):
                report.skipped_errors += 1
                continue
            events = parse_lark_messages(
                cid,
                cname,
                msgs,
                self_open_id=self_open_id,
                allowlist=allowlist,
            )
            if events:
                res = sink.emit_batch(self.name, events)
                report.events_emitted += len(events)
                report.created += res.get("created", 0)
                report.existing += res.get("existing", 0)
                report.spooled += res.get("spooled", 0)
                max_ts = max(ev.t_start for ev in events)
                checkpoints.put(self.name, f"lark:{cid}", cursor={"last_ts_ms": max_ts})
                report.watermark = str(max_ts)
        return report
