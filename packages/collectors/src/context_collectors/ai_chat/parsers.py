"""Multi-provider AI Chat parsers producing Context Hub v2 `RawEventIn` records.

Supported live local stores (incremental):
- Antigravity (`~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`)
- Codex CLI / Desktop (`~/.codex/sessions/**/*.jsonl`, `.zst`/`.zstd`)
- Claude Code (`~/.claude/projects/**/*.jsonl`)
- Cursor (`state.vscdb` + `workspaceStorage/*/workspace.json`)
- OpenCode (`opencode.db`)
- WorkBuddy (JSONL with `<user_query>` unwrapping)
- QClaw (JSONL with fenced untrusted-metadata unwrapping)
- DeepSeek Harness (JSONL)

Supported export archives:
- ChatGPT (`conversations.json`)
- Claude.ai Web (`conversations.json`)
- Gemini CLI / Export JSON
- Generic `transcript` JSON
"""

from __future__ import annotations

import datetime
import hashlib
import json
import math
import re
from collections import defaultdict
from pathlib import Path
from typing import Any

from context_hub.models import RawEventIn
from context_hub.project_resolver import normalize_project_slug, project_from_path

from ..runtime import default_device_id, open_maybe_zstd, open_readonly_sqlite

_ABS_PATH_RE = re.compile(r"(/(?:Users|home|workspace|Volumes)/[^\s\"'`<>|()]+)")


def parse_timestamp_ms(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
        return round(value if abs(value) >= 100_000_000_000 else 1000 * value)
    if isinstance(value, str) and value.strip():
        try:
            dt = datetime.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.UTC)
            return round(dt.timestamp() * 1000)
        except ValueError:
            return None
    return None


def safe_id(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = value.strip()
    if not cleaned or len(cleaned) > 512 or not cleaned.isprintable():
        return None
    return cleaned


def extract_text_blocks(content: Any, allowed_types: tuple[str, ...]) -> str:
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for item in content:
        if isinstance(item, str):
            parts.append(item)
        elif (
            isinstance(item, dict)
            and item.get("type", "") in allowed_types
            and isinstance(item.get("text"), str)
        ):
            parts.append(item["text"])
    return "\n".join(parts).strip()


def is_human_visible_turn(role: str, text: str) -> bool:
    """Filter out injected runtime envelopes that carry `role=user` without human authorship."""
    if not text or not text.strip():
        return False
    if role != "user":
        return True
    stripped = text.lstrip()
    if stripped.startswith("# AGENTS.md instructions for "):
        before, closing, after = stripped.partition("</INSTRUCTIONS>")
        if closing and "<INSTRUCTIONS>" in before and (
            not after.strip()
            or re.fullmatch(
                r"\s*<environment_context>.*?</environment_context>\s*", after, re.S
            )
        ):
            return False
    blocked_prefixes = (
        "<environment_context>",
        "<subagent_notification>",
        "<turn_aborted>",
        "<permissions instructions>",
        "<system-reminder>",
        "<local-command-caveat>",
        "<CONTEXT_SUMMARY>",
        "<command-name>",
    )
    return not stripped.startswith(blocked_prefixes)


def unwrap_workbuddy_user(text: str) -> str:
    if re.match(r"\s*<(?:system-reminder|additional_data)(?=[\s>])", text):
        match = re.search(r"<user_query>(.*?)</user_query>\s*$", text, re.S)
        if not match:
            return ""
        return match.group(1).strip("\r\n")
    return text


def unwrap_qclaw_user(text: str) -> str:
    labels = (
        "Conversation info (untrusted metadata):",
        "Sender (untrusted metadata):",
        "Forwarded message context (untrusted metadata):",
    )
    while text.startswith(labels):
        label, _, rest = text.partition("\n")
        if label not in labels:
            break
        fence = "```"
        opening, _, tail = rest.partition("\n")
        if opening.strip() != fence + "json":
            return ""
        try:
            _, end = json.JSONDecoder().raw_decode(tail.lstrip())
        except ValueError:
            return ""
        remainder = tail.lstrip()[end:].lstrip("\r\n")
        if remainder.split("\n", 1)[0].rstrip("\r") != fence:
            return ""
        text = remainder.partition("\n")[2].lstrip("\r\n")
    return text


def make_chat_event(
    *,
    provider: str,
    session_id: str,
    message_id: str,
    role: str,
    text: str,
    timestamp_ms: int | None,
    project: str | None = None,
    cwd: str | None = None,
    origin: str = "user",
    locator: str | None = None,
    parent_message_id: str | None = None,
    parent_session_id: str | None = None,
    order: int | None = None,
    device_id: str | None = None,
) -> RawEventIn:
    connector = f"chat-history/{provider}"
    source_id = f"{session_id}:{message_id}"
    resolved_project = (
        normalize_project_slug(project) if project else None
    ) or project_from_path(cwd)
    ts = timestamp_ms if timestamp_ms is not None and timestamp_ms >= 0 else 0
    first_line = text.strip().splitlines()[0][:100] if text.strip() else f"{provider} turn"
    title = f"[{provider}] {first_line}"

    context: dict[str, Any] = {
        "session_id": session_id,
        "provider": provider,
        "role": role,
        "origin": origin,
    }
    if resolved_project:
        context["project"] = resolved_project
    if cwd:
        context["cwd"] = cwd
    if parent_session_id:
        context["parent_session_id"] = parent_session_id
    if timestamp_ms is None:
        context["timestamp_status"] = "missing"
    if order is not None:
        context["source_order"] = order

    links: list[dict[str, Any]] = []
    if parent_message_id:
        context["parent_message_id"] = parent_message_id

    return RawEventIn(
        source="ai_chat",
        kind="chat_turn",
        t_start=ts,
        t_end=ts,
        device_id=device_id or default_device_id(),
        actor="self" if role == "user" else provider,
        project=resolved_project,
        content={
            "role": role,
            "title": title,
            "text": text.strip(),
            "source_hash": hashlib.sha256(text.strip().encode("utf-8")).hexdigest(),
        },
        context=context,
        links=links,
        provenance={
            "connector": connector,
            "source_id": source_id,
            "locator": locator or f"{provider}://{session_id}#{message_id}",
        },
    )


# ----------------------------------------------------------------------
# 1. Antigravity Transcript Parser (Incremental JSONL)
# ----------------------------------------------------------------------
def _infer_project_from_antigravity_step(obj: dict[str, Any]) -> tuple[str | None, str | None]:
    """Infer workspace cwd/project from tool_calls or user prompt paths without storing tool dumps."""
    for tc in obj.get("tool_calls") or []:
        if not isinstance(tc, dict):
            continue
        args = tc.get("arguments") or tc.get("args") or {}
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except ValueError:
                args = {}
        if not isinstance(args, dict):
            continue
        for key in ("Path", "path", "CommandLine", "cwd", "Directory"):
            val = args.get(key)
            if isinstance(val, str):
                match = _ABS_PATH_RE.search(val)
                if match:
                    cand = match.group(1).rstrip(".,;:")
                    if "/.gemini/" in cand or "/.local/" in cand:
                        continue
                    proj = project_from_path(cand)
                    if proj:
                        return proj, cand
    content = obj.get("content")
    if isinstance(content, str):
        for match in _ABS_PATH_RE.finditer(content):
            cand = match.group(1).rstrip(".,;:")
            if "/.gemini/" in cand:
                continue
            proj = project_from_path(cand)
            if proj:
                return proj, cand
    return None, None


def parse_antigravity_records(
    records: list[tuple[int, dict[str, Any]]],
    *,
    conversation_id: str,
    path: Path,
    state: dict[str, Any] | None = None,
    project: str | None = None,
) -> tuple[list[RawEventIn], dict[str, Any]]:
    """Parse incremental Antigravity `transcript.jsonl` lines into clean user/assistant turns."""
    meta = dict(state or {})
    known_project = project or meta.get("project")
    known_cwd = meta.get("cwd")
    events: list[RawEventIn] = []

    for line_no, obj in records:
        if not known_project:
            inferred_proj, inferred_cwd = _infer_project_from_antigravity_step(obj)
            if inferred_proj:
                known_project = inferred_proj
                known_cwd = inferred_cwd

        step_type = obj.get("type")
        if step_type not in ("USER_INPUT", "PLANNER_RESPONSE"):
            continue
        content = obj.get("content")
        if not isinstance(content, str) or not content.strip():
            # Tool-only PLANNER_RESPONSE steps carry thinking/tool_calls without visible content
            continue
        role = "user" if step_type == "USER_INPUT" else "assistant"
        if not is_human_visible_turn(role, content):
            continue
        step_idx = obj.get("step_index")
        msg_id = f"step-{step_idx}" if isinstance(step_idx, int) else f"line-{line_no}"
        ts = parse_timestamp_ms(obj.get("created_at"))
        source_tag = str(obj.get("source") or "")
        origin = "user" if source_tag in ("USER_EXPLICIT", "MODEL", "") else "automation"
        events.append(
            make_chat_event(
                provider="antigravity",
                session_id=conversation_id,
                message_id=msg_id,
                role=role,
                text=content,
                timestamp_ms=ts,
                project=known_project,
                cwd=known_cwd,
                origin=origin,
                locator=f"antigravity://{conversation_id}#{msg_id}",
                order=step_idx if isinstance(step_idx, int) else line_no,
            )
        )

    meta["project"] = known_project
    meta["cwd"] = known_cwd
    return events, meta


# ----------------------------------------------------------------------
# 2. Codex CLI / Desktop Rollout Parser (`.jsonl` and `.zst`/`.zstd`)
# ----------------------------------------------------------------------
def parse_codex_file(path: Path, *, project: str | None = None) -> list[RawEventIn]:
    """Parse a Codex rollout file while deduplicating native/legacy/response wire formats."""
    found = re.search(r"([0-9a-fA-F-]{36})\.jsonl(?:\.zstd?)?$", path.name)
    session = found.group(1) if found else None
    origin = "unknown"
    cwd: str | None = None
    native: dict[str, tuple[str, str, str, Any]] = {}
    legacy: list[tuple[str, str, str, Any]] = []
    messages: list[tuple[str, str, str, Any]] = []
    own = False

    with open_maybe_zstd(path) as stream:
        for number, raw_line in enumerate(stream, 1):
            if not raw_line.strip():
                continue
            try:
                obj = json.loads(raw_line)
            except (ValueError, UnicodeError):
                continue
            if not isinstance(obj, dict):
                continue
            tag, p = obj.get("type"), obj.get("payload")
            if not isinstance(p, dict):
                continue
            if tag == "session_meta":
                ids = (p.get("id"), p.get("session_id"))
                session = session or next((i for i in ids if isinstance(i, str) and i), None)
                own = bool(session and session in ids)
                if own:
                    if isinstance(p.get("cwd"), str):
                        cwd = p["cwd"]
                    category, src = p.get("thread_source"), p.get("source")
                    if (
                        p.get("parent_thread_id")
                        or p.get("agent_path")
                        or (isinstance(src, dict) and "subagent" in src)
                    ):
                        origin = "subagent"
                    elif category == "automation" or src == "exec":
                        origin = "automation"
                    elif category == "user" or src in ("vscode", "cli", "desktop"):
                        origin = "user"
                continue
            item = p.get("item") or {}
            if (
                tag == "event_msg"
                and p.get("type") == "item_completed"
                and item.get("type") in ("UserMessage", "AgentMessage")
            ):
                if (p.get("thread_id") and session != p["thread_id"]) or (
                    not p.get("thread_id") and not own
                ):
                    continue
                role = "user" if item["type"] == "UserMessage" else "assistant"
                text = extract_text_blocks(item.get("content"), ("text", "Text"))
                if text and is_human_visible_turn(role, text):
                    idx = safe_id(item.get("id")) or f"line-{number}"
                    native[idx] = (idx, role, text, obj.get("timestamp"))
            elif own and tag == "event_msg" and p.get("type") in ("user_message", "agent_message"):
                role = "user" if p["type"] == "user_message" else "assistant"
                text = p.get("message")
                if isinstance(text, str) and text.strip() and is_human_visible_turn(role, text):
                    idx = safe_id(p.get("id")) or f"line-{number}"
                    legacy.append((idx, role, text.strip(), obj.get("timestamp")))
            elif own and tag == "response_item" and p.get("type") == "message":
                role = p.get("role")
                if role not in ("assistant", "user") or p.get("recipient") not in (None, "all"):
                    continue
                text = extract_text_blocks(
                    p.get("content"), ("output_text",) if role == "assistant" else ("input_text",)
                )
                if text and is_human_visible_turn(role, text):
                    idx = safe_id(p.get("id")) or f"line-{number}"
                    messages.append((idx, role, text, obj.get("timestamp")))

    if not session:
        return []

    events: list[RawEventIn] = []
    for role in ("user", "assistant"):
        turns = next(
            (
                group
                for group in (
                    [v for v in native.values() if v[1] == role],
                    [v for v in legacy if v[1] == role],
                    [v for v in messages if v[1] == role],
                )
                if group
            ),
            [],
        )
        for idx, _, text, when in turns:
            events.append(
                make_chat_event(
                    provider="codex",
                    session_id=session,
                    message_id=idx,
                    role=role,
                    text=text,
                    timestamp_ms=parse_timestamp_ms(when),
                    project=project,
                    cwd=cwd,
                    origin=origin,
                    locator=f"codex://{path.name}#{idx}",
                )
            )
    events.sort(key=lambda e: (e.t_start, e.provenance.source_id))
    return events


# ----------------------------------------------------------------------
# 3. Claude Code Incremental JSONL Parser
# ----------------------------------------------------------------------
def parse_claude_code_records(
    records: list[tuple[int, dict[str, Any]]],
    *,
    path: Path,
    state: dict[str, Any] | None = None,
    project: str | None = None,
) -> tuple[list[RawEventIn], dict[str, Any]]:
    meta = dict(state or {})
    events: list[RawEventIn] = []
    for line_no, obj in records:
        role = obj.get("type")
        msg = obj.get("message")
        if role not in ("user", "assistant") or not isinstance(msg, dict) or msg.get("role") != role:
            continue
        if (
            obj.get("isMeta")
            or obj.get("isCompactSummary")
            or "toolUseResult" in obj
            or "sourceToolAssistantUUID" in obj
        ):
            continue
        text = extract_text_blocks(msg.get("content"), ("text",))
        if not text or not is_human_visible_turn(role, text):
            continue
        session = safe_id(obj.get("sessionId") or obj.get("session_id")) or path.stem
        agent_id = safe_id(obj.get("agentId"))
        if agent_id:
            session = f"{session}/{agent_id}"
        mid = safe_id(obj.get("uuid")) or f"line-{line_no}"
        cwd = obj.get("cwd") if isinstance(obj.get("cwd"), str) else meta.get("cwd")
        if cwd:
            meta["cwd"] = cwd
        events.append(
            make_chat_event(
                provider="claude",
                session_id=session,
                message_id=mid,
                role=role,
                text=text,
                timestamp_ms=parse_timestamp_ms(obj.get("timestamp")),
                project=project,
                cwd=cwd,
                origin="subagent" if agent_id or obj.get("isSidechain") else "user",
                parent_message_id=safe_id(obj.get("parentUuid")),
                locator=f"claude://{session}#{mid}",
                order=line_no,
            )
        )
    return events, meta


# ----------------------------------------------------------------------
# 4. WorkBuddy & QClaw Incremental JSONL Parser
# ----------------------------------------------------------------------
def parse_workbuddy_or_qclaw_records(
    provider: str,
    records: list[tuple[int, dict[str, Any]]],
    *,
    path: Path,
    state: dict[str, Any] | None = None,
    project: str | None = None,
) -> tuple[list[RawEventIn], dict[str, Any]]:
    is_wb = provider == "workbuddy"
    meta = dict(state or {})
    session_id: str | None = meta.get("session_id")
    cwd: str | None = meta.get("cwd")
    parent_session: str | None = meta.get("parent_session_id")
    events: list[RawEventIn] = []

    for line_no, obj in records:
        tag = obj.get("type")
        mid = safe_id(obj.get("id"))
        sid = safe_id(obj.get("sessionId")) if is_wb else (mid if tag == "session" else None)
        if sid:
            session_id = sid
        if isinstance(obj.get("cwd"), str):
            cwd = obj["cwd"]
        if isinstance(obj.get("parentSessionId"), str):
            parent_session = obj["parentSessionId"]
        if tag != "message":
            continue
        visible = obj if is_wb else obj.get("message")
        if not isinstance(visible, dict):
            continue
        role = visible.get("role")
        if role not in ("user", "assistant"):
            continue
        content = visible.get("content")
        if is_wb:
            text = extract_text_blocks(
                content, ("input_text",) if role == "user" else ("output_text",)
            )
            if role == "user":
                text = unwrap_workbuddy_user(text)
        else:
            text = (
                content
                if isinstance(content, str)
                else extract_text_blocks(content, ("text",))
            )
            if role == "user":
                text = unwrap_qclaw_user(text)
        if not text.strip() or not is_human_visible_turn(role, text):
            continue
        ts = parse_timestamp_ms(
            obj.get("timestamp") if obj.get("timestamp") is not None else visible.get("timestamp")
        )
        resolved_sid = session_id or path.stem
        resolved_mid = mid or f"line-{line_no}"
        events.append(
            make_chat_event(
                provider=provider,
                session_id=resolved_sid,
                message_id=resolved_mid,
                role=role,
                text=text,
                timestamp_ms=ts,
                project=project,
                cwd=cwd,
                origin="subagent" if parent_session else "user",
                parent_message_id=safe_id(obj.get("parentId")),
                parent_session_id=parent_session,
                locator=f"{provider}://{resolved_sid}#{resolved_mid}",
                order=line_no,
            )
        )

    meta["session_id"] = session_id
    meta["cwd"] = cwd
    meta["parent_session_id"] = parent_session
    return events, meta


# ----------------------------------------------------------------------
# 5. DeepSeek Harness Incremental JSONL Parser
# ----------------------------------------------------------------------
def parse_deepseek_records(
    records: list[tuple[int, dict[str, Any]]],
    *,
    path: Path,
    state: dict[str, Any] | None = None,
    project: str | None = None,
) -> tuple[list[RawEventIn], dict[str, Any]]:
    meta = dict(state or {})
    session_id: str | None = meta.get("session_id")
    cwd: str | None = meta.get("cwd")
    parent_session: str | None = meta.get("parent_session_id")
    origin: str = meta.get("origin") or "user"
    events: list[RawEventIn] = []

    for line_no, record in records:
        kind = record.get("type")
        if kind == "session":
            session_id = safe_id(record.get("id")) or session_id
            if isinstance(record.get("cwd"), str):
                cwd = record["cwd"]
            parent = record.get("parentSession")
            if isinstance(parent, dict):
                parent = parent.get("id") or parent.get("sessionId")
            parent_session = safe_id(parent) or parent_session
            origin = "subagent" if parent_session or record.get("delegationDepth", 0) else "user"
            continue
        if kind not in {"user/message", "assistant/message"}:
            continue
        data = record.get("data") or {}
        message = data if kind == "user/message" else data.get("message") or {}
        role = message.get("role")
        if role != kind.partition("/")[0]:
            continue
        src = message.get("source") or {}
        if role == "user" and (not isinstance(src, dict) or src.get("kind") != "user"):
            continue
        text = extract_text_blocks(message.get("content"), ("text",))
        if not text:
            continue
        resolved_sid = session_id or path.stem
        mid = safe_id(message.get("id")) or f"line-{line_no}"
        events.append(
            make_chat_event(
                provider="deepseek-harness",
                session_id=resolved_sid,
                message_id=mid,
                role=role,
                text=text,
                timestamp_ms=parse_timestamp_ms(record.get("time")),
                project=project,
                cwd=cwd,
                origin=origin,
                parent_session_id=parent_session,
                locator=f"deepseek://{resolved_sid}#{mid}",
                order=record.get("seq", line_no),
            )
        )

    meta["session_id"] = session_id
    meta["cwd"] = cwd
    meta["parent_session_id"] = parent_session
    meta["origin"] = origin
    return events, meta


# ----------------------------------------------------------------------
# 6. Cursor & OpenCode Read-Only SQLite Readers (Incremental Cursors)
# ----------------------------------------------------------------------
def _cursor_workspace_map(workspaces_dir: Path | None) -> dict[str, set[str]]:
    links: dict[str, set[str]] = defaultdict(set)
    if not workspaces_dir or not workspaces_dir.is_dir():
        return links
    for marker in sorted(workspaces_dir.glob("*/workspace.json")):
        db = marker.with_name("state.vscdb")
        if marker.is_symlink() or not db.is_file() or db.is_symlink():
            continue
        try:
            meta = json.loads(marker.read_bytes())
            uri = meta.get("folder") or meta.get("workspace")
            if not uri:
                continue
            with open_readonly_sqlite(db) as conn:
                row = conn.execute(
                    "SELECT value FROM ItemTable WHERE key='composer.composerData'"
                ).fetchone()
                if row and row[0]:
                    for entry in json.loads(row[0]).get("allComposers", []):
                        if isinstance(entry, dict) and entry.get("composerId"):
                            links[entry["composerId"]].add(uri)
        except (OSError, ValueError):
            continue
    return links


def parse_cursor_db(
    global_vscdb: Path,
    *,
    workspaces_dir: Path | None = None,
    seen_header_counts: dict[str, int] | None = None,
    project: str | None = None,
) -> tuple[list[RawEventIn], dict[str, int]]:
    """Read new visible bubbles from Cursor `globalStorage/state.vscdb` safely read-only."""
    prior_counts = dict(seen_header_counts or {})
    next_counts = dict(prior_counts)
    links = _cursor_workspace_map(workspaces_dir)
    events: list[RawEventIn] = []

    with open_readonly_sqlite(global_vscdb) as db:
        composers = db.execute(
            """SELECT key, json_extract(value,'$.composerId') sid,
                      json_extract(value,'$.fullConversationHeadersOnly') headers,
                      json_extract(value,'$.workspacePath') workspace,
                      json_extract(value,'$.parentComposerId') parent
               FROM cursorDiskKV WHERE key GLOB 'composerData:*' ORDER BY key"""
        ).fetchall()

        for row in composers:
            sid = safe_id(row["sid"])
            if not sid or row["key"] != f"composerData:{sid}":
                continue
            headers = json.loads(row["headers"] or "[]")
            if not isinstance(headers, list):
                continue
            prev_len = prior_counts.get(sid, 0)
            if len(headers) <= prev_len:
                continue

            workspace = row["workspace"]
            if not workspace and len(links[sid]) == 1:
                workspace = next(iter(links[sid]))

            start_idx = prev_len if prev_len < len(headers) else 0
            for idx, header in enumerate(headers[start_idx:], start=start_idx):
                if not isinstance(header, dict):
                    continue
                mid = safe_id(header.get("bubbleId"))
                if not mid:
                    continue
                bubble = db.execute(
                    """SELECT json_extract(value,'$.bubbleId') id,
                              json_extract(value,'$.type') role,
                              json_extract(value,'$.text') text,
                              json_extract(value,'$.createdAt') ts,
                              json_extract(value,'$.parentBubbleId') parent,
                              json_extract(value,'$.skipRendering') hidden,
                              json_extract(value,'$.isNudge') nudge,
                              json_extract(value,'$.isSynthetic') synthetic
                       FROM cursorDiskKV WHERE key=?""",
                    (f"bubbleId:{sid}:{mid}",),
                ).fetchone()
                if bubble is None:
                    continue
                role = {1: "user", 2: "assistant"}.get(bubble["role"])
                text = bubble["text"]
                if (
                    role
                    and isinstance(text, str)
                    and text.strip()
                    and not any(bubble[k] for k in ("hidden", "nudge", "synthetic"))
                    and is_human_visible_turn(role, text)
                ):
                    events.append(
                        make_chat_event(
                            provider="cursor",
                            session_id=sid,
                            message_id=mid,
                            role=role,
                            text=text,
                            timestamp_ms=parse_timestamp_ms(bubble["ts"]),
                            project=project,
                            cwd=workspace if isinstance(workspace, str) else None,
                            origin="subagent" if row["parent"] else "user",
                            parent_message_id=safe_id(bubble["parent"]),
                            parent_session_id=safe_id(row["parent"]),
                            locator=f"cursor://{sid}#{mid}",
                            order=idx,
                        )
                    )
            next_counts[sid] = len(headers)
    return events, next_counts


def parse_opencode_db(
    db_path: Path,
    *,
    after_time_created: int = 0,
    project: str | None = None,
) -> tuple[list[RawEventIn], int]:
    """Read new visible turns from OpenCode SQLite DB using `time_created` watermark."""
    events: list[RawEventIn] = []
    max_created = after_time_created
    with open_readonly_sqlite(db_path) as db:
        sessions = {
            row["id"]: (row["directory"] or row["project_id"], row["parent_id"])
            for row in db.execute(
                "SELECT id, project_id, directory, parent_id FROM session"
            ).fetchall()
        }
        msg_rows = db.execute(
            """SELECT id, session_id, time_created,
                      json_extract(data,'$.role') role,
                      json_extract(data,'$.parentID') parent_id,
                      json_extract(data,'$.time.created') ts,
                      json_type(data,'$.summary') generated_summary
               FROM message
               WHERE time_created > ?
               ORDER BY time_created ASC, id ASC""",
            (after_time_created,),
        ).fetchall()

        for row in msg_rows:
            created = int(row["time_created"] or 0)
            if created > max_created:
                max_created = created
            role = row["role"]
            if role not in ("user", "assistant") or row["generated_summary"] == "true":
                continue
            sid = safe_id(row["session_id"])
            mid = safe_id(row["id"])
            if not sid or not mid:
                continue
            parts = db.execute(
                """SELECT json_extract(data,'$.text') FROM part
                   WHERE session_id=? AND message_id=?
                     AND json_extract(data,'$.type')='text'
                     AND NOT coalesce(json_extract(data,'$.synthetic'), 0)
                     AND NOT coalesce(json_extract(data,'$.ignored'), 0)
                   ORDER BY time_created, id""",
                (sid, mid),
            ).fetchall()
            text = "\n".join(v for (v,) in parts if isinstance(v, str)).strip()
            if not text or not is_human_visible_turn(role, text):
                continue
            directory, parent_session = sessions.get(sid, (None, None))
            ts = row["ts"] if row["ts"] is not None else created
            events.append(
                make_chat_event(
                    provider="opencode",
                    session_id=sid,
                    message_id=mid,
                    role=role,
                    text=text,
                    timestamp_ms=parse_timestamp_ms(ts),
                    project=project,
                    cwd=directory if isinstance(directory, str) else None,
                    origin="subagent" if parent_session else "user",
                    parent_message_id=safe_id(row["parent_id"]),
                    parent_session_id=safe_id(parent_session),
                    locator=f"opencode://{sid}#{mid}",
                )
            )
    return events, max_created


# ----------------------------------------------------------------------
# 7. Export Archive Parsers (ChatGPT, Claude Web, Gemini, Generic)
# ----------------------------------------------------------------------
def parse_chatgpt_export(data: Any, *, project: str | None = None) -> list[RawEventIn]:
    events: list[RawEventIn] = []
    chats = data if isinstance(data, list) else [data]
    for chat in chats:
        if not isinstance(chat, dict):
            continue
        session = safe_id(chat.get("conversation_id") or chat.get("id"))
        mapping = chat.get("mapping")
        if not session or not isinstance(mapping, dict):
            continue
        visible: dict[str, tuple[str, str, Any]] = {}
        for node_id, node in mapping.items():
            if not isinstance(node, dict):
                continue
            m = node.get("message") or {}
            role = (m.get("author") or {}).get("role")
            content = m.get("content") or {}
            if role not in ("user", "assistant") or m.get("recipient") not in (None, "all"):
                continue
            if (m.get("metadata") or {}).get("is_visually_hidden_from_conversation"):
                continue
            if content.get("content_type") not in ("text", "multimodal_text"):
                continue
            text = extract_text_blocks(content.get("parts"), ("text",))
            if text and is_human_visible_turn(role, text):
                visible[node_id] = (role, text, m.get("create_time"))
        for order, (node_id, (role, text, when)) in enumerate(visible.items()):
            parent = mapping[node_id].get("parent")
            seen = {node_id}
            while parent and parent not in visible and parent in mapping:
                if parent in seen:
                    parent = None
                    break
                seen.add(parent)
                parent = mapping[parent].get("parent")
            events.append(
                make_chat_event(
                    provider="chatgpt",
                    session_id=session,
                    message_id=node_id,
                    role=role,
                    text=text,
                    timestamp_ms=parse_timestamp_ms(when),
                    project=project,
                    origin="user",
                    parent_message_id=parent if parent in visible else None,
                    locator=f"chatgpt://{session}#mapping:{node_id}",
                    order=order,
                )
            )
    return events


def parse_claude_web_export(data: Any, *, project: str | None = None) -> list[RawEventIn]:
    events: list[RawEventIn] = []
    chats = data if isinstance(data, list) else [data]
    for chat in chats:
        if not isinstance(chat, dict):
            continue
        session = safe_id(chat.get("uuid"))
        if not session:
            continue
        visible: dict[str, tuple[str, str, Any, int]] = {}
        parents: dict[str, str | None] = {}
        for order, msg in enumerate(chat.get("chat_messages") or []):
            mid = safe_id(msg.get("uuid"))
            if not mid:
                continue
            parent = msg.get("parent_message_uuid")
            parents[mid] = None if parent == "00000000-0000-0000-0000-000000000000" else safe_id(parent)
            role = {"human": "user", "assistant": "assistant"}.get(msg.get("sender"))
            if not role:
                continue
            content = msg.get("content")
            text = (
                extract_text_blocks(content, ("text",))
                if content
                else extract_text_blocks(msg.get("text"), ())
            )
            if text and is_human_visible_turn(role, text):
                visible[mid] = (role, text, msg.get("created_at"), order)
        for mid, (role, text, when, order) in visible.items():
            parent, seen = parents.get(mid), {mid}
            while parent in parents and parent not in visible:
                if parent in seen:
                    parent = None
                    break
                seen.add(parent)
                parent = parents.get(parent)
            events.append(
                make_chat_event(
                    provider="claude-web",
                    session_id=session,
                    message_id=mid,
                    role=role,
                    text=text,
                    timestamp_ms=parse_timestamp_ms(when),
                    project=project,
                    origin="user",
                    parent_message_id=parent if parent in visible else None,
                    locator=f"claude-web://{session}#{mid}",
                    order=order,
                )
            )
    return events


def parse_gemini_export(data: Any, *, project: str | None = None) -> list[RawEventIn]:
    events: list[RawEventIn] = []
    sessions = data if isinstance(data, list) else [data]
    for sess in sessions:
        if not isinstance(sess, dict):
            continue
        sid = safe_id(sess.get("sessionId") or sess.get("id"))
        if not sid:
            continue
        for idx, m in enumerate(sess.get("messages") or []):
            role = {"user": "user", "gemini": "assistant", "model": "assistant"}.get(m.get("type") or m.get("role"))
            text = extract_text_blocks(m.get("content"), ("", "text"))
            if role and text and is_human_visible_turn(role, text):
                mid = safe_id(m.get("id")) or f"msg-{idx}"
                events.append(
                    make_chat_event(
                        provider="gemini",
                        session_id=sid,
                        message_id=mid,
                        role=role,
                        text=text,
                        timestamp_ms=parse_timestamp_ms(m.get("timestamp")),
                        project=project,
                        origin="user",
                        locator=f"gemini://{sid}#{mid}",
                        order=idx,
                    )
                )
    return events


def parse_generic_transcript(data: dict[str, Any], *, project: str | None = None) -> list[RawEventIn]:
    provider = data.get("provider", "transcript")
    if not isinstance(provider, str) or not re.fullmatch(r"[a-z][a-z0-9_-]{0,48}", provider):
        raise ValueError("Expected short provider key.")
    sid = safe_id(data.get("session_id"))
    if not sid:
        raise ValueError("Missing session_id.")
    origin = str(data.get("origin") or "user")
    events: list[RawEventIn] = []
    for idx, m in enumerate(data.get("messages") or []):
        role = m.get("role")
        text = m.get("text")
        if role not in ("user", "assistant") or not isinstance(text, str) or not text.strip():
            continue
        mid = safe_id(m.get("id")) or f"msg-{idx}"
        when = None if m.get("timestamp_status") == "missing" else m.get("timestamp")
        events.append(
            make_chat_event(
                provider=provider,
                session_id=sid,
                message_id=mid,
                role=role,
                text=text,
                timestamp_ms=parse_timestamp_ms(when),
                project=project or data.get("project"),
                origin=origin,
                parent_message_id=safe_id(m.get("parent_id")),
                parent_session_id=safe_id(data.get("parent_session_id")),
                locator=f"{provider}://{sid}#{mid}",
                order=idx,
            )
        )
    return events


def parse_export_file(path: Path, source: str, *, project: str | None = None) -> list[RawEventIn]:
    """One-off parser dispatcher for CLI import (`context-collectors import-chat`)."""
    if source == "codex":
        return parse_codex_file(path, project=project)
    if source == "claude":
        records: list[tuple[int, dict[str, Any]]] = []
        with open_maybe_zstd(path) as fh:
            for i, line in enumerate(fh, 1):
                if line.strip():
                    records.append((i, json.loads(line)))
        events, _ = parse_claude_code_records(records, path=path, project=project)
        return events
    if source == "deepseek":
        records = []
        with open_maybe_zstd(path) as fh:
            for i, line in enumerate(fh, 1):
                if line.strip():
                    records.append((i, json.loads(line)))
        events, _ = parse_deepseek_records(records, path=path, project=project)
        return events
    if source == "antigravity":
        records = []
        with open_maybe_zstd(path) as fh:
            for i, line in enumerate(fh, 1):
                if line.strip():
                    records.append((i, json.loads(line)))
        conv_id = path.parent.parent.parent.name if path.name == "transcript.jsonl" else path.stem
        events, _ = parse_antigravity_records(
            records, conversation_id=conv_id, path=path, project=project
        )
        return events
    with open_maybe_zstd(path) as fh:
        data = json.load(fh)
    if source == "chatgpt":
        return parse_chatgpt_export(data, project=project)
    if source == "claude-web":
        return parse_claude_web_export(data, project=project)
    if source == "gemini":
        return parse_gemini_export(data, project=project)
    if source == "transcript":
        return parse_generic_transcript(data, project=project)
    raise ValueError(f"Unsupported chat source: {source}")
