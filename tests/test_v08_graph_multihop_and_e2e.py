"""Unit & integration tests for Raw Memory v0.8 Track A & Track B upgrades:
- Entity & Concept Anchor Extraction (`extract_anchors`, `extract_query_entities`)
- Multi-Hop & Open-Inference Syntactic Query Planner (`analyze_query_structure`)
- RM3 Bridge Term Extraction (`extract_bridge_terms`) & Soft Cross-Session Diversification
- SQLite `entity_edges` Bipartite Graph (`HubStore.index_entity_graph`, `graph_bridge_search`)
  with privacy (`local_only`) isolation
- Official Academic E2E Harness (`academic_e2e.py`): Token F1, verbatim LongMemEval ICLR 2025
  task-specific judge prompts, strict blind separation (`reader_inputs.jsonl` vs `gold_key.json`),
  and end-to-end report aggregation (`score_academic_e2e`, `render_academic_e2e_markdown`)
"""

from __future__ import annotations

import datetime
import json
from pathlib import Path

from context_eval.academic_e2e import (
    compute_token_f1,
    get_longmemeval_judge_instruction,
    prepare_locomo_e2e_pack,
    render_academic_e2e_markdown,
    score_academic_e2e,
)
from context_hub.graph import (
    analyze_query_structure,
    diversify_by_group,
    extract_anchors,
    extract_bridge_terms,
    extract_query_entities,
)
from context_hub.models import RawEventIn
from context_hub.store import HubStore

REPO_ROOT = Path(__file__).resolve().parent.parent


def _utc_ms(y: int, m: int, d: int, hh: int = 12) -> int:
    return int(datetime.datetime(y, m, d, hh, 0, tzinfo=datetime.UTC).timestamp() * 1000)


def test_query_planner_dual_entity_choice_and_multihop_detection() -> None:
    p_dual = analyze_query_structure("What subject have Caroline and Melanie both painted?")
    assert p_dual.is_multi_hop is True
    assert "caroline" in p_dual.entities and "melanie" in p_dual.entities
    assert len(p_dual.sub_queries) >= 2
    assert any("Caroline" in sq and "Melanie" not in sq for sq in p_dual.sub_queries)
    assert any("Melanie" in sq and "Caroline" not in sq for sq in p_dual.sub_queries)

    p_choice = analyze_query_structure(
        "Would Melanie be more interested in going to a national park or a theme park?"
    )
    assert p_choice.is_open_inference is True
    assert len(p_choice.sub_queries) >= 2
    assert any("national park" in sq.lower() for sq in p_choice.sub_queries)
    assert any("theme park" in sq.lower() for sq in p_choice.sub_queries)

    p_plural = analyze_query_structure("What musical artists/bands has Melanie seen?")
    assert p_plural.is_multi_hop is True

    p_zh = analyze_query_structure("之前我们讨论过哪些核心记忆方案？")
    assert p_zh.is_multi_hop is True

    p_single = analyze_query_structure("When did Caroline visit the museum?")
    assert p_single.is_multi_hop is False
    assert p_single.is_open_inference is False


def test_extract_anchors_bridge_terms_and_cross_session_diversification() -> None:
    anchors = dict(
        extract_anchors(
            "Melanie went camping in Yosemite and watched the Perseid meteor shower.",
            actor="Melanie",
        )
    )
    assert "melanie" in anchors
    assert "yosemite" in anchors
    assert "camping" in anchors

    ents = extract_query_entities("What did Matt Patterson play at Summer Sounds?")
    assert "matt patterson" in ents or "matt" in ents
    assert "summer sounds" in ents or "summer" in ents

    bridges = extract_bridge_terms(
        "Would Melanie prefer a national park or a theme park?",
        [
            "Melanie loves hiking and camping in the mountains with her family.",
            "Melanie roasted marshmallows around the campfire during their camping trip.",
        ],
        df_map={"camping": 3, "mountain": 4, "hiking": 3, "campfire": 2, "family": 40},
        total_docs=60,
        max_terms=4,
    )
    assert "camping" in bridges

    # Cross-session soft diversification promotes D8 & D13 ahead of redundant 3rd turn in D1
    scored = [
        ("D1:12", 0.95),
        ("D1:14", 0.88),
        ("D1:16", 0.85),
        ("D8:6", 0.72),
        ("D13:8", 0.68),
    ]
    div = diversify_by_group(
        scored,
        group_of={d: d.split(":")[0] for d, _ in scored},
        decay_second=0.76,
        decay_rest=0.56,
        top_k=4,
    )
    top4_ids = [d for d, _ in div]
    assert top4_ids[0] == "D1:12"
    assert "D8:6" in top4_ids[:3]
    assert "D13:8" in top4_ids[:4]


def test_hubstore_entity_graph_bridge_and_privacy_isolation(tmp_path: Path) -> None:
    store = HubStore(tmp_path)
    t0 = _utc_ms(2026, 3, 1)
    try:
        store.ingest_sessions_bulk(
            [
                {
                    "episode_id": "ep_s1",
                    "title": "Outdoor hiking",
                    "t_start": t0,
                    "turns": [
                        {
                            "id": "r_hike",
                            "actor": "Melanie",
                            "t_start": t0,
                            "text": "Melanie loves exploring nature, hiking in the mountains, and camping outdoors.",
                        }
                    ],
                },
                {
                    "episode_id": "ep_s2",
                    "title": "Family campfire tradition",
                    "t_start": t0 + 86_400_000 * 5,
                    "turns": [
                        {
                            "id": "r_camp",
                            "actor": "Melanie",
                            "t_start": t0 + 86_400_000 * 5,
                            "text": "Our annual family camping trip with campfire marshmallows under the Perseid meteor shower is our favorite tradition.",
                        }
                    ],
                },
                {
                    "episode_id": "ep_s3",
                    "title": "Unrelated topic",
                    "t_start": t0 + 86_400_000 * 10,
                    "turns": [
                        {
                            "id": "r_other",
                            "actor": "Bob",
                            "t_start": t0 + 86_400_000 * 10,
                            "text": "Bob bought a new ergonomic keyboard for coding.",
                        }
                    ],
                },
            ],
            project="personal",
        )
        # Ingest a local_only turn with the same entity & bridge concept — must NEVER surface
        store.ingest_event(
            RawEventIn(
                id="r_secret_camp",
                source="ai_chat",
                kind="chat_turn",
                t_start=t0 + 86_400_000 * 12,
                t_end=t0 + 86_400_000 * 12 + 1000,
                actor="Melanie",
                project="personal",
                privacy={"tier": "local_only"},
                content={
                    "title": "Private",
                    "text": "Melanie secret camping trip vault code 9999.",
                },
                provenance={"connector": "test", "source_id": "sec:1"},
            )
        )

        idx_stats = store.index_entity_graph(kinds=("raw",))
        assert idx_stats["edges"] > 0
        assert idx_stats["entities"] > 0

        # Given Hop-1 seed `r_hike`, 2-hop graph walk bridges Melanie + camping -> `r_camp`
        # while strictly excluding `r_secret_camp`!
        bridge_hits = store.graph_bridge_search(
            "Would Melanie prefer a national park or a theme park?",
            ["Melanie loves exploring nature, hiking in the mountains, and camping outdoors."],
            item_kind="raw",
            top_k=5,
            agent=True,
        )
        hit_ids = [rid for rid, _ in bridge_hits]
        assert "r_camp" in hit_ids
        assert "r_secret_camp" not in hit_ids
    finally:
        store.close()


def test_academic_e2e_blind_isolation_token_f1_and_scoring(tmp_path: Path) -> None:
    # 1. Token F1 normalization & official LongMemEval judge prompt selection
    assert compute_token_f1("The blue lavender stems!", "blue lavender stems") == 1.0
    assert compute_token_f1("totally wrong", "blue lavender stems") == 0.0
    assert 0.4 < compute_token_f1("lavender stems", "blue lavender stems") < 0.9

    assert "off-by-one" in get_longmemeval_judge_instruction("temporal-reasoning", False)
    assert "updated answer" in get_longmemeval_judge_instruction("knowledge-update", False)
    assert "rubric" in get_longmemeval_judge_instruction("single-session-preference", False)
    assert "unanswerable" in get_longmemeval_judge_instruction("single-session-user", True)

    # 2. Blind E2E pack separation on locomo_smoke fixture (no semantic/rerank needed for fast CI)
    pack_dir = tmp_path / "locomo_smoke_e2e"
    meta = prepare_locomo_e2e_pack(
        REPO_ROOT / "benchmarks" / "fixtures" / "locomo_smoke.json",
        pack_dir,
        mode="curated",
        use_semantic=False,
        use_reranker=False,
    )
    assert meta["count"] == 4
    reader_lines = (pack_dir / "reader_inputs.jsonl").read_text(encoding="utf-8").splitlines()
    assert len(reader_lines) == 4
    # Strictly verify NO gold answers leak into reader_inputs.jsonl
    for line in reader_lines:
        row = json.loads(line)
        assert "gold_answer" not in row
        assert "answer" not in row
        assert "is_abstention" not in row

    gold_map = json.loads((pack_dir / "gold_key.json").read_text(encoding="utf-8"))
    # Simulate blind Reader outputs + Judge verdicts and score
    with (pack_dir / "reader_outputs.jsonl").open("w", encoding="utf-8") as rf, (
        pack_dir / "judge_outputs.jsonl"
    ).open("w", encoding="utf-8") as jf:
        for iid, g in gold_map.items():
            pred = (
                "Not mentioned in the conversation history."
                if g["is_abstention"]
                else g["gold_answer"]
            )
            rf.write(json.dumps({"item_id": iid, "answer": pred}) + "\n")
            jf.write(json.dumps({"item_id": iid, "correct": True, "reason": "exact"}) + "\n")

    rep = score_academic_e2e(
        pack_dir,
        suite="locomo-curated",
        engine_label="test-v0.8",
        reader_model="test-reader",
        judge_model="test-judge",
    )
    assert rep.total_questions == 4
    assert rep.overall_accuracy == 1.0
    assert rep.abstention_accuracy == 1.0
    assert rep.avg_token_f1 == 1.0
    md = render_academic_e2e_markdown(rep)
    assert "Raw Memory Academic E2E LLM-as-a-Judge Report" in md
    assert "100.0%" in md
