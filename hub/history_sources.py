"""Turn projections for owner-selected native chat logs and exported conversations."""
from contextlib import contextmanager
from datetime import datetime
import json
import math
from pathlib import Path
import re
import subprocess
import uuid


def key(*parts):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, json.dumps(parts, ensure_ascii=False, separators=(",", ":"))))


def ms(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
        return round(value if abs(value) >= 100_000_000_000 else 1000 * value)
    if isinstance(value, str):
        d = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if d.tzinfo:
            return round(d.timestamp() * 1000)
    raise ValueError("A message needs a timestamp with timezone or Unix epoch.")


def identifier(value):
    if not isinstance(value, str) or not 0 < len(value) <= 512 or not value.isprintable():
        raise ValueError("Missing or invalid native identifier.")
    return value


def text_blocks(content, types):
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    out = []
    for part in content:
        if isinstance(part, str):
            out.append(part)
        elif isinstance(part, dict) and part.get("type", "") in types and isinstance(part.get("text"), str):
            out.append(part["text"])
    return "\n".join(out).strip()


def event(provider, session, msg, role, text, when, project=None, parent=None, origin="unknown", ref=None, order=None, parent_session=None):
    import hashlib
    provider, session, msg = map(identifier, (provider, session, msg))
    if role not in ("assistant", "user"):
        raise ValueError("Only user and assistant turns are supported.")
    time_ms = ms(when) if when is not None else 0
    connector = "chat-history/" + provider
    ident = key(connector, session, msg)
    episode = key(connector, session)
    context = {"session_id": session, "project": project or "unassigned/" + episode, "origin": origin}
    if when is None:
        # The ContextEvent schema requires integer times. Consumers must consult this
        # flag instead of presenting the wire sentinel as a genuine capture timestamp.
        context["timestamp_status"] = "missing"
        if order is not None:
            context["source_order"] = order
    if parent_session:
        context["parent_session_id"] = identifier(parent_session)
    row = {"id": ident, "source": "ai_chat", "kind": "chat_turn", "t_start": time_ms, "t_end": time_ms,
           "t_observed": time_ms, "episode_id": episode, "content": {"role": role, "text": text},
           "context": context, "privacy": {"tier": "local_only"},
           "provenance": {"connector": connector, "source_id": ident, "message_id": msg,
                          "locator": ref or "message:" + msg,
                          "source_hash": hashlib.sha256(text.encode("utf-8")).hexdigest()}}
    if parent:
        row["links"] = [{"relation": "reply_to", "target_id": key(connector, session, identifier(parent))}]
    return row


def from_cwd(cwd):
    return "workspace/" + key(str(Path(cwd))) if isinstance(cwd, str) and Path(cwd).is_absolute() else None


@contextmanager
def stream(path):
    if path.suffix not in {".zst", ".zstd"}:
        with path.open("rb") as source:
            yield source
        return
    with path.open("rb") as src:
        proc = subprocess.Popen(["zstd", "-dc"], stdin=src, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            yield proc.stdout
            if proc.wait() != 0:
                raise ValueError("Incomplete or invalid zstd stream.")
        finally:
            proc.stdout.close()
            if proc.poll() is None:
                proc.terminate()
            proc.wait()


def lines(path):
    with stream(path) as f:
        for number, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except (ValueError, UnicodeError) as exc:
                raise ValueError(f"Invalid JSON at line {number}.") from exc
            if not isinstance(obj, dict):
                raise ValueError(f"Expected an object at line {number}.")
            yield number, obj


def codex_rows(path, project):
    # Rollouts may echo inherited parent turns. Bind items to their actual thread.
    found = re.search(r"([0-9a-fA-F-]{36})\.jsonl(?:\.zstd?)?$", path.name)
    session = found.group(1) if found else None
    origin, workspace = "unknown", None
    native, legacy, messages = {}, [], []
    own = False
    for number, obj in lines(path):
        tag, p = obj.get("type"), obj.get("payload", {})
        if not isinstance(p, dict):
            continue
        if tag == "session_meta":
            ids = (p.get("id"), p.get("session_id"))
            session = session or next((i for i in ids if i), None)
            own = bool(session and session in ids)
            if own:
                workspace = from_cwd(p.get("cwd"))
                category, source = p.get("thread_source"), p.get("source")
                if p.get("parent_thread_id") or p.get("agent_path") or isinstance(source, dict) and "subagent" in source:
                    origin = "subagent"
                elif category == "automation" or source == "exec":
                    origin = "automation"
                elif category == "user" or source in ("vscode", "cli"):
                    origin = "user"
            continue
        item = p.get("item") or {}
        if tag == "event_msg" and p.get("type") == "item_completed" and item.get("type") in ("UserMessage", "AgentMessage"):
            if (p.get("thread_id") and session != p["thread_id"]) or (not p.get("thread_id") and not own):
                continue
            role = "user" if item["type"] == "UserMessage" else "assistant"
            text = text_blocks(item.get("content"), ("text", "Text"))
            if text and participant_text(role, text):
                idx = identifier(item.get("id") or "line-" + str(number))
                native[idx] = (idx, role, text, obj["timestamp"])
        elif own and tag == "event_msg" and p.get("type") in ("user_message", "agent_message"):
            role = "user" if p["type"] == "user_message" else "assistant"
            text = p.get("message")
            if isinstance(text, str) and text.strip() and participant_text(role, text):
                legacy.append((p.get("id") or "line-" + str(number), role, text.strip(), obj["timestamp"]))
        elif own and tag == "response_item" and p.get("type") == "message":
            role = p.get("role")
            if role not in ("assistant", "user") or p.get("recipient") not in (None, "all"):
                continue
            text = text_blocks(p.get("content"), ("output_text",) if role == "assistant" else ("input_text",))
            if text and participant_text(role, text):
                messages.append((p.get("id") or "line-" + str(number), role, text, obj["timestamp"]))
    if not session:
        raise ValueError("Missing Codex session metadata.")
    # Older versions may only write one representation per role. Prefer the UI
    # completion if present and never import its wire-level duplicate as a second turn.
    for role in ("user", "assistant"):
        turns = next((group for group in ([v for v in native.values() if v[1] == role],
                                          [v for v in legacy if v[1] == role],
                                          [v for v in messages if v[1] == role]) if group), [])
        for idx, _, text, when in turns:
            yield event("codex", session, idx, role, text, when, project or workspace, origin=origin)


def participant_text(role, text):
    # Runtime envelopes can have a user role even though no person authored them.
    return role != "user" or not text.lstrip().startswith(("<environment_context>", "<subagent_notification>",
        "<turn_aborted>", "<permissions instructions>", "<system-reminder>", "<local-command-caveat>"))


def claude_rows(path, project):
    for line, obj in lines(path):
        role, m = obj.get("type"), obj.get("message", {})
        if role not in ("user", "assistant") or not isinstance(m, dict) or m.get("role") != role:
            continue
        if obj.get("isMeta") or obj.get("isCompactSummary") or "toolUseResult" in obj or "sourceToolAssistantUUID" in obj:
            continue
        text = text_blocks(m.get("content"), ("text",))
        if text and participant_text(role, text):
            session = identifier(obj.get("sessionId") or obj.get("session_id"))
            agent_id = obj.get("agentId")
            if agent_id:
                session += "/" + identifier(agent_id)
            yield event("claude", session, obj.get("uuid") or "line-" + str(line), role, text,
                        obj["timestamp"], project or from_cwd(obj.get("cwd")), parent=obj.get("parentUuid"),
                        origin="subagent" if agent_id or obj.get("isSidechain") else "user")


def gemini_rows(data, project):
    for m in data["messages"]:
        role = {"user": "user", "gemini": "assistant"}.get(m.get("type"))
        text = text_blocks(m.get("content"), ("", "text"))
        if role and text and participant_text(role, text):
            workspace = project or ("gemini/" + data["projectHash"] if data.get("projectHash") else None)
            yield event("gemini", data["sessionId"], m["id"], role, text, m["timestamp"], workspace)


def chatgpt_rows(data, project):
    for chat in data if isinstance(data, list) else [data]:
        session = chat.get("conversation_id") or chat.get("id")
        mapping = chat["mapping"]
        if not isinstance(mapping, dict):
            raise ValueError("Expected a ChatGPT node mapping.")
        visible = {}
        for node_id, node in mapping.items():
            m = node.get("message") or {}
            role = (m.get("author") or {}).get("role")
            content = m.get("content") or {}
            if role not in ("user", "assistant") or m.get("recipient") not in (None, "all"):
                continue
            if (m.get("metadata") or {}).get("is_visually_hidden_from_conversation") or content.get("content_type") not in ("text", "multimodal_text"):
                continue
            text = text_blocks(content.get("parts"), ("text",))
            if text and participant_text(role, text):
                visible[node_id] = (role, text, m.get("create_time"))
        for order, (node_id, (role, text, when)) in enumerate(visible.items()):
            parent = mapping[node_id].get("parent")
            seen = {node_id}
            while parent and parent not in visible and parent in mapping:
                if parent in seen:
                    raise ValueError("Cyclic conversation ancestry.")
                seen.add(parent)
                parent = mapping[parent].get("parent")
            yield event("chatgpt", session, node_id, role, text, when, project,
                        parent=parent if parent in visible else None, origin="user", ref="mapping:" + node_id, order=order)


def claude_web_rows(data, project):
    """Import exported Claude.ai conversations, which differ from Claude Code JSONL."""
    for chat in data if isinstance(data, list) else [data]:
        session = identifier(chat["uuid"])
        visible, parents = {}, {}
        for order, msg in enumerate(chat["chat_messages"]):
            mid = identifier(msg["uuid"])
            if mid in parents:
                raise ValueError("Repeated Claude export message identifier.")
            parent = msg.get("parent_message_uuid")
            parents[mid] = None if parent == "00000000-0000-0000-0000-000000000000" else parent
            role = {"human": "user", "assistant": "assistant"}.get(msg.get("sender"))
            if not role:
                continue
            # Legacy exports have plain text only. Modern text blocks disambiguate
            # visible text from tools, attachments, documents and extended thinking.
            content = msg.get("content")
            text = text_blocks(content, ("text",)) if content else text_blocks(msg.get("text"), ())
            if text and participant_text(role, text):
                visible[mid] = (role, text, msg.get("created_at"), order)
        for mid, (role, text, when, order) in visible.items():
            parent, seen = parents[mid], {mid}
            while parent in parents and parent not in visible:
                if parent in seen:
                    raise ValueError("Cyclic Claude export ancestry.")
                seen.add(parent)
                parent = parents[parent]
            if parent == mid:
                raise ValueError("A message cannot be its own parent.")
            yield event("claude-web", session, mid, role, text, when, project,
                        parent=parent if parent in visible else None, order=order, origin="user")


def transcript_rows(data, project):
    name = data.get("provider", "transcript")
    if not isinstance(name, str) or not re.fullmatch(r"[a-z][a-z0-9_-]{0,48}", name):
        raise ValueError("Expected a short provider key.")
    origin = data.get("origin", "unknown")
    if origin not in {"unknown", "user", "automation", "subagent"}:
        raise ValueError("Unknown conversation origin.")
    for index, m in enumerate(data["messages"]):
        if m["role"] in ("user", "assistant") and isinstance(m["text"], str) and m["text"].strip():
            when = m.get("timestamp")
            if m.get("timestamp_status") == "missing":
                if when not in (None, 0):
                    raise ValueError("A missing source timestamp conflicts with the given timestamp.")
                when = None
            yield event(name, data["session_id"], m["id"], m["role"], m["text"], when,
                        project or data.get("project"), parent=m.get("parent_id"), origin=origin,
                        parent_session=data.get("parent_session_id"), order=index)


def rows(path, source, project):
    if source == "codex":
        yield from codex_rows(path, project)
    elif source == "claude":
        yield from claude_rows(path, project)
    elif source == "deepseek":
        from .deepseek_history import deepseek_rows
        yield from deepseek_rows(path, project)
    else:
        with stream(path) as f:
            data = json.load(f)
        parser = {"gemini": gemini_rows, "chatgpt": chatgpt_rows, "claude-web": claude_web_rows, "transcript": transcript_rows}[source]
        yield from parser(data, project)
