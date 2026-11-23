"""Incremental Audio Collector (`Record for Agent` Mac Library + CloudKit/Drop Inbox).

Solves all 5 integration gaps documented in `docs/research/channel-audio.md`:
1. Logical `recordingGroup` / session stitching across consecutive ~60s segments.
2. Absolute wall-clock span timestamps (`segment.startedAt + span.start * 1000`).
3. Full GPS location (`latitude`, `longitude`, `horizontalAccuracy`) + explicit timezone preservation.
4. High-accuracy offline ASR (`SenseVoice-Small` + `Silero-VAD`) with optional Apple-transcript
   side-by-side preservation (`context.original_transcript`) and instant silence skipping.
5. Incremental checkpointing so already-transcribed segments are skipped in O(1) without
   re-running ASR.
"""

from __future__ import annotations

import datetime
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from context_hub.models import RawEventIn

from ..runtime import (
    CheckpointBackend,
    HubSink,
    SyncReport,
    default_device_id,
    open_readonly_sqlite,
)
from .asr import (
    ASRResult,
    AudioTranscriber,
    SenseVoiceASR,
    default_models_dir,
    sensevoice_model_status,
)


@dataclass
class AudioPaths:
    library_dir: Path | None = None
    inbox_dir: Path | None = None
    models_dir: Path | None = None


def discover_audio_paths(home: Path | None = None) -> AudioPaths:
    h = (home or Path.home()).expanduser()
    lib = Path(
        os.environ.get(
            "CONTEXT_AUDIO_LIBRARY_DIR",
            str(h / "Library" / "Application Support" / "RecordForAgent" / "Library"),
        )
    ).expanduser()
    inbox = Path(
        os.environ.get(
            "CONTEXT_AUDIO_INBOX_DIR",
            str(h / ".local" / "share" / "context-hub-v2" / "inbox" / "audio"),
        )
    ).expanduser()
    return AudioPaths(library_dir=lib, inbox_dir=inbox, models_dir=default_models_dir())


def _parse_iso_or_ms(value: Any) -> int:
    if isinstance(value, (int, float)):
        return round(value if abs(value) >= 100_000_000_000 else value * 1000)
    if isinstance(value, str) and value.strip():
        dt = datetime.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.UTC)
        return round(dt.timestamp() * 1000)
    return 0


def _locate_audio_file(library_dir: Path, recording_id: str, manifest: dict[str, Any]) -> Path | None:
    obj_dir = library_dir / "objects" / recording_id
    candidates = [
        obj_dir / f"{recording_id}.caf",
        obj_dir / f"{recording_id}.m4a",
        obj_dir / str(manifest.get("fileName") or ""),
    ]
    for cand in candidates:
        if cand.is_file() and not cand.is_symlink():
            return cand
    if obj_dir.is_dir():
        for ext in ("*.m4a", "*.caf", "*.wav", "*.opus"):
            matches = list(obj_dir.glob(ext))
            if matches and matches[0].is_file():
                return matches[0]
    return None


def _build_voice_event(
    *,
    recording_id: str,
    manifest: dict[str, Any],
    text: str,
    spans: list[dict[str, Any]],
    asr_engine: str,
    locale: str,
    connector: str,
    locator: str,
    original_apple_transcript: str | None = None,
    device_id: str | None = None,
    audio_path: Path | None = None,
    speech_seconds: float | None = None,
) -> RawEventIn:
    t_start = _parse_iso_or_ms(manifest.get("startedAt"))
    t_end = _parse_iso_or_ms(manifest.get("endedAt")) or t_start
    if t_end < t_start:
        t_end = t_start
    duration_s = round((t_end - t_start) / 1000.0, 2)

    group = manifest.get("recordingGroup") or {}
    group_id = (
        str(group.get("id"))
        if isinstance(group, dict) and group.get("id")
        else str(manifest.get("recordingGroupID") or manifest.get("sessionID") or recording_id)
    )
    seq = manifest.get("sequence")
    tz_id = manifest.get("timeZoneIdentifier")
    loc = manifest.get("location")

    snippet = text.strip().splitlines()[0][:80] if text.strip() else "录音片段"
    dt_label = (
        datetime.datetime.fromtimestamp(t_start / 1000.0, tz=datetime.UTC).strftime("%m-%d %H:%M")
        if t_start > 0
        else ""
    )
    title = f"[语音 {dt_label}] {snippet}" if dt_label else f"[语音] {snippet}"

    context: dict[str, Any] = {
        "session_id": str(manifest.get("sessionID") or group_id),
        "recording_group_id": group_id,
        "sequence": seq,
        "duration_seconds": duration_s,
        "asr_engine": asr_engine,
        "locale": locale,
        "audio_sha256": manifest.get("sha256"),
        "audio_bytes": manifest.get("byteCount"),
        "audio_format": audio_path.suffix.lstrip(".") if audio_path else None,
        "time_zone": tz_id,
        "time_zone_source": "recorded" if tz_id else "utc_fallback",
    }
    if speech_seconds is not None:
        context["speech_seconds"] = speech_seconds
    if isinstance(loc, dict) and loc.get("latitude") is not None and loc.get("longitude") is not None:
        context["location"] = {
            "latitude": loc["latitude"],
            "longitude": loc["longitude"],
            "horizontal_accuracy": loc.get("horizontalAccuracy"),
            "captured_at": loc.get("capturedAt"),
        }
    if original_apple_transcript and original_apple_transcript.strip() != text.strip():
        context["original_apple_transcript"] = original_apple_transcript.strip()

    return RawEventIn(
        source="voice",
        kind="transcript_segment",
        t_start=t_start,
        t_end=t_end,
        device_id=device_id or str(manifest.get("deviceID") or default_device_id()),
        actor="self",
        attention=min(1.0, round(0.35 + (speech_seconds or duration_s) / 90.0, 3)),
        content={
            "title": title[:220],
            "text": text.strip(),
            "transcript": text.strip(),
            "lang": locale,
            "spans": spans,
        },
        context={k: v for k, v in context.items() if v is not None},
        provenance={
            "connector": connector,
            "source_id": recording_id,
            "locator": locator,
        },
    )


class AudioCollector:
    """Collects audio segments from RecordForAgent SQLite library and CloudKit/Drop inbox."""

    name = "audio"
    source = "voice"

    def __init__(
        self,
        paths: AudioPaths | None = None,
        *,
        transcriber: AudioTranscriber | None = None,
        asr_mode: str = "auto",  # "auto" | "sensevoice" | "existing_only"
        upgrade_apple_transcripts: bool = False,
        max_segments_per_sync: int = 100,
    ):
        self.paths = paths or discover_audio_paths()
        self._transcriber = transcriber
        self.asr_mode = asr_mode
        self.upgrade_apple_transcripts = upgrade_apple_transcripts
        self.max_segments_per_sync = max(1, max_segments_per_sync)

    def _get_transcriber(self) -> AudioTranscriber | None:
        if self.asr_mode == "existing_only":
            return None
        if self._transcriber is not None:
            return self._transcriber
        st = sensevoice_model_status(self.paths.models_dir)
        if st["sherpa_onnx_installed"] and st["sensevoice_ready"]:
            self._transcriber = SenseVoiceASR(self.paths.models_dir)
            return self._transcriber
        if self.asr_mode == "sensevoice":
            raise RuntimeError(
                "SenseVoice-Small model is not installed. "
                "Run `uv run context-collectors download-asr-models`."
            )
        return None

    def doctor(self) -> dict[str, Any]:
        lib_db = self.paths.library_dir / "library.sqlite3" if self.paths.library_dir else None
        lib_info: dict[str, Any] = {
            "path": str(lib_db) if lib_db else None,
            "available": bool(lib_db and lib_db.is_file()),
        }
        if lib_db and lib_db.is_file():
            try:
                with open_readonly_sqlite(lib_db) as conn:
                    lib_info["recordings"] = conn.execute("SELECT COUNT(*) FROM recordings").fetchone()[0]
                    lib_info["existing_transcripts"] = conn.execute(
                        "SELECT COUNT(*) FROM transcripts WHERE length(trim(coalesce(search_text, ''))) > 0"
                    ).fetchone()[0]
            except Exception as exc:  # noqa: BLE001
                lib_info["error"] = str(exc)

        inbox = self.paths.inbox_dir
        inbox_files = (
            [p for p in inbox.glob("*.json") if p.is_file()] if inbox and inbox.is_dir() else []
        )
        return {
            "collector": self.name,
            "library": lib_info,
            "inbox": {
                "path": str(inbox) if inbox else None,
                "available": bool(inbox and inbox.is_dir()),
                "pending_sidecars": len(inbox_files),
            },
            "asr": sensevoice_model_status(self.paths.models_dir),
        }

    def _sync_library_sqlite(
        self,
        library_dir: Path,
        sink: HubSink,
        checkpoints: CheckpointBackend,
        report: SyncReport,
        transcriber: AudioTranscriber | None,
    ) -> None:
        db_path = library_dir / "library.sqlite3"
        if not db_path.is_file():
            return
        report.sources_scanned += 1
        source_key = f"library:{db_path}"
        cp = checkpoints.get(self.name, source_key)
        cursor = dict((cp or {}).get("cursor") or {})
        processed: dict[str, str] = dict(cursor.get("processed") or {})

        st = db_path.stat()
        with open_readonly_sqlite(db_path) as conn:
            rows = conn.execute(
                """SELECT r.id, r.session_id, r.sequence, r.started_at, r.ended_at,
                          r.manifest_json, t.transcript_json
                   FROM recordings r
                   LEFT JOIN transcripts t ON t.recording_id = r.id
                   ORDER BY r.started_at ASC, r.id ASC"""
            ).fetchall()

        events: list[RawEventIn] = []
        handled_this_pass = 0
        for row in rows:
            if handled_this_pass >= self.max_segments_per_sync:
                break
            rid = str(row["id"])
            prior_sig = processed.get(rid)
            existing_tr = json.loads(row["transcript_json"]) if row["transcript_json"] else None
            apple_text = str((existing_tr or {}).get("text") or "").strip()

            want_sensevoice = transcriber is not None and (
                self.upgrade_apple_transcripts or not apple_text
            )
            desired_sig = (
                f"asr:{transcriber.engine_name}"
                if want_sensevoice and transcriber
                else (f"existing:{(existing_tr or {}).get('engine', 'apple')}" if apple_text else "none")
            )
            if prior_sig == desired_sig or (prior_sig and prior_sig.startswith("asr:") and not want_sensevoice):
                continue

            manifest = json.loads(row["manifest_json"])
            manifest.setdefault("startedAt", row["started_at"])
            manifest.setdefault("endedAt", row["ended_at"])
            manifest.setdefault("sessionID", row["session_id"])
            manifest.setdefault("sequence", row["sequence"])
            t_start = _parse_iso_or_ms(manifest["startedAt"])
            audio_file = _locate_audio_file(library_dir, rid, manifest)

            text = ""
            spans_out: list[dict[str, Any]] = []
            engine = "none"
            locale = "zh-CN"
            speech_s: float | None = None

            if want_sensevoice and transcriber is not None and audio_file is not None:
                try:
                    asr_res: ASRResult = transcriber.transcribe_file(audio_file)
                    text = asr_res.text
                    spans_out = [sp.to_dict(t_start) for sp in asr_res.spans]
                    engine = asr_res.engine
                    locale = asr_res.locale
                    speech_s = asr_res.speech_seconds
                except Exception as exc:  # noqa: BLE001
                    report.skipped_errors += 1
                    report.errors.append(f"asr:{rid[:8]}: {exc}")
                    # Fall back to Apple transcript if available rather than losing the segment
                    if apple_text:
                        text = apple_text
                        engine = str((existing_tr or {}).get("engine") or "apple-speech-transcriber")
                        locale = str((existing_tr or {}).get("locale") or "zh-CN")
            elif apple_text:
                text = apple_text
                engine = str((existing_tr or {}).get("engine") or "apple-speech-transcriber")
                locale = str((existing_tr or {}).get("locale") or "zh-CN")
                for sp in (existing_tr or {}).get("spans") or []:
                    if isinstance(sp, dict) and sp.get("text"):
                        start_s = float(sp.get("start") or 0.0)
                        end_s = float(sp.get("end") or start_s)
                        spans_out.append(
                            {
                                "start": round(start_s, 3),
                                "end": round(end_s, 3),
                                "abs_start_ms": t_start + round(start_s * 1000),
                                "abs_end_ms": t_start + round(end_s * 1000),
                                "text": str(sp["text"]),
                            }
                        )
            else:
                # No transcript and no transcriber available yet; skip without marking permanently done
                if transcriber is None:
                    continue

            handled_this_pass += 1
            processed[rid] = f"asr:{engine}" if want_sensevoice else f"existing:{engine}"

            if not text.strip():
                # Pure silence — checkpointed so we don't waste CPU re-running ASR
                continue

            events.append(
                _build_voice_event(
                    recording_id=rid,
                    manifest=manifest,
                    text=text,
                    spans=spans_out,
                    asr_engine=engine,
                    locale=locale,
                    connector="record-for-agent/library",
                    locator=f"record-for-agent://library/{rid}",
                    original_apple_transcript=apple_text if apple_text else None,
                    audio_path=audio_file,
                    speech_seconds=speech_s,
                )
            )

        if events:
            report.events_emitted += len(events)
            res = sink.emit_batch(self.name, events)
            report.created += res.get("created", 0)
            report.existing += res.get("existing", 0)
            report.spooled += res.get("spooled", 0)
        elif handled_this_pass == 0:
            report.sources_unchanged += 1

        checkpoints.put(
            self.name,
            source_key,
            inode=st.st_ino,
            file_size=st.st_size,
            mtime_ns=st.st_mtime_ns,
            cursor={"processed": processed, "total_known": len(rows)},
        )
        report.watermark = f"library_processed={len(processed)}/{len(rows)}"

    def _sync_inbox_dir(
        self,
        inbox_dir: Path,
        sink: HubSink,
        checkpoints: CheckpointBackend,
        report: SyncReport,
        transcriber: AudioTranscriber | None,
    ) -> None:
        """Ingest compressed `.m4a`/`.caf` + `.json` sidecars dropped by CloudKit Mac companion."""
        if not inbox_dir.is_dir():
            return
        sidecars = sorted(p for p in inbox_dir.glob("*.json") if p.is_file() and not p.is_symlink())
        if not sidecars:
            return
        report.sources_scanned += len(sidecars)
        events: list[RawEventIn] = []
        handled = 0

        for meta_path in sidecars:
            if handled >= self.max_segments_per_sync:
                break
            source_key = f"inbox:{meta_path.name}"
            cp = checkpoints.get(self.name, source_key)
            st = meta_path.stat()
            if (
                cp
                and int(cp.get("inode") or 0) == st.st_ino
                and int(cp.get("file_size") or 0) == st.st_size
                and int(cp.get("mtime_ns") or 0) == st.st_mtime_ns
            ):
                report.sources_unchanged += 1
                continue
            try:
                manifest = json.loads(meta_path.read_text(encoding="utf-8"))
                rid = str(manifest.get("id") or meta_path.stem)
                t_start = _parse_iso_or_ms(manifest.get("startedAt"))
                audio_file: Path | None = None
                for cand_name in (
                    manifest.get("fileName"),
                    f"{meta_path.stem}.m4a",
                    f"{meta_path.stem}.caf",
                    f"{meta_path.stem}.wav",
                ):
                    if cand_name:
                        c = inbox_dir / Path(str(cand_name)).name
                        if c.is_file():
                            audio_file = c
                            break

                text = str(manifest.get("transcript") or "").strip()
                spans_out: list[dict[str, Any]] = []
                engine = str(manifest.get("asr_engine") or "inbox-metadata")
                locale = str(manifest.get("locale") or "zh-CN")
                speech_s: float | None = None

                if transcriber is not None and audio_file is not None and (
                    self.upgrade_apple_transcripts or not text
                ):
                    asr_res = transcriber.transcribe_file(audio_file)
                    text = asr_res.text
                    spans_out = [sp.to_dict(t_start) for sp in asr_res.spans]
                    engine = asr_res.engine
                    locale = asr_res.locale
                    speech_s = asr_res.speech_seconds

                handled += 1
                if text:
                    events.append(
                        _build_voice_event(
                            recording_id=rid,
                            manifest=manifest,
                            text=text,
                            spans=spans_out,
                            asr_engine=engine,
                            locale=locale,
                            connector="record-for-agent/cloudkit-inbox",
                            locator=f"record-for-agent://inbox/{rid}",
                            audio_path=audio_file,
                            speech_seconds=speech_s,
                        )
                    )
                checkpoints.put(
                    self.name,
                    source_key,
                    inode=st.st_ino,
                    file_size=st.st_size,
                    mtime_ns=st.st_mtime_ns,
                    cursor={"recording_id": rid, "engine": engine},
                )
            except Exception as exc:  # noqa: BLE001
                report.skipped_errors += 1
                report.errors.append(f"inbox:{meta_path.name}: {exc}")

        if events:
            report.events_emitted += len(events)
            res = sink.emit_batch(self.name, events)
            report.created += res.get("created", 0)
            report.existing += res.get("existing", 0)
            report.spooled += res.get("spooled", 0)

    def sync(self, sink: HubSink, checkpoints: CheckpointBackend) -> SyncReport:
        report = SyncReport(collector=self.name, source=self.source)
        transcriber = self._get_transcriber()
        found_any = False

        if self.paths.library_dir and (self.paths.library_dir / "library.sqlite3").is_file():
            found_any = True
            self._sync_library_sqlite(self.paths.library_dir, sink, checkpoints, report, transcriber)

        if self.paths.inbox_dir and self.paths.inbox_dir.is_dir():
            found_any = True
            self._sync_inbox_dir(self.paths.inbox_dir, sink, checkpoints, report, transcriber)

        if not found_any:
            report.status = "idle"
            report.message = "No RecordForAgent library or CloudKit audio inbox found yet."
        else:
            asr_label = transcriber.engine_name if transcriber else "existing-transcripts-only"
            report.message = (
                f"Audio synced ({asr_label}): created={report.created}, "
                f"existing={report.existing}, skipped_errors={report.skipped_errors}"
            )
        return report
