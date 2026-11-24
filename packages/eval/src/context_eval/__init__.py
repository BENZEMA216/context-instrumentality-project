"""Raw Memory Eval — Raw Data Readiness Gate, Curated Memory Observability & Meta Benchmark."""

from __future__ import annotations

from .anti_echo import run_anti_echo_stress
from .memory_judge import MemoryAuditReport, audit_curated_memory, render_memory_audit_markdown
from .miner import mine_candidates
from .raw_audit import RawAuditReport, audit_raw_data, render_raw_audit_markdown
from .runner import default_dataset_path, evaluate_dataset, load_dataset, render_markdown_report
from .schema import (
    AntiEchoReport,
    BaselineName,
    BaselineScorecard,
    BenchmarkCase,
    BenchmarkDataset,
    CaseResult,
    CuratedFixture,
    DimensionSummary,
    EvalDimension,
    EvalReport,
    FactProbe,
)

__all__ = [
    "AntiEchoReport",
    "BaselineName",
    "BaselineScorecard",
    "BenchmarkCase",
    "BenchmarkDataset",
    "CaseResult",
    "CuratedFixture",
    "DimensionSummary",
    "EvalDimension",
    "EvalReport",
    "FactProbe",
    "MemoryAuditReport",
    "RawAuditReport",
    "audit_curated_memory",
    "audit_raw_data",
    "default_dataset_path",
    "evaluate_dataset",
    "load_dataset",
    "mine_candidates",
    "render_markdown_report",
    "render_memory_audit_markdown",
    "render_raw_audit_markdown",
    "run_anti_echo_stress",
]
