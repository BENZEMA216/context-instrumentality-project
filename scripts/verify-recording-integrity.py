#!/usr/bin/env python3
"""Collect Watch-local integrity reports. No audio export and no installation.

capture defaults to incremental quick mode; full hashes on the Watch. A timeout
keeps the request so `fetch --request ...` can collect its eventual result.
"""
import argparse
from contextlib import contextmanager
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urlparse
import uuid

REMOTE_ROOT = "Library/Application Support/WristRecordIntegrity"
MAX_REPORT_BYTES = 32 * 1024 * 1024
SHA = re.compile(r"^[0-9a-f]{64}$")


class IntegrityError(Exception):
    pass


def require(condition, code):
    if not condition:
        raise IntegrityError(code)


def canonical(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def private_directory(path):
    path = Path(path).absolute()
    require(not path.is_symlink(), "state_directory_symlink")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(path.is_dir() and path.stat().st_uid == os.getuid(), "state_directory_owner")
    require(path.stat().st_mode & 0o077 == 0, "state_directory_must_be_private")
    return path


def atomic(path, value):
    data = value if isinstance(value, bytes) else canonical(value)
    fd, temporary = tempfile.mkstemp(prefix=".integrity-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def report_bytes(path):
    """Read one stable regular JSON leaf, never an alias or an unbounded stream."""
    path = Path(path)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise IntegrityError("report_file_invalid") from None
        raise
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1, "report_file_invalid")
        require(0 < before.st_size <= MAX_REPORT_BYTES, "report_too_large")
        chunks, total = [], 0
        while True:
            chunk = os.read(descriptor, min(65_536, MAX_REPORT_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            require(total <= MAX_REPORT_BYTES, "report_too_large")
        after = os.fstat(descriptor)
        # Bind both the open file and its named leaf. Replacement, truncation,
        # in-place writes and a newly introduced hard link all invalidate it.
        named = os.stat(path, follow_symlinks=False)
        def identity(value):
            return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
                    value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        require(identity(before) == identity(after) == identity(named) and total == after.st_size,
                "report_changed_during_read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def parse_report(data):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "report_duplicate_json_key")
            result[key] = value
        return result
    def invalid_constant(_):
        raise IntegrityError("report_nonfinite_json_number")
    try:
        value = json.loads(data, object_pairs_hook=unique_object, parse_constant=invalid_constant)
    except (ValueError, UnicodeError, RecursionError):
        raise IntegrityError("report_json_invalid") from None
    require(type(value) is dict, "report_json_invalid")
    return value


def load(path):
    return parse_report(report_bytes(path))


def request_id(value):
    require(isinstance(value, str), "request_id_invalid")
    try:
        require(str(uuid.UUID(value)) == value, "request_id_invalid")
    except ValueError:
        raise IntegrityError("request_id_invalid") from None
    return value


def validate_report(report, request, bundle):
    require(report.get("schemaVersion") == 1, "report_schema")
    require(report.get("requestID") == request["requestID"], "report_nonce_mismatch")
    require(report.get("mode") == request["mode"], "report_mode_mismatch")
    require(report.get("appBundleID") == bundle, "report_bundle_mismatch")
    require(report.get("status") in {"complete", "incomplete", "deferred", "failed"}, "report_status")
    if report["status"] != "complete":
        return report
    audit = report.get("audit")
    require(isinstance(audit, dict), "report_audit_missing")
    require(audit.get("nonce") == request["requestID"], "audit_nonce_mismatch")
    require(audit.get("mode") == request["mode"], "audit_mode_mismatch")
    require(report.get("usedBaselineID") == request.get("expectedBaselineID"), "used_baseline_mismatch")
    started, ended = audit.get("startedAt"), audit.get("endedAt")
    generated = report.get("generatedAtUnixMS")
    require(all(type(value) is int for value in (started, ended, generated))
            and 0 <= ended - started <= 3_600_000 and ended <= generated + 5_000, "observation_window_invalid")
    require(audit.get("isComplete") is True and audit.get("passed") is True, "audit_not_passed")
    require(isinstance(audit.get("libraryGeneration"), str) and audit["libraryGeneration"], "generation_missing")
    require(SHA.fullmatch(audit.get("catalogDigest", "")) is not None, "catalog_digest_invalid")
    require(SHA.fullmatch(report.get("baselineID", "")) is not None, "baseline_id_invalid")
    require(isinstance(audit.get("entries"), list), "entries_missing")
    require(audit.get("nonAtomicSnapshot") is True and audit.get("issues") == [], "audit_observation_invalid")
    paths = set()
    hashed, historical, resumed, pruned, recovered, retained, physical_bytes = 0, 0, 0, 0, 0, 0, 0
    for entry in audit["entries"]:
        path = entry.get("relativePath")
        require(isinstance(path, str) and not path.startswith("/") and ".." not in Path(path).parts
                and path not in paths, "catalog_member_invalid")
        paths.add(path)
        kind, verification = entry.get("sourceKind"), entry.get("verification")
        require(kind in {"sealed_audio", "recovered_original", "manifest", "acknowledgement", "receipt", "session"},
                "catalog_kind_invalid")
        require(entry.get("issueCode") is None, "entry_failed")
        expected = entry.get("expectedSHA256")
        if expected is not None:
            require(isinstance(expected, str) and SHA.fullmatch(expected) is not None, "expected_digest_invalid")
        if verification == "acknowledgedPruned":
            require(kind == "sealed_audio" and expected and entry.get("identity") is None
                    and entry.get("observedSHA256") is None and entry.get("bytesHashed") == 0,
                    "pruned_entry_invalid")
            pruned += 1
            continue
        observed, identity = entry.get("observedSHA256"), entry.get("identity")
        require(isinstance(observed, str) and SHA.fullmatch(observed) is not None, "observed_digest_missing")
        require(isinstance(identity, dict) and type(identity.get("byteCount")) is int
                and identity["byteCount"] >= 0, "file_identity_missing")
        require(expected is None or expected == observed, "observed_expected_mismatch")
        observed_at = entry.get("hashObservedAt")
        require(type(observed_at) is int and observed_at <= ended + 1, "hash_observation_time_invalid")
        if verification != "historicalHashMetadataUnchanged":
            require(observed_at >= started - 1, "hash_outside_observation_window")
        if kind == "sealed_audio":
            require(expected is not None and entry.get("expectedByteCount") == identity["byteCount"],
                    "audio_source_binding_invalid")
            retained += 1
        if kind == "recovered_original":
            recovered += 1
        if verification == "currentHash":
            require(entry.get("bytesHashed") == identity["byteCount"], "actual_hash_bytes_invalid")
            physical_bytes += identity["byteCount"]
            hashed += 1
        elif verification == "checkpointHashMetadataUnchanged":
            require(entry.get("bytesHashed") == 0, "checkpoint_bytes_invalid")
            resumed += 1
        elif verification == "historicalHashMetadataUnchanged":
            require(request["mode"] == "quick" and kind in {"sealed_audio", "recovered_original"}
                    and entry.get("bytesHashed") == 0, "historical_hash_scope_invalid")
            historical += 1
        else:
            raise IntegrityError("entry_verification_invalid")
    require(audit.get("currentHashCount") == hashed and audit.get("filesHashedThisCall") == hashed
            and audit.get("historicalHashCount") == historical and audit.get("bytesHashed") == physical_bytes
            and audit.get("filesHashedInObservationWindow") == hashed + resumed
            and audit.get("retainedAudioCount") == retained and audit.get("recoveredOriginalCount") == recovered
            and audit.get("acknowledgedPrunedCount") == pruned
            and audit.get("expectedSourceCount") == retained + pruned, "coverage_counts_invalid")
    if request["mode"] == "full":
        require(audit.get("fullContentVerified") is True, "full_content_incomplete")
    return report


def validate_host(host):
    require(host.get("hostSchemaVersion") == 1, "host_schema")
    request = host["request"]
    request_id(request.get("requestID"))
    validate_report(host["watchReport"], request, host["appBundleID"])
    require(host["watchReport"]["status"] == "complete", "host_report_incomplete")
    require(digest(canonical(host["watchReport"])) == host.get("watchReportCanonicalSHA256"), "host_report_digest_mismatch")
    require(host.get("audioBytesCopied") == 0, "unexpected_audio_copy")
    require(host["watchReport"]["audit"]["startedAt"] >= host["createdAtUnixMS"] - 5_000
            and host["watchReport"]["generatedAtUnixMS"] <= host["receivedAtUnixMS"] + 5_000,
            "host_observation_time_invalid")
    if host.get("expectedLibraryGeneration") is not None:
        require(host["watchReport"]["audit"]["libraryGeneration"] == host["expectedLibraryGeneration"],
                "library_generation_changed")
    return host


class Collector:
    def __init__(self, directory, device, bundle, lock_fd=None):
        self.directory, self.device, self.bundle = directory, device, bundle
        self.lock_fd = lock_fd
        self.sequence = 0

    def native(self, arguments):
        self.sequence += 1
        operation = private_directory(self.directory / ("native-%04d" % self.sequence))
        raw = operation / "result.json"
        argv = ["xcrun", "devicectl", *arguments, "--timeout", "45", "--json-output", str(raw), "--quiet"]
        started = time.time()
        timed_out = False
        with open(operation / "stdout", "xb") as stdout, open(operation / "stderr", "xb") as stderr:
            try:
                result = subprocess.run(argv, stdout=stdout, stderr=stderr, timeout=60, check=False,
                                        pass_fds=() if self.lock_fd is None else (self.lock_fd,))
                code = result.returncode
            except subprocess.TimeoutExpired:
                timed_out, code = True, None
        atomic(operation / "process.json", {"arguments": argv, "actualExitCode": code,
               "startedAtUnix": started, "completedAtUnix": time.time(), "hardTimeout": timed_out})
        if code != 0 or not raw.is_file():
            return None
        value = load(raw)
        require(value.get("info", {}).get("outcome") == "success", "native_outcome_invalid")
        require(value.get("info", {}).get("arguments") == argv[1:], "native_arguments_invalid")
        return value.get("result", {})

    def report_metadata(self, source):
        # Query only the exact nonce-named JSON leaf in the diagnostic mailbox.
        # Do not enumerate recordings, recurse, or follow a report-supplied path.
        prefix = REMOTE_ROOT + "/reports/"
        require(isinstance(source, str) and source.startswith(prefix) and source.endswith(".json"),
                "report_source_invalid")
        leaf = source[len(prefix):]
        request_id(leaf[:-5])
        result = self.native(["device", "info", "files", "--device", self.device,
                              "--domain-type", "appDataContainer", "--domain-identifier", self.bundle,
                              "--subdirectory", prefix[:-1], "--no-recurse", "--filter", "Name = '" + leaf + "'"])
        if result is None:
            return None
        require(result.get("deviceIdentifier") == self.device and result.get("domainIdentifier") == self.bundle
                and not result.get("error") and not result.get("errors"), "native_metadata_scope_mismatch")
        files = result.get("files")
        require(type(files) is list, "native_metadata_invalid")
        if not files:
            return None  # No report yet; leave the delivered request pending.
        require(len(files) == 1 and type(files[0]) is dict, "native_metadata_invalid")
        item = files[0]
        resources, metadata = item.get("resources"), item.get("metadata")
        require(type(resources) is dict and type(metadata) is dict and
                item.get("name") == item.get("relativePath") == leaf and
                resources.get("isDirectory") is False and resources.get("isSymbolicLink") is False and
                resources.get("isReadable") is True, "native_metadata_leaf_invalid")
        size = metadata.get("size")
        require(type(size) is int and 0 < size <= MAX_REPORT_BYTES, "report_too_large")
        return size

    def copy(self, direction, source, destination):
        require(direction in {"to", "from"}, "native_copy_direction_invalid")
        if direction == "from" and self.report_metadata(source) is None:
            return False
        result = self.native(["device", "copy", direction, "--device", self.device,
                              "--source", str(source), "--destination", str(destination),
                              "--domain-type", "appDataContainer", "--domain-identifier", self.bundle])
        if result is None:
            return False
        require(result.get("deviceIdentifier") == self.device and result.get("domain") == "appDataContainer"
                and result.get("domainIdentifier") == self.bundle, "native_scope_mismatch")
        def path_value(value):
            return unquote(urlparse(value).path) if value.startswith("file:") else value
        actual_source = path_value(result.get("source", ""))
        actual_destination = path_value(result.get("destination", ""))
        if direction == "to":
            # devicectl reports local sources as file URLs (possibly /private/var
            # aliases), and destinations as absolute URLs inside the bound container.
            require(Path(actual_source).resolve() == Path(source).resolve(), "native_source_mismatch")
            require(actual_destination == str(destination)
                    or actual_destination.endswith("/" + str(destination)), "native_destination_mismatch")
        else:
            require(actual_source == str(source) or actual_source.endswith("/" + str(source)), "native_source_mismatch")
            require(Path(actual_destination).resolve() == Path(destination).resolve(), "native_destination_mismatch")
            # Metadata is only a preflight: the report can be atomically replaced
            # before native copy. Check the copied bytes independently as well.
            report_bytes(destination)
        return True

    def launch(self):
        # Never terminate an existing recorder to deliver diagnostic arguments.
        require(self.native(["device", "process", "launch", "--device", self.device, self.bundle]) is not None,
                "watch_launch_failed_request_preserved")


def poll(collector, ticket, seconds, initial_wait=0):
    require(0 <= initial_wait <= min(3600, seconds), "initial_wait_invalid")
    started = time.monotonic()
    started_unix_ms = int(time.time() * 1000)
    deadline = started + seconds
    request = ticket["request"]
    remote = REMOTE_ROOT + "/reports/" + request_id(request["requestID"]) + ".json"
    last = None
    wait_ended = None
    read_attempts = 0

    def finish(result, host=None):
        ended = time.monotonic()
        quiet_end = ended if wait_ended is None else wait_ended
        # Host collection timing is separate from the Watch audit observation window.
        timing = {"timeoutSeconds": seconds, "initialWaitRequestedSeconds": initial_wait,
                  "initialWaitElapsedSeconds": max(0, quiet_end - started),
                  "reportPollingElapsedSeconds": max(0, ended - quiet_end),
                  "reportReadAttempts": read_attempts, "totalElapsedSeconds": max(0, ended - started),
                  "startedAtUnixMS": started_unix_ms, "finishedAtUnixMS": int(time.time() * 1000)}
        atomic(collector.directory / "collection-timing.json", timing)
        if host is not None:
            host["collectorTiming"] = timing
            atomic(collector.directory / "report.json", host)
            if result["status"] == "complete":
                validate_host(host)
                atomic(Path(ticket["stateDirectory"]) / "latest-report.json", host)
        return {**result, "collectorTiming": timing}

    pending = {"status": "pending", "request": str(collector.directory / "request-ticket.json"),
               "audioBytesCopied": 0}
    try:
        # No device operations occur in this interruptible quiet period. It consumes
        # the same soft timeout as polling; an in-flight native copy may still overrun.
        if initial_wait:
            time.sleep(initial_wait)
        wait_ended = time.monotonic()
        while time.monotonic() < deadline:
            local = collector.directory / ("received-%04d.json" % (collector.sequence + 1))
            read_attempts += 1
            if collector.copy("from", remote, local):
                data = report_bytes(local)
                report = validate_report(parse_report(data), request, ticket["appBundleID"])
                last = report["status"]
                if last in {"complete", "failed"}:
                    host = {**ticket, "watchReport": report, "receivedAtUnixMS": int(time.time() * 1000),
                            "watchReportSHA256": digest(data), "audioBytesCopied": 0,
                            "watchReportCanonicalSHA256": digest(canonical(report)),
                            "backupRecoverableEstablishedByThisCheck": False}
                    if last == "complete":
                        return finish({"status": "complete", "mode": request["mode"],
                                       "fullContentVerified": report["audit"]["fullContentVerified"],
                                       "report": str(collector.directory / "report.json"), "audioBytesCopied": 0}, host)
                    return finish({"status": "failed", "error": report.get("errorCode", "watch_audit_failed"),
                                   "report": str(collector.directory / "report.json"), "audioBytesCopied": 0}, host)
            time.sleep(min(3, max(0, deadline - time.monotonic())))
    except KeyboardInterrupt:
        # The Watch may still be auditing. Preserve its request and never infer completion.
        return finish({**pending, "lastWatchStatus": last, "interrupted": True})
    return finish({**pending, "lastWatchStatus": last})


@contextmanager
def device_lock(path):
    private_directory(path.parent)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise IntegrityError("device_operation_in_progress") from None
        yield descriptor
    finally:
        # Closing our copy leaves an inherited child lock valid until it exits.
        os.close(descriptor)


def capture(args, lock_fd=None):
    state = private_directory(args.state_dir)
    identifier = str(uuid.uuid4())
    directory = private_directory(state / identifier)
    request = {"schemaVersion": 1, "requestID": identifier, "mode": args.mode}
    baseline_path = Path(args.baseline) if args.baseline else state / "latest-report.json"
    if args.new_baseline:
        require(args.mode == "full", "new_baseline_requires_full")
    elif baseline_path.exists():
        baseline = validate_host(load(baseline_path))
        require(baseline["deviceArgument"] == args.device and baseline["appBundleID"] == args.bundle_id,
                "baseline_device_mismatch")
        request["expectedBaselineID"] = baseline["watchReport"]["baselineID"]
    elif args.baseline:
        raise IntegrityError("explicit_baseline_missing")
    ticket = {"hostSchemaVersion": 1, "deviceArgument": args.device, "appBundleID": args.bundle_id,
              "createdAtUnixMS": int(time.time() * 1000), "request": request, "stateDirectory": str(state)}
    if "expectedBaselineID" in request:
        ticket["expectedLibraryGeneration"] = baseline["watchReport"]["audit"]["libraryGeneration"]
    atomic(directory / "request-ticket.json", ticket)
    request_path = directory / "request.json"
    atomic(request_path, request)
    collector = Collector(directory, args.device, args.bundle_id, lock_fd)
    collector.launch()  # Initializes the small sibling mailbox on a new installation.
    # Only this small diagnostic mailbox is written. Recording data is read on Watch.
    require(collector.copy("to", request_path, REMOTE_ROOT + "/request.json"), "request_delivery_failed")
    return poll(collector, ticket, args.timeout, args.initial_wait)


def fetch(args, lock_fd=None):
    ticket_path = Path(args.request).absolute()
    ticket = load(ticket_path)
    request_id(ticket["request"]["requestID"])
    directory = private_directory(ticket_path.parent / ("fetch-" + str(uuid.uuid4())))
    collector = Collector(directory, ticket["deviceArgument"], ticket["appBundleID"], lock_fd)
    atomic(directory / "request-ticket.json", ticket)
    return poll(collector, ticket, args.timeout, args.initial_wait)


def compare(before, after):
    before, after = validate_host(before), validate_host(after)
    require(before["deviceArgument"] == after["deviceArgument"] and before["appBundleID"] == after["appBundleID"],
            "comparison_device_mismatch")
    a, b = before["watchReport"], after["watchReport"]
    require(a["requestID"] != b["requestID"], "comparison_requires_new_observation")
    require(after["createdAtUnixMS"] >= before["receivedAtUnixMS"], "comparison_observation_order_invalid")
    require(after["request"].get("expectedBaselineID") == a["baselineID"], "comparison_baseline_binding_missing")
    require(a["audit"]["libraryGeneration"] == b["audit"]["libraryGeneration"], "library_generation_changed")
    require(a.get("criticalSettings") == b.get("criticalSettings") and isinstance(a.get("criticalSettings"), dict),
            "critical_settings_changed_or_missing")
    # Entries are catalog members; reused hashes remain historical on the after report.
    def indexed(report):
        entries = report["audit"]["entries"]
        result = {entry["relativePath"]: entry for entry in entries}
        require(len(result) == len(entries), "duplicate_catalog_member")
        return result
    old, new = indexed(a), indexed(b)
    missing = set(old) - set(new)
    changed = []
    for path in set(old) & set(new):
        left, right = old[path], new[path]
        def member_value(entry):
            if entry["verification"] == "acknowledgedPruned":
                return entry["expectedSHA256"], entry["expectedByteCount"]
            return entry["observedSHA256"], entry["identity"]["byteCount"]
        old_hash, old_size = member_value(left)
        new_hash, new_size = member_value(right)
        if not old_hash or old_hash != new_hash or old_size != new_size:
            changed.append(path)
    return {"status": "preserved" if not missing and not changed else "changed",
            "beforeFileCount": len(old), "afterFileCount": len(new), "missingCount": len(missing),
            "changedCount": len(changed), "addedCount": len(set(new) - set(old)),
            "fullContentVerified": b["audit"]["fullContentVerified"], "audioBytesCopied": 0,
            "backupRecoverableEstablishedByThisCheck": False}


def main(argv=None):
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    capture_parser = sub.add_parser("capture")
    capture_parser.add_argument("--device", required=True)
    capture_parser.add_argument("--bundle-id", required=True)
    capture_parser.add_argument("--state-dir", type=Path, required=True)
    capture_parser.add_argument("--mode", choices=["quick", "full"], default="quick")
    baseline_options = capture_parser.add_mutually_exclusive_group()
    baseline_options.add_argument("--baseline", type=Path)
    baseline_options.add_argument("--new-baseline", action="store_true",
                                  help="Explicit full audit of a new library; does not establish preservation of an old library")
    fetch_parser = sub.add_parser("fetch")
    fetch_parser.add_argument("--request", type=Path, required=True)
    for child in [capture_parser, fetch_parser]:
        child.add_argument("--timeout", type=float, default=600)
        child.add_argument("--initial-wait", type=float, default=0,
                           help="Quiet seconds before reading reports; 0..3600 and included in --timeout")
        child.add_argument("--lock-file", type=Path,
                           help="Share the same exclusive lock as an existing installer/device workflow")
    compare_parser = sub.add_parser("compare")
    compare_parser.add_argument("--before", type=Path, required=True)
    compare_parser.add_argument("--after", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "compare":
            result = compare(load(args.before), load(args.after))
        else:
            require(0 < args.timeout <= 3600, "timeout_invalid")
            require(0 <= args.initial_wait <= min(3600, args.timeout), "initial_wait_invalid")
            state = private_directory(args.state_dir if args.command == "capture" else load(args.request)["stateDirectory"])
            lock_path = args.lock_file.absolute() if args.lock_file else state / "device-operation.lock"
            with device_lock(lock_path) as lock_fd:
                result = capture(args, lock_fd) if args.command == "capture" else fetch(args, lock_fd)
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result["status"] in {"complete", "preserved"} else 2
    except (IntegrityError, OSError, ValueError, KeyError, TypeError) as error:
        code = str(error) if isinstance(error, IntegrityError) else "integrity_tool_unavailable"
        print(json.dumps({"status": "failed", "error": code}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
