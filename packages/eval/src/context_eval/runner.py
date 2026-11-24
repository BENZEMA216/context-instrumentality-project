"""Benchmark runner, metric aggregation, and Markdown/JSON scorecard rendering."""

from __future__ import annotations

import datetime
import math
import tempfile
import unicodedata
from collections.abc import Sequence
from pathlib import Path

from context_hub.models import now_ms

from .anti_echo import run_anti_echo_stress
from .baselines import build_causal_replay_store, run_baseline
from .schema import (
    ALL_BASELINES,
    BaselineName,
    BaselineScorecard,
    BenchmarkCase,
    BenchmarkDataset,
    CaseResult,
    DimensionSummary,
    EvalDimension,
    EvalReport,
    FactProbe,
)

_DIMENSION_ORDER: tuple[EvalDimension, ...] = (
    "cold_start_continuation",
    "correction_avoidance",
    "bitemporal_supersession",
)


def default_dataset_path() -> Path:
    """Locate the bundled synthetic reflexive benchmark dataset."""
    here = Path(__file__).resolve()
    candidates = [
        here.parents[2] / "datasets" / "synthetic_reflexive_v1.json",
        here.parents[3] / "datasets" / "synthetic_reflexive_v1.json",
        here.parents[4] / "packages" / "eval" / "datasets" / "synthetic_reflexive_v1.json",
    ]
    for path in candidates:
        if path.is_file():
            return path
    return candidates[0]


def load_dataset(path: Path | None = None) -> BenchmarkDataset:
    target = Path(path) if path is not None else default_dataset_path()
    return BenchmarkDataset.model_validate_json(target.read_text(encoding="utf-8"))


def _normalize(text: str) -> str:
    return unicodedata.normalize("NFKC", text).casefold()


def matches_probe(haystack_norm: str, probe: FactProbe) -> bool:
    if not probe.all_of and not probe.any_of:
        return False
    if probe.all_of and not all(_normalize(term) in haystack_norm for term in probe.all_of):
        return False
    return not (probe.any_of and not any(_normalize(term) in haystack_norm for term in probe.any_of))


def compute_token_efficiency(recall: float, approx_tokens: int) -> float:
    """Fact recall density per 1k tokens (higher is better; 0 when recall or tokens is 0)."""
    if recall <= 0.0 or approx_tokens <= 0:
        return 0.0
    return round(recall / (max(approx_tokens, 100) / 1000.0), 4)


def _percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return round(ordered[0], 3)
    rank = (pct / 100.0) * (len(ordered) - 1)
    lo = math.floor(rank)
    hi = math.ceil(rank)
    if lo == hi:
        return round(ordered[lo], 3)
    frac = rank - lo
    return round(ordered[lo] * (1.0 - frac) + ordered[hi] * frac, 3)


def _score_case(
    case: BenchmarkCase,
    *,
    baseline: BaselineName,
    context_text: str,
    approx_tokens: int,
    latency_ms: float,
    ingested_count: int,
    excluded_future_count: int,
) -> CaseResult:
    haystack = _normalize(context_text)

    matched_req: list[str] = []
    missed_req: list[str] = []
    for probe in case.required_facts:
        if matches_probe(haystack, probe):
            matched_req.append(probe.fact_id)
        else:
            missed_req.append(probe.fact_id)
    recall = len(matched_req) / len(case.required_facts) if case.required_facts else 1.0

    leaked_stale: list[str] = []
    for probe in case.forbidden_stale_facts:
        if matches_probe(haystack, probe):
            leaked_stale.append(probe.fact_id)
    stale_rate = (
        len(leaked_stale) / len(case.forbidden_stale_facts) if case.forbidden_stale_facts else 0.0
    )

    future_leak = any(_normalize(tok) in haystack for tok in case.future_canary_tokens)

    correction_avoided: float | None = None
    current_truth_accurate: float | None = None
    if case.dimension == "correction_avoidance":
        correction_avoided = 1.0 if (recall >= 1.0 and stale_rate == 0.0) else 0.0
    elif case.dimension == "bitemporal_supersession":
        current_truth_accurate = 1.0 if recall >= 1.0 else 0.0

    return CaseResult(
        case_id=case.case_id,
        dimension=case.dimension,
        baseline=baseline,
        required_fact_recall=round(recall, 4),
        matched_required_facts=matched_req,
        missed_required_facts=missed_req,
        stale_leakage_rate=round(stale_rate, 4),
        leaked_stale_facts=leaked_stale,
        future_leak_detected=future_leak,
        correction_avoided=correction_avoided,
        current_truth_accurate=current_truth_accurate,
        approx_tokens=approx_tokens,
        token_efficiency=compute_token_efficiency(recall, approx_tokens),
        latency_ms=round(latency_ms, 3),
        ingested_events_count=ingested_count,
        excluded_future_events_count=excluded_future_count,
    )


def _mean(values: list[float]) -> float:
    return round(sum(values) / len(values), 4) if values else 0.0


def _aggregate_dimension(dimension: EvalDimension, results: list[CaseResult]) -> DimensionSummary:
    latencies = [r.latency_ms for r in results]
    corr_vals = [r.correction_avoided for r in results if r.correction_avoided is not None]
    truth_vals = [r.current_truth_accurate for r in results if r.current_truth_accurate is not None]
    return DimensionSummary(
        dimension=dimension,
        case_count=len(results),
        required_fact_recall=_mean([r.required_fact_recall for r in results]),
        correction_avoidance_rate=_mean(corr_vals) if corr_vals else None,
        current_truth_accuracy=_mean(truth_vals) if truth_vals else None,
        stale_leakage_rate=_mean([r.stale_leakage_rate for r in results]),
        future_leak_count=sum(1 for r in results if r.future_leak_detected),
        avg_tokens=round(_mean([float(r.approx_tokens) for r in results]), 1),
        token_efficiency=_mean([r.token_efficiency for r in results]),
        p50_latency_ms=_percentile(latencies, 50.0),
        p95_latency_ms=_percentile(latencies, 95.0),
    )


def _aggregate_baseline(baseline: BaselineName, results: list[CaseResult]) -> BaselineScorecard:
    by_dim: dict[EvalDimension, DimensionSummary] = {}
    for dim in _DIMENSION_ORDER:
        dim_rows = [r for r in results if r.dimension == dim]
        if dim_rows:
            by_dim[dim] = _aggregate_dimension(dim, dim_rows)

    latencies = [r.latency_ms for r in results]
    bt_rows = [r for r in results if r.dimension == "bitemporal_supersession"]
    stale_scope = bt_rows if bt_rows else results

    return BaselineScorecard(
        baseline=baseline,
        case_count=len(results),
        overall_fact_recall=_mean([r.required_fact_recall for r in results]),
        cold_start_recall=(
            by_dim["cold_start_continuation"].required_fact_recall
            if "cold_start_continuation" in by_dim
            else None
        ),
        correction_avoidance_rate=(
            by_dim["correction_avoidance"].correction_avoidance_rate
            if "correction_avoidance" in by_dim
            else None
        ),
        current_truth_accuracy=(
            by_dim["bitemporal_supersession"].current_truth_accuracy
            if "bitemporal_supersession" in by_dim
            else None
        ),
        stale_leakage_rate=_mean([r.stale_leakage_rate for r in stale_scope]),
        future_leak_count=sum(1 for r in results if r.future_leak_detected),
        avg_tokens=round(_mean([float(r.approx_tokens) for r in results]), 1),
        token_efficiency=_mean([r.token_efficiency for r in results]),
        p50_latency_ms=_percentile(latencies, 50.0),
        p95_latency_ms=_percentile(latencies, 95.0),
        by_dimension=by_dim,
        case_results=results,
    )


def evaluate_dataset(
    dataset: BenchmarkDataset,
    *,
    baselines: Sequence[BaselineName] = ALL_BASELINES,
    run_anti_echo: bool = True,
    generations: int = 5,
) -> EvalReport:
    """Evaluate a BenchmarkDataset with strict H_<t causal isolation per case."""
    selected_baselines: list[BaselineName] = list(dict.fromkeys(baselines))
    results_by_baseline: dict[BaselineName, list[CaseResult]] = {
        b: [] for b in selected_baselines
    }

    for case in dataset.cases:
        with tempfile.TemporaryDirectory(prefix=f"context-eval-{case.case_id}-") as tmp:
            replay = build_causal_replay_store(case, Path(tmp))
            for baseline in selected_baselines:
                retrieval = run_baseline(baseline, replay.store, case)
                case_res = _score_case(
                    case,
                    baseline=baseline,
                    context_text=retrieval.context_text,
                    approx_tokens=retrieval.approx_tokens,
                    latency_ms=retrieval.latency_ms,
                    ingested_count=len(replay.ingested_ids),
                    excluded_future_count=len(replay.excluded_future_ids),
                )
                results_by_baseline[baseline].append(case_res)

    scorecards = [
        _aggregate_baseline(b, results_by_baseline[b]) for b in selected_baselines
    ]
    anti_echo = run_anti_echo_stress(generations=generations) if run_anti_echo else None

    return EvalReport(
        dataset_name=dataset.name,
        dataset_version=dataset.version,
        total_cases=len(dataset.cases),
        baselines=scorecards,
        anti_echo=anti_echo,
        generated_at_ms=now_ms(),
    )


def _fmt_pct(val: float | None) -> str:
    if val is None:
        return "—"
    return f"{val * 100:.1f}%"


def render_markdown_report(report: EvalReport) -> str:
    """Render a crisp GitHub-flavored Markdown scorecard from an EvalReport."""
    ts = datetime.datetime.fromtimestamp(
        report.generated_at_ms / 1000.0, tz=datetime.UTC
    ).strftime("%Y-%m-%d %H:%M:%S UTC")

    lines: list[str] = [
        "# Reflexive Meta Memory Benchmark — Baseline Scorecard",
        "",
        (
            f"- **Dataset**: `{report.dataset_name}` (`v{report.dataset_version}`, "
            f"{report.total_cases} synthetic cases)"
        ),
        f"- **Generated**: `{ts}`",
        "- **Causal Isolation**: Strict $H_{<t}$ ephemeral `HubStore` replay + leak-check guard",
        "",
        "## 1. Overall A/B Baseline Comparison",
        "",
        (
            "| Baseline | Overall Recall ↑ | Cold-Start Recall ↑ | Correction Avoidance ↑ | "
            "Bi-Temporal Truth ↑ | Stale Leakage ↓ | Future Leaks | Avg Tokens | "
            "Tok Eff (↑) | p50 / p95 ms |"
        ),
        "| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for sc in report.baselines:
        lines.append(
            f"| `{sc.baseline}` | {_fmt_pct(sc.overall_fact_recall)} | "
            f"{_fmt_pct(sc.cold_start_recall)} | {_fmt_pct(sc.correction_avoidance_rate)} | "
            f"{_fmt_pct(sc.current_truth_accuracy)} | {_fmt_pct(sc.stale_leakage_rate)} | "
            f"{sc.future_leak_count} | {sc.avg_tokens:.1f} | {sc.token_efficiency:.2f} | "
            f"{sc.p50_latency_ms:.2f} / {sc.p95_latency_ms:.2f} |"
        )

    lines.extend(["", "## 2. Per-Dimension Breakdown", ""])
    lines.append(
        "| Dimension | Baseline | Cases | Fact Recall ↑ | Primary Metric ↑ | "
        "Stale Leakage ↓ | Avg Tokens | Tok Eff (↑) | p50 / p95 ms |"
    )
    lines.append("| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")

    for dim in _DIMENSION_ORDER:
        for sc in report.baselines:
            ds = sc.by_dimension.get(dim)
            if ds is None:
                continue
            if dim == "correction_avoidance":
                primary = _fmt_pct(ds.correction_avoidance_rate)
            elif dim == "bitemporal_supersession":
                primary = _fmt_pct(ds.current_truth_accuracy)
            else:
                primary = _fmt_pct(ds.required_fact_recall)
            lines.append(
                f"| `{dim}` | `{sc.baseline}` | {ds.case_count} | "
                f"{_fmt_pct(ds.required_fact_recall)} | {primary} | "
                f"{_fmt_pct(ds.stale_leakage_rate)} | {ds.avg_tokens:.1f} | "
                f"{ds.token_efficiency:.2f} | {ds.p50_latency_ms:.2f} / {ds.p95_latency_ms:.2f} |"
            )

    if report.anti_echo is not None:
        ae = report.anti_echo
        status_badge = "PASS" if ae.passed else "FAIL"
        lines.extend(
            [
                "",
                f"## 3. Reflexive Anti-Echo Closed-Loop Stress Test ({ae.generations} Generations · {status_badge})",
                "",
                "| Metric | Value | Target | Status |",
                "| :--- | ---: | ---: | :---: |",
                (
                    f"| `hallucination_amplification_rate` | {_fmt_pct(ae.hallucination_amplification_rate)} | "
                    f"0.0% | {'PASS' if ae.hallucination_amplification_rate == 0.0 else 'FAIL'} |"
                ),
                (
                    f"| `authority_drift_rate` | {_fmt_pct(ae.authority_drift_rate)} | "
                    f"0.0% | {'PASS' if ae.authority_drift_rate == 0.0 else 'FAIL'} |"
                ),
                (
                    f"| `injection_compromise_rate` | {_fmt_pct(ae.injection_compromise_rate)} | "
                    f"0.0% | {'PASS' if ae.injection_compromise_rate == 0.0 else 'FAIL'} |"
                ),
                (
                    f"| `memory_bloat_ratio` | {ae.memory_bloat_ratio:.2f}x "
                    f"({ae.final_curated_items}/{ae.unique_ground_truth_facts}) | "
                    f"<= 1.10x | {'PASS' if ae.memory_bloat_ratio <= 1.1 else 'FAIL'} |"
                ),
                (
                    f"| `fabricated_evidence_gate_passed` | {ae.fabricated_evidence_gate_passed} | "
                    f"True | {'PASS' if ae.fabricated_evidence_gate_passed else 'FAIL'} |"
                ),
            ]
        )

    return "\n".join(lines) + "\n"
