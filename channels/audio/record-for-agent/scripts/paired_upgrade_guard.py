#!/usr/bin/env python3
"""A local, fail-closed journal for an existing paired-app upgrade.

This module never runs a command or touches a device. The operator supplies fresh
native app-query results and an install callback. Every entry point for the same
upgrade must use the same private journal directory and binding digest.
An install-start record is immutable, including after exceptions or interruption.
It records permission to invoke the callback, not a successful install or preserved
data container. Only a separate native readback can verify the new app version.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time
import uuid


class UpgradeGuardError(RuntimeError):
    """A stable code, without device identities or private paths in its message."""


class PairedUpgradeGuard:
    MAX_OBSERVATION_AGE_MS = 60_000
    MAX_JOURNAL_BYTES = 16 * 1024
    ROLE_NAMES = ("phone", "watch")

    def __init__(self, journal_directory, *, upgrade_id, binding_sha256, roles, clock=None):
        self._fd = None
        self._clock = clock or (lambda: int(time.time() * 1000))
        if not isinstance(upgrade_id, str) or not 0 < len(upgrade_id) <= 128:
            raise UpgradeGuardError("upgrade_id_invalid")
        if not isinstance(binding_sha256, str) or not re.fullmatch("[0-9a-f]{64}", binding_sha256):
            raise UpgradeGuardError("binding_digest_invalid")
        if type(roles) is not dict or set(roles) != set(self.ROLE_NAMES):
            raise UpgradeGuardError("paired_roles_required")
        checked = {}
        for role in self.ROLE_NAMES:
            value = roles[role]
            if type(value) is not dict or set(value) != {"target", "bundle", "old_build", "new_build"}:
                raise UpgradeGuardError("role_binding_invalid")
            if any(type(value[k]) is not str or not 0 < len(value[k]) <= 512 for k in value):
                raise UpgradeGuardError("role_binding_invalid")
            if value["old_build"] == value["new_build"]:
                raise UpgradeGuardError("distinct_builds_required")
            checked[role] = dict(value)
        if checked["phone"]["target"] == checked["watch"]["target"] or checked["phone"]["bundle"] == checked["watch"]["bundle"]:
            raise UpgradeGuardError("distinct_paired_bindings_required")
        self._plan = {"schemaVersion": 1, "upgradeID": upgrade_id,
                      "bindingSHA256": binding_sha256, "roles": checked}
        directory = Path(journal_directory)
        if not directory.is_absolute():
            raise UpgradeGuardError("absolute_journal_directory_required")
        try:
            try:
                os.mkdir(str(directory), 0o700)
            except FileExistsError:
                pass
            self._fd = os.open(str(directory), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            info = os.fstat(self._fd)
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise UpgradeGuardError("private_journal_directory_required")
            expected = self._encode(self._plan)
            try:
                self._write_new("plan.json", expected)
            except FileExistsError:
                if self._read("plan.json") != expected:
                    raise UpgradeGuardError("upgrade_plan_changed")
        except BaseException:
            self.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None

    @staticmethod
    def _encode(value):
        return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                           allow_nan=False) + "\n").encode("utf-8")

    def _now(self):
        value = self._clock()
        if type(value) is not int or value < 0:
            raise UpgradeGuardError("host_time_invalid")
        return value

    def _role(self, role):
        if role not in self.ROLE_NAMES:
            raise UpgradeGuardError("unknown_role")
        if self._fd is None:
            raise UpgradeGuardError("journal_closed")
        return self._plan["roles"][role]

    def _read(self, leaf):
        try:
            fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=self._fd)
        except FileNotFoundError:
            return None
        try:
            first = os.fstat(fd)
            if (not stat.S_ISREG(first.st_mode) or first.st_nlink != 1 or first.st_uid != os.getuid()
                    or stat.S_IMODE(first.st_mode) != 0o600 or not 0 < first.st_size <= self.MAX_JOURNAL_BYTES):
                raise UpgradeGuardError("journal_file_boundary_invalid")
            chunks = []
            remaining = self.MAX_JOURNAL_BYTES + 1
            while remaining:
                part = os.read(fd, min(remaining, 4096))
                if not part:
                    break
                chunks.append(part)
                remaining -= len(part)
            raw = b"".join(chunks)
            last = os.fstat(fd)
            identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            if len(raw) != first.st_size or identity(first) != identity(last):
                raise UpgradeGuardError("journal_changed_during_read")
            return raw
        finally:
            os.close(fd)

    def _write_new(self, leaf, raw):
        if not 0 < len(raw) <= self.MAX_JOURNAL_BYTES:
            raise UpgradeGuardError("journal_record_too_large")
        fd = os.open(leaf, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600, dir_fd=self._fd)
        # A failed write/fsync deliberately leaves the claim in place. It is not
        # safe to decide that a previous entry point never invoked the installer.
        try:
            offset = 0
            while offset < len(raw):
                written = os.write(fd, raw[offset:])
                if written <= 0:
                    raise UpgradeGuardError("journal_write_failed")
                offset += written
            os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(self._fd)

    def _observe(self, role, result, observed_at_ms):
        value = self._role(role)
        if type(observed_at_ms) is not int or not 0 <= self._now() - observed_at_ms <= self.MAX_OBSERVATION_AGE_MS:
            raise UpgradeGuardError("fresh_native_observation_required")
        if type(result) is not dict or ("error" in result and result["error"] is not None) or result.get("errors"):
            raise UpgradeGuardError("native_query_failed")
        if "outcome" in result and result["outcome"] != "success":
            raise UpgradeGuardError("native_query_failed")
        apps = result.get("apps")
        if result.get("deviceIdentifier") != value["target"]:
            raise UpgradeGuardError("native_target_mismatch")
        if type(apps) is not list or len(apps) != 1 or type(apps[0]) is not dict:
            raise UpgradeGuardError("existing_app_not_uniquely_visible")
        app = apps[0]
        if app.get("bundleIdentifier") != value["bundle"]:
            raise UpgradeGuardError("native_bundle_mismatch")
        build_value = app.get("bundleVersion")
        if type(build_value) not in (str, int):
            raise UpgradeGuardError("native_build_invalid")
        build = str(build_value)
        if build not in (value["old_build"], value["new_build"]):
            raise UpgradeGuardError("native_build_unknown")
        try:
            query_sha = hashlib.sha256(self._encode(result)).hexdigest()
        except (TypeError, ValueError):
            raise UpgradeGuardError("native_query_not_json")
        return {"observedBuild": build, "observedAtMS": observed_at_ms, "sourceQuerySHA256": query_sha}

    def _base_record(self, role, kind):
        value = self._role(role)
        return {"schemaVersion": 1, "upgradeID": self._plan["upgradeID"],
                "bindingSHA256": self._plan["bindingSHA256"], "role": role, "kind": kind,
                "target": value["target"], "bundle": value["bundle"],
                "oldBuild": value["old_build"], "newBuild": value["new_build"]}

    def _record(self, role, kind):
        leaf = ("before-" if kind == "preexisting" else "install-") + role + ".json"
        raw = self._read(leaf)
        if raw is None:
            return None
        try:
            def unique_object(pairs):
                result = {}
                for key, item in pairs:
                    if key in result:
                        raise ValueError("duplicate_key")
                    result[key] = item
                return result
            def invalid_constant(_):
                raise ValueError("nonfinite_value")
            value = json.loads(raw, object_pairs_hook=unique_object, parse_constant=invalid_constant)
        except (ValueError, UnicodeError):
            raise UpgradeGuardError("journal_record_invalid")
        expected = self._base_record(role, kind)
        keys = set(expected) | {"observedBuild", "observedAtMS", "sourceQuerySHA256"}
        if kind == "install_started":
            keys |= {"invocationID", "recordedAtMS"}
        if (type(value) is not dict or set(value) != keys
                or any(type(value.get(k)) is not type(v) or value.get(k) != v for k, v in expected.items())):
            raise UpgradeGuardError("journal_record_binding_changed")
        if (value.get("observedBuild") != self._role(role)["old_build"]
                or type(value.get("observedAtMS")) is not int or value["observedAtMS"] < 0
                or not isinstance(value.get("sourceQuerySHA256"), str)
                or not re.fullmatch("[0-9a-f]{64}", value["sourceQuerySHA256"])):
            raise UpgradeGuardError("journal_observation_invalid")
        if kind == "install_started" and (not isinstance(value.get("invocationID"), str)
                or not re.fullmatch("[0-9a-f]{32}", value["invocationID"])
                or type(value.get("recordedAtMS")) is not int
                or value["recordedAtMS"] < value["observedAtMS"]):
            raise UpgradeGuardError("journal_invocation_invalid")
        return value

    def record_before(self, role, result, *, observed_at_ms):
        """Record an old-build app before either member of the pair is updated."""
        observation = self._observe(role, result, observed_at_ms)
        if observation["observedBuild"] != self._role(role)["old_build"]:
            raise UpgradeGuardError("preexisting_old_build_required")
        existing = self._record(role, "preexisting")
        if existing is not None:
            return existing
        if any(self._record(r, "install_started") is not None for r in self.ROLE_NAMES):
            raise UpgradeGuardError("before_capture_after_install_started")
        value = dict(self._base_record(role, "preexisting"), **observation)
        try:
            self._write_new("before-" + role + ".json", self._encode(value))
        except FileExistsError:
            # Another entry point may have completed the same immutable capture.
            return self._record(role, "preexisting")
        return value

    def _require_pair_before(self):
        if self._read("plan.json") != self._encode(self._plan):
            raise UpgradeGuardError("upgrade_plan_changed")
        if any(self._record(role, "preexisting") is None for role in self.ROLE_NAMES):
            raise UpgradeGuardError("both_preexisting_apps_required")

    def install_once(self, role, result, *, observed_at_ms, install):
        """Claim durably, then call install at most once across all entry points.

        A missing app is never a fresh-install authorization. After an unknown
        observation the operator may make a new read-only query; only a fresh,
        exact old/new result can proceed. This makes no data-preservation claim.
        """
        observation = self._observe(role, result, observed_at_ms)
        self._require_pair_before()
        previous = self._record(role, "install_started")
        if observation["observedBuild"] == self._role(role)["new_build"]:
            return {"action": "already_new_readback", "installIssued": False,
                    "priorInvocationRecorded": previous is not None}
        if previous is not None:
            raise UpgradeGuardError("prior_install_started_readback_only")
        if not callable(install):
            raise UpgradeGuardError("install_callback_required")
        record = dict(self._base_record(role, "install_started"), **observation)
        record.update(invocationID=uuid.uuid4().hex, recordedAtMS=self._now())
        try:
            self._write_new("install-" + role + ".json", self._encode(record))
        except FileExistsError:
            raise UpgradeGuardError("prior_install_started_readback_only")
        result = install()
        return {"action": "install_callback_returned", "installIssued": True,
                "invocationID": record["invocationID"], "nativeResult": result,
                "requiresIndependentReadback": True}

    def verify_installed(self, role, result, *, observed_at_ms):
        """Readback only: never alter or clear an install-start record."""
        observation = self._observe(role, result, observed_at_ms)
        self._require_pair_before()
        previous = self._record(role, "install_started")
        if observation["observedBuild"] != self._role(role)["new_build"]:
            raise UpgradeGuardError("new_build_not_verified")
        return {"verifiedNewBuild": True, "priorInvocationRecorded": previous is not None,
                "dataContainerPreservedProven": False}
