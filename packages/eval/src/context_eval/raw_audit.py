"""Raw Data Integrity & Agent Consumption Readiness Gate for Raw Memory.

Verifies BEFORE memory curation that real raw data is trustworthy, noise-free,
privacy-bounded, and genuinely consumable by Agents via Raw Memory's retrieval APIs.
Never prints or emits private user text — reports aggregate metrics and pass/fail gates only.
"""

from __future__ import annotations

import json
import sqlite3
import time
from collections import Counter
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field

from context_hub.models import now_ms
from context_hub.store import HubStore

_LEAKED_ENVELOPE_PREFIXES = (
    "<USER_REQUEST>",
    "<ADDITIONAL_METADATA>",
    "<CONTEXT_SUMMARY>",
    "<SYSTEM_MESSAGE>",
    "<context_hub_memory>",
    "<context_pack>",
    "<memory_index>",
    "<heartbeat>",
    "<task-notification>",
    "<external_codex_apps_open_page>",
    "<in-app-browser-context>",
)


class GateCheck(BaseModel):
    name: str
    passed: bool
    value: Any
    target: str
    detail: str = ""


class RawAuditReport(BaseModel):
    data_dir: str
    audited_at_ms: int
    ready_for_curation: bool
    checks: list[GateCheck] = Field(default_factory=list)
    storage: dict[str, Any] = Field(default_factory=dict)
    signal_hygiene: dict[str, Any] = Field(default_factory=dict)
    privacy: dict[str, Any] = Field(default_factory=dict)
    consumption: dict[str, Any] = Field(default_factory=dict)


def audit_raw_data(data_dir: Path, *, probe_query: str | None = None) -> RawAuditReport:
    """Run all 4 Raw Data readiness gates against a local Raw Memory data directory."""
    root = Path(data_dir).expanduser()
    db_path = root / "hub.sqlite3"
    if not db_path.is_file():
        return RawAuditReport(
            data_dir=str(root),
            audited_at_ms=now_ms(),
            ready_for_curation=False,
            checks=[
                GateCheck(
                    name="db_exists",
                    passed=False,
                    value=False,
                    target="True",
                    detail=f"Missing {db_path}",
                )
            ],
        )

    store = HubStore(root)
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        # ---------------- Gate 1: Storage & Index Integrity ----------------
        total_raw = conn.execute(
            "SELECT COUNT(*) FROM raw_events WHERE deleted = 0"
        ).fetchone()[0]
        by_source = dict(
            conn.execute(
                "SELECT source, COUNT(*) FROM raw_events WHERE deleted = 0 "
                "GROUP BY source ORDER BY COUNT(*) DESC"
            ).fetchall()
        )
        by_connector = dict(
            conn.execute(
                "SELECT connector, COUNT(*) FROM raw_events WHERE deleted = 0 "
                "GROUP BY connector ORDER BY COUNT(*) DESC"
            ).fetchall()
        )
        fts_rows = conn.execute("SELECT COUNT(*) FROM raw_fts").fetchone()[0]
        active_ids = {
            r[0] for r in conn.execute("SELECT id FROM raw_events WHERE deleted = 0").fetchall()
        }
        indexed_ids = {r[0] for r in conn.execute("SELECT raw_id FROM raw_fts").fetchall()}
        unindexed_raw = len(active_ids - indexed_ids)
        duplicate_source_keys = conn.execute(
            """SELECT COUNT(*) FROM (
                   SELECT source, connector, source_id
                   FROM raw_events WHERE deleted = 0
                   GROUP BY source, connector, source_id
                   HAVING COUNT(*) > 1
               )"""
        ).fetchone()[0]

        future_horizon_ms = now_ms() + 24 * 3600 * 1000
        bad_timestamps = conn.execute(
            "SELECT COUNT(*) FROM raw_events WHERE deleted = 0 AND (t_start <= 0 OR t_start > ?)",
            (future_horizon_ms,),
        ).fetchone()[0]
        empty_bodies = conn.execute(
            "SELECT COUNT(*) FROM raw_events WHERE deleted = 0 "
            "AND LENGTH(TRIM(COALESCE(body_text, ''))) = 0"
        ).fetchone()[0]

        blob_refs = [
            r[0]
            for r in conn.execute(
                "SELECT DISTINCT body_blob_sha256 FROM raw_events "
                "WHERE deleted = 0 AND body_blob_sha256 IS NOT NULL AND body_blob_sha256 != ''"
            ).fetchall()
        ]
        missing_blobs = sum(1 for sha in blob_refs if not store.blobs.has_blob(sha))

        raw_log_files = list((root / "raw").rglob("*.jsonl")) if (root / "raw").is_dir() else []
        raw_log_lines = sum(sum(1 for ln in p.open("rb") if ln.strip()) for p in raw_log_files)
        l0_parity_ok = raw_log_lines >= total_raw if raw_log_files else total_raw == 0

        episodes_by_status = dict(
            conn.execute("SELECT status, COUNT(*) FROM episodes GROUP BY status").fetchall()
        )
        links_total = conn.execute("SELECT COUNT(*) FROM links").fetchone()[0]
        cross_channel_links = conn.execute(
            """SELECT COUNT(*) FROM links l
               JOIN raw_events a ON a.id = l.src_id
               JOIN raw_events b ON b.id = l.dst_id
               WHERE a.source != b.source"""
        ).fetchone()[0]

        # ---------------- Gate 2: Signal Hygiene & Anti-Echo ----------------
        ai_chat_total = 0
        leaked_envelopes = 0
        reflexive_filtered = 0
        subagent_turns = 0
        signal_hints: Counter[str] = Counter()
        for row in conn.execute(
            "SELECT body_text, event_json FROM raw_events WHERE source = 'ai_chat' AND deleted = 0"
        ):
            ai_chat_total += 1
            stripped = (row["body_text"] or "").lstrip()
            if stripped.startswith(_LEAKED_ENVELOPE_PREFIXES):
                leaked_envelopes += 1
            ctx = (json.loads(row["event_json"] or "{}")).get("context") or {}
            if ctx.get("reflexive_filtered"):
                reflexive_filtered += 1
            if ctx.get("is_subagent"):
                subagent_turns += 1
            for hint in ctx.get("signal_hints") or []:
                signal_hints[str(hint)] += 1

        leaked_envelope_rate = round(leaked_envelopes / ai_chat_total, 4) if ai_chat_total else 0.0

        # ---------------- Gate 3: Privacy Boundary ----------------
        local_only_ids = [
            r[0]
            for r in conn.execute(
                "SELECT id FROM raw_events WHERE deleted = 0 AND privacy_tier = 'local_only'"
            ).fetchall()
        ]
        local_only_set = set(local_only_ids)
        privacy_tiers = dict(
            conn.execute(
                "SELECT privacy_tier, COUNT(*) FROM raw_events WHERE deleted = 0 "
                "GROUP BY privacy_tier"
            ).fetchall()
        )

        # Pick an objective non-private probe query from top anchor/project token if none passed
        chosen_query = probe_query
        if not chosen_query:
            anchor_row = conn.execute(
                """SELECT ea.anchor FROM event_anchors ea
                   JOIN raw_events r ON r.id = ea.event_id
                   WHERE r.deleted = 0 AND r.privacy_tier != 'local_only'
                     AND (ea.anchor LIKE 'project:%' OR ea.anchor LIKE 'repo:%')
                   GROUP BY ea.anchor ORDER BY COUNT(*) DESC LIMIT 1"""
            ).fetchone()
            if anchor_row:
                chosen_query = str(anchor_row[0]).split(":", 1)[1].split("/")[-1]
            else:
                chosen_query = "memory"

        # ---------------- Gate 4: Live Agent Consumption Smoke ----------------
        t0 = time.perf_counter()
        now_view = store.what_was_i_doing(minutes=24 * 60, agent=True, max_tokens=1500)
        now_ms_lat = round((time.perf_counter() - t0) * 1000.0, 2)

        t0 = time.perf_counter()
        pack = store.get_context_pack(
            query=chosen_query,
            minutes=24 * 60,
            max_tokens=2000,
            agent=True,
        )
        pack_ms_lat = round((time.perf_counter() - t0) * 1000.0, 2)

        t0 = time.perf_counter()
        searched = store.search_context(chosen_query, limit=10, agent=True)
        search_ms_lat = round((time.perf_counter() - t0) * 1000.0, 2)

        t0 = time.perf_counter()
        queue = store.get_curation_queue(limit=5, include_local_only=False)
        queue_ms_lat = round((time.perf_counter() - t0) * 1000.0, 2)

        # Verify expand(level='raw') works on a shareable event
        sample_shareable = conn.execute(
            "SELECT id FROM raw_events WHERE deleted = 0 AND privacy_tier != 'local_only' "
            "ORDER BY t_start DESC LIMIT 1"
        ).fetchone()
        expand_ok = True
        expand_ms_lat = 0.0
        if sample_shareable:
            t0 = time.perf_counter()
            expanded = store.expand(sample_shareable[0], kind="raw", level="raw", agent=True)
            expand_ms_lat = round((time.perf_counter() - t0) * 1000.0, 2)
            rec = expanded.get("record") if isinstance(expanded, dict) else None
            expand_ok = bool(isinstance(rec, dict) and rec.get("id") == sample_shareable[0])

        # Verify local_only is strictly blocked across ALL agent=True entrypoints
        local_only_expand_blocked = True
        if local_only_ids:
            try:
                store.expand(local_only_ids[0], kind="raw", level="raw", agent=True)
                local_only_expand_blocked = False
            except Exception:
                local_only_expand_blocked = True

        leaked_pack = sum(
            1 for r in (pack.get("raw_evidence") or []) if r.get("id") in local_only_set
        )
        leaked_search = sum(
            1 for r in (searched.get("raw_matches") or []) if r.get("id") in local_only_set
        )
        leaked_queue = sum(
            1
            for item in (queue.get("items") or [])
            for ev in (item.get("events") or [])
            if ev.get("id") in local_only_set
        )
        total_privacy_leaks = (
            leaked_pack + leaked_search + leaked_queue + (0 if local_only_expand_blocked else 1)
        )

        # Verify get_context_pack surfaces direct evidence when search_context matches raw events
        search_raw_hits = len(searched.get("raw_matches") or [])
        pack_raw_hits = len(pack.get("raw_evidence") or [])
        pack_has_consumable_content = bool(
            pack.get("active_decisions")
            or pack.get("memories")
            or pack.get("episodes")
            or pack_raw_hits > 0
        )
        pack_raw_wiring_ok = (search_raw_hits == 0) or (
            pack_raw_hits > 0 or bool(pack.get("active_decisions"))
        )
        pack_within_budget = int(pack.get("approx_tokens") or 0) <= int(pack.get("max_tokens") or 2000) + 120
        pending_total = int(queue.get("total_pending") or 0)
        queue_returned = len(queue.get("items") or [])
        queue_ok = (pending_total == 0) or (queue_returned > 0)
    finally:
        conn.close()

    checks = [
        GateCheck(
            name="non_empty_raw_store",
            passed=total_raw > 0,
            value=total_raw,
            target="> 0",
        ),
        GateCheck(
            name="l0_l1_parity",
            passed=l0_parity_ok,
            value=f"L0={raw_log_lines} / L1={total_raw}",
            target="L0 >= L1",
        ),
        GateCheck(
            name="fts5_full_coverage",
            passed=unindexed_raw == 0 and fts_rows >= total_raw,
            value=f"unindexed={unindexed_raw}, fts_rows={fts_rows}",
            target="unindexed == 0",
        ),
        GateCheck(
            name="zero_duplicates",
            passed=duplicate_source_keys == 0,
            value=duplicate_source_keys,
            target="0",
        ),
        GateCheck(
            name="timestamp_sanity",
            passed=bad_timestamps == 0,
            value=bad_timestamps,
            target="0",
        ),
        GateCheck(
            name="zero_empty_bodies",
            passed=empty_bodies == 0,
            value=empty_bodies,
            target="0",
        ),
        GateCheck(
            name="blob_store_integrity",
            passed=missing_blobs == 0,
            value=f"missing={missing_blobs}/{len(blob_refs)}",
            target="missing == 0",
        ),
        GateCheck(
            name="zero_leaked_envelopes",
            passed=leaked_envelopes == 0,
            value=f"{leaked_envelopes}/{ai_chat_total} ({leaked_envelope_rate * 100:.2f}%)",
            target="0.0%",
        ),
        GateCheck(
            name="privacy_boundary_zero_leaks",
            passed=total_privacy_leaks == 0,
            value=total_privacy_leaks,
            target="0",
        ),
        GateCheck(
            name="agent_context_pack_consumable",
            passed=pack_has_consumable_content and pack_raw_wiring_ok and pack_within_budget,
            value=f"raw_evidence={pack_raw_hits}, tokens={pack.get('approx_tokens')}/{pack.get('max_tokens')}",
            target="consumable & within budget",
        ),
        GateCheck(
            name="agent_curation_queue_ready",
            passed=queue_ok,
            value=f"returned={queue_returned}, pending={pending_total}",
            target="returned > 0 when pending > 0",
        ),
        GateCheck(
            name="agent_expand_raw_ok",
            passed=expand_ok,
            value=expand_ok,
            target="True",
        ),
    ]

    return RawAuditReport(
        data_dir=str(root),
        audited_at_ms=now_ms(),
        ready_for_curation=all(c.passed for c in checks),
        checks=checks,
        storage={
            "db_size_mib": round(db_path.stat().st_size / 1_048_576.0, 2),
            "total_raw": total_raw,
            "by_source": by_source,
            "by_connector": by_connector,
            "fts_rows": fts_rows,
            "raw_log_files": len(raw_log_files),
            "raw_log_lines": raw_log_lines,
            "blob_refs": len(blob_refs),
            "missing_blobs": missing_blobs,
            "episodes_by_status": episodes_by_status,
            "links_total": links_total,
            "cross_channel_links": cross_channel_links,
        },
        signal_hygiene={
            "ai_chat_total": ai_chat_total,
            "leaked_envelopes": leaked_envelopes,
            "leaked_envelope_rate": leaked_envelope_rate,
            "reflexive_filtered": reflexive_filtered,
            "subagent_turns": subagent_turns,
            "signal_hints": dict(signal_hints),
        },
        privacy={
            "tiers": privacy_tiers,
            "local_only_count": len(local_only_ids),
            "local_only_expand_blocked": local_only_expand_blocked,
            "total_leaks": total_privacy_leaks,
        },
        consumption={
            "what_was_i_doing_ms": now_ms_lat,
            "what_was_i_doing_episodes": len(now_view.get("episodes") or []),
            "get_context_pack_ms": pack_ms_lat,
            "get_context_pack_tokens": pack.get("approx_tokens"),
            "get_context_pack_raw_evidence": pack_raw_hits,
            "search_context_ms": search_ms_lat,
            "search_context_raw_matches": search_raw_hits,
            "get_curation_queue_ms": queue_ms_lat,
            "get_curation_queue_returned": queue_returned,
            "get_curation_queue_pending": pending_total,
            "expand_raw_ms": expand_ms_lat,
        },
    )


def render_raw_audit_markdown(report: RawAuditReport) -> str:
    badge = "READY ✅" if report.ready_for_curation else "BLOCKED ❌"
    lines = [
        f"# Raw Memory — Raw Data Readiness & Consumption Gate ({badge})",
        "",
        f"- **Data Dir**: `{report.data_dir}`",
        f"- **Raw Events**: `{report.storage.get('total_raw', 0)}` · **DB Size**: `{report.storage.get('db_size_mib', 0)} MiB` · **Cross-Channel Links**: `{report.storage.get('cross_channel_links', 0)}`",
        "",
        "| Gate Check | Value | Target | Status |",
        "| :--- | :--- | :--- | :---: |",
    ]
    for chk in report.checks:
        lines.append(
            f"| `{chk.name}` | `{chk.value}` | `{chk.target}` | {'PASS' if chk.passed else 'FAIL'} |"
        )
    c = report.consumption
    if c:
        lines.extend(
            [
                "",
                "## Agent Consumption Latencies",
                "",
                "| Tool / Entrypoint | Latency (ms) | Result Summary |",
                "| :--- | ---: | :--- |",
                f"| `what_was_i_doing` | {c.get('what_was_i_doing_ms', 0):.2f} | episodes={c.get('what_was_i_doing_episodes', 0)} |",
                f"| `get_context_pack` | {c.get('get_context_pack_ms', 0):.2f} | raw_evidence={c.get('get_context_pack_raw_evidence', 0)}, tokens={c.get('get_context_pack_tokens', 0)} |",
                f"| `search_context` | {c.get('search_context_ms', 0):.2f} | raw_matches={c.get('search_context_raw_matches', 0)} |",
                f"| `get_curation_queue` | {c.get('get_curation_queue_ms', 0):.2f} | returned={c.get('get_curation_queue_returned', 0)} / pending={c.get('get_curation_queue_pending', 0)} |",
                f"| `expand(level='raw')` | {c.get('expand_raw_ms', 0):.2f} | verified verbatim raw read |",
            ]
        )
    return "\n".join(lines) + "\n"
