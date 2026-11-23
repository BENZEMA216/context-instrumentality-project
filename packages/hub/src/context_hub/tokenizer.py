"""CJK + English hybrid tokenization for native SQLite FTS5 indexing & querying."""

from __future__ import annotations

import re
import unicodedata

# Matches contiguous CJK Unified Ideographs (and common CJK extensions)
_CJK_RUN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+")
# Matches Latin/numeric/identifier tokens (keeps kebab-case/snake_case pieces searchable)
_WORD_RUN = re.compile(r"[a-z0-9][a-z0-9_.-]*")


def normalize_text(text: str) -> str:
    return unicodedata.normalize("NFKC", text).casefold()


def index_tokens(text: str) -> str:
    """Produce FTS5-indexable text supporting 1-char, 2-char, and multi-char CJK + English."""
    if not text:
        return ""
    norm = normalize_text(text)
    tokens: list[str] = []

    for match in _WORD_RUN.finditer(norm):
        word = match.group(0).strip(".-_")
        if not word:
            continue
        tokens.append(word)
        if any(sep in word for sep in (".", "-", "_")):
            for sub in re.split(r"[._-]+", word):
                if sub and sub != word:
                    tokens.append(sub)

    for match in _CJK_RUN.finditer(norm):
        run = match.group(0)
        # Emit all bigrams for crisp 2+ char matching and individual chars for 1-char queries.
        for ch in run:
            tokens.append(ch)
        for i in range(len(run) - 1):
            tokens.append(run[i : i + 2])

    return " ".join(tokens)


def fts_match_query(raw_query: str) -> str:
    """Convert a free-form Chinese/English user query into a safe FTS5 MATCH expression."""
    norm = normalize_text(raw_query).strip()
    if not norm:
        return ""

    clauses: list[str] = []
    seen: set[str] = set()

    for match in _WORD_RUN.finditer(norm):
        word = match.group(0).strip(".-_")
        if not word:
            continue
        # Escape quotes just in case and allow prefix match on >=3 char Latin tokens
        safe = word.replace('"', "")
        if not safe:
            continue
        expr = f'"{safe}"*' if len(safe) >= 3 and "." not in safe else f'"{safe}"'
        if expr not in seen:
            seen.add(expr)
            clauses.append(expr)

    for match in _CJK_RUN.finditer(norm):
        run = match.group(0)
        if len(run) == 1:
            expr = f'"{run}"'
            if expr not in seen:
                seen.add(expr)
                clauses.append(expr)
        else:
            for i in range(len(run) - 1):
                bg = run[i : i + 2]
                expr = f'"{bg}"'
                if expr not in seen:
                    seen.add(expr)
                    clauses.append(expr)

    if not clauses:
        return ""
    # Bound terms to keep FTS5 planning fast even on long queries
    return " AND ".join(clauses[:24])
