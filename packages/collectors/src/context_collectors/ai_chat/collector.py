"""Incremental auto-discovering AI Chat Collector across macOS local Agent stores."""

from __future__ import annotations

import os
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
        max_files_per_provider: int = 400,
    ):
        self.paths = paths or discover_default_paths()
        self.max_files_per_provider = max_files_per_provider

    def _list_antigravity_files(self) -> list[tuple[str, Path]]:
        root = self.paths.antigravity_brain
        if not root or not root.is_dir():
            return []
        found: list[tuple[str, Path]] = []
        for p in root.glob("*/.system_generated/logs/transcript.jsonl"):
            if p.is_file() and not p.is_symlink():
                conv_id = p.parent.parent.parent.name
                found.append((conv_id, p))
        found.sort(key=lambda pair: pair[1].stat().st_mtime_ns, reverse=True)
        return found[: self.max_files_per_provider]

    def _list_glob_files(self, root: Path | None, patterns: tuple[str, ...]) -> list[Path]:
        if not root or not root.is_dir():
            return []
        files: list[Path] = []
        for pat in patterns:
            for p in root.glob(pat):
                if p.is_file() and not p.is_symlink():
                    files.append(p)
        files.sort(key=lambda p: p.stat().st_mtime_ns, reverse=True)
        return files[: self.max_files_per_provider]

    def doctor(self) -> dict[str, Any]:
        checks: dict[str, Any] = {}
        p = self.paths
        ag = self._list_antigravity_files()
        checks["antigravity"] = {
            "path": str(p.antigravity_brain) if p.antigravity_brain else None,
            "available": bool(ag),
            "files": len(ag),
        }
        codex = self._list_glob_files(p.codex_sessions, ("**/*.jsonl", "**/*.jsonl.zst", "**/*.jsonl.zstd"))
        checks["codex"] = {
            "path": str(p.codex_sessions) if p.codex_sessions else None,
            "available": bool(codex),
            "files": len(codex),
        }
        claude = self._list_glob_files(p.claude_projects, ("**/*.jsonl",))
        checks["claude"] = {
            "path": str(p.claude_projects) if p.claude_projects else None,
            "available": bool(claude),
            "files": len(claude),
        }
        checks["cursor"] = {
            "path": str(p.cursor_global_db) if p.cursor_global_db else None,
            "available": bool(p.cursor_global_db and p.cursor_global_db.is_file()),
        }
        checks["opencode"] = {
            "path": str(p.opencode_db) if p.opencode_db else None,
            "available": bool(p.opencode_db and p.opencode_db.is_file()),
        }
        wb = self._list_glob_files(p.workbuddy_dir, ("**/*.jsonl", "*.jsonl"))
        checks["workbuddy"] = {
            "path": str(p.workbuddy_dir) if p.workbuddy_dir else None,
            "available": bool(wb),
            "files": len(wb),
        }
        qc = self._list_glob_files(p.qclaw_dir, ("*.jsonl", "**/*.jsonl"))
        checks["qclaw"] = {
            "path": str(p.qclaw_dir) if p.qclaw_dir else None,
            "available": bool(qc),
            "files": len(qc),
        }
        ds = self._list_glob_files(p.deepseek_dir, ("*.jsonl", "**/*.jsonl"))
        checks["deepseek"] = {
            "path": str(p.deepseek_dir) if p.deepseek_dir else None,
            "available": bool(ds),
            "files": len(ds),
        }
        return {"collector": self.name, "providers": checks}

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

    def sync(self, sink: HubSink, checkpoints: CheckpointBackend) -> SyncReport:
        report = SyncReport(collector=self.name, source=self.source)
        enabled = self.paths.enabled_providers
        provider_counts: dict[str, int] = {}

        # 1. Antigravity (true incremental JSONL tailing)
        if "antigravity" in enabled:
            for conv_id, path in self._list_antigravity_files():
                report.sources_scanned += 1
                source_key = f"antigravity:{path}"
                cp = checkpoints.get(self.name, source_key)
                try:
                    batch = read_incremental_jsonl(path, cp)
                    report.skipped_errors += batch.skipped_errors
                    if batch.unchanged:
                        report.sources_unchanged += 1
                        continue
                    prev_state = {} if batch.rotated else ((cp or {}).get("cursor") or {}).get("state") or {}
                    events, next_state = parse_antigravity_records(
                        batch.records, conversation_id=conv_id, path=path, state=prev_state
                    )
                    self._emit(sink, events, report)
                    provider_counts["antigravity"] = provider_counts.get("antigravity", 0) + len(events)
                    checkpoints.put(
                        self.name,
                        source_key,
                        inode=batch.inode,
                        file_size=batch.file_size,
                        mtime_ns=batch.mtime_ns,
                        byte_offset=batch.next_offset,
                        cursor={"line_no": batch.next_line_no, "state": next_state},
                    )
                except (OSError, ValueError) as exc:
                    report.skipped_errors += 1
                    report.errors.append(f"antigravity:{conv_id}: {exc}")

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
                report.sources_scanned += 1
                source_key = f"claude:{path}"
                cp = checkpoints.get(self.name, source_key)
                try:
                    batch = read_incremental_jsonl(path, cp)
                    report.skipped_errors += batch.skipped_errors
                    if batch.unchanged:
                        report.sources_unchanged += 1
                        continue
                    prev_state = {} if batch.rotated else ((cp or {}).get("cursor") or {}).get("state") or {}
                    events, next_state = parse_claude_code_records(
                        batch.records, path=path, state=prev_state
                    )
                    self._emit(sink, events, report)
                    provider_counts["claude"] = provider_counts.get("claude", 0) + len(events)
                    checkpoints.put(
                        self.name,
                        source_key,
                        inode=batch.inode,
                        file_size=batch.file_size,
                        mtime_ns=batch.mtime_ns,
                        byte_offset=batch.next_offset,
                        cursor={"line_no": batch.next_line_no, "state": next_state},
                    )
                except (OSError, ValueError) as exc:
                    report.skipped_errors += 1
                    report.errors.append(f"claude:{path.name}: {exc}")

        # 4. WorkBuddy & QClaw (true incremental JSONL tailing)
        for prov, root in (
            ("workbuddy", self.paths.workbuddy_dir),
            ("qclaw", self.paths.qclaw_dir),
        ):
            if prov not in enabled:
                continue
            for path in self._list_glob_files(root, ("**/*.jsonl", "*.jsonl")):
                report.sources_scanned += 1
                source_key = f"{prov}:{path}"
                cp = checkpoints.get(self.name, source_key)
                try:
                    batch = read_incremental_jsonl(path, cp)
                    report.skipped_errors += batch.skipped_errors
                    if batch.unchanged:
                        report.sources_unchanged += 1
                        continue
                    prev_state = {} if batch.rotated else ((cp or {}).get("cursor") or {}).get("state") or {}
                    events, next_state = parse_workbuddy_or_qclaw_records(
                        prov, batch.records, path=path, state=prev_state
                    )
                    self._emit(sink, events, report)
                    provider_counts[prov] = provider_counts.get(prov, 0) + len(events)
                    checkpoints.put(
                        self.name,
                        source_key,
                        inode=batch.inode,
                        file_size=batch.file_size,
                        mtime_ns=batch.mtime_ns,
                        byte_offset=batch.next_offset,
                        cursor={"line_no": batch.next_line_no, "state": next_state},
                    )
                except (OSError, ValueError) as exc:
                    report.skipped_errors += 1
                    report.errors.append(f"{prov}:{path.name}: {exc}")

        # 5. DeepSeek Harness (true incremental JSONL tailing)
        if "deepseek" in enabled:
            for path in self._list_glob_files(self.paths.deepseek_dir, ("**/*.jsonl", "*.jsonl")):
                report.sources_scanned += 1
                source_key = f"deepseek:{path}"
                cp = checkpoints.get(self.name, source_key)
                try:
                    batch = read_incremental_jsonl(path, cp)
                    report.skipped_errors += batch.skipped_errors
                    if batch.unchanged:
                        report.sources_unchanged += 1
                        continue
                    prev_state = {} if batch.rotated else ((cp or {}).get("cursor") or {}).get("state") or {}
                    events, next_state = parse_deepseek_records(
                        batch.records, path=path, state=prev_state
                    )
                    self._emit(sink, events, report)
                    provider_counts["deepseek"] = provider_counts.get("deepseek", 0) + len(events)
                    checkpoints.put(
                        self.name,
                        source_key,
                        inode=batch.inode,
                        file_size=batch.file_size,
                        mtime_ns=batch.mtime_ns,
                        byte_offset=batch.next_offset,
                        cursor={"line_no": batch.next_line_no, "state": next_state},
                    )
                except (OSError, ValueError) as exc:
                    report.skipped_errors += 1
                    report.errors.append(f"deepseek:{path.name}: {exc}")

        # 6. Cursor global state.vscdb (read-only incremental composer cursor)
        if "cursor" in enabled and self.paths.cursor_global_db and self.paths.cursor_global_db.is_file():
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
        if "opencode" in enabled and self.paths.opencode_db and self.paths.opencode_db.is_file():
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
