"""Compression Fidelity, Exchange-Pair Provenance & Anti-Noise Durability Inspector for Raw Memory.

Measures THREE complementary axes of curated Memory quality:
1. **Claim-to-Evidence Precision (`claim_support_rate`)**:
   Extracts every concrete factual token (versions/numbers/sizes, domains, technical/product
   identifiers) from a compressed Decision or Memory and verifies whether each token is
   actually present inside its cited verbatim Raw Evidence (`evidence_ids`).
2. **Anti-Noise & Durability Hygiene (`durability_hygiene_rate`)** — Meta Benchmark Pillar #4:
   Flags three proven real-world memory pollution failure modes calibrated from human adjudication:
   - `volatile_status_snapshot`: transient external status (Build NNN, App Store 提审进度, PR #N)
     that should live as a `Project Profile` live lookup pointer instead of L3 memory.
   - `duplicate_of:<id>`: Decision <-> Memory near-duplicate restating the same fact.
   - `isolated_short_reply`: short elliptical `ai_chat` user reply (< 28 chars) cited without
     its preceding conversational Q&A turn.
3. **Episode Omission Recall (`high_signal_coverage_rate`)**:
   Scans every curated Episode's raw events for `actor='self'` high-signal turns and surfaces
   potentially omitted user constraints/nuances.

When `include_quotes=True`, each cited `ai_chat` evidence entry also includes its
conversational exchange window (`±1` adjacent turns within the same session/episode) so
humans and auditing agents always see full Q&A context rather than isolated sentences.
"""

from __future__ import annotations

import json
import re
import sqlite3
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field

from context_hub.models import now_ms

_DOMAIN_RE = re.compile(
    r"\b[a-z0-9](?:[a-z0-9-]{0,40}[a-z0-9])?\.(?:app|ai|dev|com|org|io|net|md|py|swift|json|sqlite3?)\b",
    re.I,
)
_VERSION_OR_NUM_RE = re.compile(r"\bv?\d+(?:\.\d+)*(?:\s*(?:GB|MB|KB|MiB|GiB|ms|mm|%))?\b", re.I)
_IDENT_RE = re.compile(r"\b[A-Za-z][A-Za-z0-9_.-]{2,}\b")

# Transient external operational snapshots that belong in L1/L2 logs or Project Profile pointers, not L3 Memory
_VOLATILE_SNAPSHOT_RE = re.compile(
    r"(?:\bbuild\s*\d+\b|提审|重新提审|挂载\s*build|内测推进|\bpr\s*#\d+\b|testflight\s*build\s*\d+|ci\s*(?:通过|失败))",
    re.I,
)

_GENERIC_CLAIM_WORDS = {
    "app",
    "build",
    "phase",
    "meta",
    "raw",
    "memory",
    "agent",
    "for",
    "and",
    "the",
    "with",
    "from",
    "macos",
    "ios",
    "watch",
    "store",
    "benchmark",
    "memory.md",
    "v1",
    "v2",
}


class ClaimCheckItem(BaseModel):
    item_id: str
    item_kind: str  # "decision" | "memory"
    status: str
    authority: str
    project: str | None
    topic_or_title: str
    statement: str
    evidence_ids: list[str]
    evidence_actors: list[str]
    evidence_quotes: list[dict[str, Any]] = Field(default_factory=list)
    extracted_claims: list[str] = Field(default_factory=list)
    supported_claims: list[str] = Field(default_factory=list)
    unsupported_claims: list[str] = Field(default_factory=list)
    claim_support_rate: float = 1.0
    noise_flags: list[str] = Field(default_factory=list)


class EpisodeOmissionItem(BaseModel):
    episode_id: str
    project: str | None
    title: str
    total_events: int
    human_turns: int
    high_signal_human_turns: int
    covered_high_signal_turns: int
    coverage_rate: float
    omitted_turns: list[dict[str, Any]] = Field(default_factory=list)


class FidelityReport(BaseModel):
    data_dir: str
    audited_at_ms: int
    avg_claim_support_rate: float
    total_claims_checked: int
    total_unsupported_claims: int
    durability_hygiene_rate: float = 1.0
    total_noise_flags: int = 0
    project_profiles_count: int = 0
    avg_episode_signal_coverage: float
    items: list[ClaimCheckItem] = Field(default_factory=list)
    episode_omissions: list[EpisodeOmissionItem] = Field(default_factory=list)


def _norm(text: str) -> str:
    return unicodedata.normalize("NFKC", text).casefold()


def _char_bigrams(text: str) -> set[str]:
    compact = re.sub(r"[\s\W_]+", "", _norm(text))
    if len(compact) < 2:
        return {compact} if compact else set()
    return {compact[i : i + 2] for i in range(len(compact) - 1)}


def _bigram_jaccard(a: str, b: str) -> float:
    sa = _char_bigrams(a)
    sb = _char_bigrams(b)
    if not sa or not sb:
        return 0.0
    return len(sa & sb) / len(sa | sb)


def extract_verifiable_claims(text: str) -> list[str]:
    """Extract concrete numbers/versions/domains/technical identifiers from a compressed statement."""
    claims: list[str] = []
    seen: set[str] = set()

    def _add(tok: str) -> None:
        cleaned = tok.strip(".,;:()[]{}\"'`")
        low = _norm(cleaned)
        if not low or low in _GENERIC_CLAIM_WORDS or low in seen:
            return
        if low.isdigit() and len(low) == 1:
            return
        seen.add(low)
        claims.append(cleaned)

    for m in _DOMAIN_RE.finditer(text):
        _add(m.group(0))
    for m in _VERSION_OR_NUM_RE.finditer(text):
        _add(m.group(0))
    for m in _IDENT_RE.finditer(text):
        tok = m.group(0)
        if any(ch.isupper() for ch in tok) or any(ch in "-_." for ch in tok):
            _add(tok)

    return claims


def _claim_supported_in_text(claim: str, evidence_norm: str) -> bool:
    low = _norm(claim)
    if low in evidence_norm:
        return True
    compact_claim = re.sub(r"[\s_-]+", "", low)
    compact_ev = re.sub(r"[\s_-]+", "", evidence_norm)
    if len(compact_claim) >= 3 and compact_claim in compact_ev:
        return True
    return bool(low.startswith("v") and len(low) > 2 and low[1:] in evidence_norm)


def inspect_compression_fidelity(
    data_dir: Path,
    *,
    include_quotes: bool = False,
    project: str | None = None,
) -> FidelityReport:
    """Inspect Claim-to-Evidence precision, Anti-Noise durability hygiene, and Episode omissions."""
    root = Path(data_dir).expanduser()
    db_path = root / "hub.sqlite3"
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    try:
        raw_map: dict[str, dict[str, Any]] = {}
        ep_ordered_raws: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for r in conn.execute(
            "SELECT id, source, actor, episode_id, t_start, title, body_text, privacy_tier, event_json "
            "FROM raw_events WHERE deleted = 0 ORDER BY t_start ASC, id ASC"
        ):
            rd = dict(r)
            ctx = json.loads(rd["event_json"] or "{}").get("context") or {}
            rd["_session_id"] = ctx.get("session_id")
            rd["_signal_hints"] = ctx.get("signal_hints") or []
            raw_map[rd["id"]] = rd
            if rd.get("episode_id") and rd["privacy_tier"] != "local_only":
                ep_ordered_raws[rd["episode_id"]].append(rd)

        dec_ev: dict[str, list[str]] = defaultdict(list)
        for r in conn.execute("SELECT decision_id, raw_id FROM decision_evidence"):
            dec_ev[r["decision_id"]].append(r["raw_id"])

        mem_ev: dict[str, list[str]] = defaultdict(list)
        for r in conn.execute("SELECT memory_id, raw_id FROM memory_evidence"):
            mem_ev[r["memory_id"]].append(r["raw_id"])

        ep_ev: dict[str, list[str]] = defaultdict(list)
        for r in conn.execute("SELECT episode_id, raw_id FROM episode_events"):
            ep_ev[r["episode_id"]].append(r["raw_id"])

        # Count project profiles if table exists (backward compatible with older DBs)
        has_profiles = (
            conn.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='project_profiles'"
            ).fetchone()
            is not None
        )
        profiles_count = (
            int(conn.execute("SELECT COUNT(*) FROM project_profiles").fetchone()[0])
            if has_profiles
            else 0
        )

        def _exchange_window(raw_row: dict[str, Any]) -> list[dict[str, str]]:
            ep_id = raw_row.get("episode_id")
            if not ep_id or raw_row["source"] != "ai_chat":
                return []
            siblings = ep_ordered_raws.get(ep_id, [])
            sess_id = raw_row.get("_session_id")
            if sess_id:
                same = [s for s in siblings if s.get("_session_id") == sess_id]
                if any(s["id"] == raw_row["id"] for s in same):
                    siblings = same
            idx = next((i for i, s in enumerate(siblings) if s["id"] == raw_row["id"]), -1)
            if idx < 0:
                return []
            turns: list[dict[str, str]] = []
            for pos in range(max(0, idx - 1), min(len(siblings), idx + 2)):
                sib = siblings[pos]
                role = "cited" if pos == idx else ("prev_context" if pos < idx else "next_context")
                turns.append(
                    {
                        "role": role,
                        "raw_id": str(sib["id"]),
                        "actor": str(sib["actor"]),
                        "source": str(sib["source"]),
                        "quote": str(sib["body_text"]).replace("\n", " ").strip()[:280],
                    }
                )
            return turns

        items: list[ClaimCheckItem] = []

        def _audit_entry(
            *,
            item_id: str,
            item_kind: str,
            status: str,
            authority: str,
            proj: str | None,
            topic_or_title: str,
            statement: str,
            ev_ids: list[str],
        ) -> None:
            if project and proj != project:
                return
            ev_texts: list[str] = []
            ev_actors: list[str] = []
            ev_quotes: list[dict[str, Any]] = []
            cited_rows: list[dict[str, Any]] = []
            for eid in ev_ids:
                row = raw_map.get(eid)
                if not row:
                    continue
                cited_rows.append(row)
                ev_texts.append(f"{row['title']}\n{row['body_text']}")
                ev_actors.append(f"{row['actor']}({row['source']})")
                if include_quotes and row["privacy_tier"] != "local_only":
                    ev_quotes.append(
                        {
                            "raw_id": eid,
                            "actor": str(row["actor"]),
                            "source": str(row["source"]),
                            "quote": str(row["body_text"]).replace("\n", " ").strip()[:280],
                            "exchange_window": _exchange_window(row),
                        }
                    )
            combined_norm = _norm("\n".join(ev_texts))
            claim_source = statement if item_kind == "decision" else f"{topic_or_title} {statement}"
            claims = extract_verifiable_claims(claim_source)
            supported = [c for c in claims if _claim_supported_in_text(c, combined_norm)]
            unsupported = [c for c in claims if c not in supported]
            rate = round(len(supported) / len(claims), 4) if claims else 1.0

            # Anti-Noise / Durability checks
            noise_flags: list[str] = []
            if _VOLATILE_SNAPSHOT_RE.search(f"{topic_or_title} {statement}"):
                noise_flags.append("volatile_status_snapshot")

            # Flag isolated elliptical ai_chat confirmations lacking their Q&A pair
            if (
                len(cited_rows) == 1
                and cited_rows[0]["source"] == "ai_chat"
                and cited_rows[0]["actor"] == "self"
                and len(str(cited_rows[0]["body_text"]).strip()) < 28
            ):
                noise_flags.append("isolated_short_reply")

            items.append(
                ClaimCheckItem(
                    item_id=item_id,
                    item_kind=item_kind,
                    status=status,
                    authority=authority,
                    project=proj,
                    topic_or_title=topic_or_title,
                    statement=statement,
                    evidence_ids=ev_ids,
                    evidence_actors=ev_actors,
                    evidence_quotes=ev_quotes,
                    extracted_claims=claims,
                    supported_claims=supported,
                    unsupported_claims=unsupported,
                    claim_support_rate=rate,
                    noise_flags=noise_flags,
                )
            )

        for d in conn.execute(
            "SELECT * FROM decisions WHERE status != 'retracted' ORDER BY valid_at ASC"
        ):
            _audit_entry(
                item_id=d["id"],
                item_kind="decision",
                status=d["status"],
                authority=d["authority"],
                proj=d["project"],
                topic_or_title=d["topic"],
                statement=d["statement"],
                ev_ids=dec_ev.get(d["id"], []),
            )

        for m in conn.execute("SELECT * FROM memories WHERE deleted = 0 ORDER BY created_at ASC"):
            _audit_entry(
                item_id=m["id"],
                item_kind="memory",
                status=m["kind"],
                authority=m["origin"],
                proj=m["project"],
                topic_or_title=m["title"],
                statement=m["body"],
                ev_ids=mem_ev.get(m["id"], []),
            )

        # Cross-item near-duplicate detection (Decision <-> Memory restating the same fact)
        active_decs = [it for it in items if it.item_kind == "decision" and it.status == "active"]
        mems = [it for it in items if it.item_kind == "memory"]
        for mem in mems:
            for dec in active_decs:
                if _bigram_jaccard(mem.statement, dec.statement) >= 0.42:
                    flag = f"duplicate_of:{dec.item_id}"
                    if flag not in mem.noise_flags:
                        mem.noise_flags.append(flag)
                    break

        cited_in_l3 = {eid for it in items for eid in it.evidence_ids}
        curated_l3_text_by_proj: dict[str, str] = defaultdict(str)
        for it in items:
            curated_l3_text_by_proj[it.project or ""] += f"\n{it.topic_or_title} {it.statement}"

        omissions: list[EpisodeOmissionItem] = []
        for ep in conn.execute(
            "SELECT * FROM episodes WHERE status IN ('curated', 'manual') ORDER BY t_start ASC"
        ):
            if project and ep["project"] != project:
                continue
            eids = ep_ev.get(ep["id"], [])
            ep_bundle_norm = _norm(
                f"{ep['title']}\n{ep['summary']}\n{ep['overview']}\n"
                + curated_l3_text_by_proj.get(ep["project"] or "", "")
            )
            human_turns = 0
            high_sig = 0
            covered = 0
            omitted_list: list[dict[str, Any]] = []
            for eid in eids:
                r = raw_map.get(eid)
                if not r or r["privacy_tier"] == "local_only":
                    continue
                if r["actor"] != "self":
                    continue
                human_turns += 1
                hints = r.get("_signal_hints") or []
                is_high_sig = bool(
                    set(hints) & {"user_correction", "user_decision"}
                ) or len(str(r["body_text"]).strip()) >= 35
                if not is_high_sig:
                    continue
                high_sig += 1
                if eid in cited_in_l3:
                    covered += 1
                    continue
                turn_claims = extract_verifiable_claims(str(r["body_text"]))
                if turn_claims and any(
                    _claim_supported_in_text(c, ep_bundle_norm) for c in turn_claims
                ):
                    covered += 1
                    continue
                omitted_item: dict[str, Any] = {
                    "raw_id": eid,
                    "source": r["source"],
                    "hints": hints,
                    "char_len": len(str(r["body_text"])),
                }
                if include_quotes:
                    omitted_item["quote"] = str(r["body_text"]).replace("\n", " ")[:220]
                    omitted_item["exchange_window"] = _exchange_window(r)
                omitted_list.append(omitted_item)

            cov_rate = round(covered / high_sig, 4) if high_sig else 1.0
            omissions.append(
                EpisodeOmissionItem(
                    episode_id=ep["id"],
                    project=ep["project"],
                    title=ep["title"],
                    total_events=len(eids),
                    human_turns=human_turns,
                    high_signal_human_turns=high_sig,
                    covered_high_signal_turns=covered,
                    coverage_rate=cov_rate,
                    omitted_turns=omitted_list,
                )
            )
    finally:
        conn.close()

    total_claims = sum(len(it.extracted_claims) for it in items)
    total_unsupported = sum(len(it.unsupported_claims) for it in items)
    avg_support = (
        round((total_claims - total_unsupported) / total_claims, 4) if total_claims else 1.0
    )
    total_noise = sum(len(it.noise_flags) for it in items)
    clean_items = sum(1 for it in items if not it.noise_flags)
    durability_rate = round(clean_items / len(items), 4) if items else 1.0
    avg_cov = (
        round(sum(o.coverage_rate for o in omissions) / len(omissions), 4) if omissions else 1.0
    )

    return FidelityReport(
        data_dir=str(root),
        audited_at_ms=now_ms(),
        avg_claim_support_rate=avg_support,
        total_claims_checked=total_claims,
        total_unsupported_claims=total_unsupported,
        durability_hygiene_rate=durability_rate,
        total_noise_flags=total_noise,
        project_profiles_count=profiles_count,
        avg_episode_signal_coverage=avg_cov,
        items=items,
        episode_omissions=omissions,
    )


def render_fidelity_markdown(report: FidelityReport) -> str:
    lines = [
        "# Raw Memory — Compression Fidelity, Exchange Provenance & Anti-Noise Audit",
        "",
        f"- **Claim-to-Evidence Support Rate**: **`{report.avg_claim_support_rate * 100:.1f}%`** (`{report.total_claims_checked - report.total_unsupported_claims}/{report.total_claims_checked}` concrete claims verified verbatim; unsupported=`{report.total_unsupported_claims}`)",
        f"- **Anti-Noise Durability Hygiene**: **`{report.durability_hygiene_rate * 100:.1f}%`** (`{report.total_noise_flags}` noise/duplicate/isolated-reply flags; `{report.project_profiles_count}` structured Project Profiles)",
        f"- **Curated Episode High-Signal Human Turn Coverage**: **`{report.avg_episode_signal_coverage * 100:.1f}%`** across `{len(report.episode_omissions)}` episodes",
        "",
        "## 1. Decision & Memory Verification",
        "",
        "| Kind / Status | Topic / Title | Support | Unsupported Claims | Anti-Noise Flags | Cited Actors |",
        "| :--- | :--- | ---: | :--- | :--- | :--- |",
    ]
    for it in report.items:
        unsup = ", ".join(it.unsupported_claims) or "✅ none"
        nflags = ", ".join(it.noise_flags) or "✅ clean"
        actors = ", ".join(it.evidence_actors)
        lines.append(
            f"| `{it.item_kind}:{it.status}` | {it.topic_or_title} | {it.claim_support_rate * 100:.0f}% | {unsup} | {nflags} | {actors} |"
        )

    lines.extend(
        [
            "",
            "## 2. Episode High-Signal Human Turn Coverage (Omission Check)",
            "",
            "| Episode | Events | High-Signal Human Turns | Covered | Coverage | Potentially Omitted Raw IDs |",
            "| :--- | ---: | ---: | ---: | ---: | :--- |",
        ]
    )
    for om in report.episode_omissions:
        om_ids = ", ".join(t["raw_id"] for t in om.omitted_turns[:5]) or "✅ none"
        lines.append(
            f"| {om.title} (`{om.episode_id}`) | {om.total_events} | {om.high_signal_human_turns} | {om.covered_high_signal_turns} | {om.coverage_rate * 100:.0f}% | {om_ids} |"
        )

    return "\n".join(lines) + "\n"
