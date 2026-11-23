"""L0 Immutable Append-Only Raw Event Archive (HPI-inspired replayable storage)."""

from __future__ import annotations

import datetime
import json
import os
from collections.abc import Iterator
from pathlib import Path
from typing import Any


class RawLog:
    """Append-only raw JSONL archive partitioned by UTC date and source channel."""

    def __init__(self, root: Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.tombstones_path = self.root / "_tombstones.jsonl"

    def _bucket_path(self, source: str, t_start_ms: int) -> Path:
        dt = datetime.datetime.fromtimestamp(max(0, t_start_ms) / 1000.0, tz=datetime.UTC)
        safe_source = source.replace("/", "_").replace("..", "_")
        folder = self.root / f"{dt.year:04d}" / f"{dt.month:02d}" / f"{dt.day:02d}"
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        return folder / f"{safe_source}.jsonl"

    def append(self, event: dict[str, Any]) -> Path:
        path = self._bucket_path(event["source"], int(event["t_start"]))
        line = json.dumps(event, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
        with path.open("a", encoding="utf-8") as fh:
            fh.write(line)
            fh.flush()
            os.fsync(fh.fileno())
        return path

    def record_tombstone(self, event_id: str, deleted_at_ms: int) -> None:
        entry = {"id": event_id, "deleted_at": deleted_at_ms}
        line = json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n"
        with self.tombstones_path.open("a", encoding="utf-8") as fh:
            fh.write(line)
            fh.flush()
            os.fsync(fh.fileno())

    def deleted_ids(self) -> set[str]:
        if not self.tombstones_path.is_file():
            return set()
        ids: set[str] = set()
        with self.tombstones_path.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ids.add(json.loads(line)["id"])
                except (ValueError, KeyError):
                    continue
        return ids

    def iter_events(self) -> Iterator[dict[str, Any]]:
        """Stream all non-tombstoned raw events in chronological file order for L1 rebuild."""
        tombstones = self.deleted_ids()
        for path in sorted(self.root.rglob("*.jsonl")):
            if path.name.startswith("_"):
                continue
            with path.open("r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if event.get("id") in tombstones:
                        continue
                    yield event
