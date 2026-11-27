"""Core domain models and validation contracts for Context Hub v2."""

from __future__ import annotations

import secrets
import time
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator

ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

PrivacyTier = Literal["local_only", "redacted", "shareable"]
EpisodeStatus = Literal["pending_curation", "curated", "manual"]
DecisionStatus = Literal["active", "superseded", "retracted"]
DecisionAuthority = Literal["user_confirmed", "assistant_suggested", "observed"]
MemoryOrigin = Literal["curated", "manual"]
MemoryKind = Literal["episode_note", "preference", "fact", "commitment", "manual"]
MemoryScope = Literal["global", "project", "ephemeral"]
TrustLevel = Literal["user_direct", "curated_verified", "untrusted_external"]
RuleScope = Literal["source", "connector", "project", "domain"]

PRIVACY_RANK: dict[PrivacyTier, int] = {
    "local_only": 0,
    "redacted": 1,
    "shareable": 2,
}


def now_ms() -> int:
    return time.time_ns() // 1_000_000


def new_ulid(prefix: str = "") -> str:
    value = (now_ms() << 80) | secrets.randbits(80)
    core = "".join(ALPHABET[(value >> shift) & 31] for shift in range(125, -1, -5))
    return f"{prefix}{core}" if prefix else core


def strictest_tier(tiers: list[PrivacyTier]) -> PrivacyTier:
    if not tiers:
        return "local_only"
    return min(tiers, key=lambda t: PRIVACY_RANK[t])


class Provenance(BaseModel):
    connector: str = Field(..., min_length=1, max_length=256)
    source_id: str = Field(..., min_length=1, max_length=512)
    version: str | None = None
    source_hash: str | None = None
    locator: str | None = None
    extra: dict[str, Any] = Field(default_factory=dict)


class Privacy(BaseModel):
    tier: PrivacyTier | None = None
    pii_tags: list[str] = Field(default_factory=list)


class EventLinkInput(BaseModel):
    target_id: str = Field(..., min_length=1, max_length=256)
    relation: str = Field(..., min_length=1, max_length=64)
    confidence: float = Field(default=1.0, ge=0.0, le=1.0)
    evidence: str | None = None


class RawEventIn(BaseModel):
    id: str | None = None
    source: str = Field(..., min_length=1, max_length=100)
    kind: str = Field(..., min_length=1, max_length=100)
    t_start: int
    t_end: int | None = None
    t_observed: int | None = None
    tz: str | None = None
    tz_source: Literal["recorded", "utc_fallback"] | None = None
    device_id: str | None = None
    actor: str | None = None
    project: str | None = None
    episode_id: str | None = None
    content: dict[str, Any] = Field(default_factory=dict)
    context: dict[str, Any] = Field(default_factory=dict)
    anchors: list[str] = Field(default_factory=list)
    attention: float | None = Field(default=None, ge=0.0, le=1.0)
    links: list[EventLinkInput] = Field(default_factory=list)
    location: dict[str, Any] | None = None
    provenance: Provenance
    privacy: Privacy = Field(default_factory=Privacy)

    @field_validator("source")
    @classmethod
    def _validate_source(cls, v: str) -> str:
        builtin = {"voice", "clipboard", "browser", "ai_chat", "window", "wechat", "location", "vault"}
        if v in builtin:
            return v
        parts = v.split(".")
        if len(parts) >= 2 and all(part and part[0].islower() for part in parts):
            return v
        raise ValueError(f"Invalid source '{v}': expected built-in source or namespaced 'a.b'")


class PrivacyRuleIn(BaseModel):
    scope: RuleScope
    match_value: str = Field(..., min_length=1, max_length=256)
    default_tier: PrivacyTier
    priority: int = Field(default=100, ge=0, le=1000)
    description: str = ""


class EpisodeCurationIn(BaseModel):
    episode_id: str = Field(..., min_length=1, max_length=256)
    title: str = Field(..., min_length=1, max_length=240)
    summary: str = Field(..., min_length=1, max_length=2000)
    overview: str = Field(default="", max_length=24000)
    project: str | None = None
    entities: list[str] = Field(default_factory=list)
    evidence_ids: list[str] = Field(..., min_length=1, max_length=256)
    expected_revision: int | None = None


class DecisionCurationIn(BaseModel):
    project: str = Field(..., min_length=1, max_length=160)
    topic: str = Field(..., min_length=1, max_length=200)
    statement: str = Field(..., min_length=1, max_length=4000)
    authority: DecisionAuthority = "user_confirmed"
    confidence: float = Field(default=0.9, ge=0.0, le=1.0)
    valid_at: int | None = None
    supersedes_decision_id: str | None = None
    evidence_ids: list[str] = Field(..., min_length=1, max_length=128)


class MemoryCurationIn(BaseModel):
    id: str | None = None
    title: str = Field(..., min_length=1, max_length=240)
    body: str = Field(..., min_length=1, max_length=32000)
    kind: MemoryKind = "episode_note"
    project: str | None = None
    scope: MemoryScope | None = None
    expires_at: int | None = None
    trust_level: TrustLevel | None = None
    tags: list[str] = Field(default_factory=list)
    evidence_ids: list[str] = Field(..., min_length=1, max_length=256)
    expected_revision: int | None = None


class CuratedLinkIn(BaseModel):
    src_id: str = Field(..., min_length=1, max_length=256)
    dst_id: str = Field(..., min_length=1, max_length=256)
    relation: str = Field(..., min_length=1, max_length=64)
    confidence: float = Field(default=0.85, ge=0.0, le=1.0)
    evidence: str = ""


class CurationBatchIn(BaseModel):
    curator_agent: str = Field(..., min_length=1, max_length=120)
    episodes: list[EpisodeCurationIn] = Field(default_factory=list)
    decisions: list[DecisionCurationIn] = Field(default_factory=list)
    memories: list[MemoryCurationIn] = Field(default_factory=list)
    links: list[CuratedLinkIn] = Field(default_factory=list)
    notes: str = Field(default="", max_length=2000)


class CollectorStatusIn(BaseModel):
    collector: str = Field(..., min_length=1, max_length=120)
    source: str = Field(..., min_length=1, max_length=100)
    status: Literal["idle", "running", "ok", "degraded", "error", "unconfigured"] = "ok"
    items_synced: int = 0
    watermark: str | None = None
    message: str = ""


class StatusPointerIn(BaseModel):
    label: str = Field(..., min_length=1, max_length=160)
    how_to_check: str = Field(..., min_length=1, max_length=800)


class ProjectProfileIn(BaseModel):
    project: str = Field(..., min_length=1, max_length=160)
    display_name: str = Field(default="", max_length=200)
    summary: str = Field(default="", max_length=2000)
    repos: list[str] = Field(default_factory=list)
    domains: list[str] = Field(default_factory=list)
    status_pointers: list[StatusPointerIn] = Field(default_factory=list)
    tech_notes: list[str] = Field(default_factory=list)
    evidence_ids: list[str] = Field(default_factory=list)
    updated_by: str = Field(default="owner", max_length=120)


class DynamicFocusItem(BaseModel):
    text: str = Field(..., min_length=1, max_length=600)
    project: str | None = None
    expires_at: int | None = None
    updated_at: int | None = None


class UserProfileIn(BaseModel):
    profile_key: str = Field(default="self", min_length=1, max_length=80)
    static_traits: list[str] = Field(default_factory=list)
    dynamic_focus: list[DynamicFocusItem] = Field(default_factory=list)
    evidence_ids: list[str] = Field(default_factory=list)
    updated_by: str = Field(default="owner", max_length=120)
