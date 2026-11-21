"""Record text visible in a user-selected WeChat message pane as local OCR evidence."""

import hashlib
import json
import math
import re

from .imports import stable_id
from .wechat_history import scope_value


_CURSOR = """CREATE TABLE IF NOT EXISTS wechat_ocr_cursors (
 episode TEXT PRIMARY KEY, observed_ms INTEGER NOT NULL, line_keys TEXT NOT NULL, raw_id TEXT
)"""


def _lines(frame):
    rows = frame.get("lines")
    if not isinstance(rows, list) or len(rows) > 512:
        raise ValueError("Expected at most 512 OCR lines from one viewport.")
    result = []
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("text"), str):
            raise ValueError("Expected OCR text and a normalized rectangle.")
        text = row["text"].strip()
        if not text:
            continue
        line = {"text": text}
        for field in ("x", "y", "width", "height", "confidence"):
            value = row.get(field)
            if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1:
                raise ValueError("Invalid normalized OCR coordinates or confidence.")
            line[field] = value
        if (line["width"] <= 0 or line["height"] <= 0 or line["x"] + line["width"] > 1.00001
                or line["y"] + line["height"] > 1.00001):
            raise ValueError("OCR line extends beyond the selected message pane.")
        result.append(line)
    return result


def _line_keys(episode, lines):
    # Preserve repeats, punctuation, and rough horizontal position. The y coordinate changes
    # as the viewport scrolls. Strong anchors may establish overlap but never identify a speaker.
    result = []
    for line in lines:
        material = json.dumps([episode, round(20 * line["x"]), line["text"]], ensure_ascii=False)
        digest = hashlib.sha256(material.encode()).hexdigest()
        result.append([digest, line["confidence"] >= 0.8])
    return result


def _count_sequence(rows, pattern):
    return sum(rows[i:i + len(pattern)] == pattern for i in range(len(rows) - len(pattern) + 1))


def _overlap(previous, current):
    """Return the first new visible line, or zero when alignment is uncertain."""
    old = [key for key, _ in previous]
    new = [key for key, _ in current]
    if _count_sequence(old, new):
        return len(new)
    overlap = 0
    for size in range(min(len(old), len(new)), 1, -1):
        shared = new[:size]
        if old[-size:] != shared:
            continue
        anchors = {key for (key, strong), (_, prev_strong) in zip(current[:size], previous[-size:])
                   if strong and prev_strong}
        if len(anchors) >= 2:
            if overlap or _count_sequence(old, shared) != 1 or _count_sequence(new, shared) != 1:
                return 0
            overlap = size
    return overlap


def observe_frame(store, frame, *, account, conversation, observed_ms, max_gap_ms=90_000):
    """Ingest one verified native helper result into a local Store. All times describe observation."""
    scope_value(account, "account namespace")
    scope_value(conversation, "conversation identifier")
    if type(observed_ms) is not int or not 0 <= observed_ms < 2**63:
        raise ValueError("Expected a nonnegative observation time in Unix milliseconds.")
    if type(max_gap_ms) is not int or max_gap_ms <= 0:
        raise ValueError("Expected a positive maximum gap in milliseconds.")
    if not isinstance(frame, dict) or frame.get("status") not in ("ok", "skipped"):
        raise ValueError("Unknown WeChat capture result.")
    episode = stable_id("wechat-conversation", account, conversation)
    lines = _lines(frame) if frame["status"] == "ok" else []
    keys = _line_keys(episode, lines)
    # Never persist pixels or a second copy of the text in a checkpoint. Both checkpoint
    # movement and the ordinary Hub validation/insert succeed or roll back together.
    with store._transaction(True) as conn:
        conn.execute(_CURSOR)
        previous = conn.execute("SELECT * FROM wechat_ocr_cursors WHERE episode=?", (episode,)).fetchone()
        if previous and observed_ms <= previous["observed_ms"]:
            return {"status": "skipped", "reason": "stale_observation"}
        continuous = previous is not None and observed_ms - previous["observed_ms"] <= max_gap_ms
        last_id = previous["raw_id"] if continuous else None
        if not lines:
            reason = frame.get("reason", "empty_pane")
            if not isinstance(reason, str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", reason):
                reason = "capture_unavailable"
            result = {"status": "skipped", "reason": reason}
            last_id = None
        else:
            basis = conn.execute("SELECT revision FROM raw_events WHERE id=?", (last_id,)).fetchone() if last_id else None
            old_keys = json.loads(previous["line_keys"]) if basis else []
            offset = _overlap(old_keys, keys)
            raw_id = stable_id("wechat-ocr-pane-v1", episode, [key for key, _ in keys])
            # A reappearing viewport may contain the same words from different messages.
            # Treat it as the same visible evidence; never count the number of messages.
            seen = conn.execute("SELECT revision FROM raw_events WHERE id=?", (raw_id,)).fetchone()
            if seen is not None:
                result = {"status": "unchanged"}
                if seen[0] > 1:
                    # Use its line hashes only to avoid reintroducing withdrawn text
                    # in the next viewport. A revised/tombstoned row cannot be evidence.
                    last_id = raw_id
                elif offset != len(lines):
                    # Seen globally, but this observation cannot establish continuity
                    # with an earlier epoch (e.g. A/B -> gap -> A/B -> A/B/C).
                    keys, last_id = [], None
            elif offset == len(lines):
                result = {"status": "unchanged"}
            else:
                mode = "unaligned_viewport" if old_keys else "baseline_viewport"
                if offset:
                    mode = "overlap_tail" if basis[0] == 1 else "tail_after_user_change"
                visible = lines[offset:]
                event = {
                    "id": raw_id, "episode_id": episode, "source": "wechat.ocr",
                    "kind": "visible_text_observation", "actor": "unknown",
                    "t_start": observed_ms, "t_end": observed_ms, "t_observed": observed_ms,
                    "context": {"account_namespace": account, "conversation_id": conversation,
                                "time_basis": "screen_observation", "coverage": "visible_message_pane"},
                    "content": {"text": "\n".join(line["text"] for line in visible),
                                "title": f"微信 OCR 可见文字 · {account} / {conversation}", "ocr_lines": visible},
                    "provenance": {"connector": "wechat-ocr", "version": "1", "source_id": raw_id,
                                   "observation_mode": mode, "overlap_lines": offset},
                    "privacy": {"tier": "local_only"},
                }
                if mode == "overlap_tail":
                    event["links"] = [{"target_id": last_id, "relation": "overlaps_observation"}]
                store._put_raw(conn, event)
                result = {"status": "created", "id": raw_id}
                last_id = raw_id
        conn.execute("""INSERT INTO wechat_ocr_cursors VALUES(?,?,?,?) ON CONFLICT(episode) DO UPDATE SET
                     observed_ms=excluded.observed_ms, line_keys=excluded.line_keys, raw_id=excluded.raw_id""",
                     (episode, observed_ms, json.dumps(keys, separators=(",", ":")), last_id))
        return result
