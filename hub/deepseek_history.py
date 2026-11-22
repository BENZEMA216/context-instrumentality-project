"""Read completed, visible messages from an owner-selected DeepSeek Harness session."""
from .history_sources import event, from_cwd, identifier, lines, text_blocks


def deepseek_rows(path, project=None):
    session_id = None
    parent_session = None
    origin = "unknown"
    workspace = project

    for line, record in lines(path):
        kind = record.get("type")
        if kind == "session":
            candidate = identifier(record.get("id"))
            if session_id is not None and candidate != session_id:
                raise ValueError("Conflicting DeepSeek session headers.")
            session_id = candidate
            workspace = project or from_cwd(record.get("cwd"))
            parent = record.get("parentSession")
            if isinstance(parent, dict):
                parent = parent.get("id") or parent.get("sessionId")
            parent_session = parent if isinstance(parent, str) else None
            origin = "subagent" if parent_session or record.get("delegationDepth", 0) else "unknown"
            continue
        if kind not in {"user/message", "assistant/message"}:
            continue
        if session_id is None:
            raise ValueError("DeepSeek message before session header.")

        data = record.get("data") or {}
        message = data if kind == "user/message" else data.get("message") or {}
        role = message.get("role")
        if role != kind.partition("/")[0]:
            continue
        # The harness logs goal ticks, tool notifications and skill catalogs as
        # user-role messages. Only kind=user originated at the user interface.
        source = message.get("source") or {}
        if role == "user" and (not isinstance(source, dict) or source.get("kind") != "user"):
            continue
        text = text_blocks(message.get("content"), ("text",))
        if text:
            yield event("deepseek-harness", session_id, message["id"], role, text,
                        record.get("time"), workspace, origin=origin,
                        parent_session=parent_session, order=record.get("seq", line))

    if session_id is None:
        raise ValueError("Missing DeepSeek session header.")
