"""Reflexive Session Memory tests: No-Echo/Anti-Loop filtering, signal hints, subagents, scalability & CLI."""

from __future__ import annotations

import json
import os
import sqlite3
import time
from pathlib import Path
from typing import Any

import pytest

from context_collectors.ai_chat import (
    AIChatCollector,
    AIChatPaths,
    extract_signal_hints,
    sanitize_turn_text,
)
from context_collectors.ai_chat.parsers import (
    make_chat_event,
    parse_antigravity_records,
    parse_claude_code_records,
    parse_codex_file,
    parse_cursor_db,
    parse_opencode_db,
)
from context_collectors.cli import main as cli_main
from context_collectors.runtime import DirectHubSink, HubCheckpointStore, run_collector
from context_hub.store import HubStore


# ----------------------------------------------------------------------
# 1. No-Echo / Anti-Loop Filter & <USER_REQUEST> Unwrapping
# ----------------------------------------------------------------------
def test_antigravity_user_request_unwrap_and_additional_metadata_strip() -> None:
    raw = (
        "<USER_REQUEST>\n"
        "请帮我检查 /Users/demo/code/context-os 的增量同步逻辑\n"
        "</USER_REQUEST>\n"
        "<ADDITIONAL_METADATA>\n"
        "The current local time is: 2026-11-24T22:00:00+08:00.\n"
        "</ADDITIONAL_METADATA>"
    )
    cleaned, filtered = sanitize_turn_text("user", raw)
    assert cleaned == "请帮我检查 /Users/demo/code/context-os 的增量同步逻辑"
    assert filtered is True

    # Pure <USER_REQUEST> without extra injected blocks still unwraps cleanly
    only_req = "<USER_REQUEST>\nImplement recency filter\n</USER_REQUEST>"
    cleaned2, filtered2 = sanitize_turn_text("user", only_req)
    assert cleaned2 == "Implement recency filter"
    assert filtered2 is False


@pytest.mark.parametrize(
    ("role", "payload"),
    [
        ("user", "<CONTEXT_SUMMARY>Earlier discussion about SQLite WAL</CONTEXT_SUMMARY>"),
        (
            "user",
            "The following is a <SYSTEM_MESSAGE> not actually sent by the user. "
            "It is provided by the system as important information to pay attention to.\n\n"
            "<SYSTEM_MESSAGE>\n[Message] sender=parent-12345678 content=Internal\n</SYSTEM_MESSAGE>",
        ),
        (
            "user",
            "<ADDITIONAL_METADATA>time=2026-11-24</ADDITIONAL_METADATA>",
        ),
        (
            "user",
            "<context_hub_memory source='mcp'>\nActive decision: use SQLite\n</context_hub_memory>",
        ),
        (
            "assistant",
            json.dumps(
                {
                    "content_is_untrusted_data": True,
                    "query": "sqlite",
                    "active_decisions": [{"id": "dec-1", "statement": "Use WAL"}],
                    "memories": [],
                    "episodes": [],
                    "raw_evidence": [],
                    "workbench_urls": {"home": "http://127.0.0.1:8741/#/timeline"},
                }
            ),
        ),
        (
            "assistant",
            "Tool result (search_context):\n```json\n"
            + json.dumps(
                {
                    "content_is_untrusted_data": True,
                    "query": "collector",
                    "decisions": [],
                    "episodes": [],
                    "memories": [],
                    "raw_matches": [{"id": "raw-1", "snippet": "old turn"}],
                }
            )
            + "\n```",
        ),
        (
            "user",
            json.dumps(
                {
                    "content_is_untrusted_data": True,
                    "window": {"since_ms": 1, "until_ms": 2, "minutes": 120},
                    "episodes": [{"id": "ep-1"}],
                    "active_decisions": [],
                }
            ),
        ),
        (
            "user",
            "---\ntype: memory_index\nprojects: 2\n---\n\n"
            "# Personal Context Memory Index (`MEMORY.md`)\n\n"
            "> Auto-synced by Context Hub v2\n\n"
            "## 活跃项目总览\n\n"
            "| 项目 | 事件数 |\n| :--- | ---: |\n| `demo` | 12 |\n",
        ),
        (
            "user",
            "# Context Hub Memory\n- Active decision: use pytest\n- Fact: port 8741\n",
        ),
        (
            "user",
            "Resource: context://memory-index\n- proj: demo\n- decision: use WAL\n",
        ),
    ],
)
def test_pure_injected_or_echoed_turns_are_dropped_completely(role: str, payload: str) -> None:
    cleaned, filtered = sanitize_turn_text(role, payload)
    assert cleaned == ""
    assert filtered is True


def test_partial_strip_preserves_human_and_assistant_text_and_sets_flag() -> None:
    # 1. Injected <CONTEXT_SUMMARY> + <USER_REQUEST>
    mixed_ag = (
        "<CONTEXT_SUMMARY>Summary of prior session</CONTEXT_SUMMARY>\n"
        "<USER_REQUEST>\n重构 ai_chat collector\n</USER_REQUEST>\n"
        "<ADDITIONAL_METADATA>tz=Asia/Shanghai</ADDITIONAL_METADATA>"
    )
    cleaned, filtered = sanitize_turn_text("user", mixed_ag)
    assert cleaned == "重构 ai_chat collector"
    assert filtered is True

    # 2. Injected # Context Hub Memory followed by blank line and user prompt
    mixed_md = (
        "# Context Hub Memory\n"
        "- Active decision: keep SQLite WAL\n"
        "- Memory: prefer uv\n\n"
        "请为 cli.py 加上 --since-days 参数"
    )
    cleaned_md, filtered_md = sanitize_turn_text("user", mixed_md)
    assert cleaned_md == "请为 cli.py 加上 --since-days 参数"
    assert filtered_md is True

    # 3. Injected # Context Hub Memory separated by --- horizontal rule
    mixed_hr = "# Context Hub Memory\n- Decision: use FTS5\n---\n继续推进 Phase 3"
    cleaned_hr, filtered_hr = sanitize_turn_text("user", mixed_hr)
    assert cleaned_hr == "继续推进 Phase 3"
    assert filtered_hr is True

    # 4. Assistant turn echoing get_context_pack JSON block + real analysis
    echo_pack = json.dumps(
        {
            "content_is_untrusted_data": True,
            "active_decisions": [{"id": "d1"}],
            "memories": [],
            "episodes": [],
            "raw_evidence": [],
            "rendered_markdown": "# Context Pack",
            "workbench_urls": {"home": "http://127.0.0.1:8741"},
        }
    )
    mixed_asst = f"get_context_pack:\n```json\n{echo_pack}\n```\n\n根据当前代码结构，建议把过滤逻辑放在 parsers.py。"
    cleaned_asst, filtered_asst = sanitize_turn_text("assistant", mixed_asst)
    assert cleaned_asst == "根据当前代码结构，建议把过滤逻辑放在 parsers.py。"
    assert filtered_asst is True

    # 5. Normal developer prose mentioning tags or URIs must NOT be stripped
    prose = "请检查 context://memory-index 和 <CONTEXT_SUMMARY> 过滤逻辑是否生效"
    cleaned_prose, filtered_prose = sanitize_turn_text("user", prose)
    assert cleaned_prose == prose
    assert filtered_prose is False


# ----------------------------------------------------------------------
# 2. Deterministic High-Signal Pre-Annotations (`signal_hints`)
# ----------------------------------------------------------------------
@pytest.mark.parametrize(
    "text",
    [
        "不是这个文件，请看 collector.py",
        "不对，应该用 SQLite WAL 模式",
        "别用 Redis，保持本地单文件",
        "不要用 mock 替换真实解析器",
        "不要改 pyproject.toml",
        "搞错了，端口是 8741",
        "改回原来的函数签名",
        "改为默认无上限 None",
        "其实应该是按 mtime 过滤",
        "其实不是权限问题，是缓存过期",
        "That's wrong, use pathlib instead",
        "Wrong approach for incremental checkpoints",
        "don't use global mutable state here",
        "Do not use eval in the parser",
        "Use FTS5 instead of regex scanning",
        "Actually it's stored under state.vscdb",
        "Please revert that commit",
        "Rollback the migration immediately",
        "No, use pytest for this suite",
    ],
)
def test_signal_hints_user_correction(text: str) -> None:
    hints = extract_signal_hints("user", text)
    assert "user_correction" in hints
    assert "verified_outcome" not in hints


@pytest.mark.parametrize(
    "text",
    [
        "就用这个方案实现吧",
        "就按你刚才列的 4 步推进",
        "那就叫 reflexive_filtered",
        "定了，默认不限制文件数",
        "我拍板了，主库坚持 SQLite",
        "统一叫 context-hub-v2",
        "确认用 --since-days 14 做验证",
        "Let's go with option B",
        "Approved, please proceed",
        "Confirmed for production rollout",
        "LGTM, ship it!",
    ],
)
def test_signal_hints_user_decision(text: str) -> None:
    hints = extract_signal_hints("user", text)
    assert "user_decision" in hints
    assert "verified_outcome" not in hints


def test_signal_hints_precision_guards_and_combined_cues() -> None:
    # Debugging question must not false-positive as a correction
    assert extract_signal_hints("user", "What is wrong with this failing test?") == []
    # Neutral chat produces no hints
    assert extract_signal_hints("user", "帮我看一下 parsers.py 有多少行") == []
    assert extract_signal_hints("assistant", "好的，我先读取文件结构。") == []
    # Combined correction + decision produces both in deterministic order
    assert extract_signal_hints("user", "不对，别用 Postgres，就用 SQLite，定了") == [
        "user_correction",
        "user_decision",
    ]


@pytest.mark.parametrize(
    "text",
    [
        "Ran pytest: 24 passed in 1.42s and ruff All checks passed.",
        "xcodebuild finished with BUILD SUCCEEDED.",
        "所有 18 项测试全部通过，构建成功。",
        "Committed abc1234 and pushed to origin main.",
        "已写入 `packages/collectors/src/context_collectors/ai_chat/parsers.py` 并验证通过。",
    ],
)
def test_signal_hints_verified_outcome_and_actor_separation(text: str) -> None:
    ev = make_chat_event(
        provider="codex",
        session_id="sess-1",
        message_id="m-1",
        role="assistant",
        text=text,
        timestamp_ms=1_763_900_000_000,
    )
    assert ev.actor == "codex"
    assert ev.actor != "self"
    assert ev.context.get("signal_hints") == ["verified_outcome"]

    # Failing test runs must NOT be marked verified_outcome
    assert extract_signal_hints("assistant", "pytest finished: 10 passed, 2 failed") == []
    assert extract_signal_hints("assistant", "pytest finished: 0 passed, 3 failed") == []
    # Assistant never gets user_correction / user_decision
    assert extract_signal_hints("assistant", "不对，别用这个，就用方案 A") == []
    # Step metadata can also report verified written artifacts
    assert extract_signal_hints("assistant", "Done.", step_meta={"written_files": ["a.py"]}) == [
        "verified_outcome"
    ]


# ----------------------------------------------------------------------
# 3. Provider Real-World Edge Cases & Subagent Metadata
# ----------------------------------------------------------------------
def test_antigravity_subagent_detection_and_main_session_distinction(tmp_path: Path) -> None:
    # Subagent transcript starts with SYSTEM_MESSAGE carrying sender=<parent_id>, no USER_INPUT
    sub_records = [
        (
            1,
            {
                "step_index": 0,
                "source": "SYSTEM",
                "type": "SYSTEM_MESSAGE",
                "created_at": "2026-11-24T10:00:00Z",
                "content": "[Message] timestamp=2026-11-24T10:00:00Z sender=parent-conv-9999 content=Do work",
            },
        ),
        (
            2,
            {
                "step_index": 1,
                "source": "MODEL",
                "type": "PLANNER_RESPONSE",
                "created_at": "2026-11-24T10:00:10Z",
                "content": "Completed implementation. 12 passed in 0.8s.",
                "tool_calls": [
                    {"name": "edit_file", "arguments": {"Path": "/Users/demo/code/context-os/a.py"}}
                ],
            },
        ),
    ]
    sub_events, sub_state = parse_antigravity_records(
        sub_records, conversation_id="sub-conv-1", path=tmp_path / "transcript.jsonl"
    )
    assert len(sub_events) == 1
    ev = sub_events[0]
    assert ev.actor == "antigravity"
    assert ev.context["is_subagent"] is True
    assert ev.context["origin"] == "subagent"
    assert ev.context["parent_session_id"] == "parent-conv-9999"
    assert ev.context["turn_index"] == 0
    assert ev.context["source_order"] == 1
    assert ev.context["signal_hints"] == ["verified_outcome"]
    assert sub_state["is_subagent"] is True

    # Main conversation starts with USER_INPUT, later receives SYSTEM_MESSAGE reply from subagent
    main_records = [
        (
            1,
            {
                "step_index": 0,
                "source": "USER_EXPLICIT",
                "type": "USER_INPUT",
                "created_at": "2026-11-24T10:00:00Z",
                "content": "<USER_REQUEST>\n就用 SQLite，别用 Redis\n</USER_REQUEST>\n<ADDITIONAL_METADATA>tz=UTC</ADDITIONAL_METADATA>",
            },
        ),
        (
            2,
            {
                "step_index": 1,
                "source": "SYSTEM",
                "type": "SYSTEM_MESSAGE",
                "created_at": "2026-11-24T10:00:15Z",
                "content": "[Message] sender=sub-conv-1 content=Subagent finished",
            },
        ),
        (
            3,
            {
                "step_index": 2,
                "source": "MODEL",
                "type": "PLANNER_RESPONSE",
                "created_at": "2026-11-24T10:00:20Z",
                "content": "Subagent report integrated.",
            },
        ),
    ]
    main_events, main_state = parse_antigravity_records(
        main_records, conversation_id="parent-conv-9999", path=tmp_path / "main.jsonl"
    )
    assert len(main_events) == 2
    assert main_state["is_subagent"] is False
    assert "is_subagent" not in main_events[0].context
    assert main_events[0].actor == "self"
    assert main_events[0].content["text"] == "就用 SQLite，别用 Redis"
    assert main_events[0].context["reflexive_filtered"] is True
    assert main_events[0].context["signal_hints"] == ["user_correction", "user_decision"]
    assert [e.context["turn_index"] for e in main_events] == [0, 1]


def test_codex_real_envelopes_nested_subagent_and_order(tmp_path: Path) -> None:
    sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    parent_sid = "11111111-2222-3333-4444-555555555555"
    rollout = tmp_path / f"rollout-2026-11-24-{sid}.jsonl"
    lines = [
        {
            "type": "session_meta",
            "payload": {
                "id": sid,
                "session_id": sid,
                "cwd": "/Users/demo/code/context-os",
                "thread_source": "subagent",
                "source": {
                    "subagent": {
                        "thread_spawn": {
                            "parent_thread_id": parent_sid,
                            "agent_nickname": "worker-1",
                            "depth": 1,
                        }
                    }
                },
            },
        },
        # Pure heartbeat envelope -> MUST be dropped (both user and assistant)
        {
            "type": "event_msg",
            "timestamp": "2026-11-24T09:00:00Z",
            "payload": {
                "type": "item_completed",
                "thread_id": sid,
                "item": {
                    "id": "hb-1",
                    "type": "UserMessage",
                    "content": [{"type": "text", "text": "<heartbeat>ping</heartbeat>"}],
                },
            },
        },
        {
            "type": "event_msg",
            "timestamp": "2026-11-24T09:00:01Z",
            "payload": {
                "type": "item_completed",
                "thread_id": sid,
                "item": {
                    "id": "hb-a1",
                    "type": "AgentMessage",
                    "content": [{"type": "text", "text": "<heartbeat>ok</heartbeat>"}],
                },
            },
        },
        # Pure external_codex_apps_open_page envelope -> MUST be dropped
        {
            "type": "event_msg",
            "timestamp": "2026-11-24T09:00:05Z",
            "payload": {
                "type": "item_completed",
                "thread_id": sid,
                "item": {
                    "id": "ext-1",
                    "type": "UserMessage",
                    "content": [
                        {
                            "type": "text",
                            "text": "<external_codex_apps_open_page>https://example.com</external_codex_apps_open_page>",
                        }
                    ],
                },
            },
        },
        # Partial in-app-browser-context + real human prompt -> strip block, keep prompt
        {
            "type": "event_msg",
            "timestamp": "2026-11-24T09:01:00Z",
            "payload": {
                "type": "item_completed",
                "thread_id": sid,
                "item": {
                    "id": "u-real",
                    "type": "UserMessage",
                    "content": [
                        {
                            "type": "text",
                            "text": "<in-app-browser-context>URL: http://localhost:3000</in-app-browser-context>\n不对，按钮应该右对齐",
                        }
                    ],
                },
            },
        },
        {
            "type": "event_msg",
            "timestamp": "2026-11-24T09:01:10Z",
            "payload": {
                "type": "item_completed",
                "thread_id": sid,
                "item": {
                    "id": "a-real",
                    "type": "AgentMessage",
                    "content": [{"type": "text", "text": "Updated alignment; pytest 8 passed."}],
                },
            },
        },
    ]
    rollout.write_text("\n".join(json.dumps(x) for x in lines) + "\n", encoding="utf-8")

    events = parse_codex_file(rollout)
    assert len(events) == 2
    u_ev, a_ev = events
    assert u_ev.content["text"] == "不对，按钮应该右对齐"
    assert u_ev.context["reflexive_filtered"] is True
    assert u_ev.context["is_subagent"] is True
    assert u_ev.context["parent_session_id"] == parent_sid
    assert u_ev.context["signal_hints"] == ["user_correction"]
    assert u_ev.context["turn_index"] == 0
    assert u_ev.context["source_order"] == 5
    assert a_ev.context["is_subagent"] is True
    assert a_ev.context["turn_index"] == 1
    assert a_ev.context["signal_hints"] == ["verified_outcome"]


def test_claude_code_task_notification_dropped_and_subagent_tagged(tmp_path: Path) -> None:
    sub_path = tmp_path / "proj" / "subagents" / "agent-1.jsonl"
    records = [
        (
            1,
            {
                "type": "user",
                "sessionId": "cl-parent",
                "agentId": "worker-a",
                "isSidechain": True,
                "uuid": "u-notif",
                "cwd": "/Users/demo/code/context-os",
                "timestamp": "2026-11-24T09:00:00Z",
                "message": {
                    "role": "user",
                    "content": "<task-notification><task-id>t1</task-id>done</task-notification>",
                },
            },
        ),
        (
            2,
            {
                "type": "user",
                "sessionId": "cl-parent",
                "agentId": "worker-a",
                "isSidechain": True,
                "uuid": "u-cmd",
                "timestamp": "2026-11-24T09:00:02Z",
                "message": {
                    "role": "user",
                    "content": "<local-command-stdout>ok</local-command-stdout>",
                },
            },
        ),
        (
            3,
            {
                "type": "user",
                "sessionId": "cl-parent",
                "agentId": "worker-a",
                "isSidechain": True,
                "uuid": "u-real",
                "timestamp": "2026-11-24T09:00:05Z",
                "message": {
                    "role": "user",
                    "content": [{"type": "text", "text": "Confirmed, use the new schema."}],
                },
            },
        ),
    ]
    events, state = parse_claude_code_records(records, path=sub_path)
    assert len(events) == 1
    ev = events[0]
    assert ev.context["session_id"] == "cl-parent/worker-a"
    assert ev.context["parent_session_id"] == "cl-parent"
    assert ev.context["is_subagent"] is True
    assert ev.context["origin"] == "subagent"
    assert ev.context["signal_hints"] == ["user_decision"]
    assert ev.context["turn_index"] == 0
    assert state["turn_index"] == 1


def test_cursor_and_opencode_subagent_and_echo_defenses(tmp_path: Path) -> None:
    # Cursor DB with child composer + pure echoed memory bubble + real bubble
    cursor_db = tmp_path / "cursor.vscdb"
    conn = sqlite3.connect(cursor_db)
    conn.execute("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute(
        "INSERT INTO cursorDiskKV VALUES (?, ?)",
        (
            "composerData:child-1",
            json.dumps(
                {
                    "composerId": "child-1",
                    "parentComposerId": "root-comp",
                    "workspacePath": "/Users/demo/code/context-os",
                    "fullConversationHeadersOnly": [
                        {"bubbleId": "b-echo", "type": 1},
                        {"bubbleId": "b-real", "type": 1},
                    ],
                }
            ),
        ),
    )
    conn.execute(
        "INSERT INTO cursorDiskKV VALUES (?, ?)",
        (
            "bubbleId:child-1:b-echo",
            json.dumps(
                {
                    "bubbleId": "b-echo",
                    "type": 1,
                    "text": "<context_hub_memory>Old memory</context_hub_memory>",
                    "createdAt": 1763900000000,
                }
            ),
        ),
    )
    conn.execute(
        "INSERT INTO cursorDiskKV VALUES (?, ?)",
        (
            "bubbleId:child-1:b-real",
            json.dumps(
                {
                    "bubbleId": "b-real",
                    "type": 1,
                    "text": "Let's go with SQLite",
                    "createdAt": 1763900001000,
                }
            ),
        ),
    )
    conn.commit()
    conn.close()

    c_events, _ = parse_cursor_db(cursor_db)
    assert len(c_events) == 1
    assert c_events[0].context["is_subagent"] is True
    assert c_events[0].context["parent_session_id"] == "root-comp"
    assert c_events[0].context["signal_hints"] == ["user_decision"]

    # OpenCode DB with child session + turn_index
    oc_db = tmp_path / "opencode.db"
    oconn = sqlite3.connect(oc_db)
    oconn.execute("CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, directory TEXT, parent_id TEXT)")
    oconn.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
    oconn.execute("CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT, message_id TEXT, time_created INTEGER, data TEXT)")
    oconn.execute("INSERT INTO session VALUES ('oc-sub', 'p1', '/Users/demo/code/context-os', 'oc-root')")
    oconn.execute(
        "INSERT INTO message VALUES ('m1', 'oc-sub', 1763900005000, ?)",
        (json.dumps({"role": "assistant", "time": {"created": 1763900005000}}),),
    )
    oconn.execute(
        "INSERT INTO part VALUES ('p1', 'oc-sub', 'm1', 1763900005000, ?)",
        (json.dumps({"type": "text", "text": "All checks passed and 5 passed in pytest."}),),
    )
    oconn.commit()
    oconn.close()

    oc_events, _ = parse_opencode_db(oc_db)
    assert len(oc_events) == 1
    assert oc_events[0].context["is_subagent"] is True
    assert oc_events[0].context["parent_session_id"] == "oc-root"
    assert oc_events[0].context["turn_index"] == 0
    assert oc_events[0].context["signal_hints"] == ["verified_outcome"]


# ----------------------------------------------------------------------
# 4. Scalability (Unlimited Default >400 Files, since_days, Multi-batch, CLI)
# ----------------------------------------------------------------------
def _write_codex_rollout(path: Path, uuid_hex: str, text: str, mtime: float) -> None:
    lines = [
        {
            "type": "session_meta",
            "payload": {"id": uuid_hex, "cwd": "/Users/demo/code/context-os", "source": "cli"},
        },
        {
            "type": "event_msg",
            "timestamp": "2026-11-24T08:00:00Z",
            "payload": {
                "type": "item_completed",
                "thread_id": uuid_hex,
                "item": {
                    "id": "u1",
                    "type": "UserMessage",
                    "content": [{"type": "text", "text": text}],
                },
            },
        },
    ]
    path.write_text("\n".join(json.dumps(x) for x in lines) + "\n", encoding="utf-8")
    os.utime(path, (mtime, mtime))


def test_unlimited_discovery_above_400_since_days_and_honest_doctor(tmp_path: Path) -> None:
    codex_dir = tmp_path / "codex"
    codex_dir.mkdir()
    qclaw_dir = tmp_path / "qclaw"
    qclaw_dir.mkdir()
    # Top-level QClaw file to verify overlapping glob patterns are never double-counted
    (qclaw_dir / "top.jsonl").write_text(
        json.dumps({"type": "session", "id": "qc-1", "cwd": "/Users/demo/code/context-os"})
        + "\n"
        + json.dumps(
            {
                "type": "message",
                "id": "m-1",
                "timestamp": "2026-11-24T08:00:00Z",
                "message": {"role": "user", "content": "Hello QClaw"},
            }
        )
        + "\n",
        encoding="utf-8",
    )

    now = time.time()
    recent_count = 15
    old_count = 405  # Total = 420 > old 400 hard cap!
    for i in range(recent_count + old_count):
        uid = f"00000000-0000-4000-8000-{i:012d}"
        mtime = (now - 3600) if i < recent_count else (now - 30 * 86400)
        _write_codex_rollout(codex_dir / f"rollout-{uid}.jsonl", uid, f"turn {i}", mtime)

    paths = AIChatPaths(
        codex_sessions=codex_dir,
        qclaw_dir=qclaw_dir,
        enabled_providers={"codex", "qclaw"},
    )

    # Default collector has max_files_per_provider=None -> discovers all 420 Codex files!
    col_all = AIChatCollector(paths)
    assert col_all.max_files_per_provider is None
    doc_all = col_all.doctor()
    assert doc_all["providers"]["codex"]["files"] == 420
    assert doc_all["providers"]["codex"]["total_files"] == 420
    assert doc_all["providers"]["qclaw"]["files"] == 1
    assert doc_all["providers"]["qclaw"]["total_files"] == 1

    # Recency-scoped collector (since_days=7) reports honest total_files=420 and filtered files=15
    col_recent = AIChatCollector(paths, since_days=7.0)
    doc_recent = col_recent.doctor()
    assert doc_recent["providers"]["codex"]["total_files"] == 420
    assert doc_recent["providers"]["codex"]["files"] == recent_count

    store = HubStore(tmp_path / "hub-recent")
    sink = DirectHubSink(store)
    cp = HubCheckpointStore(store)
    rep1 = run_collector(col_recent, sink, cp)
    assert rep1.status == "ok"
    assert rep1.created == recent_count + 1  # 15 recent Codex + 1 QClaw

    # Second run is O(1) idempotent
    rep2 = run_collector(col_recent, sink, cp)
    assert rep2.created == 0
    assert rep2.sources_unchanged == rep2.sources_scanned

    # Explicit max_files_per_provider still respected while doctor keeps honest total_files
    col_capped = AIChatCollector(paths, max_files_per_provider=5)
    doc_capped = col_capped.doctor()
    assert doc_capped["providers"]["codex"]["total_files"] == 420
    assert doc_capped["providers"]["codex"]["files"] == 5


def test_multibatch_large_jsonl_drains_in_single_sync_pass(tmp_path: Path) -> None:
    ag_root = tmp_path / "ag"
    transcript = ag_root / "big-conv" / ".system_generated" / "logs" / "transcript.jsonl"
    transcript.parent.mkdir(parents=True)
    # 5,100 lines (> read_incremental_jsonl default max_lines=5000), with visible turns at start & end
    lines: list[str] = [
        json.dumps(
            {
                "step_index": 0,
                "source": "USER_EXPLICIT",
                "type": "USER_INPUT",
                "created_at": "2026-11-24T08:00:00Z",
                "content": "<USER_REQUEST>start turn</USER_REQUEST>",
            }
        )
    ]
    for i in range(1, 5099):
        lines.append(
            json.dumps(
                {
                    "step_index": i,
                    "source": "MODEL",
                    "type": "GENERIC",
                    "created_at": "2026-11-24T08:00:01Z",
                    "content": "tool noise",
                }
            )
        )
    lines.append(
        json.dumps(
            {
                "step_index": 5099,
                "source": "MODEL",
                "type": "PLANNER_RESPONSE",
                "created_at": "2026-11-24T08:05:00Z",
                "content": "Finished all work. 10 passed.",
            }
        )
    )
    transcript.write_text("\n".join(lines) + "\n", encoding="utf-8")

    store = HubStore(tmp_path / "hub")
    col = AIChatCollector(
        AIChatPaths(antigravity_brain=ag_root, enabled_providers={"antigravity"})
    )
    rep1 = run_collector(col, DirectHubSink(store), HubCheckpointStore(store))
    assert rep1.created == 2
    rep2 = run_collector(col, DirectHubSink(store), HubCheckpointStore(store))
    assert rep2.created == 0
    assert rep2.sources_unchanged == 1


def test_cli_since_days_and_max_files_flags(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    codex_dir = tmp_path / "codex_cli"
    codex_dir.mkdir()
    now = time.time()
    for i in range(6):
        uid = f"10000000-0000-4000-8000-{i:012d}"
        mtime = (now - 600 * i) if i < 4 else (now - 20 * 86400)
        _write_codex_rollout(codex_dir / f"rollout-{uid}.jsonl", uid, f"cli turn {i}", mtime)

    # Point all default env dirs to isolated temp dirs so we never touch live user stores
    monkeypatch.setenv("CONTEXT_CODEX_SESSIONS_DIR", str(codex_dir))
    monkeypatch.setenv("CONTEXT_ANTIGRAVITY_BRAIN_DIR", str(tmp_path / "empty_ag"))
    monkeypatch.setenv("CONTEXT_CLAUDE_PROJECTS_DIR", str(tmp_path / "empty_cl"))
    monkeypatch.setenv("CONTEXT_CURSOR_GLOBAL_DB", str(tmp_path / "missing_cursor.db"))
    monkeypatch.setenv("CONTEXT_CURSOR_WORKSPACES_DIR", str(tmp_path / "empty_cw"))
    monkeypatch.setenv("CONTEXT_OPENCODE_DB", str(tmp_path / "missing_oc.db"))
    monkeypatch.setenv("CONTEXT_WORKBUDDY_DIR", str(tmp_path / "empty_wb"))
    monkeypatch.setenv("CONTEXT_QCLAW_DIR", str(tmp_path / "empty_qc"))
    monkeypatch.setenv("CONTEXT_DEEPSEEK_DIR", str(tmp_path / "empty_ds"))

    data_dir = tmp_path / "cli_hub"

    # 1. doctor with --since-days and --max-files
    rc = cli_main(
        ["--data-dir", str(data_dir), "doctor", "--collector", "ai_chat", "--since-days", "7", "--max-files", "2"]
    )
    assert rc == 0
    doc_payload: dict[str, Any] = json.loads(capsys.readouterr().out)
    ai_doc = doc_payload["collectors"][0]
    assert ai_doc["filters"] == {"since_days": 7.0, "max_files_per_provider": 2}
    assert ai_doc["providers"]["codex"]["total_files"] == 6
    assert ai_doc["providers"]["codex"]["files"] == 2

    # 2. sync with --since-days 7 (should ingest 4 recent files)
    rc_sync = cli_main(
        ["--data-dir", str(data_dir), "sync", "--collector", "ai_chat", "--since-days", "7"]
    )
    assert rc_sync == 0
    sync_payload = json.loads(capsys.readouterr().out)
    assert sync_payload["reports"][0]["created"] == 4

    # 3. backward-compatible sync without new flags picks up the remaining 2 old files
    rc_full = cli_main(["--data-dir", str(data_dir), "sync", "--collector", "ai_chat"])
    assert rc_full == 0
    full_payload = json.loads(capsys.readouterr().out)
    assert full_payload["reports"][0]["created"] == 2
    assert full_payload["reports"][0]["sources_unchanged"] == 4
