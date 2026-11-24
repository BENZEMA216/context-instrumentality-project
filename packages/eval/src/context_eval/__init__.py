"""Context Eval — Reflexive Meta Memory Benchmark harness for Context Hub v2."""

from __future__ import annotations

from .anti_echo import run_anti_echo_stress
from .miner import mine_candidates
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
    "default_dataset_path",
    "evaluate_dataset",
    "load_dataset",
    "mine_candidates",
    "render_markdown_report",
    "run_anti_echo_stress",
]
