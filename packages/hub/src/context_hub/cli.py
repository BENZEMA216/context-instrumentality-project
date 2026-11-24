"""Command-line entry point for Context Hub v2."""

from __future__ import annotations

import argparse
import json
import sys
import webbrowser
from pathlib import Path

import uvicorn

from .api import create_app, seed_demo_data
from .curation_rules import build_curator_prompt
from .mcp_server import default_data_dir, run_stdio_mcp
from .store import HubStore


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="raw-memory",
        description="Raw Memory — Local-first personal raw data store, evidence-gated Memory engine & Agent-as-Curator MCP",
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=default_data_dir(),
        help="Local Hub data directory (default: ~/.local/share/context-hub-v2)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    serve = sub.add_parser("serve", help="Run the HTTP API and Context Workbench UI")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8741)

    mcp = sub.add_parser("mcp", help="Run the stdio MCP server for Antigravity / Codex / WorkBuddy")
    mcp.add_argument(
        "--allow-local-only-curation",
        action="store_true",
        help="Permit trusted local Curator Agent to inspect/curate local_only episodes (derived outputs remain local_only)",
    )

    open_cmd = sub.add_parser("open", help="Open Context Workbench in your default browser")
    open_cmd.add_argument("--port", type=int, default=8741)

    sub.add_parser("status", help="Print JSON summary of local Hub data and curation queue")
    sub.add_parser("seed-demo", help="Load a multi-channel synthetic demo dataset")
    sub.add_parser("rebuild", help="Rebuild L1 SQLite index & links from immutable L0 raw/ logs")
    sub.add_parser(
        "reconcile-projects",
        help="Re-normalize project names across raw_events, episodes, decisions & memories using project_aliases.json",
    )

    prompt_cmd = sub.add_parser(
        "curate-prompt",
        help="Print a ready-to-paste curation prompt for Antigravity, Codex, or WorkBuddy",
    )
    prompt_cmd.add_argument("--agent", default="antigravity")
    prompt_cmd.add_argument("--project", default=None)
    prompt_cmd.add_argument("--limit", type=int, default=5)

    args = parser.parse_args(argv)

    if args.command == "serve":
        app = create_app(args.data_dir)
        uvicorn.run(app, host=args.host, port=args.port, log_level="info")
        return 0

    if args.command == "mcp":
        run_stdio_mcp(args.data_dir, allow_local_only_curation=args.allow_local_only_curation)
        return 0

    if args.command == "open":
        webbrowser.open(f"http://127.0.0.1:{args.port}/")
        return 0

    if args.command == "curate-prompt":
        print(
            build_curator_prompt(
                curator_agent=args.agent, project=args.project, limit=args.limit
            )
        )
        return 0

    store = HubStore(args.data_dir)
    if args.command == "status":
        print(json.dumps(store.stats(), ensure_ascii=False, indent=2))
    elif args.command == "seed-demo":
        print(json.dumps(seed_demo_data(store), ensure_ascii=False, indent=2))
    elif args.command == "rebuild":
        print(json.dumps(store.rebuild_from_l0(), ensure_ascii=False, indent=2))
    elif args.command == "reconcile-projects":
        print(json.dumps(store.reconcile_projects(), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
