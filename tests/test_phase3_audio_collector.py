"""Unit tests for Phase 3 Audio Collector (`Record for Agent` library + CloudKit inbox + ASR)."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from context_collectors.audio import (
    ASRResult,
    ASRSpan,
    AudioCollector,
    AudioPaths,
    GoogleDriveAudioTransport,
    WebDAVAudioTransport,
    pack_audio_packet,
    unpack_audio_packet,
)
from context_collectors.runtime import DirectHubSink, HubCheckpointStore, run_collector
from context_hub.store import HubStore


class _StubTranscriber:
    engine_name = "sensevoice-stub"

    def __init__(self, responses: dict[str, ASRResult]):
        self.responses = responses
        self.calls: list[str] = []

    def transcribe_file(self, audio_path: Path) -> ASRResult:
        self.calls.append(audio_path.name)
        return self.responses.get(
            audio_path.name,
            ASRResult(text="", spans=[], engine=self.engine_name, audio_seconds=60.0),
        )


def test_audio_collector_library_stitching_spans_location_silence_and_idempotency(
    tmp_path: Path,
) -> None:
    store = HubStore(tmp_path / "hub")
    sink = DirectHubSink(store)
    checkpoints = HubCheckpointStore(store)

    lib_dir = tmp_path / "RecordForAgent" / "Library"
    (lib_dir / "objects" / "rec-001").mkdir(parents=True)
    (lib_dir / "objects" / "rec-002").mkdir(parents=True)
    (lib_dir / "objects" / "rec-003").mkdir(parents=True)
    (lib_dir / "objects" / "rec-001" / "rec-001.caf").write_bytes(b"fake-caf-1")
    (lib_dir / "objects" / "rec-002" / "rec-002.caf").write_bytes(b"fake-caf-2")
    (lib_dir / "objects" / "rec-003" / "rec-003.caf").write_bytes(b"fake-caf-silence")

    db_path = lib_dir / "library.sqlite3"
    conn = sqlite3.connect(db_path)
    conn.execute(
        """CREATE TABLE recordings (
            id TEXT PRIMARY KEY, session_id TEXT, sequence INTEGER,
            started_at INTEGER, ended_at INTEGER, manifest_json TEXT
        )"""
    )
    conn.execute(
        """CREATE TABLE transcripts (
            recording_id TEXT PRIMARY KEY, transcript_json TEXT, search_text TEXT
        )"""
    )
    t0 = 1_763_850_000_000
    # rec-001: has Apple transcript + GPS location + recordingGroup
    m1 = {
        "id": "rec-001",
        "sessionID": "sess-walk",
        "sequence": 1,
        "startedAt": t0,
        "endedAt": t0 + 60_000,
        "timeZoneIdentifier": "Asia/Shanghai",
        "sha256": "aaa111",
        "byteCount": 12345,
        "recordingGroup": {"id": "grp-walk-1", "startedAt": t0},
        "location": {"latitude": 31.23, "longitude": 121.47, "horizontalAccuracy": 15.0},
    }
    tr1 = {
        "engine": "apple-speech-transcriber",
        "locale": "zh-CN",
        "text": "我们决定用蓝鲸模型",
        "spans": [{"start": 2.5, "end": 5.0, "text": "我们决定用蓝鲸模型"}],
    }
    # rec-002: missing Apple transcript -> must run SenseVoice stub
    m2 = {
        "id": "rec-002",
        "sessionID": "sess-walk",
        "sequence": 2,
        "startedAt": t0 + 60_000,
        "endedAt": t0 + 120_000,
        "timeZoneIdentifier": "Asia/Shanghai",
        "sha256": "bbb222",
        "byteCount": 12345,
        "recordingGroup": {"id": "grp-walk-1", "startedAt": t0},
    }
    # rec-003: pure silence -> SenseVoice returns empty text -> skipped cleanly & checkpointed
    m3 = {
        "id": "rec-003",
        "sessionID": "sess-walk",
        "sequence": 3,
        "startedAt": t0 + 120_000,
        "endedAt": t0 + 180_000,
        "sha256": "ccc333",
        "byteCount": 1000,
    }
    conn.execute(
        "INSERT INTO recordings VALUES (?, ?, ?, ?, ?, ?)",
        ("rec-001", "sess-walk", 1, t0, t0 + 60_000, json.dumps(m1)),
    )
    conn.execute(
        "INSERT INTO transcripts VALUES (?, ?, ?)",
        ("rec-001", json.dumps(tr1, ensure_ascii=False), tr1["text"]),
    )
    conn.execute(
        "INSERT INTO recordings VALUES (?, ?, ?, ?, ?, ?)",
        ("rec-002", "sess-walk", 2, t0 + 60_000, t0 + 120_000, json.dumps(m2)),
    )
    conn.execute(
        "INSERT INTO recordings VALUES (?, ?, ?, ?, ?, ?)",
        ("rec-003", "sess-walk", 3, t0 + 120_000, t0 + 180_000, json.dumps(m3)),
    )
    conn.commit()
    conn.close()

    stub = _StubTranscriber(
        {
            "rec-002.caf": ASRResult(
                text="然后把音频压成 M4A 走 CloudKit 私有库同步。",
                spans=[ASRSpan(start=1.0, end=4.5, text="然后把音频压成 M4A 走 CloudKit 私有库同步。")],
                engine="sensevoice-stub",
                locale="zh",
                audio_seconds=60.0,
                speech_seconds=3.5,
            )
        }
    )

    col = AudioCollector(AudioPaths(library_dir=lib_dir), transcriber=stub, asr_mode="auto")
    r1 = run_collector(col, sink, checkpoints)
    assert r1.status == "ok"
    assert r1.created == 2  # rec-001 (existing) + rec-002 (stub ASR); rec-003 silence skipped
    assert stub.calls == ["rec-002.caf", "rec-003.caf"]

    events = store.list_raw(sources=["voice"], limit=10)
    assert len(events) == 2
    by_src = {e["provenance"]["source_id"]: e for e in events}

    # Verify GPS, timezone, recordingGroup, and absolute span timestamps!
    ev1 = by_src["rec-001"]
    assert ev1["context"]["location"]["latitude"] == 31.23
    assert ev1["context"]["recording_group_id"] == "grp-walk-1"
    assert ev1["content"]["spans"][0]["abs_start_ms"] == t0 + 2500

    ev2 = by_src["rec-002"]
    assert ev2["context"]["asr_engine"] == "sensevoice-stub"
    assert ev2["content"]["spans"][0]["abs_start_ms"] == t0 + 61_000
    # Both segments land inside the SAME Hub Episode!
    assert ev1["episode_id"] == ev2["episode_id"]

    # Second run skips everything in O(1) without calling ASR again
    stub.calls.clear()
    r2 = run_collector(col, sink, checkpoints)
    assert r2.created == 0
    assert stub.calls == []


def test_audio_collector_cloudkit_inbox_m4a_sidecar(tmp_path: Path) -> None:
    store = HubStore(tmp_path / "hub")
    sink = DirectHubSink(store)
    checkpoints = HubCheckpointStore(store)

    inbox = tmp_path / "inbox" / "audio"
    inbox.mkdir(parents=True)
    (inbox / "ck-seg-1.m4a").write_bytes(b"fake-m4a")
    (inbox / "ck-seg-1.json").write_text(
        json.dumps(
            {
                "id": "ck-seg-1",
                "sessionID": "ck-sess-1",
                "startedAt": "2026-11-23T11:00:00Z",
                "endedAt": "2026-11-23T11:01:00Z",
                "fileName": "ck-seg-1.m4a",
                "timeZoneIdentifier": "Asia/Shanghai",
                "location": {"latitude": 31.2, "longitude": 121.4},
            }
        ),
        encoding="utf-8",
    )

    stub = _StubTranscriber(
        {
            "ck-seg-1.m4a": ASRResult(
                text="CloudKit 私有库自动同步测试通过。",
                spans=[ASRSpan(start=0.5, end=3.2, text="CloudKit 私有库自动同步测试通过。")],
                engine="sensevoice-stub",
                locale="zh",
                audio_seconds=60.0,
                speech_seconds=2.7,
            )
        }
    )
    col = AudioCollector(AudioPaths(inbox_dir=inbox), transcriber=stub, asr_mode="auto")
    r1 = run_collector(col, sink, checkpoints)
    assert r1.created == 1
    ev = store.list_raw(sources=["voice"])[0]
    assert ev["provenance"]["connector"] == "record-for-agent/cloudkit-inbox"
    assert ev["context"]["audio_format"] == "m4a"
    assert "CloudKit" in ev["body_text"]


def test_audio_packet_roundtrip_and_webdav_and_gdrive_incremental_pull(tmp_path: Path) -> None:
    store = HubStore(tmp_path / "hub")
    checkpoints = HubCheckpointStore(store)

    # 1. Pack & verify single atomic `.ctxaudio.zip` packet
    raw_m4a = tmp_path / "seg-99.m4a"
    raw_m4a.write_bytes(b"compact-aac-audio-bytes-99")
    pkt_path = tmp_path / "seg-99.ctxaudio.zip"
    packed = pack_audio_packet(
        raw_m4a,
        {"id": "seg-99", "sessionID": "sess-99", "startedAt": "2026-11-23T12:00:00Z"},
        pkt_path,
        compress=False,
    )
    pkt_bytes = pkt_path.read_bytes()
    assert packed["segment_id"] == "seg-99"

    inbox_direct = tmp_path / "inbox-direct"
    unpacked = unpack_audio_packet(pkt_bytes, inbox_direct)
    assert unpacked["segment_id"] == "seg-99"
    assert (inbox_direct / "seg-99.m4a").read_bytes() == b"compact-aac-audio-bytes-99"
    assert json.loads((inbox_direct / "seg-99.json").read_text())["id"] == "seg-99"

    # 2. WebDAV incremental pull (simulates 坚果云 Nutstore PROPFIND + GET + ETag skip)
    webdav_inbox = tmp_path / "inbox-webdav"
    wd = WebDAVAudioTransport(
        "https://dav.jianguoyun.com/dav/RecordForAgent/",
        username="u",
        password="p",
    )
    propfind_xml = b"""<?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:">
      <d:response>
        <d:href>/dav/RecordForAgent/seg-99.ctxaudio.zip</d:href>
        <d:propstat><d:prop>
          <d:getetag>"etag-99"</d:getetag>
          <d:getcontentlength>512</d:getcontentlength>
        </d:prop></d:propstat>
      </d:response>
    </d:multistatus>"""

    def _fake_wd(method: str, url: str, *, data=None, headers=None):
        if method == "PROPFIND":
            return 207, propfind_xml, {}
        if method == "GET" and url.endswith("seg-99.ctxaudio.zip"):
            return 200, pkt_bytes, {}
        raise AssertionError(f"Unexpected WebDAV request: {method} {url}")

    wd._request = _fake_wd  # type: ignore[method-assign]
    r_wd1 = wd.pull_to_inbox(webdav_inbox, checkpoints)
    assert r_wd1.downloaded == 1
    assert not r_wd1.errors
    assert (webdav_inbox / "seg-99.m4a").is_file()

    # Second pass skips via persisted ETag without downloading again
    r_wd2 = wd.pull_to_inbox(webdav_inbox, checkpoints)
    assert r_wd2.downloaded == 0
    assert r_wd2.skipped_existing == 1

    # 3. Google Drive incremental pull (`startPageToken` -> `changes.list` delta)
    import hashlib

    gd_inbox = tmp_path / "inbox-gdrive"
    gd = GoogleDriveAudioTransport("fake-token", "folder-123")
    pkt_sha = hashlib.sha256(pkt_bytes).hexdigest()
    gd_calls: list[str] = []

    def _fake_gd(method: str, url: str, *, data=None, headers=None):
        gd_calls.append(url)
        if url.endswith("/changes/startPageToken"):
            return json.dumps({"startPageToken": "tok-1"}).encode()
        if "/files?" in url:
            return json.dumps(
                {
                    "files": [
                        {
                            "id": "file-99",
                            "name": "seg-99.ctxaudio.zip",
                            "sha256Checksum": pkt_sha,
                            "parents": ["folder-123"],
                        }
                    ]
                }
            ).encode()
        if url.endswith("/files/file-99?alt=media"):
            return pkt_bytes
        if "/changes?" in url:
            return json.dumps({"changes": [], "newStartPageToken": "tok-2"}).encode()
        raise AssertionError(f"Unexpected Drive request: {method} {url}")

    gd._request = _fake_gd  # type: ignore[method-assign]
    r_gd1 = gd.pull_to_inbox(gd_inbox, checkpoints)
    assert r_gd1.downloaded == 1
    assert r_gd1.cursor == "tok-1"
    assert (gd_inbox / "seg-99.json").is_file()

    # Second pass uses incremental `/changes?pageToken=tok-1` instead of full folder scan!
    r_gd2 = gd.pull_to_inbox(gd_inbox, checkpoints)
    assert r_gd2.downloaded == 0
    assert r_gd2.cursor == "tok-2"
    assert any("/changes?" in u for u in gd_calls)
