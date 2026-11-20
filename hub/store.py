"""SQLite-backed original events and editable memories with explicit evidence links."""

import hashlib
import json
import re
import sqlite3
import time
import unicodedata
import uuid
from contextlib import contextmanager
from pathlib import Path

from .contract import validate_event


class StoreError(ValueError):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


_MAX_EVENT_BYTES = 16 * 1024 * 1024
_SOURCE_NAMES = {"voice": "语音", "clipboard": "剪贴板", "ai_chat": "对话", "browser": "网页", "window": "窗口"}
_SALIENT = re.compile(
    r"决定|改为|改用|计划|偏好|需要|截止|待办|下一步|确认|错误|失败|放弃|取消|不再|"
    r"\b(decided?|prefer\w*|switched?|deadline|todo|next step|plan|agreed?|failed?|error|instead)\b", re.I
)
_TABLES = """
CREATE TABLE IF NOT EXISTS raw_events (
 id TEXT PRIMARY KEY, source TEXT NOT NULL, connector TEXT NOT NULL, source_id TEXT NOT NULL,
 event TEXT, searchable TEXT NOT NULL, tier TEXT NOT NULL, t_start INTEGER NOT NULL,
 revision INTEGER NOT NULL, dirty INTEGER NOT NULL, UNIQUE(source, connector, source_id)
);
CREATE INDEX IF NOT EXISTS raw_time ON raw_events(t_start DESC, id);
CREATE INDEX IF NOT EXISTS raw_dirty ON raw_events(dirty) WHERE dirty = 1;
CREATE TABLE IF NOT EXISTS memories (
 id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL, searchable TEXT NOT NULL,
 origin TEXT NOT NULL, group_key TEXT UNIQUE, revision INTEGER NOT NULL, needs_review INTEGER NOT NULL,
 deleted INTEGER NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS memory_time ON memories(updated_at DESC, id);
CREATE TABLE IF NOT EXISTS evidence (
 memory_id TEXT NOT NULL REFERENCES memories(id), raw_id TEXT NOT NULL REFERENCES raw_events(id),
 position INTEGER NOT NULL, PRIMARY KEY(memory_id, raw_id)
);
CREATE INDEX IF NOT EXISTS evidence_raw ON evidence(raw_id);
CREATE TABLE IF NOT EXISTS suppressed_evidence (raw_id TEXT PRIMARY KEY);
"""
_AGENT_MEMORY = """m.needs_review = 0 AND NOT EXISTS (
 SELECT 1 FROM evidence e JOIN raw_events r ON e.raw_id = r.id
 WHERE e.memory_id = m.id AND (r.tier = 'local_only' OR r.event IS NULL))"""


def _now():
    return time.time_ns() // 1000000


def _fold(text):
    return unicodedata.normalize("NFKC", text).casefold()


def _identifier(value, field):
    if field == "id" and value in (".", ".."):
        raise StoreError("ID cannot be a relative path component")
    if not isinstance(value, str) or not value or value != value.strip() or len(value) > 512 or not value.isprintable():
        raise StoreError("Invalid " + field)
    return value


def _json(value):
    try:
        encoded = json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":"))
        size = len(encoded.encode("utf-8"))
    except (TypeError, ValueError, OverflowError, RecursionError, UnicodeError) as exc:
        raise StoreError("Expected finite, UTF-8 JSON data") from exc
    if size > _MAX_EVENT_BYTES:
        raise StoreError("Event exceeds 16 MiB", 413)
    return encoded


def _revision(expected):
    if type(expected) is not int or expected < 1:
        raise StoreError("A positive expected_revision is required", 409)


def _check_revision(actual, expected):
    _revision(expected)
    if actual != expected:
        raise StoreError("Revision conflict", 409)


def _query(q, limit, offset):
    if not isinstance(q, str) or len(q) > 512:
        raise StoreError("Search query must be at most 512 characters")
    if type(limit) is not int or not 1 <= limit <= 200 or type(offset) is not int or offset < 0 or offset >= 2**63:
        raise StoreError("Invalid page size or offset")
    terms = _fold(q).split()
    if len(terms) > 32:
        raise StoreError("Too many search terms")
    return terms


def _text(value):
    return value.strip() if isinstance(value, str) else ""


def _short(text, maximum):
    return text if len(text) <= maximum else text[:maximum - 1].rstrip() + "…"


def _summary(event):
    """Build an extractive note. Only select observed words or explicitly named metadata."""
    source = event["source"]
    content, context = event.get("content", {}), event.get("context", {})
    fields = {
        "voice": ("text", "transcript", "summary"),
        "clipboard": ("text", "summary"),
        "ai_chat": ("text", "summary"),
        "browser": ("summary", "text"),
        "window": ("text", "summary"),
    }.get(source, ("text", "summary"))
    excerpts = [_text(part["text"]) for part in content.get("excerpts", [])]
    material = next((content[k] for k in fields if _text(content.get(k))), "") or "\n".join(filter(None, excerpts))
    title = _text(content.get("title")) or _text(context.get("window_title"))
    if material:
        # Use exact source text for grouping; case, punctuation and indentation can change meaning.
        clauses = [s.strip() for s in re.split(r"(?<=[。！？])|(?<=[.!?])\s+|[\r\n]+", material[:32000]) if s.strip()]
        if not clauses:
            clauses = [material]
        indices = sorted(range(len(clauses)), key=lambda i: (not bool(_SALIENT.search(clauses[i])), i))[:3]
        body = "\n".join(clauses[i] for i in sorted(indices))
        title = title or _short(clauses[indices[0]], 72)
        actor = _text(event.get("actor"))
        role = _text(content.get("role")) or _text(context.get("role"))
        # A quoted plan from an assistant should not appear to be a user's decision.
        if actor or role or source == "ai_chat":
            who = " / ".join(dict.fromkeys(filter(None, (actor, role)))) or "说话者未标注"
            label = _SOURCE_NAMES.get(source, source) + " · " + _short(who, 64)
            title = label + " · " + title
            body = label + " · " + body
        key_material = json.dumps([material, _text(content.get("title")), _text(context.get("window_title")),
                                   source if actor or role or source == "ai_chat" else "", actor, role],
                                  ensure_ascii=False, separators=(",", ":"))
    else:
        details = [title, _text(content.get("url_norm")), _text(context.get("app_bundle"))]
        details = list(dict.fromkeys(d for d in details if d))
        if not details:
            return None  # Keep the raw event, but avoid inventing content for an empty capture.
        title = title or details[0]
        body = _SOURCE_NAMES.get(source, source) + " · " + " / ".join(details)
        key_material = "metadata:" + event["id"]
    key = hashlib.sha256((event["privacy"]["tier"] + "\0" + key_material).encode("utf-8")).hexdigest()
    return _short(title, 160), _short(body, 900), key


class Store:
    def __init__(self, path):
        self.path = str(path)
        if self.path == ":memory:":
            raise StoreError("Store requires a database file")
        Path(self.path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self._transaction(None) as conn:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.executescript(_TABLES)

    @contextmanager
    def _transaction(self, write):
        conn = sqlite3.connect(self.path, timeout=15, isolation_level=None)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute("PRAGMA foreign_keys=ON")
            conn.execute("PRAGMA secure_delete=ON")
            if write is not None:
                conn.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            yield conn
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
        finally:
            conn.close()

    @staticmethod
    def _raw_dict(row):
        event = json.loads(row["event"])
        event["revision"] = row["revision"]
        return event

    @staticmethod
    def _raw_row(conn, raw_id, agent):
        row = conn.execute("SELECT * FROM raw_events WHERE id = ?", (_identifier(raw_id, "id"),)).fetchone()
        if not row or row["event"] is None or (agent and row["tier"] == "local_only"):
            raise StoreError("Raw event not found", 404)
        return row

    def get_raw(self, id, agent=False):
        with self._transaction(False) as conn:
            return self._raw_dict(self._raw_row(conn, id, agent))

    def list_raw(self, q="", limit=50, offset=0, agent=False):
        terms = _query(q, limit, offset)
        conditions = ["event IS NOT NULL"] + ["instr(searchable, ?) > 0"] * len(terms)
        if agent:
            conditions.append("tier != 'local_only'")
        query = "SELECT event, revision FROM raw_events WHERE " + " AND ".join(conditions) + " ORDER BY t_start DESC, id LIMIT ? OFFSET ?"
        with self._transaction(False) as conn:
            return [self._raw_dict(r) for r in conn.execute(query, (*terms, limit, offset))]

    def put_raw(self, event, expected_revision=None, agent=False):
        if not isinstance(event, dict):
            raise StoreError("Raw event must be an object")
        event = event.copy()
        event.pop("revision", None)
        encoded = _json(event)
        try:
            validate_event(event)
        except ValueError as exc:
            raise StoreError(str(exc)) from exc
        for field in ("t_start", "t_end", "t_observed"):
            if type(event[field]) is not int or not -(2**63) <= event[field] < 2**63:
                raise StoreError(field + " must be a signed 64-bit integer")
        event_id = _identifier(event["id"], "id")
        provenance = event["provenance"]
        identity = (_identifier(event["source"], "source"), _identifier(provenance["connector"], "connector"),
                    _identifier(provenance["source_id"], "source_id"))
        _identifier(event["kind"], "kind")
        if event["t_end"] < event["t_start"]:
            raise StoreError("t_end must be at or after t_start")
        tier = event["privacy"]["tier"]
        with self._transaction(True) as conn:
            row = conn.execute("SELECT * FROM raw_events WHERE source=? AND connector=? AND source_id=?", identity).fetchone()
            by_id = conn.execute("SELECT * FROM raw_events WHERE id=?", (event_id,)).fetchone()
            if agent and (tier == "local_only" or any(r is not None and r["tier"] == "local_only" for r in (row, by_id))):
                raise StoreError("Raw event unavailable", 404)
            if by_id is not None and (row is None or row["id"] != by_id["id"]):
                raise StoreError("Event ID belongs to another source record", 409)
            if row is None:
                if expected_revision is not None:
                    raise StoreError("Raw event not found", 404)
                conn.execute("INSERT INTO raw_events VALUES(?,?,?,?,?,?,?,?,1,1)",
                             (event_id, *identity, encoded, _fold(encoded), tier, event["t_start"]))
            else:
                if row["event"] is None:
                    raise StoreError("Source record was deleted", 410)
                if expected_revision is not None and event_id != row["id"]:
                    raise StoreError("Edit requires the canonical event ID", 409)
                event_id = row["id"]
                event["id"] = event_id
                previous = json.loads(row["event"])
                if expected_revision is None:
                    # Re-observing the same source record does not replace its original observed time.
                    equivalent = dict(event, t_observed=previous["t_observed"])
                    if row["event"] == _json(equivalent):
                        return self._raw_dict(row)
                    raise StoreError("Source record exists; provide its revision to edit", 409)
                _check_revision(row["revision"], expected_revision)
                if row["event"] == _json(event):
                    return self._raw_dict(row)
                if agent and tier != row["tier"]:
                    raise StoreError("Agent cannot change a privacy tier", 403)
                self._invalidate(conn, event_id, deleted=False)
                encoded = _json(event)
                conn.execute("UPDATE raw_events SET event=?, searchable=?, tier=?, t_start=?, revision=revision+1, dirty=1 WHERE id=?",
                             (encoded, _fold(encoded), tier, event["t_start"], event_id))
            return self._raw_dict(self._raw_row(conn, event_id, agent))

    def delete_raw(self, id, expected_revision, agent=False):
        with self._transaction(True) as conn:
            row = self._raw_row(conn, id, agent)
            _check_revision(row["revision"], expected_revision)
            self._invalidate(conn, id, deleted=True)
            conn.execute("UPDATE raw_events SET event=NULL, searchable='', dirty=0, revision=revision+1 WHERE id=?", (id,))
            return {"id": id, "deleted": True}

    @staticmethod
    def _memory_row(conn, memory_id, agent):
        sql = "SELECT m.* FROM memories m WHERE m.id=? AND m.deleted=0"
        if agent:
            sql += " AND " + _AGENT_MEMORY
        row = conn.execute(sql, (_identifier(memory_id, "id"),)).fetchone()
        if row is None:
            raise StoreError("Memory not found", 404)
        return row

    @staticmethod
    def _memory_dict(conn, row):
        ids = [r[0] for r in conn.execute("SELECT raw_id FROM evidence WHERE memory_id=? ORDER BY position,raw_id", (row["id"],))]
        return {**{k: row[k] for k in ("id", "title", "body", "revision", "origin", "created_at", "updated_at")},
                "evidence_ids": ids, "needs_review": bool(row["needs_review"])}

    def get_memory(self, id, agent=False):
        with self._transaction(False) as conn:
            return self._memory_dict(conn, self._memory_row(conn, id, agent))

    def list_memory(self, q="", limit=50, offset=0, agent=False):
        terms = _query(q, limit, offset)
        conditions = ["m.deleted=0"] + ["instr(m.searchable, ?) > 0"] * len(terms)
        if agent:
            conditions.append(_AGENT_MEMORY)
        sql = "SELECT m.* FROM memories m WHERE " + " AND ".join(conditions) + " ORDER BY m.updated_at DESC, m.id LIMIT ? OFFSET ?"
        with self._transaction(False) as conn:
            return [self._memory_dict(conn, row) for row in conn.execute(sql, (*terms, limit, offset))]

    @staticmethod
    def _retire(conn, record, suppress):
        if suppress and record["group_key"]:
            conn.execute("INSERT OR IGNORE INTO suppressed_evidence SELECT raw_id FROM evidence WHERE memory_id=?", (record["id"],))
        conn.execute("DELETE FROM evidence WHERE memory_id=?", (record["id"],))
        # Keep only the opaque identity for rejected retries. The original text is removed.
        group = record["group_key"] if suppress else None
        conn.execute("""UPDATE memories SET title='',body='',searchable='',group_key=?,deleted=1,revision=revision+1,
                     updated_at=? WHERE id=?""", (group, _now(), record["id"]))

    def _invalidate(self, conn, raw_id, deleted):
        records = conn.execute("SELECT m.* FROM memories m JOIN evidence e ON m.id=e.memory_id WHERE e.raw_id=?", (raw_id,)).fetchall()
        for row in records:
            if row["origin"] == "manual":
                if deleted:
                    self._retire(conn, row, suppress=True)
                else:
                    conn.execute("UPDATE memories SET needs_review=1,revision=revision+1,updated_at=? WHERE id=?", (_now(), row["id"]))
                continue
            conn.execute("DELETE FROM evidence WHERE memory_id=? AND raw_id=?", (row["id"], raw_id))
            remaining = conn.execute("""SELECT r.event FROM raw_events r JOIN evidence e ON r.id=e.raw_id
                                     WHERE e.memory_id=? ORDER BY e.position, r.id LIMIT 1""", (row["id"],)).fetchone()
            if remaining is None:
                self._retire(conn, row, suppress=False)
            else:
                title, body, _ = _summary(json.loads(remaining[0]))
                conn.execute("""UPDATE memories SET title=?, body=?, searchable=?, revision=revision+1,updated_at=? WHERE id=?""",
                             (title, body, _fold(title+"\n"+body), _now(), row["id"]))

    def save_memory(self, data, expected_revision=None, agent=False):
        if not isinstance(data, dict):
            raise StoreError("Memory must be an object")
        memory_id = _identifier(data["id"], "id") if "id" in data else str(uuid.uuid4())
        title, body = _text(data.get("title")), _text(data.get("body"))
        if not title or len(title) > 512 or not body or len(body) > 65536:
            raise StoreError("Memory requires a title (1–512 characters) and body (1–65536 characters)")
        _json([title, body])
        ids = data.get("evidence_ids")
        if not isinstance(ids, list) or not 1 <= len(ids) <= 256:
            raise StoreError("Memory requires 1–256 evidence IDs")
        ids = list(dict.fromkeys(_identifier(raw_id, "evidence id") for raw_id in ids))
        searchable = _fold(title+"\n"+body)
        with self._transaction(True) as conn:
            for raw_id in ids:
                self._raw_row(conn, raw_id, agent)
            row = conn.execute("SELECT * FROM memories WHERE id=?", (memory_id,)).fetchone()
            now = _now()
            if row is None:
                if expected_revision is not None:
                    raise StoreError("Memory not found", 404)
                conn.execute("""INSERT INTO memories VALUES(?,?,?,?,'manual',NULL,1,0,0,?,?)""",
                             (memory_id, title, body, searchable, now, now))
            else:
                row = self._memory_row(conn, memory_id, agent)
                _check_revision(row["revision"], expected_revision)
                if row["group_key"]:
                    conn.execute("INSERT OR IGNORE INTO suppressed_evidence SELECT raw_id FROM evidence WHERE memory_id=?", (memory_id,))
                conn.execute("DELETE FROM evidence WHERE memory_id=?", (memory_id,))
                conn.execute("""UPDATE memories SET title=?,body=?,searchable=?,origin='manual',needs_review=0,
                             revision=revision+1,updated_at=? WHERE id=?""", (title, body, searchable, now, memory_id))
            conn.executemany("INSERT INTO evidence VALUES(?,?,?)", [(memory_id, raw_id, i) for i, raw_id in enumerate(ids)])
            return self._memory_dict(conn, self._memory_row(conn, memory_id, agent))

    def delete_memory(self, id, expected_revision, agent=False):
        with self._transaction(True) as conn:
            row = self._memory_row(conn, id, agent)
            _check_revision(row["revision"], expected_revision)
            self._retire(conn, row, suppress=True)
            return {"id": id, "deleted": True}

    def extract(self):
        """Process only pending sources; navigation text is calculated entirely on this device."""
        counts = {"created": 0, "updated": 0, "skipped": 0}
        with self._transaction(True) as conn:
            # Snapshot IDs before clearing the dirty index. Load each potentially large payload on demand.
            pending = conn.execute("SELECT id FROM raw_events WHERE dirty=1 ORDER BY t_start,id").fetchall()
            for item in pending:
                raw_id = item["id"]
                raw = conn.execute("SELECT event FROM raw_events WHERE id=?", (raw_id,)).fetchone()
                conn.execute("UPDATE raw_events SET dirty=0 WHERE id=?", (raw_id,))
                generated = _summary(json.loads(raw["event"]))
                if not generated or conn.execute("SELECT 1 FROM suppressed_evidence WHERE raw_id=?", (raw_id,)).fetchone():
                    counts["skipped"] += 1
                    continue
                title, body, key = generated
                row = conn.execute("SELECT id,deleted,origin FROM memories WHERE group_key=?", (key,)).fetchone()
                now = _now()
                if row is None:
                    memory_id = str(uuid.uuid4())
                    conn.execute("INSERT INTO memories VALUES(?,?,?,?,'extracted',?,1,0,0,?,?)",
                                 (memory_id, title, body, _fold(title+"\n"+body), key, now, now))
                    counts["created"] += 1
                elif row["deleted"] or row["origin"] == "manual":
                    counts["skipped"] += 1
                    continue
                else:
                    memory_id = row["id"]
                    conn.execute("UPDATE memories SET revision=revision+1,updated_at=? WHERE id=?", (now, memory_id))
                    counts["updated"] += 1
                conn.execute("""INSERT INTO evidence SELECT ?, ?, COALESCE(MAX(position),-1)+1
                             FROM evidence WHERE memory_id=?""", (memory_id, raw_id, memory_id))
        return counts
