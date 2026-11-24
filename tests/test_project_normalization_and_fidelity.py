"""Tests for Project Normalization (home/.git guard, worktrees, regex aliases) & Compression Fidelity."""

from __future__ import annotations

import json
from pathlib import Path

from context_eval.fidelity import inspect_compression_fidelity
from context_hub.models import (
    CurationBatchIn,
    DecisionCurationIn,
    EpisodeCurationIn,
    MemoryCurationIn,
    RawEventIn,
)
from context_hub.project_resolver import ProjectResolver, normalize_project_slug, project_from_path
from context_hub.store import HubStore


def test_project_resolver_guards_system_paths_worktrees_and_patterns(tmp_path: Path) -> None:
    # 1. System / Xcode toolchain paths must never produce fake "lib" / "contents" projects
    assert (
        project_from_path(
            "/Volumes/WristRecordUpgrade/Xcode-27.1/Xcode.app/Contents/Developer/usr/lib/libxcrun.dylib"
        )
        is None
    )
    assert project_from_path("/usr/lib/libSystem.B.dylib") is None
    assert project_from_path(str(Path.home())) is None

    # 2. Hex fragments & 1-char slugs rejected
    assert normalize_project_slug("b") is None
    assert normalize_project_slug("2f5") is None
    assert normalize_project_slug("2f56fc3b-0e") is None

    # 3. Git worktree pointer `.git` file resolves to parent main repo name
    main_repo = tmp_path / "record-for-agent"
    (main_repo / ".git" / "worktrees" / "rfa-build89").mkdir(parents=True)
    wt_dir = tmp_path / "rfa-build89"
    wt_dir.mkdir()
    (wt_dir / ".git").write_text(
        f"gitdir: {main_repo / '.git' / 'worktrees' / 'rfa-build89'}\n",
        encoding="utf-8",
    )
    assert project_from_path(str(wt_dir)) == "record-for-agent"

    # 4. Exact aliases + regex patterns in project_aliases.json
    alias_file = tmp_path / "project_aliases.json"
    alias_file.write_text(
        json.dumps(
            {
                "aliases": {
                    "手表录音-app": "record-for-agent",
                    "clipcontext": "clip-for-agent",
                    "context": "raw-memory",
                },
                "patterns": [
                    {"match": r"^record-for-agent-.+$", "target": "record-for-agent"},
                    {"match": r"^rfa\d*-.+$", "target": "record-for-agent"},
                ],
            }
        ),
        encoding="utf-8",
    )
    resolver = ProjectResolver(alias_file)
    assert resolver.apply_alias("手表录音-app") == "record-for-agent"
    assert resolver.apply_alias("rfa89-cloud") == "record-for-agent"
    assert resolver.apply_alias("record-for-agent-p60-bg-progress-20261103") == "record-for-agent"
    assert resolver.apply_alias("clipcontext") == "clip-for-agent"
    assert resolver.apply_alias("context") == "raw-memory"


def test_store_reconcile_projects_merges_fragmented_slugs(tmp_path: Path) -> None:
    hub_dir = tmp_path / "hub"
    hub_dir.mkdir()
    (hub_dir / "project_aliases.json").write_text(
        json.dumps(
            {
                "aliases": {"手表录音-app": "record-for-agent", "context": "raw-memory"},
                "patterns": [{"match": r"^rfa\d*-.+$", "target": "record-for-agent"}],
            }
        ),
        encoding="utf-8",
    )
    store = HubStore(hub_dir)
    t0 = 1_763_950_000_000

    # Simulate historical rows stored BEFORE aliases were added
    store.ingest_event(
        RawEventIn(
            id="ev_p1",
            source="ai_chat",
            kind="chat_turn",
            t_start=t0,
            t_end=t0 + 1000,
            actor="self",
            project="rfa-build88",
            content={"role": "user", "title": "Watch", "text": "优化手表录音启动延迟"},
            context={"provider": "codex", "session_id": "s1", "cwd": "/tmp/rfa-build88"},
            provenance={"connector": "chat-history/codex", "source_id": "s1:1"},
        ),
        write_l0=False,
        sync_md=False,
    )
    # Manually corrupt stored project to simulate pre-fix DB state
    with store._tx(True) as conn:
        conn.execute("UPDATE raw_events SET project = 'rfa-build88' WHERE id = 'ev_p1'")
        conn.execute("UPDATE episodes SET project = 'rfa-build88'")

    summary = store.reconcile_projects()
    assert summary["raw_events_updated"] == 1
    assert summary["episodes_updated"] == 1
    assert store.get_raw("ev_p1")["project"] == "record-for-agent"


def test_compression_fidelity_catches_unsupported_claims_and_omissions(tmp_path: Path) -> None:
    hub_dir = tmp_path / "fidelity_hub"
    store = HubStore(hub_dir)
    t0 = 1_763_960_000_000

    store.ingest_event(
        RawEventIn(
            id="ev_f1",
            source="ai_chat",
            kind="chat_turn",
            t_start=t0,
            t_end=t0 + 1000,
            actor="self",
            project="raw-memory",
            content={
                "role": "user",
                "title": "Rename",
                "text": "把后端引擎改叫 Raw Memory，优先用 rawmemory.app，Build 154 继续保留。",
            },
            context={"provider": "antigravity", "session_id": "sf1", "signal_hints": ["user_decision"]},
            provenance={"connector": "chat-history/antigravity", "source_id": "sf1:1"},
        ),
        write_l0=False,
        sync_md=False,
    )
    store.ingest_event(
        RawEventIn(
            id="ev_f2",
            source="ai_chat",
            kind="chat_turn",
            t_start=t0 + 20_000,
            t_end=t0 + 21_000,
            actor="self",
            project="raw-memory",
            content={
                "role": "user",
                "title": "Forgotten correction",
                "text": "别用 MongoDB，以后严禁在本地引擎里引入 Docker 容器依赖。",
            },
            context={"provider": "antigravity", "session_id": "sf1", "signal_hints": ["user_correction"]},
            provenance={"connector": "chat-history/antigravity", "source_id": "sf1:2"},
        ),
        write_l0=False,
        sync_md=False,
    )

    q = store.get_curation_queue(limit=5)
    ep_id = q["items"][0]["episode"]["id"]
    store.commit_curation_batch(
        CurationBatchIn(
            curator_agent="antigravity",
            episodes=[
                EpisodeCurationIn(
                    episode_id=ep_id,
                    title="引擎更名为 Raw Memory",
                    summary="正式更名为 Raw Memory 并启用 rawmemory.app。",
                    overview="启用 rawmemory.app。",
                    project="raw-memory",
                    entities=["Raw Memory", "rawmemory.app"],
                    evidence_ids=["ev_f1"],
                )
            ],
            decisions=[
                # Accurate decision: 100% supported claims
                DecisionCurationIn(
                    project="raw-memory",
                    topic="engine_brand",
                    statement="后端引擎正式命名为 Raw Memory，启用 rawmemory.app（保留 Build 154）",
                    authority="user_confirmed",
                    valid_at=t0 + 5000,
                    evidence_ids=["ev_f1"],
                ),
                # Distorted decision: hallucinates "Build 999" & "PostgreSQL" not in ev_f1!
                DecisionCurationIn(
                    project="raw-memory",
                    topic="hallucinated_claim",
                    statement="升级到 Build 999 并迁移到 PostgreSQL 数据库",
                    authority="user_confirmed",
                    valid_at=t0 + 6000,
                    evidence_ids=["ev_f1"],
                ),
            ],
            memories=[
                MemoryCurationIn(
                    title="域名规划",
                    body="优先启用 rawmemory.app。",
                    kind="preference",
                    project="raw-memory",
                    evidence_ids=["ev_f1"],
                )
            ],
        )
    )

    rep = inspect_compression_fidelity(hub_dir, include_quotes=True)
    by_topic = {it.topic_or_title: it for it in rep.items}
    # Accurate item -> 100% claim support
    assert by_topic["engine_brand"].claim_support_rate == 1.0
    assert by_topic["engine_brand"].unsupported_claims == []
    # Hallucinated item -> caught!
    assert by_topic["hallucinated_claim"].claim_support_rate < 1.0
    assert "999" in by_topic["hallucinated_claim"].unsupported_claims
    assert "PostgreSQL" in by_topic["hallucinated_claim"].unsupported_claims
    # Omitted user_correction turn ev_f2 -> caught!
    assert len(rep.episode_omissions) == 1
    omitted_ids = [t["raw_id"] for t in rep.episode_omissions[0].omitted_turns]
    assert "ev_f2" in omitted_ids
