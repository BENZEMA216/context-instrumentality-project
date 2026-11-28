"""Official-Protocol Academic E2E Reader & LLM-as-a-Judge Harness (Track B).

Implements the exact published end-to-end QA & LLM-as-a-Judge evaluation contracts for:
  1. **LongMemEval-S / LongMemEval-Oracle (ICLR 2025)**:
     - Verbatim task-specific official judge prompts for `single-session-user`,
       `single-session-assistant`, `multi-session`, `temporal-reasoning` (with official
       off-by-one day tolerance), `knowledge-update` (updated answer supersedes old),
       `single-session-preference` (personalized rubric), and `_abs` abstention.
  2. **LoCoMo (ACL 2024 + Mem0 / Supermemory LLM-as-a-Judge protocol)**:
     - Official normalized Token F1 (categories 1–4) + LLM-as-a-Judge binary accuracy
       (`J-Score`, including adversarial false-premise abstention for category 5).

Strict Blind Isolation Guarantee:
  - `prepare_*_e2e_pack()` separates `reader_inputs.jsonl` (question + timestamped retrieved
    context ONLY — zero gold answers!) from `gold_key.json` (gold answers + metadata).
  - Supports BOTH direct HTTP LLM APIs (OpenAI-compatible / DeepSeek / OpenRouter / Ollama /
    Gemini / Anthropic) AND external/workflow blind Reader & Judge JSONL execution via
    `prepare` -> blind Reader -> independent blind Judge -> `score`.
"""

from __future__ import annotations

import json
import os
import re
import string
import time
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field

from context_hub.models import now_ms
from context_hub.store import HubStore

from .standard_benchmarks import (
    DEFAULT_BENCH_CACHE,
    LOCOMO_CATEGORIES,
    _parse_locomo_datetime_ms,
    _parse_locomo_evidence,
    _parse_longmemeval_datetime_ms,
    _retrieve_locomo_ranked,
    compute_ranking_metrics,
)

# ---------------------------------------------------------------------------
# Verbatim Official LongMemEval (ICLR 2025) & LoCoMo Prompts
# ---------------------------------------------------------------------------
READER_SYSTEM_PROMPT = (
    "You are a precise memory-grounded assistant answering questions about a user's past "
    "conversations. Rely ONLY on the provided timestamped memory excerpts.\n"
    "Rules:\n"
    "1. Pay strict attention to timestamps: if a fact or preference changed over time, "
    "the MOST RECENT timestamp supersedes earlier ones.\n"
    "2. For temporal questions (e.g. 'how many days between', 'how long ago', 'which came first'), "
    "compute exact date differences using the explicit session dates and Question Date.\n"
    "3. For multi-session counting/aggregation questions, list each relevant dated instance "
    "briefly and give the exact total.\n"
    "4. For preference/recommendation questions, explicitly tailor your response using the "
    "user's specific stated preferences, hobbies, ingredients, or constraints from memory.\n"
    "5. If the memory excerpts do NOT contain enough information to answer the question (or "
    "contradict a false premise in the question), explicitly state that the information is not "
    "mentioned / cannot be answered from the conversation history. Never fabricate facts.\n"
    "Keep your answer concise, direct, and factual."
)

LONGMEMEVAL_JUDGE_PROMPTS: dict[str, str] = {
    "default": (
        "I will give you a question, a correct answer, and a response from a model. "
        "Please answer yes if the response contains the correct answer. Otherwise, answer no. "
        "If the response is equivalent to the correct answer or contains all the intermediate "
        "steps to get the correct answer, you should also answer yes. If the response only "
        "contains a subset of the information required by the answer, answer no."
    ),
    "temporal-reasoning": (
        "I will give you a question, a correct answer, and a response from a model. "
        "Please answer yes if the response contains the correct answer. Otherwise, answer no. "
        "If the response is equivalent to the correct answer or contains all the intermediate "
        "steps to get the correct answer, you should also answer yes. If the response only "
        "contains a subset of the information required by the answer, answer no. In addition, "
        "do not penalize off-by-one errors for the number of days. If the question asks for the "
        "number of days/weeks/months, etc., and the model makes off-by-one errors (e.g., "
        "predicting 19 days when the answer is 18), the model's response is still correct."
    ),
    "knowledge-update": (
        "I will give you a question, a correct answer, and a response from a model. "
        "Please answer yes if the response contains the correct answer. Otherwise, answer no. "
        "If the response contains some previous information along with an updated answer, "
        "the response should be considered as correct as long as the updated answer is the "
        "required answer."
    ),
    "single-session-preference": (
        "I will give you a question, a rubric for desired personalized response, and a response "
        "from a model. Please answer yes if the response satisfies the desired response. "
        "Otherwise, answer no. The model does not need to reflect all the points in the rubric. "
        "The response is correct as long as it recalls and utilizes the user's personal "
        "information correctly."
    ),
    "abstention": (
        "I will give you an unanswerable question, an explanation, and a response from a model. "
        "Please answer yes if the model correctly identifies the question as unanswerable. "
        "The model could say that the information is incomplete, or some other information is "
        "given but the asked information is not."
    ),
}

LOCOMO_JUDGE_PROMPT = (
    "Your task is to label an answer to a question as 'CORRECT' or 'WRONG'. "
    "You will be given (1) a question, (2) a 'gold' (ground truth) answer, and "
    "(3) a generated answer from a memory system.\n"
    "Be generous on phrasing as long as the core factual content matches the gold answer. "
    "For time/date questions, allow equivalent date formats (e.g. '7 May 2023' vs 'May 7, 2023' "
    "vs 'the day before May 8, 2023'). For multi-item questions, all key items in the gold "
    "answer should be covered. For adversarial/unanswerable questions (where gold indicates "
    "the premise is false or not mentioned), label CORRECT if the generated answer refuses, "
    "corrects the false premise, or states the information is not mentioned."
)


def get_longmemeval_judge_instruction(category: str, is_abstention: bool) -> str:
    if is_abstention:
        return LONGMEMEVAL_JUDGE_PROMPTS["abstention"]
    return LONGMEMEVAL_JUDGE_PROMPTS.get(category, LONGMEMEVAL_JUDGE_PROMPTS["default"])


# ---------------------------------------------------------------------------
# Official Normalized Token F1 (LoCoMo ACL 2024 / SQuAD-style)
# ---------------------------------------------------------------------------
_ARTICLES_RE = re.compile(r"\b(a|an|the)\b", re.I)


def normalize_answer_for_f1(text: str) -> str:
    s = (text or "").lower()
    s = "".join(ch if ch not in string.punctuation else " " for ch in s)
    s = _ARTICLES_RE.sub(" ", s)
    return " ".join(s.split())


def compute_token_f1(prediction: str, ground_truth: str) -> float:
    pred_toks = normalize_answer_for_f1(prediction).split()
    gold_toks = normalize_answer_for_f1(ground_truth).split()
    if not pred_toks or not gold_toks:
        return 1.0 if pred_toks == gold_toks else 0.0
    common = Counter(pred_toks) & Counter(gold_toks)
    num_same = sum(common.values())
    if num_same == 0:
        return 0.0
    prec = num_same / len(pred_toks)
    rec = num_same / len(gold_toks)
    return round(2.0 * prec * rec / (prec + rec), 4)


# ---------------------------------------------------------------------------
# Report Schemas
# ---------------------------------------------------------------------------
class AcademicE2EItemResult(BaseModel):
    item_id: str
    category: str
    question: str
    question_date: str = ""
    is_abstention: bool = False
    gold_answer: str
    predicted_answer: str
    judge_correct: bool
    judge_reason: str = ""
    token_f1: float | None = None
    retrieval_hit_at_5: bool = False
    retrieval_hit_at_10: bool = False
    context_tokens: int = 0
    full_history_tokens: int = 0


class AcademicE2EReport(BaseModel):
    suite: str
    engine_label: str
    reader_model: str
    judge_model: str
    evaluated_at_ms: int
    total_questions: int
    scored_questions: int
    abstention_questions: int = 0
    overall_accuracy: float
    positive_accuracy: float
    abstention_accuracy: float | None = None
    avg_token_f1: float | None = None
    retrieval_r5: float = 0.0
    retrieval_r10: float = 0.0
    avg_context_tokens: float = 0.0
    avg_full_history_tokens: float = 0.0
    token_reduction_pct: float = 0.0
    by_category: dict[str, dict[str, Any]] = Field(default_factory=dict)
    sample_errors: list[dict[str, Any]] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Stage 1-3: Retrieval Context Pack Preparation (Strictly Blind Separation)
# ---------------------------------------------------------------------------
def _approx_toks(text: str) -> int:
    return max(1, len(text) // 4)


def prepare_longmemeval_e2e_pack(
    dataset_path: Path,
    out_dir: Path,
    *,
    split_name: str = "longmemeval-s",
    top_sessions: int = 5,
    top_turns: int = 12,
    max_context_chars: int = 36_000,
    limit_questions: int | None = None,
    stratified_per_cat: int | None = None,
    use_semantic: bool = True,
    use_reranker: bool = True,
    embed_model: str | None = None,
    rerank_model: str | None = None,
    embed_cache_path: Path | None = None,
) -> dict[str, Any]:
    """Run real v0.8 `HubStore` retrieval on LongMemEval and emit blind `reader_inputs.jsonl` + `gold_key.json`."""
    from context_hub.semantic import (
        DEFAULT_EMBED_MODEL,
        PersistentEmbedCache,
        calibrate_rerank_blend,
        cosine_top_k,
        query_targets_assistant,
        rerank_candidates,
        reranker_available,
        rrf_fuse_lists,
        select_rerank_model,
    )
    from context_hub.temporal import TemporalWindow, temporal_proximity_score

    data = json.loads(Path(dataset_path).expanduser().read_text(encoding="utf-8"))
    if stratified_per_cat is not None:
        buckets: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for it in data:
            key = "abstention" if str(it["question_id"]).endswith("_abs") else str(it["question_type"])
            buckets[key].append(it)
        selected: list[dict[str, Any]] = []
        for key in sorted(buckets):
            rows = buckets[key]
            step = max(1, len(rows) // stratified_per_cat)
            selected.extend(rows[::step][:stratified_per_cat])
        data = selected
    elif limit_questions is not None:
        data = data[:limit_questions]

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    reader_path = out_dir / "reader_inputs.jsonl"
    gold_path = out_dir / "gold_key.json"

    embed_cache = None
    if use_semantic:
        cache_db = embed_cache_path or (DEFAULT_BENCH_CACHE / "embed_cache.sqlite3")
        embed_cache = PersistentEmbedCache(cache_db)

    reader_rows: list[dict[str, Any]] = []
    gold_map: dict[str, dict[str, Any]] = {}
    t0_all = time.perf_counter()

    try:
        for item in data:
            qid = str(item["question_id"])
            qtype = str(item["question_type"])
            is_abs = qid.endswith("_abs")
            question = str(item["question"])
            q_date = str(item.get("question_date") or "")
            answer = str(item.get("answer") or "")
            sess_ids: list[str] = list(item["haystack_session_ids"])
            sess_dates: list[str] = list(item["haystack_dates"])
            sessions_raw: list[list[dict[str, Any]]] = list(item["haystack_sessions"])
            gold_sess_ids = set(item.get("answer_session_ids") or [])

            full_chars = 0
            sessions_payload: list[dict[str, Any]] = []
            gold_turn_ids: set[str] = set()
            raw_to_sess: dict[str, str] = {}
            raw_to_text: dict[str, str] = {}
            raw_to_meta: dict[str, tuple[str, str, str, str]] = {}
            ep_to_sess: dict[str, str] = {}
            sess_to_raw_ids: dict[str, list[str]] = defaultdict(list)
            sess_to_date: dict[str, str] = {}

            for sidx, (sid, sdate, turns) in enumerate(
                zip(sess_ids, sess_dates, sessions_raw, strict=False)
            ):
                t_sess = _parse_longmemeval_datetime_ms(sdate, sidx)
                ep_id = f"{sid}__s{sidx}"
                ep_to_sess[ep_id] = sid
                sess_to_date[sid] = sdate
                turns_payload: list[dict[str, Any]] = []
                prev_content = ""
                for tidx, turn in enumerate(turns):
                    rid = f"t_{sidx}_{tidx}"
                    role = str(turn.get("role") or "user")
                    actor = "self" if role == "user" else "assistant"
                    content = str(turn.get("content") or "")
                    full_chars += len(content) + 20
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

            q_date_ms = _parse_longmemeval_datetime_ms(q_date, len(sess_ids))
            store = HubStore(Path("/tmp/rm-e2e-lme-unused"), in_memory=True)
            try:
                store.ingest_sessions_bulk(sessions_payload, project=f"lme-{qid}")
                if use_semantic:
                    store.index_semantic(
                        kinds=("episode_chunk",) if use_reranker else ("episode",),
                        model_name=embed_model,
                        embed_cache=embed_cache,
                    )
                searched = store.search_context(
                    question,
                    reference_time_ms=q_date_ms,
                    limit=24,
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

                sess_scores: dict[str, float] = {}
                rrf_k = 15.0
                for rank, ep in enumerate(ep_hits):
                    sid = ep_to_sess.get(ep["id"], ep["id"])
                    sess_scores[sid] = sess_scores.get(sid, 0.0) + (2.00 if use_semantic else 1.15) / (
                        rrf_k + rank + 1
                    )
                ranked_sessions = [
                    sid for sid, _ in sorted(sess_scores.items(), key=lambda kv: kv[1], reverse=True)
                ][:12]
                bm25_turns = [h["id"] for h in raw_hits]
                ranked_turns = bm25_turns[:top_turns]

                if use_semantic and embed_cache is not None:
                    active_model = embed_model or DEFAULT_EMBED_MODEL
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
                    cand_sids_list = list(ranked_sessions[:10])
                    if tw_obj is not None and tw_obj.specificity == "point":
                        for sid, s_ms in sess_date_ms_map.items():
                            prox_s = temporal_proximity_score(s_ms, s_ms, tw_obj)
                            if prox_s >= 0.65 and sid not in cand_sids_list:
                                cand_sids_list.append(sid)
                            if prox_s >= 0.80:
                                sess_scores[sid] = sess_scores.get(sid, 0.0) + 0.10 * prox_s
                    cand_rids: list[str] = []
                    seen_r: set[str] = set()
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
                        sem_turn_pairs = cosine_top_k(q_vec, cand_rids, cand_mat, top_k=30)
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
                            if tw_turn_scored:
                                turn_lists.append(
                                    (
                                        [rid for rid, _ in tw_turn_scored],
                                        1.45 if tw_obj.specificity == "point" else 0.70,
                                    )
                                )
                        fused_turns = rrf_fuse_lists(turn_lists, k=20.0)
                        if use_reranker and reranker_available() and fused_turns:
                            ce_pool = fused_turns[:28]
                            ce_pairs: list[tuple[str, str]] = []
                            for rid in ce_pool:
                                role, sdate, content, prev_c = raw_to_meta.get(
                                    rid, ("user", "", raw_to_text.get(rid, ""), "")
                                )
                                if role == "user":
                                    doc = f"User ({sdate}): {content[:950]}"
                                else:
                                    doc = f"Assistant ({sdate}): {content[:950]}"
                                    if prev_c and "?" in prev_c:
                                        doc += f"\n[In reply to question]: {prev_c[:150]}"
                                ce_pairs.append((rid, doc))
                            rmodel = select_rerank_model(question, rerank_model)
                            ce_scored = rerank_candidates(question, ce_pairs, model_name=rmodel)
                            if ce_scored:
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
                                ranked_turns = [rid for rid, _ in blended_turns][:top_turns]
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
                                ranked_turns = fused_turns[:top_turns]
                        else:
                            ranked_turns = fused_turns[:top_turns]

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
                            for sid, _ in sorted(
                                sess_scores.items(), key=lambda kv: kv[1], reverse=True
                            )
                        ][:10]

                # Assemble rank-prioritized, untruncated top-hit context, rendered chronologically
                top_hit_set = set(ranked_turns[:top_turns])
                chosen_rids: set[str] = set()
                for rid in ranked_turns[:top_turns]:
                    sid = raw_to_sess.get(rid)
                    if not sid:
                        continue
                    s_rids = sess_to_raw_ids.get(sid, [])
                    if rid in s_rids:
                        idx = s_rids.index(rid)
                        for nb_idx in (idx - 1, idx, idx + 1):
                            if 0 <= nb_idx < len(s_rids):
                                chosen_rids.add(s_rids[nb_idx])
                for sid in ranked_sessions[:top_sessions]:
                    for rid in sess_to_raw_ids.get(sid, []):
                        chosen_rids.add(rid)

                rank_ordered_sids: list[str] = []
                for sid in ranked_sessions[:top_sessions]:
                    if sid not in rank_ordered_sids:
                        rank_ordered_sids.append(sid)
                for rid in ranked_turns[:top_turns]:
                    sid = raw_to_sess.get(rid)
                    if sid and sid not in rank_ordered_sids:
                        rank_ordered_sids.append(sid)

                selected_blocks: list[tuple[int, str]] = []
                used_chars = 0
                for sid in rank_ordered_sids:
                    sdate = sess_to_date.get(sid, "")
                    lines = [f"=== Session ({sdate}) ==="]
                    for rid in sess_to_raw_ids.get(sid, []):
                        if rid not in chosen_rids:
                            continue
                        role_r, _, content_r, _ = raw_to_meta[rid]
                        if rid in top_hit_set:
                            cap_len = 4000
                        elif role_r == "user":
                            cap_len = 1200
                        else:
                            cap_len = 1800
                        lines.append(f"{role_r}: {content_r[:cap_len]}")
                    if len(lines) > 1:
                        block = "\n".join(lines)
                        if used_chars + len(block) > max_context_chars and selected_blocks:
                            continue
                        selected_blocks.append(
                            (_parse_longmemeval_datetime_ms(sdate, 0), block)
                        )
                        used_chars += len(block)
                selected_blocks.sort(key=lambda kv: kv[0])
                context_text = "\n\n".join(b for _, b in selected_blocks)
                sess_m = compute_ranking_metrics(ranked_sessions, gold_sess_ids, ks=(5, 10))
                turn_m = compute_ranking_metrics(ranked_turns, gold_turn_ids, ks=(5, 10))

                reader_rows.append(
                    {
                        "item_id": qid,
                        "question": question,
                        "question_date": q_date,
                        "context_text": context_text,
                        "context_tokens": _approx_toks(context_text),
                    }
                )
                gold_map[qid] = {
                    "item_id": qid,
                    "category": qtype,
                    "is_abstention": is_abs,
                    "question": question,
                    "question_date": q_date,
                    "gold_answer": answer,
                    "retrieval_hit_at_5": bool(sess_m["r@5"] > 0 or is_abs),
                    "retrieval_hit_at_10": bool(sess_m["r@10"] > 0 or is_abs),
                    "turn_r5": turn_m["r@5"],
                    "context_tokens": _approx_toks(context_text),
                    "full_history_tokens": max(1, full_chars // 4),
                }
            finally:
                store.close()
    finally:
        if embed_cache is not None:
            embed_cache.close()

    with reader_path.open("w", encoding="utf-8") as fh:
        for row in reader_rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    gold_path.write_text(json.dumps(gold_map, indent=2, ensure_ascii=False), encoding="utf-8")

    return {
        "suite": split_name,
        "count": len(reader_rows),
        "reader_inputs": str(reader_path),
        "gold_key": str(gold_path),
        "elapsed_s": round(time.perf_counter() - t0_all, 2),
        "avg_context_tokens": round(
            sum(r["context_tokens"] for r in reader_rows) / max(1, len(reader_rows)), 1
        ),
        "avg_full_history_tokens": round(
            sum(g["full_history_tokens"] for g in gold_map.values()) / max(1, len(gold_map)), 1
        ),
    }


def prepare_locomo_e2e_pack(
    dataset_path: Path,
    out_dir: Path,
    *,
    mode: str = "curated",
    top_k: int = 10,
    limit_convs: int | None = None,
    stratified_per_cat: int | None = None,
    use_semantic: bool = True,
    use_reranker: bool = True,
    embed_model: str | None = None,
    rerank_model: str | None = None,
    embed_cache_path: Path | None = None,
) -> dict[str, Any]:
    """Run real v0.8 `HubStore` retrieval on LoCoMo and emit blind `reader_inputs.jsonl` + `gold_key.json`."""
    from context_hub.semantic import PersistentEmbedCache

    data = json.loads(Path(dataset_path).expanduser().read_text(encoding="utf-8"))
    if limit_convs is not None:
        data = data[:limit_convs]

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    reader_path = out_dir / "reader_inputs.jsonl"
    gold_path = out_dir / "gold_key.json"

    embed_cache = None
    if use_semantic:
        cache_db = embed_cache_path or (DEFAULT_BENCH_CACHE / "embed_cache.sqlite3")
        embed_cache = PersistentEmbedCache(cache_db)

    reader_rows: list[dict[str, Any]] = []
    gold_map: dict[str, dict[str, Any]] = {}
    cat_counts: Counter[str] = Counter()
    t0_all = time.perf_counter()

    try:
        for conv_idx, sample in enumerate(data):
            conv = sample["conversation"]
            session_nums = sorted(
                int(k.split("_")[1])
                for k in conv
                if k.startswith("session_")
                and not k.endswith("_date_time")
                and isinstance(conv[k], list)
            )
            sessions_payload: list[dict[str, Any]] = []
            raw_to_dia: dict[str, str] = {}
            dia_to_raw: dict[str, str] = {}
            dia_to_text: dict[str, str] = {}
            dia_to_prev: dict[str, str] = {}
            dia_to_next: dict[str, str] = {}
            ep_to_dias: dict[str, list[str]] = {}
            summaries = sample.get("session_summary") or {}
            full_chars = 0

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
                    full_chars += len(full_text) + 4
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
                ep_summary = (
                    str(summaries.get(f"session_{snum}_summary") or "") if mode == "curated" else ""
                )
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
                                        "title": f"{speaker} observation ({date_str})"
                                        if date_str
                                        else speaker,
                                        "body": f"[{date_str}] {fact_text}"
                                        if date_str
                                        else fact_text,
                                        "kind": "fact",
                                        "tags": [speaker, f"session_{snum}"],
                                        "evidence_ids": ev_rids,
                                    }
                                )

            # Pre-filter which QAs we need from this conv when stratified sampling is requested
            qas_to_run: list[tuple[int, dict[str, Any], str]] = []
            for qidx, qa in enumerate(sample.get("qa") or []):
                cat_num = int(qa.get("category") or 0)
                cat_name = LOCOMO_CATEGORIES.get(cat_num, f"cat_{cat_num}")
                if not _parse_locomo_evidence(qa.get("evidence")):
                    continue
                if stratified_per_cat is not None and cat_counts[cat_name] >= stratified_per_cat:
                    continue
                qas_to_run.append((qidx, qa, cat_name))
                cat_counts[cat_name] += 1
            if not qas_to_run:
                continue

            store = HubStore(Path("/tmp/rm-e2e-locomo-unused"), in_memory=True)
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

                for qidx, qa, cat_name in qas_to_run:
                    cat_num = int(qa.get("category") or 0)
                    item_id = f"{sample.get('sample_id', conv_idx)}#q{qidx}"
                    question = str(qa.get("question") or "")
                    gold_dias = _parse_locomo_evidence(qa.get("evidence"))
                    is_adv = cat_num == 5
                    gold_ans = (
                        f"UNANSWERABLE / FALSE PREMISE (adversarial trap: {qa.get('adversarial_answer', '')})"
                        if is_adv
                        else str(qa.get("answer") or "")
                    )

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
                    # Build compact timestamped excerpts: each top-10 hit + immediate ±1 neighbor
                    lines: list[str] = []
                    seen_ctx_dias: set[str] = set()
                    for idx, (dia, snip) in enumerate(zip(ranked_dias[:top_k], snippets[:top_k], strict=False)):
                        block_lines: list[str] = []
                        if snip.startswith("[L3"):
                            obs_head = snip.split(" || ", 1)[0]
                            block_lines.append(f"  {obs_head}")
                        p1 = dia_to_prev.get(dia)
                        n1 = dia_to_next.get(dia)
                        for nb_d in (p1, dia, n1):
                            if nb_d and nb_d not in seen_ctx_dias and nb_d in dia_to_text:
                                seen_ctx_dias.add(nb_d)
                                marker = " *" if nb_d == dia else ""
                                block_lines.append(f"  [{nb_d}{marker}] {dia_to_text[nb_d]}")
                        if block_lines:
                            lines.append(f"Excerpt #{idx + 1}:\n" + "\n".join(block_lines))
                    context_text = "\n".join(lines)[:9000]
                    m = compute_ranking_metrics(ranked_dias, gold_dias, ks=(5, 10))

                    reader_rows.append(
                        {
                            "item_id": item_id,
                            "question": question,
                            "question_date": "",
                            "context_text": context_text,
                            "context_tokens": _approx_toks(context_text),
                        }
                    )
                    gold_map[item_id] = {
                        "item_id": item_id,
                        "category": cat_name,
                        "is_abstention": is_adv,
                        "question": question,
                        "question_date": "",
                        "gold_answer": gold_ans,
                        "retrieval_hit_at_5": bool(m["r@5"] > 0),
                        "retrieval_hit_at_10": bool(m["r@10"] > 0),
                        "context_tokens": _approx_toks(context_text),
                        "full_history_tokens": max(1, full_chars // 4),
                    }
            finally:
                store.close()
    finally:
        if embed_cache is not None:
            embed_cache.close()

    with reader_path.open("w", encoding="utf-8") as fh:
        for row in reader_rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    gold_path.write_text(json.dumps(gold_map, indent=2, ensure_ascii=False), encoding="utf-8")

    return {
        "suite": f"locomo-{mode}",
        "count": len(reader_rows),
        "reader_inputs": str(reader_path),
        "gold_key": str(gold_path),
        "elapsed_s": round(time.perf_counter() - t0_all, 2),
        "avg_context_tokens": round(
            sum(r["context_tokens"] for r in reader_rows) / max(1, len(reader_rows)), 1
        ),
        "avg_full_history_tokens": round(
            sum(g["full_history_tokens"] for g in gold_map.values()) / max(1, len(gold_map)), 1
        ),
    }


# ---------------------------------------------------------------------------
# Stage 4-5: Pluggable OpenAI-Compatible / Gemini / Anthropic API Runner
# ---------------------------------------------------------------------------
def _detect_api_backend(
    *,
    model_override: str | None = None,
    base_url_override: str | None = None,
) -> dict[str, str] | None:
    if os.environ.get("OPENAI_API_KEY") or os.environ.get("RAW_MEMORY_LLM_API_KEY"):
        return {
            "provider": "openai",
            "api_key": os.environ.get("RAW_MEMORY_LLM_API_KEY")
            or os.environ["OPENAI_API_KEY"],
            "base_url": (
                base_url_override
                or os.environ.get("RAW_MEMORY_LLM_BASE_URL")
                or os.environ.get("OPENAI_BASE_URL")
                or "https://api.openai.com/v1"
            ).rstrip("/"),
            "model": model_override or os.environ.get("RAW_MEMORY_LLM_MODEL") or "gpt-4o-mini",
        }
    if os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY"):
        return {
            "provider": "gemini",
            "api_key": os.environ.get("GEMINI_API_KEY") or os.environ["GOOGLE_API_KEY"],
            "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
            "model": model_override or os.environ.get("RAW_MEMORY_LLM_MODEL") or "gemini-2.5-flash",
        }
    return None


def _call_chat_completion(cfg: dict[str, str], system: str, user: str) -> str:
    payload = json.dumps(
        {
            "model": cfg["model"],
            "temperature": 0.0,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        f"{cfg['base_url']}/chat/completions",
        data=payload,
        headers={
            "Authorization": f"Bearer {cfg['api_key']}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    return str(body["choices"][0]["message"]["content"]).strip()


def run_api_reader_and_judge(
    pack_dir: Path,
    *,
    suite: str,
    reader_model: str | None = None,
    judge_model: str | None = None,
    base_url: str | None = None,
) -> tuple[Path, Path, str, str]:
    """Execute blind Reader + independent Official Judge via OpenAI-compatible or Gemini API."""
    reader_cfg = _detect_api_backend(model_override=reader_model, base_url_override=base_url)
    judge_cfg = _detect_api_backend(model_override=judge_model, base_url_override=base_url)
    if reader_cfg is None or judge_cfg is None:
        raise RuntimeError(
            "No LLM API key found. Set OPENAI_API_KEY (or GEMINI_API_KEY / RAW_MEMORY_LLM_API_KEY) "
            "or run external/workflow reader & judge JSONL files and call `score_academic_e2e()`."
        )

    pack_dir = Path(pack_dir)
    reader_inputs = [
        json.loads(line)
        for line in (pack_dir / "reader_inputs.jsonl").read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    gold_map = json.loads((pack_dir / "gold_key.json").read_text(encoding="utf-8"))

    reader_out_path = pack_dir / "reader_outputs.jsonl"
    judge_out_path = pack_dir / "judge_outputs.jsonl"

    preds: dict[str, str] = {}
    with reader_out_path.open("w", encoding="utf-8") as fh:
        for row in reader_inputs:
            iid = str(row["item_id"])
            q_date_line = f"Question Date: {row['question_date']}\n" if row.get("question_date") else ""
            user_prompt = (
                f"{q_date_line}Question: {row['question']}\n\n"
                f"Retrieved Memory Excerpts:\n{row['context_text']}\n\n"
                "Answer concisely based strictly on the memory excerpts above:"
            )
            ans = _call_chat_completion(reader_cfg, READER_SYSTEM_PROMPT, user_prompt)
            preds[iid] = ans
            fh.write(json.dumps({"item_id": iid, "answer": ans}, ensure_ascii=False) + "\n")

    is_lme = suite.startswith("longmemeval")
    with judge_out_path.open("w", encoding="utf-8") as fh:
        for row in reader_inputs:
            iid = str(row["item_id"])
            g = gold_map[iid]
            if is_lme:
                instr = get_longmemeval_judge_instruction(
                    str(g["category"]), bool(g["is_abstention"])
                )
                j_user = (
                    f"{instr}\n\n"
                    f"Question: {g['question']}\n"
                    f"Correct Answer: {g['gold_answer']}\n"
                    f"Model Response: {preds.get(iid, '')}\n\n"
                    'Respond with strict JSON: {"correct": true|false, "reason": "brief reason"}'
                )
            else:
                j_user = (
                    f"{LOCOMO_JUDGE_PROMPT}\n\n"
                    f"Question: {g['question']}\n"
                    f"Gold Answer: {g['gold_answer']}\n"
                    f"Generated Answer: {preds.get(iid, '')}\n\n"
                    'Respond with strict JSON: {"correct": true|false, "reason": "brief reason"}'
                )
            raw = _call_chat_completion(
                judge_cfg, "You are a strict, impartial academic benchmark evaluator.", j_user
            )
            m = re.search(r"\{.*\}", raw, re.DOTALL)
            if m:
                parsed = json.loads(m.group(0))
                ok = bool(parsed.get("correct"))
                reason = str(parsed.get("reason") or "")
            else:
                low = raw.lower()
                ok = low.startswith("yes") or "correct" in low[:24]
                reason = raw[:120]
            fh.write(
                json.dumps({"item_id": iid, "correct": ok, "reason": reason}, ensure_ascii=False)
                + "\n"
            )

    return reader_out_path, judge_out_path, reader_cfg["model"], judge_cfg["model"]


# ---------------------------------------------------------------------------
# Stage 5 Aggregation & Scorecard Rendering
# ---------------------------------------------------------------------------
def score_academic_e2e(
    pack_dir: Path,
    *,
    suite: str,
    engine_label: str,
    reader_model: str,
    judge_model: str,
    reader_outputs_path: Path | None = None,
    judge_outputs_path: Path | None = None,
) -> AcademicE2EReport:
    """Aggregate blind Reader + independent Judge JSONL outputs into an `AcademicE2EReport`."""
    pack_dir = Path(pack_dir)
    gold_map = json.loads((pack_dir / "gold_key.json").read_text(encoding="utf-8"))
    r_path = reader_outputs_path or (pack_dir / "reader_outputs.jsonl")
    j_path = judge_outputs_path or (pack_dir / "judge_outputs.jsonl")

    preds: dict[str, str] = {}
    for line in r_path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            obj = json.loads(line)
            preds[str(obj["item_id"])] = str(obj.get("answer") or "")

    verdicts: dict[str, tuple[bool, str]] = {}
    for line in j_path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            obj = json.loads(line)
            verdicts[str(obj["item_id"])] = (
                bool(obj.get("correct")),
                str(obj.get("reason") or ""),
            )

    is_locomo = suite.startswith("locomo")
    items: list[AcademicE2EItemResult] = []
    by_cat: dict[str, list[AcademicE2EItemResult]] = defaultdict(list)

    for iid, g in gold_map.items():
        if iid not in verdicts:
            continue
        ok, reason = verdicts[iid]
        pred = preds.get(iid, "")
        is_abs = bool(g.get("is_abstention"))
        cat = "abstention" if (is_abs and not is_locomo) else str(g["category"])
        f1_val = (
            compute_token_f1(pred, str(g["gold_answer"]))
            if (is_locomo and not is_abs)
            else None
        )
        row = AcademicE2EItemResult(
            item_id=iid,
            category=cat,
            question=str(g["question"]),
            question_date=str(g.get("question_date") or ""),
            is_abstention=is_abs,
            gold_answer=str(g["gold_answer"]),
            predicted_answer=pred,
            judge_correct=ok,
            judge_reason=reason,
            token_f1=f1_val,
            retrieval_hit_at_5=bool(g.get("retrieval_hit_at_5")),
            retrieval_hit_at_10=bool(g.get("retrieval_hit_at_10")),
            context_tokens=int(g.get("context_tokens") or 0),
            full_history_tokens=int(g.get("full_history_tokens") or 0),
        )
        items.append(row)
        by_cat[cat].append(row)

    pos_items = [x for x in items if not x.is_abstention]
    abs_items = [x for x in items if x.is_abstention]
    f1_vals = [x.token_f1 for x in items if x.token_f1 is not None]

    avg_ctx = sum(x.context_tokens for x in items) / max(1, len(items))
    avg_full = sum(x.full_history_tokens for x in items) / max(1, len(items))
    red_pct = round((1.0 - avg_ctx / max(1.0, avg_full)) * 100.0, 1)

    cat_summary: dict[str, dict[str, Any]] = {}
    for cat, rows in sorted(by_cat.items()):
        entry: dict[str, Any] = {
            "count": len(rows),
            "accuracy": round(sum(1 for r in rows if r.judge_correct) / max(1, len(rows)), 4),
            "retrieval_r5": round(
                sum(1 for r in rows if r.retrieval_hit_at_5) / max(1, len(rows)), 4
            ),
            "retrieval_r10": round(
                sum(1 for r in rows if r.retrieval_hit_at_10) / max(1, len(rows)), 4
            ),
        }
        cat_f1 = [r.token_f1 for r in rows if r.token_f1 is not None]
        if cat_f1:
            entry["token_f1"] = round(sum(cat_f1) / len(cat_f1), 4)
        cat_summary[cat] = entry

    errors = [
        {
            "item_id": x.item_id,
            "category": x.category,
            "question": x.question,
            "gold_answer": x.gold_answer,
            "predicted_answer": x.predicted_answer,
            "judge_reason": x.judge_reason,
            "retrieval_hit_at_5": x.retrieval_hit_at_5,
        }
        for x in items
        if not x.judge_correct
    ][:30]

    return AcademicE2EReport(
        suite=suite,
        engine_label=engine_label,
        reader_model=reader_model,
        judge_model=judge_model,
        evaluated_at_ms=now_ms(),
        total_questions=len(items),
        scored_questions=len(pos_items),
        abstention_questions=len(abs_items),
        overall_accuracy=round(sum(1 for x in items if x.judge_correct) / max(1, len(items)), 4),
        positive_accuracy=round(
            sum(1 for x in pos_items if x.judge_correct) / max(1, len(pos_items)), 4
        ),
        abstention_accuracy=round(
            sum(1 for x in abs_items if x.judge_correct) / len(abs_items), 4
        )
        if abs_items
        else None,
        avg_token_f1=round(sum(f1_vals) / len(f1_vals), 4) if f1_vals else None,
        retrieval_r5=round(
            sum(1 for x in pos_items if x.retrieval_hit_at_5) / max(1, len(pos_items)), 4
        ),
        retrieval_r10=round(
            sum(1 for x in pos_items if x.retrieval_hit_at_10) / max(1, len(pos_items)), 4
        ),
        avg_context_tokens=round(avg_ctx, 1),
        avg_full_history_tokens=round(avg_full, 1),
        token_reduction_pct=red_pct,
        by_category=cat_summary,
        sample_errors=errors,
    )


def render_academic_e2e_markdown(rep: AcademicE2EReport) -> str:
    lines = [
        f"# Raw Memory Academic E2E LLM-as-a-Judge Report — `{rep.suite}`",
        "",
        f"- **Memory Engine**: `{rep.engine_label}` (100% Local SQLite + ONNX Embeddings + Cross-Encoder + Entity Graph)",
        f"- **Blind Reader LLM**: `{rep.reader_model}` (zero gold visibility)",
        f"- **Independent Judge LLM**: `{rep.judge_model}` (official academic prompt)",
        f"- **Evaluated Questions**: `{rep.total_questions}` (`{rep.scored_questions}` positive + `{rep.abstention_questions}` abstention/adversarial)",
        f"- **Overall E2E Accuracy (`J-Score`)**: **{rep.overall_accuracy * 100:.1f}%** (Positive: **{rep.positive_accuracy * 100:.1f}%**"
        + (
            f" · Abstention: **{rep.abstention_accuracy * 100:.1f}%**"
            if rep.abstention_accuracy is not None
            else ""
        )
        + ")",
        f"- **Retrieval Grounding**: `R@5 = {rep.retrieval_r5 * 100:.1f}%` · `R@10 = {rep.retrieval_r10 * 100:.1f}%`",
        f"- **Context Efficiency**: Avg **{rep.avg_context_tokens:.0f} tokens** vs `{rep.avg_full_history_tokens:.0f}` full history (**-{rep.token_reduction_pct:.1f}%** prompt tokens)",
    ]
    if rep.avg_token_f1 is not None:
        lines.append(f"- **Official Normalized Token F1 (cat 1–4)**: **{rep.avg_token_f1 * 100:.1f}%**")

    lines.extend(["", "## Per-Category Breakdown", ""])
    has_f1 = any("token_f1" in m for m in rep.by_category.values())
    if has_f1:
        lines.append("| Category | N | E2E Accuracy (`J-Score`) | Token F1 | Retrieval R@5 | Retrieval R@10 |")
        lines.append("| :--- | ---: | ---: | ---: | ---: | ---: |")
        for cat, m in rep.by_category.items():
            f1_s = f"{m['token_f1'] * 100:.1f}%" if "token_f1" in m else "—"
            lines.append(
                f"| `{cat}` | {m['count']} | **{m['accuracy'] * 100:.1f}%** | {f1_s} | {m['retrieval_r5'] * 100:.1f}% | {m['retrieval_r10'] * 100:.1f}% |"
            )
    else:
        lines.append("| Official Pillar | N | E2E Accuracy | Retrieval R@5 | Retrieval R@10 |")
        lines.append("| :--- | ---: | ---: | ---: | ---: |")
        for cat, m in rep.by_category.items():
            lines.append(
                f"| `{cat}` | {m['count']} | **{m['accuracy'] * 100:.1f}%** | {m['retrieval_r5'] * 100:.1f}% | {m['retrieval_r10'] * 100:.1f}% |"
            )

    if rep.sample_errors:
        lines.extend(["", "## Sample E2E Errors (for Failure Audit)", ""])
        for err in rep.sample_errors[:10]:
            lines.append(
                f"- **`{err['item_id']}` (`{err['category']}`, ret_hit@5={err['retrieval_hit_at_5']})**: {err['question']}"
            )
            lines.append(f"  - Gold: `{err['gold_answer'][:160]}`")
            lines.append(f"  - Pred: `{err['predicted_answer'][:160]}`")
            if err.get("judge_reason"):
                lines.append(f"  - Judge: {err['judge_reason'][:160]}")

    return "\n".join(lines) + "\n"
