"""Local WeChat conversation capture and scoped, portable JSON exports."""

import argparse
import hashlib
import json
import math
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from time import sleep

from .__main__ import data_dir
from .imports import read_bytes, stable_id
from .store import Store
from .wechat_history import scope_value

SOURCES = ("wechat.message", "wechat.ocr", "wechat.transcript")


def interval(value):
    seconds = float(value)
    if not math.isfinite(seconds) or seconds < 2 or seconds > 86400:
        raise argparse.ArgumentTypeError("Choose an interval of 2–86400 seconds.")
    return seconds


def import_text(store, episode, path, observed_ms):
    """A selected excerpt has neither reliable message boundaries nor original send times."""
    payload = read_bytes(path, maximum=2 * 1024 * 1024)
    text = payload.decode("utf-8-sig")
    if not text.strip() or "\0" in text:
        raise ValueError("Choose a nonempty UTF-8 text file.")
    digest = hashlib.sha256(payload).hexdigest()
    event_id = stable_id("wechat-transcript", episode, digest)
    event = {
        "id": event_id, "episode_id": episode, "source": "wechat.transcript", "kind": "selected_excerpt",
        "t_start": observed_ms, "t_end": observed_ms, "t_observed": observed_ms, "actor": "unknown",
        "content": {"text": text, "title": "手工选取的微信历史片段"},
        "context": {"time_basis": "import_observation", "message_boundaries": "unknown"},
        "provenance": {"connector": "wechat-selected-text", "source_id": event_id, "source_hash": digest,
                       "locator": "sha256:" + digest}, "privacy": {"tier": "local_only"},
    }
    with store._transaction(True) as conn:
        existing = conn.execute("SELECT event IS NULL FROM raw_events WHERE id=?", (event_id,)).fetchone()
        if existing:
            return {"status": "deleted" if existing[0] else "already_imported", "id": event_id}
        store._put_raw(conn, event)
    return {"status": "created", "id": event_id}


def export_episode(store, episode, directory):
    """Stream a consistent owner snapshot; retain the old complete file if writing fails."""
    import fcntl  # The capture/archive CLI runs on macOS or Linux.

    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination = directory / ("wechat-" + episode + ".context.json")
    folder = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    temp = None
    count = 0
    try:
        # Obtain the lock before taking a database snapshot so overlapping exporters cannot
        # replace a fresh archive with a stale one when finishing out of order.
        fcntl.flock(folder, fcntl.LOCK_EX)
        with tempfile.NamedTemporaryFile(dir=directory, mode="w", encoding="utf-8", delete=False) as out:
            temp = Path(out.name)
            out.write("[")
            for event in store.episode_events(episode, SOURCES):
                if count:
                    out.write(",")
                out.write("\n" + event)
                count += 1
            out.write("\n]\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(temp, destination)
    finally:
        if temp:
            temp.unlink(missing_ok=True)
        os.close(folder)
    return {"status": "exported", "records": count, "filename": destination.name}


def capture_command(args):
    helper = str(args.helper.expanduser().resolve()) if args.helper else shutil.which("wechat-ocr")
    if not helper or not Path(helper).is_file() or not os.access(helper, os.X_OK):
        raise ValueError("Build wechat-ocr and supply its path with --helper.")
    config = json.loads(read_bytes(args.calibration, maximum=16384))
    if (not isinstance(config, dict) or config.get("status") != "ok"
            or not all(isinstance(config.get(k), str) and 0 < len(config[k]) < 160
                       for k in ("header", "messages", "window_size"))
            or not all(type(config.get(k)) is int and 0 < config[k] <= 2**32 - 1
                       for k in ("window_id", "process_id"))):
        raise ValueError("Expected the JSON produced by a successful wechat-ocr calibrate.")
    return [helper, "capture", "--title", scope_value(args.title), "--header", config["header"],
            "--messages", config["messages"], "--window-size", config["window_size"],
            "--window-id", str(config["window_id"]), "--process-id", str(config["process_id"])]


def sample(store, command, account, conversation):
    from .wechat_ocr import observe_frame

    # The helper returns only the matched message pane. Do not forward subprocess
    # diagnostics, command lines or frame text into scheduled task logs.
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=45)
    if result.returncode:
        raise RuntimeError("The OCR helper failed; check its permissions and calibration.")
    if len(result.stdout) > 2 * 1024 * 1024:
        raise ValueError("OCR frame exceeds the expected size.")
    try:
        frame = json.loads(result.stdout)
    except (UnicodeError, ValueError):
        raise ValueError("The OCR helper returned invalid JSON.") from None
    return observe_frame(store, frame, account=account, conversation=conversation,
                         observed_ms=time.time_ns() // 1_000_000)


def report(status):
    print(json.dumps(status, ensure_ascii=False), flush=True)


def watch(store, args, episode):
    from .wechat_ocr import observe_frame

    command = capture_command(args)
    next_export = 0.0
    previous = None
    while True:
        failed = False
        try:
            outcome = sample(store, command, args.account, args.conversation)
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, sqlite3.Error) as exc:
            outcome = {"status": "error", "stage": "capture", "error": type(exc).__name__}
            try:
                observe_frame(store, {"status": "skipped", "reason": "capture_failed"},
                              account=args.account, conversation=args.conversation,
                              observed_ms=time.time_ns() // 1_000_000)
            except sqlite3.Error:
                pass  # The next poll retries the database too.
            failed = True
        if args.once or outcome != previous:
            report(outcome)
        previous = outcome
        if args.export_dir and time.monotonic() >= next_export:
            try:
                report(export_episode(store, episode, args.export_dir))
                next_export = time.monotonic() + args.export_every
            except (OSError, sqlite3.Error) as exc:
                report({"status": "error", "stage": "export", "error": type(exc).__name__})
                failed = True
        if args.once:
            return int(failed)
        sleep(args.interval)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="context-hub-wechat", description=__doc__)
    parsers = parser.add_subparsers(dest="action", required=True)
    capture = parsers.add_parser("watch", help="Sample the selected, visible Mac WeChat conversation")
    capture.add_argument("--title", required=True, help="Exact visible conversation title")
    capture.add_argument("--calibration", type=Path, required=True, help="JSON from wechat-ocr calibrate")
    capture.add_argument("--helper", type=Path, help="Path to the built wechat-ocr executable")
    capture.add_argument("--interval", type=interval, default=15, help="Seconds between samples (default 15)")
    capture.add_argument("--once", action="store_true", help="Run one capture and optional export, then exit")
    capture.add_argument("--export-dir", type=Path, help="Also maintain a portable JSON snapshot here")
    capture.add_argument("--export-every", type=interval, default=300, help="Seconds between snapshots (default 300)")
    export = parsers.add_parser("export", help="Export the selected conversation's active evidence as ContextEvent JSON")
    export.add_argument("--export-dir", type=Path, required=True)
    transcript = parsers.add_parser("import-text", help="Import one manually selected UTF-8 history excerpt")
    transcript.add_argument("file", type=Path)
    for sub in (capture, export, transcript):
        sub.add_argument("--account", required=True, help="Your stable local account alias")
        sub.add_argument("--conversation", required=True, help="Stable conversation ID (WeFlow session.accountId, if known)")
        sub.add_argument("--data-dir", type=Path, default=data_dir(), help="Local Context Hub data directory")
    args = parser.parse_args(argv)
    try:
        if os.getenv("HUB_MODE", "local") != "local":
            raise ValueError("WeChat capture/export requires the local Hub data directory.")
        episode = stable_id("wechat-conversation", scope_value(args.account), scope_value(args.conversation))
        store = Store(args.data_dir / "local.sqlite3")
        if args.action == "watch":
            try:
                return watch(store, args, episode)
            except KeyboardInterrupt:
                if args.export_dir:
                    report(export_episode(store, episode, args.export_dir))
                return 0
        if args.action == "import-text":
            report(import_text(store, episode, args.file, time.time_ns() // 1_000_000))
        else:
            report(export_episode(store, episode, args.export_dir))
        return 0
    except KeyboardInterrupt:
        return 0
    except (OSError, ValueError, sqlite3.Error) as exc:
        parser.exit(1, f"WeChat channel: {exc}\n")


if __name__ == "__main__":
    sys.exit(main())
