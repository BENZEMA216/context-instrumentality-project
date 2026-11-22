"""Import selected conversation histories and inspect their local, evidence-backed memories."""
import argparse
import json
import os
import re
from pathlib import Path
import sys
import tempfile
from time import time_ns

from .history_sources import rows
from .store import Store


def import_one(store, path, source, project=None, update_existing=False):
    counts = dict(created=0, unchanged=0, updated=0, tombstones=0)
    before = path.stat()
    if not path.is_file():
        raise ValueError("Expected a regular exported conversation file.")
    # Large compressed rollouts are slow to decode. Stage visible turns privately
    # before acquiring the SQLite write lock; malformed/partial files never commit.
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as staged:
        for row in rows(path, source, project):
            staged.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + "\n")
        after = path.stat()
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError("The source changed during the import; retry its new snapshot.")
        staged.seek(0)
        with store._transaction(True) as conn:
            for encoded in staged:
                row = json.loads(encoded)
                prior = conn.execute("SELECT event,revision FROM raw_events WHERE id=?", (row["id"],)).fetchone()
                if prior is not None:
                    if prior["event"] is None:
                        counts["tombstones"] += 1
                        continue
                    previous = json.loads(prior["event"])
                    # Preserve observation time. Replaying private source history must never silently
                    # overwrite a subsequent privacy grant or a manual correction.
                    row["t_observed"] = previous["t_observed"]
                    if previous == row:
                        counts["unchanged"] += 1
                        continue
                    if not update_existing:
                        raise ValueError("Existing turn differs; review before --update-existing.")
                    store._put_raw(conn, row, expected_revision=prior["revision"])
                    counts["updated"] += 1
                else:
                    row["t_observed"] = time_ns() // 1_000_000
                    store._put_raw(conn, row)
                    counts["created"] += 1
    return counts


_HISTORY = "source='ai_chat' AND substr(connector,1,13)='chat-history/' AND event IS NOT NULL"


def sessions(store, project=None):
    sql = """SELECT json_extract(event,'$.episode_id') episode, connector,
             json_extract(event,'$.context.project') project, json_extract(event,'$.context.origin') origin,
             count(*) turns,
             count(CASE WHEN json_extract(event,'$.context.timestamp_status')='missing' THEN 1 END) unknown_times,
             min(CASE WHEN json_extract(event,'$.context.timestamp_status') IS NOT 'missing' THEN t_start END) first_ms,
             max(CASE WHEN json_extract(event,'$.context.timestamp_status') IS NOT 'missing' THEN t_start END) last_ms FROM raw_events WHERE """ + _HISTORY
    params = ()
    if project:
        sql += " AND json_extract(event,'$.context.project')=?"
        params = (project,)
    sql += " GROUP BY episode,connector,project,origin ORDER BY last_ms DESC,episode"
    with store._transaction(False) as conn:
        return [dict(r) for r in conn.execute(sql, params)]


def brief(store, session, limit=30, offset=0):
    if not 1 <= limit <= 500 or offset < 0:
        raise ValueError("Expected limit 1–500 and nonnegative offset.")
    sql = """SELECT id,event,revision FROM raw_events WHERE """ + _HISTORY + """
             AND json_extract(event,'$.episode_id')=?
             ORDER BY json_extract(event,'$.context.timestamp_status') IS 'missing',
             t_start,json_extract(event,'$.context.source_order'),id LIMIT ? OFFSET ?"""
    with store._transaction(False) as conn:
        turns = []
        for r in conn.execute(sql, (session, limit, offset)):
            raw = json.loads(r["event"])
            memories = conn.execute("""SELECT m.id,m.body,m.needs_review FROM memories m JOIN evidence e
                ON m.id=e.memory_id WHERE e.raw_id=? AND m.deleted=0 ORDER BY m.id""", (r["id"],))
            when = None if raw["context"].get("timestamp_status") == "missing" else raw["t_start"]
            turns.append({"at_ms": when, "role": raw["content"]["role"], "raw_id": r["id"],
                          "revision": r["revision"], "locator": raw["provenance"]["locator"],
                          "parents": [v["target_id"] for v in raw.get("links", []) if v["relation"] == "reply_to"],
                          "memories": [dict(m) for m in memories]})
        return turns


_CHANGE = re.compile(r"改为|改成|改用|更正|纠正|撤回|取消|不再|取代|放弃|"
                     r"\b(?:instead|replace|withdraw|cancel|supersede|switche?d?)\b", re.I)
_REQUEST = re.compile(r"决定|希望|请|我想|我要|需要|计划|确认|偏好|\b(?:want|need|please|prefer|decid\w*)\b", re.I)
_REPORT = re.compile(r"已完成|已验证|已更新|已测试|失败|报错|尚未|"
                     r"\b(?:verified|tested|completed|failed|blocked)\b", re.I)


def digest(store, project=None, session=None, limit=5, origin=None):
    """Build bounded, attributed excerpts for each category, with exact evidence pointers."""
    if not 1 <= limit <= 100 or bool(project) == bool(session):
        raise ValueError("Choose one project or session and a per-category limit between 1 and 100.")
    # SQLite can use the expression index only when the JSON path is a literal.
    scope_column = "json_extract(r.event,'$.context.project')" if project else "json_extract(r.event,'$.episode_id')"
    sql = """SELECT r.id,CASE WHEN json_extract(r.event,'$.context.timestamp_status') IS NOT 'missing'
             THEN r.t_start END t_start,r.connector,r.revision,json_extract(r.event,'$.content.role') role,
             json_extract(r.event,'$.episode_id') episode,json_extract(r.event,'$.provenance.locator') locator,
             m.id memory_id,m.body FROM raw_events r JOIN evidence e ON e.raw_id=r.id
             JOIN memories m ON e.memory_id=m.id
             WHERE r.source='ai_chat' AND substr(r.connector,1,13)='chat-history/' AND r.event IS NOT NULL
             AND m.deleted=0 AND m.needs_review=0 AND m.origin='extracted' AND """ + scope_column + "=?"
    params = [project or session]
    if origin:
        sql += " AND json_extract(r.event,'$.context.origin')=?"
        params.append(origin)
    sql += " ORDER BY t_start DESC,r.id,e.memory_id"
    groups = {k: [] for k in ("user_change_mentions","user_requests","other_user_turns",
                              "assistant_progress_reports","other_assistant_turns")}
    totals = dict.fromkeys(groups, 0)
    with store._transaction(False) as conn:
        for row in conn.execute(sql, params):
            if row["role"] == "user":
                if _CHANGE.search(row["body"]):
                    category = "user_change_mentions"
                elif _REQUEST.search(row["body"]):
                    category = "user_requests"
                else:
                    category = "other_user_turns"
            else:
                category = "assistant_progress_reports" if _REPORT.search(row["body"]) else "other_assistant_turns"
            totals[category] += 1
            if len(groups[category]) < limit:
                groups[category].append(dict(row))
    return {"project": project, "episode": session, "origin_filter": origin,
            "matched": totals, "recent_evidence": groups}


def versions(store, raw_id):
    with store._transaction(False) as conn:
        raw = store._raw_row(conn, raw_id, agent=False)
        if not raw["connector"].startswith("chat-history/"):
            raise ValueError("Expected a chat-history Raw.")
        old = conn.execute("SELECT revision,event FROM chat_history_versions WHERE raw_id=? ORDER BY revision", (raw_id,))
        return [dict(revision=v["revision"], text=json.loads(v["event"])["content"]["text"]) for v in [*old, raw]]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    imp = sub.add_parser("import", help="Import each complete file in a local transaction")
    imp.add_argument("--source", choices=("codex", "claude", "gemini", "chatgpt", "claude-web", "deepseek", "transcript"), required=True)
    imp.add_argument("files", type=Path, nargs="*")
    imp.add_argument("--files-from", help="Read one path per line, or - for stdin")
    imp.add_argument("--project", help="Explicit project key for this selection")
    imp.add_argument("--update-existing", action="store_true")
    imp.add_argument("--keep-going", action="store_true", help="Continue with the next file after a rejected file")
    imp.add_argument("--defer-memory", action="store_true", help="Run extract once after several import jobs")
    extract = sub.add_parser("extract")
    session = sub.add_parser("sessions", help="List project, provider, origin, episode and counts")
    session.add_argument("--project")
    summary = sub.add_parser("brief", help="Read local Memory excerpts and Raw locators for an episode")
    summary.add_argument("--session", required=True, help="Episode key from sessions")
    summary.add_argument("--limit", type=int, default=30)
    summary.add_argument("--offset", type=int, default=0)
    digest_cmd = sub.add_parser("digest", help="Build an attributed local digest from extracted Memories")
    scope = digest_cmd.add_mutually_exclusive_group(required=True)
    scope.add_argument("--session", help="Episode key from sessions")
    scope.add_argument("--project")
    digest_cmd.add_argument("--limit", type=int, default=5, help="Excerpts per category")
    digest_cmd.add_argument("--origin", choices=("user", "automation", "subagent", "unknown"))
    revision = sub.add_parser("versions", help="Show owner-only prior versions of a turn")
    revision.add_argument("--raw", required=True)
    for cmd in (imp, extract, session, summary, digest_cmd, revision):
        cmd.add_argument("--database", type=Path, required=True, help="Local owner-selected SQLite path")
    args = parser.parse_args(argv)
    os.umask(0o077)
    store = Store(args.database)
    if args.command == "import":
        files = list(args.files)
        if args.files_from:
            lines = sys.stdin.read() if args.files_from == "-" else Path(args.files_from).read_text(encoding="utf-8")
            files.extend(Path(line) for line in lines.splitlines() if line)
        if not files:
            parser.error("Select files or supply --files-from.")
        results = dict(files=0, empty_files=0, rejected=0, created=0, updated=0, unchanged=0, tombstones=0)
        for number, path in enumerate(files, 1):
            try:
                counts = import_one(store, path, args.source, args.project, args.update_existing)
            except (OSError, ValueError, KeyError, TypeError, AttributeError, OverflowError) as exc:
                results["rejected"] += 1
                # Third-party parsers and file exceptions may embed source values or paths.
                print(f"Input {number} rejected ({type(exc).__name__}); no changes from this file.", file=sys.stderr)
                if not args.keep_going:
                    break
                continue
            results["files"] += 1
            results["empty_files"] += int(not any(counts.values()))
            for key, value in counts.items():
                results[key] += value
        if not args.defer_memory:
            results["extraction"] = store.extract()
        print(json.dumps(results))
        return int(bool(results["rejected"]))
    if args.command == "extract":
        result = store.extract()
    elif args.command == "sessions":
        result = sessions(store, args.project)
    elif args.command == "brief":
        result = brief(store, args.session, args.limit, args.offset)
    elif args.command == "digest":
        result = digest(store, args.project, args.session, args.limit, args.origin)
    else:
        result = versions(store, args.raw)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
