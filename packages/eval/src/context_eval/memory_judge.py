"""Meta Benchmark Real-Memory Observability & Quality Grader for Raw Memory.

Evaluates curated intermediate Memory (`episodes`, `decisions`, `memories`, `markdown/MEMORY.md`)
directly against the underlying Raw Data with zero private text leakage:
1. Evidence Grounding & Authority Fidelity (catches fabricated IDs & assistant-only authority inflation)
2. Compression Ratio & Deduplication Density
3. Bi-Temporal Coherence & Stale-Fact Suppression
4. Self-Bootstrapped Live A/B Benchmark (`no_memory` vs `raw_fts` vs `flat_memory_md` vs `raw_memory_curated`)
"""

from __future__ import annotations

import math
import re
import sqlite3
import time
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field

from context_hub.models import now_ms
from context_hub.store import HubStore

from .baselines import _extract_fallback_terms, approx_text_tokens
from .raw_audit import GateCheck

_SALIENT_TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{2,}|[\u4e00-\u9fff]{2,6}")
_STOP_WORDS = {
    "我们",
    "可以",
    "需要",
    "使用",
    "已经",
    "目前",
    "进行",
    "完成",
    "支持",
    "保持",
    "继续",
    "通过",
    "以及",
    "作为",
    "当前",
    "所有",
    "后续",
    "确保",
    "问题",
    "方案",
    "统一",
    "the",
    "and",
    "for",
    "with",
    "from",
    "that",
    "this",
    "into",
    "only",
    "use",
    "not",
    "are",
    "was",
    "will",
}
_HUMAN_SOURCES = {"clipboard", "voice", "audio", "browser", "note", "manual"}
_PRIVACY_RANK = {"shareable": 0, "redacted": 1, "local_only": 2}


class LiveBaselineRow(BaseModel):
    baseline: str
    probe_count: int
    active_truth_recall: float
    stale_leakage_rate: float
    traceability_rate: float
    avg_tokens: float
    p50_latency_ms: float
    p95_latency_ms: float


class MemoryAuditReport(BaseModel):
    data_dir: str
    audited_at_ms: int
    overall_passed: bool
    checks: list[GateCheck] = Field(default_factory=list)
    coverage: dict[str, Any] = Field(default_factory=dict)
    grounding: dict[str, Any] = Field(default_factory=dict)
    coherence: dict[str, Any] = Field(default_factory=dict)
    compression: dict[str, Any] = Field(default_factory=dict)
    live_ab_scorecard: list[LiveBaselineRow] = Field(default_factory=list)


def _norm(text: str) -> str:
    return unicodedata.normalize("NFKC", text).casefold()


def _extract_salient_terms(text: str, *, limit: int = 4) -> list[str]:
    terms: list[str] = []
    seen: set[str] = set()
    for match in _SALIENT_TOKEN_RE.finditer(text):
        tok = match.group(0).strip(".-_")
        low = _norm(tok)
        if len(low) < 2 or low in _STOP_WORDS or low in seen:
            continue
        seen.add(low)
        terms.append(tok)
    # Prefer specific identifiers (mixed case/digits/longer tokens)
    terms.sort(key=lambda t: (any(ch.isdigit() or ch in "-_." for ch in t), len(t)), reverse=True)
    return terms[:limit]


def _percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return round(ordered[0], 3)
    rank = (pct / 100.0) * (len(ordered) - 1)
    lo = math.floor(rank)
    hi = math.ceil(rank)
    if lo == hi:
        return round(ordered[lo], 3)
    frac = rank - lo
    return round(ordered[lo] * (1.0 - frac) + ordered[hi] * frac, 3)


def _is_human_raw_event(actor: str | None, source: str | None) -> bool:
    return (actor or "").strip().lower() == "self" or (source or "").strip().lower() in _HUMAN_SOURCES


def audit_curated_memory(data_dir: Path, *, run_live_ab: bool = True) -> MemoryAuditReport:
    """Observe and grade real curated Memory directly against L0/L1 Raw Data (zero text leaked)."""
    root = Path(data_dir).expanduser()
    db_path = root / "hub.sqlite3"
    if not db_path.is_file():
        return MemoryAuditReport(
            data_dir=str(root),
            audited_at_ms=now_ms(),
            overall_passed=False,
            checks=[GateCheck(name="db_exists", passed=False, value=False, target="True")],
        )

    store = HubStore(root)
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    try:
        # Load raw lookup table (metadata only: id, actor, source, privacy_tier, body_char_len)
        raw_meta: dict[str, dict[str, Any]] = {}
        for r in conn.execute(
            "SELECT id, actor, source, privacy_tier, body_char_len, deleted FROM raw_events"
        ):
            raw_meta[r["id"]] = dict(r)

        total_episodes = conn.execute("SELECT COUNT(*) FROM episodes").fetchone()[0]
        curated_episodes = conn.execute(
            "SELECT * FROM episodes WHERE status IN ('curated', 'manual')"
        ).fetchall()
        all_decisions = conn.execute("SELECT * FROM decisions ORDER BY valid_at ASC").fetchall()
        active_decisions = [d for d in all_decisions if d["status"] == "active"]
        superseded_decisions = [d for d in all_decisions if d["status"] == "superseded"]
        all_memories = conn.execute("SELECT * FROM memories ORDER BY created_at ASC").fetchall()

        dec_evidence: dict[str, list[str]] = defaultdict(list)
        for row in conn.execute("SELECT decision_id, raw_id FROM decision_evidence"):
            dec_evidence[row["decision_id"]].append(row["raw_id"])

        mem_evidence: dict[str, list[str]] = defaultdict(list)
        for row in conn.execute("SELECT memory_id, raw_id FROM memory_evidence"):
            mem_evidence[row["memory_id"]].append(row["raw_id"])

        ep_evidence: dict[str, list[str]] = defaultdict(list)
        for row in conn.execute("SELECT episode_id, raw_id FROM episode_events"):
            ep_evidence[row["episode_id"]].append(row["raw_id"])

        # ---------------- 1. Evidence Grounding & Authority Fidelity ----------------
        total_curated_items = len(curated_episodes) + len(all_decisions) + len(all_memories)
        grounded_items = 0
        privacy_ok_items = 0
        user_confirmed_total = 0
        user_confirmed_human_backed = 0

        def _check_evidence(item_tier: str, ev_ids: list[str]) -> tuple[bool, bool, bool]:
            if not ev_ids:
                return False, True, False
            valid_rows = [
                raw_meta[eid]
                for eid in ev_ids
                if eid in raw_meta and int(raw_meta[eid]["deleted"]) == 0
            ]
            all_exist = len(valid_rows) == len(ev_ids)
            strictest_rank = max(
                (_PRIVACY_RANK.get(str(r["privacy_tier"]), 0) for r in valid_rows),
                default=0,
            )
            privacy_ok = _PRIVACY_RANK.get(item_tier, 0) >= strictest_rank
            has_human = any(
                _is_human_raw_event(r["actor"], r["source"]) for r in valid_rows
            )
            return all_exist, privacy_ok, has_human

        for ep in curated_episodes:
            ok_ev, ok_priv, _ = _check_evidence(str(ep["privacy_tier"]), ep_evidence.get(ep["id"], []))
            if ok_ev:
                grounded_items += 1
            if ok_priv:
                privacy_ok_items += 1

        for dec in all_decisions:
            ev_ids = dec_evidence.get(dec["id"], [])
            ok_ev, ok_priv, has_human = _check_evidence(str(dec["privacy_tier"]), ev_ids)
            if ok_ev:
                grounded_items += 1
            if ok_priv:
                privacy_ok_items += 1
            if dec["authority"] == "user_confirmed":
                user_confirmed_total += 1
                if has_human:
                    user_confirmed_human_backed += 1

        for mem in all_memories:
            ev_ids = mem_evidence.get(mem["id"], [])
            ok_ev, ok_priv, _ = _check_evidence(str(mem["privacy_tier"]), ev_ids)
            if ok_ev:
                grounded_items += 1
            if ok_priv:
                privacy_ok_items += 1

        grounding_rate = (
            round(grounded_items / total_curated_items, 4) if total_curated_items else 0.0
        )
        privacy_inheritance_rate = (
            round(privacy_ok_items / total_curated_items, 4) if total_curated_items else 0.0
        )
        authority_grounding_rate = (
            round(user_confirmed_human_backed / user_confirmed_total, 4)
            if user_confirmed_total
            else 1.0
        )

        # ---------------- 2. Compression & Deduplication Density ----------------
        curated_raw_ids = {
            eid
            for ep in curated_episodes
            for eid in ep_evidence.get(ep["id"], [])
            if eid in raw_meta and int(raw_meta[eid]["deleted"]) == 0
        }
        curated_raw_chars = sum(int(raw_meta[eid]["body_char_len"] or 0) for eid in curated_raw_ids)
        memory_artifact_chars = (
            sum(len(str(ep["summary"] or "")) + len(str(ep["overview"] or "")) for ep in curated_episodes)
            + sum(len(str(d["statement"] or "")) for d in active_decisions)
            + sum(len(str(m["title"] or "")) + len(str(m["body"] or "")) for m in all_memories)
        )
        compression_ratio = (
            round(curated_raw_chars / max(1, memory_artifact_chars), 2)
            if curated_raw_chars > 0
            else 0.0
        )

        memory_index_path = root / "markdown" / "MEMORY.md"
        memory_md_ok = memory_index_path.is_file() and memory_index_path.stat().st_size > 40

        # Detect duplicate active decisions on the same (project, topic)
        active_topic_counts: Counter[tuple[str, str]] = Counter(
            (_norm(str(d["project"])), _norm(str(d["topic"]))) for d in active_decisions
        )
        active_topic_conflicts = sum(1 for cnt in active_topic_counts.values() if cnt > 1)

        # Detect near-duplicate memories by normalized (project, kind, title)
        mem_keys: Counter[tuple[str, str, str]] = Counter(
            (_norm(str(m["project"] or "")), _norm(str(m["kind"])), _norm(str(m["title"])))
            for m in all_memories
        )
        duplicate_memories = sum(cnt - 1 for cnt in mem_keys.values() if cnt > 1)

        # ---------------- 3. Bi-Temporal Coherence ----------------
        dec_by_id = {d["id"]: d for d in all_decisions}
        broken_chains = 0
        for sd in superseded_decisions:
            target_id = sd["superseded_by"]
            if not target_id or target_id not in dec_by_id:
                broken_chains += 1
                continue
            # Cycle check
            visited = {sd["id"]}
            cur = target_id
            while cur and cur in dec_by_id:
                if cur in visited:
                    broken_chains += 1
                    break
                visited.add(cur)
                cur = dec_by_id[cur]["superseded_by"]
            if sd["invalid_at"] is not None and int(sd["invalid_at"]) < int(sd["valid_at"]):
                broken_chains += 1

        chain_integrity_ok = broken_chains == 0

        # Verify superseded decisions do NOT leak into active_decisions of get_context_pack
        superseded_ids = {d["id"] for d in superseded_decisions}
        stale_pack_leaks = 0
        for sd in superseded_decisions:
            pack = store.get_context_pack(
                query=f"{sd['project']} {sd['topic']}",
                project=sd["project"],
                minutes=30 * 24 * 60,
                max_tokens=2000,
                agent=True,
            )
            if any(ad["id"] in superseded_ids for ad in (pack.get("active_decisions") or [])):
                stale_pack_leaks += 1

        # ---------------- 4. Self-Bootstrapped Live A/B Benchmark ----------------
        live_rows: list[LiveBaselineRow] = []
        if run_live_ab and (active_decisions or all_memories):
            live_rows = _run_live_ab_probes(
                store,
                active_decisions=active_decisions,
                superseded_decisions=superseded_decisions,
                all_memories=all_memories,
                dec_by_id=dec_by_id,
            )
    finally:
        conn.close()

    curated_live_row = next((r for r in live_rows if r.baseline == "raw_memory_curated"), None)
    flat_live_row = next((r for r in live_rows if r.baseline == "flat_memory_md"), None)
    raw_fts_live_row = next((r for r in live_rows if r.baseline == "raw_fts"), None)

    checks = [
        GateCheck(
            name="has_curated_memory",
            passed=len(curated_episodes) > 0 and (len(active_decisions) + len(all_memories)) > 0,
            value=f"episodes={len(curated_episodes)}, active_decisions={len(active_decisions)}, memories={len(all_memories)}",
            target="curated > 0",
        ),
        GateCheck(
            name="evidence_grounding_100pct",
            passed=total_curated_items > 0 and grounding_rate == 1.0,
            value=f"{grounding_rate * 100:.1f}% ({grounded_items}/{total_curated_items})",
            target="100.0%",
        ),
        GateCheck(
            name="authority_grounding_100pct",
            passed=authority_grounding_rate == 1.0,
            value=f"{authority_grounding_rate * 100:.1f}% ({user_confirmed_human_backed}/{user_confirmed_total})",
            target="100.0%",
        ),
        GateCheck(
            name="privacy_inheritance_100pct",
            passed=total_curated_items > 0 and privacy_inheritance_rate == 1.0,
            value=f"{privacy_inheritance_rate * 100:.1f}%",
            target="100.0%",
        ),
        GateCheck(
            name="bitemporal_chain_integrity",
            passed=chain_integrity_ok and active_topic_conflicts == 0 and stale_pack_leaks == 0,
            value=f"broken={broken_chains}, conflicts={active_topic_conflicts}, pack_leaks={stale_pack_leaks}",
            target="all 0",
        ),
        GateCheck(
            name="memory_md_synced",
            passed=memory_md_ok,
            value=memory_md_ok,
            target="True",
        ),
        GateCheck(
            name="zero_duplicate_memories",
            passed=duplicate_memories == 0,
            value=duplicate_memories,
            target="0",
        ),
    ]
    if curated_live_row is not None and raw_fts_live_row is not None:
        checks.append(
            GateCheck(
                name="live_ab_curated_beats_raw_fts",
                passed=(
                    curated_live_row.active_truth_recall >= raw_fts_live_row.active_truth_recall
                    and curated_live_row.stale_leakage_rate <= raw_fts_live_row.stale_leakage_rate
                ),
                value=(
                    f"curated_recall={curated_live_row.active_truth_recall * 100:.1f}% / "
                    f"stale={curated_live_row.stale_leakage_rate * 100:.1f}% vs "
                    f"raw_fts={raw_fts_live_row.active_truth_recall * 100:.1f}% / "
                    f"stale={raw_fts_live_row.stale_leakage_rate * 100:.1f}%"
                ),
                target="recall >= & stale <=",
            )
        )
    if curated_live_row is not None and flat_live_row is not None and superseded_decisions:
        checks.append(
            GateCheck(
                name="live_ab_curated_suppresses_stale_vs_flat",
                passed=curated_live_row.stale_leakage_rate < flat_live_row.stale_leakage_rate
                or curated_live_row.stale_leakage_rate == 0.0,
                value=(
                    f"curated_stale={curated_live_row.stale_leakage_rate * 100:.1f}% vs "
                    f"flat_stale={flat_live_row.stale_leakage_rate * 100:.1f}%"
                ),
                target="curated_stale == 0.0%",
            )
        )

    mem_by_kind = Counter(str(m["kind"]) for m in all_memories)
    return MemoryAuditReport(
        data_dir=str(root),
        audited_at_ms=now_ms(),
        overall_passed=all(c.passed for c in checks),
        checks=checks,
        coverage={
            "total_episodes": total_episodes,
            "curated_episodes": len(curated_episodes),
            "active_decisions": len(active_decisions),
            "superseded_decisions": len(superseded_decisions),
            "total_memories": len(all_memories),
            "memories_by_kind": dict(mem_by_kind),
        },
        grounding={
            "total_curated_items": total_curated_items,
            "grounded_items": grounded_items,
            "grounding_rate": grounding_rate,
            "user_confirmed_total": user_confirmed_total,
            "user_confirmed_human_backed": user_confirmed_human_backed,
            "authority_grounding_rate": authority_grounding_rate,
            "privacy_inheritance_rate": privacy_inheritance_rate,
        },
        coherence={
            "broken_chains": broken_chains,
            "active_topic_conflicts": active_topic_conflicts,
            "stale_pack_leaks": stale_pack_leaks,
            "duplicate_memories": duplicate_memories,
            "memory_md_synced": memory_md_ok,
        },
        compression={
            "curated_raw_events": len(curated_raw_ids),
            "curated_raw_chars": curated_raw_chars,
            "memory_artifact_chars": memory_artifact_chars,
            "compression_ratio": compression_ratio,
        },
        live_ab_scorecard=live_rows,
    )


def _run_live_ab_probes(
    store: HubStore,
    *,
    active_decisions: list[sqlite3.Row],
    superseded_decisions: list[sqlite3.Row],
    all_memories: list[sqlite3.Row],
    dec_by_id: dict[str, sqlite3.Row],
) -> list[LiveBaselineRow]:
    """Build deterministic probes from live curated items and compare 4 baselines (zero text leaked)."""
    # Map active decision ID -> list of superseded predecessor statements that differ
    superseded_by_active: dict[str, list[str]] = defaultdict(list)
    for sd in superseded_decisions:
        # Walk to terminal active decision
        cur = sd["superseded_by"]
        visited = {sd["id"]}
        while cur and cur in dec_by_id and cur not in visited:
            visited.add(cur)
            nxt = dec_by_id[cur]["superseded_by"]
            if not nxt:
                superseded_by_active[cur].append(str(sd["statement"]))
                break
            cur = nxt

    probes: list[dict[str, Any]] = []
    for dec in active_decisions:
        if dec["privacy_tier"] == "local_only":
            continue
        active_terms = _extract_salient_terms(str(dec["statement"]), limit=3)
        if not active_terms:
            continue
        active_norm_set = {_norm(t) for t in active_terms}
        stale_terms: list[str] = []
        for old_stmt in superseded_by_active.get(dec["id"], []):
            for t in _extract_salient_terms(old_stmt, limit=3):
                if _norm(t) not in active_norm_set and _norm(t) not in _norm(str(dec["statement"])):
                    stale_terms.append(t)
        # Build a natural query from salient terms rather than internal snake_case topic keys
        # so raw_fts gets a fair retrieval shot against raw transcripts.
        natural_q = " ".join(active_terms[:2])
        probes.append(
            {
                "query": natural_q,
                "project": dec["project"],
                "required_terms": active_terms[:2],
                "stale_terms": stale_terms[:2],
                "expected_id": dec["id"],
            }
        )

    for mem in all_memories:
        if mem["privacy_tier"] == "local_only":
            continue
        body_terms = _extract_salient_terms(str(mem["body"]), limit=3)
        if not body_terms:
            continue
        title_terms = _extract_salient_terms(str(mem["title"]), limit=2)
        natural_q = " ".join(title_terms or body_terms[:2])
        probes.append(
            {
                "query": natural_q,
                "project": mem["project"],
                "required_terms": body_terms[:2],
                "stale_terms": [],
                "expected_id": mem["id"],
            }
        )

    if not probes:
        return []

    baselines = ("no_memory", "raw_fts", "flat_memory_md", "raw_memory_curated")
    rows: list[LiveBaselineRow] = []

    for bname in baselines:
        recalls: list[float] = []
        stale_hits: list[float] = []
        trace_hits: list[float] = []
        tokens: list[int] = []
        lats: list[float] = []

        for p in probes:
            t0 = time.perf_counter()
            if bname == "no_memory":
                text = ""
                stale_hay_text = ""
                has_trace = False
            elif bname == "raw_fts":
                res = store.search_context(p["query"], project=p["project"], limit=8, agent=True, max_tokens=2000)
                matches = list(res.get("raw_matches") or [])
                if not matches:
                    seen_ids: set[str] = set()
                    for term in _extract_fallback_terms(p["query"]):
                        for h in store.list_raw(q=term, project=p["project"], limit=4, agent=True):
                            if h["id"] not in seen_ids:
                                seen_ids.add(h["id"])
                                matches.append(
                                    {
                                        "id": h["id"],
                                        "title": h["title"],
                                        "snippet": (h.get("body_text") or "")[:400],
                                    }
                                )
                matches = matches[:8]
                text = "\n".join(f"{m['id']} {m['title']} {m.get('snippet', '')}" for m in matches)
                stale_hay_text = text
                has_trace = any(bool(m.get("id")) for m in matches)
            elif bname == "flat_memory_md":
                decs = store.list_decisions(project=p["project"], status=None, limit=80, agent=True)
                mems = store.list_memories(project=p["project"], limit=80, agent=True)
                dec_text = "\n".join(f"[{d['project']}] {d['topic']}: {d['statement']}" for d in decs)
                mem_text = "\n".join(f"[{m['kind']}] {m['title']}: {m['body'][:360]}" for m in mems)
                text = f"{dec_text}\n{mem_text}".strip()
                stale_hay_text = dec_text
                has_trace = False
            else:
                pack = store.get_context_pack(
                    query=p["query"],
                    project=p["project"],
                    minutes=30 * 24 * 60,
                    max_tokens=2000,
                    agent=True,
                )
                text = str(pack.get("rendered_markdown") or "")
                stale_hay_text = "\n".join(
                    [f"{d['topic']}: {d['statement']}" for d in (pack.get("active_decisions") or [])]
                    + [f"{r['title']} {r.get('snippet', '')}" for r in (pack.get("raw_evidence") or [])]
                )
                has_trace = any(
                    bool(d.get("evidence_ids")) for d in (pack.get("active_decisions") or [])
                ) or any(bool(m.get("evidence_ids")) for m in (pack.get("memories") or []))

            lats.append((time.perf_counter() - t0) * 1000.0)
            tokens.append(approx_text_tokens(text))
            hay = _norm(text)
            stale_hay = _norm(stale_hay_text)

            req = p["required_terms"]
            hit_req = sum(1 for t in req if _norm(t) in hay)
            recalls.append(hit_req / len(req) if req else 1.0)

            stale = p["stale_terms"]
            if stale:
                hit_stale = sum(1 for t in stale if _norm(t) in stale_hay)
                stale_hits.append(hit_stale / len(stale))
            trace_hits.append(1.0 if (has_trace and hit_req > 0) else 0.0)

        rows.append(
            LiveBaselineRow(
                baseline=bname,
                probe_count=len(probes),
                active_truth_recall=round(sum(recalls) / len(recalls), 4),
                stale_leakage_rate=round(sum(stale_hits) / len(stale_hits), 4) if stale_hits else 0.0,
                traceability_rate=round(sum(trace_hits) / len(trace_hits), 4),
                avg_tokens=round(sum(tokens) / len(tokens), 1),
                p50_latency_ms=_percentile(lats, 50.0),
                p95_latency_ms=_percentile(lats, 95.0),
            )
        )
    return rows


def render_memory_audit_markdown(report: MemoryAuditReport) -> str:
    badge = "PASS ✅" if report.overall_passed else "NEEDS ATTENTION ⚠️"
    cov = report.coverage
    comp = report.compression
    lines = [
        f"# Raw Memory — Curated Memory Observability & Meta Benchmark ({badge})",
        "",
        f"- **Data Dir**: `{report.data_dir}`",
        (
            f"- **Curated Coverage**: `{cov.get('curated_episodes', 0)}/{cov.get('total_episodes', 0)}` episodes · "
            f"`{cov.get('active_decisions', 0)}` active decisions (`{cov.get('superseded_decisions', 0)}` superseded) · "
            f"`{cov.get('total_memories', 0)}` memories"
        ),
        (
            f"- **Compression Ratio**: **`{comp.get('compression_ratio', 0):.2f}x`** "
            f"(`{comp.get('curated_raw_chars', 0):,}` raw chars across `{comp.get('curated_raw_events', 0)}` events → "
            f"`{comp.get('memory_artifact_chars', 0):,}` memory chars)"
        ),
        "",
        "## 1. Memory Quality & Grounding Gates",
        "",
        "| Gate Check | Value | Target | Status |",
        "| :--- | :--- | :--- | :---: |",
    ]
    for chk in report.checks:
        lines.append(
            f"| `{chk.name}` | `{chk.value}` | `{chk.target}` | {'PASS' if chk.passed else 'FAIL'} |"
        )

    if report.live_ab_scorecard:
        lines.extend(
            [
                "",
                "## 2. Live Real-Memory Meta A/B Scorecard (Self-Bootstrapped from Real Curated Memory)",
                "",
                "| Baseline | Probes | Active Truth Recall ↑ | Stale Leakage ↓ | Evidence Traceability ↑ | Avg Tokens | p50 / p95 ms |",
                "| :--- | ---: | ---: | ---: | ---: | ---: | ---: |",
            ]
        )
        for row in report.live_ab_scorecard:
            lines.append(
                f"| `{row.baseline}` | {row.probe_count} | {row.active_truth_recall * 100:.1f}% | "
                f"{row.stale_leakage_rate * 100:.1f}% | {row.traceability_rate * 100:.1f}% | "
                f"{row.avg_tokens:.1f} | {row.p50_latency_ms:.2f} / {row.p95_latency_ms:.2f} |"
            )

    return "\n".join(lines) + "\n"
