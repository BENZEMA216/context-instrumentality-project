"""Lightweight Local Entity-Concept Bipartite Graph & Multi-Hop Query Planner (v0.8).

Designed for 100% local CPU execution (zero cloud LLM calls, < 5 ms per query) inside SQLite:
  1. **Entity & Concept Anchor Extraction**: Extracts speakers, capitalized proper nouns,
     acronyms, and salient bilingual (EN/ZH) content anchors from raw turns, memories, and
     episodes into the `entity_edges` bipartite table (`entity <-> item_id`).
  2. **Syntactic Multi-Hop Query Planning (`analyze_query_structure`)**:
     - Detects plural/aggregation/cross-entity multi-hop queries (`is_multi_hop`) and
       counterfactual/preference inference queries (`is_open_inference`).
     - Decomposes dual-entity predicates (`"X and Y both ..."`) and binary choices
       (`"more interested in A or B"`) into clean entity-scoped sub-queries.
  3. **2-Hop Associative Bridge Expansion (RM3 / HippoRAG-inspired)**:
     - Extracts highest-IDF co-occurring bridge concepts from Hop-1 evidence turns and walks
       the SQLite entity graph (`graph_bridge_walk`) to surface multi-session / indirect hits.
  4. **Soft Cross-Session Diversity (`diversify_by_group`)**:
     - Prevents a single chatty session from consuming all Top-5 slots on multi-session /
       multi-hop queries, lifting multi-gold All-Recall@5 without hurting single-hop precision.
"""

from __future__ import annotations

import math
import re
from collections import Counter
from dataclasses import dataclass, field

_EN_SENTENCE_STARTERS = frozenset(
    {
        "the",
        "a",
        "an",
        "what",
        "which",
        "who",
        "whom",
        "whose",
        "where",
        "when",
        "why",
        "how",
        "would",
        "could",
        "should",
        "will",
        "can",
        "may",
        "might",
        "must",
        "did",
        "does",
        "do",
        "has",
        "have",
        "had",
        "is",
        "are",
        "was",
        "were",
        "yes",
        "no",
        "hey",
        "hi",
        "hello",
        "thanks",
        "thank",
        "yeah",
        "yep",
        "nah",
        "wow",
        "well",
        "oh",
        "ok",
        "okay",
        "sure",
        "great",
        "awesome",
        "nice",
        "cool",
        "good",
        "that",
        "this",
        "these",
        "those",
        "there",
        "here",
        "it",
        "its",
        "they",
        "their",
        "them",
        "we",
        "our",
        "you",
        "your",
        "he",
        "she",
        "his",
        "her",
        "my",
        "me",
        "i",
        "and",
        "but",
        "or",
        "so",
        "if",
        "then",
        "because",
        "although",
        "though",
        "while",
        "after",
        "before",
        "since",
        "during",
        "for",
        "from",
        "with",
        "about",
        "into",
        "onto",
        "also",
        "just",
        "still",
        "even",
        "really",
        "very",
        "last",
        "next",
        "yesterday",
        "today",
        "tomorrow",
        "recently",
        "lately",
        "actually",
        "honestly",
        "maybe",
        "probably",
        "definitely",
        "absolutely",
        "totally",
        "personally",
        "unfortunately",
        "fortunately",
        "finally",
        "suddenly",
        "anyway",
        "meanwhile",
        "besides",
        "however",
        "therefore",
        "monday",
        "tuesday",
        "wednesday",
        "thursday",
        "friday",
        "saturday",
        "sunday",
        "january",
        "february",
        "march",
        "april",
        "june",
        "july",
        "august",
        "september",
        "october",
        "november",
        "december",
        "user",
        "assistant",
        "session",
        "image",
        "photo",
        "picture",
        "fact",
        "summary",
        "prev",
        "turn",
        "earlier",
        "reply",
        "am",
        "pm",
    }
)

_EN_CONTENT_STOPWORDS = _EN_SENTENCE_STARTERS | frozenset(
    {
        "been",
        "being",
        "more",
        "most",
        "some",
        "many",
        "much",
        "other",
        "another",
        "such",
        "only",
        "same",
        "different",
        "than",
        "over",
        "under",
        "again",
        "both",
        "each",
        "every",
        "all",
        "any",
        "none",
        "like",
        "likes",
        "liked",
        "want",
        "wants",
        "wanted",
        "know",
        "think",
        "feel",
        "make",
        "made",
        "take",
        "took",
        "give",
        "gave",
        "going",
        "went",
        "gone",
        "come",
        "came",
        "getting",
        "got",
        "said",
        "says",
        "saying",
        "told",
        "tell",
        "talk",
        "talked",
        "talking",
        "mentioned",
        "mention",
        "look",
        "looking",
        "looked",
        "seems",
        "seem",
        "around",
        "through",
        "things",
        "thing",
        "something",
        "anything",
        "everything",
        "nothing",
        "someone",
        "anyone",
        "everyone",
        "people",
        "person",
        "time",
        "times",
        "year",
        "years",
        "month",
        "months",
        "week",
        "weeks",
        "day",
        "days",
        "kind",
        "kinds",
        "type",
        "types",
        "way",
        "ways",
        "part",
        "parts",
        "lot",
        "lots",
        "bit",
        "little",
        "pretty",
        "quite",
        "always",
        "never",
        "often",
        "sometimes",
        "usually",
        "likely",
        "considered",
        "interested",
        "prefer",
        "pursue",
        "option",
        "based",
        "between",
        "among",
        "does",
        "doing",
        "done",
        "have",
        "having",
        "using",
        "used",
        "help",
        "work",
        "working",
        "tried",
        "trying",
        "start",
        "started",
        "keep",
        "kept",
        "best",
        "better",
        "well",
        "long",
        "still",
        "back",
        "down",
        "away",
        "ever",
        "soon",
        "already",
        "almost",
        "enough",
        "though",
        "whether",
        "without",
        "within",
        "across",
        "along",
        "against",
        "above",
        "below",
        "behind",
        "beside",
        "near",
        "toward",
        "towards",
        "until",
        "upon",
        "where",
        "while",
        "whose",
        "which",
        "whom",
        "what",
        "when",
        "sounds",
        "sound",
        "love",
        "loved",
        "loving",
        "hope",
        "glad",
        "happy",
        "sorry",
        "please",
        "thankful",
        "amazing",
        "wonderful",
        "super",
        "totally",
        "definitely",
        "actually",
    }
)

_PROPER_PHRASE_RE = re.compile(
    r"\b(?:[A-Z][a-z]{1,20}|[A-Z]{2,8})(?:\s+(?:[A-Z][a-z]{1,20}|[A-Z]{2,8}))*\b"
)
_EN_WORD_RE = re.compile(r"[a-zA-Z][a-zA-Z0-9'-]{2,}")
_ZH_CHUNK_RE = re.compile(r"[\u4e00-\u9fff]{2,6}")
_DUAL_ENTITY_RE = re.compile(
    r"\b([A-Z][a-z]{2,18})\s+and\s+([A-Z][a-z]{2,18})\b"
)
_OR_CHOICE_RE = re.compile(
    r"\b(?:prefer|interested in|choose|rather|go to|going to|between|like|enjoy)\s+"
    r"([^?.,;]{3,42}?)\s+or\s+([^?.,;]{3,42}?)(?:[?.,;]|$)",
    re.I,
)
_MULTI_HOP_RE = re.compile(
    r"\b(?:both|all (?:the )?|how many|total|altogether|combined|compare|list|"
    r"in what ways|what are (?:some |the )?|"
    r"what (?:[a-z0-9+'-]+\s+){0,2}(?:kinds?|types?|fields?|events?|activities|hobbies|"
    r"things|items|books|movies|artists|bands|songs|places|cities|countries|sports|games|"
    r"pets|animals|foods|traits|qualities|topics|projects|classes|courses|instruments|"
    r"skills|jobs|roles|colors|paintings|subjects?|symbols?|changes|names|reasons|ways)|"
    r"(?:what|where) (?:has|have|did|do|does) .{1,40}\b(?:painted|read|watched|visited|"
    r"played|seen|attended|joined|made|done|bought|eaten|collected|liked|like|"
    r"participated|camped|traveled|gone|tried|learned))\b"
    r"|哪些|分别|一共|总共|都有|都做过|同时|共同",
    re.I,
)
_OPEN_INFERENCE_RE = re.compile(
    r"^\s*would\b|"
    r"\b(?:likely|probably|prefer|pursue|considered|more interested in|"
    r"personality traits?|political leaning|might\b.*\b(?:say|think|find interesting|prefer|like)|"
    r"recommend\b.*\b(?:interesting|prefer|should i))\b"
    r"|可能会|更倾向于|性格特点|推荐.*感兴趣",
    re.I,
)


def _norm_token(tok: str) -> str:
    s = tok.strip().strip("'\"").casefold()
    if s.endswith("'s"):
        s = s[:-2]
    # Light singularization for entity/concept matching
    if len(s) > 4 and s.endswith("ies"):
        s = s[:-3] + "y"
    elif len(s) > 4 and s.endswith("s") and not s.endswith(("ss", "us", "is")):
        s = s[:-1]
    return s


@dataclass
class QueryPlan:
    query: str
    entities: list[str] = field(default_factory=list)
    is_multi_hop: bool = False
    is_open_inference: bool = False
    sub_queries: list[str] = field(default_factory=list)


def extract_query_entities(query: str) -> list[str]:
    """Extract clean named entities / proper nouns from a natural-language query."""
    found: list[str] = []
    seen: set[str] = set()
    q = (query or "").strip()
    if not q:
        return found

    for m in _PROPER_PHRASE_RE.finditer(q):
        raw = m.group(0).strip()
        parts = raw.split()
        # Strip leading sentence-starter stopword if part of a phrase (e.g., "What Caroline")
        while parts and parts[0].casefold() in _EN_SENTENCE_STARTERS:
            parts.pop(0)
        if not parts:
            continue
        cleaned = " ".join(parts)
        norm = _norm_token(cleaned)
        if len(norm) >= 2 and norm not in _EN_SENTENCE_STARTERS and norm not in seen:
            seen.add(norm)
            found.append(norm)
        # Also index individual tokens of a multi-word entity
        if len(parts) > 1:
            for p in parts:
                np = _norm_token(p)
                if len(np) >= 3 and np not in _EN_SENTENCE_STARTERS and np not in seen:
                    seen.add(np)
                    found.append(np)

    # Chinese 2-4 char chunks (useful for CJK entity anchoring)
    for m in _ZH_CHUNK_RE.finditer(q):
        tok = m.group(0)
        if tok not in seen:
            seen.add(tok)
            found.append(tok)

    return found[:8]


def extract_anchors(
    text: str,
    *,
    actor: str | None = None,
    extra_tags: list[str] | None = None,
    max_anchors: int = 24,
) -> list[tuple[str, float]]:
    """Extract weighted `(anchor, weight)` pairs for the SQLite entity-concept bipartite graph."""
    weights: dict[str, float] = {}

    def _add(key: str, w: float) -> None:
        if not key or len(key) < 2 or key in _EN_SENTENCE_STARTERS:
            return
        if w > weights.get(key, 0.0):
            weights[key] = w

    if actor:
        na = _norm_token(actor)
        if na and na not in {"self", "user", "assistant", "system", "unknown"}:
            _add(na, 1.8)

    for tag in extra_tags or []:
        nt = _norm_token(str(tag))
        if nt and not nt.startswith("session_") and nt not in _EN_CONTENT_STOPWORDS:
            _add(nt, 1.5)

    body = (text or "")[:1600]
    # 1. Proper nouns & acronyms
    for m in _PROPER_PHRASE_RE.finditer(body):
        parts = m.group(0).split()
        while parts and parts[0].casefold() in _EN_SENTENCE_STARTERS:
            parts.pop(0)
        if not parts:
            continue
        phrase = _norm_token(" ".join(parts))
        if len(phrase) >= 2 and phrase not in _EN_SENTENCE_STARTERS:
            _add(phrase, 1.5 if len(parts) > 1 else 1.3)
        if len(parts) > 1:
            for p in parts:
                np = _norm_token(p)
                if len(np) >= 3 and np not in _EN_SENTENCE_STARTERS:
                    _add(np, 1.2)

    # 2. Salient content words (TF-capped, non-stopword)
    word_counts: Counter[str] = Counter()
    for m in _EN_WORD_RE.finditer(body):
        nw = _norm_token(m.group(0))
        if len(nw) >= 4 and nw not in _EN_CONTENT_STOPWORDS:
            word_counts[nw] += 1
    for tok, cnt in word_counts.most_common(14):
        _add(tok, min(1.1, 0.72 + 0.12 * min(cnt, 3)))

    # 3. CJK salient phrases
    zh_counts: Counter[str] = Counter()
    for m in _ZH_CHUNK_RE.finditer(body):
        zh_counts[m.group(0)] += 1
    for tok, _ in zh_counts.most_common(8):
        _add(tok, 1.1)

    ranked = sorted(weights.items(), key=lambda kv: kv[1], reverse=True)
    return ranked[:max_anchors]


def analyze_query_structure(query: str) -> QueryPlan:
    """Detect multi-hop / open-inference intent and generate syntactic entity sub-queries."""
    q = (query or "").strip()
    entities = extract_query_entities(q)
    is_open = bool(_OPEN_INFERENCE_RE.search(q))
    is_multi = bool(_MULTI_HOP_RE.search(q))

    sub_queries: list[str] = []
    seen_sq: set[str] = set()

    def _push_sq(sq: str) -> None:
        cleaned = re.sub(r"\s+", " ", sq).strip(" ?.,")
        if cleaned and cleaned.casefold() != q.casefold() and cleaned.casefold() not in seen_sq:
            seen_sq.add(cleaned.casefold())
            sub_queries.append(cleaned)

    # 1. Dual-entity decomposition: "What subject have Caroline and Melanie both painted?"
    #    -> ["Caroline painted subject", "Melanie painted subject"]
    m_dual = _DUAL_ENTITY_RE.search(q)
    if m_dual:
        e1, e2 = m_dual.group(1), m_dual.group(2)
        if (
            e1.casefold() not in _EN_SENTENCE_STARTERS
            and e2.casefold() not in _EN_SENTENCE_STARTERS
        ):
            is_multi = True
            # Remove the other entity and "both" to form each entity's clean sub-query
            rest = _DUAL_ENTITY_RE.sub("__ENT__", q, count=1)
            rest = re.sub(r"\bboth\b", "", rest, flags=re.I)
            _push_sq(rest.replace("__ENT__", e1))
            _push_sq(rest.replace("__ENT__", e2))

    # 2. Binary choice decomposition: "Would Melanie prefer a national park or a theme park?"
    #    -> ["Melanie national park", "Melanie theme park"]
    m_or = _OR_CHOICE_RE.search(q)
    if m_or:
        opt_a = m_or.group(1).strip()
        opt_b = m_or.group(2).strip()
        prefix = " ".join(entities[:2])
        if opt_a and opt_b and len(opt_a) <= 40 and len(opt_b) <= 40:
            _push_sq(f"{prefix} {opt_a}".strip())
            _push_sq(f"{prefix} {opt_b}".strip())

    # 3. Open-inference framing strip: strip "Would X likely / be considered / pursue..."
    #    to expose the core entity + topic terms cleanly
    if is_open and entities and len(sub_queries) < 2:
        core_words = [
            m.group(0)
            for m in _EN_WORD_RE.finditer(q)
            if _norm_token(m.group(0)) not in _EN_CONTENT_STOPWORDS
        ]
        if core_words:
            _push_sq(" ".join(dict.fromkeys(core_words[:8])))

    return QueryPlan(
        query=q,
        entities=entities,
        is_multi_hop=is_multi,
        is_open_inference=is_open,
        sub_queries=sub_queries[:3],
    )


def extract_bridge_terms(
    query: str,
    seed_texts: list[str],
    *,
    df_map: dict[str, int],
    total_docs: int,
    max_terms: int = 5,
) -> list[str]:
    """RM3-style Pseudo-Relevance bridge term extraction from Hop-1 retrieved evidence.

    Selects discriminative (mid-IDF) concepts present across Hop-1 hits that are NOT already
    in the original query, enabling Hop-2 retrieval to bridge zero-overlap conceptual gaps.
    """
    q_norms = {_norm_token(m.group(0)) for m in _EN_WORD_RE.finditer(query or "")}
    q_norms |= set(_ZH_CHUNK_RE.findall(query or ""))

    term_tf: Counter[str] = Counter()
    term_seed_df: Counter[str] = Counter()
    for rank, txt in enumerate(seed_texts[:6]):
        weight = 1.0 / (1.0 + 0.35 * rank)
        seen_in_doc: set[str] = set()
        for anc, aw in extract_anchors(txt, max_anchors=16):
            if anc in q_norms or anc in _EN_CONTENT_STOPWORDS or len(anc) < 3:
                continue
            # Prefer single salient terms or compact proper phrases
            if " " in anc and len(anc) > 22:
                continue
            if anc not in seen_in_doc:
                seen_in_doc.add(anc)
                term_seed_df[anc] += 1
                term_tf[anc] += weight * aw

    max_df = max(12, int(0.24 * max(1, total_docs)))
    scored: list[tuple[str, float]] = []
    for term, tf_w in term_tf.items():
        df = df_map.get(term, 1)
        if df < 2 or df > max_df:
            continue
        idf = math.log(1.0 + (total_docs + 1.0) / (df + 1.0))
        # Reward concepts echoed by >=2 Hop-1 hits slightly higher
        consensus = 1.25 if term_seed_df[term] >= 2 else 1.0
        scored.append((term, tf_w * idf * consensus))

    scored.sort(key=lambda kv: kv[1], reverse=True)
    return [t for t, _ in scored[:max_terms]]


def diversify_by_group(
    scored_items: list[tuple[str, float]],
    group_of: dict[str, str],
    *,
    decay_second: float = 0.84,
    decay_rest: float = 0.66,
    top_k: int = 10,
) -> list[tuple[str, float]]:
    """Greedy soft-cap diversification across sessions/groups for multi-hop recall.

    Preserves Rank #1 untouched, gently discounts repeated turns from the same session so
    2nd and 3rd hops residing in OTHER sessions enter Top-5 / Top-10 cleanly.
    """
    if len(scored_items) <= 2:
        return list(scored_items[:top_k])

    remaining = list(scored_items)
    selected: list[tuple[str, float]] = []
    group_counts: dict[str, int] = {}

    while remaining and len(selected) < top_k:
        best_idx = 0
        best_eff = -1e18
        for idx, (item_id, base_sc) in enumerate(remaining):
            grp = group_of.get(item_id, "")
            cnt = group_counts.get(grp, 0) if grp else 0
            mult = 1.0 if cnt == 0 else (decay_second if cnt == 1 else decay_rest)
            eff = base_sc * mult
            if eff > best_eff:
                best_eff = eff
                best_idx = idx
        chosen_id, chosen_base = remaining.pop(best_idx)
        selected.append((chosen_id, round(best_eff, 6) if chosen_base >= 0 else chosen_base))
        grp = group_of.get(chosen_id, "")
        if grp:
            group_counts[grp] = group_counts.get(grp, 0) + 1

    return selected
