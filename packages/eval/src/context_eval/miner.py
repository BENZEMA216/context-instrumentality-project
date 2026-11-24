"""Privacy-safe local candidate miner for real Context Hub v2 SQLite databases."""

from __future__ import annotations

import json
import re
import sqlite3
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from context_hub.mcp_server import default_data_dir
from context_hub.models import now_ms

COLD_START_GAP_MS = 30 * 60 * 1000  # 30 minutes

_CORRECTION_FALLBACK_RE = re.compile(
    r"(?:不要再用|不要用|不要改|严禁|别再用|别用|搞错了|改错了|不是让你|之前说过|我说过|"
    r"已经定案|禁止修改|don['’]t\s+use|do\s+not\s+use|never\s+use|stop\s+using|"
    r"instead\s+of|we\s+already\s+decided|wrong\s+approach|do\s+not\s+modify)",
    re.I,
)


def default_eval_dir(data_dir: Path | None = None) -> Path:
    """Private local eval directory under Hub data_dir (never git-tracked)."""
    return (Path(data_dir) if data_dir is not None else default_data_dir()) / "eval"


def _open_readonly_hub(db_path: Path) -> sqlite3.Connection:
    resolved = db_path.expanduser().resolve()
    if not resolved.is_file():
        raise FileNotFoundError(f"Hub SQLite database not found: {resolved}")
    conn = sqlite3.connect(f"file:{resolved}?mode=ro", uri=True, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def _parse_event_json(raw_json: str | None) -> dict[str, Any]:
    if not raw_json:
        return {}
    try:
        parsed = json.loads(raw_json)
        return parsed if isinstance(parsed, dict) else {}
    except ValueError:
        return {}


def _extract_provider(connector: str, ctx: dict[str, Any]) -> str:
    prov = ctx.get("provider")
    if isinstance(prov, str) and prov.strip():
        return prov.strip().lower()
    if "/" in connector:
        return connector.split("/", 1)[1].strip().lower()
    return connector.strip().lower() or "unknown"


def _extract_session_id(row: sqlite3.Row, ctx: dict[str, Any]) -> str:
    sid = ctx.get("session_id")
    if isinstance(sid, str) and sid.strip():
        return sid.strip()
    if row["episode_id"]:
        return str(row["episode_id"])
    src_id = str(row["source_id"] or "")
    if ":" in src_id:
        return src_id.split(":", 1)[0]
    return str(row["id"])


def _has_user_correction_hint(ctx: dict[str, Any]) -> bool:
    hints = ctx.get("signal_hints")
    if isinstance(hints, list):
        return any(str(h).strip().lower() == "user_correction" for h in hints)
    if isinstance(hints, str):
        return "user_correction" in hints.lower()
    return False


@dataclass(slots=True)
class _SessionSummary:
    session_id: str
    project: str
    provider: str
    t_start: int
    t_end: int
    turn_count: int
    first_event_id: str
    first_user_event_id: str | None
    first_user_text: str
    first_user_tier: str
    anchor_count: int


def _count_anchors_by_event(conn: sqlite3.Connection) -> dict[str, int]:
    rows = conn.execute(
        "SELECT event_id, COUNT(*) AS cnt FROM event_anchors GROUP BY event_id"
    ).fetchall()
    return {str(r["event_id"]): int(r["cnt"]) for r in rows}


def _mine_cold_start(
    conn: sqlite3.Connection,
    anchor_counts: dict[str, int],
    *,
    redact: bool,
) -> list[dict[str, Any]]:
    rows = conn.execute(
        """SELECT id, connector, source_id, t_start, t_end, actor, project,
                  episode_id, privacy_tier, body_text, event_json
           FROM raw_events
           WHERE source = 'ai_chat' AND deleted = 0 AND project IS NOT NULL
           ORDER BY project ASC, t_start ASC, id ASC"""
    ).fetchall()

    grouped: dict[tuple[str, str], list[tuple[sqlite3.Row, dict[str, Any]]]] = defaultdict(list)
    for row in rows:
        payload = _parse_event_json(row["event_json"])
        ctx = payload.get("context") or {}
        if not isinstance(ctx, dict):
            ctx = {}
        sid = _extract_session_id(row, ctx)
        grouped[(str(row["project"]), sid)].append((row, ctx))

    by_project: dict[str, list[_SessionSummary]] = defaultdict(list)
    for (project, sid), items in grouped.items():
        items.sort(key=lambda pair: (int(pair[0]["t_start"]), str(pair[0]["id"])))
        first_row, first_ctx = items[0]
        provider = _extract_provider(str(first_row["connector"]), first_ctx)
        t_start = min(int(r["t_start"]) for r, _ in items)
        t_end = max(int(r["t_end"] or r["t_start"]) for r, _ in items)
        anchor_total = sum(anchor_counts.get(str(r["id"]), 0) for r, _ in items)

        first_user_id: str | None = None
        first_user_text = ""
        first_user_tier = str(first_row["privacy_tier"])
        for r, c in items:
            role = str(c.get("role") or "").lower()
            if r["actor"] == "self" or role == "user":
                first_user_id = str(r["id"])
                first_user_text = str(r["body_text"] or "")
                first_user_tier = str(r["privacy_tier"])
                break

        by_project[project].append(
            _SessionSummary(
                session_id=sid,
                project=project,
                provider=provider,
                t_start=t_start,
                t_end=t_end,
                turn_count=len(items),
                first_event_id=str(first_row["id"]),
                first_user_event_id=first_user_id,
                first_user_text=first_user_text,
                first_user_tier=first_user_tier,
                anchor_count=anchor_total,
            )
        )

    candidates: list[dict[str, Any]] = []
    for project, sessions in sorted(by_project.items()):
        sessions.sort(key=lambda s: s.t_start)
        prior_turns_accum = 0
        for idx in range(1, len(sessions)):
            prev = sessions[idx - 1]
            curr = sessions[idx]
            prior_turns_accum += prev.turn_count
            gap_ms = curr.t_start - prev.t_end
            provider_switched = curr.provider != prev.provider
            if gap_ms > COLD_START_GAP_MS or provider_switched:
                reason = (
                    "provider_switch_and_time_gap"
                    if (provider_switched and gap_ms > COLD_START_GAP_MS)
                    else ("provider_switch" if provider_switched else "time_gap_over_30m")
                )
                entry: dict[str, Any] = {
                    "candidate_id": f"mine_cs_{curr.first_user_event_id or curr.first_event_id}",
                    "dimension": "cold_start_continuation",
                    "project": project,
                    "cutoff_ms": curr.t_start,
                    "trigger_event_id": curr.first_user_event_id or curr.first_event_id,
                    "prior_session_id": prev.session_id,
                    "current_session_id": curr.session_id,
                    "provider_transition": f"{prev.provider}->{curr.provider}",
                    "gap_minutes": round(max(0, gap_ms) / 60_000.0, 1),
                    "trigger_reason": reason,
                    "prior_event_count": prior_turns_accum,
                    "anchor_count": prev.anchor_count + curr.anchor_count,
                    "redacted": redact,
                }
                if not redact:
                    entry["query_preview"] = (
                        "[local_only_omitted]"
                        if curr.first_user_tier == "local_only"
                        else curr.first_user_text[:280]
                    )
                candidates.append(entry)

    candidates.sort(key=lambda c: int(c["cutoff_ms"]), reverse=True)
    return candidates


def _mine_correction_avoidance(
    conn: sqlite3.Connection,
    anchor_counts: dict[str, int],
    *,
    redact: bool,
) -> list[dict[str, Any]]:
    rows = conn.execute(
        """SELECT id, connector, source_id, t_start, actor, project,
                  episode_id, privacy_tier, body_text, event_json
           FROM raw_events
           WHERE source = 'ai_chat' AND deleted = 0 AND project IS NOT NULL
           ORDER BY t_start DESC, id ASC"""
    ).fetchall()

    candidates: list[dict[str, Any]] = []
    for row in rows:
        payload = _parse_event_json(row["event_json"])
        ctx = payload.get("context") or {}
        if not isinstance(ctx, dict):
            ctx = {}
        role = str(ctx.get("role") or "").lower()
        if row["actor"] != "self" and role != "user":
            continue

        body = str(row["body_text"] or "")
        hint_match = _has_user_correction_hint(ctx)
        pattern_match = bool(_CORRECTION_FALLBACK_RE.search(body)) if not hint_match else False
        if not (hint_match or pattern_match):
            continue

        project = str(row["project"])
        t_start = int(row["t_start"])
        prior_count = int(
            conn.execute(
                """SELECT COUNT(*) FROM raw_events
                   WHERE project = ? AND deleted = 0 AND t_start < ?""",
                (project, t_start),
            ).fetchone()[0]
        )
        if prior_count <= 0:
            continue

        provider = _extract_provider(str(row["connector"]), ctx)
        entry: dict[str, Any] = {
            "candidate_id": f"mine_ca_{row['id']}",
            "dimension": "correction_avoidance",
            "project": project,
            "cutoff_ms": t_start,
            "trigger_event_id": str(row["id"]),
            "session_id": _extract_session_id(row, ctx),
            "provider": provider,
            "signal_source": "signal_hints" if hint_match else "pattern_fallback",
            "prior_event_count": prior_count,
            "anchor_count": anchor_counts.get(str(row["id"]), 0),
            "redacted": redact,
        }
        if not redact:
            entry["turn_preview"] = (
                "[local_only_omitted]" if row["privacy_tier"] == "local_only" else body[:280]
            )
        candidates.append(entry)

    return candidates


def _mine_bitemporal_supersession(
    conn: sqlite3.Connection,
    anchor_counts: dict[str, int],
    *,
    redact: bool,
) -> list[dict[str, Any]]:
    rows = conn.execute(
        """SELECT * FROM decisions
           WHERE status = 'superseded' OR superseded_by IS NOT NULL
           ORDER BY COALESCE(invalid_at, updated_at) DESC, valid_at DESC"""
    ).fetchall()

    candidates: list[dict[str, Any]] = []
    for old_row in rows:
        new_row = (
            conn.execute(
                "SELECT * FROM decisions WHERE id = ?", (old_row["superseded_by"],)
            ).fetchone()
            if old_row["superseded_by"]
            else None
        )
        dec_ids = [str(old_row["id"])] + ([str(new_row["id"])] if new_row else [])
        ph = ",".join("?" for _ in dec_ids)
        ev_ids = [
            str(r[0])
            for r in conn.execute(
                f"SELECT DISTINCT raw_id FROM decision_evidence WHERE decision_id IN ({ph})",
                dec_ids,
            ).fetchall()
        ]
        anchor_total = sum(anchor_counts.get(eid, 0) for eid in ev_ids)

        cutoff_ms = (
            int(new_row["valid_at"]) + 1
            if new_row is not None
            else int(old_row["invalid_at"] or old_row["updated_at"]) + 1
        )
        entry: dict[str, Any] = {
            "candidate_id": f"mine_bt_{old_row['id']}",
            "dimension": "bitemporal_supersession",
            "project": str(old_row["project"]),
            "cutoff_ms": cutoff_ms,
            "old_decision_id": str(old_row["id"]),
            "new_decision_id": str(new_row["id"]) if new_row is not None else None,
            "old_valid_at": int(old_row["valid_at"]),
            "invalid_at": int(old_row["invalid_at"]) if old_row["invalid_at"] is not None else None,
            "new_valid_at": int(new_row["valid_at"]) if new_row is not None else None,
            "evidence_count": len(ev_ids),
            "anchor_count": anchor_total,
            "redacted": redact,
        }
        if not redact:
            old_private = old_row["privacy_tier"] == "local_only"
            new_private = new_row is not None and new_row["privacy_tier"] == "local_only"
            entry["topic"] = "[local_only_omitted]" if old_private else str(old_row["topic"])
            entry["old_statement_preview"] = (
                "[local_only_omitted]" if old_private else str(old_row["statement"])[:240]
            )
            if new_row is not None:
                entry["new_statement_preview"] = (
                    "[local_only_omitted]" if new_private else str(new_row["statement"])[:240]
                )
        candidates.append(entry)

    return candidates


def _balanced_take(
    buckets: list[list[dict[str, Any]]],
    limit: int,
) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    cursors = [0] * len(buckets)
    while len(selected) < limit:
        progressed = False
        for idx, bucket in enumerate(buckets):
            if cursors[idx] < len(bucket):
                selected.append(bucket[cursors[idx]])
                cursors[idx] += 1
                progressed = True
                if len(selected) >= limit:
                    break
        if not progressed:
            break
    return selected


def mine_candidates(
    data_dir: Path | None = None,
    *,
    limit: int = 30,
    redact: bool = True,
    out_path: Path | None = None,
) -> dict[str, Any]:
    """Read-only miner discovering real benchmark candidates from a local Context Hub DB."""
    base_dir = Path(data_dir) if data_dir is not None else default_data_dir()
    db_path = base_dir / "hub.sqlite3"
    limit = max(1, min(limit, 500))

    conn = _open_readonly_hub(db_path)
    try:
        anchor_counts = _count_anchors_by_event(conn)
        cs = _mine_cold_start(conn, anchor_counts, redact=redact)
        ca = _mine_correction_avoidance(conn, anchor_counts, redact=redact)
        bt = _mine_bitemporal_supersession(conn, anchor_counts, redact=redact)
    finally:
        conn.close()

    selected = _balanced_take([cs, ca, bt], limit)
    counts_by_dim = {
        "cold_start_continuation": sum(
            1 for c in selected if c["dimension"] == "cold_start_continuation"
        ),
        "correction_avoidance": sum(
            1 for c in selected if c["dimension"] == "correction_avoidance"
        ),
        "bitemporal_supersession": sum(
            1 for c in selected if c["dimension"] == "bitemporal_supersession"
        ),
    }

    payload: dict[str, Any] = {
        "schema_version": "reflexive-mined-candidates-v1",
        "generated_at_ms": now_ms(),
        "source_db": str(db_path.expanduser().resolve()),
        "redacted": redact,
        "privacy_notice": (
            "Metadata-only redacted skeleton (no raw transcript text)."
            if redact
            else "LOCAL PRIVATE EXPORT — contains non-local_only text previews; NEVER commit to git!"
        ),
        "discovered_totals": {
            "cold_start_continuation": len(cs),
            "correction_avoidance": len(ca),
            "bitemporal_supersession": len(bt),
        },
        "exported_counts": counts_by_dim,
        "exported_total": len(selected),
        "candidates": selected,
    }

    if out_path is not None:
        target = Path(out_path).expanduser()
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        payload["output_path"] = str(target)

    return payload
