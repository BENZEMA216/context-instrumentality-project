"""CLI for Context Hub v2 Channel Collectors (`doctor`, `sync`, `watch`, `import-chat`)."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from context_hub.mcp_server import default_data_dir
from context_hub.store import HubStore

from .ai_chat import AIChatCollector, parse_export_file
from .audio import (
    AudioCollector,
    GoogleDriveAudioTransport,
    WebDAVAudioTransport,
    build_audio_soak_report,
    discover_audio_paths,
    ensure_sensevoice_models,
    probe_cloud_endpoints,
)
from .clipcontext import ClipContextCollector
from .runtime import (
    CheckpointBackend,
    Collector,
    DirectHubSink,
    HttpHubSink,
    HubCheckpointStore,
    HubSink,
    StandaloneCheckpointStore,
    run_collector,
    watch_collectors,
)


def _build_collectors(
    selected: str,
    *,
    asr_mode: str = "auto",
    since_days: float | None = None,
    max_files_per_provider: int | None = None,
) -> list[Collector]:
    mapping: dict[str, Collector] = {
        "ai_chat": AIChatCollector(
            max_files_per_provider=max_files_per_provider,
            since_days=since_days,
        ),
        "clipcontext": ClipContextCollector(),
        "audio": AudioCollector(asr_mode=asr_mode),
    }
    if selected == "all":
        return list(mapping.values())
    if selected not in mapping:
        raise ValueError(f"Unknown collector: {selected}")
    return [mapping[selected]]


def _build_sink_and_checkpoints(args: argparse.Namespace) -> tuple[HubSink, CheckpointBackend]:
    data_dir = Path(args.data_dir).expanduser() if args.data_dir else default_data_dir()
    if args.hub_url:
        token = args.token
        if not token:
            tok_file = data_dir / "owner.token"
            if tok_file.is_file():
                token = tok_file.read_text(encoding="ascii").strip()
        sink: HubSink = HttpHubSink(
            args.hub_url,
            owner_token=token,
            spool_dir=data_dir / "spool",
        )
        checkpoints: CheckpointBackend = StandaloneCheckpointStore(
            data_dir / "collector_checkpoints.sqlite3"
        )
        return sink, checkpoints
    store = HubStore(data_dir)
    return DirectHubSink(store), HubCheckpointStore(store)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="context-collectors",
        description="Context Hub v2 resilient multi-channel collectors",
    )
    parser.add_argument(
        "--data-dir",
        help="Context Hub data directory (default: ~/.local/share/context-hub-v2 or CONTEXT_HUB_DATA_DIR)",
    )
    parser.add_argument(
        "--hub-url",
        help="Push over HTTP to a running Hub (e.g. http://127.0.0.1:8741) with offline spooling; omit for direct local SQLite mode",
    )
    parser.add_argument("--token", help="Owner bearer token when using --hub-url")

    sub = parser.add_subparsers(dest="command", required=True)

    doc_p = sub.add_parser("doctor", help="Inspect local channel availability & health without mutating state")
    doc_p.add_argument("--collector", default="all", choices=("all", "ai_chat", "clipcontext", "audio"))
    doc_p.add_argument(
        "--since-days",
        type=float,
        default=None,
        help="Only count/select AI chat files modified within the last N days",
    )
    doc_p.add_argument(
        "--max-files",
        type=int,
        default=None,
        help="Optional per-provider file cap for AI chat discovery (default: unlimited)",
    )

    sync_p = sub.add_parser("sync", help="Run one incremental checkpointed sync pass")
    sync_p.add_argument("--collector", default="all", choices=("all", "ai_chat", "clipcontext", "audio"))
    sync_p.add_argument("--asr-mode", default="auto", choices=("auto", "sensevoice", "existing_only"))
    sync_p.add_argument(
        "--since-days",
        type=float,
        default=None,
        help="Only sync AI chat files modified within the last N days",
    )
    sync_p.add_argument(
        "--max-files",
        type=int,
        default=None,
        help="Optional per-provider file cap for AI chat sync (default: unlimited)",
    )

    watch_p = sub.add_parser("watch", help="Run resilient continuous background collector loop")
    watch_p.add_argument("--collector", default="all", choices=("all", "ai_chat", "clipcontext", "audio"))
    watch_p.add_argument("--asr-mode", default="auto", choices=("auto", "sensevoice", "existing_only"))
    watch_p.add_argument("--interval", type=float, default=30.0, help="Polling interval in seconds")
    watch_p.add_argument("--max-ticks", type=int, default=None, help="Optional tick limit for testing")
    watch_p.add_argument(
        "--since-days",
        type=float,
        default=None,
        help="Only watch AI chat files modified within the last N days",
    )
    watch_p.add_argument(
        "--max-files",
        type=int,
        default=None,
        help="Optional per-provider file cap for AI chat watch (default: unlimited)",
    )

    sub.add_parser(
        "download-asr-models",
        help="Download local offline SenseVoice-Small (int8) + Silero-VAD ONNX models into user cache",
    )

    sub.add_parser(
        "probe-cloud",
        help="Test live reachability & latency of Apple CloudKit, Nutstore WebDAV, and Google Drive (proxy vs direct)",
    )

    soak_p = sub.add_parser(
        "audio-soak-report",
        help="Audit live CloudKit Mac companion status, SHA-256 integrity, compression ratio, sequence gaps, and delivery latency",
    )
    soak_p.add_argument("--hours", type=float, default=72.0, help="Lookback soak window in hours (default 72)")
    soak_p.add_argument("--no-probe", action="store_true", help="Skip live HTTP cloud endpoint probing")

    wd_p = sub.add_parser(
        "pull-webdav",
        help="Incrementally pull .ctxaudio.zip packets from WebDAV (e.g. Nutstore/坚果云 or NAS) into inbox/audio",
    )
    wd_p.add_argument("--url", required=True, help="WebDAV folder URL (e.g. https://dav.jianguoyun.com/dav/RecordForAgent/)")
    wd_p.add_argument("--username", required=True)
    wd_p.add_argument("--password", required=True)
    wd_p.add_argument("--use-proxy", action="store_true")

    gd_p = sub.add_parser(
        "pull-gdrive",
        help="Incrementally pull .ctxaudio.zip packets from Google Drive (via system proxy if set) into inbox/audio",
    )
    gd_p.add_argument("--folder-id", required=True, help="Google Drive folder ID")
    gd_p.add_argument("--access-token", required=True, help="Google OAuth access token")

    imp_p = sub.add_parser("import-chat", help="Import exported AI chat files (ChatGPT, Claude Web, Gemini, Codex, Claude, DeepSeek, Antigravity)")
    imp_p.add_argument(
        "--source",
        required=True,
        choices=("chatgpt", "claude-web", "gemini", "codex", "claude", "deepseek", "antigravity", "transcript"),
    )
    imp_p.add_argument("--project", help="Explicit canonical project slug override")
    imp_p.add_argument("files", nargs="+", type=Path)

    args = parser.parse_args(argv)

    if args.command == "download-asr-models":
        status = ensure_sensevoice_models()
        print(json.dumps(status, ensure_ascii=False, indent=2))
        return 0

    if args.command == "probe-cloud":
        print(json.dumps({"endpoints": probe_cloud_endpoints()}, ensure_ascii=False, indent=2))
        return 0

    if args.command == "audio-soak-report":
        rep = build_audio_soak_report(
            since_hours=args.hours,
            probe_cloud=not args.no_probe,
        )
        print(json.dumps(rep, ensure_ascii=False, indent=2))
        return 0 if rep["healthy"] else 1

    if args.command == "doctor":
        cols = _build_collectors(
            args.collector,
            since_days=args.since_days,
            max_files_per_provider=args.max_files,
        )
        out = {"collectors": [c.doctor() for c in cols]}
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    sink, checkpoints = _build_sink_and_checkpoints(args)

    if args.command == "pull-webdav":
        inbox = discover_audio_paths().inbox_dir
        assert inbox is not None
        transport = WebDAVAudioTransport(
            args.url,
            username=args.username,
            password=args.password,
            use_system_proxy=args.use_proxy,
        )
        rep = transport.pull_to_inbox(inbox, checkpoints)
        print(json.dumps(rep.to_dict(), ensure_ascii=False, indent=2))
        return 1 if rep.errors else 0

    if args.command == "pull-gdrive":
        inbox = discover_audio_paths().inbox_dir
        assert inbox is not None
        transport = GoogleDriveAudioTransport(args.access_token, args.folder_id)
        rep = transport.pull_to_inbox(inbox, checkpoints)
        print(json.dumps(rep.to_dict(), ensure_ascii=False, indent=2))
        return 1 if rep.errors else 0

    if args.command == "sync":
        cols = _build_collectors(
            args.collector,
            asr_mode=args.asr_mode,
            since_days=args.since_days,
            max_files_per_provider=args.max_files,
        )
        reports = [run_collector(c, sink, checkpoints).to_dict() for c in cols]
        print(json.dumps({"reports": reports}, ensure_ascii=False, indent=2))
        return 0

    if args.command == "watch":
        cols = _build_collectors(
            args.collector,
            asr_mode=args.asr_mode,
            since_days=args.since_days,
            max_files_per_provider=args.max_files,
        )

        def _on_tick(tick_reports: list[Any]) -> None:
            summary = [
                f"{r.collector}:{r.status}(+{r.created},err={r.skipped_errors},spool={r.spooled})"
                for r in tick_reports
            ]
            print(f"[watch] {' | '.join(summary)}", file=sys.stderr, flush=True)

        watch_collectors(
            cols,
            sink,
            checkpoints,
            interval_seconds=args.interval,
            max_ticks=args.max_ticks,
            on_tick=_on_tick,
        )
        return 0

    if args.command == "import-chat":
        totals = {"files": 0, "events": 0, "created": 0, "existing": 0, "spooled": 0, "errors": 0}
        for path in args.files:
            try:
                events = parse_export_file(path, args.source, project=args.project)
                res = sink.emit_batch(f"import-{args.source}", events)
                totals["files"] += 1
                totals["events"] += len(events)
                totals["created"] += res.get("created", 0)
                totals["existing"] += res.get("existing", 0)
                totals["spooled"] += res.get("spooled", 0)
            except (OSError, ValueError) as exc:
                totals["errors"] += 1
                print(f"[import-chat] skipped {path}: {exc}", file=sys.stderr)
        print(json.dumps(totals, ensure_ascii=False, indent=2))
        return 1 if totals["errors"] else 0

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
