"""Regression tests for Standard Memory Benchmarks (LoCoMo / LongMemEval), Hybrid BM25, and Debug Workbench."""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from context_eval.fidelity import inspect_compression_fidelity
from context_eval.standard_benchmarks import (
    evaluate_locomo,
    evaluate_longmemeval,
    render_benchmark_markdown,
)
from context_eval.workbench import create_workbench_app, summarize_adjudications
from context_hub.models import (
    CurationBatchIn,
    DecisionCurationIn,
    MemoryCurationIn,
    ProjectProfileIn,
    RawEventIn,
    StatusPointerIn,
)
from context_hub.store import HubStore
from context_hub.tokenizer import fts_match_query, fts_match_query_or

REPO_ROOT = Path(__file__).resolve().parent.parent


def test_tokenizer_natural_language_and_privacy_needle_guard() -> None:
    """Stopwords & contraction debris are stripped; single-concept CJK needles stay strict."""
    q_en = fts_match_query("When did Caroline's friend paint a sunrise?")
    assert "when" not in q_en
    assert "did" not in q_en
    assert '"s"' not in q_en
    assert '"caroline"*' in q_en
    assert '"paint"*' in q_en
    assert '"sunrise"*' in q_en

    q_or = fts_match_query_or("When did Caroline's friend paint a sunrise?")
    assert " OR " in q_or

    # Single-concept CJK codeword must NOT trigger OR expansion (protects exact needle search)
    assert fts_match_query_or("松针蓝七号") == ""
    assert fts_match_query_or("星尘灰九号") == ""

    # Long Chinese natural language sentence triggers multi-concept OR BM25 fallback
    zh_or = fts_match_query_or("上次跟政哥对齐手表录音界面的波形冲突怎么改的？")
    assert " OR " in zh_or


def test_locomo_smoke_fixture_raw_and_curated() -> None:
    fixture = REPO_ROOT / "benchmarks" / "fixtures" / "locomo_smoke.json"
    raw_rep = evaluate_locomo(fixture, mode="raw", engine_label="test-raw")
    cur_rep = evaluate_locomo(fixture, mode="curated", engine_label="test-curated")

    assert raw_rep.scored_questions == 4
    assert cur_rep.scored_questions == 4
    assert raw_rep.overall["r@5"] == 1.0
    assert cur_rep.overall["r@5"] == 1.0
    assert cur_rep.overall["r@1"] >= 0.75
    assert cur_rep.overall["ans_cov@5"] == 1.0

    md = render_benchmark_markdown(cur_rep)
    assert "Raw Memory Benchmark Report" in md
    assert "`single_hop`" in md


def test_longmemeval_smoke_fixture_with_abstention() -> None:
    fixture = REPO_ROOT / "benchmarks" / "fixtures" / "longmemeval_smoke.json"
    rep = evaluate_longmemeval(fixture, split_name="longmemeval-s", engine_label="test-lme")

    assert rep.total_questions == 2
    assert rep.scored_questions == 1
    assert rep.abstention_questions == 1
    assert rep.overall["sess_r@1"] == 1.0
    assert rep.overall["turn_r@5"] == 1.0
    assert rep.overall["ans_cov@5"] == 1.0
    assert "knowledge-update" in rep.by_category
    assert "refuting_sess_r@5" in rep.abstention_metrics


def test_human_in_the_loop_debug_workbench_endpoints(tmp_path: Path) -> None:
    hub_dir = tmp_path / "hub"
    store = HubStore(hub_dir)
    base_ms = 1_764_000_000_000

    store.ingest_event(
        RawEventIn(
            id="ev_wb_1",
            source="ai_chat",
            kind="chat_turn",
            t_start=base_ms,
            t_end=base_ms + 1000,
            actor="self",
            project="raw-memory",
            content={
                "title": "Brand decision",
                "text": "我们就叫 Raw Memory，先只确认 Clip for Agent 和 Record for Agent。",
            },
            context={"signal_hints": ["user_decision"]},
            provenance={"connector": "chat-history/antigravity", "source_id": "wb:1"},
        )
    )
    store.ingest_event(
        RawEventIn(
            id="ev_wb_2",
            source="ai_chat",
            kind="chat_turn",
            t_start=base_ms + 5000,
            t_end=base_ms + 6000,
            actor="self",
            project="raw-memory",
            content={
                "title": "Watch feedback",
                "text": "手表录音界面尽量精简组件，心率状态和波形目前有冲突，需要去掉冗余元素。",
            },
            context={"signal_hints": ["user_correction"]},
            provenance={"connector": "chat-history/antigravity", "source_id": "wb:2"},
        )
    )
    q = store.get_curation_queue(limit=5, include_local_only=False)
    ep_id = q["items"][0]["episode"]["id"]
    commit = store.commit_curation_batch(
        CurationBatchIn(
            curator_agent="antigravity",
            episodes=[
                {
                    "episode_id": ep_id,
                    "title": "品牌与命名确认",
                    "summary": "确认引擎叫 Raw Memory。",
                    "overview": "确认引擎名 Raw Memory。",
                    "project": "raw-memory",
                    "evidence_ids": ["ev_wb_1", "ev_wb_2"],
                }
            ],
            decisions=[
                DecisionCurationIn(
                    project="raw-memory",
                    topic="brand_name",
                    statement="引擎叫 Raw Memory，产品含 Clip for Agent 和 Vault for Agent",
                    authority="user_confirmed",
                    valid_at=base_ms + 1500,
                    evidence_ids=["ev_wb_1"],
                )
            ],
        )
    )
    dec_id = commit["committed"]["decisions"][0]

    app = create_workbench_app(hub_dir)
    client = TestClient(app)

    # 1. HTML studio loads cleanly
    r_html = client.get("/")
    assert r_html.status_code == 200
    assert "Raw Memory" in r_html.text

    # 2. Overview detects unsupported "Vault" and omitted Watch turn
    r_ov = client.get("/api/debug/overview")
    assert r_ov.status_code == 200
    ov = r_ov.json()
    assert ov["fidelity"]["total_unsupported_claims"] >= 1
    assert any("Vault" in it["unsupported_claims"] for it in ov["fidelity"]["items"])

    # 3. Record human adjudication verdict
    r_adj = client.post(
        "/api/debug/adjudicate",
        json={
            "target_kind": "decision",
            "target_id": dec_id,
            "verdict": "over_extrapolated",
            "note": "删掉未确认的 Vault for Agent",
            "project": "raw-memory",
            "snapshot_summary": "brand_name",
        },
    )
    assert r_adj.status_code == 200
    assert r_adj.json()["summary"]["open_fix_count"] == 1

    # 4. Run live retrieval debug query & record feedback
    r_q = client.post(
        "/api/debug/query",
        json={"query": "手表录音界面的波形冲突怎么改？", "project": "raw-memory"},
    )
    assert r_q.status_code == 200
    q_data = r_q.json()
    assert q_data["latency_ms"] >= 0
    assert any(h["id"] == "ev_wb_2" for h in q_data["raw_search_hits"])

    r_qf = client.post(
        "/api/debug/query-feedback",
        json={
            "query": "手表录音界面的波形冲突怎么改？",
            "project": "raw-memory",
            "rating": "good",
            "expected_note": "命中了 ev_wb_2",
        },
    )
    assert r_qf.status_code == 200

    summary = summarize_adjudications(hub_dir)
    assert summary["total_adjudicated"] == 1
    assert summary["query_feedback_count"] == 1


def test_project_profile_exchange_window_and_anti_noise_gate(tmp_path: Path) -> None:
    """Verify Project Profiles, Q&A exchange windows, retract/delete hygiene, and Anti-Noise flags."""
    hub_dir = tmp_path / "hub_v21"
    store = HubStore(hub_dir)
    base_ms = 1_764_100_000_000

    # 3-turn Q&A conversation + 1 local_only secret turn that must never leak into context window
    store.ingest_event(
        RawEventIn(
            id="ev_qa_1",
            source="ai_chat",
            kind="chat_turn",
            t_start=base_ms,
            t_end=base_ms + 1000,
            actor="antigravity",
            project="clip-for-agent",
            content={"title": "Naming proposal", "text": "建议把 macOS 剪贴板工具改名叫 Clip for Agent"},
            context={"session_id": "sess_qa"},
            provenance={"connector": "chat-history/antigravity", "source_id": "qa:1"},
        )
    )
    store.ingest_event(
        RawEventIn(
            id="ev_qa_2",
            source="ai_chat",
            kind="chat_turn",
            t_start=base_ms + 2000,
            t_end=base_ms + 3000,
            actor="self",
            project="clip-for-agent",
            content={"title": "Short confirm", "text": "那就叫 Clip for Agent"},
            context={"session_id": "sess_qa", "signal_hints": ["user_decision"]},
            provenance={"connector": "chat-history/antigravity", "source_id": "qa:2"},
        )
    )
    store.ingest_event(
        RawEventIn(
            id="ev_qa_3",
            source="ai_chat",
            kind="chat_turn",
            t_start=base_ms + 4000,
            t_end=base_ms + 5000,
            actor="antigravity",
            project="clip-for-agent",
            content={"title": "Applied", "text": "已同步更新 Info.plist 为 Clip for Agent"},
            context={"session_id": "sess_qa"},
            provenance={"connector": "chat-history/antigravity", "source_id": "qa:3"},
        )
    )
    store.ingest_event(
        RawEventIn(
            id="ev_qa_secret",
            source="ai_chat",
            kind="chat_turn",
            t_start=base_ms + 6000,
            t_end=base_ms + 7000,
            actor="self",
            project="clip-for-agent",
            privacy={"tier": "local_only"},
            content={"title": "Private", "text": "SECRET_TOKEN_XYZ"},
            context={"session_id": "sess_qa"},
            provenance={"connector": "chat-history/antigravity", "source_id": "qa:secret"},
        )
    )

    # 1. Exchange-pair context window returns [prev, cited, next] and excludes local_only
    win = store.get_evidence_context_window("ev_qa_2", before=1, after=1, agent=True)
    assert [t["role"] for t in win["turns"]] == ["prev_context", "cited", "next_context"]
    assert [t["raw_id"] for t in win["turns"]] == ["ev_qa_1", "ev_qa_2", "ev_qa_3"]
    win_tail = store.get_evidence_context_window("ev_qa_3", before=1, after=1, agent=True)
    assert all(t["raw_id"] != "ev_qa_secret" for t in win_tail["turns"])

    # 2. Project Profile surfaces in get_project_state & get_context_pack
    store.upsert_project_profile(
        ProjectProfileIn(
            project="clip-for-agent",
            display_name="Clip for Agent",
            summary="macOS 剪贴板采集工具",
            repos=["BENZEMA216/ClipContext"],
            status_pointers=[
                StatusPointerIn(label="Linear 进度", how_to_check="查询 Linear REC-62")
            ],
            tech_notes=["使用 Apple Development 正式证书签名"],
            evidence_ids=["ev_qa_2"],
        )
    )
    state = store.get_project_state("clip-for-agent", agent=True)
    assert state["profile"]["display_name"] == "Clip for Agent"
    pack = store.get_context_pack(query="Clip for Agent 状态去哪查", project="clip-for-agent", agent=True)
    assert len(pack["project_profiles"]) == 1
    assert "Project Profile" in pack["rendered_markdown"]
    assert "Linear REC-62" in pack["rendered_markdown"]

    # 3. Anti-Noise Gate catches volatile Build snapshot, isolated short reply, and Decision<->Memory duplicate
    batch = store.commit_curation_batch(
        CurationBatchIn(
            curator_agent="test",
            decisions=[
                DecisionCurationIn(
                    project="clip-for-agent",
                    topic="build_status",
                    statement="App Store 提审已挂载 Build 154 并推进内测",
                    authority="user_confirmed",
                    valid_at=base_ms + 3000,
                    evidence_ids=["ev_qa_2"],
                )
            ],
            memories=[
                MemoryCurationIn(
                    title="重复记录",
                    body="App Store 提审已挂载 Build 154 并推进内测",
                    kind="fact",
                    project="clip-for-agent",
                    evidence_ids=["ev_qa_2"],
                )
            ],
        )
    )
    rep_before = inspect_compression_fidelity(hub_dir, include_quotes=True)
    assert rep_before.project_profiles_count == 1
    assert rep_before.total_noise_flags >= 3
    dec_item = next(i for i in rep_before.items if i.item_kind == "decision")
    mem_item = next(i for i in rep_before.items if i.item_kind == "memory")
    assert "volatile_status_snapshot" in dec_item.noise_flags
    assert "isolated_short_reply" in dec_item.noise_flags
    assert any(f.startswith("duplicate_of:") for f in mem_item.noise_flags)
    assert len(dec_item.evidence_quotes[0]["exchange_window"]) == 3

    # 4. Retract & delete remove noise cleanly from fidelity audit
    store.retract_decision(batch["committed"]["decisions"][0], reason="noise")
    store.delete_memory(batch["committed"]["memories"][0])
    rep_after = inspect_compression_fidelity(hub_dir, include_quotes=True)
    assert len(rep_after.items) == 0
    assert rep_after.total_noise_flags == 0
    assert rep_after.durability_hygiene_rate == 1.0

