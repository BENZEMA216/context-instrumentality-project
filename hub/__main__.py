"""Start the Hub, open its owner page, or connect a local MCP host."""
import argparse
import ipaddress
import json
import math
import os
import secrets
import sys
import threading
import webbrowser
from pathlib import Path
from tempfile import NamedTemporaryFile
from urllib.parse import quote, urlsplit


def data_dir():
    if "HUB_DATA_DIR" in os.environ:
        return Path(os.environ["HUB_DATA_DIR"]).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/Context Hub"
    return Path(os.getenv("XDG_DATA_HOME", Path.home() / ".local/share")) / "context-hub"


def credential(directory, role, create=False):
    token = os.getenv("HUB_" + role.upper() + "_TOKEN")
    if token:
        return token
    directory = Path(directory)
    path = directory / (role + ".token")
    if create and not path.exists():
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with NamedTemporaryFile(dir=directory, mode="w", encoding="ascii", delete=False) as tmp:
            temp = Path(tmp.name)
            tmp.write(secrets.token_urlsafe(32))
        try:
            os.link(temp, path)
        except FileExistsError:
            pass
        finally:
            temp.unlink()
    if not path.is_file():
        raise ValueError(f"Missing {role} token. Start this local Hub or set HUB_{role.upper()}_TOKEN.")
    return path.read_text(encoding="ascii").strip()


def local_host(name):
    if name == "localhost":
        return True
    try:
        return ipaddress.ip_address(name).is_loopback
    except ValueError:
        return False


def main(argv=None):
    cli = argparse.ArgumentParser(prog="context-hub")
    commands = cli.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="Serve the UI/API and periodic Memory worker")
    serve.add_argument("--data-dir", type=Path, default=data_dir())
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8741)
    serve.add_argument("--mode", choices=("local", "cloud"), default=os.getenv("HUB_MODE", "local"))
    serve.add_argument("--interval", type=float, default=60, help="Seconds between extraction cycles")
    browse = commands.add_parser("open", help="Open the owner page on this computer")
    browse.add_argument("--data-dir", type=Path, default=data_dir())
    browse.add_argument("--port", type=int, default=8741)
    token = commands.add_parser("token", help="Print the requested credential for the owner of this installation")
    token.add_argument("role", choices=("agent", "owner"))
    token.add_argument("--data-dir", type=Path, default=data_dir())
    mcp = commands.add_parser("mcp", help="Run the agent-scoped stdio MCP bridge")
    mcp.add_argument("--data-dir", type=Path, default=data_dir())
    args = cli.parse_args(argv)
    try:
        if args.command == "token":
            print(credential(args.data_dir, args.role))
            return
        if args.command == "open":
            # Only place a local owner's credential in a loopback URL fragment.
            key = credential(args.data_dir, "owner")
            webbrowser.open(f"http://127.0.0.1:{args.port}/#token={quote(key, safe='')}")
            return
        if args.command == "mcp":
            from .agent import main as agent_main
            url = urlsplit(os.getenv("HUB_URL", "http://127.0.0.1:8741"))
            if not os.getenv("HUB_AGENT_TOKEN") and local_host(url.hostname):
                os.environ["HUB_AGENT_TOKEN"] = credential(args.data_dir, "agent")
            return agent_main()
        from .server import HubHTTP, run_worker
        from .store import Store
        if args.mode not in ("local", "cloud"):
            raise ValueError("Unknown HUB_MODE")
        if not local_host(args.host) and args.mode != "cloud":
            raise ValueError("Use loopback for local data; remote serving requires --mode cloud")
        if not math.isfinite(args.interval) or args.interval <= 0:
            raise ValueError("--interval must be positive")
        args.data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        owner, agent = (credential(args.data_dir, role, create=True) for role in ("owner", "agent"))
        # Keep operational data and credentials for different privacy modes separate.
        store = Store(args.data_dir / (args.mode + ".sqlite3"))
        stopped = threading.Event()
        with HubHTTP((args.host, args.port), store, owner, agent, args.mode) as server:
            worker = threading.Thread(target=run_worker, args=(store, args.interval, stopped), daemon=True)
            worker.start()
            print(json.dumps({"status": "ready", "mode": args.mode, "host": args.host,
                              "port": server.server_port, "interval_seconds": args.interval}), flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
            finally:
                stopped.set()
                worker.join()
    except (ValueError, OSError) as exc:
        cli.exit(2, f"context-hub: {exc}\n")


if __name__ == "__main__":
    main()
