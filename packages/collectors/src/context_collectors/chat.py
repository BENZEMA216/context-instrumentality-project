"""Chat for Agent — Compliant WeFlow / WeChat / Telegram / IM Export Collector (Issue #7).

Implements strict privacy-by-default ingestion of user-exported IM chat archives:
  - Supported formats:
      1. WeFlow native JSON (`{"session": {"accountId", "name", "isGroup"}, "messages": [...]}`)
      2. Telegram Desktop JSON (`{"name", "type", "id", "messages": [...]}`)
      3. Generic chat JSON / JSONL arrays & CSV exports
  - Privacy-by-Default Boundary:
      Every imported conversation defaults to `privacy.tier = "local_only"` unless its
      session ID or group name appears explicitly in `chat_allowlist.json` (e.g. an opted-in
      project group), protecting personal DMs from ever leaking into Agent context packs.
  - Conversational Provenance:
      Preserves `actor="self"` vs peer name, reply/quote linkage, and deterministic day+session
      Episode grouping so multi-person decisions keep full Q&A context.
"""

from __future__ import annotations

import csv
import datetime
import hashlib
import json
import re
from pathlib import Path
from typing import Any

from context_hub.models import PrivacyTier, RawEventIn

from .runtime import CheckpointBackend, HubSink, SyncReport, default_device_id

_NOISE_MESSAGE_EXACT = frozenset(
    {
        "[动画表情]",
        "[表情]",
        "[图片]",
        "[语音]",
        "[视频]",
        "[Sticker]",
        "[Photo]",
    }
)
_SYSTEM_NOISE_RE = re.compile(
    r"^(?:.*撤回了一条消息|你已添加了.*|以上是打招呼的内容|.*加入了群聊|.*拍了拍.*)$"
)


def default_chat_inbox_dir(data_dir: Path | None = None) -> Path:
    root = Path(data_dir) if data_dir else (Path.home() / ".local" / "share" / "context-hub-v2")
    return root.expanduser() / "inbox" / "chat"


def load_chat_allowlist(path: Path | None) -> dict[str, Any]:
    """Load optional `chat_allowlist.json` controlling which IM sessions may leave `local_only`."""
    if not path or not path.is_file():
        return {"allow_sessions": [], "default_allowed_tier": "shareable", "project_map": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return {
                "allow_sessions": [str(x) for x in (data.get("allow_sessions") or [])],
                "default_allowed_tier": str(data.get("default_allowed_tier") or "shareable"),
                "project_map": {
                    str(k): str(v) for k, v in (data.get("project_map") or {}).items()
                },
            }
    except (OSError, ValueError):
        pass
    return {"allow_sessions": [], "default_allowed_tier": "shareable", "project_map": {}}


def _parse_ts_ms(raw: Any) -> int:
    if raw is None or raw == "":
        return 0
    if isinstance(raw, (int, float)):
        val = int(raw)
        if val > 10_000_000_000_000:
            return val // 1000
        if val > 10_000_000_000:
            return val
        return val * 1000
    s = str(raw).strip()
    if s.isdigit():
        return _parse_ts_ms(int(s))
    cleaned = s.replace("Z", "+00:00").replace("/", "-")
    try:
        dt = datetime.datetime.fromisoformat(cleaned)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.UTC)
        return int(dt.timestamp() * 1000)
    except ValueError:
        return 0


def _flatten_telegram_text(raw: Any) -> str:
    if isinstance(raw, str):
        return raw
    if isinstance(raw, list):
        parts: list[str] = []
        for item in raw:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict) and item.get("text"):
                parts.append(str(item["text"]))
        return "".join(parts)
    return str(raw or "")


def _is_chat_noise(text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return True
    if stripped in _NOISE_MESSAGE_EXACT:
        return True
    return bool(_SYSTEM_NOISE_RE.match(stripped))


def _resolve_session_policy(
    *,
    session_id: str,
    session_name: str,
    allowlist: dict[str, Any],
    explicit_project: str | None = None,
) -> tuple[PrivacyTier, str | None]:
    allowed_set = {x.casefold() for x in (allowlist.get("allow_sessions") or [])}
    keys = {session_id.casefold(), session_name.casefold()}
    tier: PrivacyTier = "local_only"
    if keys & allowed_set:
        cand = str(allowlist.get("default_allowed_tier") or "shareable")
        tier = cand if cand in {"local_only", "redacted", "shareable"} else "shareable"  # type: ignore[assignment]

    project = explicit_project
    if not project:
        pmap = allowlist.get("project_map") or {}
        for k, v in pmap.items():
            if k.casefold() in keys:
                project = str(v)
                break
    return tier, project


def parse_chat_export_file(
    path: Path,
    *,
    platform_hint: str = "auto",
    allowlist: dict[str, Any] | None = None,
    project: str | None = None,
    self_names: set[str] | None = None,
) -> list[RawEventIn]:
    """Parse a WeFlow JSON, Telegram Desktop JSON, JSONL, or CSV chat archive into `RawEventIn`."""
    policy = allowlist or {"allow_sessions": [], "default_allowed_tier": "shareable", "project_map": {}}
    self_low = {s.casefold() for s in (self_names or {"self", "me", "我"})}
    suffix = path.suffix.casefold()
    device_id = default_device_id()

    raw_records: list[dict[str, Any]] = []
    session_id = path.stem
    session_name = path.stem
    is_group = False
    detected_platform = platform_hint if platform_hint != "auto" else "wechat"

    if suffix == ".csv":
        with path.open("r", encoding="utf-8-sig", newline="") as fh:
            for idx, row in enumerate(csv.DictReader(fh), 1):
                raw_records.append(
                    {
                        "id": row.get("id") or f"row_{idx}",
                        "ts": row.get("timestamp") or row.get("time") or row.get("date"),
                        "sender": row.get("sender") or row.get("from") or "unknown",
                        "is_self": str(row.get("is_self") or "").casefold() in {"1", "true", "yes"},
                        "text": row.get("content") or row.get("text") or row.get("message") or "",
                        "session_id": row.get("session_id") or row.get("session") or session_id,
                        "session_name": row.get("session_name") or row.get("session") or session_name,
                        "reply_to": row.get("reply_to") or "",
                    }
                )
    elif suffix == ".jsonl":
        for idx, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if isinstance(obj, dict):
                raw_records.append(
                    {
                        "id": obj.get("id") or f"line_{idx}",
                        "ts": obj.get("createTime") or obj.get("timestamp") or obj.get("t_start"),
                        "sender": obj.get("sender") or obj.get("senderName") or obj.get("from") or "unknown",
                        "is_self": bool(obj.get("isSelf") or obj.get("is_self")),
                        "text": obj.get("content") or obj.get("text") or "",
                        "session_id": obj.get("sessionId") or obj.get("session_id") or session_id,
                        "session_name": obj.get("sessionName") or obj.get("session_name") or session_name,
                        "reply_to": obj.get("replyTo") or obj.get("reply_to") or "",
                    }
                )
    else:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(payload, dict) and isinstance(payload.get("messages"), list):
            # 1) WeFlow native export (`session.accountId`)
            if isinstance(payload.get("session"), dict):
                detected_platform = "wechat"
                sess = payload["session"]
                session_id = str(sess.get("accountId") or sess.get("id") or path.stem)
                session_name = str(sess.get("name") or sess.get("remark") or session_id)
                is_group = bool(sess.get("isGroup") or "@chatroom" in session_id)
                for idx, msg in enumerate(payload["messages"], 1):
                    if not isinstance(msg, dict):
                        continue
                    raw_records.append(
                        {
                            "id": msg.get("id") or msg.get("msgId") or f"wf_{idx}",
                            "ts": msg.get("createTime") or msg.get("timestamp") or msg.get("time"),
                            "sender": msg.get("senderName") or msg.get("sender") or "unknown",
                            "is_self": bool(msg.get("isSelf") or msg.get("isSend") == 1),
                            "text": msg.get("content") or msg.get("text") or "",
                            "session_id": session_id,
                            "session_name": session_name,
                            "reply_to": msg.get("replyTo") or msg.get("quoteId") or "",
                        }
                    )
            else:
                # 2) Telegram Desktop JSON export
                detected_platform = "telegram" if platform_hint == "auto" else platform_hint
                session_id = str(payload.get("id") or path.stem)
                session_name = str(payload.get("name") or session_id)
                is_group = "group" in str(payload.get("type") or "").casefold()
                for idx, msg in enumerate(payload["messages"], 1):
                    if not isinstance(msg, dict) or msg.get("type") == "service":
                        continue
                    raw_records.append(
                        {
                            "id": msg.get("id") or f"tg_{idx}",
                            "ts": msg.get("date_unixtime") or msg.get("date"),
                            "sender": msg.get("from") or msg.get("actor") or "unknown",
                            "is_self": bool(msg.get("is_self")),
                            "text": _flatten_telegram_text(msg.get("text")),
                            "session_id": session_id,
                            "session_name": session_name,
                            "reply_to": msg.get("reply_to_message_id") or "",
                        }
                    )
        elif isinstance(payload, list):
            for idx, msg in enumerate(payload, 1):
                if not isinstance(msg, dict):
                    continue
                raw_records.append(
                    {
                        "id": msg.get("id") or f"item_{idx}",
                        "ts": msg.get("createTime") or msg.get("timestamp") or msg.get("date"),
                        "sender": msg.get("senderName") or msg.get("sender") or msg.get("from") or "unknown",
                        "is_self": bool(msg.get("isSelf") or msg.get("is_self")),
                        "text": msg.get("content") or msg.get("text") or "",
                        "session_id": msg.get("sessionId") or msg.get("session_id") or session_id,
                        "session_name": msg.get("sessionName") or msg.get("session_name") or session_name,
                        "reply_to": msg.get("replyTo") or msg.get("reply_to") or "",
                    }
                )

    events: list[RawEventIn] = []
    source_name = "wechat" if detected_platform == "wechat" else f"im.{detected_platform}"

    for rec in raw_records:
        text = str(rec.get("text") or "").strip()
        if _is_chat_noise(text):
            continue
        t_start = _parse_ts_ms(rec.get("ts"))
        if t_start <= 0:
            continue
        sid = str(rec.get("session_id") or session_id)
        sname = str(rec.get("session_name") or session_name)
        sender = str(rec.get("sender") or "unknown").strip()
        is_self = bool(rec.get("is_self")) or sender.casefold() in self_low
        actor = "self" if is_self else sender
        tier, resolved_proj = _resolve_session_policy(
            session_id=sid,
            session_name=sname,
            allowlist=policy,
            explicit_project=project,
        )
        day_str = datetime.datetime.fromtimestamp(t_start / 1000.0, tz=datetime.UTC).strftime("%Y%m%d")
        ep_hash = hashlib.sha1(f"{detected_platform}:{sid}:{day_str}".encode()).hexdigest()[:14]
        source_id = f"{detected_platform}:{sid}:{rec['id']}"

        events.append(
            RawEventIn(
                source=source_name,
                kind="message",
                t_start=t_start,
                t_end=t_start,
                actor=actor,
                device_id=device_id,
                project=resolved_proj,
                episode_id=f"ep_chat_{ep_hash}",
                content={
                    "title": f"{sname} · {actor}",
                    "text": text,
                },
                context={
                    "platform": detected_platform,
                    "session_id": sid,
                    "session_name": sname,
                    "is_group": is_group,
                    "reply_to": str(rec.get("reply_to") or "") or None,
                },
                provenance={
                    "connector": f"chat-for-agent/{detected_platform}",
                    "source_id": source_id,
                    "locator": f"{detected_platform}://{sid}#{rec['id']}",
                },
                privacy={
                    "tier": tier,
                    "pii_tags": [] if tier != "local_only" else ["unlisted_im_chat"],
                },
            )
        )
    return events


class ChatInboxCollector:
    """Chat for Agent dropbox collector syncing exported WeFlow/WeChat/IM archives."""

    name = "chat"
    source = "wechat"

    def __init__(
        self,
        *,
        inbox_dir: Path | None = None,
        allowlist_path: Path | None = None,
        data_dir: Path | None = None,
    ):
        self.inbox_dir = Path(inbox_dir or default_chat_inbox_dir(data_dir)).expanduser()
        self.allowlist_path = (
            Path(allowlist_path).expanduser()
            if allowlist_path
            else (self.inbox_dir / "chat_allowlist.json")
        )

    def _discover_files(self) -> list[Path]:
        if not self.inbox_dir.is_dir():
            return []
        files: list[Path] = []
        for p in sorted(self.inbox_dir.rglob("*")):
            if not p.is_file() or p.name == "chat_allowlist.json":
                continue
            if p.suffix.casefold() in {".json", ".jsonl", ".csv"}:
                files.append(p)
        return files

    def doctor(self) -> dict[str, Any]:
        files = self._discover_files()
        allowlist = load_chat_allowlist(self.allowlist_path)
        return {
            "collector": self.name,
            "source": self.source,
            "available": self.inbox_dir.is_dir(),
            "inbox_dir": str(self.inbox_dir),
            "export_files_found": len(files),
            "allowlisted_sessions": len(allowlist.get("allow_sessions") or []),
            "privacy_default": "local_only",
        }

    def sync(self, sink: HubSink, checkpoints: CheckpointBackend) -> SyncReport:
        report = SyncReport(collector=self.name, source=self.source)
        files = self._discover_files()
        if not files:
            report.status = "unconfigured" if not self.inbox_dir.is_dir() else "ok"
            report.message = f"No chat export archives in {self.inbox_dir}"
            return report

        allowlist = load_chat_allowlist(self.allowlist_path)
        for path in files:
            report.sources_scanned += 1
            try:
                st = path.stat()
            except OSError as exc:
                report.skipped_errors += 1
                report.errors.append(f"{path.name}: {exc}")
                continue
            source_key = f"chat:{path.resolve()}"
            cp = checkpoints.get(self.name, source_key)
            if (
                cp
                and cp.get("inode") == st.st_ino
                and cp.get("file_size") == st.st_size
                and cp.get("mtime_ns") == st.st_mtime_ns
            ):
                report.sources_unchanged += 1
                continue
            try:
                events = parse_chat_export_file(path, allowlist=allowlist)
            except (OSError, ValueError, KeyError) as exc:
                report.skipped_errors += 1
                report.errors.append(f"{path.name}: {exc}")
                continue
            if events:
                res = sink.emit_batch(self.name, events)
                report.events_emitted += len(events)
                report.created += res.get("created", 0)
                report.existing += res.get("existing", 0)
                report.spooled += res.get("spooled", 0)
            checkpoints.put(
                self.name,
                source_key,
                inode=st.st_ino,
                file_size=st.st_size,
                mtime_ns=st.st_mtime_ns,
                cursor={"events": len(events)},
            )
            report.watermark = str(st.st_mtime_ns)
        return report
