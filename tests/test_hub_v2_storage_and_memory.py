"""Tests for unified L0.5 blob tiering, multi-chunk FTS5, project resolution, and L2 Memory artifacts."""

from __future__ import annotations

from pathlib import Path

from context_hub.models import CurationBatchIn, MemoryCurationIn, RawEventIn
from context_hub.store import HubStore


def test_large_payload_blob_tiering_chunked_fts5_and_paginated_expand(tmp_path: Path) -> None:
    store = HubStore(tmp_path)
    prefix = "前言段落：这是一份关于个人上下文操作系统的长篇会议逐字稿。\n\n" * 160  # > 5,000 chars
    needle = "唯一深埋结论：采用星尘灰九号作为内容寻址校验标记。"
    suffix = "\n\n后续讨论：确认本地优先与离线队列稳定性。" * 80
    huge_text = prefix + needle + suffix
    assert len(huge_text) > 6000

    res = store.ingest_event(
        RawEventIn(
            id="ev_long_meeting_01",
            source="voice",
            kind="transcript_segment",
            t_start=1_763_700_000_000,
            t_end=1_763_701_800_000,
            device_id="mac-studio",
            project="context-os",
            content={"title": "架构深聊长录音", "text": huge_text},
            provenance={"connector": "record-for-agent", "source_id": "rec-long-1"},
            privacy={"tier": "shareable"},
        )
    )
    ev = res["event"]
    assert ev["body_blob_sha256"] is not None
    assert ev["body_truncated"] is True
    assert ev["body_char_len"] == len(huge_text)
    assert len(ev["body_text"]) <= 4096

    # Multi-chunk FTS5 must find the needle buried past char 5,000 without duplicating raw_id
    hits = store.list_raw(q="星尘灰九号", agent=True)
    assert [h["id"] for h in hits] == ["ev_long_meeting_01"]

    # Paginated content read recovers full verbatim payload
    page1 = store.get_raw_content("ev_long_meeting_01", offset=0, limit=3000, agent=True)
    assert page1["storage"] == "blob"
    assert page1["has_more"] is True
    assembled = page1["text"]
    next_off = page1["next_offset"]
    while next_off is not None:
        nxt = store.get_raw_content("ev_long_meeting_01", offset=next_off, limit=3000, agent=True)
        assembled += nxt["text"]
        next_off = nxt["next_offset"]
    assert assembled == huge_text

    # Expand with level="raw" attaches blob page
    expanded = store.expand("ev_long_meeting_01", level="raw", offset=0, limit=1500, agent=True)
    assert expanded["record"]["full_content"]["total_chars"] == len(huge_text)
    assert expanded["record"]["full_content"]["has_more"] is True

    # L0 rebuild preserves blob & deep searchability
    rebuilt = store.rebuild_from_l0()
    assert rebuilt["replayed_raw_events"] == 1
    assert [h["id"] for h in store.list_raw(q="星尘灰九号", agent=True)] == ["ev_long_meeting_01"]


def test_human_readable_project_resolution_and_cross_channel_inference(tmp_path: Path) -> None:
    store = HubStore(tmp_path)
    t0 = 1_763_710_000_000

    # AI chat with messy cwd path & opaque legacy workspace hash -> resolves clean repo slug
    chat_res = store.ingest_event(
        RawEventIn(
            id="ev_chat_proj",
            source="ai_chat",
            kind="chat_turn",
            t_start=t0,
            device_id="mbp-16",
            project="workspace/11111111-2222-3333-4444-555555555555",
            content={"text": "Reviewing storage layout"},
            context={"cwd": "/Users/dev/work/my-awesome-repo/packages/hub"},
            provenance={"connector": "chat-history/codex", "source_id": "s1:m1"},
            privacy={"tier": "shareable"},
        )
    )
    assert chat_res["event"]["project"] == "hub" or chat_res["event"]["project"] == "my-awesome-repo"

    # Explicit GitHub URL event without cwd -> resolves repo name
    web_res = store.ingest_event(
        RawEventIn(
            id="ev_web_proj",
            source="browser",
            kind="page_read",
            t_start=t0 + 60_000,
            device_id="mbp-16",
            content={
                "title": "PR #12",
                "url": "https://github.com/BENZEMA216/context-instrumentality-project/issues/1",
                "text": "Reviewing issue",
            },
            provenance={"connector": "browser-mv3", "source_id": "web-1"},
            privacy={"tier": "shareable"},
        )
    )
    assert web_res["event"]["project"] == "context-instrumentality-project"

    # Unattributed clipboard copy 2 minutes later on same device inherits project automatically
    clip_res = store.ingest_event(
        RawEventIn(
            id="ev_clip_inferred",
            source="clipboard",
            kind="copy",
            t_start=t0 + 120_000,
            device_id="mbp-16",
            content={"text": "uv run pytest -v"},
            provenance={"connector": "clipcontext", "source_id": "clip-1"},
            privacy={"tier": "shareable"},
        )
    )
    assert clip_res["event"]["project"] == "context-instrumentality-project"
    assert clip_res["event"]["context"].get("project_inferred") is True


def test_memory_intermediate_artifacts_and_context_pack(tmp_path: Path) -> None:
    store = HubStore(tmp_path)
    t0 = 1_763_720_000_000
    store.ingest_event(
        RawEventIn(
            id="ev_pref_01",
            source="ai_chat",
            kind="chat_turn",
            t_start=t0,
            project="context-os",
            content={"text": "以后所有代码回复都保持简洁中文，且优先给本地深度链接。"},
            provenance={"connector": "chat-history/antigravity", "source_id": "ag:1"},
            privacy={"tier": "shareable"},
        )
    )
    store.commit_curation_batch(
        CurationBatchIn(
            curator_agent="antigravity",
            decisions=[
                {
                    "project": "context-os",
                    "topic": "用户体验入口",
                    "statement": "核心入口为桌面客户端 + 根植于 Agent 的插件（对话中直达网页视图）。",
                    "authority": "user_confirmed",
                    "evidence_ids": ["ev_pref_01"],
                }
            ],
            memories=[
                {
                    "title": "回复风格偏好",
                    "body": "保持简洁中文，并附上可点击的本地 Workbench 深度链接。",
                    "kind": "preference",
                    "tags": ["style", "ux"],
                    "evidence_ids": ["ev_pref_01"],
                }
            ],
        )
    )
    store.save_manual_memory(
        MemoryCurationIn(
            title="绝对禁止把 SQLite 放进 iCloud Drive",
            body="所有实时索引和 WAL 文件必须在非 iCloud 的本地磁盘目录运行。",
            kind="manual",
            project="context-os",
            evidence_ids=["ev_pref_01"],
        )
    )

    # Verify L2 Markdown intermediate artifacts were materialized automatically
    mem_index = store.markdown.read_file("MEMORY.md")
    assert "context-os" in mem_index
    assert "用户体验入口" in mem_index
    prefs_md = store.markdown.read_file("memories/preferences.md")
    assert "回复风格偏好" in prefs_md
    manual_md = store.markdown.read_file("memories/manual.md")
    assert "绝对禁止把 SQLite 放进 iCloud Drive" in manual_md

    # Verify Agent Context Pack output & deep links
    pack = store.get_context_pack(
        project="context-os",
        query="入口",
        max_tokens=1800,
        agent=True,
        workbench_base_url="http://127.0.0.1:8741",
    )
    assert pack["content_is_untrusted_data"] is True
    assert len(pack["active_decisions"]) == 1
    assert len(pack["memories"]) >= 2
    assert pack["approx_tokens"] <= 1800
    assert pack["workbench_urls"]["project"] == "http://127.0.0.1:8741/#/projects/context-os"
    assert pack["workbench_urls"]["memory_index"] == "http://127.0.0.1:8741/#/artifacts/MEMORY.md"
    assert "## Active Decisions" in pack["rendered_markdown"]


def test_cjk_adjacent_urls_with_ports_never_crash_ingestion(tmp_path: Path) -> None:
    store = HubStore(tmp_path)
    res = store.ingest_event(
        RawEventIn(
            source="clipboard",
            kind="copy",
            t_start=1_763_730_000_000,
            content={
                "text": "打开 `http://localhost:5173`。以及 http://127.0.0.1:3000（由 Vite 启动）和 http://bad:notaport/x"
            },
            provenance={"connector": "clipcontext", "source_id": "cjk-url-1"},
            privacy={"tier": "shareable"},
        )
    )
    anchors = res["event"]["anchors"]
    assert "url:https://localhost:5173/" in anchors
    assert "url:https://127.0.0.1:3000/" in anchors
