"""CLI entry point for `context-eval`."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from context_hub.mcp_server import default_data_dir

from .academic_e2e import (
    prepare_locomo_e2e_pack,
    prepare_longmemeval_e2e_pack,
    render_academic_e2e_markdown,
    run_api_reader_and_judge,
    score_academic_e2e,
)
from .e2e_judge import evaluate_e2e_convomem
from .fidelity import inspect_compression_fidelity, render_fidelity_markdown
from .frozen_bench import (
    compute_benchmark_diff,
    default_frozen_suite_path,
    default_personal_bench_path,
    evaluate_personal_golden_set,
    evaluate_rawmemory_bench,
    render_frozen_markdown,
    render_personal_markdown,
)
from .memory_judge import audit_curated_memory, render_memory_audit_markdown
from .miner import default_eval_dir, mine_candidates
from .raw_audit import audit_raw_data, render_raw_audit_markdown
from .runner import default_dataset_path, evaluate_dataset, load_dataset, render_markdown_report
from .schema import ALL_BASELINES, BaselineName
from .standard_benchmarks import (
    DEFAULT_BENCH_CACHE,
    default_manifest_path,
    download_benchmark_datasets,
    evaluate_convomem,
    evaluate_locomo,
    evaluate_longmemeval,
    load_manifest,
    render_benchmark_markdown,
)
from .workbench import create_workbench_app, summarize_adjudications


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

    bench_cmd = sub.add_parser(
        "bench",
        help="Download and run standard public Agent Memory Benchmarks (LoCoMo, LongMemEval-S, LongMemEval-Oracle)",
    )
    bench_sub = bench_cmd.add_subparsers(dest="bench_action", required=True)

    bench_dl = bench_sub.add_parser("download", help="Download public benchmark datasets to local cache")
    bench_dl.add_argument(
        "--suite",
        choices=("all", "locomo", "longmemeval-oracle", "longmemeval-s"),
        default="all",
    )
    bench_dl.add_argument("--cache-dir", type=Path, default=DEFAULT_BENCH_CACHE)
    bench_dl.add_argument("--force", action="store_true")

    bench_run = bench_sub.add_parser("run", help="Run Raw Memory on a standard public benchmark suite")
    bench_run.add_argument(
        "--suite",
        choices=("locomo", "longmemeval-oracle", "longmemeval-s", "convomem-smoke"),
        required=True,
    )
    bench_run.add_argument(
        "--mode",
        choices=("raw", "curated"),
        default="raw",
        help="For LoCoMo: 'raw' (L1 turns only) or 'curated' (L1 + L2 summaries + L3 observations)",
    )
    bench_run.add_argument("--dataset", type=Path, default=None, help="Optional explicit dataset JSON path")
    bench_run.add_argument("--cache-dir", type=Path, default=DEFAULT_BENCH_CACHE)
    bench_run.add_argument("--engine-label", type=str, default="raw-memory")
    bench_run.add_argument("--semantic", action="store_true", help="Enable Hybrid BM25 + Local fastembed Semantic Vector RRF")
    bench_run.add_argument("--embed-model", type=str, default=None, help="Optional fastembed ONNX model name")
    bench_run.add_argument("--rerank", action="store_true", help="Enable v0.6 Multi-Chunk MaxSim + Temporal Window + Local Cross-Encoder Reranker")
    bench_run.add_argument("--rerank-model", type=str, default=None, help="Optional local ONNX Cross-Encoder model name")
    bench_run.add_argument("--limit", type=int, default=None, help="Optional limit (conversations for LoCoMo, questions for LongMemEval)")
    bench_run.add_argument("--format", choices=("markdown", "json"), default="markdown")
    bench_run.add_argument("--out", type=Path, default=None)
    bench_run.add_argument("--json-out", type=Path, default=None)

    frozen_cmd = sub.add_parser(
        "bench-frozen",
        help="Run frozen SHA-256 locked RawMemory-Bench v1.0 (9 pillars, 32 cases)",
    )
    frozen_cmd.add_argument("--suite", type=Path, default=default_frozen_suite_path())
    frozen_cmd.add_argument("--engine-label", type=str, default="raw-memory-v0.5.0")
    frozen_cmd.add_argument("--baseline", type=Path, default=None, help="Optional saved baseline JSON for diff")
    frozen_cmd.add_argument("--format", choices=("markdown", "json"), default="markdown")
    frozen_cmd.add_argument("--out", type=Path, default=None)
    frozen_cmd.add_argument("--json-out", type=Path, default=None)

    pers_cmd = sub.add_parser(
        "bench-personal",
        help="Run private local Personal Golden Set against live HubStore (never committed to Git)",
    )
    pers_cmd.add_argument("--data-dir", type=Path, default=default_data_dir())
    pers_cmd.add_argument("--bench", type=Path, default=None)
    pers_cmd.add_argument("--engine-label", type=str, default="raw-memory-v0.5.0-live")
    pers_cmd.add_argument("--format", choices=("markdown", "json"), default="markdown")
    pers_cmd.add_argument("--out", type=Path, default=None)
    pers_cmd.add_argument("--json-out", type=Path, default=None)

    e2e_cmd = sub.add_parser(
        "bench-e2e",
        help="Run 5-stage MemoryBench E2E Judge pipeline (ConvoMem schema) and emit MemScore",
    )
    e2e_cmd.add_argument("--dataset", type=Path, default=None)
    e2e_cmd.add_argument("--engine-label", type=str, default="raw-memory-v0.5.0")
    e2e_cmd.add_argument("--semantic", action="store_true")
    e2e_cmd.add_argument("--embed-model", type=str, default=None)
    e2e_cmd.add_argument("--no-llm-judge", action="store_true")
    e2e_cmd.add_argument("--json-out", type=Path, default=None)

    acad_e2e_cmd = sub.add_parser(
        "bench-e2e-academic",
        help="Official-protocol Academic E2E LLM-as-a-Judge harness for LongMemEval-S and LoCoMo",
    )
    acad_sub = acad_e2e_cmd.add_subparsers(dest="acad_action", required=True)

    acad_prep = acad_sub.add_parser(
        "prepare",
        help="Run local HubStore retrieval and emit strictly blind reader_inputs.jsonl + gold_key.json",
    )
    acad_prep.add_argument(
        "--suite",
        choices=("longmemeval-s", "longmemeval-oracle", "locomo"),
        required=True,
    )
    acad_prep.add_argument("--mode", choices=("raw", "curated"), default="curated")
    acad_prep.add_argument("--dataset", type=Path, default=None)
    acad_prep.add_argument("--cache-dir", type=Path, default=DEFAULT_BENCH_CACHE)
    acad_prep.add_argument("--out-dir", type=Path, required=True)
    acad_prep.add_argument("--limit", type=int, default=None)
    acad_prep.add_argument("--stratified-per-cat", type=int, default=None)
    acad_prep.add_argument("--no-rerank", action="store_true")

    acad_run = acad_sub.add_parser(
        "run",
        help="Execute blind Reader + independent Official Judge via OpenAI-compatible or Gemini API",
    )
    acad_run.add_argument("--pack-dir", type=Path, required=True)
    acad_run.add_argument(
        "--suite",
        choices=("longmemeval-s", "longmemeval-oracle", "locomo-curated", "locomo-raw"),
        required=True,
    )
    acad_run.add_argument("--engine-label", type=str, default="raw-memory-v0.8.0")
    acad_run.add_argument("--reader-model", type=str, default=None)
    acad_run.add_argument("--judge-model", type=str, default=None)
    acad_run.add_argument("--base-url", type=str, default=None)
    acad_run.add_argument("--out", type=Path, default=None)
    acad_run.add_argument("--json-out", type=Path, default=None)

    acad_score = acad_sub.add_parser(
        "score",
        help="Score blind reader_outputs.jsonl + judge_outputs.jsonl into an AcademicE2EReport",
    )
    acad_score.add_argument("--pack-dir", type=Path, required=True)
    acad_score.add_argument("--suite", type=str, required=True)
    acad_score.add_argument("--engine-label", type=str, default="raw-memory-v0.8.0")
    acad_score.add_argument("--reader-model", type=str, required=True)
    acad_score.add_argument("--judge-model", type=str, required=True)
    acad_score.add_argument("--out", type=Path, default=None)
    acad_score.add_argument("--json-out", type=Path, default=None)

    wb_cmd = sub.add_parser(
        "workbench",
        help="Launch localhost Human-in-the-Loop Memory Testing & Debugging Workbench UI",
    )
    wb_cmd.add_argument("--data-dir", type=Path, default=default_data_dir())
    wb_cmd.add_argument("--host", type=str, default="127.0.0.1")
    wb_cmd.add_argument("--port", type=int, default=8765)
    wb_cmd.add_argument("--results-dir", type=Path, default=None)

    adj_cmd = sub.add_parser(
        "debug-summary",
        help="Print summary of recorded human adjudications & debug query feedback",
    )
    adj_cmd.add_argument("--data-dir", type=Path, default=default_data_dir())

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

    if args.command == "bench":
        if args.bench_action == "download":
            suites = None if args.suite == "all" else [args.suite]
            res = download_benchmark_datasets(suites, cache_dir=args.cache_dir, force=args.force)
            sys.stdout.write(json.dumps(res, ensure_ascii=False, indent=2) + "\n")
            return 0
        if args.bench_action == "run":
            manifest = load_manifest()
            info = manifest["suites"][args.suite]
            if args.dataset is not None:
                ds_path = args.dataset
            elif info.get("bundled"):
                ds_path = default_manifest_path().parent.parent / info["filename"]
            else:
                ds_path = Path(args.cache_dir).expanduser() / info["filename"]
            if not ds_path.is_file():
                sys.stderr.write(
                    f"Dataset not found at {ds_path}. Run `raw-memory-eval bench download --suite {args.suite}` first.\n"
                )
                return 2
            if args.suite == "locomo":
                report = evaluate_locomo(
                    ds_path,
                    mode=args.mode,
                    engine_label=args.engine_label,
                    limit_convs=args.limit,
                    use_semantic=args.semantic,
                    embed_model=args.embed_model,
                    use_reranker=args.rerank,
                    rerank_model=args.rerank_model,
                )
            elif args.suite == "convomem-smoke":
                report = evaluate_convomem(
                    ds_path,
                    engine_label=args.engine_label,
                    use_semantic=args.semantic,
                    embed_model=args.embed_model,
                )
            else:
                report = evaluate_longmemeval(
                    ds_path,
                    split_name=args.suite,
                    engine_label=args.engine_label,
                    limit_questions=args.limit,
                    use_semantic=args.semantic,
                    embed_model=args.embed_model,
                    use_reranker=args.rerank,
                    rerank_model=args.rerank_model,
                )
            rendered = (
                render_benchmark_markdown(report)
                if args.format == "markdown"
                else report.model_dump_json(indent=2) + "\n"
            )
            if args.out is not None:
                args.out.expanduser().parent.mkdir(parents=True, exist_ok=True)
                args.out.expanduser().write_text(rendered, encoding="utf-8")
            if args.json_out is not None:
                args.json_out.expanduser().parent.mkdir(parents=True, exist_ok=True)
                args.json_out.expanduser().write_text(report.model_dump_json(indent=2) + "\n", encoding="utf-8")
            sys.stdout.write(rendered)
            return 0

    if args.command == "bench-frozen":
        report = evaluate_rawmemory_bench(args.suite, engine_label=args.engine_label)
        rendered = (
            render_frozen_markdown(report)
            if args.format == "markdown"
            else report.model_dump_json(indent=2) + "\n"
        )
        if args.out is not None:
            args.out.expanduser().parent.mkdir(parents=True, exist_ok=True)
            args.out.expanduser().write_text(rendered, encoding="utf-8")
        if args.json_out is not None:
            args.json_out.expanduser().parent.mkdir(parents=True, exist_ok=True)
            args.json_out.expanduser().write_text(report.model_dump_json(indent=2) + "\n", encoding="utf-8")
        if args.baseline is not None and args.baseline.expanduser().is_file():
            base = json.loads(args.baseline.expanduser().read_text(encoding="utf-8"))
            diff = compute_benchmark_diff(report.model_dump(), base)
            sys.stderr.write(f"Baseline diff: {json.dumps(diff)}\n")
        sys.stdout.write(rendered)
        return 0 if report.overall_pass_rate >= 1.0 and report.integrity_verified else 1

    if args.command == "bench-personal":
        bpath = args.bench or default_personal_bench_path(args.data_dir)
        report = evaluate_personal_golden_set(
            args.data_dir,
            bench_path=bpath,
            engine_label=args.engine_label,
        )
        rendered = (
            render_personal_markdown(report)
            if args.format == "markdown"
            else report.model_dump_json(indent=2) + "\n"
        )
        if args.out is not None:
            args.out.expanduser().parent.mkdir(parents=True, exist_ok=True)
            args.out.expanduser().write_text(rendered, encoding="utf-8")
        if args.json_out is not None:
            args.json_out.expanduser().parent.mkdir(parents=True, exist_ok=True)
            args.json_out.expanduser().write_text(report.model_dump_json(indent=2) + "\n", encoding="utf-8")
        sys.stdout.write(rendered)
        return 0 if report.pii_leak_count == 0 else 1

    if args.command == "bench-e2e":
        ds_path = args.dataset or (
            default_manifest_path().parent / "fixtures" / "convomem_smoke.json"
        )
        e2e_report = evaluate_e2e_convomem(
            ds_path,
            engine_label=args.engine_label,
            use_semantic=args.semantic,
            embed_model=args.embed_model,
            allow_llm_judge=not args.no_llm_judge,
        )
        payload = e2e_report.model_dump_json(indent=2) + "\n"
        if args.json_out is not None:
            args.json_out.expanduser().parent.mkdir(parents=True, exist_ok=True)
            args.json_out.expanduser().write_text(payload, encoding="utf-8")
        sys.stdout.write(payload)
        return 0

    if args.command == "bench-e2e-academic":
        if args.acad_action == "prepare":
            manifest = load_manifest()
            info = manifest["suites"][args.suite]
            ds_path = args.dataset or (Path(args.cache_dir).expanduser() / info["filename"])
            if args.suite == "locomo":
                meta = prepare_locomo_e2e_pack(
                    ds_path,
                    args.out_dir,
                    mode=args.mode,
                    limit_convs=args.limit,
                    stratified_per_cat=args.stratified_per_cat,
                    use_semantic=True,
                    use_reranker=not args.no_rerank,
                )
            else:
                meta = prepare_longmemeval_e2e_pack(
                    ds_path,
                    args.out_dir,
                    split_name=args.suite,
                    limit_questions=args.limit,
                    stratified_per_cat=args.stratified_per_cat,
                    use_semantic=True,
                    use_reranker=not args.no_rerank,
                )
            sys.stdout.write(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
            return 0
        if args.acad_action == "run":
            r_out, j_out, r_mod, j_mod = run_api_reader_and_judge(
                args.pack_dir,
                suite=args.suite,
                reader_model=args.reader_model,
                judge_model=args.judge_model,
                base_url=args.base_url,
            )
            rep = score_academic_e2e(
                args.pack_dir,
                suite=args.suite,
                engine_label=args.engine_label,
                reader_model=r_mod,
                judge_model=j_mod,
                reader_outputs_path=r_out,
                judge_outputs_path=j_out,
            )
            md = render_academic_e2e_markdown(rep)
            if args.out is not None:
                args.out.expanduser().parent.mkdir(parents=True, exist_ok=True)
                args.out.expanduser().write_text(md, encoding="utf-8")
            if args.json_out is not None:
                args.json_out.expanduser().parent.mkdir(parents=True, exist_ok=True)
                args.json_out.expanduser().write_text(rep.model_dump_json(indent=2) + "\n", encoding="utf-8")
            sys.stdout.write(md)
            return 0
        if args.acad_action == "score":
            rep = score_academic_e2e(
                args.pack_dir,
                suite=args.suite,
                engine_label=args.engine_label,
                reader_model=args.reader_model,
                judge_model=args.judge_model,
            )
            md = render_academic_e2e_markdown(rep)
            if args.out is not None:
                args.out.expanduser().parent.mkdir(parents=True, exist_ok=True)
                args.out.expanduser().write_text(md, encoding="utf-8")
            if args.json_out is not None:
                args.json_out.expanduser().parent.mkdir(parents=True, exist_ok=True)
                args.json_out.expanduser().write_text(rep.model_dump_json(indent=2) + "\n", encoding="utf-8")
            sys.stdout.write(md)
            return 0

    if args.command == "workbench":
        import uvicorn

        app = create_workbench_app(args.data_dir, results_dir=args.results_dir)
        sys.stdout.write(
            f"Raw Memory Debug Workbench running at http://{args.host}:{args.port} (data={args.data_dir})\n"
        )
        sys.stdout.flush()
        uvicorn.run(app, host=args.host, port=args.port, log_level="warning")
        return 0

    if args.command == "debug-summary":
        summary = summarize_adjudications(args.data_dir)
        sys.stdout.write(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
