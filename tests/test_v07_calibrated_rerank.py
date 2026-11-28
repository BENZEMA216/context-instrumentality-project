"""Unit & integration tests for Raw Memory v0.7 calibrated hierarchical reranking:
- Automatic CJK vs Latin Cross-Encoder routing (`select_rerank_model`)
- Bilingual past-tense assistant-recall detection (`query_targets_assistant`)
- Confidence-adaptive calibrated logit + RRF fusion (`calibrate_rerank_blend`)
- Official LoCoMo category mapping (`1=multi_hop`, `4=single_hop`)
- End-to-end `HubStore.search_context(use_reranker=True)` Session-Best-Chunk CE,
  `[Prev2, Prev1]` context window, and RFC-0003 First-Person Authority Prior
"""

from __future__ import annotations

import datetime
from pathlib import Path

import pytest

from context_eval.standard_benchmarks import LOCOMO_CATEGORIES
from context_hub.semantic import (
    DEFAULT_RERANK_MODEL,
    MULTILINGUAL_RERANK_MODEL,
    PersistentEmbedCache,
    calibrate_rerank_blend,
    query_targets_assistant,
    reranker_available,
    select_rerank_model,
    semantic_available,
)
from context_hub.store import HubStore


def _utc_ms(y: int, m: int, d: int, hh: int = 12) -> int:
    return int(datetime.datetime(y, m, d, hh, 0, tzinfo=datetime.UTC).timestamp() * 1000)


def test_select_rerank_model_routes_cjk_and_latin() -> None:
    assert select_rerank_model("What book did I buy last Tuesday?") == DEFAULT_RERANK_MODEL
    assert select_rerank_model("上次跟政哥对齐的手表录音界面怎么改的？") == MULTILINGUAL_RERANK_MODEL
    assert select_rerank_model("raw memory 的命名规则是什么") == MULTILINGUAL_RERANK_MODEL
    assert select_rerank_model("先週おすすめした本は何ですか？") == MULTILINGUAL_RERANK_MODEL
    assert select_rerank_model("中文查询", override="custom/model") == "custom/model"


def test_query_targets_assistant_distinguishes_past_recall_from_present_request() -> None:
    # Past-tense assistant recall -> True
    assert query_targets_assistant("Remind me which Thai restaurant you recommended earlier.")
    assert query_targets_assistant("What books did you suggest when we talked about sci-fi?")
    assert query_targets_assistant("In our previous conversation, what podcast did you mention?")
    assert query_targets_assistant("你上次推荐的播客叫什么名字？")
    assert query_targets_assistant("提醒我一下之前聊的方案")

    # Present-tense recommendation requests & first-person fact questions -> False
    assert not query_targets_assistant("Can you recommend a vegetarian dinner recipe for tonight?")
    assert not query_targets_assistant("Could you suggest some beginner photography tips?")
    assert not query_targets_assistant("What camera lens did I buy in March?")
    assert not query_targets_assistant("能帮我推荐几个周末去处吗？")


def test_calibrate_rerank_blend_confidence_adaptation() -> None:
    # Case 1: High-confidence CE logit margin (+8.5 vs -3.2) overrides noisy Stage-1 RRF #1
    rrf_order = ["noisy_bm25_top", "gold_item", "other_item"]
    ce_confident = [("gold_item", 8.5), ("noisy_bm25_top", -3.2), ("other_item", -6.0)]
    blended_high = calibrate_rerank_blend(rrf_order, ce_confident)
    assert blended_high[0][0] == "gold_item"
    assert blended_high[0][1] > blended_high[1][1] + 0.35

    # Case 2: Low-confidence CE logits (all <= -7.0, e.g. abstract zero-overlap preference query)
    # shifts weight back to Stage-1 Dense MaxSim RRF so a marginal -7.2 noise logit does not
    # hijack a clean Stage-1 #1 candidate at -7.8.
    rrf_dense = ["dense_gold", "low_rank_1", "low_rank_2", "low_rank_3", "low_rank_4", "ce_noise"]
    ce_weak = [
        ("ce_noise", -7.2),
        ("dense_gold", -7.8),
        ("low_rank_1", -8.0),
        ("low_rank_2", -8.2),
        ("low_rank_3", -8.5),
        ("low_rank_4", -9.0),
    ]
    blended_low = calibrate_rerank_blend(rrf_dense, ce_weak)
    assert blended_low[0][0] == "dense_gold"

    # Case 3: Extra authority bonus breaks near-ties cleanly
    tied_ce = [("assistant_echo", 5.0), ("user_fact", 5.0)]
    blended_auth = calibrate_rerank_blend(
        ["assistant_echo", "user_fact"],
        tied_ce,
        extra_bonuses={"user_fact": 0.14},
    )
    assert blended_auth[0][0] == "user_fact"


def test_locomo_official_category_mapping() -> None:
    assert LOCOMO_CATEGORIES[1] == "multi_hop"
    assert LOCOMO_CATEGORIES[2] == "temporal"
    assert LOCOMO_CATEGORIES[3] == "open_domain"
    assert LOCOMO_CATEGORIES[4] == "single_hop"
    assert LOCOMO_CATEGORIES[5] == "adversarial"


@pytest.mark.skipif(
    not (semantic_available() and reranker_available()),
    reason="fastembed semantic + cross-encoder reranker extra required",
)
def test_hubstore_v07_session_chunk_ce_and_authority_prior(tmp_path: Path) -> None:
    store = HubStore(tmp_path)
    cache = PersistentEmbedCache(tmp_path / "embed_cache.sqlite3")
    try:
        t0 = _utc_ms(2026, 2, 10)
        store.ingest_sessions_bulk(
            [
                {
                    "episode_id": "ep_camera",
                    "title": "Camera purchase & recommendation",
                    "t_start": t0,
                    "turns": [
                        {
                            "id": "t_user_fact",
                            "actor": "self",
                            "t_start": t0,
                            "text": "I finally bought the Sony FE 35mm f/1.4 GM lens for street photography.",
                        },
                        {
                            "id": "t_asst_echo",
                            "actor": "assistant",
                            "t_start": t0 + 1000,
                            "text": "Congratulations on buying the Sony FE 35mm f/1.4 GM lens for street photography! I also recommend trying the Peak Design Slide Lite strap.",
                        },
                        {
                            "id": "t_distractor",
                            "actor": "self",
                            "t_start": t0 + 2000,
                            "text": "By the way, how do I clean dust off a camera sensor?",
                        },
                    ],
                },
                {
                    "episode_id": "ep_cooking",
                    "title": "Unrelated pasta chat",
                    "t_start": t0 + 86_400_000,
                    "turns": [
                        {
                            "id": "t_cook_1",
                            "actor": "self",
                            "t_start": t0 + 86_400_000,
                            "text": "I made homemade pesto pasta with toasted pine nuts.",
                        }
                    ],
                },
            ],
            project="personal",
        )
        store.index_semantic(
            kinds=("episode_chunk", "raw"),
            embed_cache=cache,
            contextualize_turns=True,
        )

        # 1. First-person fact query -> prefers human `t_user_fact` over assistant echo
        res_user = store.search_context(
            "What camera lens did I buy for street photography?",
            use_semantic=True,
            embed_cache=cache,
            use_reranker=True,
            agent=True,
        )
        assert res_user["episodes"][0]["id"] == "ep_camera"
        assert res_user["raw_matches"][0]["id"] == "t_user_fact"

        # 2. Past-tense assistant recall query -> prefers assistant `t_asst_echo`
        res_asst = store.search_context(
            "Remind me which camera strap you recommended earlier?",
            use_semantic=True,
            embed_cache=cache,
            use_reranker=True,
            agent=True,
        )
        assert res_asst["episodes"][0]["id"] == "ep_camera"
        assert res_asst["raw_matches"][0]["id"] == "t_asst_echo"
    finally:
        cache.close()
        store.close()
