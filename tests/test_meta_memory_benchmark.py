"""Tests for the Reflexive Meta Memory Benchmark (`context_eval`) package."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from context_eval.anti_echo import run_anti_echo_stress
from context_eval.baselines import (
    CausalLeakageError,
    build_causal_replay_store,
    run_baseline,
    verify_causal_isolation,
)
from context_eval.cli import main as eval_cli_main
from context_eval.memory_judge import audit_curated_memory
from context_eval.miner import mine_candidates
from context_eval.raw_audit import audit_raw_data
from context_eval.runner import (
    default_dataset_path,
    evaluate_dataset,
    load_dataset,
    render_markdown_report,
)
from context_eval.schema import BenchmarkCase, CuratedDecisionSpec, CuratedFixture, FactProbe
from context_hub.models import CurationBatchIn, DecisionCurationIn, RawEventIn
from context_hub.store import HubStore


def test_strict_causal_isolation_excludes_future_events_and_curations(tmp_path: Path) -> None:
    cutoff = 1_765_000_100_000
    case = BenchmarkCase(
        case_id="causal_guard_test",
        dimension="bitemporal_supersession",
        title="Strict H_<t Isolation Test",
        cutoff_ms=cutoff,
        project="synth-proj",
        query="当前部署方案是什么？",
        events=[
            {
                "id": "ev_past",
                "source": "ai_chat",
                "kind": "chat_turn",
                "t_start": cutoff - 60_000,
                "t_end": cutoff - 50_000,
                "actor": "self",
                "project": "synth-proj",
                "episode_id": "ep_past",
                "content": {"role": "user", "title": "Past", "text": "当前采用 LocalSQLite 方案。"},
                "provenance": {"connector": "chat-history/codex", "source_id": "s1:1"},
            },
            {
                "id": "ev_boundary_equal",
                "source": "ai_chat",
                "kind": "chat_turn",
                "t_start": cutoff,
                "t_end": cutoff + 1_000,
                "actor": "self",
                "project": "synth-proj",
                "episode_id": "ep_boundary",
                "content": {"role": "user", "title": "Boundary", "text": "CANARY_EQUAL_BOUNDARY"},
                "provenance": {"connector": "chat-history/codex", "source_id": "s2:1"},
            },
            {
                "id": "ev_future",
                "source": "ai_chat",
                "kind": "chat_turn",
                "t_start": cutoff + 60_000,
                "t_end": cutoff + 70_000,
                "actor": "self",
                "project": "synth-proj",
                "episode_id": "ep_future",
                "content": {"role": "user", "title": "Future", "text": "CANARY_FUTURE_CLOUD"},
                "provenance": {"connector": "chat-history/codex", "source_id": "s3:1"},
            },
        ],
        curations=[
            CuratedFixture(
                committed_at_ms=cutoff - 30_000,
                decisions=[
                    CuratedDecisionSpec(
                        ref_id="d1",
                        project="synth-proj",
                        topic="deploy_mode",
                        statement="采用 LocalSQLite 方案。",
                        valid_at=cutoff - 60_000,
                        evidence_ids=["ev_past"],
                    )
                ],
            ),
            CuratedFixture(
                committed_at_ms=cutoff + 90_000,
                decisions=[
                    CuratedDecisionSpec(
                        ref_id="d2",
                        project="synth-proj",
                        topic="deploy_mode",
                        statement="改用 CANARY_FUTURE_CLOUD 方案。",
                        valid_at=cutoff + 60_000,
                        supersedes_ref="d1",
                        evidence_ids=["ev_future"],
                    )
                ],
            ),
        ],
        required_facts=[FactProbe(fact_id="local", any_of=["localsqlite"])],
        forbidden_stale_facts=[FactProbe(fact_id="future", any_of=["canary_future_cloud"])],
        future_canary_tokens=["CANARY_EQUAL_BOUNDARY", "CANARY_FUTURE_CLOUD"],
    )

    replay = build_causal_replay_store(case, tmp_path / "replay")
    assert replay.ingested_ids == {"ev_past"}
    assert replay.excluded_future_ids == {"ev_boundary_equal", "ev_future"}

    # Every baseline must see zero future canaries
    for baseline_name in ("no_memory", "raw_fts", "flat_memory_md", "hub_v2_curated"):
        out = run_baseline(baseline_name, replay.store, case)  # type: ignore[arg-type]
        assert "CANARY_EQUAL_BOUNDARY" not in out.context_text
        assert "CANARY_FUTURE_CLOUD" not in out.context_text

    # Directly verify leak-check guard trips if a future event is manually injected
    replay.store.ingest_event(case.events[1], write_l0=False, sync_md=False)
    with pytest.raises(CausalLeakageError):
        verify_causal_isolation(replay.store, cutoff)


def test_synthetic_dataset_baselines_and_scorecard_comparisons() -> None:
    dataset = load_dataset(default_dataset_path())
    assert dataset.synthetic_only is True
    assert len(dataset.cases) == 18
    dims = [c.dimension for c in dataset.cases]
    assert dims.count("cold_start_continuation") == 6
    assert dims.count("correction_avoidance") == 6
    assert dims.count("bitemporal_supersession") == 6

    report = evaluate_dataset(dataset, run_anti_echo=True, generations=5)
    by_name = {sc.baseline: sc for sc in report.baselines}
    assert set(by_name) == {"no_memory", "raw_fts", "flat_memory_md", "hub_v2_curated"}

    # Zero causal future leaks across all baselines
    for sc in report.baselines:
        assert sc.future_leak_count == 0

    no_mem = by_name["no_memory"]
    raw_fts = by_name["raw_fts"]
    flat_md = by_name["flat_memory_md"]
    hub_v2 = by_name["hub_v2_curated"]

    # Baselines ordering sanity checks
    assert no_mem.overall_fact_recall == 0.0
    assert no_mem.avg_tokens == 0.0

    # hub_v2_curated must clearly outperform no_memory and raw_fts overall and on correction avoidance
    assert hub_v2.overall_fact_recall > raw_fts.overall_fact_recall
    assert hub_v2.overall_fact_recall >= 0.95
    assert (hub_v2.correction_avoidance_rate or 0.0) > (raw_fts.correction_avoidance_rate or 0.0)
    assert (hub_v2.correction_avoidance_rate or 0.0) >= 0.95

    # On bitemporal_supersession, hub_v2_curated achieves high accuracy with strictly lower stale leakage than flat_memory_md
    bt_hub = hub_v2.by_dimension["bitemporal_supersession"]
    bt_flat = flat_md.by_dimension["bitemporal_supersession"]
    assert (bt_hub.current_truth_accuracy or 0.0) >= 0.95
    assert bt_hub.stale_leakage_rate < bt_flat.stale_leakage_rate
    assert bt_hub.stale_leakage_rate == 0.0
    assert bt_flat.stale_leakage_rate >= 0.5

    # Markdown scorecard renders cleanly with all sections
    md = render_markdown_report(report)
    assert "## 1. Overall A/B Baseline Comparison" in md
    assert "## 2. Per-Dimension Breakdown" in md
    assert "## 3. Reflexive Anti-Echo Closed-Loop Stress Test" in md
    assert "`hub_v2_curated`" in md


def test_anti_echo_five_generation_stress_guarded_vs_naive() -> None:
    guarded = run_anti_echo_stress(generations=5, mode="guarded")
    assert guarded.passed is True
    assert guarded.generations == 5
    assert len(guarded.traces) == 5
    assert guarded.hallucination_amplification_rate == 0.0
    assert guarded.authority_drift_rate == 0.0
    assert guarded.injection_compromise_rate == 0.0
    assert guarded.memory_bloat_ratio <= 1.1
    assert guarded.fabricated_evidence_gate_passed is True

    # Falsifiability check: unguarded naive curator must trigger all reflexive failure modes
    naive = run_anti_echo_stress(generations=3, mode="naive_unguarded")
    assert naive.passed is False
    assert naive.hallucination_amplification_rate > 0.0
    assert naive.authority_drift_rate > 0.0
    assert naive.injection_compromise_rate > 0.0
    assert naive.memory_bloat_ratio > 1.5


def test_miner_discovers_all_three_candidate_types_with_default_redaction(tmp_path: Path) -> None:
    hub_dir = tmp_path / "synthetic-hub"
    store = HubStore(hub_dir)
    t0 = 1_764_000_000_000

    # 1. Cold-start continuation: codex session followed >30 min later by antigravity session on same project
    store.ingest_event(
        RawEventIn(
            id="ev_m_1",
            source="ai_chat",
            kind="chat_turn",
            t_start=t0,
            t_end=t0 + 60_000,
            actor="self",
            project="synth-miner",
            content={
                "role": "user",
                "title": "Session 1",
                "text": "PRIVATE_SECRET_PHRASE_S1 讨论初版架构 https://github.com/acme-labs/synth-miner",
            },
            context={"provider": "codex", "session_id": "s_codex_1", "role": "user"},
            provenance={"connector": "chat-history/codex", "source_id": "s_codex_1:1"},
        ),
        write_l0=False,
        sync_md=False,
    )
    store.ingest_event(
        RawEventIn(
            id="ev_m_2",
            source="ai_chat",
            kind="chat_turn",
            t_start=t0 + 45 * 60 * 1000,
            t_end=t0 + 46 * 60 * 1000,
            actor="self",
            project="synth-miner",
            content={
                "role": "user",
                "title": "Session 2",
                "text": "PRIVATE_SECRET_PHRASE_S2 继续昨天的工作",
            },
            context={"provider": "antigravity", "session_id": "s_ag_2", "role": "user"},
            provenance={"connector": "chat-history/antigravity", "source_id": "s_ag_2:1"},
        ),
        write_l0=False,
        sync_md=False,
    )

    # 2. Correction avoidance: user turn with signal_hints=["user_correction"] + prior same-project history
    store.ingest_event(
        RawEventIn(
            id="ev_m_3",
            source="ai_chat",
            kind="chat_turn",
            t_start=t0 + 50 * 60 * 1000,
            t_end=t0 + 50 * 60 * 1000,
            actor="self",
            project="synth-miner",
            content={
                "role": "user",
                "title": "Correction turn",
                "text": "PRIVATE_CORRECTION_TEXT 不要用全局 pytest，改用 .venv/bin/pytest",
            },
            context={
                "provider": "antigravity",
                "session_id": "s_ag_2",
                "role": "user",
                "signal_hints": ["user_correction"],
            },
            provenance={"connector": "chat-history/antigravity", "source_id": "s_ag_2:2"},
        ),
        write_l0=False,
        sync_md=False,
    )

    # 3. Bi-temporal supersession: decision v1 superseded by decision v2
    c1 = store.commit_curation_batch(
        CurationBatchIn(
            curator_agent="test-curator",
            decisions=[
                DecisionCurationIn(
                    project="synth-miner",
                    topic="cache_policy",
                    statement="PRIVATE_DECISION_V1 使用旧方案",
                    authority="user_confirmed",
                    valid_at=t0 + 10_000,
                    evidence_ids=["ev_m_1"],
                )
            ],
        )
    )
    old_dec_id = c1["committed"]["decisions"][0]
    store.commit_curation_batch(
        CurationBatchIn(
            curator_agent="test-curator",
            decisions=[
                DecisionCurationIn(
                    project="synth-miner",
                    topic="cache_policy",
                    statement="PRIVATE_DECISION_V2 切换为新方案",
                    authority="user_confirmed",
                    valid_at=t0 + 55 * 60 * 1000,
                    supersedes_decision_id=old_dec_id,
                    evidence_ids=["ev_m_3"],
                )
            ],
        )
    )

    # Default export MUST redact all private text
    out_redacted = tmp_path / "out" / "mined_redacted.json"
    mined = mine_candidates(hub_dir, limit=20, redact=True, out_path=out_redacted)
    assert out_redacted.is_file()
    assert mined["redacted"] is True
    assert mined["exported_counts"]["cold_start_continuation"] >= 1
    assert mined["exported_counts"]["correction_avoidance"] >= 1
    assert mined["exported_counts"]["bitemporal_supersession"] >= 1

    raw_exported = out_redacted.read_text(encoding="utf-8")
    for secret_str in (
        "PRIVATE_SECRET_PHRASE_S1",
        "PRIVATE_SECRET_PHRASE_S2",
        "PRIVATE_CORRECTION_TEXT",
        "PRIVATE_DECISION_V1",
        "PRIVATE_DECISION_V2",
    ):
        assert secret_str not in raw_exported

    cs_cand = next(c for c in mined["candidates"] if c["dimension"] == "cold_start_continuation")
    assert cs_cand["provider_transition"] == "codex->antigravity"
    assert cs_cand["gap_minutes"] >= 40.0
    assert cs_cand["anchor_count"] >= 1

    ca_cand = next(c for c in mined["candidates"] if c["dimension"] == "correction_avoidance")
    assert ca_cand["signal_source"] == "signal_hints"
    assert ca_cand["prior_event_count"] >= 2

    # Opt-in unredacted export includes non-local_only text previews
    unredacted = mine_candidates(hub_dir, limit=20, redact=False)
    assert unredacted["redacted"] is False
    assert "PRIVATE_CORRECTION_TEXT" in json.dumps(unredacted, ensure_ascii=False)


def test_cli_run_and_mine_smoke(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    out_json = tmp_path / "scorecard.json"
    rc = eval_cli_main(
        [
            "run",
            "--baselines",
            "no_memory,hub_v2_curated",
            "--generations",
            "2",
            "--format",
            "json",
            "--out",
            str(out_json),
        ]
    )
    assert rc == 0
    assert out_json.is_file()
    parsed = json.loads(out_json.read_text(encoding="utf-8"))
    assert parsed["total_cases"] == 18
    assert len(parsed["baselines"]) == 2
    assert parsed["anti_echo"]["passed"] is True
    captured = capsys.readouterr()
    assert '"dataset_name": "synthetic_reflexive_v1"' in captured.out


def test_raw_audit_and_memory_observability_gates(tmp_path: Path) -> None:
    """Verify audit-raw readiness gate & audit-memory authority/grounding/live-AB grader."""
    hub_dir = tmp_path / "raw_memory_store"
    store = HubStore(hub_dir)
    base_ms = 1_763_900_000_000

    # 1. Ingest clean shareable + local_only raw events across ai_chat & clipboard
    store.ingest_event(
        RawEventIn(
            id="ev_raw_u1",
            source="ai_chat",
            kind="chat_turn",
            t_start=base_ms,
            t_end=base_ms + 1000,
            actor="self",
            project="raw-memory-demo",
            content={"role": "user", "title": "Old naming", "text": "引擎先叫 LegacyHubEngine"},
            context={"provider": "codex", "session_id": "s1", "signal_hints": ["user_decision"]},
            provenance={"connector": "chat-history/codex", "source_id": "s1:1"},
        )
    )
    store.ingest_event(
        RawEventIn(
            id="ev_raw_a1",
            source="ai_chat",
            kind="chat_turn",
            t_start=base_ms + 2000,
            t_end=base_ms + 3000,
            actor="codex",
            project="raw-memory-demo",
            content={"role": "assistant", "title": "Suggestion", "text": "建议加一个 Redis 缓存层"},
            context={"provider": "codex", "session_id": "s1"},
            provenance={"connector": "chat-history/codex", "source_id": "s1:2"},
        )
    )
    store.ingest_event(
        RawEventIn(
            id="ev_raw_u2",
            source="ai_chat",
            kind="chat_turn",
            t_start=base_ms + 60_000,
            t_end=base_ms + 61_000,
            actor="self",
            project="raw-memory-demo",
            content={"role": "user", "title": "Rename", "text": "把引擎名字统一改成 RawMemoryEngine，不要再用 LegacyHubEngine"},
            context={"provider": "antigravity", "session_id": "s2", "signal_hints": ["user_correction", "user_decision"]},
            provenance={"connector": "chat-history/antigravity", "source_id": "s2:1"},
        )
    )
    store.ingest_event(
        RawEventIn(
            id="ev_raw_secret",
            source="clipboard",
            kind="copy",
            t_start=base_ms + 70_000,
            t_end=base_ms + 70_000,
            actor="self",
            project="raw-memory-demo",
            privacy_tier="local_only",
            content={"title": "secret", "text": "LOCAL_ONLY_CANARY_999"},
            provenance={"connector": "clipcontext", "source_id": "dev:secret1"},
        )
    )

    # Gate 1: audit-raw MUST pass with 0 privacy leaks & 0 leaked envelopes & consumable pack!
    raw_rep = audit_raw_data(hub_dir, probe_query="RawMemoryEngine")
    assert raw_rep.ready_for_curation is True
    assert raw_rep.privacy["total_leaks"] == 0
    assert raw_rep.consumption["get_context_pack_raw_evidence"] >= 1
    assert raw_rep.consumption["get_curation_queue_returned"] >= 1

    # Curate episode + bi-temporal supersession (v1 -> v2) + memory
    q = store.get_curation_queue(limit=5, include_local_only=False)
    ep_id = q["items"][0]["episode"]["id"]
    # Verify signal_hints are surfaced in curation queue!
    assert any("signal_hints" in ev for ev in q["items"][0]["events"])

    c1 = store.commit_curation_batch(
        CurationBatchIn(
            curator_agent="antigravity",
            episodes=[
                {
                    "episode_id": ep_id,
                    "title": "引擎命名演进至 RawMemoryEngine",
                    "summary": "用户最终决定把引擎改名为 RawMemoryEngine，废止 LegacyHubEngine。",
                    "overview": "## 结论\n统一命名为 RawMemoryEngine。",
                    "project": "raw-memory-demo",
                    "entities": ["RawMemoryEngine"],
                    "evidence_ids": ["ev_raw_u1", "ev_raw_u2"],
                }
            ],
            decisions=[
                DecisionCurationIn(
                    project="raw-memory-demo",
                    topic="engine_name",
                    statement="引擎初版命名为 LegacyHubEngine",
                    authority="user_confirmed",
                    valid_at=base_ms + 1000,
                    evidence_ids=["ev_raw_u1"],
                )
            ],
            memories=[
                {
                    "title": "RawMemoryEngine 命名约束",
                    "body": "对外统一使用 RawMemoryEngine，不再使用 LegacyHubEngine。",
                    "kind": "preference",
                    "project": "raw-memory-demo",
                    "evidence_ids": ["ev_raw_u2"],
                }
            ],
        )
    )
    old_dec = c1["committed"]["decisions"][0]
    store.commit_curation_batch(
        CurationBatchIn(
            curator_agent="antigravity",
            decisions=[
                DecisionCurationIn(
                    project="raw-memory-demo",
                    topic="engine_name",
                    statement="引擎正式命名为 RawMemoryEngine（取代旧名）",
                    authority="user_confirmed",
                    valid_at=base_ms + 62_000,
                    supersedes_decision_id=old_dec,
                    evidence_ids=["ev_raw_u2"],
                )
            ],
        )
    )

    # Gate 2: audit-memory MUST pass 100% grounding, 100% authority fidelity, 0% stale leakage!
    mem_rep = audit_curated_memory(hub_dir, run_live_ab=True)
    assert mem_rep.overall_passed is True
    assert mem_rep.grounding["grounding_rate"] == 1.0
    assert mem_rep.grounding["authority_grounding_rate"] == 1.0
    assert mem_rep.coherence["stale_pack_leaks"] == 0
    by_b = {r.baseline: r for r in mem_rep.live_ab_scorecard}
    assert by_b["raw_memory_curated"].active_truth_recall == 1.0
    assert by_b["raw_memory_curated"].stale_leakage_rate == 0.0
    assert by_b["flat_memory_md"].stale_leakage_rate > 0.0

    # Negative test: an AI-only decision falsely marked `user_confirmed` MUST fail authority_grounding_100pct!
    store.commit_curation_batch(
        CurationBatchIn(
            curator_agent="buggy-curator",
            decisions=[
                DecisionCurationIn(
                    project="raw-memory-demo",
                    topic="cache_layer",
                    statement="强制引入 Redis 缓存层",
                    authority="user_confirmed",
                    valid_at=base_ms + 65_000,
                    evidence_ids=["ev_raw_a1"],  # assistant-only!
                )
            ],
        )
    )
    mem_rep_bad = audit_curated_memory(hub_dir, run_live_ab=False)
    assert mem_rep_bad.overall_passed is False
    assert mem_rep_bad.grounding["authority_grounding_rate"] < 1.0
    auth_chk = next(c for c in mem_rep_bad.checks if c.name == "authority_grounding_100pct")
    assert auth_chk.passed is False
