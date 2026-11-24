"""CLI entry point for `context-eval`."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from context_hub.mcp_server import default_data_dir

from .fidelity import inspect_compression_fidelity, render_fidelity_markdown
from .memory_judge import audit_curated_memory, render_memory_audit_markdown
from .miner import default_eval_dir, mine_candidates
from .raw_audit import audit_raw_data, render_raw_audit_markdown
from .runner import default_dataset_path, evaluate_dataset, load_dataset, render_markdown_report
from .schema import ALL_BASELINES, BaselineName


def _parse_baselines(raw: str | None) -> list[BaselineName]:
    if not raw:
        return list(ALL_BASELINES)
    valid = set(ALL_BASELINES)
    chosen: list[BaselineName] = []
    for item in raw.split(","):
        name = item.strip()
        if not name:
            continue
        if name not in valid:
            raise argparse.ArgumentTypeError(
                f"Invalid baseline '{name}'. Expected one of: {', '.join(ALL_BASELINES)}"
            )
        chosen.append(name)  # type: ignore[arg-type]
    if not chosen:
        raise argparse.ArgumentTypeError("At least one baseline must be specified.")
    return chosen


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="raw-memory-eval",
        description="Raw Memory — Raw Data Readiness Gate, Curated Memory Observability & Reflexive Meta Benchmark",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    run_cmd = sub.add_parser(
        "run",
        help="Run A/B memory baselines with H_<t causal isolation + N-gen anti-echo stress test",
    )
    run_cmd.add_argument(
        "--dataset",
        type=Path,
        default=default_dataset_path(),
        help="Path to benchmark dataset JSON (default: bundled synthetic_reflexive_v1.json)",
    )
    run_cmd.add_argument(
        "--baselines",
        type=str,
        default=",".join(ALL_BASELINES),
        help=f"Comma-separated baselines (default: {','.join(ALL_BASELINES)})",
    )
    run_cmd.add_argument(
        "--generations",
        type=int,
        default=5,
        help="Number of closed-loop generations for reflexive anti-echo stress test (default: 5)",
    )
    run_cmd.add_argument(
        "--skip-anti-echo",
        action="store_true",
        help="Skip the N-generation reflexive anti-echo stress test",
    )
    run_cmd.add_argument(
        "--format",
        choices=("markdown", "json"),
        default="markdown",
        help="Output rendering format (default: markdown)",
    )
    run_cmd.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Optional file path to write the rendered scorecard",
    )

    mine_cmd = sub.add_parser(
        "mine",
        help="Read-only miner discovering private candidate benchmark cases from local Hub DB",
    )
    mine_cmd.add_argument(
        "--data-dir",
        type=Path,
        default=default_data_dir(),
        help="Local Context Hub data directory (default: ~/.local/share/context-hub-v2)",
    )
    mine_cmd.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Output JSON path (default: <data-dir>/eval/mined_candidates.json)",
    )
    mine_cmd.add_argument(
        "--limit",
        type=int,
        default=30,
        help="Maximum number of balanced candidates to export (default: 30)",
    )
    mine_cmd.add_argument(
        "--include-text",
        action="store_true",
        help="Opt-in to include non-local_only text previews in local private export (default: redacted metadata only)",
    )

    raw_cmd = sub.add_parser(
        "audit-raw",
        help="Verify Raw Data integrity, signal hygiene, privacy boundaries, and live Agent consumption readiness",
    )
    raw_cmd.add_argument(
        "--data-dir",
        type=Path,
        default=default_data_dir(),
        help="Local Raw Memory data directory (default: ~/.local/share/context-hub-v2)",
    )
    raw_cmd.add_argument("--query", type=str, default=None, help="Optional non-private smoke probe query")
    raw_cmd.add_argument("--format", choices=("markdown", "json"), default="markdown")

    mem_cmd = sub.add_parser(
        "audit-memory",
        help="Observe & grade real curated Memory against L0/L1 Raw Data + run live A/B benchmark scorecard",
    )
    mem_cmd.add_argument(
        "--data-dir",
        type=Path,
        default=default_data_dir(),
        help="Local Raw Memory data directory (default: ~/.local/share/context-hub-v2)",
    )
    mem_cmd.add_argument("--skip-live-ab", action="store_true")
    mem_cmd.add_argument("--format", choices=("markdown", "json"), default="markdown")

    fid_cmd = sub.add_parser(
        "inspect-fidelity",
        help="Verify compressed Decisions/Memories claim-by-claim against cited Raw Evidence and detect omitted user turns",
    )
    fid_cmd.add_argument(
        "--data-dir",
        type=Path,
        default=default_data_dir(),
        help="Local Raw Memory data directory (default: ~/.local/share/context-hub-v2)",
    )
    fid_cmd.add_argument("--project", type=str, default=None)
    fid_cmd.add_argument("--include-quotes", action="store_true")
    fid_cmd.add_argument("--format", choices=("markdown", "json"), default="markdown")

    args = parser.parse_args(argv)

    if args.command == "run":
        baselines = _parse_baselines(args.baselines)
        dataset = load_dataset(args.dataset)
        report = evaluate_dataset(
            dataset,
            baselines=baselines,
            run_anti_echo=not args.skip_anti_echo,
            generations=args.generations,
        )
        rendered = (
            render_markdown_report(report)
            if args.format == "markdown"
            else report.model_dump_json(indent=2) + "\n"
        )
        if args.out is not None:
            target = args.out.expanduser()
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(rendered, encoding="utf-8")
        sys.stdout.write(rendered)
        return 0

    if args.command == "mine":
        out_path = args.out or (default_eval_dir(args.data_dir) / "mined_candidates.json")
        result = mine_candidates(
            args.data_dir,
            limit=args.limit,
            redact=not args.include_text,
            out_path=out_path,
        )
        summary = {
            "source_db": result["source_db"],
            "output_path": result.get("output_path"),
            "redacted": result["redacted"],
            "discovered_totals": result["discovered_totals"],
            "exported_counts": result["exported_counts"],
            "exported_total": result["exported_total"],
        }
        sys.stdout.write(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
        return 0

    if args.command == "audit-raw":
        report = audit_raw_data(args.data_dir, probe_query=args.query)
        rendered = (
            render_raw_audit_markdown(report)
            if args.format == "markdown"
            else report.model_dump_json(indent=2) + "\n"
        )
        sys.stdout.write(rendered)
        return 0 if report.ready_for_curation else 1

    if args.command == "audit-memory":
        report = audit_curated_memory(args.data_dir, run_live_ab=not args.skip_live_ab)
        rendered = (
            render_memory_audit_markdown(report)
            if args.format == "markdown"
            else report.model_dump_json(indent=2) + "\n"
        )
        sys.stdout.write(rendered)
        return 0 if report.overall_passed else 1

    if args.command == "inspect-fidelity":
        report = inspect_compression_fidelity(
            args.data_dir,
            include_quotes=args.include_quotes,
            project=args.project,
        )
        rendered = (
            render_fidelity_markdown(report)
            if args.format == "markdown"
            else report.model_dump_json(indent=2) + "\n"
        )
        sys.stdout.write(rendered)
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
