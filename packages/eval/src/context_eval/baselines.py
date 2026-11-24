"""Causal Time-Travel Replay (H_<t Isolation) and 4 A/B Baselines on isolated HubStore."""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from context_hub.models import (
    CuratedLinkIn,
    CurationBatchIn,
    DecisionCurationIn,
    EpisodeCurationIn,
    MemoryCurationIn,
)
from context_hub.store import HubStore

from .schema import BaselineName, BaselineRetrieval, BenchmarkCase


class CausalLeakageError(RuntimeError):
    """Raised when an event with t_start >= cutoff_ms leaks into an isolated replay store."""


@dataclass(slots=True)
class ReplayContext:
    """Result of building a causally isolated ephemeral HubStore for a single case."""

    store: HubStore
    ingested_ids: set[str]
    excluded_future_ids: set[str]
    decision_ref_map: dict[str, str]


_TERM_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{1,}|[\u4e00-\u9fff]{2,}")
_STOP_TERMS = {
    "继续",
    "帮我",
    "一下",
    "这个",
    "那个",
    "我们",
    "可以",
    "现在",
    "当前",
    "什么",
    "怎么",
    "开始",
    "完成",
    "优化",
    "实现",
    "新增",
    "结合",
    "刚才",
    "昨天",
    "昨晚",
    "continue",
    "please",
    "the",
    "and",
    "for",
    "with",
    "from",
    "what",
    "this",
    "that",
}


def approx_text_tokens(text: str) -> int:
    """Conservative mixed CJK/English token estimator aligned with Context Hub v2."""
    cleaned = text.strip()
    if not cleaned:
        return 0
    return max(1, len(cleaned) // 3)


def verify_causal_isolation(store: HubStore, cutoff_ms: int) -> None:
    """Assert zero future events (t_start >= cutoff_ms) or future decisions exist in the store."""
    with store._tx(False) as conn:
        future_raw = conn.execute(
            "SELECT id, t_start FROM raw_events WHERE t_start >= ?",
            (cutoff_ms,),
        ).fetchall()
        if future_raw:
            sample = ", ".join(f"{r['id']}@{r['t_start']}" for r in future_raw[:5])
            raise CausalLeakageError(
                f"Causal isolation violated: {len(future_raw)} raw events with "
                f"t_start >= {cutoff_ms} ({sample})"
            )
        future_dec = conn.execute(
            "SELECT id, valid_at FROM decisions WHERE valid_at >= ?",
            (cutoff_ms,),
        ).fetchall()
        if future_dec:
            sample = ", ".join(f"{r['id']}@{r['valid_at']}" for r in future_dec[:5])
            raise CausalLeakageError(
                f"Causal isolation violated: {len(future_dec)} decisions with "
                f"valid_at >= {cutoff_ms} ({sample})"
            )


def build_causal_replay_store(case: BenchmarkCase, work_dir: Path) -> ReplayContext:
    """Populate an ephemeral isolated HubStore strictly with H_<t events and curations."""
    store = HubStore(work_dir)
    ingested_ids: set[str] = set()
    excluded_future_ids: set[str] = set()

    ordered_events = sorted(case.events, key=lambda ev: (int(ev.get("t_start", 0)), str(ev.get("id", ""))))
    for ev in ordered_events:
        t_start = int(ev["t_start"])
        ev_id = str(ev.get("id") or ev.get("provenance", {}).get("source_id") or "")
        if t_start >= case.cutoff_ms:
            excluded_future_ids.add(ev_id)
            continue
        res = store.ingest_event(ev, write_l0=False, sync_md=False)
        ingested_ids.add(res["event"]["id"])

    decision_ref_map: dict[str, str] = {}
    ordered_curations = sorted(case.curations, key=lambda c: c.committed_at_ms)

    for fixture in ordered_curations:
        if fixture.committed_at_ms >= case.cutoff_ms:
            continue

        valid_episodes: list[EpisodeCurationIn] = []
        for ep in fixture.episodes:
            if not all(eid in ingested_ids for eid in ep.evidence_ids):
                continue
            valid_episodes.append(
                EpisodeCurationIn(
                    episode_id=ep.episode_id,
                    title=ep.title,
                    summary=ep.summary,
                    overview=ep.overview,
                    project=ep.project,
                    entities=ep.entities,
                    evidence_ids=ep.evidence_ids,
                )
            )

        valid_decisions: list[tuple[str | None, DecisionCurationIn]] = []
        for dec in fixture.decisions:
            if not all(eid in ingested_ids for eid in dec.evidence_ids):
                continue
            valid_at = dec.valid_at if dec.valid_at is not None else fixture.committed_at_ms
            if valid_at >= case.cutoff_ms:
                continue
            supersedes_id: str | None = None
            if dec.supersedes_ref:
                supersedes_id = decision_ref_map.get(dec.supersedes_ref)
                if supersedes_id is None:
                    # Superseded target did not exist prior to cutoff_ms; skip invalid chain
                    continue
            valid_decisions.append(
                (
                    dec.ref_id,
                    DecisionCurationIn(
                        project=dec.project,
                        topic=dec.topic,
                        statement=dec.statement,
                        authority=dec.authority,
                        confidence=dec.confidence,
                        valid_at=valid_at,
                        supersedes_decision_id=supersedes_id,
                        evidence_ids=dec.evidence_ids,
                    ),
                )
            )

        curated_memories: list[MemoryCurationIn] = []
        manual_memories: list[MemoryCurationIn] = []
        for mem in fixture.memories:
            if not all(eid in ingested_ids for eid in mem.evidence_ids):
                continue
            mem_in = MemoryCurationIn(
                title=mem.title,
                body=mem.body,
                kind=mem.kind,
                project=mem.project,
                tags=mem.tags,
                evidence_ids=mem.evidence_ids,
            )
            if mem.manual:
                manual_memories.append(mem_in)
            else:
                curated_memories.append(mem_in)

        valid_links: list[CuratedLinkIn] = []
        for lk in fixture.links:
            if lk.src_id in ingested_ids and lk.dst_id in ingested_ids:
                valid_links.append(
                    CuratedLinkIn(
                        src_id=lk.src_id,
                        dst_id=lk.dst_id,
                        relation=lk.relation,
                        confidence=lk.confidence,
                        evidence=lk.evidence,
                    )
                )

        if valid_episodes or valid_decisions or curated_memories or valid_links:
            batch = CurationBatchIn(
                curator_agent=fixture.curator_agent,
                episodes=valid_episodes,
                decisions=[d for _, d in valid_decisions],
                memories=curated_memories,
                links=valid_links,
                notes=fixture.notes,
            )
            committed = store.commit_curation_batch(batch, allow_local_only=False)
            dec_ids = committed["committed"]["decisions"]
            for (ref_id, _), real_id in zip(valid_decisions, dec_ids, strict=True):
                if ref_id:
                    decision_ref_map[ref_id] = real_id

        for manual_mem in manual_memories:
            store.save_manual_memory(
                manual_mem,
                author=fixture.curator_agent,
                allow_local_only=False,
            )

    verify_causal_isolation(store, case.cutoff_ms)
    return ReplayContext(
        store=store,
        ingested_ids=ingested_ids,
        excluded_future_ids=excluded_future_ids,
        decision_ref_map=decision_ref_map,
    )


def _extract_fallback_terms(query: str) -> list[str]:
    """Extract informative tokens for raw_fts fallback when strict AND FTS matches 0 rows."""
    candidates: list[str] = []
    seen: set[str] = set()
    for match in _TERM_RE.finditer(query):
        tok = match.group(0).strip(".-_")
        if not tok:
            continue
        low = tok.casefold()
        if low in _STOP_TERMS:
            continue
        # Split long CJK spans into 2-char bigrams as fallback query probes
        if all("\u4e00" <= ch <= "\u9fff" for ch in tok) and len(tok) > 4:
            for idx in range(0, len(tok) - 1, 2):
                piece = tok[idx : idx + 2]
                if piece not in _STOP_TERMS and piece not in seen:
                    seen.add(piece)
                    candidates.append(piece)
            continue
        if low not in seen:
            seen.add(low)
            candidates.append(tok)
    # Prefer longer / more specific technical identifiers first
    candidates.sort(key=lambda s: len(s), reverse=True)
    return candidates[:8]


def _run_no_memory(store: HubStore, case: BenchmarkCase) -> BaselineRetrieval:
    t0 = time.perf_counter()
    latency_ms = (time.perf_counter() - t0) * 1000.0
    return BaselineRetrieval(
        baseline="no_memory",
        context_text="",
        approx_tokens=0,
        latency_ms=latency_ms,
        items_returned=0,
        metadata={},
    )


def _run_raw_fts(store: HubStore, case: BenchmarkCase) -> BaselineRetrieval:
    """Query ONLY raw_events via FTS5, completely ignoring L2/L3 curated records."""
    t0 = time.perf_counter()
    budget = case.max_tokens
    searched = store.search_context(
        case.query,
        project=case.project,
        limit=12,
        agent=True,
        max_tokens=budget,
    )
    raw_hits: list[dict[str, Any]] = list(searched.get("raw_matches") or [])

    # Fair natural-language fallback: if strict AND FTS returns nothing, probe informative tokens
    if not raw_hits:
        scored: dict[str, tuple[int, dict[str, Any]]] = {}
        for term in _extract_fallback_terms(case.query):
            for hit in store.list_raw(q=term, project=case.project, limit=6, agent=True):
                rid = hit["id"]
                prev_score, _ = scored.get(rid, (0, hit))
                scored[rid] = (prev_score + 1, hit)
        ranked = sorted(
            scored.values(),
            key=lambda pair: (pair[0], int(pair[1].get("t_start", 0))),
            reverse=True,
        )
        raw_hits = [
            {
                "id": h["id"],
                "source": h["source"],
                "project": h.get("project"),
                "t_start": h["t_start"],
                "title": h["title"],
                "snippet": (h.get("body_text") or "")[:400],
            }
            for _, h in ranked[:12]
        ]

    lines: list[str] = ["# Raw FTS Matches"]
    used = approx_text_tokens(lines[0])
    returned = 0
    for hit in raw_hits:
        snippet = (hit.get("snippet") or hit.get("body_text") or "").strip()
        line = f"- `{hit['id']}` ({hit['source']}, t={hit['t_start']}): {hit['title']} — {snippet}"
        cost = approx_text_tokens(line)
        if used + cost > budget and returned > 0:
            break
        lines.append(line)
        used += cost
        returned += 1

    text = "\n".join(lines) if returned > 0 else ""
    latency_ms = (time.perf_counter() - t0) * 1000.0
    return BaselineRetrieval(
        baseline="raw_fts",
        context_text=text,
        approx_tokens=approx_text_tokens(text),
        latency_ms=latency_ms,
        items_returned=returned,
        metadata={"raw_hits": returned},
    )


def _run_flat_memory_md(store: HubStore, case: BenchmarkCase) -> BaselineRetrieval:
    """Static un-versioned MEMORY.md baseline: concatenates ALL historical decisions & memories."""
    t0 = time.perf_counter()
    budget = case.max_tokens

    # Intentionally includes BOTH active and superseded decisions without bi-temporal filtering,
    # modeling a flat append-only MEMORY.md file where outdated entries linger alongside new ones.
    all_decisions = store.list_decisions(project=case.project, status=None, limit=80, agent=True)
    all_decisions.sort(key=lambda d: (int(d.get("valid_at", 0)), str(d.get("id", ""))))

    all_memories = store.list_memories(project=case.project, limit=80, agent=True)
    global_memories = [
        m
        for m in store.list_memories(limit=40, agent=True)
        if m.get("project") is None and all(m["id"] != existing["id"] for existing in all_memories)
    ]
    combined_memories = all_memories + global_memories

    lines: list[str] = ["# Flat MEMORY.md"]
    used = approx_text_tokens(lines[0])
    returned = 0

    if all_decisions:
        lines.append("## Decisions")
        used += approx_text_tokens(lines[-1])
        for dec in all_decisions:
            line = f"- [{dec['project']}] {dec['topic']}: {dec['statement']}"
            cost = approx_text_tokens(line)
            if used + cost > budget and returned > 0:
                break
            lines.append(line)
            used += cost
            returned += 1

    if combined_memories:
        lines.append("## Memories")
        used += approx_text_tokens(lines[-1])
        for mem in combined_memories:
            scope = mem.get("project") or "global"
            line = f"- [{mem['kind']} · {scope}] {mem['title']}: {mem['body'][:360]}"
            cost = approx_text_tokens(line)
            if used + cost > budget and returned > 0:
                break
            lines.append(line)
            used += cost
            returned += 1

    text = "\n".join(lines) if returned > 0 else ""
    latency_ms = (time.perf_counter() - t0) * 1000.0
    return BaselineRetrieval(
        baseline="flat_memory_md",
        context_text=text,
        approx_tokens=approx_text_tokens(text),
        latency_ms=latency_ms,
        items_returned=returned,
        metadata={
            "decisions_included": len(all_decisions),
            "memories_included": len(combined_memories),
        },
    )


def _run_hub_v2_curated(store: HubStore, case: BenchmarkCase) -> BaselineRetrieval:
    """Full Context Hub v2 curated Context Pack with causal-window & anchor-graph support."""
    t0 = time.perf_counter()
    budget = case.max_tokens
    pack = store.get_context_pack(
        query=case.query,
        project=case.project,
        minutes=case.window_minutes,
        max_tokens=budget,
        agent=True,
    )

    sections: list[str] = [pack["rendered_markdown"]]
    used = approx_text_tokens(pack["rendered_markdown"])
    items_returned = (
        len(pack["active_decisions"])
        + len(pack["memories"])
        + len(pack["episodes"])
        + len(pack["raw_evidence"])
    )

    # Causal-anchor fallback: `what_was_i_doing` inside get_context_pack defaults to wall-clock now,
    # so when replaying historical cutoff_ms without project episodes, anchor recency at cutoff_ms.
    if not pack["episodes"]:
        recent = store.what_was_i_doing(
            minutes=case.window_minutes,
            at_ms=case.cutoff_ms,
            agent=True,
            max_tokens=max(400, budget - used),
        )
        seen_d = {d["id"] for d in pack["active_decisions"]}
        extra_lines: list[str] = []
        for d in recent.get("active_decisions") or []:
            if d["id"] not in seen_d:
                extra_lines.append(
                    f"- **[{d['project']}] {d['topic']}** (`{d['authority']}`): {d['statement']} (`{d['id']}`)"
                )
                seen_d.add(d["id"])
        for ep in recent.get("episodes") or []:
            extra_lines.append(
                f"- **{ep['title']}** (`{ep['id']}` · `{ep['primary_source']}`): {ep['summary']}"
            )
        if extra_lines:
            block = "## Causal Window Episodes\n" + "\n".join(extra_lines)
            if used + approx_text_tokens(block) <= budget:
                sections.append(block)
                used += approx_text_tokens(block)
                items_returned += len(extra_lines)

    # Cross-channel anchor expansion (e.g. URL pasted/read across browser + clipboard + ai_chat)
    if case.anchor_urls:
        seen_raw = {r["id"] for r in pack["raw_evidence"]}
        rel_lines: list[str] = []
        for url in case.anchor_urls:
            rel = store.related(url=url, limit=6, agent=True)
            for item in rel.get("items") or []:
                if item["id"] in seen_raw:
                    continue
                seen_raw.add(item["id"])
                line = f"- `{item['id']}` ({item['source']}): {item['title']} — {item['snippet']}"
                if used + approx_text_tokens(line) <= budget:
                    rel_lines.append(line)
                    used += approx_text_tokens(line)
                    items_returned += 1
        if rel_lines:
            sections.append("## Linked Cross-Channel Anchors\n" + "\n".join(rel_lines))

    # Raw fallback ONLY when curated L2/L3 produced zero decisions, memories, and episodes
    if items_returned == 0 and case.query.strip():
        searched = store.search_context(
            case.query,
            project=case.project,
            limit=6,
            agent=True,
            max_tokens=budget,
        )
        raw_lines: list[str] = []
        for r in searched.get("raw_matches") or []:
            line = f"- `{r['id']}` ({r['source']}): {r['title']} — {r['snippet']}"
            if used + approx_text_tokens(line) <= budget:
                raw_lines.append(line)
                used += approx_text_tokens(line)
                items_returned += 1
        if raw_lines:
            sections.append("## Fallback Evidence\n" + "\n".join(raw_lines))

    text = "\n\n".join(s.strip() for s in sections if s.strip())
    latency_ms = (time.perf_counter() - t0) * 1000.0
    return BaselineRetrieval(
        baseline="hub_v2_curated",
        context_text=text,
        approx_tokens=approx_text_tokens(text),
        latency_ms=latency_ms,
        items_returned=items_returned,
        metadata={
            "active_decisions": len(pack["active_decisions"]),
            "memories": len(pack["memories"]),
            "episodes": len(pack["episodes"]),
            "anchor_urls": len(case.anchor_urls),
        },
    )


def run_baseline(
    baseline: BaselineName,
    store: HubStore,
    case: BenchmarkCase,
) -> BaselineRetrieval:
    """Dispatch a single baseline against a causally isolated replay HubStore."""
    if baseline == "no_memory":
        return _run_no_memory(store, case)
    if baseline == "raw_fts":
        return _run_raw_fts(store, case)
    if baseline == "flat_memory_md":
        return _run_flat_memory_md(store, case)
    if baseline == "hub_v2_curated":
        return _run_hub_v2_curated(store, case)
    raise ValueError(f"Unknown baseline: {baseline}")
