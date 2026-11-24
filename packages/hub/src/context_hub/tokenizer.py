"""CJK + English hybrid tokenization & BM25 query planning for native SQLite FTS5."""

from __future__ import annotations

import re
import unicodedata

# Matches contiguous CJK Unified Ideographs (and common CJK extensions)
_CJK_RUN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+")
# Matches Latin/numeric/identifier tokens (keeps kebab-case/snake_case pieces searchable)
_WORD_RUN = re.compile(r"[a-z0-9][a-z0-9_.-]*")

# High-frequency English conversational/interrogative stopwords stripped during query planning
# (NEVER stripped from index_tokens so exact phrase/code lookups remain intact).
_EN_STOPWORDS = frozenset(
    {
        "a",
        "about",
        "above",
        "after",
        "again",
        "ago",
        "all",
        "also",
        "am",
        "an",
        "and",
        "any",
        "are",
        "as",
        "at",
        "be",
        "because",
        "been",
        "before",
        "being",
        "between",
        "both",
        "but",
        "by",
        "can",
        "could",
        "currently",
        "d",
        "did",
        "do",
        "does",
        "doing",
        "done",
        "during",
        "each",
        "either",
        "else",
        "even",
        "ever",
        "every",
        "few",
        "first",
        "for",
        "from",
        "get",
        "give",
        "go",
        "going",
        "got",
        "had",
        "has",
        "have",
        "having",
        "he",
        "her",
        "here",
        "hers",
        "him",
        "his",
        "how",
        "i",
        "if",
        "in",
        "into",
        "is",
        "it",
        "its",
        "just",
        "kind",
        "last",
        "like",
        "likely",
        "ll",
        "long",
        "m",
        "made",
        "make",
        "many",
        "may",
        "me",
        "might",
        "more",
        "most",
        "much",
        "must",
        "my",
        "name",
        "need",
        "never",
        "new",
        "no",
        "not",
        "now",
        "of",
        "off",
        "on",
        "one",
        "only",
        "or",
        "other",
        "our",
        "out",
        "over",
        "own",
        "please",
        "re",
        "recent",
        "recently",
        "s",
        "said",
        "same",
        "say",
        "see",
        "she",
        "should",
        "since",
        "so",
        "some",
        "still",
        "such",
        "t",
        "take",
        "tell",
        "than",
        "that",
        "the",
        "their",
        "them",
        "then",
        "there",
        "these",
        "they",
        "thing",
        "things",
        "this",
        "those",
        "through",
        "time",
        "to",
        "told",
        "too",
        "two",
        "under",
        "up",
        "us",
        "use",
        "used",
        "using",
        "ve",
        "very",
        "want",
        "was",
        "way",
        "we",
        "well",
        "went",
        "were",
        "what",
        "when",
        "where",
        "which",
        "while",
        "who",
        "whom",
        "whose",
        "why",
        "will",
        "with",
        "would",
        "you",
        "your",
        "yours",
    }
)

_ZH_STOPWORDS = frozenset(
    {
        "我们",
        "你们",
        "他们",
        "什么",
        "怎么",
        "如何",
        "为什么",
        "哪个",
        "哪些",
        "一下",
        "这个",
        "那个",
        "可以",
        "请问",
        "帮我",
        "之前",
        "上次",
        "现在",
        "目前",
        "还是",
        "以及",
        "因为",
        "所以",
        "如果",
        "但是",
        "然后",
        "已经",
        "就是",
        "一个",
        "没有",
        "不是",
        "打算",
        "准备",
        "有没有",
        "是不是",
    }
)


def normalize_text(text: str) -> str:
    return unicodedata.normalize("NFKC", text).casefold()


def _en_stem(word: str) -> str:
    """Lightweight deterministic English morphological stemmer for FTS5 query/index alignment."""
    if len(word) < 5 or not word.isalpha():
        return word
    if word.endswith("ies") and len(word) >= 5:
        return word[:-3] + "y"
    if word.endswith("ied") and len(word) >= 5:
        return word[:-3] + "y"
    if word.endswith("ing") and len(word) >= 6:
        stem = word[:-3]
        if len(stem) >= 4 and stem[-1] == stem[-2]:
            stem = stem[:-1]
        return stem
    if word.endswith("ed") and len(word) >= 5:
        stem = word[:-2]
        if len(stem) >= 4 and stem[-1] == stem[-2]:
            stem = stem[:-1]
        return stem
    if word.endswith("es") and len(word) >= 5 and word[-3] in {"s", "x", "z", "h"}:
        return word[:-2]
    if word.endswith("s") and not word.endswith(("ss", "us", "is")) and len(word) >= 5:
        return word[:-1]
    return word


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
        stem = _en_stem(word)
        if stem != word and len(stem) >= 3:
            tokens.append(stem)
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


def _extract_query_clauses(raw_query: str) -> tuple[list[str], int]:
    """Extract salient FTS5 clauses plus the count of distinct conceptual units."""
    norm = normalize_text(raw_query).strip()
    if not norm:
        return [], 0

    latin_all: list[str] = []
    latin_salient: list[str] = []
    seen_words: set[str] = set()

    for match in _WORD_RUN.finditer(norm):
        word = match.group(0).strip(".-_")
        if not word:
            continue
        safe = word.replace('"', "")
        if not safe or safe in seen_words:
            continue
        seen_words.add(safe)
        latin_all.append(safe)
        # Skip single-letter contraction debris and conversational stopwords
        if len(safe) == 1 and not safe.isdigit():
            continue
        if safe in _EN_STOPWORDS:
            continue
        latin_salient.append(safe)

    # Fall back to non-empty Latin words if every word was a stopword (e.g. query="go")
    chosen_latin = latin_salient if latin_salient else [w for w in latin_all if len(w) >= 2]

    clauses: list[str] = []
    seen_expr: set[str] = set()
    concept_count = 0

    for safe in chosen_latin:
        concept_count += 1
        stem = _en_stem(safe)
        if "." in safe:
            expr = f'"{safe}"'
        elif stem != safe and len(stem) >= 4:
            # Prefix on stem covers both inflected and base forms; include exact if stem diverges (e.g. stories -> story)
            expr = f'"{stem}"*' if safe.startswith(stem) else f'("{safe}" OR "{stem}"*)'
        elif len(safe) >= 3:
            expr = f'"{safe}"*'
        else:
            expr = f'"{safe}"'
        if expr not in seen_expr:
            seen_expr.add(expr)
            clauses.append(expr)

    cjk_runs = [m.group(0) for m in _CJK_RUN.finditer(norm)]
    for run in cjk_runs:
        if run in _ZH_STOPWORDS and (chosen_latin or len(cjk_runs) > 1):
            continue
        # Treat long Chinese natural-language sentences as multi-concept queries
        if len(run) >= 7:
            concept_count += max(2, len(run) // 4)
        else:
            concept_count += 1
        if len(run) == 1:
            expr = f'"{run}"'
            if expr not in seen_expr:
                seen_expr.add(expr)
                clauses.append(expr)
        else:
            run_bigrams: list[str] = []
            for i in range(len(run) - 1):
                bg = run[i : i + 2]
                if len(run) >= 7 and bg in _ZH_STOPWORDS:
                    continue
                run_bigrams.append(bg)
            if not run_bigrams:
                run_bigrams = [run[i : i + 2] for i in range(len(run) - 1)]
            for bg in run_bigrams:
                expr = f'"{bg}"'
                if expr not in seen_expr:
                    seen_expr.add(expr)
                    clauses.append(expr)

    return clauses[:24], concept_count


def fts_match_query(raw_query: str) -> str:
    """Convert a free-form Chinese/English query into a stopword-aware precision FTS5 `AND` query."""
    clauses, _ = _extract_query_clauses(raw_query)
    if not clauses:
        return ""
    return " AND ".join(clauses)


def fts_match_query_or(raw_query: str) -> str:
    """Build a BM25-ranked `OR` recall query for multi-concept natural-language queries.

    Returns `""` when the query contains only a single crisp concept (e.g., an exact CJK
    codeword like `"松针蓝七号"` or single identifier) so single-concept precision queries
    never fall back to noisy partial-bigram matches.
    """
    clauses, concept_count = _extract_query_clauses(raw_query)
    if len(clauses) < 2 or concept_count < 2:
        return ""
    return " OR ".join(clauses)
