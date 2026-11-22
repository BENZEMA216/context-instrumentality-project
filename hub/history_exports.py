"""Export visible conversations from explicitly selected native stores to private JSON."""

import argparse
from collections import Counter, defaultdict
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import tempfile
from urllib.parse import unquote, urlsplit

from .history_sources import from_cwd, identifier, lines, participant_text


@contextmanager
def database(path):
    connection = sqlite3.connect(
        path.resolve(strict=True).as_uri() + "?mode=ro", uri=True
    )
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("BEGIN")
        yield connection
    finally:
        connection.close()


def project(value):
    if not isinstance(value, str) or not value:
        return None
    if value.startswith("file://"):
        uri = urlsplit(value)
        if uri.netloc in ("", "localhost"):
            value = unquote(uri.path)
    return from_cwd(value) or "project/" + hashlib.sha256(value.encode()).hexdigest()


def blocks(content, kind):
    if not isinstance(content, list):
        return ""
    return "\n".join(
        p["text"]
        for p in content
        if isinstance(p, dict)
        and p.get("type") == kind
        and isinstance(p.get("text"), str)
    )


def workbuddy_user(text):
    if re.match(r"\s*<(?:system-reminder|additional_data)(?=[\s>])", text):
        # The native client appends its own identity, project and system context.
        match = re.search(r"<user_query>(.*?)</user_query>\s*$", text, re.S)
        if not match:
            return ""
        return match.group(1).strip("\r\n")
    return text


def qclaw_user(text):
    # The transport prefixes human input with labeled, fenced JSON metadata.
    labels = (
        "Conversation info (untrusted metadata):",
        "Sender (untrusted metadata):",
        "Forwarded message context (untrusted metadata):",
    )
    while text.startswith(labels):
        label, _, rest = text.partition("\n")
        if label not in labels:
            break
        fence = chr(96) * 3
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


def session(provider, sid, workspace=None, parent=None):
    result = {
        "provider": provider,
        "session_id": identifier(sid),
        "project": project(workspace),
        "messages": [],
    }
    if parent:
        result["parent_session_id"] = identifier(parent)
    return result


def message(mid, role, text, timestamp, parent=None):
    data = {"id": identifier(mid), "role": role, "text": text, "timestamp": timestamp}
    if parent:
        data["parent_id"] = identifier(parent)
    return data


def attach_parents(messages, ancestry):
    visible = {item["id"] for item in messages}
    if len(visible) != len(messages):
        raise ValueError("Duplicate native visible message ID in a session.")
    for item in messages:
        parent = ancestry.get(item["id"])
        visited = {item["id"]}
        while parent and parent not in visible and parent not in visited:
            visited.add(parent)
            parent = ancestry.get(parent)
        if parent in visible and parent not in visited:
            item["parent_id"] = parent


def jsonl_session(provider, path, stats):
    is_wb = provider == "workbuddy"
    result, ancestors, messages = None, {}, []
    # A session spans hidden tool/reasoning nodes. Only their parent keys enter the graph.
    for _, obj in lines(path):
        tag, mid = obj.get("type"), obj.get("id")
        sid = obj.get("sessionId") if is_wb else (mid if tag == "session" else None)
        if sid:
            if result is not None and result["session_id"] != sid:
                raise ValueError("Conflicting session IDs in selected JSONL.")
            if result is None:
                result = session(
                    provider, sid, obj.get("cwd"), obj.get("parentSessionId")
                )
        if isinstance(mid, str):
            if mid in ancestors and ancestors[mid] != obj.get("parentId"):
                raise ValueError("Conflicting native message ancestry.")
            ancestors[mid] = obj.get("parentId")
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
            text = blocks(content, "input_text" if role == "user" else "output_text")
            if role == "user":
                text = workbuddy_user(text)
        else:
            text = content if isinstance(content, str) else blocks(content, "text")
            if role == "user":
                text = qclaw_user(text)
        if not text.strip() or not participant_text(role, text):
            continue
        timestamp = obj.get("timestamp")
        if timestamp is None:
            timestamp = visible.get("timestamp")
        messages.append(message(mid, role, text, timestamp))
    if result is None:
        stats["files_without_session_metadata"] += 1
        return None
    attach_parents(messages, ancestors)
    result["messages"] = messages
    return result


def workspace_map(path):
    links = defaultdict(set)
    if path:
        for marker in sorted(path.glob("*/workspace.json")):
            db = marker.with_name("state.vscdb")
            if marker.is_symlink() or not db.is_file() or db.is_symlink():
                continue
            meta = json.loads(marker.read_bytes())
            uri = meta.get("folder") or meta.get("workspace")
            if not uri:
                continue
            with database(db) as conn:
                row = conn.execute(
                    "SELECT value FROM ItemTable WHERE key='composer.composerData'"
                ).fetchone()
                if row:
                    for entry in json.loads(row[0]).get("allComposers", []):
                        if isinstance(entry, dict) and entry.get("composerId"):
                            links[entry["composerId"]].add(uri)
    return links


def cursor_sessions(path, workspaces, stats):
    links = workspace_map(workspaces)
    with database(path) as db:
        # Do not open detached bubbles, richText attachments, tool payloads or editor drafts.
        composers = db.execute("""
            SELECT key, json_extract(value,'$.composerId') sid,
              json_extract(value,'$.fullConversationHeadersOnly') headers,
              json_extract(value,'$.workspacePath') workspace,
              json_extract(value,'$.parentComposerId') parent,
              json_extract(value,'$.subComposerIds') children,
              json_extract(value,'$.subagentComposerIds') agents
            FROM cursorDiskKV WHERE key GLOB 'composerData:*' ORDER BY key""").fetchall()
        parents = defaultdict(set)
        for row in composers:
            for field in ("children", "agents"):
                for child in json.loads(row[field] or "[]"):
                    if isinstance(child, str):
                        parents[child].add(row["sid"])
        for row in composers:
            sid = identifier(row["sid"])
            if row["key"] != "composerData:" + sid:
                raise ValueError("Composer ID does not match its native key.")
            workspace = row["workspace"]
            if not workspace and len(links[sid]) == 1:
                workspace = next(iter(links[sid]))
            parent = row["parent"] or (
                next(iter(parents[sid])) if len(parents[sid]) == 1 else None
            )
            doc = session("cursor", sid, workspace, parent)
            seen, ancestry = set(), {}
            for header in json.loads(row["headers"] or "[]"):
                mid = header.get("bubbleId")
                if not isinstance(mid, str) or mid in seen:
                    continue
                seen.add(mid)
                bubble = db.execute(
                    """
                    SELECT json_extract(value,'$.bubbleId') id, json_extract(value,'$.type') role,
                      json_extract(value,'$.text') text, json_extract(value,'$.createdAt') ts,
                      json_extract(value,'$.parentBubbleId') parent, json_extract(value,'$.skipRendering') hidden,
                      json_extract(value,'$.isNudge') nudge, json_extract(value,'$.isSynthetic') synthetic
                    FROM cursorDiskKV WHERE key=?""",
                    ("bubbleId:" + sid + ":" + mid,),
                ).fetchone()
                if bubble is None:
                    stats["missing_header_bubbles"] += 1
                    continue
                if (
                    bubble["id"] != mid
                    or header.get("type", bubble["role"]) != bubble["role"]
                ):
                    raise ValueError("Conflicting Cursor bubble identity or role.")
                ancestry[mid] = bubble["parent"]
                role = {1: "user", 2: "assistant"}.get(bubble["role"])
                text = bubble["text"]
                if (
                    role
                    and isinstance(text, str)
                    and text.strip()
                    and not any(bubble[k] for k in ("hidden", "nudge", "synthetic"))
                    and participant_text(role, text)
                ):
                    doc["messages"].append(message(mid, role, text, bubble["ts"]))
            attach_parents(doc["messages"], ancestry)
            yield doc


def opencode_sessions(path):
    with database(path) as db:
        for sid, pid, directory, parent in db.execute(
            "SELECT id,project_id,directory,parent_id FROM session ORDER BY id"
        ):
            doc = session("opencode", sid, directory or pid, parent)
            ancestors = {}
            for mid, created, role, parent_id, ts, generated_summary in db.execute(
                """
                SELECT id,time_created,json_extract(data,'$.role'),json_extract(data,'$.parentID'),
                       json_extract(data,'$.time.created'),json_type(data,'$.summary')
                FROM message WHERE session_id=? ORDER BY time_created,id""",
                (sid,),
            ):
                ancestors[mid] = parent_id
                if role not in ("user", "assistant") or generated_summary == "true":
                    continue
                parts = db.execute(
                    """
                    SELECT json_extract(data,'$.text') FROM part WHERE session_id=? AND message_id=?
                    AND json_extract(data,'$.type')='text'
                    AND NOT coalesce(json_extract(data,'$.synthetic'),0)
                    AND NOT coalesce(json_extract(data,'$.ignored'),0)
                    ORDER BY time_created,id""",
                    (sid, mid),
                )
                text = "\n".join(v for (v,) in parts if isinstance(v, str))
                if text.strip() and participant_text(role, text):
                    doc["messages"].append(
                        message(mid, role, text, ts if ts is not None else created)
                    )
            attach_parents(doc["messages"], ancestors)
            yield doc


def export_native(provider, source, output, cursor_workspaces=None):
    source, output = Path(source), Path(output)
    if source.is_symlink() or not source.exists():
        raise ValueError("Expected an existing native source.")
    if cursor_workspaces and (
        provider != "cursor" or not Path(cursor_workspaces).is_dir()
    ):
        raise ValueError(
            "Select Cursor workspaceStorage together with a Cursor database."
        )
    if provider in ("workbuddy", "qclaw"):
        files = (
            [source]
            if source.is_file()
            else sorted(
                source.glob("*/*.jsonl" if provider == "workbuddy" else "*.jsonl")
            )
        )
        if not files:
            raise ValueError("No selected native JSONL files.")
    stats = Counter()
    if provider == "cursor":
        docs = cursor_sessions(
            source, Path(cursor_workspaces) if cursor_workspaces else None, stats
        )
    elif provider == "opencode":
        docs = opencode_sessions(source)
    elif provider in ("workbuddy", "qclaw"):
        docs = (jsonl_session(provider, f, stats) for f in files if not f.is_symlink())
    else:
        raise ValueError("Unknown provider.")
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    if (
        output.is_symlink()
        or output.stat().st_uid != os.getuid()
        or output.stat().st_mode & 0o077
    ):
        raise ValueError(
            "Choose a private output directory owned by the current user (0700)."
        )
    seen = {}
    for doc in docs:
        if doc is None:
            continue
        sid = doc["session_id"]
        filename = (
            sid
            if re.fullmatch(r"[A-Za-z0-9_-]{1,180}", sid)
            else hashlib.sha256(sid.encode()).hexdigest()
        )
        dest = output / (filename + ".json")
        if dest.is_symlink() or (
            dest.exists() and (not dest.is_file() or dest.stat().st_mode & 0o077)
        ):
            raise ValueError("Unsafe export destination.")
        payload = (
            json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n"
        ).encode()
        digest = hashlib.sha256(payload).digest()
        if sid in seen:
            if seen[sid] != digest:
                raise ValueError("Two source sessions share an ID but differ.")
            stats["duplicate_sessions"] += 1
            continue
        seen[sid] = digest
        with tempfile.NamedTemporaryFile(
            dir=output, prefix=".export-", delete=False
        ) as f:
            tmp = Path(f.name)
            try:
                f.write(payload)
                f.flush()
                os.fsync(f.fileno())
                f.close()
                os.replace(tmp, dest)
            finally:
                tmp.unlink(missing_ok=True)
        stats["sessions"] += 1
        stats["empty_sessions"] += not doc["messages"]
        stats["unknown_project"] += doc["project"] is None
        for item in doc["messages"]:
            stats[item["role"]] += 1
            stats["unknown_timestamp"] += item["timestamp"] is None
    return dict(stats)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "provider", choices=("cursor", "workbuddy", "opencode", "qclaw")
    )
    parser.add_argument("source", type=Path)
    parser.add_argument(
        "output", type=Path, help="Private directory dedicated to the selected provider"
    )
    parser.add_argument(
        "--cursor-workspaces",
        type=Path,
        help="Explicit Cursor workspaceStorage for project mapping",
    )
    args = parser.parse_args()
    print(
        json.dumps(
            export_native(
                args.provider, args.source, args.output, args.cursor_workspaces
            ),
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
