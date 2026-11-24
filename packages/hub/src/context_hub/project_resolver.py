"""Deterministic, human-readable Project Attribution & Slug Normalization.

Replaces opaque `workspace/<uuid>` hashes, OS/toolchain paths, `$HOME/.git` accidents,
and temporary git worktree slugs with clean canonical project names via:
1. Local git root & worktree parent-repo detection (strictly stopping below `$HOME`).
2. Ignored system/toolchain path filtering (Xcode, `/Library`, `/usr`, `.gemini`, etc.).
3. Exact aliases and regex `patterns` configured in `<data_dir>/project_aliases.json`.
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
    "developer",
    "chatgpt",
    "google",
    "lib",
    "usr",
    "bin",
    "sbin",
    "etc",
    "opt",
    "data",
    "应用",
    "applications",
    "library",
    "volumes",
    "contents",
    "resources",
    "build",
    "dist",
    "venv",
    ".venv",
    "scratch",
    "logs",
    "homebrew",
    "growth",
    "node_modules",
}

_IGNORED_PATH_MARKERS = (
    ".app/contents/",
    "/system/library/",
    "/library/developer/",
    "/library/application support/",
    "/usr/lib/",
    "/usr/local/",
    "/opt/homebrew/",
    "/.gemini/antigravity/brain/",
    "/.codex/sessions/",
    "/.claude/projects/",
    "/node_modules/",
)

_GITHUB_REPO_RE = re.compile(
    r"https?://(?:www\.)?(?:github\.com|gitlab\.com)/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)"
)
_OPAQUE_PROJECT_RE = re.compile(r"^(?:workspace|unassigned|project)/[0-9a-f-]{16,}$", re.I)
_HEX_FRAGMENT_RE = re.compile(r"^(?:[0-9a-f]{2,12}|[0-9a-f]{6,8}-[0-9a-f]{1,6})$", re.I)


def _is_user_home_dir(path: Path) -> bool:
    """Return True if path is `/` or `/Users` or `/Users/<user>` or `/home/<user>` or `$HOME`."""
    try:
        resolved = path.resolve()
        home_resolved = Path.home().resolve()
        if resolved == home_resolved:
            return True
    except OSError:
        pass
    parts = [p for p in path.parts if p not in ("/", "\\")]
    if len(parts) <= 1:
        return True
    return len(parts) == 2 and parts[0].lower() in ("users", "home")


def _is_ignored_system_path(text: str) -> bool:
    low = text.replace("\\", "/").lower()
    if any(marker in low for marker in _IGNORED_PATH_MARKERS):
        return True
    return low.startswith(("/system/", "/usr/", "/opt/", "/applications/", "/bin/", "/sbin/"))


def _resolve_worktree_parent_repo(git_file: Path) -> str | None:
    """If `.git` is a git worktree pointer file, return the main repository directory name."""
    try:
        first_line = git_file.read_text(encoding="utf-8", errors="ignore").splitlines()[0].strip()
    except (OSError, IndexError):
        return None
    if not first_line.lower().startswith("gitdir:"):
        return None
    gitdir = Path(first_line.split(":", 1)[1].strip())
    if not gitdir.is_absolute():
        gitdir = (git_file.parent / gitdir).resolve()
    parts = list(gitdir.parts)
    for idx, part in enumerate(parts):
        if part == ".git" and idx >= 1:
            return normalize_project_slug(parts[idx - 1])
    return None


def _local_home_username() -> str:
    return Path.home().name.strip().lower()


def normalize_project_slug(value: str, *, allow_home_username: bool = False) -> str | None:
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
    # Reject 1-char ASCII slugs (e.g. "b") and truncated hex/UUID fragments (e.g. "2f5", "2f56fc3b-0e")
    if len(cleaned) == 1 and cleaned.isascii():
        return None
    if _HEX_FRAGMENT_RE.match(cleaned) and any(ch.isdigit() for ch in cleaned):
        return None
    if not allow_home_username and cleaned == _local_home_username():
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

    if _is_ignored_system_path(text):
        return None

    p = Path(text)
    if _is_user_home_dir(p):
        return None

    # If the path exists locally on disk, walk upward to find the nearest git repo root,
    # strictly stopping BEFORE `$HOME` so a dotfiles `~/.git` never hijacks unrelated projects.
    try:
        if p.exists():
            curr = p if p.is_dir() else p.parent
            for _ in range(6):
                if _is_user_home_dir(curr):
                    break
                dot_git = curr / ".git"
                if dot_git.is_file():
                    wt_parent = _resolve_worktree_parent_repo(dot_git)
                    if wt_parent:
                        return wt_parent
                if dot_git.exists():
                    slug = normalize_project_slug(curr.name)
                    if slug:
                        return slug
                if curr.parent == curr:
                    break
                curr = curr.parent
    except OSError:
        pass

    # Fallback: take the last non-generic path component (ignoring user home segment)
    parts = [part for part in p.parts if part and part not in ("/", "\\")]
    home_name = _local_home_username()
    for idx in range(len(parts) - 1, -1, -1):
        part = parts[idx]
        if idx == 1 and parts[0].lower() in ("users", "home"):
            continue
        # Skip filenames with extensions when a parent folder exists (except meaningful stems)
        if "." in part and len(parts) > 1 and not part.startswith("."):
            stem = Path(part).stem
            # Keep meaningful project-like document stems only if parent is generic (e.g. Growth/fatesense-seo-playbook.md)
            parent_slug = normalize_project_slug(parts[idx - 1]) if idx > 0 else None
            if parent_slug is None:
                stem_slug = normalize_project_slug(stem)
                if stem_slug:
                    return stem_slug
            continue
        if part.strip().lower() == home_name and idx > 1 and parts[idx - 1].lower() == "obsidian":
            return "obsidian"
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
    """Resolves canonical project names from explicit metadata, paths, URLs, aliases & patterns."""

    def __init__(self, alias_file: Path | None = None):
        self.alias_file = alias_file
        self._aliases: dict[str, str] = {}
        self._patterns: list[tuple[re.Pattern[str], str]] = []
        self.reload_aliases()

    def reload_aliases(self) -> None:
        self._aliases = {}
        self._patterns = []
        if self.alias_file and self.alias_file.is_file():
            try:
                data = json.loads(self.alias_file.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    raw_aliases = data.get("aliases") if isinstance(data.get("aliases"), dict) else data
                    for k, v in raw_aliases.items():
                        if k == "patterns":
                            continue
                        if isinstance(k, str) and isinstance(v, str):
                            nk = normalize_project_slug(k, allow_home_username=True) or k.strip().lower()
                            nv = normalize_project_slug(v)
                            if nk and nv:
                                self._aliases[nk] = nv
                    raw_patterns = data.get("patterns")
                    if isinstance(raw_patterns, list):
                        for item in raw_patterns:
                            if not isinstance(item, dict):
                                continue
                            pat = item.get("match")
                            target = item.get("target")
                            if isinstance(pat, str) and isinstance(target, str):
                                nt = normalize_project_slug(target)
                                if nt:
                                    try:
                                        self._patterns.append((re.compile(pat, re.I), nt))
                                    except re.error:
                                        continue
            except (OSError, ValueError):
                pass

    def apply_alias(self, slug: str | None) -> str | None:
        if not slug:
            return None
        low = slug.strip().lower()
        if low in self._aliases:
            return self._aliases[low]
        for regex, target in self._patterns:
            if regex.match(low):
                return target
        return slug

    def _apply_alias(self, slug: str | None) -> str | None:
        return self.apply_alias(slug)

    def resolve(
        self,
        event: dict[str, Any],
        anchors: list[str] | None = None,
        *,
        prefer_path: bool = False,
    ) -> str | None:
        context = event.get("context") or {}
        content = event.get("content") or {}

        def _from_paths() -> str | None:
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
            return None

        def _from_explicit() -> str | None:
            for cand in (event.get("project"), context.get("project")):
                if isinstance(cand, str) and cand.strip():
                    if "/" in cand and cand.startswith("/"):
                        from_p = project_from_path(cand)
                        if from_p:
                            return self._apply_alias(from_p)
                    slug = normalize_project_slug(cand)
                    if slug:
                        return self._apply_alias(slug)
            return None

        if prefer_path:
            # Used during project reconciliation so a stale/polluted stored slug (e.g. from ~/.git)
            # yields to the real underlying cwd/repo path when available.
            if resolved := _from_paths():
                return resolved
            if resolved := _from_explicit():
                return resolved
        else:
            if resolved := _from_explicit():
                return resolved
            if resolved := _from_paths():
                return resolved

        # 3. URL / locator pointing to GitHub/GitLab repo
        for cand in (
            content.get("url_norm"),
            content.get("url"),
            content.get("source_url"),
            context.get("source_url"),
            (event.get("provenance") or {}).get("locator"),
        ):
            if isinstance(cand, str):
                from_u = project_from_url(cand)
                if from_u:
                    return self._apply_alias(from_u)

        # 4. Anchors (`repo:owner/name` -> `project:...` -> `path:...`)
        for anchor in anchors or []:
            if anchor.startswith("repo:"):
                slug = normalize_project_slug(anchor)
                if slug:
                    return self._apply_alias(slug)
        for anchor in anchors or []:
            if anchor.startswith("project:"):
                slug = normalize_project_slug(anchor)
                if slug:
                    return self._apply_alias(slug)
            elif anchor.startswith("path:"):
                from_p = project_from_path(anchor[len("path:") :])
                if from_p:
                    return self._apply_alias(from_p)

        return None
