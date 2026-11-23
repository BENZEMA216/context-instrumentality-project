"""Resilient Collector Runtime: Checkpoints, Incremental JSONL Tailing, Spooling & Sinks.

Design goals:
- Incremental O(1) skip for unchanged files via `(inode, size, mtime_ns)`.
- Byte-offset newline-bounded tailing for append-only JSONL logs (never advances past
  a half-written trailing line, automatically recovers on file rotation/truncation).
- Safe read-only SQLite access with `SQLITE_BUSY` retry so host apps are never locked.
- Durable offline spool (`spool/<collector>.jsonl`) when HTTP Hub is temporarily down.
- Strict per-source error isolation and structured health telemetry into `collector_status`.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import sqlite3
import subprocess
import time
import urllib.error
import urllib.request
from collections.abc import Iterator
from contextlib import contextmanager, suppress
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from context_hub.models import CollectorStatusIn, RawEventIn, now_ms
from context_hub.store import HubStore, HubStoreError


def default_device_id() -> str:
    return os.environ.get("CONTEXT_HUB_DEVICE_ID") or socket.gethostname().split(".")[0] or "mac-local"


@dataclass
class SyncReport:
    collector: str
    source: str
    status: str = "ok"
    sources_scanned: int = 0
    sources_unchanged: int = 0
    events_emitted: int = 0
    created: int = 0
    existing: int = 0
    revoked: int = 0
    skipped_errors: int = 0
    spooled: int = 0
    spool_drained: int = 0
    duration_ms: int = 0
    watermark: str | None = None
    message: str = ""
    errors: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "collector": self.collector,
            "source": self.source,
            "status": self.status,
            "sources_scanned": self.sources_scanned,
            "sources_unchanged": self.sources_unchanged,
            "events_emitted": self.events_emitted,
            "created": self.created,
            "existing": self.existing,
            "revoked": self.revoked,
            "skipped_errors": self.skipped_errors,
            "spooled": self.spooled,
            "spool_drained": self.spool_drained,
            "duration_ms": self.duration_ms,
            "watermark": self.watermark,
            "message": self.message,
            "errors": self.errors[:20],
        }


class CheckpointBackend(Protocol):
    def get(self, collector: str, source_key: str) -> dict[str, Any] | None: ...

    def put(
        self,
        collector: str,
        source_key: str,
        *,
        device_id: str = "",
        inode: int = 0,
        file_size: int = 0,
        mtime_ns: int = 0,
        byte_offset: int = 0,
        content_sha256: str = "",
        cursor: dict[str, Any] | None = None,
    ) -> dict[str, Any]: ...


class HubCheckpointStore:
    """Stores collector checkpoints directly inside `HubStore`'s WAL SQLite DB."""

    def __init__(self, store: HubStore):
        self.store = store

    def get(self, collector: str, source_key: str) -> dict[str, Any] | None:
        return self.store.get_collector_checkpoint(collector, source_key)

    def put(
        self,
        collector: str,
        source_key: str,
        *,
        device_id: str = "",
        inode: int = 0,
        file_size: int = 0,
        mtime_ns: int = 0,
        byte_offset: int = 0,
        content_sha256: str = "",
        cursor: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        return self.store.set_collector_checkpoint(
            collector,
            source_key,
            device_id=device_id,
            inode=inode,
            file_size=file_size,
            mtime_ns=mtime_ns,
            byte_offset=byte_offset,
            content_sha256=content_sha256,
            cursor=cursor,
        )


class StandaloneCheckpointStore:
    """Standalone SQLite checkpoint store for remote/HTTP-mode collectors."""

    def __init__(self, db_path: Path):
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        conn = sqlite3.connect(str(self.db_path), timeout=15, isolation_level=None)
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=NORMAL")
            conn.execute(
                """CREATE TABLE IF NOT EXISTS collector_checkpoints (
                    collector TEXT NOT NULL,
                    source_key TEXT NOT NULL,
                    device_id TEXT NOT NULL DEFAULT '',
                    inode INTEGER NOT NULL DEFAULT 0,
                    file_size INTEGER NOT NULL DEFAULT 0,
                    mtime_ns INTEGER NOT NULL DEFAULT 0,
                    byte_offset INTEGER NOT NULL DEFAULT 0,
                    content_sha256 TEXT NOT NULL DEFAULT '',
                    cursor_json TEXT NOT NULL DEFAULT '{}',
                    updated_at INTEGER NOT NULL,
                    PRIMARY KEY(collector, source_key)
                )"""
            )
        finally:
            conn.close()

    def get(self, collector: str, source_key: str) -> dict[str, Any] | None:
        conn = sqlite3.connect(str(self.db_path), timeout=15)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute(
                "SELECT * FROM collector_checkpoints WHERE collector=? AND source_key=?",
                (collector, source_key),
            ).fetchone()
            if row is None:
                return None
            out = dict(row)
            out["cursor"] = json.loads(out.pop("cursor_json") or "{}")
            return out
        finally:
            conn.close()

    def put(
        self,
        collector: str,
        source_key: str,
        *,
        device_id: str = "",
        inode: int = 0,
        file_size: int = 0,
        mtime_ns: int = 0,
        byte_offset: int = 0,
        content_sha256: str = "",
        cursor: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        now = now_ms()
        cursor_json = json.dumps(cursor or {}, ensure_ascii=False, sort_keys=True)
        conn = sqlite3.connect(str(self.db_path), timeout=15)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute(
                """INSERT INTO collector_checkpoints
                   (collector, source_key, device_id, inode, file_size, mtime_ns,
                    byte_offset, content_sha256, cursor_json, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(collector, source_key) DO UPDATE SET
                     device_id=excluded.device_id,
                     inode=excluded.inode,
                     file_size=excluded.file_size,
                     mtime_ns=excluded.mtime_ns,
                     byte_offset=excluded.byte_offset,
                     content_sha256=excluded.content_sha256,
                     cursor_json=excluded.cursor_json,
                     updated_at=excluded.updated_at""",
                (
                    collector,
                    source_key,
                    device_id,
                    inode,
                    file_size,
                    mtime_ns,
                    byte_offset,
                    content_sha256,
                    cursor_json,
                    now,
                ),
            )
            conn.commit()
            row = conn.execute(
                "SELECT * FROM collector_checkpoints WHERE collector=? AND source_key=?",
                (collector, source_key),
            ).fetchone()
            out = dict(row)
            out["cursor"] = json.loads(out.pop("cursor_json") or "{}")
            return out
        finally:
            conn.close()


class HubSink(Protocol):
    def emit_batch(self, collector: str, events: list[RawEventIn]) -> dict[str, int]: ...

    def revoke(self, source: str, connector: str, source_id: str) -> bool: ...

    def report_status(self, status_in: CollectorStatusIn) -> None: ...

    def drain_spool(self, collector: str) -> int: ...


class DirectHubSink:
    """In-process local sink writing directly into `HubStore` (zero HTTP overhead)."""

    def __init__(self, store: HubStore):
        self.store = store

    def emit_batch(self, collector: str, events: list[RawEventIn]) -> dict[str, int]:
        if not events:
            return {"created": 0, "existing": 0, "spooled": 0}
        res = self.store.ingest_batch(events)
        return {
            "created": int(res.get("created", 0)),
            "existing": int(res.get("existing", 0)),
            "spooled": 0,
        }

    def revoke(self, source: str, connector: str, source_id: str) -> bool:
        res = self.store.delete_raw_by_source(source, connector, source_id)
        return bool(res.get("deleted"))

    def report_status(self, status_in: CollectorStatusIn) -> None:
        self.store.update_collector_status(status_in)

    def drain_spool(self, collector: str) -> int:
        return 0


class HttpHubSink:
    """HTTP sink pushing batches to a running Hub server with automatic offline spooling."""

    def __init__(
        self,
        hub_url: str,
        *,
        owner_token: str | None = None,
        spool_dir: Path | None = None,
        batch_size: int = 100,
        timeout_seconds: float = 15.0,
    ):
        self.hub_url = hub_url.rstrip("/")
        self.owner_token = owner_token
        self.spool_dir = spool_dir
        self.batch_size = max(1, min(batch_size, 500))
        self.timeout_seconds = timeout_seconds
        if self.spool_dir is not None:
            self.spool_dir.mkdir(parents=True, exist_ok=True, mode=0o700)

    def _request_json(self, method: str, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.owner_token:
            headers["Authorization"] = f"Bearer {self.owner_token}"
        req = urllib.request.Request(
            f"{self.hub_url}{path}", data=body, headers=headers, method=method
        )
        with urllib.request.urlopen(req, timeout=self.timeout_seconds) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}

    def _spool_path(self, collector: str) -> Path | None:
        if self.spool_dir is None:
            return None
        safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in collector)
        return self.spool_dir / f"{safe}.jsonl"

    def _append_spool(self, collector: str, events: list[RawEventIn]) -> int:
        sp = self._spool_path(collector)
        if sp is None or not events:
            return 0
        with sp.open("a", encoding="utf-8") as fh:
            for ev in events:
                fh.write(json.dumps(ev.model_dump(exclude_none=True), ensure_ascii=False) + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        return len(events)

    def drain_spool(self, collector: str) -> int:
        sp = self._spool_path(collector)
        if sp is None or not sp.is_file():
            return 0
        lines = [line for line in sp.read_text(encoding="utf-8").splitlines() if line.strip()]
        if not lines:
            sp.unlink(missing_ok=True)
            return 0
        drained = 0
        remaining: list[str] = []
        for idx in range(0, len(lines), self.batch_size):
            chunk_lines = lines[idx : idx + self.batch_size]
            parsed = [json.loads(line) for line in chunk_lines]
            try:
                self._request_json("POST", "/api/v2/events/batch", {"events": parsed})
                drained += len(parsed)
            except (urllib.error.URLError, TimeoutError, OSError):
                remaining.extend(lines[idx:])
                break
        if remaining:
            sp.write_text("\n".join(remaining) + "\n", encoding="utf-8")
        else:
            sp.unlink(missing_ok=True)
        return drained

    def emit_batch(self, collector: str, events: list[RawEventIn]) -> dict[str, int]:
        totals = {"created": 0, "existing": 0, "spooled": 0}
        if not events:
            return totals
        for idx in range(0, len(events), self.batch_size):
            chunk = events[idx : idx + self.batch_size]
            payload = {"events": [ev.model_dump(exclude_none=True) for ev in chunk]}
            try:
                res = self._request_json("POST", "/api/v2/events/batch", payload)
                totals["created"] += int(res.get("created", 0))
                totals["existing"] += int(res.get("existing", 0))
            except (urllib.error.URLError, TimeoutError, OSError):
                totals["spooled"] += self._append_spool(collector, events[idx:])
                break
        return totals

    def revoke(self, source: str, connector: str, source_id: str) -> bool:
        try:
            res = self._request_json(
                "POST",
                "/api/v2/events/revoke",
                {"source": source, "connector": connector, "source_id": source_id},
            )
            return bool(res.get("deleted"))
        except (urllib.error.URLError, TimeoutError, OSError):
            return False

    def report_status(self, status_in: CollectorStatusIn) -> None:
        with suppress(urllib.error.URLError, TimeoutError, OSError):
            self._request_json(
                "POST", "/api/v2/collectors/status", status_in.model_dump(exclude_none=True)
            )


# ----------------------------------------------------------------------
# File & SQLite Reliability Utilities
# ----------------------------------------------------------------------
@contextmanager
def open_readonly_sqlite(path: Path, *, retries: int = 3) -> Iterator[sqlite3.Connection]:
    """Open an external app's SQLite DB strictly read-only with transient busy backoff."""
    resolved = path.resolve(strict=True)
    uri = resolved.as_uri() + "?mode=ro"
    last_exc: Exception | None = None
    for attempt in range(max(1, retries)):
        conn = sqlite3.connect(uri, uri=True, timeout=5.0)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute("PRAGMA query_only=ON")
            conn.execute("PRAGMA busy_timeout=5000")
            conn.execute("BEGIN")
            try:
                yield conn
            finally:
                conn.close()
            return
        except sqlite3.OperationalError as exc:
            conn.close()
            last_exc = exc
            if "locked" in str(exc).lower() or "busy" in str(exc).lower():
                time.sleep(0.15 * (attempt + 1))
                continue
            raise
    if last_exc:
        raise last_exc


@contextmanager
def open_maybe_zstd(path: Path) -> Iterator[Any]:
    if path.suffix not in {".zst", ".zstd"}:
        with path.open("rb") as fh:
            yield fh
        return
    with path.open("rb") as src:
        proc = subprocess.Popen(
            ["zstd", "-dc"], stdin=src, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
        )
        assert proc.stdout is not None
        try:
            yield proc.stdout
            if proc.wait() != 0:
                raise ValueError(f"Incomplete or invalid zstd stream: {path}")
        finally:
            proc.stdout.close()
            if proc.poll() is None:
                proc.terminate()
            proc.wait()


@dataclass
class IncrementalJsonlBatch:
    records: list[tuple[int, dict[str, Any]]]
    next_offset: int
    next_line_no: int
    inode: int
    file_size: int
    mtime_ns: int
    unchanged: bool = False
    rotated: bool = False
    skipped_errors: int = 0


def read_incremental_jsonl(
    path: Path,
    checkpoint: dict[str, Any] | None = None,
    *,
    max_lines: int = 5000,
) -> IncrementalJsonlBatch:
    """Read only newly appended complete newline-terminated JSONL objects from `path`.

    Guarantees:
    - O(1) stat skip if `(inode, size, mtime_ns)` match checkpoint.
    - Never advances past a partially written trailing line lacking `\\n`.
    - Detects rotation/truncation (`inode` change or `size < byte_offset`) and cleanly
      re-reads from offset 0.
    - Isolates individual malformed JSON lines (`skipped_errors`) instead of aborting.
    """
    st = path.stat()
    inode = st.st_ino
    size = st.st_size
    mtime_ns = st.st_mtime_ns

    cp_inode = int((checkpoint or {}).get("inode") or 0)
    cp_size = int((checkpoint or {}).get("file_size") or 0)
    cp_mtime = int((checkpoint or {}).get("mtime_ns") or 0)
    cp_offset = int((checkpoint or {}).get("byte_offset") or 0)
    cp_cursor = (checkpoint or {}).get("cursor") or {}
    cp_line_no = int(cp_cursor.get("line_no") or 0)

    if checkpoint and cp_inode == inode and cp_size == size and cp_mtime == mtime_ns and cp_offset == size:
        return IncrementalJsonlBatch(
            records=[],
            next_offset=cp_offset,
            next_line_no=cp_line_no,
            inode=inode,
            file_size=size,
            mtime_ns=mtime_ns,
            unchanged=True,
        )

    # Compressed files cannot seek by compressed byte offset cleanly; re-read on mtime/size change
    if path.suffix in {".zst", ".zstd"}:
        if checkpoint and cp_inode == inode and cp_size == size and cp_mtime == mtime_ns:
            return IncrementalJsonlBatch(
                records=[],
                next_offset=size,
                next_line_no=cp_line_no,
                inode=inode,
                file_size=size,
                mtime_ns=mtime_ns,
                unchanged=True,
            )
        records: list[tuple[int, dict[str, Any]]] = []
        skipped = 0
        line_no = 0
        with open_maybe_zstd(path) as stream:
            for line_no, raw_line in enumerate(stream, 1):
                if not raw_line.strip():
                    continue
                try:
                    obj = json.loads(raw_line)
                except (ValueError, UnicodeError):
                    skipped += 1
                    continue
                if isinstance(obj, dict):
                    records.append((line_no, obj))
        return IncrementalJsonlBatch(
            records=records,
            next_offset=size,
            next_line_no=line_no,
            inode=inode,
            file_size=size,
            mtime_ns=mtime_ns,
            unchanged=False,
            rotated=bool(checkpoint),
            skipped_errors=skipped,
        )

    rotated = False
    start_offset = cp_offset
    line_no = cp_line_no
    if not checkpoint or cp_inode != inode or size < cp_offset:
        rotated = bool(checkpoint)
        start_offset = 0
        line_no = 0

    records = []
    skipped = 0
    cursor_offset = start_offset
    with path.open("rb") as fh:
        fh.seek(start_offset)
        while len(records) < max_lines:
            raw_line = fh.readline()
            if not raw_line:
                break
            # Guard against partial concurrent writes: only commit complete newline-terminated lines
            if not raw_line.endswith(b"\n"):
                break
            cursor_offset += len(raw_line)
            line_no += 1
            if not raw_line.strip():
                continue
            try:
                obj = json.loads(raw_line)
            except (ValueError, UnicodeError):
                skipped += 1
                continue
            if isinstance(obj, dict):
                records.append((line_no, obj))

    return IncrementalJsonlBatch(
        records=records,
        next_offset=cursor_offset,
        next_line_no=line_no,
        inode=inode,
        file_size=size,
        mtime_ns=mtime_ns,
        unchanged=False,
        rotated=rotated,
        skipped_errors=skipped,
    )


class Collector(Protocol):
    name: str
    source: str

    def doctor(self) -> dict[str, Any]: ...

    def sync(self, sink: HubSink, checkpoints: CheckpointBackend) -> SyncReport: ...


def run_collector(
    collector: Collector,
    sink: HubSink,
    checkpoints: CheckpointBackend,
) -> SyncReport:
    """Execute one collector pass with error isolation, spool drain, and health telemetry."""
    started = time.perf_counter()
    drained = sink.drain_spool(collector.name)
    try:
        report = collector.sync(sink, checkpoints)
        report.spool_drained = drained
        report.duration_ms = round((time.perf_counter() - started) * 1000)
        if report.spooled > 0 and report.status == "ok":
            report.status = "degraded"
            report.message = (
                f"{report.message}; spooled {report.spooled} events offline".strip("; ")
            )
    except (OSError, ValueError, HubStoreError, sqlite3.Error) as exc:
        report = SyncReport(
            collector=collector.name,
            source=collector.source,
            status="error",
            spool_drained=drained,
            duration_ms=round((time.perf_counter() - started) * 1000),
            message=f"{type(exc).__name__}: {exc}",
            errors=[f"{type(exc).__name__}: {exc}"],
        )

    sink.report_status(
        CollectorStatusIn(
            collector=collector.name,
            source=collector.source,  # type: ignore[arg-type]
            status=report.status,  # type: ignore[arg-type]
            items_synced=report.created,
            watermark=report.watermark,
            message=report.message or f"created={report.created}, existing={report.existing}, errors={report.skipped_errors}",
        )
    )
    return report


def watch_collectors(
    collectors: list[Collector],
    sink: HubSink,
    checkpoints: CheckpointBackend,
    *,
    interval_seconds: float = 30.0,
    max_ticks: int | None = None,
    on_tick: Any = None,
) -> list[list[SyncReport]]:
    """Run collectors in a resilient daemon loop with clean SIGINT/SIGTERM handling."""
    stop = False

    def _handle_signal(_signum: int, _frame: Any) -> None:
        nonlocal stop
        stop = True

    old_int = signal.getsignal(signal.SIGINT)
    old_term = signal.getsignal(signal.SIGTERM)
    try:
        signal.signal(signal.SIGINT, _handle_signal)
        signal.signal(signal.SIGTERM, _handle_signal)
    except ValueError:
        # Running inside a non-main thread (e.g. test harness)
        old_int = old_term = None

    history: list[list[SyncReport]] = []
    ticks = 0
    try:
        while not stop:
            tick_reports = [run_collector(col, sink, checkpoints) for col in collectors]
            history.append(tick_reports)
            ticks += 1
            if on_tick is not None:
                on_tick(tick_reports)
            if max_ticks is not None and ticks >= max_ticks:
                break
            deadline = time.monotonic() + max(0.5, interval_seconds)
            while not stop and time.monotonic() < deadline:
                time.sleep(min(0.5, max(0.05, deadline - time.monotonic())))
    finally:
        if old_int is not None:
            signal.signal(signal.SIGINT, old_int)
        if old_term is not None:
            signal.signal(signal.SIGTERM, old_term)
    return history
