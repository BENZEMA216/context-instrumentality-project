"""Opt-in iCloud Drive transport. Each installation writes its own encrypted replica."""

import hashlib
import json
import os
import re
import time
import sys
import uuid
from pathlib import Path

from . import intake
from .storage import FILENAME, VaultError


def provider_state(snapshot):
    """Apple file-provider acknowledgment for this device's own encrypted file."""
    if sys.platform != "darwin" or not snapshot.is_file():
        return None
    import Foundation as F

    url = F.NSURL.fileURLWithPath_(str(snapshot))
    keys = [
        F.NSURLIsUbiquitousItemKey,
        F.NSURLUbiquitousItemIsUploadedKey,
        F.NSURLUbiquitousItemIsUploadingKey,
        F.NSURLUbiquitousItemUploadingErrorKey,
    ]
    values, _ = url.resourceValuesForKeys_error_(keys, None)
    if not values or not values.get(keys[0]):
        return None
    if values.get(keys[1]):
        return "uploaded"
    error = values.get(keys[3])
    if error is not None and hasattr(error, "code"):
        if error.domain() == F.NSCocoaErrorDomain:
            if error.code() == F.NSUbiquitousFileUbiquityServerNotAvailable:
                return "unavailable"
            if error.code() == F.NSUbiquitousFileNotUploadedDueToQuotaError:
                return "quota"
        return "provider_error"
    return "uploading" if values.get(keys[2]) else "pending"


class CloudFiles:
    def __init__(self, local, remote):
        self.local = Path(local)
        self.remote = Path(remote) if remote else None
        self.config = self.local / "cloud-config.json"
        self.options = {"device": uuid.uuid4().hex, "enabled": False}
        if self.config.exists():
            options = json.loads(self.config.read_text())
            if not re.fullmatch("[a-f0-9]{32}", options["device"]):
                raise VaultError("Invalid local backup device identifier")
            self.options.update(options)
        self.error = None
        self.next_check = 0
        self._fingerprints = {}

    def _save(self):
        intake._publish(self.config, json.dumps(self.options).encode())

    def status(self):
        remote_state = None
        if self.remote and self.options["enabled"] and self.options.get("last_backup"):
            latest = self.remote / "Devices" / self.options["device"] / "latest.cvault"
            remote_state = provider_state(latest)
        return {
            "provider_state": remote_state,
            "available": self.remote is not None,
            "enabled": self.options["enabled"],
            "last_backup": self.options.get("last_backup"),
            "error": self.error,
        }

    def set_enabled(self, enabled, store):
        if type(enabled) is not bool:
            raise VaultError("Expected a boolean cloud option")
        if enabled and self.remote is None:
            raise VaultError("iCloud Drive unavailable", 409)
        self.options["enabled"] = enabled
        self._save()
        if enabled:
            self.tick(store, force=True)
        return self.status()

    def tick(self, store, force=False):
        if not self.remote or not self.options["enabled"] or not store.initialized:
            return
        if not force and time.monotonic() < self.next_check:
            return
        self.next_check = time.monotonic() + 30
        try:
            stat = (self.local / FILENAME).stat()
            generation = [stat.st_ino, stat.st_size, stat.st_mtime_ns]
            dest = self.remote / "Devices" / self.options["device"]
            for path in (
                self.remote,
                self.remote / "Devices",
                dest,
                self.remote / "Inbox",
            ):
                if path.is_symlink():
                    raise OSError("Invalid backup folder")
                path.mkdir(mode=0o700, exist_ok=True)
            latest = dest / "latest.cvault"
            if (
                force
                or generation != self.options.get("generation")
                or not latest.is_file()
            ):
                snapshot = store.backup(dest)
                os.replace(dest / snapshot, latest)
                self.options.update(generation=generation, last_backup=int(time.time()))
                self._save()
            self.error = None
        except (OSError, VaultError):
            self.error = "iCloud Drive 写入失败，将在稍后重试。"

    def _entries(self):
        if not self.remote or not self.options["enabled"]:
            return
        inbox = self.remote / "Inbox"
        if inbox.is_symlink() or not inbox.is_dir():
            return
        for path in sorted(inbox.glob("*.cvdrop")):
            if path.is_symlink() or not path.is_file():
                continue
            try:
                info = path.stat()
                stamp = (info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
                cached = self._fingerprints.get(path)
                if cached and cached[0] == stamp:
                    digest = cached[1]
                else:
                    digest = hashlib.sha256(intake.read_package_bytes(path)).hexdigest()
                    self._fingerprints[path] = (stamp, digest)
            except (OSError, VaultError):
                continue
            if not (self.local / "cloud-seen" / digest).is_file():
                yield "cloud-" + digest, path

    def _verified_package(self, key, path):
        data = intake.read_package_bytes(path)
        if key != "cloud-" + hashlib.sha256(data).hexdigest():
            raise VaultError("Cloud item changed. Review the new item.", 409)
        return intake.parse_package(data)

    def package(self, identifier):
        for key, path in self._entries():
            if key == identifier:
                return self._verified_package(key, path)
        raise VaultError("Cloud item changed or is unavailable", 404)

    def list(self, store):
        entries = []
        for key, path in self._entries():
            try:
                item = intake.open_drop(store, self._verified_package(key, path))
                entries.append(
                    {"id": key, "label": item["label"][:160], "kind": item["kind"]}
                )
            except (OSError, VaultError):
                entries.append(
                    {"id": key, "label": "无法读取的 iCloud 收件", "kind": "invalid"}
                )
            if len(entries) >= 100:
                break
        return entries

    def dismiss(self, identifier):
        if not re.fullmatch("cloud-[a-f0-9]{64}", identifier):
            raise VaultError("Invalid cloud item")
        seen = self.local / "cloud-seen"
        seen.mkdir(mode=0o700, exist_ok=True)
        intake._publish(seen / identifier[6:], b"")
