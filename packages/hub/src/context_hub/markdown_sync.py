"""L2 Human & Obsidian Readable Markdown Artifact Generator with YAML Frontmatter."""

from __future__ import annotations

import datetime
import os
import re
import tempfile
from pathlib import Path
from typing import Any

import yaml


def _slug(value: str, max_len: int = 48) -> str:
    cleaned = re.sub(r"[^\w\u4e00-\u9fff-]+", "-", value.strip()).strip("-").lower()
    return (cleaned[:max_len].strip("-")) or "untitled"


def _iso_utc(ms: int) -> str:
    dt = datetime.datetime.fromtimestamp(max(0, ms) / 1000.0, tz=datetime.UTC)
    return dt.isoformat().replace("+00:00", "Z")


def _date_str(ms: int) -> str:
    dt = datetime.datetime.fromtimestamp(max(0, ms) / 1000.0, tz=datetime.UTC)
    return dt.strftime("%Y-%m-%d")


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(
        dir=path.parent, mode="w", encoding="utf-8", delete=False, prefix=".md-"
    ) as tmp:
        tmp_path = Path(tmp.name)
        try:
            tmp.write(text)
            tmp.flush()
            os.fsync(tmp.fileno())
        except BaseException:
            tmp_path.unlink(missing_ok=True)
            raise
    os.replace(tmp_path, path)


def _render_doc(frontmatter: dict[str, Any], body: str) -> str:
    fm = yaml.safe_dump(frontmatter, allow_unicode=True, sort_keys=False).strip()
    return f"---\n{fm}\n---\n\n{body.strip()}\n"


class MarkdownSync:
    """Maintains clean L2 Markdown files synchronized from Hub L1/L2/L3 records."""

    def __init__(self, root: Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)

    def write_episode(
        self,
        episode: dict[str, Any],
        events: list[dict[str, Any]],
        decisions: list[dict[str, Any]],
    ) -> str:
        t_start = int(episode["t_start"])
        dt = datetime.datetime.fromtimestamp(max(0, t_start) / 1000.0, tz=datetime.UTC)
        short_id = episode["id"][-8:]
        filename = f"{dt.strftime('%Y-%m-%d')}-{_slug(episode['title'])}-{short_id}.md"
        rel_path = Path("episodes") / f"{dt.year:04d}" / f"{dt.month:02d}" / filename

        fm = {
            "id": episode["id"],
            "type": "episode",
            "title": episode["title"],
            "project": episode.get("project") or "unassigned",
            "status": episode["status"],
            "privacy_tier": episode["privacy_tier"],
            "primary_source": episode.get("primary_source") or "mixed",
            "t_start": _iso_utc(t_start),
            "t_end": _iso_utc(int(episode["t_end"])),
            "entities": episode.get("entities") or [],
            "evidence_count": len(events),
            "curated_by": episode.get("curated_by"),
            "revision": episode["revision"],
        }

        lines = [f"# {episode['title']}", ""]
        if episode.get("summary"):
            lines += ["## 摘要", "", episode["summary"], ""]
        if episode.get("overview"):
            lines += ["## 整理详述", "", episode["overview"], ""]
        if decisions:
            lines += ["## 关联决策", ""]
            for d in decisions:
                badge = "生效" if d["status"] == "active" else d["status"]
                lines.append(
                    f"- **[{badge} · {d['authority']}] {d['topic']}**：{d['statement']} (`{d['id']}`)"
                )
            lines.append("")

        lines += ["## 原始证据时间线", ""]
        for ev in events:
            snippet = (ev.get("body_text") or ev.get("title") or "(仅元数据)").replace("\n", " ")
            if len(snippet) > 220:
                snippet = snippet[:219].rstrip() + "…"
            locator = ev.get("locator") or ev["id"]
            lines.append(
                f"- `{_iso_utc(int(ev['t_start']))}` · **{ev['source']}** ({ev.get('actor') or 'unknown'}) — {snippet}  \n"
                f"  `raw_id: {ev['id']}` · `locator: {locator}`"
            )

        _atomic_write(self.root / rel_path, _render_doc(fm, "\n".join(lines)))
        return rel_path.as_posix()

    def write_project(
        self,
        project: str,
        decisions: list[dict[str, Any]],
        episodes: list[dict[str, Any]],
        memories: list[dict[str, Any]],
    ) -> str:
        rel_path = Path("projects") / f"{_slug(project, 64)}.md"
        active = [d for d in decisions if d["status"] == "active"]
        history = [d for d in decisions if d["status"] != "active"]

        fm = {
            "type": "project",
            "project": project,
            "active_decisions": len(active),
            "episodes": len(episodes),
            "memories": len(memories),
        }

        lines = [f"# 项目档案 · {project}", "", "## 当前生效决策", ""]
        if active:
            for d in active:
                ev_str = ", ".join(f"`{eid}`" for eid in d.get("evidence_ids", [])[:5])
                lines.append(
                    f"- **{d['topic']}** (`{d['authority']}` · `{_date_str(int(d['valid_at']))}`): {d['statement']}  \n"
                    f"  证据：{ev_str}"
                )
        else:
            lines.append("_暂无已整理决策。_")

        if history:
            lines += ["", "## 历史变更记录（Superseded）", ""]
            for d in history:
                sup = f" → 被 `{d['superseded_by']}` 取代" if d.get("superseded_by") else ""
                lines.append(
                    f"- ~~**{d['topic']}**：{d['statement']}~~ (`{d['status']}`{sup})"
                )

        if memories:
            lines += ["", "## 项目记忆与经验", ""]
            for m in memories[:30]:
                lines.append(f"- **[{m['kind']}] {m['title']}**：{m['body']}")

        lines += ["", "## 近期情景（Episodes）", ""]
        for ep in episodes[:30]:
            summary = ep.get("summary") or "(待 Agent 整理)"
            lines.append(
                f"- `{_date_str(int(ep['t_start']))}` **{ep['title']}** (`{ep['status']}`) — {summary}"
            )

        _atomic_write(self.root / rel_path, _render_doc(fm, "\n".join(lines)))
        return rel_path.as_posix()

    def write_daily(
        self,
        date_str: str,
        episodes: list[dict[str, Any]],
        decisions: list[dict[str, Any]],
    ) -> str:
        rel_path = Path("daily") / f"{date_str}.md"
        fm = {
            "type": "daily",
            "date": date_str,
            "episodes": len(episodes),
            "decisions": len(decisions),
        }
        lines = [f"# 每日上下文摘要 · {date_str}", ""]
        if decisions:
            lines += ["## 当日决策与变更", ""]
            for d in decisions:
                lines.append(
                    f"- **[{d['project']}] {d['topic']}** ({d['authority']}): {d['statement']}"
                )
            lines.append("")

        lines += ["## 情景时间线", ""]
        if episodes:
            for ep in episodes:
                proj = ep.get("project") or "未归属项目"
                summary = ep.get("summary") or "(待整理)"
                lines.append(
                    f"### {ep['title']} · `{proj}` ({ep['status']})\n\n"
                    f"- 时间：`{_iso_utc(int(ep['t_start']))}` ~ `{_iso_utc(int(ep['t_end']))}`\n"
                    f"- 摘要：{summary}\n"
                )
        else:
            lines.append("_当日暂无记录。_")

        _atomic_write(self.root / rel_path, _render_doc(fm, "\n".join(lines)))
        return rel_path.as_posix()

    def list_files(self) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        for path in sorted(self.root.rglob("*.md")):
            if path.name.startswith("."):
                continue
            stat = path.stat()
            rel = path.relative_to(self.root).as_posix()
            category = rel.split("/", 1)[0] if "/" in rel else "root"
            results.append(
                {
                    "path": rel,
                    "category": category,
                    "size_bytes": stat.st_size,
                    "updated_at": int(stat.st_mtime * 1000),
                }
            )
        results.sort(key=lambda r: r["updated_at"], reverse=True)
        return results

    def read_file(self, relative_path: str) -> str:
        target = (self.root / relative_path).resolve()
        if not target.is_relative_to(self.root.resolve()) or not target.is_file():
            raise FileNotFoundError("Markdown artifact not found")
        return target.read_text(encoding="utf-8")
