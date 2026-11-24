"""Incremental auto-discovering AI Chat Collector across macOS local Agent stores."""

from __future__ import annotations

import os
import time
from contextlib import suppress
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from context_hub.models import RawEventIn

from ..runtime import (
    CheckpointBackend,
    HubSink,
    SyncReport,
    read_incremental_jsonl,
)
from .parsers import (
    parse_antigravity_records,
    parse_claude_code_records,
    parse_codex_file,
    parse_cursor_db,
    parse_deepseek_records,
    parse_opencode_db,
    parse_workbuddy_or_qclaw_records,
)


@dataclass
class AIChatPaths:
    antigravity_brain: Path | None = None
    codex_sessions: Path | None = None
    claude_projects: Path | None = None
    cursor_global_db: Path | None = None
    cursor_workspaces: Path | None = None
    opencode_db: Path | None = None
    workbuddy_dir: Path | None = None
    qclaw_dir: Path | None = None
    deepseek_dir: Path | None = None
    enabled_providers: set[str] = field(
        default_factory=lambda: {
            "antigravity",
            "codex",
            "claude",
            "cursor",
            "opencode",
            "workbuddy",
            "qclaw",
            "deepseek",
        }
    )


def discover_default_paths(home: Path | None = None) -> AIChatPaths:
    h = (home or Path.home()).expanduser()
    cursor_user = h / "Library" / "Application Support" / "Cursor" / "User"

    def _env_or(env_key: str, default: Path) -> Path:
        val = os.environ.get(env_key)
        return Path(val).expanduser() if val else default

    return AIChatPaths(
        antigravity_brain=_env_or(
            "CONTEXT_ANTIGRAVITY_BRAIN_DIR", h / ".gemini" / "antigravity" / "brain"
        ),
        codex_sessions=_env_or("CONTEXT_CODEX_SESSIONS_DIR", h / ".codex" / "sessions"),
        claude_projects=_env_or("CONTEXT_CLAUDE_PROJECTS_DIR", h / ".claude" / "projects"),
        cursor_global_db=_env_or(
            "CONTEXT_CURSOR_GLOBAL_DB", cursor_user / "globalStorage" / "state.vscdb"
        ),
        cursor_workspaces=_env_or(
            "CONTEXT_CURSOR_WORKSPACES_DIR", cursor_user / "workspaceStorage"
        ),
        opencode_db=_env_or(
            "CONTEXT_OPENCODE_DB", h / ".local" / "share" / "opencode" / "opencode.db"
        ),
        workbuddy_dir=_env_or("CONTEXT_WORKBUDDY_DIR", h / ".workbuddy"),
        qclaw_dir=_env_or("CONTEXT_QCLAW_DIR", h / ".qclaw" / "agents"),
        deepseek_dir=_env_or("CONTEXT_DEEPSEEK_DIR", h / ".deepseek" / "sessions"),
    )


class AIChatCollector:
    """Incrementally syncs local AI coding & chat transcripts into Context Hub v2."""

    name = "ai_chat"
    source = "ai_chat"

    def __init__(
        self,
        paths: AIChatPaths | None = None,
        *,
        max_files_per_provider: int | None = None,
        since_days: float | None = None,
    ):
        if max_files_per_provider is not None and max_files_per_provider < 0:
            raise ValueError("max_files_per_provider must be >= 0 or None")
        if since_days is not None and since_days < 0:
            raise ValueError("since_days must be >= 0 or None")
        self.paths = paths or discover_default_paths()
        self.max_files_per_provider = max_files_per_provider
        self.since_days = since_days

    def _cutoff_ns(self) -> int | None:
        if self.since_days is None:
            return None
        return time.time_ns() - int(self.since_days * 86_400 * 1_000_000_000)

    def _db_within_since_days(self, db_path: Path) -> bool:
        cutoff_ns = self._cutoff_ns()
        if cutoff_ns is None:
            return True
        try:
            mtime_ns = db_path.stat().st_mtime_ns
        except OSError:
            return False
        wal_path = Path(f"{db_path}-wal")
        if wal_path.is_file():
            with suppress(OSError):
                mtime_ns = max(mtime_ns, wal_path.stat().st_mtime_ns)
        return mtime_ns >= cutoff_ns

    def _discover_antigravity_files(self) -> tuple[list[tuple[str, Path]], int]:
        root = self.paths.antigravity_brain
        if not root or not root.is_dir():
            return [], 0
        entries: list[tuple[int, str, Path]] = []
        for p in root.glob("*/.system_generated/logs/transcript.jsonl"):
            if p.is_file() and not p.is_symlink():
                try:
                    mtime_ns = p.stat().st_mtime_ns
                except OSError:
                    continue
                conv_id = p.parent.parent.parent.name
                entries.append((mtime_ns, conv_id, p))
        total = len(entries)
        entries.sort(key=lambda item: item[0], reverse=True)
        cutoff_ns = self._cutoff_ns()
        if cutoff_ns is not None:
            entries = [item for item in entries if item[0] >= cutoff_ns]
        if self.max_files_per_provider is not None:
            entries = entries[: self.max_files_per_provider]
        return [(conv_id, p) for _, conv_id, p in entries], total

    def _list_antigravity_files(self) -> list[tuple[str, Path]]:
        files, _ = self._discover_antigravity_files()
        return files

    def _discover_glob_files(
        self, root: Path | None, patterns: tuple[str, ...]
    ) -> tuple[list[Path], int]:
        if not root or not root.is_dir():
            return [], 0
        seen: set[Path] = set()
        entries: list[tuple[int, Path]] = []
        for pat in patterns:
            for p in root.glob(pat):
                if p in seen or not p.is_file() or p.is_symlink():
                    continue
                seen.add(p)
                try:
                    mtime_ns = p.stat().st_mtime_ns
                except OSError:
                    continue
                entries.append((mtime_ns, p))
        total = len(entries)
        entries.sort(key=lambda item: item[0], reverse=True)
        cutoff_ns = self._cutoff_ns()
        if cutoff_ns is not None:
            entries = [item for item in entries if item[0] >= cutoff_ns]
        if self.max_files_per_provider is not None:
            entries = entries[: self.max_files_per_provider]
        return [p for _, p in entries], total

    def _list_glob_files(self, root: Path | None, patterns: tuple[str, ...]) -> list[Path]:
        files, _ = self._discover_glob_files(root, patterns)
        return files

    def doctor(self) -> dict[str, Any]:
        checks: dict[str, Any] = {}
        p = self.paths
        ag, ag_total = self._discover_antigravity_files()
        checks["antigravity"] = {
            "path": str(p.antigravity_brain) if p.antigravity_brain else None,
            "available": ag_total > 0,
            "files": len(ag),
            "total_files": ag_total,
        }
        codex, codex_total = self._discover_glob_files(
            p.codex_sessions, ("**/*.jsonl", "**/*.jsonl.zst", "**/*.jsonl.zstd")
        )
        checks["codex"] = {
            "path": str(p.codex_sessions) if p.codex_sessions else None,
            "available": codex_total > 0,
            "files": len(codex),
            "total_files": codex_total,
        }
        claude, claude_total = self._discover_glob_files(p.claude_projects, ("**/*.jsonl",))
        checks["claude"] = {
            "path": str(p.claude_projects) if p.claude_projects else None,
            "available": claude_total > 0,
            "files": len(claude),
            "total_files": claude_total,
        }
        cursor_avail = bool(p.cursor_global_db and p.cursor_global_db.is_file())
        checks["cursor"] = {
            "path": str(p.cursor_global_db) if p.cursor_global_db else None,
            "available": cursor_avail,
        }
        if cursor_avail and self.since_days is not None and p.cursor_global_db is not None:
            checks["cursor"]["within_since_days"] = self._db_within_since_days(p.cursor_global_db)
        opencode_avail = bool(p.opencode_db and p.opencode_db.is_file())
        checks["opencode"] = {
            "path": str(p.opencode_db) if p.opencode_db else None,
            "available": opencode_avail,
        }
        if opencode_avail and self.since_days is not None and p.opencode_db is not None:
            checks["opencode"]["within_since_days"] = self._db_within_since_days(p.opencode_db)
        wb, wb_total = self._discover_glob_files(p.workbuddy_dir, ("**/*.jsonl",))
        checks["workbuddy"] = {
            "path": str(p.workbuddy_dir) if p.workbuddy_dir else None,
            "available": wb_total > 0,
            "files": len(wb),
            "total_files": wb_total,
        }
        qc, qc_total = self._discover_glob_files(p.qclaw_dir, ("**/*.jsonl",))
        checks["qclaw"] = {
            "path": str(p.qclaw_dir) if p.qclaw_dir else None,
            "available": qc_total > 0,
            "files": len(qc),
            "total_files": qc_total,
        }
        ds, ds_total = self._discover_glob_files(p.deepseek_dir, ("**/*.jsonl",))
        checks["deepseek"] = {
            "path": str(p.deepseek_dir) if p.deepseek_dir else None,
            "available": ds_total > 0,
            "files": len(ds),
            "total_files": ds_total,
        }
        return {
            "collector": self.name,
            "filters": {
                "since_days": self.since_days,
                "max_files_per_provider": self.max_files_per_provider,
            },
            "providers": checks,
        }

    def _emit(self, sink: HubSink, events: list[RawEventIn], report: SyncReport) -> bool:
        if not events:
            return True
        report.events_emitted += len(events)
        res = sink.emit_batch(self.name, events)
        report.created += res.get("created", 0)
        report.existing += res.get("existing", 0)
        report.spooled += res.get("spooled", 0)
        # Only advance checkpoint if events were accepted or safely spooled
        return True

    def _sync_incremental_jsonl(
        self,
        *,
        provider: str,
        path: Path,
        source_key: str,
        error_label: str,
        parse_fn: Any,
        sink: HubSink,
        checkpoints: CheckpointBackend,
        report: SyncReport,
        provider_counts: dict[str, int],
    ) -> None:
        report.sources_scanned += 1
        cp = checkpoints.get(self.name, source_key)
        try:
            while True:
                prev_offset = int((cp or {}).get("byte_offset") or 0)
                batch = read_incremental_jsonl(path, cp)
                report.skipped_errors += batch.skipped_errors
                if batch.unchanged:
                    report.sources_unchanged += 1
                    return
                prev_state = {} if batch.rotated else ((cp or {}).get("cursor") or {}).get("state") or {}
                events, next_state = parse_fn(batch.records, prev_state)
                self._emit(sink, events, report)
                provider_counts[provider] = provider_counts.get(provider, 0) + len(events)
                cp = checkpoints.put(
                    self.name,
                    source_key,
                    inode=batch.inode,
                    file_size=batch.file_size,
                    mtime_ns=batch.mtime_ns,
                    byte_offset=batch.next_offset,
                    cursor={"line_no": batch.next_line_no, "state": next_state},
                )
                # Continue draining within this pass if the file exceeded the per-batch line cap
                if (
                    len(batch.records) < 5000
                    or batch.next_offset >= batch.file_size
                    or batch.next_offset <= prev_offset
                ):
                    return
        except (OSError, ValueError) as exc:
            report.skipped_errors += 1
            report.errors.append(f"{error_label}: {exc}")

    def sync(self, sink: HubSink, checkpoints: CheckpointBackend) -> SyncReport:
        report = SyncReport(collector=self.name, source=self.source)
        enabled = self.paths.enabled_providers
        provider_counts: dict[str, int] = {}

        # 1. Antigravity (true incremental JSONL tailing)
        if "antigravity" in enabled:
            for conv_id, path in self._list_antigravity_files():
                self._sync_incremental_jsonl(
                    provider="antigravity",
                    path=path,
                    source_key=f"antigravity:{path}",
                    error_label=f"antigravity:{conv_id}",
                    parse_fn=lambda recs, st, cid=conv_id, p=path: parse_antigravity_records(
                        recs, conversation_id=cid, path=p, state=st
                    ),
                    sink=sink,
                    checkpoints=checkpoints,
                    report=report,
                    provider_counts=provider_counts,
                )

        # 2. Codex (stat-gated rollout parser with native/legacy wire dedup)
        if "codex" in enabled:
            for path in self._list_glob_files(
                self.paths.codex_sessions, ("**/*.jsonl", "**/*.jsonl.zst", "**/*.jsonl.zstd")
            ):
                report.sources_scanned += 1
                source_key = f"codex:{path}"
                cp = checkpoints.get(self.name, source_key)
                try:
                    st = path.stat()
                    if (
                        cp
                        and int(cp.get("inode") or 0) == st.st_ino
                        and int(cp.get("file_size") or 0) == st.st_size
                        and int(cp.get("mtime_ns") or 0) == st.st_mtime_ns
                    ):
                        report.sources_unchanged += 1
                        continue
                    events = parse_codex_file(path)
                    self._emit(sink, events, report)
                    provider_counts["codex"] = provider_counts.get("codex", 0) + len(events)
                    checkpoints.put(
                        self.name,
                        source_key,
                        inode=st.st_ino,
                        file_size=st.st_size,
                        mtime_ns=st.st_mtime_ns,
                        byte_offset=st.st_size,
                    )
                except (OSError, ValueError) as exc:
                    report.skipped_errors += 1
                    report.errors.append(f"codex:{path.name}: {exc}")

        # 3. Claude Code (true incremental JSONL tailing)
        if "claude" in enabled:
            for path in self._list_glob_files(self.paths.claude_projects, ("**/*.jsonl",)):
                self._sync_incremental_jsonl(
                    provider="claude",
                    path=path,
                    source_key=f"claude:{path}",
                    error_label=f"claude:{path.name}",
                    parse_fn=lambda recs, st, p=path: parse_claude_code_records(
                        recs, path=p, state=st
                    ),
                    sink=sink,
                    checkpoints=checkpoints,
                    report=report,
                    provider_counts=provider_counts,
                )

        # 4. WorkBuddy & QClaw (true incremental JSONL tailing)
        for prov, root in (
            ("workbuddy", self.paths.workbuddy_dir),
            ("qclaw", self.paths.qclaw_dir),
        ):
            if prov not in enabled:
                continue
            for path in self._list_glob_files(root, ("**/*.jsonl",)):
                self._sync_incremental_jsonl(
                    provider=prov,
                    path=path,
                    source_key=f"{prov}:{path}",
                    error_label=f"{prov}:{path.name}",
                    parse_fn=lambda recs, st, pr=prov, p=path: parse_workbuddy_or_qclaw_records(
                        pr, recs, path=p, state=st
                    ),
                    sink=sink,
                    checkpoints=checkpoints,
                    report=report,
                    provider_counts=provider_counts,
                )

        # 5. DeepSeek Harness (true incremental JSONL tailing)
        if "deepseek" in enabled:
            for path in self._list_glob_files(self.paths.deepseek_dir, ("**/*.jsonl",)):
                self._sync_incremental_jsonl(
                    provider="deepseek",
                    path=path,
                    source_key=f"deepseek:{path}",
                    error_label=f"deepseek:{path.name}",
                    parse_fn=lambda recs, st, p=path: parse_deepseek_records(
                        recs, path=p, state=st
                    ),
                    sink=sink,
                    checkpoints=checkpoints,
                    report=report,
                    provider_counts=provider_counts,
                )

        # 6. Cursor global state.vscdb (read-only incremental composer cursor)
        if (
            "cursor" in enabled
            and self.paths.cursor_global_db
            and self.paths.cursor_global_db.is_file()
            and self._db_within_since_days(self.paths.cursor_global_db)
        ):
            db_path = self.paths.cursor_global_db
            report.sources_scanned += 1
            source_key = f"cursor:{db_path}"
            cp = checkpoints.get(self.name, source_key)
            try:
                st = db_path.stat()
                if (
                    cp
                    and int(cp.get("inode") or 0) == st.st_ino
                    and int(cp.get("file_size") or 0) == st.st_size
                    and int(cp.get("mtime_ns") or 0) == st.st_mtime_ns
                ):
                    report.sources_unchanged += 1
                else:
                    seen_counts = ((cp or {}).get("cursor") or {}).get("composer_counts") or {}
                    events, next_counts = parse_cursor_db(
                        db_path,
                        workspaces_dir=self.paths.cursor_workspaces,
                        seen_header_counts=seen_counts,
                    )
                    self._emit(sink, events, report)
                    provider_counts["cursor"] = provider_counts.get("cursor", 0) + len(events)
                    checkpoints.put(
                        self.name,
                        source_key,
                        inode=st.st_ino,
                        file_size=st.st_size,
                        mtime_ns=st.st_mtime_ns,
                        cursor={"composer_counts": next_counts},
                    )
            except Exception as exc:  # noqa: BLE001
                report.skipped_errors += 1
                report.errors.append(f"cursor: {exc}")

        # 7. OpenCode SQLite DB (read-only incremental time_created cursor)
        if (
            "opencode" in enabled
            and self.paths.opencode_db
            and self.paths.opencode_db.is_file()
            and self._db_within_since_days(self.paths.opencode_db)
        ):
            db_path = self.paths.opencode_db
            report.sources_scanned += 1
            source_key = f"opencode:{db_path}"
            cp = checkpoints.get(self.name, source_key)
            try:
                st = db_path.stat()
                if (
                    cp
                    and int(cp.get("inode") or 0) == st.st_ino
                    and int(cp.get("file_size") or 0) == st.st_size
                    and int(cp.get("mtime_ns") or 0) == st.st_mtime_ns
                ):
                    report.sources_unchanged += 1
                else:
                    after_ts = int(((cp or {}).get("cursor") or {}).get("max_time_created") or 0)
                    events, next_ts = parse_opencode_db(db_path, after_time_created=after_ts)
                    self._emit(sink, events, report)
                    provider_counts["opencode"] = provider_counts.get("opencode", 0) + len(events)
                    checkpoints.put(
                        self.name,
                        source_key,
                        inode=st.st_ino,
                        file_size=st.st_size,
                        mtime_ns=st.st_mtime_ns,
                        cursor={"max_time_created": next_ts},
                    )
            except Exception as exc:  # noqa: BLE001
                report.skipped_errors += 1
                report.errors.append(f"opencode: {exc}")

        if report.skipped_errors > 0 and report.created == 0 and report.sources_scanned > 0:
            report.status = "degraded"
        summary = ", ".join(f"{k}:{v}" for k, v in sorted(provider_counts.items())) or "no new turns"
        report.watermark = f"scanned={report.sources_scanned},unchanged={report.sources_unchanged}"
        report.message = f"AI chat sync ({summary}); skipped_errors={report.skipped_errors}"
        return report
