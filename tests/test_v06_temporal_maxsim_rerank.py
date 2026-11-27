"""Unit & integration tests for Raw Memory v0.6 retrieval upgrades:
- Bilingual (EN + ZH) temporal query parsing & Gaussian proximity scoring
- Multi-chunk `episode_chunk` MaxSim preventing multi-topic session dilution
- Soft Temporal Window RRF inside `HubStore.search_context(reference_time_ms=...)`
- Contextualized turn indexing (`[prev]`) + Local ONNX Cross-Encoder reranking
"""

from __future__ import annotations

import datetime
from pathlib import Path

import pytest

from context_hub.semantic import PersistentEmbedCache, reranker_available, semantic_available
from context_hub.store import HubStore
from context_hub.temporal import DAY_MS, parse_temporal_window, temporal_proximity_score


def _utc_ms(y: int, m: int, d: int, hh: int = 12) -> int:
    return int(datetime.datetime(y, m, d, hh, 0, tzinfo=datetime.UTC).timestamp() * 1000)


def test_bilingual_temporal_parser_and_gaussian_peak() -> None:
    ref = _utc_ms(2023, 5, 5, 16)  # Friday 2023-05-05

    tw_2w = parse_temporal_window("What gardening activity did I do two weeks ago?", ref)
    assert tw_2w is not None
    assert tw_2w.specificity == "point"
    # Gold 2023-04-21 (14 days before 2023-05-05) should peak near 1.0
    exact_score = temporal_proximity_score(_utc_ms(2023, 4, 21), _utc_ms(2023, 4, 21, 13), tw_2w)
    far_score = temporal_proximity_score(_utc_ms(2023, 4, 1), _utc_ms(2023, 4, 1, 13), tw_2w)
    assert exact_score > 0.95
    assert far_score < 0.1

    tw_tue = parse_temporal_window("Who did I meet during lunch last Tuesday?", _utc_ms(2023, 4, 18, 16))
    assert tw_tue is not None
    assert temporal_proximity_score(_utc_ms(2023, 4, 11, 22), _utc_ms(2023, 4, 11, 22), tw_tue) > 0.90

    tw_range = parse_temporal_window("Events during the past month", _utc_ms(2023, 7, 1, 20))
    assert tw_range is not None
    assert tw_range.specificity == "range"
    assert temporal_proximity_score(_utc_ms(2023, 6, 10), _utc_ms(2023, 6, 10), tw_range) == 1.0

    # Chinese expressions
    tw_zh_2w = parse_temporal_window("两周前我聊过的录音方案是什么？", ref)
    assert tw_zh_2w is not None
    assert temporal_proximity_score(_utc_ms(2023, 4, 21), _utc_ms(2023, 4, 21), tw_zh_2w) > 0.95

    tw_zh_wd = parse_temporal_window("上周二中午跟谁吃的饭？", _utc_ms(2023, 4, 18, 16))
    assert tw_zh_wd is not None
    assert tw_zh_wd.specificity == "point"
    assert temporal_proximity_score(_utc_ms(2023, 4, 11), _utc_ms(2023, 4, 11), tw_zh_wd) > 0.90

    tw_zh_mon = parse_temporal_window("过去一个月做过哪些 benchmark？", _utc_ms(2023, 7, 1))
    assert tw_zh_mon is not None
    assert tw_zh_mon.specificity == "range"

    assert parse_temporal_window("How does SQLite WAL mode work?", ref) is None


def test_search_context_soft_temporal_window_boosts_target_date(tmp_path: Path) -> None:
    store = HubStore(tmp_path)
    ref = _utc_ms(2023, 5, 5, 16)
    try:
        store.ingest_sessions_bulk(
            [
                {
                    "episode_id": "ep_old",
                    "title": "Old garden session",
                    "t_start": ref - 40 * DAY_MS,
                    "t_end": ref - 40 * DAY_MS + 60_000,
                    "turns": [
                        {
                            "id": "r_old_1",
                            "actor": "self",
                            "t_start": ref - 40 * DAY_MS,
                            "text": "I bought some potting soil and garden gloves.",
                        }
                    ],
                },
                {
                    "episode_id": "ep_target",
                    "title": "Two weeks ago session",
                    "t_start": ref - 14 * DAY_MS,
                    "t_end": ref - 14 * DAY_MS + 60_000,
                    "turns": [
                        {
                            "id": "r_tgt_1",
                            "actor": "self",
                            "t_start": ref - 14 * DAY_MS,
                            "text": "Today I planted twelve cherry tomato saplings in the backyard.",
                        }
                    ],
                },
            ],
            project="life",
        )
        res = store.search_context(
            "What gardening activity did I do two weeks ago?",
            reference_time_ms=ref,
            agent=True,
        )
        assert res["temporal_window"] is not None
        assert res["temporal_window"]["matched_phrase"] == "two weeks ago"
        assert res["episodes"]
        assert res["episodes"][0]["id"] == "ep_target"
    finally:
        store.close()


@pytest.mark.skipif(
    not (semantic_available() and reranker_available()),
    reason="fastembed semantic + cross-encoder reranker extra required",
)
def test_episode_chunk_maxsim_and_contextual_cross_encoder_rerank(tmp_path: Path) -> None:
    store = HubStore(tmp_path)
    cache = PersistentEmbedCache(tmp_path / "embed_cache.sqlite3")
    try:
        t0 = _utc_ms(2026, 1, 10)
        # Session 1 mixes 1 culinary preference turn with 6 unrelated pest-control turns
        store.ingest_sessions_bulk(
            [
                {
                    "episode_id": "ep_mixed_garden",
                    "title": "Garden & cooking chat",
                    "t_start": t0,
                    "turns": [
                        {"id": "g0", "actor": "self", "t_start": t0, "text": "I harvested fresh basil, mint, and cherry tomatoes from my garden for cooking."},
                        {"id": "g1", "actor": "assistant", "t_start": t0 + 1000, "text": "Fresh herbs and tomatoes are great!"},
                        {"id": "g2", "actor": "self", "t_start": t0 + 2000, "text": "Neem oil did not stop aphids on my pepper plants."},
                        {"id": "g3", "actor": "self", "t_start": t0 + 3000, "text": "Should I buy ladybugs to eat the aphids?"},
                        {"id": "g4", "actor": "self", "t_start": t0 + 4000, "text": "Do lacewings survive winter in zone 7?"},
                        {"id": "g5", "actor": "self", "t_start": t0 + 5000, "text": "How often should I spray insecticidal soap for aphids?"},
                    ],
                },
                {
                    "episode_id": "ep_music",
                    "title": "Concert chat",
                    "t_start": t0 + DAY_MS,
                    "turns": [
                        {"id": "m0", "actor": "assistant", "t_start": t0 + DAY_MS, "text": "Which singer or band did you see at the concert last night?"},
                        {"id": "m1", "actor": "self", "t_start": t0 + DAY_MS + 1000, "text": "It was Matt Patterson, he is so talented! His voice was amazing."},
                    ],
                },
            ],
            project="personal",
        )
        idx = store.index_semantic(
            kinds=("episode_chunk", "raw"),
            embed_cache=cache,
            contextualize_turns=True,
        )
        assert idx["indexed"]["episode_chunk"] >= 3
        assert idx["indexed"]["raw"] == 8

        # Multi-chunk MaxSim retrieves ep_mixed_garden #1 despite 4 off-topic aphid turns
        res_food = store.search_context(
            "What should I cook for dinner with my homegrown ingredients?",
            use_semantic=True,
            embed_cache=cache,
            use_reranker=True,
            agent=True,
        )
        assert res_food["episodes"][0]["id"] == "ep_mixed_garden"

        # Contextualized turn + Cross-Encoder promotes elliptical answer turn `m1` over question `m0`
        res_band = store.search_context(
            "Which musical artist or singer did the user see at the concert?",
            use_semantic=True,
            embed_cache=cache,
            use_reranker=True,
            agent=True,
        )
        assert res_band["raw_matches"]
        assert res_band["raw_matches"][0]["id"] == "m1"
    finally:
        cache.close()
        store.close()
