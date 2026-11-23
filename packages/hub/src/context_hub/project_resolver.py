"""Deterministic, human-readable Project Attribution & Slug Normalization.

Replaces opaque `workspace/<uuid>` hashes with readable canonical project slugs derived
from filesystem paths (walking upward for `.git` when local), GitHub/GitLab URLs,
anchors, or user-configured project aliases.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit

_GENERIC_DIRS = {
    "",
    "/",
    "users",
    "home",
    "desktop",
    "downloads",
    "documents",
    "tmp",
    "var",
    "private",
    "work",
    "workspace",
    "workspaces",
    "projects",
    "repos",
    "src",
    "code",
    "dev",
    "chatgpt",
}

_GITHUB_REPO_RE = re.compile(
    r"https?://(?:www\.)?(?:github\.com|gitlab\.com)/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)"
)
_OPAQUE_PROJECT_RE = re.compile(r"^(?:workspace|unassigned|project)/[0-9a-f-]{16,}$", re.I)


def normalize_project_slug(value: str) -> str | None:
    """Normalize an arbitrary project string into a clean, readable canonical slug."""
    raw = value.strip()
    if not raw or _OPAQUE_PROJECT_RE.match(raw):
        return None
    # Strip trailing .git or leading project:/repo: prefix
    if raw.startswith("project:"):
        raw = raw[len("project:") :]
    elif raw.startswith("repo:"):
        raw = raw.split("/")[-1]
    if raw.endswith(".git"):
        raw = raw[:-4]
    cleaned = re.sub(r"[^\w\u4e00-\u9fff.-]+", "-", raw).strip("-.").lower()
    if not cleaned or cleaned in _GENERIC_DIRS:
        return None
    return cleaned[:64]


def project_from_path(raw_path: str | None) -> str | None:
    """Extract a readable project slug from a local directory path or `file://` URI."""
    if not raw_path or not isinstance(raw_path, str):
        return None
    text = raw_path.strip()
    if not text:
        return None
    if text.startswith("file://"):
        parsed = urlsplit(text)
        if parsed.netloc not in ("", "localhost"):
            return None
        text = unquote(parsed.path)

    p = Path(text)
    # If the path exists locally on disk, walk upward to find the nearest git repo root
    try:
        if p.exists():
            curr = p if p.is_dir() else p.parent
            for _ in range(6):
                if (curr / ".git").exists():
                    slug = normalize_project_slug(curr.name)
                    if slug:
                        return slug
                if curr.parent == curr:
                    break
                curr = curr.parent
    except OSError:
        pass

    # Fallback: take the last non-generic path component
    parts = [part for part in p.parts if part and part not in ("/", "\\")]
    for part in reversed(parts):
        # Skip filenames with extensions when a parent folder exists
        if "." in part and len(parts) > 1 and not part.startswith("."):
            continue
        slug = normalize_project_slug(part)
        if slug:
            return slug
    return None


def project_from_url(url: str | None) -> str | None:
    """Derive a canonical project slug from a GitHub/GitLab repository URL."""
    if not url or not isinstance(url, str):
        return None
    m = _GITHUB_REPO_RE.search(url)
    if m:
        return normalize_project_slug(m.group(2))
    return None


class ProjectResolver:
    """Resolves canonical project names from explicit metadata, paths, URLs, and aliases."""

    def __init__(self, alias_file: Path | None = None):
        self.alias_file = alias_file
        self._aliases: dict[str, str] = {}
        self.reload_aliases()

    def reload_aliases(self) -> None:
        self._aliases = {}
        if self.alias_file and self.alias_file.is_file():
            try:
                data = json.loads(self.alias_file.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    for k, v in data.items():
                        if isinstance(k, str) and isinstance(v, str):
                            nk = normalize_project_slug(k) or k.strip().lower()
                            nv = normalize_project_slug(v)
                            if nk and nv:
                                self._aliases[nk] = nv
            except (OSError, ValueError):
                pass

    def _apply_alias(self, slug: str | None) -> str | None:
        if not slug:
            return None
        return self._aliases.get(slug, slug)

    def resolve(self, event: dict[str, Any], anchors: list[str] | None = None) -> str | None:
        context = event.get("context") or {}
        content = event.get("content") or {}

        # 1. Explicit project (only if readable, not an opaque workspace/<uuid> hash)
        for cand in (event.get("project"), context.get("project")):
            if isinstance(cand, str) and cand.strip():
                if "/" in cand and cand.startswith("/"):
                    from_p = project_from_path(cand)
                    if from_p:
                        return self._apply_alias(from_p)
                slug = normalize_project_slug(cand)
                if slug:
                    return self._apply_alias(slug)

        # 2. Explicit workspace / cwd path
        for cand in (
            context.get("cwd"),
            context.get("workspace"),
            context.get("workspace_path"),
            context.get("repo_root"),
        ):
            if isinstance(cand, str):
                from_p = project_from_path(cand)
                if from_p:
                    return self._apply_alias(from_p)

        # 3. URL / locator pointing to GitHub/GitLab repo
        for cand in (
            content.get("url_norm"),
            content.get("url"),
            (event.get("provenance") or {}).get("locator"),
        ):
            if isinstance(cand, str):
                from_u = project_from_url(cand)
                if from_u:
                    return self._apply_alias(from_u)

        # 4. Anchors (`project:...` or `repo:owner/name` or `path:...`)
        for anchor in anchors or []:
            if anchor.startswith(("project:", "repo:")):
                slug = normalize_project_slug(anchor)
                if slug:
                    return self._apply_alias(slug)
            elif anchor.startswith("path:"):
                from_p = project_from_path(anchor[len("path:") :])
                if from_p:
                    return self._apply_alias(from_p)

        return None
