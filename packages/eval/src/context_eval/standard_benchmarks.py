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
    1: "single_hop",
    2: "temporal",
    3: "open_domain",
    4: "multi_hop",
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

    if mode == "curated":
        res = store.search_context(question, limit=max(top_k * 2, 20), agent=True, max_tokens=24_000)
        # Fuse L3 Curated Observations (evidence_ids), L1 Raw Turns, and L2 Episodes via RRF
        scores: dict[str, float] = {}
        best_snippet: dict[str, str] = {}
        rrf_k = 15.0

        for rank, mem in enumerate(res.get("memories") or []):
            for eid in mem.get("evidence_ids") or []:
                dia = raw_to_dia.get(eid)
                if dia:
                    scores[dia] = scores.get(dia, 0.0) + 1.25 / (rrf_k + rank + 1)
                    if dia not in best_snippet:
                        best_snippet[dia] = f"[L3 Memory] {mem['body']} || {dia_to_text.get(dia, '')}"

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

        for dia, _ in sorted(scores.items(), key=lambda kv: kv[1], reverse=True)[:top_k]:
            _push_dia(dia, best_snippet.get(dia))
    else:
        raw_hits = store.list_raw(q=question, limit=max(top_k, 15), agent=True)
        for hit in raw_hits:
            dia = raw_to_dia.get(hit["id"])
            if dia:
                _push_dia(dia, hit.get("body_text") or dia_to_text.get(dia, ""))

    return ranked_dias[:top_k], snippets[:top_k]


def evaluate_locomo(
    dataset_path: Path,
    *,
    mode: str = "raw",
    engine_label: str = "raw-memory",
    top_k: int = 10,
    limit_convs: int | None = None,
    max_failures: int = 25,
) -> StandardBenchmarkReport:
    """Evaluate Raw Memory on LoCoMo (`locomo10.json` or schema-compatible fixture)."""
    t_wall0 = time.perf_counter()
    data = json.loads(Path(dataset_path).expanduser().read_text(encoding="utf-8"))
    if limit_convs is not None:
        data = data[:limit_convs]

    all_rows: list[dict[str, float]] = []
    by_cat_rows: dict[str, list[dict[str, float]]] = defaultdict(list)
    latencies: list[float] = []
    failures: list[BenchmarkFailureSample] = []
    total_q = 0
    scored_q = 0

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

    by_category = {
        cat: {"count": len(rows), **_mean_metrics(rows)}
        for cat, rows in sorted(by_cat_rows.items())
    }
    return StandardBenchmarkReport(
        suite="locomo",
        mode=mode,
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

    pos_rows: list[dict[str, float]] = []
    abs_rows: list[dict[str, float]] = []
    by_cat_rows: dict[str, list[dict[str, float]]] = defaultdict(list)
    latencies: list[float] = []
    failures: list[BenchmarkFailureSample] = []

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
        ep_to_sess: dict[str, str] = {}

        for sidx, (sid, sdate, turns) in enumerate(
            zip(sess_ids, sess_dates, sessions_raw, strict=False)
        ):
            t_sess = _parse_longmemeval_datetime_ms(sdate, sidx)
            ep_id = f"{sid}__s{sidx}"
            ep_to_sess[ep_id] = sid
            turns_payload: list[dict[str, Any]] = []
            for tidx, turn in enumerate(turns):
                rid = f"t_{sidx}_{tidx}"
                role = str(turn.get("role") or "user")
                actor = "self" if role == "user" else "assistant"
                content = str(turn.get("content") or "")
                stamped = f"[{sdate}] {role}: {content}"
                raw_to_sess[rid] = sid
                raw_to_text[rid] = stamped
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

        store = HubStore(Path("/tmp/raw-memory-bench-unused"), in_memory=True)
        try:
            store.ingest_sessions_bulk(sessions_payload, project=f"lme-{qid}")

            t0 = time.perf_counter()
            searched = store.search_context(
                question,
                limit=max(top_k * 2, 20),
                agent=True,
                max_tokens=32_000,
            )
            latencies.append((time.perf_counter() - t0) * 1000.0)

            raw_hits = searched.get("raw_matches") or []
            ep_hits = searched.get("episodes") or []

            ranked_turns = [h["id"] for h in raw_hits][:top_k]
            ranked_texts = [raw_to_text.get(rid, "") for rid in ranked_turns]

            # Derive session ranking via RRF fusion of session-level `episodes` and turn-level `raw_matches`
            sess_scores: dict[str, float] = {}
            rrf_k = 15.0
            for rank, ep in enumerate(ep_hits):
                sid = ep_to_sess.get(ep["id"], ep["id"])
                sess_scores[sid] = sess_scores.get(sid, 0.0) + 1.15 / (rrf_k + rank + 1)
            for rank, hit in enumerate(raw_hits):
                sid = raw_to_sess.get(hit["id"])
                if sid:
                    sess_scores[sid] = sess_scores.get(sid, 0.0) + 0.90 / (rrf_k + rank + 1)
            ranked_sessions = [
                sid for sid, _ in sorted(sess_scores.items(), key=lambda kv: kv[1], reverse=True)
            ][:top_k]

            sess_m = compute_ranking_metrics(ranked_sessions, gold_sess_ids, ks=(1, 5, 10))
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

    by_category = {
        cat: {"count": len(rows), **_mean_metrics(rows)}
        for cat, rows in sorted(by_cat_rows.items())
    }
    return StandardBenchmarkReport(
        suite=split_name,
        mode="hub_retrieval",
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
