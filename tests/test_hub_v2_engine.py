"""Core L0-L3 engine, CJK FTS5, deterministic linking, privacy, and Agent-as-Curator tests."""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from context_hub.anchors import canonicalize_url
from context_hub.models import (
    CurationBatchIn,
    MemoryCurationIn,
    PrivacyRuleIn,
    RawEventIn,
)
from context_hub.store import HubStore, HubStoreError


def _ev(
    *,
    id: str,
    source: str,
    kind: str,
    t_start: int,
    t_end: int | None = None,
    text: str = "",
    title: str = "",
    url: str | None = None,
    project: str | None = "alpha",
    device_id: str | None = "mac-1",
    actor: str = "self",
    tier: str | None = None,
) -> RawEventIn:
    content: dict = {}
    if title:
        content["title"] = title
    if text:
        content["text"] = text
    if url:
        content["url"] = url
    return RawEventIn(
        id=id,
        source=source,
        kind=kind,
        t_start=t_start,
        t_end=t_end,
        actor=actor,
        device_id=device_id,
        project=project,
        content=content,
        provenance={
            "connector": f"test-{source}",
            "source_id": f"src-{id}",
            "locator": f"test://{source}/{id}",
        },
        privacy={"tier": tier} if tier else {},
    )


def test_url_canonicalization_strips_tracking_and_secrets() -> None:
    u1 = canonicalize_url("https://www.github.com/kepano/defuddle/?utm_source=x&token=abc&b=2&a=1#sec")
    u2 = canonicalize_url("http://github.com/kepano/defuddle?a=1&b=2&fbclid=zzz")
    assert u1 == "https://github.com/kepano/defuddle?a=1&b=2"
    assert u1 == u2


def test_cross_channel_deterministic_linking_and_promnesia_related(tmp_path: Path) -> None:
    store = HubStore(tmp_path)
    t0 = 1_763_625_600_000

    store.ingest_event(
        _ev(
            id="ev_browser",
            source="browser",
            kind="page_read",
            t_start=t0,
            t_end=t0 + 180_000,
            title="Defuddle Docs",
            url="https://github.com/kepano/defuddle?utm_campaign=launch",
            text="Run uv run context-hub serve --port 8741 to launch locally.",
        )
    )
    res_clip = store.ingest_event(
        _ev(
            id="ev_clip",
            source="clipboard",
            kind="copy",
            t_start=t0 + 60_000,
            text="uv run context-hub serve --port 8741",
        )
    )
    assert res_clip["links_created"] >= 2  # copy_of + during (+ related)

    store.ingest_event(
        _ev(
            id="ev_chat",
            source="ai_chat",
            kind="chat_turn",
            t_start=t0 + 120_000,
            text="参考 https://github.com/kepano/defuddle 实现正文抽取",
        )
    )

    rel_clip = store.related(item_id="ev_clip", agent=True)
    rel_ids = {item["id"] for item in rel_clip["items"]}
    assert "ev_browser" in rel_ids

    rel_url = store.related(url="http://www.github.com/kepano/defuddle/", agent=True)
    url_ids = {item["id"] for item in rel_url["items"]}
    assert {"ev_browser", "ev_chat"}.issubset(url_ids)


def test_privacy_policy_secret_firewall_and_propagation(tmp_path: Path) -> None:
    store = HubStore(tmp_path)
    t0 = 1_763_625_600_000

    # Clipboard defaults shareable, but raw API key must be hard-locked to local_only
    secret_res = store.ingest_event(
        _ev(
            id="ev_secret",
            source="clipboard",
            kind="copy",
            t_start=t0,
            text="export OPENAI_API_KEY=sk-proj-1234567890abcdefghijklmnop",
        )
    )
    assert secret_res["event"]["privacy"]["tier"] == "local_only"
    assert "openai_key" in secret_res["event"]["privacy"]["pii_tags"]

    # Agent cannot see secret raw event
    with pytest.raises(HubStoreError) as exc:
        store.get_raw("ev_secret", agent=True)
    assert exc.value.status == 404

    # Custom project rule promotes wechat work group to shareable
    store.upsert_privacy_rule(
        PrivacyRuleIn(
            scope="project",
            match_value="work-group",
            default_tier="shareable",
            priority=10,
            description="Allow work-group WeChat for local agent",
        )
    )
    wx = store.ingest_event(
        _ev(
            id="ev_wx_work",
            source="wechat",
            kind="message",
            t_start=t0 + 1000,
            project="work-group",
            text="周五前上线 SenseVoice 离线转写",
        )
    )
    assert wx["event"]["privacy"]["tier"] == "shareable"

    # Curate a decision backed by ev_wx_work, then demote ev_wx_work to local_only
    store.commit_curation_batch(
        CurationBatchIn(
            curator_agent="antigravity",
            decisions=[
                {
                    "project": "work-group",
                    "topic": "ASR 方案",
                    "statement": "周五前上线 SenseVoice 离线转写。",
                    "authority": "user_confirmed",
                    "evidence_ids": ["ev_wx_work"],
                }
            ],
        ),
        allow_local_only=False,
    )
    assert len(store.list_decisions(project="work-group", agent=True)) == 1

    store.update_raw_privacy("ev_wx_work", "local_only")
    assert len(store.list_decisions(project="work-group", agent=True)) == 0
    assert len(store.list_decisions(project="work-group", agent=False)) == 1


def test_agent_as_curator_evidence_gate_supersession_and_markdown(tmp_path: Path) -> None:
    store = HubStore(tmp_path)
    t0 = 1_763_625_600_000

    store.ingest_event(
        _ev(
            id="ev_1",
            source="voice",
            kind="transcript_segment",
            t_start=t0,
            project="recorder",
            text="蓝鲸提议第一版先做私有云同步。",
        )
    )
    store.ingest_event(
        _ev(
            id="ev_2",
            source="ai_chat",
            kind="chat_turn",
            t_start=t0 + 60_000,
            project="recorder",
            text="确认推翻私有云方案，第一版改用 iCloud Drive 同步。",
        )
    )

    queue = store.get_curation_queue(limit=5)
    assert queue["total_pending"] == 1
    ep_id = queue["items"][0]["episode"]["id"]

    # Fabricated evidence_id MUST be rejected
    with pytest.raises(HubStoreError) as exc:
        store.commit_curation_batch(
            CurationBatchIn(
                curator_agent="codex",
                decisions=[
                    {
                        "project": "recorder",
                        "topic": "同步方式",
                        "statement": "瞎编的结论",
                        "evidence_ids": ["ev_nonexistent_999"],
                    }
                ],
            )
        )
    assert exc.value.status == 400

    # First decision (old)
    first = store.commit_curation_batch(
        CurationBatchIn(
            curator_agent="antigravity",
            decisions=[
                {
                    "project": "recorder",
                    "topic": "同步方式",
                    "statement": "先做私有云同步。",
                    "authority": "assistant_suggested",
                    "valid_at": t0,
                    "evidence_ids": ["ev_1"],
                }
            ],
        )
    )
    old_dec_id = first["committed"]["decisions"][0]

    # Supersede decision + curate episode + save memory
    second = store.commit_curation_batch(
        CurationBatchIn(
            curator_agent="antigravity",
            episodes=[
                {
                    "episode_id": ep_id,
                    "title": "录音同步方案定案：转向 iCloud",
                    "summary": "讨论后推翻私有云提议，确认首版使用 iCloud Drive。",
                    "overview": "## 结论\n首版采用 iCloud Drive 同步，避免自建运维成本。",
                    "project": "recorder",
                    "entities": ["蓝鲸", "iCloud Drive"],
                    "evidence_ids": ["ev_1", "ev_2"],
                }
            ],
            decisions=[
                {
                    "project": "recorder",
                    "topic": "同步方式",
                    "statement": "首版改用 iCloud Drive 同步。",
                    "authority": "user_confirmed",
                    "valid_at": t0 + 60_000,
                    "supersedes_decision_id": old_dec_id,
                    "evidence_ids": ["ev_2"],
                }
            ],
            memories=[
                {
                    "title": "项目成员蓝鲸偏好记录",
                    "body": "蓝鲸曾提议私有云，但最终确认转向 iCloud。",
                    "kind": "fact",
                    "project": "recorder",
                    "tags": ["sync", "icloud"],
                    "evidence_ids": ["ev_1", "ev_2"],
                }
            ],
        )
    )
    assert second["markdown_updated"]
    # Verify Markdown files exist with YAML frontmatter
    md_files = store.markdown.list_files()
    categories = {f["category"] for f in md_files}
    assert {"episodes", "projects", "daily"}.issubset(categories)

    # Verify bi-temporal state
    state = store.get_project_state("recorder", include_history=True, agent=True)
    assert len(state["active_decisions"]) == 1
    assert "iCloud Drive" in state["active_decisions"][0]["statement"]
    assert len(state["superseded_decisions"]) == 1
    assert state["superseded_decisions"][0]["superseded_by"] == state["active_decisions"][0]["id"]

    # Curation queue is now empty
    assert store.get_curation_queue()["total_pending"] == 0

    # Manual memory cannot be silently overwritten by curator
    manual = store.save_manual_memory(
        MemoryCurationIn(
            title="人工备忘",
            body="非常重要的人工定稿",
            project="recorder",
            evidence_ids=["ev_2"],
        )
    )
    with pytest.raises(HubStoreError) as exc2:
        store.commit_curation_batch(
            CurationBatchIn(
                curator_agent="codex",
                memories=[
                    {
                        "id": manual["id"],
                        "title": "被覆盖",
                        "body": "试图覆盖人工记忆",
                        "evidence_ids": ["ev_2"],
                    }
                ],
            )
        )
    assert exc2.value.status == 409


def test_cjk_fts5_search_and_l0_rebuild_with_tombstone(tmp_path: Path) -> None:
    store = HubStore(tmp_path)
    t0 = 1_763_625_600_000

    store.ingest_event(
        _ev(
            id="ev_zh_1",
            source="voice",
            kind="transcript_segment",
            t_start=t0,
            text="蓝鲸把周三的银杏收音笔评审改到九点，支持 SenseVoiceSmall。",
        )
    )
    store.ingest_event(
        _ev(
            id="ev_zh_del",
            source="clipboard",
            kind="copy",
            t_start=t0 + 1000,
            text="这条测试记录稍后会被用户彻底删除。",
        )
    )
    store.delete_raw("ev_zh_del")

    # 2-char Chinese, multi-char Chinese, and English prefix all hit via FTS5
    for query in ("蓝鲸", "收音笔", "SenseVoice", "周三 评审"):
        hits = store.search_context(query, agent=True)
        assert any(r["id"] == "ev_zh_1" for r in hits["raw_matches"]), f"Missed query: {query}"

    # Rebuild L1 from immutable L0 raw/ JSONL and verify deleted tombstone is respected
    rebuilt = store.rebuild_from_l0()
    assert rebuilt["replayed_raw_events"] == 1
    assert store.get_raw("ev_zh_1", agent=True)["id"] == "ev_zh_1"
    with pytest.raises(HubStoreError):
        store.get_raw("ev_zh_del", agent=False)


def test_fts5_performance_on_large_private_store(tmp_path: Path) -> None:
    """Regression test for Codex REC-68/REC-69: large private stores must query in milliseconds."""
    store = HubStore(tmp_path)
    t0 = 1_763_625_600_000

    # Bulk insert 2,000 local_only events + 5 shareable events
    events = [
        _ev(
            id=f"ev_priv_{i}",
            source="ai_chat",
            kind="chat_turn",
            t_start=t0 + i * 1000,
            project="private-hist",
            text=f"历史私有对话第 {i} 条，讨论普通构建与日志输出。",
            tier="local_only",
        )
        for i in range(2000)
    ]
    events.append(
        _ev(
            id="ev_pub_needle",
            source="ai_chat",
            kind="chat_turn",
            t_start=t0 + 3_000_000,
            project="public-proj",
            text="唯一公开针孔线索：采用松针蓝七号作为校验标签。",
            tier="shareable",
        )
    )
    store.ingest_batch(events, write_l0=False)

    start = time.perf_counter()
    empty_priv = store.list_raw(project="private-hist", limit=20, agent=True)
    needle = store.search_context("松针蓝七号", agent=True)
    elapsed = time.perf_counter() - start

    assert empty_priv == []
    assert [r["id"] for r in needle["raw_matches"]] == ["ev_pub_needle"]
    assert elapsed < 0.25, f"Expected <250ms, took {elapsed:.3f}s"
