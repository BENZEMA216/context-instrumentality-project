"""End-to-end tests for Phase 2 resilient collectors: runtime, AI Chat (incl. Antigravity), and ClipContext."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from context_collectors.ai_chat import AIChatCollector, AIChatPaths, parse_export_file
from context_collectors.clipcontext import ClipContextCollector
from context_collectors.runtime import (
    DirectHubSink,
    HttpHubSink,
    HubCheckpointStore,
    read_incremental_jsonl,
    run_collector,
)
from context_hub.models import RawEventIn
from context_hub.store import HubStore


def test_incremental_jsonl_partial_line_and_rotation_recovery(tmp_path: Path) -> None:
    log_file = tmp_path / "live.jsonl"
    line1 = json.dumps({"seq": 1, "text": "hello"}) + "\n"
    partial = '{"seq": 2, "text": "half-written'  # no trailing newline yet
    log_file.write_text(line1 + partial, encoding="utf-8")

    b1 = read_incremental_jsonl(log_file, None)
    assert len(b1.records) == 1
    assert b1.records[0][1]["seq"] == 1
    assert b1.next_offset == len(line1.encode("utf-8"))

    # Finish writing line 2 + add a malformed line 3 + valid line 4
    with log_file.open("a", encoding="utf-8") as fh:
        fh.write('"}\n')
        fh.write("{corrupted json line\n")
        fh.write(json.dumps({"seq": 4, "text": "after-error"}) + "\n")

    cp = {
        "inode": b1.inode,
        "file_size": b1.file_size,
        "mtime_ns": b1.mtime_ns,
        "byte_offset": b1.next_offset,
        "cursor": {"line_no": b1.next_line_no},
    }
    b2 = read_incremental_jsonl(log_file, cp)
    assert [r[1]["seq"] for r in b2.records] == [2, 4]
    assert b2.skipped_errors == 1

    # Unchanged file is skipped in O(1)
    cp2 = {
        "inode": b2.inode,
        "file_size": b2.file_size,
        "mtime_ns": b2.mtime_ns,
        "byte_offset": b2.next_offset,
        "cursor": {"line_no": b2.next_line_no},
    }
    b3 = read_incremental_jsonl(log_file, cp2)
    assert b3.unchanged is True
    assert b3.records == []

    # Truncation/rotation resets offset cleanly
    log_file.write_text(json.dumps({"seq": 99, "text": "rotated"}) + "\n", encoding="utf-8")
    b4 = read_incremental_jsonl(log_file, cp2)
    assert b4.rotated is True
    assert [r[1]["seq"] for r in b4.records] == [99]


def test_ai_chat_collector_antigravity_codex_claude_workbuddy_qclaw_cursor_opencode(
    tmp_path: Path,
) -> None:
    store = HubStore(tmp_path / "hub")
    sink = DirectHubSink(store)
    checkpoints = HubCheckpointStore(store)

    # 1. Antigravity transcript
    ag_root = tmp_path / "ag_brain"
    ag_file = ag_root / "conv-alpha-1" / ".system_generated" / "logs" / "transcript.jsonl"
    ag_file.parent.mkdir(parents=True)
    ag_lines = [
        {
            "step_index": 0,
            "source": "USER_EXPLICIT",
            "type": "USER_INPUT",
            "created_at": "2026-11-23T08:00:00Z",
            "content": "请检查 /Users/demo/code/context-os 里的架构",
        },
        {
            "step_index": 1,
            "source": "MODEL",
            "type": "PLANNER_RESPONSE",
            "created_at": "2026-11-23T08:00:05Z",
            "thinking": "internal thought",
            "tool_calls": [{"name": "read_file", "arguments": {"Path": "/Users/demo/code/context-os/README.md"}}],
        },
        {
            "step_index": 2,
            "source": "SYSTEM",
            "type": "CHECKPOINT",
            "created_at": "2026-11-23T08:00:08Z",
            "content": "checkpoint summary",
        },
        {
            "step_index": 3,
            "source": "MODEL",
            "type": "PLANNER_RESPONSE",
            "created_at": "2026-11-23T08:00:10Z",
            "content": "已检查完成，建议采用 L0.5 Blob 仓与 Memory 中间产物分层。",
        },
    ]
    ag_file.write_text("\n".join(json.dumps(x) for x in ag_lines) + "\n", encoding="utf-8")

    # 2. Codex rollout (tests wire deduplication)
    codex_dir = tmp_path / "codex"
    codex_dir.mkdir()
    codex_file = codex_dir / "rollout-11111111-2222-3333-4444-555555555555.jsonl"
    codex_lines = [
        {
            "type": "session_meta",
            "payload": {
                "id": "11111111-2222-3333-4444-555555555555",
                "cwd": "/Users/demo/code/context-os",
                "source": "cli",
            },
        },
        {
            "type": "event_msg",
            "timestamp": "2026-11-23T08:05:00Z",
            "payload": {
                "type": "item_completed",
                "thread_id": "11111111-2222-3333-4444-555555555555",
                "item": {"id": "u1", "type": "UserMessage", "content": [{"type": "text", "text": "优化 FTS5 查询"}]},
            },
        },
        {
            "type": "event_msg",
            "timestamp": "2026-11-23T08:05:00Z",
            "payload": {"type": "user_message", "id": "u1-dup", "message": "优化 FTS5 查询"},
        },
    ]
    codex_file.write_text("\n".join(json.dumps(x) for x in codex_lines) + "\n", encoding="utf-8")

    # 3. Claude Code JSONL (skips isMeta)
    claude_dir = tmp_path / "claude" / "proj1"
    claude_dir.mkdir(parents=True)
    claude_file = claude_dir / "sess1.jsonl"
    claude_lines = [
        {
            "type": "user",
            "sessionId": "cl-1",
            "uuid": "m-meta",
            "isMeta": True,
            "timestamp": "2026-11-23T08:10:00Z",
            "message": {"role": "user", "content": "hidden meta"},
        },
        {
            "type": "user",
            "sessionId": "cl-1",
            "uuid": "m-1",
            "cwd": "/Users/demo/code/context-os",
            "timestamp": "2026-11-23T08:10:01Z",
            "message": {"role": "user", "content": [{"type": "text", "text": "请帮我检查剪贴板同步稳定性"}]},
        },
    ]
    claude_file.write_text("\n".join(json.dumps(x) for x in claude_lines) + "\n", encoding="utf-8")

    # 4. WorkBuddy & QClaw JSONL (envelope unwrapping)
    wb_dir = tmp_path / "wb"
    wb_dir.mkdir()
    (wb_dir / "s1.jsonl").write_text(
        json.dumps(
            {
                "type": "message",
                "id": "wb-1",
                "sessionId": "wb-sess-1",
                "cwd": "/Users/demo/code/context-os",
                "role": "user",
                "timestamp": "2026-11-23T08:12:00Z",
                "content": [
                    {
                        "type": "input_text",
                        "text": "<system-reminder>ctx</system-reminder><user_query>整理今日会议纪要</user_query>",
                    }
                ],
            }
        )
        + "\n",
        encoding="utf-8",
    )

    qc_dir = tmp_path / "qclaw"
    qc_dir.mkdir()
    (qc_dir / "s1.jsonl").write_text(
        "\n".join(
            [
                json.dumps({"type": "session", "id": "qc-sess-1", "cwd": "/Users/demo/code/context-os"}),
                json.dumps(
                    {
                        "type": "message",
                        "id": "qc-1",
                        "timestamp": "2026-11-23T08:13:00Z",
                        "message": {
                            "role": "user",
                            "content": 'Sender (untrusted metadata):\n```json\n{"id":"u"}\n```\n请查一下最新进展',
                        },
                    }
                ),
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    # 5. Cursor SQLite DB
    cursor_db = tmp_path / "cursor_state.vscdb"
    conn = sqlite3.connect(cursor_db)
    conn.execute("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute(
        "INSERT INTO cursorDiskKV VALUES (?, ?)",
        (
            "composerData:comp-1",
            json.dumps(
                {
                    "composerId": "comp-1",
                    "workspacePath": "/Users/demo/code/context-os",
                    "fullConversationHeadersOnly": [{"bubbleId": "b1", "type": 1}],
                }
            ),
        ),
    )
    conn.execute(
        "INSERT INTO cursorDiskKV VALUES (?, ?)",
        (
            "bubbleId:comp-1:b1",
            json.dumps({"bubbleId": "b1", "type": 1, "text": "Cursor 对话测试", "createdAt": 1763885000000}),
        ),
    )
    conn.commit()
    conn.close()

    # 6. OpenCode SQLite DB
    opencode_db = tmp_path / "opencode.db"
    oconn = sqlite3.connect(opencode_db)
    oconn.execute("CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, directory TEXT, parent_id TEXT)")
    oconn.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
    oconn.execute("CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT, message_id TEXT, time_created INTEGER, data TEXT)")
    oconn.execute("INSERT INTO session VALUES ('oc-1', 'p1', '/Users/demo/code/context-os', NULL)")
    oconn.execute(
        "INSERT INTO message VALUES ('om-1', 'oc-1', 1763885100000, ?)",
        (json.dumps({"role": "user", "time": {"created": 1763885100000}}),),
    )
    oconn.execute(
        "INSERT INTO part VALUES ('op-1', 'oc-1', 'om-1', 1763885100000, ?)",
        (json.dumps({"type": "text", "text": "OpenCode 本地检索测试"}),),
    )
    oconn.commit()
    oconn.close()

    collector = AIChatCollector(
        AIChatPaths(
            antigravity_brain=ag_root,
            codex_sessions=codex_dir,
            claude_projects=claude_dir.parent,
            cursor_global_db=cursor_db,
            opencode_db=opencode_db,
            workbuddy_dir=wb_dir,
            qclaw_dir=qc_dir,
        )
    )

    rep1 = run_collector(collector, sink, checkpoints)
    assert rep1.status == "ok"
    # 2 Antigravity + 1 Codex (deduped) + 1 Claude (meta skipped) + 1 WorkBuddy + 1 QClaw + 1 Cursor + 1 OpenCode = 8
    assert rep1.created == 8
    assert rep1.skipped_errors == 0

    all_events = store.list_raw(limit=50, agent=False)
    assert len(all_events) == 8
    assert all(ev["project"] == "context-os" for ev in all_events)
    assert any(ev["body_text"] == "整理今日会议纪要" for ev in all_events)
    assert any(ev["body_text"] == "请查一下最新进展" for ev in all_events)

    # Second run with no changes -> 0 new events, all skipped via stat checkpoint
    rep2 = run_collector(collector, sink, checkpoints)
    assert rep2.created == 0
    assert rep2.sources_unchanged == rep2.sources_scanned

    # Append a new turn to Antigravity transcript -> ONLY the new turn is read & ingested!
    with ag_file.open("a", encoding="utf-8") as fh:
        fh.write(
            json.dumps(
                {
                    "step_index": 4,
                    "source": "USER_EXPLICIT",
                    "type": "USER_INPUT",
                    "created_at": "2026-11-23T08:20:00Z",
                    "content": "继续推进 Phase 2",
                }
            )
            + "\n"
        )
    rep3 = run_collector(collector, sink, checkpoints)
    assert rep3.created == 1
    assert store.list_collector_statuses()[0]["collector"] == "ai_chat"


def test_clipcontext_snapshot_rollback_guard_revocation_and_raw_manifest(tmp_path: Path) -> None:
    store = HubStore(tmp_path / "hub")
    sink = DirectHubSink(store)
    checkpoints = HubCheckpointStore(store)

    snap_path = tmp_path / "Agent" / "clipboard.json"
    snap_path.parent.mkdir(parents=True)
    snap_v1 = {
        "schemaVersion": 1,
        "deviceID": "mac-dev-1",
        "revision": 10,
        "updatedAt": "2026-11-23T08:00:00Z",
        "items": [
            {
                "id": "clip-1",
                "application": "com.google.Chrome",
                "firstCopiedAt": "2026-11-23T08:00:00Z",
                "lastCopiedAt": "2026-11-23T08:00:00Z",
                "numberOfCopies": 2,
                "pin": False,
                "title": "uv run context-hub serve",
                "contents": [{"type": "public.utf8-plain-text", "text": "uv run context-hub serve"}],
            },
            {
                "id": "clip-secret-1p",
                "application": "com.agilebits.onepassword7",
                "firstCopiedAt": "2026-11-23T08:01:00Z",
                "lastCopiedAt": "2026-11-23T08:01:00Z",
                "contents": [{"type": "public.utf8-plain-text", "text": "super-secret-pass"}],
            },
            {
                "id": "clip-concealed",
                "application": "com.apple.Terminal",
                "firstCopiedAt": "2026-11-23T08:02:00Z",
                "lastCopiedAt": "2026-11-23T08:02:00Z",
                "contents": [
                    {"type": "org.nspasteboard.ConcealedType", "text": ""},
                    {"type": "public.utf8-plain-text", "text": "hidden-token"},
                ],
            },
        ],
    }
    snap_path.write_text(json.dumps(snap_v1), encoding="utf-8")

    # Also create Raw/manifest.json + chunk
    raw_dir = tmp_path / "Raw"
    chunks_dir = raw_dir / "chunks"
    chunks_dir.mkdir(parents=True)
    chunk0 = {
        "deviceID": "mac-dev-1",
        "revision": 12,
        "schemaVersion": 1,
        "items": [
            {
                "id": "raw-clip-1",
                "sequence": 1,
                "application": "com.apple.Terminal",
                "firstCopiedAt": "2026-11-23T08:05:00Z",
                "lastCopiedAt": "2026-11-23T08:05:00Z",
                "numberOfCopies": 1,
                "title": "https://github.com/kepano/defuddle",
                "contents": [{"type": "public.url", "text": "https://github.com/kepano/defuddle"}],
            }
        ],
    }
    (chunks_dir / "00000000.json").write_text(json.dumps(chunk0), encoding="utf-8")
    manifest_path = raw_dir / "manifest.json"
    manifest_path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "deviceID": "mac-dev-1",
                "revision": 12,
                "itemCount": 1,
                "chunks": [{"file": "chunks/00000000.json", "sha256": "abc123", "itemCount": 1}],
            }
        ),
        encoding="utf-8",
    )

    col = ClipContextCollector(snapshot_path=snap_path, raw_manifest_path=manifest_path)
    r1 = run_collector(col, sink, checkpoints)
    assert r1.status == "ok"
    # 1Password & ConcealedType filtered out; 1 snapshot item + 1 raw chunk item = 2
    assert r1.created == 2

    # Rollback protection: lower revision MUST be rejected and NOT delete clip-1
    snap_stale = {**snap_v1, "revision": 5, "items": []}
    snap_path.write_text(json.dumps(snap_stale), encoding="utf-8")
    r_stale = run_collector(col, sink, checkpoints)
    assert r_stale.status == "degraded"
    assert r_stale.revoked == 0
    assert len(store.list_raw(sources=["clipboard"])) == 2

    # Legitimate higher revision removing clip-1 -> propagates revocation cleanly
    snap_v2 = {**snap_v1, "revision": 11, "items": []}
    snap_path.write_text(json.dumps(snap_v2), encoding="utf-8")
    r_rev = run_collector(col, sink, checkpoints)
    assert r_rev.revoked == 1
    assert len(store.list_raw(sources=["clipboard"])) == 1


def test_http_sink_offline_spool_and_recovery(tmp_path: Path) -> None:
    spool_dir = tmp_path / "spool"
    # Point to an unreachable local port so first emit spools offline
    sink = HttpHubSink("http://127.0.0.1:19", spool_dir=spool_dir, timeout_seconds=0.2)
    ev = RawEventIn(
        source="clipboard",
        kind="copy",
        t_start=1_763_800_000_000,
        content={"text": "offline spool test"},
        provenance={"connector": "clipcontext", "source_id": "offline-1"},
    )
    res = sink.emit_batch("clipcontext", [ev])
    assert res["spooled"] == 1
    assert (spool_dir / "clipcontext.jsonl").is_file()

    # Patch `_request_json` to simulate Hub coming back online and verify drain_spool
    received: list[dict] = []

    def _fake_request(method: str, path: str, payload: dict) -> dict:
        if path == "/api/v2/events/batch":
            received.extend(payload["events"])
        return {"created": len(payload.get("events", []))}

    sink._request_json = _fake_request  # type: ignore[method-assign]
    drained = sink.drain_spool("clipcontext")
    assert drained == 1
    assert len(received) == 1
    assert not (spool_dir / "clipcontext.jsonl").exists()


def test_export_parsers_chatgpt_and_claude_web(tmp_path: Path) -> None:
    cgpt = tmp_path / "chatgpt.json"
    cgpt.write_text(
        json.dumps(
            [
                {
                    "conversation_id": "cg-1",
                    "mapping": {
                        "n1": {
                            "parent": None,
                            "message": {
                                "author": {"role": "user"},
                                "create_time": 1763800000,
                                "content": {"content_type": "text", "parts": ["Explain FTS5"]},
                            },
                        },
                        "n2": {
                            "parent": "n1",
                            "message": {
                                "author": {"role": "assistant"},
                                "create_time": 1763800010,
                                "content": {"content_type": "text", "parts": ["FTS5 is SQLite full-text search."]},
                            },
                        },
                    },
                }
            ]
        ),
        encoding="utf-8",
    )
    cg_events = parse_export_file(cgpt, "chatgpt", project="context-os")
    assert len(cg_events) == 2

    cw = tmp_path / "claude_web.json"
    cw.write_text(
        json.dumps(
            [
                {
                    "uuid": "cw-1",
                    "chat_messages": [
                        {
                            "uuid": "m1",
                            "sender": "human",
                            "created_at": "2026-11-23T08:00:00Z",
                            "content": [{"type": "text", "text": "Hello Claude"}],
                        }
                    ],
                }
            ]
        ),
        encoding="utf-8",
    )
    cw_events = parse_export_file(cw, "claude-web", project="context-os")
    assert len(cw_events) == 1
