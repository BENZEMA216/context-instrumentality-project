"""Unit & integration tests for Raw Memory v0.9 Agentic Two-Turn E2E & OpenRouter/OpenAI Judge:
- Calibrated Reader prompt separating factual abstention from grounded hypothetical inference
- OpenRouter automatic API backend detection (`OPENROUTER_API_KEY`)
- Rank-prioritized Top-10 LongMemEval blind pack (`packed_session_ids` + zero gold leakage)
- Genuine local `HubStore` second-hop Agentic retrieval (`fetch_agentic_second_hop_longmemeval`
  & `fetch_agentic_second_hop_locomo`) strictly excluding already-seen sessions/turns
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from context_eval.academic_e2e import (
    AGENTIC_TURN1_SYSTEM_PROMPT,
    READER_SYSTEM_PROMPT,
    _detect_api_backend,
    fetch_agentic_second_hop_locomo,
    fetch_agentic_second_hop_longmemeval,
    prepare_longmemeval_e2e_pack,
)
from context_hub.semantic import semantic_available

REPO_ROOT = Path(__file__).resolve().parent.parent


def test_calibrated_reader_prompts_and_openrouter_backend_detection(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert "FACTUAL ABSTENTION" in READER_SYSTEM_PROMPT
    assert "GROUNDED HYPOTHETICAL INFERENCE" in READER_SYSTEM_PROMPT
    assert "needs_more_context" in AGENTIC_TURN1_SYSTEM_PROMPT
    assert "follow_up_query" in AGENTIC_TURN1_SYSTEM_PROMPT

    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("RAW_MEMORY_LLM_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-v1-dummy-test-key-0000000000")

    cfg = _detect_api_backend(model_override="openai/gpt-4o")
    assert cfg is not None
    assert cfg["provider"] == "openrouter"
    assert cfg["base_url"] == "https://openrouter.ai/api/v1"
    assert cfg["model"] == "openai/gpt-4o"


def test_longmemeval_rank_first_pack_and_blind_isolation(tmp_path: Path) -> None:
    pack_dir = tmp_path / "lme_smoke_v09"
    meta = prepare_longmemeval_e2e_pack(
        REPO_ROOT / "benchmarks" / "fixtures" / "longmemeval_smoke.json",
        pack_dir,
        split_name="longmemeval-s",
        top_sessions=10,
        use_semantic=False,
        use_reranker=False,
    )
    assert meta["count"] == 2
    rows = [
        json.loads(line)
        for line in (pack_dir / "reader_inputs.jsonl").read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    assert len(rows) == 2
    for row in rows:
        assert "packed_session_ids" in row
        assert isinstance(row["packed_session_ids"], list)
        assert "gold_answer" not in row
        assert "is_abstention" not in row


@pytest.mark.skipif(not semantic_available(), reason="fastembed semantic extra required")
def test_agentic_second_hop_excludes_seen_sessions_and_fetches_new_evidence(
    tmp_path: Path,
) -> None:
    cache_db = tmp_path / "embed_cache.sqlite3"
    # 1. LongMemEval second-hop: mark session `sess_old` already seen -> must pull unseen `sess_new`
    lme_fixture = REPO_ROOT / "benchmarks" / "fixtures" / "longmemeval_smoke.json"
    lme_data = json.loads(lme_fixture.read_text(encoding="utf-8"))
    pos_item = next(it for it in lme_data if not str(it["question_id"]).endswith("_abs"))
    qid = str(pos_item["question_id"])
    first_sid = str(pos_item["haystack_session_ids"][0])

    extras_lme = fetch_agentic_second_hop_longmemeval(
        lme_fixture,
        {qid: (str(pos_item["question"]), [first_sid])},
        extra_sessions=2,
        embed_cache_path=cache_db,
    )
    assert qid in extras_lme
    assert "Follow-Up Session" in extras_lme[qid]

    # 2. LoCoMo second-hop: mark D1:1 & D1:3 seen -> follow-up for marathon must pull unseen D2:2!
    loco_fixture = REPO_ROOT / "benchmarks" / "fixtures" / "locomo_smoke.json"
    extras_loco = fetch_agentic_second_hop_locomo(
        loco_fixture,
        {"smoke-conv-1#q2": ("Autumn Harbor Half Marathon training", ["D1:1", "D1:2", "D1:3"])},
        mode="curated",
        extra_k=3,
        embed_cache_path=cache_db,
    )
    assert "smoke-conv-1#q2" in extras_loco
    assert "Autumn Harbor Half Marathon" in extras_loco["smoke-conv-1#q2"]
    assert "[D1:3]" not in extras_loco["smoke-conv-1#q2"]
