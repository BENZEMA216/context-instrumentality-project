"""Commands for the owner, including encrypted backups and new-device restoration."""

import argparse
import getpass
import os
import secrets
import sys
import subprocess
import time
import json
import tempfile
import webbrowser
from pathlib import Path
from urllib.parse import quote
from urllib.request import ProxyHandler, build_opener

from . import intake
from .service import Service, VaultHTTP, icloud_folder
from .storage import Store, VaultError


def data_dir():
    if "CONTEXT_VAULT_DATA" in os.environ:
        return Path(os.environ["CONTEXT_VAULT_DATA"]).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/Context Vault"
    return (
        Path(os.getenv("XDG_DATA_HOME", Path.home() / ".local/share")) / "context-vault"
    )


def token(directory, role, create=False):
    path = directory / (role + ".token")
    if not path.exists() and create:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=directory, mode="w", delete=False) as out:
            tmp = Path(out.name)
            out.write(secrets.token_urlsafe(32))
        try:
            os.link(tmp, path)
        except FileExistsError:
            pass
        finally:
            tmp.unlink()
    if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
        raise VaultError(
            "No private credential available. Start the Vault service first."
        )
    return path.read_text(encoding="ascii").strip()


def launch(directory, port):
    url = f"http://127.0.0.1:{port}/health"
    http = build_opener(ProxyHandler({}))

    def ready():
        try:
            with http.open(url, timeout=0.4) as reply:
                status = json.loads(reply.read(2048))
            return (
                isinstance(status, dict)
                and type(status.get("initialized")) is bool
                and "icloud_available" in status
            )
        except (OSError, ValueError):
            return False

    if not ready():
        subprocess.Popen(
            [
                sys.executable,
                "-m",
                "context_vault.cli",
                "--data-dir",
                str(directory),
                "serve",
                "--port",
                str(port),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
        for _ in range(40):
            if ready():
                break
            time.sleep(0.1)
        else:
            raise VaultError(
                "Vault did not start. Run context-vault serve to see the startup error."
            )


def main(argv=None):
    parser = argparse.ArgumentParser(prog="context-vault")
    parser.add_argument("--data-dir", type=Path, default=data_dir())
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--port", type=int, default=8743)
    serve.add_argument(
        "--container-bind",
        action="store_true",
        help="For a container published only to host loopback",
    )
    serve.add_argument("--idle-seconds", type=int, default=300)
    open_page = sub.add_parser("open")
    open_page.add_argument("--port", type=int, default=8743)
    launch_page = sub.add_parser(
        "launch", help="Start the personal service and open its owner page"
    )
    launch_page.add_argument("--port", type=int, default=8743)
    sub.add_parser("token").add_argument("role", choices=["owner", "agent"])
    backup = sub.add_parser("backup")
    dest = backup.add_mutually_exclusive_group(required=True)
    dest.add_argument("--icloud", action="store_true")
    dest.add_argument("--folder", type=Path)
    sub.add_parser("restore").add_argument("snapshot", type=Path)
    sub.add_parser("mcp")
    args = parser.parse_args(argv)
    directory = args.data_dir.expanduser().absolute()
    try:
        if args.command == "serve":
            if not 15 <= args.idle_seconds <= 86400:
                raise VaultError("Choose an idle timeout between 15 and 86400 seconds.")
            svc = Service(
                directory,
                token(directory, "owner", True),
                token(directory, "agent", True),
                idle_seconds=args.idle_seconds,
                backups=icloud_folder(),
            )
            addr = ("0.0.0.0" if args.container_bind else "127.0.0.1", args.port)
            with VaultHTTP(addr, svc) as http:
                print(
                    f"Context Vault listening on {addr[0]}:{http.server_port}",
                    flush=True,
                )
                try:
                    http.serve_forever()
                except KeyboardInterrupt:
                    pass
                finally:
                    with svc.mutex:
                        svc.lock()
        elif args.command == "token":
            print(token(directory, args.role))
        elif args.command in ("open", "launch"):
            if args.command == "launch":
                launch(directory, args.port)
            url = f"http://127.0.0.1:{args.port}/#token=" + quote(
                token(directory, "owner"), safe=""
            )
            webbrowser.open(url)
        elif args.command == "mcp":
            os.environ["CONTEXT_VAULT_DATA"] = str(directory)
            from .mcp_bridge import main as mcp_main

            mcp_main()
        elif args.command == "backup":
            folder = icloud_folder() if args.icloud else args.folder
            if folder is None:
                raise VaultError("Enable iCloud Drive on this Mac or use --folder.")
            print(Store(directory).backup(folder))
        else:
            store = Store(directory)
            store.restore(args.snapshot, getpass.getpass("Vault passphrase: "))
            try:
                intake.pairing(store, directory)
            finally:
                store.lock()
            print("Encrypted vault restored. Unlock it in the owner page.")
    except (ValueError, OSError) as exc:
        parser.exit(2, f"context-vault: {exc}\n")


if __name__ == "__main__":
    main()
