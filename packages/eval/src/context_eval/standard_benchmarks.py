"""Standard Academic Memory Benchmark Adapters for Raw Memory.

Integrates widely adopted public LLM/Agent memory benchmarks directly into Raw Memory's
evaluation harness (`raw-memory-eval bench`):
  1. **LoCoMo** (ACL 2024, Snap Research / UNC): 10 long multi-session conversations,
     1,986 QA pairs across 5 official categories (single-hop, temporal, open-domain,
     multi-hop, adversarial). Supports BOTH:
       - `raw` mode (L1 raw dialogue turns only)
       - `curated` mode (L1 raw turns + L2 session_summary episodes + L3 observation
         memories with explicit `dia_id` evidence provenance)
  2. **LongMemEval-S & LongMemEval-Oracle** (ICLR 2025, UCLA / Tencent AI Lab):
     500 timestamped multi-session questions (~48 distractor sessions / ~494 turns per
     question in LongMemEval-S) across all 6 official pillars (single-session-user,
     single-session-assistant, single-session-preference, multi-session,
     temporal-reasoning, knowledge-update) plus abstention (`_abs`).

All evaluations run deterministically against genuine in-memory `HubStore` instances
(real SQLite schema, real `index_tokens()`, real `search_context()` / `list_raw()`),
producing exact academic retrieval metrics (Recall@K, All-Recall@K, NDCG@K, MRR,
Answer-Span Coverage, and Latency) plus inspectable failure cases for human debugging.
"""

from __future__ import annotations

import datetime
import json
import math
import re
import time
import urllib.request
from collections import defaultdict
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field

from context_hub.models import now_ms
from context_hub.store import HubStore

LOCOMO_CATEGORIES: dict[int, str] = {
    1: "multi_hop",
    2: "temporal",
    3: "open_domain",
    4: "single_hop",
    5: "adversarial",
}

DEFAULT_BENCH_CACHE = Path.home() / ".local" / "share" / "context-hub-v2" / "benchmarks"


def default_manifest_path() -> Path:
    """Locate `benchmarks/manifest.json` in the repository root."""
    here = Path(__file__).resolve()
    for parent in here.parents:
        cand = parent / "benchmarks" / "manifest.json"
        if cand.is_file():
            return cand
    return Path("benchmarks/manifest.json")


def load_manifest(manifest_path: Path | None = None) -> dict[str, Any]:
    path = manifest_path or default_manifest_path()
    return json.loads(path.read_text(encoding="utf-8"))


def download_benchmark_datasets(
    suites: list[str] | None = None,
    *,
    cache_dir: Path | None = None,
    force: bool = False,
) -> dict[str, dict[str, Any]]:
    """Download public benchmark datasets declared in `benchmarks/manifest.json`."""
    manifest = load_manifest()
    target_dir = Path(cache_dir or DEFAULT_BENCH_CACHE).expanduser()
    target_dir.mkdir(parents=True, exist_ok=True)
    requested = suites or [
        key for key, info in manifest["suites"].items() if not info.get("bundled")
    ]
    results: dict[str, dict[str, Any]] = {}
    for key in requested:
        info = manifest["suites"].get(key)
        if not info:
            raise ValueError(f"Unknown benchmark suite: {key}")
        if info.get("bundled"):
            results[key] = {"status": "bundled", "path": info["filename"]}
            continue
        dest = target_dir / info["filename"]
        if dest.is_file() and dest.stat().st_size > 0 and not force:
            results[key] = {
                "status": "cached",
                "path": str(dest),
                "bytes": dest.stat().st_size,
            }
            continue
        url = info["download_url"]
        tmp = dest.with_suffix(dest.suffix + ".part")
        with urllib.request.urlopen(url, timeout=180) as resp, tmp.open("wb") as fh:
            while True:
                chunk = resp.read(1024 * 256)
                if not chunk:
                    break
                fh.write(chunk)
        tmp.replace(dest)
        results[key] = {
            "status": "downloaded",
            "path": str(dest),
            "bytes": dest.stat().st_size,
        }
    return results


# ---------------------------------------------------------------------------
# Standard Academic Retrieval Metrics (Exact Definitions)
# ---------------------------------------------------------------------------
def _dcg_at_k(relevances: list[int], k: int) -> float:
    return sum(rel / math.log2(idx + 2) for idx, rel in enumerate(relevances[:k]) if rel > 0)


def compute_ranking_metrics(
    ranked_ids: list[str],
    gold_ids: set[str],
    *,
    ks: tuple[int, ...] = (1, 5, 10),
) -> dict[str, float]:
    """Compute Recall@K (any-hit), All-Recall@K, NDCG@K, and MRR for a single query."""
    if not gold_ids:
        out: dict[str, float] = {"mrr": 0.0}
        for k in ks:
            out[f"r@{k}"] = 0.0
            out[f"all_r@{k}"] = 0.0
            out[f"ndcg@{k}"] = 0.0
        return out

    deduped: list[str] = []
    seen: set[str] = set()
    for item in ranked_ids:
        if item not in seen:
            seen.add(item)
            deduped.append(item)

    rels = [1 if item in gold_ids else 0 for item in deduped]
    mrr = 0.0
    for idx, rel in enumerate(rels):
        if rel:
            mrr = 1.0 / (idx + 1)
            break

    metrics: dict[str, float] = {"mrr": mrr}
    for k in ks:
        top_k_set = set(deduped[:k])
        hits = len(top_k_set & gold_ids)
        metrics[f"r@{k}"] = 1.0 if hits > 0 else 0.0
        metrics[f"all_r@{k}"] = 1.0 if hits == len(gold_ids) else 0.0
        ideal_rels = [1] * min(len(gold_ids), k)
        idcg = _dcg_at_k(ideal_rels, k)
        metrics[f"ndcg@{k}"] = (_dcg_at_k(rels, k) / idcg) if idcg > 0 else 0.0
    return metrics


_ANS_TOKEN_RE = re.compile(r"[a-z0-9]{2,}")
_ANS_STOP = {
    "the",
    "and",
    "for",
    "with",
    "from",
    "that",
    "this",
    "was",
    "were",
    "are",
    "has",
    "have",
    "had",
    "her",
    "his",
    "she",
    "they",
    "their",
    "about",
    "into",
    "after",
    "before",
}


def answer_span_present(answer: Any, retrieved_texts: list[str]) -> bool:
    """Deterministic upper-bound proxy: checks if answer string or >=80% content tokens appear."""
    if answer is None:
        return False
    ans_str = str(answer).strip().casefold()
    if not ans_str:
        return False
    corpus = " ".join(retrieved_texts).casefold()
    if ans_str in corpus:
        return True
    toks = [t for t in _ANS_TOKEN_RE.findall(ans_str) if t not in _ANS_STOP]
    if not toks:
        return False
    matched = sum(1 for t in set(toks) if t in corpus)
    return (matched / len(set(toks))) >= 0.8


def _percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, int(round((pct / 100.0) * (len(ordered) - 1)))))
    return round(ordered[idx], 3)


def _mean_metrics(rows: list[dict[str, float]]) -> dict[str, float]:
    if not rows:
        return {}
    keys = list(rows[0].keys())
    return {k: round(sum(r[k] for r in rows) / len(rows), 4) for k in keys}


# ---------------------------------------------------------------------------
# Timestamp Parsers
# ---------------------------------------------------------------------------
def _parse_locomo_datetime_ms(raw: str | None, fallback_idx: int) -> int:
    base = 1_680_000_000_000 + fallback_idx * 86_400_000
    if not raw:
        return base
    cleaned = re.sub(r"\s+", " ", raw.strip())
    for fmt in (
        "%I:%M %p on %d %B, %Y",
        "%I:%M %p on %d %b, %Y",
        "%I:%M %p on %B %d, %Y",
    ):
        try:
            dt = datetime.datetime.strptime(cleaned, fmt).replace(tzinfo=datetime.UTC)
            return int(dt.timestamp() * 1000)
        except ValueError:
            continue
    return base


def _parse_longmemeval_datetime_ms(raw: str | None, fallback_idx: int) -> int:
    base = 1_680_000_000_000 + fallback_idx * 86_400_000
    if not raw:
        return base
    # Example: "2023/04/10 (Mon) 17:50"
    m = re.search(r"(\d{4})/(\d{2})/(\d{2}).*?(\d{2}):(\d{2})", raw)
    if m:
        y, mo, d, hh, mm = (int(g) for g in m.groups())
        dt = datetime.datetime(y, mo, d, hh, mm, tzinfo=datetime.UTC)
        return int(dt.timestamp() * 1000)
    return base


# ---------------------------------------------------------------------------
# Report Models
# ---------------------------------------------------------------------------
class BenchmarkFailureSample(BaseModel):
    suite: str
    item_id: str
    category: str
    question: str
    expected_answer: str = ""
    gold_ids: list[str] = Field(default_factory=list)
    retrieved_top_ids: list[str] = Field(default_factory=list)
    retrieved_top_snippets: list[str] = Field(default_factory=list)
    reason: str = ""


class StandardBenchmarkReport(BaseModel):
    suite: str
    mode: str
    engine_label: str
    dataset_path: str
    evaluated_at_ms: int
    total_questions: int
    scored_questions: int
    abstention_questions: int = 0
    overall: dict[str, float] = Field(default_factory=dict)
    by_category: dict[str, dict[str, Any]] = Field(default_factory=dict)
    abstention_metrics: dict[str, float] = Field(default_factory=dict)
    latency_p50_ms: float = 0.0
    latency_p95_ms: float = 0.0
    total_elapsed_s: float = 0.0
    sample_failures: list[BenchmarkFailureSample] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# LoCoMo Adapter (ACL 2024)
# ---------------------------------------------------------------------------
def _parse_locomo_evidence(raw_ev: list[str] | None) -> set[str]:
    """Normalize LoCoMo evidence strings like `['D1:3', 'D2:4; D2:5']` into dia_id set."""
    out: set[str] = set()
    for item in raw_ev or []:
        for part in re.split(r"[;,]\s*", str(item)):
            cleaned = part.strip()
            if cleaned:
                out.add(cleaned)
    return out


def _retrieve_locomo_ranked(
    store: HubStore,
    *,
    question: str,
    mode: str,
    top_k: int,
    raw_to_dia: dict[str, str],
    dia_to_text: dict[str, str],
    ep_to_dias: dict[str, list[str]],
    dia_to_prev: dict[str, str] | None = None,
    dia_to_next: dict[str, str] | None = None,
    use_semantic: bool = False,
    embed_model: str | None = None,
    embed_cache: Any | None = None,
    use_reranker: bool = False,
    rerank_model: str | None = None,
) -> tuple[list[str], list[str]]:
    """Query genuine `HubStore` and return ranked `(dia_ids, snippets)`."""
    ranked_dias: list[str] = []
    snippets: list[str] = []
    seen_dias: set[str] = set()

    def _push_dia(dia: str, snippet_override: str | None = None) -> None:
        if dia in seen_dias:
            return
        seen_dias.add(dia)
        ranked_dias.append(dia)
        snippets.append((snippet_override or dia_to_text.get(dia, ""))[:260])

    cand_limit = max(top_k * 3, 30) if use_reranker else max(top_k * 2, 20)
    best_snippet: dict[str, str] = {}
    rrf_order: list[str] = []

    from context_hub.graph import analyze_query_structure

    q_plan = analyze_query_structure(question)
    mem_ev_map: dict[str, list[str]] = {}
    mem_body_map: dict[str, str] = {}

    if mode == "curated":
        res = store.search_context(
            question,
            limit=cand_limit,
            agent=True,
            max_tokens=32_000,
            use_semantic=use_semantic,
            embed_model=embed_model,
            embed_cache=embed_cache,
            use_reranker=use_reranker,
            rerank_model=rerank_model,
            rerank_kinds=("memory",) if use_reranker else (),
        )
        # Fuse L3 Curated Observations (evidence_ids, already CE-reranked when use_reranker=True),
        # L1 Raw Turns, and L2 Episodes via RRF
        scores: dict[str, float] = {}
        obs_by_dia: dict[str, str] = {}
        rrf_k = 15.0

        for rank, mem in enumerate(res.get("memories") or []):
            mid = str(mem["id"])
            ev_ids = list(mem.get("evidence_ids") or [])
            mem_ev_map[mid] = ev_ids
            mem_body_map[mid] = str(mem.get("body") or "")
            for eid in ev_ids:
                dia = raw_to_dia.get(eid)
                if dia:
                    scores[dia] = scores.get(dia, 0.0) + (1.45 if use_reranker else 1.25) / (
                        rrf_k + rank + 1
                    )
                    if dia not in best_snippet:
                        best_snippet[dia] = f"[L3 Memory] {mem['body']} || {dia_to_text.get(dia, '')}"
                    if dia not in obs_by_dia:
                        obs_by_dia[dia] = str(mem.get("body") or "")

        for rank, hit in enumerate(res.get("raw_matches") or []):
            dia = raw_to_dia.get(hit["id"])
            if dia:
                scores[dia] = scores.get(dia, 0.0) + 1.0 / (rrf_k + rank + 1)
                if dia not in best_snippet:
                    best_snippet[dia] = hit.get("snippet") or dia_to_text.get(dia, "")

        for rank, ep in enumerate(res.get("episodes") or []):
            for dia in ep_to_dias.get(ep["id"], [])[:6]:
                scores[dia] = scores.get(dia, 0.0) + 0.35 / (rrf_k + rank + 1)
                if dia not in best_snippet:
                    best_snippet[dia] = f"[L2 Episode] {ep.get('summary') or ''} || {dia_to_text.get(dia, '')}"

        # Track A: Syntactic Multi-Hop / Dual-Entity / Choice Sub-Query Fusion (gentle recall boost)
        for sq in q_plan.sub_queries[:2]:
            sub_res = store.search_context(
                sq,
                limit=10,
                agent=True,
                max_tokens=16_000,
                use_semantic=use_semantic,
                embed_model=embed_model,
                embed_cache=embed_cache,
                use_reranker=False,
            )
            for rank, mem in enumerate(sub_res.get("memories") or []):
                for eid in mem.get("evidence_ids") or []:
                    dia = raw_to_dia.get(eid)
                    if dia:
                        scores[dia] = scores.get(dia, 0.0) + 0.35 / (rrf_k + rank + 1)
                        if dia not in best_snippet:
                            best_snippet[dia] = f"[L3 Memory] {mem['body']} || {dia_to_text.get(dia, '')}"
                        if dia not in obs_by_dia:
                            obs_by_dia[dia] = str(mem.get("body") or "")
            for rank, hit in enumerate(sub_res.get("raw_matches") or []):
                dia = raw_to_dia.get(hit["id"])
                if dia:
                    scores[dia] = scores.get(dia, 0.0) + 0.25 / (rrf_k + rank + 1)
                    if dia not in best_snippet:
                        best_snippet[dia] = hit.get("snippet") or dia_to_text.get(dia, "")

        # Track A: 2-Hop Curated-Observation Entity-Concept Graph Walk (strict co-occurrence)
        if q_plan.is_multi_hop or q_plan.is_open_inference:
            seed_obs = [str(m.get("body") or "") for m in (res.get("memories") or [])[:5]] + [
                str(h.get("snippet") or "") for h in (res.get("raw_matches") or [])[:4]
            ]
            graph_mems = store.graph_bridge_search(
                question, seed_obs, item_kind="memory", top_k=12, agent=True
            )
            if graph_mems:
                missing_mids = [mid for mid, _ in graph_mems if mid not in mem_ev_map]
                if missing_mids:
                    for mid in missing_mids:
                        try:
                            mobj = store.expand(mid, kind="memory", level="summary", agent=True)[
                                "record"
                            ]
                            mem_ev_map[mid] = list(mobj.get("evidence_ids") or [])
                            mem_body_map[mid] = str(mobj.get("body") or "")
                        except Exception:
                            mem_ev_map[mid] = []
                for rank, (mid, _) in enumerate(graph_mems):
                    for eid in mem_ev_map.get(mid) or []:
                        dia = raw_to_dia.get(eid)
                        if dia:
                            scores[dia] = scores.get(dia, 0.0) + 0.32 / (rrf_k + rank + 1)
                            if dia not in obs_by_dia and mem_body_map.get(mid):
                                obs_by_dia[dia] = mem_body_map[mid]
                            if dia not in best_snippet and mem_body_map.get(mid):
                                best_snippet[dia] = (
                                    f"[L3 Graph] {mem_body_map[mid]} || {dia_to_text.get(dia, '')}"
                                )

        rrf_order = [dia for dia, _ in sorted(scores.items(), key=lambda kv: kv[1], reverse=True)]
    elif use_semantic:
        obs_by_dia = {}
        scores_raw: dict[str, float] = {}
        rrf_k = 15.0
        res = store.search_context(
            question,
            limit=cand_limit,
            agent=True,
            max_tokens=32_000,
            use_semantic=True,
            embed_model=embed_model,
            embed_cache=embed_cache,
        )
        for rank, hit in enumerate(res.get("raw_matches") or []):
            dia = raw_to_dia.get(hit["id"])
            if dia:
                scores_raw[dia] = scores_raw.get(dia, 0.0) + 1.0 / (rrf_k + rank + 1)
                if dia not in best_snippet:
                    best_snippet[dia] = hit.get("snippet") or dia_to_text.get(dia, "")
        for sq in q_plan.sub_queries[:2]:
            sub_res = store.search_context(
                sq,
                limit=14,
                agent=True,
                max_tokens=16_000,
                use_semantic=True,
                embed_model=embed_model,
                embed_cache=embed_cache,
            )
            for rank, hit in enumerate(sub_res.get("raw_matches") or []):
                dia = raw_to_dia.get(hit["id"])
                if dia:
                    scores_raw[dia] = scores_raw.get(dia, 0.0) + 0.65 / (rrf_k + rank + 1)
                    if dia not in best_snippet:
                        best_snippet[dia] = hit.get("snippet") or dia_to_text.get(dia, "")
        rrf_order = [
            dia for dia, _ in sorted(scores_raw.items(), key=lambda kv: kv[1], reverse=True)
        ]
    else:
        obs_by_dia = {}
        raw_hits = store.list_raw(q=question, limit=max(top_k, 15), agent=True)
        for hit in raw_hits:
            dia = raw_to_dia.get(hit["id"])
            if dia and dia not in best_snippet:
                rrf_order.append(dia)
                best_snippet[dia] = hit.get("body_text") or dia_to_text.get(dia, "")

    if use_reranker and rrf_order:
        from context_hub.semantic import (
            calibrate_rerank_blend,
            rerank_candidates,
            reranker_available,
            select_rerank_model,
        )

        if reranker_available():
            # Expand top-12 RRF hits with ±1 (other speaker) AND ±2 (same speaker continuation)
            # neighbors so elliptical & multi-turn continuations enter the Cross-Encoder pool.
            prev_map = dia_to_prev or {}
            next_map = dia_to_next or {}
            pool: list[str] = []
            seen_p: set[str] = set()
            for d in rrf_order[:22]:
                if d not in seen_p:
                    seen_p.add(d)
                    pool.append(d)
            for d in rrf_order[:12]:
                p1 = prev_map.get(d)
                n1 = next_map.get(d)
                p2 = prev_map.get(p1) if p1 else None
                n2 = next_map.get(n1) if n1 else None
                for nb in (n1, p1, n2, p2):
                    if nb and nb not in seen_p and len(pool) < 42:
                        seen_p.add(nb)
                        pool.append(nb)

            cand_pairs: list[tuple[str, str]] = []
            for d in pool:
                cur_t = dia_to_text.get(d, "")
                p1 = prev_map.get(d)
                p2 = prev_map.get(p1) if p1 else None
                n1 = next_map.get(d)
                doc_parts = [cur_t]
                obs_txt = obs_by_dia.get(d)
                if obs_txt:
                    doc_parts.append(f"[Fact summary] {obs_txt[:260]}")
                if p1 and dia_to_text.get(p1):
                    doc_parts.append(f"[Prev turn] {dia_to_text[p1][:220]}")
                if p2 and dia_to_text.get(p2):
                    doc_parts.append(f"[Earlier turn] {dia_to_text[p2][:180]}")
                # Bidirectional follow-up cue ONLY for image-bearing turns ("take a look at this")
                if n1 and dia_to_text.get(n1) and "(image:" in cur_t:
                    doc_parts.append(f"[Next reply] {dia_to_text[n1][:140]}")
                cand_pairs.append((d, "\n".join(doc_parts)))

            rmodel = select_rerank_model(question, rerank_model)
            ce_scored = rerank_candidates(question, cand_pairs, model_name=rmodel)
            if ce_scored:
                blended = calibrate_rerank_blend(
                    rrf_order[:28],
                    ce_scored,
                    high_ce_weight=0.80,
                    low_ce_weight=0.45,
                )
                rrf_order = [d for d, _ in blended]

    for dia in rrf_order[:top_k]:
        _push_dia(dia, best_snippet.get(dia))

    return ranked_dias[:top_k], snippets[:top_k]


def evaluate_locomo(
    dataset_path: Path,
    *,
    mode: str = "raw",
    engine_label: str = "raw-memory",
    top_k: int = 10,
    limit_convs: int | None = None,
    max_failures: int = 25,
    use_semantic: bool = False,
    embed_model: str | None = None,
    embed_cache_path: Path | None = None,
    use_reranker: bool = False,
    rerank_model: str | None = None,
    e2e_pack_dir: Path | None = None,
) -> StandardBenchmarkReport:
    """Evaluate Raw Memory on LoCoMo (`locomo10.json` or schema-compatible fixture)."""
    t_wall0 = time.perf_counter()
    data = json.loads(Path(dataset_path).expanduser().read_text(encoding="utf-8"))
    if limit_convs is not None:
        data = data[:limit_convs]

    embed_cache = None
    if use_semantic:
        from context_hub.semantic import PersistentEmbedCache

        cache_db = embed_cache_path or (DEFAULT_BENCH_CACHE / "embed_cache.sqlite3")
        embed_cache = PersistentEmbedCache(cache_db)

    all_rows: list[dict[str, float]] = []
    by_cat_rows: dict[str, list[dict[str, float]]] = defaultdict(list)
    latencies: list[float] = []
    failures: list[BenchmarkFailureSample] = []
    total_q = 0
    scored_q = 0
    e2e_reader_rows: list[dict[str, Any]] = []
    e2e_gold_map: dict[str, dict[str, Any]] = {}

    try:
      for conv_idx, sample in enumerate(data):
        conv = sample["conversation"]
        session_nums = sorted(
            int(k.split("_")[1])
            for k in conv
            if k.startswith("session_") and not k.endswith("_date_time") and isinstance(conv[k], list)
        )
        sessions_payload: list[dict[str, Any]] = []
        raw_to_dia: dict[str, str] = {}
        dia_to_raw: dict[str, str] = {}
        dia_to_text: dict[str, str] = {}
        dia_to_prev: dict[str, str] = {}
        dia_to_next: dict[str, str] = {}
        ep_to_dias: dict[str, list[str]] = {}
        summaries = sample.get("session_summary") or {}

        for snum in session_nums:
            ep_id = f"ep_c{conv_idx}_s{snum}"
            date_str = str(conv.get(f"session_{snum}_date_time") or "")
            t_sess = _parse_locomo_datetime_ms(date_str, snum)
            turns_in = conv[f"session_{snum}"]
            turns_payload: list[dict[str, Any]] = []
            ep_dias: list[str] = []
            for tidx, turn in enumerate(turns_in):
                dia_id = str(turn.get("dia_id") or f"D{snum}:{tidx + 1}")
                raw_id = f"ev_c{conv_idx}_{dia_id.replace(':', '_')}"
                speaker = str(turn.get("speaker") or "speaker")
                text = str(turn.get("text") or "")
                caption = str(turn.get("blip_caption") or "").strip()
                full_text = f"[{date_str}] {speaker}: {text}" + (
                    f" (image: {caption})" if caption else ""
                )
                raw_to_dia[raw_id] = dia_id
                dia_to_raw[dia_id] = raw_id
                dia_to_text[dia_id] = full_text
                if ep_dias:
                    prev_d = ep_dias[-1]
                    dia_to_prev[dia_id] = prev_d
                    dia_to_next[prev_d] = dia_id
                ep_dias.append(dia_id)
                turns_payload.append(
                    {
                        "id": raw_id,
                        "source_id": dia_id,
                        "t_start": t_sess + tidx * 30_000,
                        "actor": speaker,
                        "title": f"{speaker} ({date_str})" if date_str else speaker,
                        "text": full_text,
                        "locator": f"locomo://{sample.get('sample_id', conv_idx)}#{dia_id}",
                    }
                )
            ep_to_dias[ep_id] = ep_dias
            ep_summary = str(summaries.get(f"session_{snum}_summary") or "") if mode == "curated" else ""
            sessions_payload.append(
                {
                    "episode_id": ep_id,
                    "title": f"Session {snum} ({date_str})" if date_str else f"Session {snum}",
                    "summary": ep_summary,
                    "status": "curated" if ep_summary else "pending_curation",
                    "t_start": t_sess,
                    "t_end": t_sess + max(1, len(turns_payload)) * 30_000,
                    "turns": turns_payload,
                }
            )

        memories_payload: list[dict[str, Any]] = []
        if mode == "curated":
            obs_root = sample.get("observation") or {}
            for snum in session_nums:
                sess_obs = obs_root.get(f"session_{snum}_observation") or {}
                date_str = str(conv.get(f"session_{snum}_date_time") or "")
                if isinstance(sess_obs, dict):
                    for speaker, entries in sess_obs.items():
                        if not isinstance(entries, list):
                            continue
                        for oidx, entry in enumerate(entries):
                            if not isinstance(entry, list) or len(entry) < 2:
                                continue
                            fact_text = str(entry[0]).strip()
                            ev_dias = _parse_locomo_evidence(
                                [entry[1]] if isinstance(entry[1], str) else entry[1]
                            )
                            ev_rids = [dia_to_raw[d] for d in ev_dias if d in dia_to_raw]
                            if not fact_text or not ev_rids:
                                continue
                            memories_payload.append(
                                {
                                    "id": f"mem_c{conv_idx}_s{snum}_{speaker}_{oidx}",
                                    "title": f"{speaker} observation ({date_str})" if date_str else speaker,
                                    "body": f"[{date_str}] {fact_text}" if date_str else fact_text,
                                    "kind": "fact",
                                    "tags": [speaker, f"session_{snum}"],
                                    "evidence_ids": ev_rids,
                                }
                            )

        store = HubStore(Path("/tmp/raw-memory-bench-unused"), in_memory=True)
        try:
            store.ingest_sessions_bulk(
                sessions_payload,
                memories=memories_payload if mode == "curated" else None,
                project=f"locomo-{sample.get('sample_id', conv_idx)}",
            )
            store.index_entity_graph(
                kinds=("raw", "memory") if mode == "curated" else ("raw",),
            )
            if use_semantic:
                store.index_semantic(
                    kinds=("raw", "episode", "memory") if mode == "curated" else ("raw",),
                    model_name=embed_model,
                    embed_cache=embed_cache,
                    contextualize_turns=use_reranker,
                )

            for qidx, qa in enumerate(sample.get("qa") or []):
                total_q += 1
                cat_num = int(qa.get("category") or 0)
                cat_name = LOCOMO_CATEGORIES.get(cat_num, f"cat_{cat_num}")
                question = str(qa.get("question") or "")
                gold_dias = _parse_locomo_evidence(qa.get("evidence"))
                if not gold_dias:
                    continue
                scored_q += 1

                t0 = time.perf_counter()
                ranked_dias, snippets = _retrieve_locomo_ranked(
                    store,
                    question=question,
                    mode=mode,
                    top_k=top_k,
                    raw_to_dia=raw_to_dia,
                    dia_to_text=dia_to_text,
                    ep_to_dias=ep_to_dias,
                    dia_to_prev=dia_to_prev,
                    dia_to_next=dia_to_next,
                    use_semantic=use_semantic,
                    embed_model=embed_model,
                    embed_cache=embed_cache,
                    use_reranker=use_reranker,
                    rerank_model=rerank_model,
                )
                latencies.append((time.perf_counter() - t0) * 1000.0)

                m = compute_ranking_metrics(ranked_dias, gold_dias, ks=(1, 5, 10))
                if cat_num != 5:
                    ans = qa.get("answer")
                    m["ans_cov@5"] = 1.0 if answer_span_present(ans, snippets[:5]) else 0.0
                    m["ans_cov@10"] = 1.0 if answer_span_present(ans, snippets[:10]) else 0.0
                else:
                    # For adversarial category 5, retrieving the refuting evidence turn is the goal
                    m["ans_cov@5"] = m["r@5"]
                    m["ans_cov@10"] = m["r@10"]

                all_rows.append(m)
                by_cat_rows[cat_name].append(m)

                if e2e_pack_dir is not None:
                    item_id = f"{sample.get('sample_id', conv_idx)}#q{qidx}"
                    is_adv = cat_num == 5
                    gold_ans = (
                        f"UNANSWERABLE / FALSE PREMISE (adversarial trap: {qa.get('adversarial_answer', '')})"
                        if is_adv
                        else str(qa.get("answer") or "")
                    )
                    ctx_lines: list[str] = []
                    seen_cd: set[str] = set()
                    for r_i, (dia, snip) in enumerate(
                        zip(ranked_dias[:top_k], snippets[:top_k], strict=False)
                    ):
                        blk: list[str] = []
                        if snip.startswith("[L3"):
                            blk.append(f"  {snip.split(' || ', 1)[0]}")
                        for nb_d in (dia_to_prev.get(dia), dia, dia_to_next.get(dia)):
                            if nb_d and nb_d not in seen_cd and nb_d in dia_to_text:
                                seen_cd.add(nb_d)
                                mark = " *" if nb_d == dia else ""
                                blk.append(f"  [{nb_d}{mark}] {dia_to_text[nb_d]}")
                        if blk:
                            ctx_lines.append(f"Excerpt #{r_i + 1}:\n" + "\n".join(blk))
                    ctx_text = "\n".join(ctx_lines)[:9000]
                    full_hist_chars = sum(len(t) + 4 for t in dia_to_text.values())
                    e2e_reader_rows.append(
                        {
                            "item_id": item_id,
                            "question": question,
                            "question_date": "",
                            "context_text": ctx_text,
                            "context_tokens": max(1, len(ctx_text) // 4),
                        }
                    )
                    e2e_gold_map[item_id] = {
                        "item_id": item_id,
                        "category": cat_name,
                        "is_abstention": is_adv,
                        "question": question,
                        "question_date": "",
                        "gold_answer": gold_ans,
                        "retrieval_hit_at_5": bool(m["r@5"] > 0),
                        "retrieval_hit_at_10": bool(m["r@10"] > 0),
                        "context_tokens": max(1, len(ctx_text) // 4),
                        "full_history_tokens": max(1, full_hist_chars // 4),
                    }

                if m["r@5"] == 0.0 and len(failures) < max_failures:
                    failures.append(
                        BenchmarkFailureSample(
                            suite="locomo",
                            item_id=f"{sample.get('sample_id', conv_idx)}#q{qidx}",
                            category=cat_name,
                            question=question,
                            expected_answer=str(
                                qa.get("answer") or qa.get("adversarial_answer") or ""
                            ),
                            gold_ids=sorted(gold_dias),
                            retrieved_top_ids=ranked_dias[:5],
                            retrieved_top_snippets=snippets[:3],
                            reason="miss_at_5" if ranked_dias else "zero_hits",
                        )
                    )
        finally:
            store.close()
    finally:
        if embed_cache is not None:
            embed_cache.close()

    if e2e_pack_dir is not None:
        out_p = Path(e2e_pack_dir)
        out_p.mkdir(parents=True, exist_ok=True)
        with (out_p / "reader_inputs.jsonl").open("w", encoding="utf-8") as fh:
            for r_row in e2e_reader_rows:
                fh.write(json.dumps(r_row, ensure_ascii=False) + "\n")
        (out_p / "gold_key.json").write_text(
            json.dumps(e2e_gold_map, indent=2, ensure_ascii=False), encoding="utf-8"
        )

    by_category = {
        cat: {"count": len(rows), **_mean_metrics(rows)}
        for cat, rows in sorted(by_cat_rows.items())
    }
    mode_tag = mode
    if use_semantic:
        mode_tag += "+semantic"
    if use_reranker:
        mode_tag += "+rerank"
    return StandardBenchmarkReport(
        suite="locomo",
        mode=mode_tag,
        engine_label=engine_label,
        dataset_path=str(dataset_path),
        evaluated_at_ms=now_ms(),
        total_questions=total_q,
        scored_questions=scored_q,
        overall=_mean_metrics(all_rows),
        by_category=by_category,
        latency_p50_ms=_percentile(latencies, 50),
        latency_p95_ms=_percentile(latencies, 95),
        total_elapsed_s=round(time.perf_counter() - t_wall0, 2),
        sample_failures=failures,
    )


# ---------------------------------------------------------------------------
# LongMemEval Adapter (ICLR 2025: LongMemEval-S & LongMemEval-Oracle)
# ---------------------------------------------------------------------------
def evaluate_longmemeval(
    dataset_path: Path,
    *,
    split_name: str = "longmemeval-s",
    engine_label: str = "raw-memory",
    top_k: int = 10,
    limit_questions: int | None = None,
    max_failures: int = 25,
    use_semantic: bool = False,
    embed_model: str | None = None,
    embed_cache_path: Path | None = None,
    use_reranker: bool = False,
    rerank_model: str | None = None,
    e2e_pack_dir: Path | None = None,
) -> StandardBenchmarkReport:
    """Evaluate Raw Memory on LongMemEval-S or LongMemEval-Oracle.

    Measures official LongMemEval retrieval metrics:
      - Session-level: `sess_r@1`, `sess_r@5`, `sess_r@10`, `sess_all_r@5`, `sess_all_r@10`,
        `sess_ndcg@5`, `sess_ndcg@10`, `sess_mrr`
      - Turn-level: `turn_r@1`, `turn_r@5`, `turn_r@10`, `turn_ndcg@5`, `turn_ndcg@10`,
        `turn_mrr`
      - Answer-span coverage proxy (`ans_cov@5`, `ans_cov@10`)
      - Separate abstention (`_abs`) tracking so positive-evidence scores stay clean.
    """
    t_wall0 = time.perf_counter()
    data = json.loads(Path(dataset_path).expanduser().read_text(encoding="utf-8"))
    if limit_questions is not None:
        data = data[:limit_questions]

    embed_cache = None
    if use_semantic:
        from context_hub.semantic import PersistentEmbedCache

        cache_db = embed_cache_path or (DEFAULT_BENCH_CACHE / "embed_cache.sqlite3")
        embed_cache = PersistentEmbedCache(cache_db)

    pos_rows: list[dict[str, float]] = []
    abs_rows: list[dict[str, float]] = []
    by_cat_rows: dict[str, list[dict[str, float]]] = defaultdict(list)
    latencies: list[float] = []
    failures: list[BenchmarkFailureSample] = []
    e2e_reader_rows: list[dict[str, Any]] = []
    e2e_gold_map: dict[str, dict[str, Any]] = {}

    try:
      for item in data:
        qid = str(item["question_id"])
        qtype = str(item["question_type"])
        is_abs = qid.endswith("_abs")
        question = str(item["question"])
        answer = item.get("answer")
        sess_ids: list[str] = list(item["haystack_session_ids"])
        sess_dates: list[str] = list(item["haystack_dates"])
        sessions_raw: list[list[dict[str, Any]]] = list(item["haystack_sessions"])
        gold_sess_ids = set(item.get("answer_session_ids") or [])

        sessions_payload: list[dict[str, Any]] = []
        gold_turn_ids: set[str] = set()
        raw_to_sess: dict[str, str] = {}
        raw_to_text: dict[str, str] = {}
        raw_to_meta: dict[str, tuple[str, str, str, str]] = {}  # (role, sdate, content, prev_content)
        ep_to_sess: dict[str, str] = {}
        sess_to_raw_ids: dict[str, list[str]] = defaultdict(list)

        for sidx, (sid, sdate, turns) in enumerate(
            zip(sess_ids, sess_dates, sessions_raw, strict=False)
        ):
            t_sess = _parse_longmemeval_datetime_ms(sdate, sidx)
            ep_id = f"{sid}__s{sidx}"
            ep_to_sess[ep_id] = sid
            turns_payload: list[dict[str, Any]] = []
            prev_content = ""
            for tidx, turn in enumerate(turns):
                rid = f"t_{sidx}_{tidx}"
                role = str(turn.get("role") or "user")
                actor = "self" if role == "user" else "assistant"
                content = str(turn.get("content") or "")
                stamped = f"[{sdate}] {role}: {content}"
                raw_to_sess[rid] = sid
                raw_to_text[rid] = stamped
                raw_to_meta[rid] = (role, sdate, content, prev_content)
                prev_content = content[:260]
                sess_to_raw_ids[sid].append(rid)
                if turn.get("has_answer"):
                    gold_turn_ids.add(rid)
                turns_payload.append(
                    {
                        "id": rid,
                        "source_id": f"{ep_id}#t{tidx}",
                        "t_start": t_sess + tidx * 10_000,
                        "actor": actor,
                        "title": f"Session {sid} ({sdate})",
                        "text": stamped,
                        "locator": f"longmemeval://{qid}/{sid}#t{tidx}",
                    }
                )
            sessions_payload.append(
                {
                    "episode_id": ep_id,
                    "title": f"Session {sid} ({sdate})",
                    "summary": "",
                    "status": "pending_curation",
                    "t_start": t_sess,
                    "t_end": t_sess + max(1, len(turns_payload)) * 10_000,
                    "turns": turns_payload,
                }
            )

        q_date_ms = _parse_longmemeval_datetime_ms(item.get("question_date"), len(sess_ids))
        store = HubStore(Path("/tmp/raw-memory-bench-unused"), in_memory=True)
        try:
            store.ingest_sessions_bulk(sessions_payload, project=f"lme-{qid}")
            if use_semantic:
                # Stage 1: Multi-chunk topic-preserving Episode MaxSim when reranker/v0.6 is active,
                # or single-vector episode embedding for v0.5 semantic-only mode.
                store.index_semantic(
                    kinds=("episode_chunk",) if use_reranker else ("episode",),
                    model_name=embed_model,
                    embed_cache=embed_cache,
                )

            t0 = time.perf_counter()
            searched = store.search_context(
                question,
                reference_time_ms=q_date_ms,
                limit=max(top_k * 2, 24),
                agent=True,
                max_tokens=32_000,
                use_semantic=use_semantic,
                embed_model=embed_model,
                embed_cache=embed_cache,
                use_reranker=use_reranker,
                rerank_model=rerank_model,
                rerank_kinds=("episode",) if use_reranker else (),
            )

            raw_hits = searched.get("raw_matches") or []
            ep_hits = searched.get("episodes") or []
            tw_meta = searched.get("temporal_window")

            # Derive session ranking: `ep_hits` from `store.search_context` ALREADY fuses
            # BM25 + Multi-Chunk MaxSim + Temporal Window + Stage-1.5 Session-Chunk Cross-Encoder.
            sess_scores: dict[str, float] = {}
            rrf_k = 15.0
            for rank, ep in enumerate(ep_hits):
                sid = ep_to_sess.get(ep["id"], ep["id"])
                sess_scores[sid] = sess_scores.get(sid, 0.0) + (2.00 if use_semantic else 1.15) / (
                    rrf_k + rank + 1
                )
            if not use_semantic:
                seen_raw_sess: dict[str, int] = {}
                for rank, hit in enumerate(raw_hits):
                    sid = raw_to_sess.get(hit["id"])
                    if sid:
                        cnt = seen_raw_sess.get(sid, 0)
                        if cnt < 2:
                            decay = 1.0 if cnt == 0 else 0.25
                            sess_scores[sid] = sess_scores.get(sid, 0.0) + (
                                0.90 * decay / (rrf_k + rank + 1)
                            )
                            seen_raw_sess[sid] = cnt + 1
            ranked_sessions = [
                sid for sid, _ in sorted(sess_scores.items(), key=lambda kv: kv[1], reverse=True)
            ][: max(top_k, 12)]

            bm25_turns = [h["id"] for h in raw_hits]
            if use_semantic and embed_cache is not None:
                # Stage 2: Turn-level dense semantic reranking inside top candidate sessions
                from context_hub.semantic import (
                    DEFAULT_EMBED_MODEL,
                    calibrate_rerank_blend,
                    cosine_top_k,
                    query_targets_assistant,
                    rerank_candidates,
                    reranker_available,
                    rrf_fuse_lists,
                    select_rerank_model,
                )

                active_model = embed_model or DEFAULT_EMBED_MODEL
                from context_hub.temporal import TemporalWindow, temporal_proximity_score

                tw_obj = (
                    TemporalWindow(
                        start_ms=int(tw_meta["start_ms"]),
                        end_ms=int(tw_meta["end_ms"]),
                        center_ms=int(tw_meta["center_ms"]),
                        specificity=str(tw_meta.get("specificity") or "range"),
                        matched_phrase=str(tw_meta.get("matched_phrase") or ""),
                    )
                    if tw_meta
                    else None
                )
                sess_date_ms_map = {
                    sid: _parse_longmemeval_datetime_ms(sdate, idx)
                    for idx, (sid, sdate) in enumerate(zip(sess_ids, sess_dates, strict=False))
                }
                cand_sess_n = 10 if use_reranker else 8
                cand_rids: list[str] = []
                seen_r: set[str] = set()
                cand_sids_list = list(ranked_sessions[:cand_sess_n])
                # Guarantee exact-date sessions inside a point-in-time window enter Stage-2 turns
                if tw_obj is not None and tw_obj.specificity == "point":
                    for sid, s_ms in sess_date_ms_map.items():
                        prox_s = temporal_proximity_score(s_ms, s_ms, tw_obj)
                        if prox_s >= 0.65 and sid not in cand_sids_list:
                            cand_sids_list.append(sid)
                        if prox_s >= 0.80:
                            sess_scores[sid] = sess_scores.get(sid, 0.0) + 0.10 * prox_s
                for sid in cand_sids_list:
                    for rid in sess_to_raw_ids.get(sid, []):
                        if rid not in seen_r:
                            seen_r.add(rid)
                            cand_rids.append(rid)
                for rid in bm25_turns[:20]:
                    if rid not in seen_r:
                        seen_r.add(rid)
                        cand_rids.append(rid)

                if cand_rids:
                    cand_texts = [raw_to_text.get(rid, "")[:1400] for rid in cand_rids]
                    q_vec = embed_cache.embed_texts([question], model_name=active_model)[0]
                    cand_mat = embed_cache.embed_texts(cand_texts, model_name=active_model)
                    sem_turn_pairs = cosine_top_k(
                        q_vec, cand_rids, cand_mat, top_k=max(top_k * 3, 30)
                    )
                    sem_turns = [rid for rid, _ in sem_turn_pairs]
                    turn_lists: list[tuple[list[str], float]] = [
                        (bm25_turns, 0.95),
                        (sem_turns, 1.45),
                    ]
                    if tw_obj is not None:
                        tw_turn_scored: list[tuple[str, float]] = []
                        for rid, sc in sem_turn_pairs:
                            sid_t = raw_to_sess.get(rid, "")
                            t_ms_t = sess_date_ms_map.get(sid_t, 0)
                            prox_t = temporal_proximity_score(t_ms_t, t_ms_t, tw_obj)
                            if prox_t > 0.15:
                                tw_turn_scored.append((rid, 0.55 * sc + 0.45 * prox_t))
                        tw_turn_scored.sort(key=lambda kv: kv[1], reverse=True)
                        tw_turn_ids = [rid for rid, _ in tw_turn_scored]
                        if tw_turn_ids:
                            turn_lists.append(
                                (tw_turn_ids, 1.45 if tw_obj.specificity == "point" else 0.70)
                            )
                    fused_turns = rrf_fuse_lists(turn_lists, k=20.0)

                    # Stage 3: Local ONNX Cross-Encoder with confidence-adaptive calibrated blend
                    if use_reranker and reranker_available() and fused_turns:
                        ce_pool = fused_turns[:28]
                        ce_pairs: list[tuple[str, str]] = []
                        for rid in ce_pool:
                            role, sdate, content, prev_c = raw_to_meta.get(
                                rid, ("user", "", raw_to_text.get(rid, ""), "")
                            )
                            if role == "user":
                                # Keep user turns crisp & unpolluted by verbose prior assistant monologues
                                doc = f"User ({sdate}): {content[:950]}"
                            else:
                                doc = f"Assistant ({sdate}): {content[:950]}"
                                # Only attach prior user turn when it was a question (avoids copying
                                # user fact statements into assistant replies and stealing Turn R@1!)
                                if prev_c and "?" in prev_c:
                                    doc += f"\n[In reply to question]: {prev_c[:150]}"
                            ce_pairs.append((rid, doc))
                        rmodel = select_rerank_model(question, rerank_model)
                        ce_scored = rerank_candidates(question, ce_pairs, model_name=rmodel)
                        if ce_scored:
                            # First-person authority prior (RFC-0003): human-authored turns are
                            # primary ground truth unless the query explicitly recalls a prior
                            # assistant response/recommendation.
                            asks_assistant = query_targets_assistant(question)
                            role_bonuses: dict[str, float] = {}
                            for rid in ce_pool:
                                role_r = raw_to_meta.get(rid, ("user", "", "", ""))[0]
                                b_val = 0.0
                                if asks_assistant and role_r == "assistant":
                                    b_val += 0.14
                                elif not asks_assistant and role_r == "user":
                                    b_val += 0.16
                                if tw_obj is not None and tw_obj.specificity == "point":
                                    sid_r = raw_to_sess.get(rid, "")
                                    t_ms_r = sess_date_ms_map.get(sid_r, 0)
                                    prox_r = temporal_proximity_score(t_ms_r, t_ms_r, tw_obj)
                                    if prox_r > 0.2:
                                        b_val += 0.34 * prox_r
                                if b_val > 0.0:
                                    role_bonuses[rid] = b_val
                            blended_turns = calibrate_rerank_blend(
                                fused_turns[:28],
                                ce_scored,
                                extra_bonuses=role_bonuses,
                                high_ce_weight=0.80,
                                low_ce_weight=0.42,
                            )
                            ranked_turns = [rid for rid, _ in blended_turns][:top_k]
                            # Feed calibrated top Cross-Encoder turn evidence back into session ranking
                            seen_ce_sess: dict[str, int] = {}
                            for rank, (rid, bscore) in enumerate(blended_turns[:12]):
                                sid = raw_to_sess.get(rid)
                                if sid:
                                    cnt = seen_ce_sess.get(sid, 0)
                                    if cnt < 2:
                                        decay = 1.0 if cnt == 0 else 0.25
                                        sess_scores[sid] = sess_scores.get(sid, 0.0) + (
                                            (1.10 + 0.60 * bscore) * decay / (rrf_k + rank + 1)
                                        )
                                        seen_ce_sess[sid] = cnt + 1
                        else:
                            ranked_turns = fused_turns[:top_k]
                    else:
                        ranked_turns = fused_turns[:top_k]

                    # Refine session ranking with deduplicated semantic turns
                    seen_sem_sess: dict[str, int] = {}
                    for rank, rid in enumerate(sem_turns[:12]):
                        sid = raw_to_sess.get(rid)
                        if sid:
                            cnt = seen_sem_sess.get(sid, 0)
                            if cnt < 2:
                                decay = 1.0 if cnt == 0 else 0.25
                                sess_scores[sid] = sess_scores.get(sid, 0.0) + (
                                    0.75 * decay / (rrf_k + rank + 1)
                                )
                                seen_sem_sess[sid] = cnt + 1
                    ranked_sessions = [
                        sid
                        for sid, _ in sorted(sess_scores.items(), key=lambda kv: kv[1], reverse=True)
                    ][:top_k]
                else:
                    ranked_turns = bm25_turns[:top_k]
                    ranked_sessions = ranked_sessions[:top_k]
            else:
                ranked_turns = bm25_turns[:top_k]
                ranked_sessions = ranked_sessions[:top_k]

            latencies.append((time.perf_counter() - t0) * 1000.0)
            ranked_texts = [raw_to_text.get(rid, "") for rid in ranked_turns]

            sess_m = compute_ranking_metrics(ranked_sessions, gold_sess_ids, ks=(1, 5, 10))
            if e2e_pack_dir is not None:
                sess_to_date_map = dict(zip(sess_ids, sess_dates, strict=False))
                top_hit_set = set(ranked_turns[:top_k])
                chosen_rids: set[str] = set()
                for rid in ranked_turns[:top_k]:
                    sid_c = raw_to_sess.get(rid)
                    if not sid_c:
                        continue
                    s_rids = sess_to_raw_ids.get(sid_c, [])
                    if rid in s_rids:
                        idx_c = s_rids.index(rid)
                        for nb_i in (idx_c - 1, idx_c, idx_c + 1):
                            if 0 <= nb_i < len(s_rids):
                                chosen_rids.add(s_rids[nb_i])
                for sid_c in ranked_sessions[:5]:
                    for rid in sess_to_raw_ids.get(sid_c, []):
                        chosen_rids.add(rid)
                # Allocate budget in retrieval-rank priority FIRST so rank-#1 sessions never get
                # starved by older low-rank distractors, then render selected sessions chronologically.
                rank_ordered_sids: list[str] = []
                for sid_c in ranked_sessions[:5]:
                    if sid_c not in rank_ordered_sids:
                        rank_ordered_sids.append(sid_c)
                for rid in ranked_turns[:top_k]:
                    sid_c = raw_to_sess.get(rid)
                    if sid_c and sid_c not in rank_ordered_sids:
                        rank_ordered_sids.append(sid_c)
                selected_blocks: list[tuple[int, str]] = []
                used_c = 0
                for sid_c in rank_ordered_sids:
                    sd_c = sess_to_date_map.get(sid_c, "")
                    bl_lines = [f"=== Session ({sd_c}) ==="]
                    for rid in sess_to_raw_ids.get(sid_c, []):
                        if rid not in chosen_rids:
                            continue
                        rr_role, _, rr_content, _ = raw_to_meta[rid]
                        if rid in top_hit_set:
                            cap_l = 4000
                        elif rr_role == "user":
                            cap_l = 1200
                        else:
                            cap_l = 1800
                        bl_lines.append(f"{rr_role}: {rr_content[:cap_l]}")
                    if len(bl_lines) > 1:
                        blk_str = "\n".join(bl_lines)
                        if used_c + len(blk_str) > 36_000 and selected_blocks:
                            continue
                        selected_blocks.append(
                            (_parse_longmemeval_datetime_ms(sd_c, 0), blk_str)
                        )
                        used_c += len(blk_str)
                selected_blocks.sort(key=lambda kv: kv[0])
                ctx_text = "\n\n".join(b for _, b in selected_blocks)
                full_chars = sum(len(t) + 12 for t in raw_to_text.values())
                e2e_reader_rows.append(
                    {
                        "item_id": qid,
                        "question": question,
                        "question_date": str(item.get("question_date") or ""),
                        "context_text": ctx_text,
                        "context_tokens": max(1, len(ctx_text) // 4),
                    }
                )
                e2e_gold_map[qid] = {
                    "item_id": qid,
                    "category": qtype,
                    "is_abstention": is_abs,
                    "question": question,
                    "question_date": str(item.get("question_date") or ""),
                    "gold_answer": str(answer or ""),
                    "retrieval_hit_at_5": bool(sess_m["r@5"] > 0 or is_abs),
                    "retrieval_hit_at_10": bool(sess_m["r@10"] > 0 or is_abs),
                    "context_tokens": max(1, len(ctx_text) // 4),
                    "full_history_tokens": max(1, full_chars // 4),
                }
            if is_abs:
                abs_rows.append(
                    {
                        "refuting_sess_r@5": sess_m["r@5"],
                        "refuting_sess_r@10": sess_m["r@10"],
                        "zero_hit_rate": 1.0 if not ranked_turns else 0.0,
                    }
                )
                continue

            turn_m = compute_ranking_metrics(ranked_turns, gold_turn_ids, ks=(1, 5, 10))
            row = {
                "sess_r@1": sess_m["r@1"],
                "sess_r@5": sess_m["r@5"],
                "sess_r@10": sess_m["r@10"],
                "sess_all_r@5": sess_m["all_r@5"],
                "sess_all_r@10": sess_m["all_r@10"],
                "sess_ndcg@5": sess_m["ndcg@5"],
                "sess_ndcg@10": sess_m["ndcg@10"],
                "sess_mrr": sess_m["mrr"],
                "turn_r@1": turn_m["r@1"],
                "turn_r@5": turn_m["r@5"],
                "turn_r@10": turn_m["r@10"],
                "turn_ndcg@5": turn_m["ndcg@5"],
                "turn_ndcg@10": turn_m["ndcg@10"],
                "turn_mrr": turn_m["mrr"],
                "ans_cov@5": 1.0 if answer_span_present(answer, ranked_texts[:5]) else 0.0,
                "ans_cov@10": 1.0 if answer_span_present(answer, ranked_texts[:10]) else 0.0,
            }
            pos_rows.append(row)
            by_cat_rows[qtype].append(row)

            if row["sess_r@5"] == 0.0 and len(failures) < max_failures:
                failures.append(
                    BenchmarkFailureSample(
                        suite=split_name,
                        item_id=qid,
                        category=qtype,
                        question=question,
                        expected_answer=str(answer or ""),
                        gold_ids=sorted(gold_sess_ids),
                        retrieved_top_ids=ranked_sessions[:5],
                        retrieved_top_snippets=[t[:220] for t in ranked_texts[:3]],
                        reason="miss_at_5" if ranked_sessions else "zero_hits",
                    )
                )
        finally:
            store.close()
    finally:
        if embed_cache is not None:
            embed_cache.close()

    if e2e_pack_dir is not None:
        out_p = Path(e2e_pack_dir)
        out_p.mkdir(parents=True, exist_ok=True)
        with (out_p / "reader_inputs.jsonl").open("w", encoding="utf-8") as fh:
            for r_row in e2e_reader_rows:
                fh.write(json.dumps(r_row, ensure_ascii=False) + "\n")
        (out_p / "gold_key.json").write_text(
            json.dumps(e2e_gold_map, indent=2, ensure_ascii=False), encoding="utf-8"
        )

    by_category = {
        cat: {"count": len(rows), **_mean_metrics(rows)}
        for cat, rows in sorted(by_cat_rows.items())
    }
    lme_mode = "hub_retrieval"
    if use_semantic:
        lme_mode += "+semantic"
    if use_reranker:
        lme_mode += "+rerank"
    return StandardBenchmarkReport(
        suite=split_name,
        mode=lme_mode,
        engine_label=engine_label,
        dataset_path=str(dataset_path),
        evaluated_at_ms=now_ms(),
        total_questions=len(data),
        scored_questions=len(pos_rows),
        abstention_questions=len(abs_rows),
        overall=_mean_metrics(pos_rows),
        by_category=by_category,
        abstention_metrics=_mean_metrics(abs_rows),
        latency_p50_ms=_percentile(latencies, 50),
        latency_p95_ms=_percentile(latencies, 95),
        total_elapsed_s=round(time.perf_counter() - t_wall0, 2),
        sample_failures=failures,
    )


# ---------------------------------------------------------------------------
# ConvoMem Adapter (6 Evidence Categories + Abstention)
# ---------------------------------------------------------------------------
def evaluate_convomem(
    dataset_path: Path,
    *,
    engine_label: str = "raw-memory",
    top_k: int = 5,
    use_semantic: bool = False,
    embed_model: str | None = None,
    embed_cache_path: Path | None = None,
) -> StandardBenchmarkReport:
    """Evaluate Raw Memory retrieval on a ConvoMem-schema benchmark dataset."""
    t_wall0 = time.perf_counter()
    data = json.loads(Path(dataset_path).expanduser().read_text(encoding="utf-8"))

    embed_cache = None
    if use_semantic:
        from context_hub.semantic import PersistentEmbedCache

        cache_db = embed_cache_path or (DEFAULT_BENCH_CACHE / "embed_cache.sqlite3")
        embed_cache = PersistentEmbedCache(cache_db)

    pos_rows: list[dict[str, float]] = []
    abs_rows: list[dict[str, float]] = []
    by_cat_rows: dict[str, list[dict[str, float]]] = defaultdict(list)
    latencies: list[float] = []
    failures: list[BenchmarkFailureSample] = []

    try:
        for item in data:
            iid = str(item["item_id"])
            cat = str(item.get("category") or "general")
            question = str(item["question"])
            answer = item.get("answer")
            is_abs = bool(item.get("is_abstention"))
            gold_sids = set(item.get("gold_session_ids") or [])

            sessions_payload: list[dict[str, Any]] = []
            raw_to_sid: dict[str, str] = {}
            raw_to_text: dict[str, str] = {}
            ep_to_sid: dict[str, str] = {}
            for sidx, sess in enumerate(item.get("sessions") or []):
                sid = str(sess.get("session_id") or f"s{sidx + 1}")
                sdate = str(sess.get("date") or f"2026-01-{sidx + 1:02d}")
                t_base = 1_767_225_600_000 + sidx * 86_400_000
                ep_id = f"ep_{iid}_{sid}"
                ep_to_sid[ep_id] = sid
                turns_payload: list[dict[str, Any]] = []
                for tidx, turn in enumerate(sess.get("turns") or []):
                    rid = f"{iid}_{sid}_t{tidx}"
                    role = str(turn.get("role") or "user")
                    actor = "self" if role == "user" else "assistant"
                    txt = f"[{sdate}] {role}: {turn.get('content', '')}"
                    raw_to_sid[rid] = sid
                    raw_to_text[rid] = txt
                    turns_payload.append(
                        {
                            "id": rid,
                            "source_id": f"{sid}#t{tidx}",
                            "t_start": t_base + tidx * 10_000,
                            "actor": actor,
                            "title": f"Session {sid} ({sdate})",
                            "text": txt,
                            "locator": f"convomem://{iid}/{sid}#t{tidx}",
                        }
                    )
                sessions_payload.append(
                    {
                        "episode_id": ep_id,
                        "title": f"Session {sid} ({sdate})",
                        "summary": "",
                        "status": "pending_curation",
                        "t_start": t_base,
                        "t_end": t_base + max(1, len(turns_payload)) * 10_000,
                        "turns": turns_payload,
                    }
                )

            store = HubStore(Path("/tmp/raw-memory-cm-unused"), in_memory=True)
            try:
                store.ingest_sessions_bulk(sessions_payload, project=f"cm-{iid}")
                if use_semantic:
                    store.index_semantic(
                        kinds=("episode", "raw"),
                        model_name=embed_model,
                        embed_cache=embed_cache,
                    )
                t0 = time.perf_counter()
                searched = store.search_context(
                    question,
                    limit=max(top_k * 2, 10),
                    agent=True,
                    max_tokens=16_000,
                    use_semantic=use_semantic,
                    embed_model=embed_model,
                    embed_cache=embed_cache,
                )
                latencies.append((time.perf_counter() - t0) * 1000.0)
                raw_hits = searched.get("raw_matches") or []
                ep_hits = searched.get("episodes") or []
                sess_scores: dict[str, float] = {}
                for rank, ep in enumerate(ep_hits):
                    sid = ep_to_sid.get(ep["id"], ep["id"])
                    sess_scores[sid] = sess_scores.get(sid, 0.0) + 1.2 / (15.0 + rank + 1)
                for rank, h in enumerate(raw_hits):
                    sid = raw_to_sid.get(h["id"])
                    if sid:
                        sess_scores[sid] = sess_scores.get(sid, 0.0) + 1.0 / (15.0 + rank + 1)
                ranked_sids = [
                    sid for sid, _ in sorted(sess_scores.items(), key=lambda kv: kv[1], reverse=True)
                ][:top_k]
                ranked_texts = [raw_to_text.get(h["id"], "") for h in raw_hits[:top_k]]

                if is_abs:
                    abs_rows.append({"zero_hit_rate": 1.0 if not raw_hits else 0.0})
                    continue

                sess_m = compute_ranking_metrics(ranked_sids, gold_sids, ks=(1, 5))
                row = {
                    "sess_r@1": sess_m["r@1"],
                    "sess_r@5": sess_m["r@5"],
                    "sess_ndcg@5": sess_m["ndcg@5"],
                    "sess_mrr": sess_m["mrr"],
                    "ans_cov@5": 1.0 if answer_span_present(answer, ranked_texts[:5]) else 0.0,
                }
                pos_rows.append(row)
                by_cat_rows[cat].append(row)
                if row["sess_r@5"] == 0.0:
                    failures.append(
                        BenchmarkFailureSample(
                            suite="convomem-smoke",
                            item_id=iid,
                            category=cat,
                            question=question,
                            expected_answer=str(answer or ""),
                            gold_ids=sorted(gold_sids),
                            retrieved_top_ids=ranked_sids[:5],
                            retrieved_top_snippets=[t[:200] for t in ranked_texts[:3]],
                            reason="miss_at_5",
                        )
                    )
            finally:
                store.close()
    finally:
        if embed_cache is not None:
            embed_cache.close()

    return StandardBenchmarkReport(
        suite="convomem-smoke",
        mode="hub_retrieval+semantic" if use_semantic else "hub_retrieval",
        engine_label=engine_label,
        dataset_path=str(dataset_path),
        evaluated_at_ms=now_ms(),
        total_questions=len(data),
        scored_questions=len(pos_rows),
        abstention_questions=len(abs_rows),
        overall=_mean_metrics(pos_rows),
        by_category={
            cat: {"count": len(rows), **_mean_metrics(rows)}
            for cat, rows in sorted(by_cat_rows.items())
        },
        abstention_metrics=_mean_metrics(abs_rows),
        latency_p50_ms=_percentile(latencies, 50),
        latency_p95_ms=_percentile(latencies, 95),
        total_elapsed_s=round(time.perf_counter() - t_wall0, 2),
        sample_failures=failures,
    )


def render_benchmark_markdown(report: StandardBenchmarkReport) -> str:
    """Render a clean GitHub-ready Markdown scorecard for LoCoMo or LongMemEval."""
    lines = [
        f"# Raw Memory Benchmark Report — `{report.suite}` ({report.mode})",
        "",
        f"- **Engine**: `{report.engine_label}`",
        f"- **Questions**: `{report.scored_questions}` scored / `{report.total_questions}` total"
        + (f" (`{report.abstention_questions}` abstention `_abs` tracked separately)" if report.abstention_questions else ""),
        f"- **Latency**: p50=`{report.latency_p50_ms:.2f} ms`, p95=`{report.latency_p95_ms:.2f} ms`, wall=`{report.total_elapsed_s:.2f} s`",
        "",
    ]

    if report.suite == "locomo":
        o = report.overall
        lines.extend(
            [
                "## Overall Metrics",
                "",
                "| R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | NDCG@10 | MRR | Ans-Cov@5 | Ans-Cov@10 |",
                "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
                f"| {o.get('r@1', 0)*100:.1f}% | {o.get('r@5', 0)*100:.1f}% | {o.get('r@10', 0)*100:.1f}% | "
                f"{o.get('all_r@5', 0)*100:.1f}% | {o.get('all_r@10', 0)*100:.1f}% | "
                f"{o.get('ndcg@5', 0)*100:.1f}% | {o.get('ndcg@10', 0)*100:.1f}% | "
                f"{o.get('mrr', 0)*100:.1f}% | {o.get('ans_cov@5', 0)*100:.1f}% | {o.get('ans_cov@10', 0)*100:.1f}% |",
                "",
                "## Breakdown by Category",
                "",
                "| Category | N | R@1 | R@5 | R@10 | All-R@5 | NDCG@5 | MRR | Ans-Cov@5 |",
                "| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
            ]
        )
        for cat, m in report.by_category.items():
            lines.append(
                f"| `{cat}` | {m['count']} | {m.get('r@1', 0)*100:.1f}% | {m.get('r@5', 0)*100:.1f}% | "
                f"{m.get('r@10', 0)*100:.1f}% | {m.get('all_r@5', 0)*100:.1f}% | "
                f"{m.get('ndcg@5', 0)*100:.1f}% | {m.get('mrr', 0)*100:.1f}% | {m.get('ans_cov@5', 0)*100:.1f}% |"
            )
    elif report.suite == "convomem-smoke":
        o = report.overall
        lines.extend(
            [
                "## Overall Metrics (ConvoMem 6-Category Retrieval)",
                "",
                "| Sess R@1 | Sess R@5 | Sess NDCG@5 | Sess MRR | Ans-Cov@5 |",
                "| ---: | ---: | ---: | ---: | ---: |",
                f"| {o.get('sess_r@1', 0)*100:.1f}% | {o.get('sess_r@5', 0)*100:.1f}% | "
                f"{o.get('sess_ndcg@5', 0)*100:.1f}% | {o.get('sess_mrr', 0)*100:.1f}% | "
                f"{o.get('ans_cov@5', 0)*100:.1f}% |",
                "",
                "## Breakdown by ConvoMem Evidence Category",
                "",
                "| Category | N | Sess R@1 | Sess R@5 | Sess NDCG@5 | Sess MRR | Ans-Cov@5 |",
                "| :--- | ---: | ---: | ---: | ---: | ---: | ---: |",
            ]
        )
        for cat, m in report.by_category.items():
            lines.append(
                f"| `{cat}` | {m['count']} | {m.get('sess_r@1', 0)*100:.1f}% | {m.get('sess_r@5', 0)*100:.1f}% | "
                f"{m.get('sess_ndcg@5', 0)*100:.1f}% | {m.get('sess_mrr', 0)*100:.1f}% | {m.get('ans_cov@5', 0)*100:.1f}% |"
            )
    else:
        o = report.overall
        lines.extend(
            [
                "## Overall Metrics (Session-Level & Turn-Level Retrieval)",
                "",
                "| Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | Ans-Cov@5 |",
                "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
                f"| {o.get('sess_r@1', 0)*100:.1f}% | {o.get('sess_r@5', 0)*100:.1f}% | {o.get('sess_r@10', 0)*100:.1f}% | "
                f"{o.get('sess_all_r@5', 0)*100:.1f}% | {o.get('sess_ndcg@5', 0)*100:.1f}% | "
                f"{o.get('turn_r@5', 0)*100:.1f}% | {o.get('turn_r@10', 0)*100:.1f}% | "
                f"{o.get('turn_ndcg@5', 0)*100:.1f}% | {o.get('ans_cov@5', 0)*100:.1f}% |",
                "",
                "## Breakdown by Official LongMemEval Pillar",
                "",
                "| Question Type | N | Sess R@1 | Sess R@5 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn NDCG@5 | Ans-Cov@5 |",
                "| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
            ]
        )
        for cat, m in report.by_category.items():
            lines.append(
                f"| `{cat}` | {m['count']} | {m.get('sess_r@1', 0)*100:.1f}% | {m.get('sess_r@5', 0)*100:.1f}% | "
                f"{m.get('sess_all_r@5', 0)*100:.1f}% | {m.get('sess_ndcg@5', 0)*100:.1f}% | "
                f"{m.get('turn_r@5', 0)*100:.1f}% | {m.get('turn_ndcg@5', 0)*100:.1f}% | {m.get('ans_cov@5', 0)*100:.1f}% |"
            )
        if report.abstention_metrics:
            am = report.abstention_metrics
            lines.extend(
                [
                    "",
                    f"**Abstention (`_abs`, N={report.abstention_questions})**: "
                    f"Refuting-session R@5=`{am.get('refuting_sess_r@5', 0)*100:.1f}%`, "
                    f"R@10=`{am.get('refuting_sess_r@10', 0)*100:.1f}%`, "
                    f"zero-hit rate=`{am.get('zero_hit_rate', 0)*100:.1f}%`",
                ]
            )

    if report.sample_failures:
        lines.extend(["", f"## Sample Failure Cases (Top {min(len(report.sample_failures), 8)} for Debugging)", ""])
        for f in report.sample_failures[:8]:
            lines.append(
                f"- **`[{f.category}]` `{f.item_id}`** (`{f.reason}`): *{f.question}* "
                f"(gold={f.gold_ids}, got={f.retrieved_top_ids[:3]})"
            )
    lines.append("")
    return "\n".join(lines)
