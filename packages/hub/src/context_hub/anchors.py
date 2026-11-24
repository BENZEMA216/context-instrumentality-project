"""Deterministic URL canonicalization and cross-channel anchor extraction."""

from __future__ import annotations

import re
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

TRACKING_PARAMS = {
    "utm_source",
    "utm_medium",
    "utm_campaign",
    "utm_term",
    "utm_content",
    "utm_id",
    "fbclid",
    "gclid",
    "mc_cid",
    "mc_eid",
    "spm",
    "spm_id_from",
    "vd_source",
    "from",
    "isappinstalled",
    "share_source",
}

SENSITIVE_QUERY_KEYS = {
    "token",
    "access_token",
    "refresh_token",
    "auth",
    "code",
    "secret",
    "api_key",
    "apikey",
    "key",
    "password",
    "passwd",
    "session",
    "session_id",
    "sig",
    "signature",
}

_URL_RE = re.compile(
    r"https?://[^\s<>\"'`()\[\]{}\u3000-\u303f\uff00-\uffef\u4e00-\u9fff]+", re.I
)
_GH_REPO_RE = re.compile(r"github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)")
_ISSUE_KEY_RE = re.compile(r"\b([A-Z]{2,8}-\d{1,6})\b")
_UNIX_PATH_RE = re.compile(r"(?:^|[\s`'(])(/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+){2,})")


def canonicalize_url(raw_url: str) -> str:
    """Normalize URL for deterministic Promnesia-style matching and strip secret/tracking params."""
    raw_url = raw_url.strip().rstrip(".,;:!?)'\"`")
    try:
        parts = urlsplit(raw_url)
        port = parts.port
    except ValueError:
        return raw_url
    if parts.scheme.lower() not in ("http", "https") or not parts.hostname:
        return raw_url

    host = parts.hostname.lower()
    if host.startswith("www."):
        host = host[4:]
    netloc = host if port in (None, 80, 443) else f"{host}:{port}"

    path = re.sub(r"/{2,}", "/", parts.path or "/")
    if path != "/" and path.endswith("/"):
        path = path[:-1]

    cleaned_query: list[tuple[str, str]] = []
    for k, v in parse_qsl(parts.query, keep_blank_values=False):
        kl = k.lower()
        if kl in TRACKING_PARAMS or kl in SENSITIVE_QUERY_KEYS or kl.startswith("utm_"):
            continue
        cleaned_query.append((k, v))
    cleaned_query.sort()
    query = urlencode(cleaned_query)

    return urlunsplit(("https", netloc, path, query, ""))


def extract_anchors(event: dict[str, Any]) -> list[str]:
    """Deterministically extract cross-channel join anchors from an event."""
    anchors: set[str] = set()
    for existing in event.get("anchors") or []:
        if isinstance(existing, str) and existing.strip():
            anchors.add(existing.strip())

    content = event.get("content") or {}
    context = event.get("context") or {}

    urls: list[str] = []
    for key in ("url_norm", "url", "source_url"):
        val = content.get(key)
        if isinstance(val, str) and val.strip():
            urls.append(val.strip())
    ctx_source_url = context.get("source_url")
    if isinstance(ctx_source_url, str) and ctx_source_url.strip():
        urls.append(ctx_source_url.strip())

    text_blobs = [
        str(content.get("title") or ""),
        str(content.get("text") or ""),
        str(content.get("summary") or ""),
        str(context.get("window_title") or ""),
    ]
    for ex in content.get("excerpts") or []:
        if isinstance(ex, dict) and ex.get("text"):
            text_blobs.append(str(ex["text"]))
    joined = "\n".join(text_blobs)

    for m in _URL_RE.finditer(joined):
        urls.append(m.group(0))

    for u in list(dict.fromkeys(urls))[:20]:
        norm = canonicalize_url(u)
        anchors.add(f"url:{norm}")
        try:
            parsed = urlsplit(norm)
            hostname = parsed.hostname
        except ValueError:
            hostname = None
        if hostname:
            anchors.add(f"domain:{hostname}")
        gh = _GH_REPO_RE.search(norm)
        if gh:
            repo = gh.group(1).removesuffix(".git").lower()
            anchors.add(f"repo:{repo}")

    for m in _ISSUE_KEY_RE.finditer(joined):
        anchors.add(f"issue:{m.group(1)}")

    for m in _UNIX_PATH_RE.finditer(joined):
        p = m.group(1)
        if len(p) <= 180 and not p.startswith(("/api/", "/v1/", "/v2/", "/static/")):
            anchors.add(f"path:{p}")

    project = event.get("project") or context.get("project")
    if isinstance(project, str) and project.strip():
        anchors.add(f"project:{project.strip().lower()}")

    return sorted(anchors)[:64]
