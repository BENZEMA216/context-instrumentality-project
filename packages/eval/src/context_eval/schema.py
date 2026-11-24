"""Pydantic v2 contracts for the Reflexive Meta Memory Benchmark."""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

from context_hub.models import DecisionAuthority, MemoryKind

EvalDimension = Literal[
    "cold_start_continuation",
    "correction_avoidance",
    "bitemporal_supersession",
]

BaselineName = Literal[
    "no_memory",
    "raw_fts",
    "flat_memory_md",
    "hub_v2_curated",
]

ALL_BASELINES: tuple[BaselineName, ...] = (
    "no_memory",
    "raw_fts",
    "flat_memory_md",
    "hub_v2_curated",
)


class FactProbe(BaseModel):
    """Deterministic bilingual substring probe for required facts or forbidden stale claims."""

    fact_id: str = Field(..., min_length=1, max_length=120)
    description: str = ""
    any_of: list[str] = Field(default_factory=list)
    all_of: list[str] = Field(default_factory=list)


class CuratedEpisodeSpec(BaseModel):
    """Episode curation fixture to replay into an isolated HubStore."""

    episode_id: str = Field(..., min_length=1, max_length=256)
    title: str = Field(..., min_length=1, max_length=240)
    summary: str = Field(..., min_length=1, max_length=2000)
    overview: str = Field(default="", max_length=24000)
    project: str | None = None
    entities: list[str] = Field(default_factory=list)
    evidence_ids: list[str] = Field(..., min_length=1, max_length=256)


class CuratedDecisionSpec(BaseModel):
    """Bi-temporal decision fixture with symbolic supersession reference."""

    ref_id: str | None = None
    project: str = Field(..., min_length=1, max_length=160)
    topic: str = Field(..., min_length=1, max_length=200)
    statement: str = Field(..., min_length=1, max_length=4000)
    authority: DecisionAuthority = "user_confirmed"
    confidence: float = Field(default=0.9, ge=0.0, le=1.0)
    valid_at: int | None = None
    supersedes_ref: str | None = None
    evidence_ids: list[str] = Field(..., min_length=1, max_length=128)


class CuratedMemorySpec(BaseModel):
    """Durable curated or manual memory fixture."""

    title: str = Field(..., min_length=1, max_length=240)
    body: str = Field(..., min_length=1, max_length=32000)
    kind: MemoryKind = "episode_note"
    project: str | None = None
    tags: list[str] = Field(default_factory=list)
    evidence_ids: list[str] = Field(..., min_length=1, max_length=256)
    manual: bool = False


class CuratedLinkSpec(BaseModel):
    """Cross-channel curated link fixture."""

    src_id: str = Field(..., min_length=1, max_length=256)
    dst_id: str = Field(..., min_length=1, max_length=256)
    relation: str = Field(..., min_length=1, max_length=64)
    confidence: float = Field(default=0.85, ge=0.0, le=1.0)
    evidence: str = ""


class CuratedFixture(BaseModel):
    """Causal curation batch committed at `committed_at_ms`."""

    curator_agent: str = "synthetic-curator"
    committed_at_ms: int
    episodes: list[CuratedEpisodeSpec] = Field(default_factory=list)
    decisions: list[CuratedDecisionSpec] = Field(default_factory=list)
    memories: list[CuratedMemorySpec] = Field(default_factory=list)
    links: list[CuratedLinkSpec] = Field(default_factory=list)
    notes: str = ""


class BenchmarkCase(BaseModel):
    """A single causally isolated evaluation scenario."""

    case_id: str = Field(..., min_length=1, max_length=120)
    dimension: EvalDimension
    title: str = Field(..., min_length=1, max_length=240)
    description: str = ""
    cutoff_ms: int
    project: str | None = None
    query: str
    window_minutes: int = Field(default=240, ge=1)
    max_tokens: int = Field(default=2500, ge=200, le=16000)
    anchor_urls: list[str] = Field(default_factory=list)
    correction_trigger: str | None = None
    events: list[dict[str, Any]] = Field(default_factory=list)
    curations: list[CuratedFixture] = Field(default_factory=list)
    required_facts: list[FactProbe] = Field(default_factory=list)
    forbidden_stale_facts: list[FactProbe] = Field(default_factory=list)
    future_canary_tokens: list[str] = Field(default_factory=list)


class BenchmarkDataset(BaseModel):
    """Collection of synthetic or local benchmark cases."""

    name: str
    version: str
    description: str = ""
    synthetic_only: bool = True
    cases: list[BenchmarkCase] = Field(default_factory=list)


class BaselineRetrieval(BaseModel):
    """Output produced by a single baseline for one benchmark case."""

    baseline: BaselineName
    context_text: str
    approx_tokens: int
    latency_ms: float
    items_returned: int
    metadata: dict[str, Any] = Field(default_factory=dict)


class CaseResult(BaseModel):
    """Per-case evaluation outcome for one baseline."""

    case_id: str
    dimension: EvalDimension
    baseline: BaselineName
    required_fact_recall: float
    matched_required_facts: list[str] = Field(default_factory=list)
    missed_required_facts: list[str] = Field(default_factory=list)
    stale_leakage_rate: float
    leaked_stale_facts: list[str] = Field(default_factory=list)
    future_leak_detected: bool = False
    correction_avoided: float | None = None
    current_truth_accurate: float | None = None
    approx_tokens: int
    token_efficiency: float
    latency_ms: float
    ingested_events_count: int
    excluded_future_events_count: int


class DimensionSummary(BaseModel):
    """Aggregated metrics for one evaluation dimension under one baseline."""

    dimension: EvalDimension
    case_count: int
    required_fact_recall: float
    correction_avoidance_rate: float | None = None
    current_truth_accuracy: float | None = None
    stale_leakage_rate: float
    future_leak_count: int
    avg_tokens: float
    token_efficiency: float
    p50_latency_ms: float
    p95_latency_ms: float


class BaselineScorecard(BaseModel):
    """Aggregated scorecard for a single baseline across the dataset."""

    baseline: BaselineName
    case_count: int
    overall_fact_recall: float
    cold_start_recall: float | None = None
    correction_avoidance_rate: float | None = None
    current_truth_accuracy: float | None = None
    stale_leakage_rate: float
    future_leak_count: int
    avg_tokens: float
    token_efficiency: float
    p50_latency_ms: float
    p95_latency_ms: float
    by_dimension: dict[EvalDimension, DimensionSummary] = Field(default_factory=dict)
    case_results: list[CaseResult] = Field(default_factory=list)


class GenerationTrace(BaseModel):
    """Per-generation audit snapshot for the N-generation anti-echo stress test."""

    generation: int
    recalled_tokens: int
    unconfirmed_evidence_count: int
    unconfirmed_authority: str
    protected_decision_active: bool
    protected_decision_compromised: bool
    active_decisions_count: int
    memories_count: int
    fabricated_evidence_rejected: bool


class AntiEchoReport(BaseModel):
    """Results of the deterministic N-generation reflexive anti-echo stress test."""

    mode: Literal["guarded", "naive_unguarded"] = "guarded"
    generations: int
    unique_ground_truth_facts: int
    final_curated_items: int
    hallucination_amplification_rate: float
    authority_drift_rate: float
    injection_compromise_rate: float
    memory_bloat_ratio: float
    fabricated_evidence_gate_passed: bool
    passed: bool
    traces: list[GenerationTrace] = Field(default_factory=list)


class EvalReport(BaseModel):
    """Complete benchmark report spanning all baselines and optional anti-echo stress test."""

    dataset_name: str
    dataset_version: str
    total_cases: int
    baselines: list[BaselineScorecard] = Field(default_factory=list)
    anti_echo: AntiEchoReport | None = None
    generated_at_ms: int
