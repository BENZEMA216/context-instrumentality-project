"""Read only an explicitly selected, already-synced iCloud Drive export.

No cloud API, downloader, audio reader, catalog writer, or background service is
used. A valid local commit is not evidence of complete sessions or cloud sync.
"""

import argparse
import base64
from contextlib import contextmanager
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

from library import BridgeError, canonical_uuid, grouped_audio_name, parse_json, validate_manifest, validate_transcript


FORMAT = "record-for-agent-icloud-drive"
SHA = re.compile(r"[0-9a-f]{64}\Z")
SF_DATALESS = 0x40000000
MAX_METADATA = 1024 * 1024
MAX_CATALOG_BYTES = 16 * MAX_METADATA
MAX_COMMITS = 10000
KINDS = {"audio", "manifest", "transcriptJSON", "transcriptText"}


class ICloudDriveError(Exception):
    def __init__(self, code, *, pending=False):
        super().__init__(code)
        self.code, self.pending = code, pending


def require(condition, code):
    if not condition:
        raise ICloudDriveError(code)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def uuid_value(value):
    try:
        return canonical_uuid(value)
    except BridgeError as error:
        raise ICloudDriveError("invalid_uuid") from error


def digest_value(value):
    require(isinstance(value, str) and SHA.fullmatch(value), "invalid_digest")
    return value


def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns, getattr(value, "st_flags", 0))


@contextmanager
def no_materialization():
    """Refuse implicit dataless-file downloads, including an eviction/open race."""
    if sys.platform != "darwin":
        yield
        return
    try:
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        libc.getiopolicy_np.argtypes = [ctypes.c_int, ctypes.c_int]
        libc.getiopolicy_np.restype = ctypes.c_int
        libc.setiopolicy_np.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
        libc.setiopolicy_np.restype = ctypes.c_int
        # Public SDK: VFS_MATERIALIZE_DATALESS_FILES=3, THREAD=1, OFF=1.
        previous = libc.getiopolicy_np(3, 1)
        if previous < 0 or libc.setiopolicy_np(3, 1, 1) != 0:
            raise ICloudDriveError("no_download_policy_unavailable", pending=True)
    except (OSError, AttributeError) as error:
        raise ICloudDriveError("no_download_policy_unavailable", pending=True) from error
    try:
        yield
    finally:
        require(libc.setiopolicy_np(3, 1, previous) == 0, "no_download_policy_restore_failed")


def local_sync_state(path, value):
    """Query local metadata only; never request materialization of a file.

    SF_DATALESS is checked before opening content. For ubiquitous files the
    CoreFoundation resource keys additionally reject stale downloads/conflicts.
    A fresh CFURL avoids reusing cached metadata across observations.
    """
    if getattr(value, "st_flags", 0) & SF_DATALESS:
        return "not_downloaded"
    if sys.platform != "darwin":
        return "local"
    try:
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        pointer = ctypes.c_void_p
        cf.CFURLCreateFromFileSystemRepresentation.argtypes = [pointer, ctypes.c_char_p, ctypes.c_long, ctypes.c_bool]
        cf.CFURLCreateFromFileSystemRepresentation.restype = pointer
        cf.CFURLCopyResourcePropertyForKey.argtypes = [pointer, pointer, pointer, pointer]
        cf.CFURLCopyResourcePropertyForKey.restype = ctypes.c_bool
        cf.CFBooleanGetValue.argtypes = [pointer]
        cf.CFBooleanGetValue.restype = ctypes.c_bool
        cf.CFEqual.argtypes = [pointer, pointer]
        cf.CFEqual.restype = ctypes.c_bool
        cf.CFRelease.argtypes = [pointer]
        cf.CFRelease.restype = None
        encoded = os.fsencode(path)
        url = cf.CFURLCreateFromFileSystemRepresentation(None, encoded, len(encoded), stat.S_ISDIR(value.st_mode))
        if not url:
            return "metadata_unavailable"

        def property_value(name):
            result, error = pointer(), pointer()
            key = pointer.in_dll(cf, name)
            ok = cf.CFURLCopyResourcePropertyForKey(url, key, ctypes.byref(result), ctypes.byref(error))
            if error.value:
                cf.CFRelease(error)
            if not ok:
                if result.value:
                    cf.CFRelease(result)
                raise ICloudDriveError("sync_metadata_unavailable", pending=True)
            return result

        try:
            ubiquitous = property_value("kCFURLIsUbiquitousItemKey")
            try:
                is_ubiquitous = bool(ubiquitous.value and cf.CFBooleanGetValue(ubiquitous))
            finally:
                if ubiquitous.value:
                    cf.CFRelease(ubiquitous)
            if not is_ubiquitous:
                return "local"
            conflict = property_value("kCFURLUbiquitousItemHasUnresolvedConflictsKey")
            try:
                if conflict.value and cf.CFBooleanGetValue(conflict):
                    return "conflict"
            finally:
                if conflict.value:
                    cf.CFRelease(conflict)
            downloaded = property_value("kCFURLUbiquitousItemDownloadingStatusKey")
            try:
                current = pointer.in_dll(cf, "kCFURLUbiquitousItemDownloadingStatusCurrent")
                return "local" if downloaded.value and cf.CFEqual(downloaded, current) else "not_downloaded"
            finally:
                if downloaded.value:
                    cf.CFRelease(downloaded)
        finally:
            cf.CFRelease(url)
    except (OSError, ValueError, AttributeError):
        return "metadata_unavailable"


class ICloudDriveLibrary:
    def __init__(self, library_root, expected_library_id=None):
        self.root = Path(library_root).expanduser().absolute()
        self.library_id = uuid_value(expected_library_id) if expected_library_id is not None else None

    @staticmethod
    def _sync(path, value):
        state = local_sync_state(path, value)
        if state == "conflict":
            raise ICloudDriveError("icloud_unresolved_conflict")
        if state != "local":
            raise ICloudDriveError("icloud_" + state, pending=True)

    @contextmanager
    def _root(self):
        with no_materialization():
            with self._root_fd() as descriptor:
                yield descriptor

    @contextmanager
    def _root_fd(self):
        descriptor = None
        try:
            before = self.root.lstat()
            require(stat.S_ISDIR(before.st_mode) and not stat.S_ISLNK(before.st_mode), "unsafe_library_root")
            self._sync(self.root, before)
            descriptor = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            require(identity(os.fstat(descriptor)) == identity(before), "library_root_changed")
            yield descriptor
            try:
                require(identity(self.root.lstat()) == identity(before), "library_root_changed")
            except FileNotFoundError as error:
                raise ICloudDriveError("library_root_changed", pending=True) from error
        except FileNotFoundError as error:
            raise ICloudDriveError("library_root_not_available", pending=True) from error
        finally:
            if descriptor is not None:
                os.close(descriptor)

    @staticmethod
    def _parts(relative):
        require(isinstance(relative, str) and len(relative) <= 512 and "\\" not in relative
                and "\x00" not in relative and not relative.startswith("/"), "unsafe_relative_path")
        parts = relative.split("/")
        require(all(part and part not in {".", ".."} for part in parts), "unsafe_relative_path")
        return parts

    @contextmanager
    def _parent(self, root_fd, relative):
        parts = self._parts(relative)
        descriptor = os.dup(root_fd)
        try:
            for index, part in enumerate(parts[:-1]):
                value = os.stat(part, dir_fd=descriptor, follow_symlinks=False)
                require(stat.S_ISDIR(value.st_mode) and not stat.S_ISLNK(value.st_mode), "unsafe_directory")
                self._sync(self.root.joinpath(*parts[:index + 1]), value)
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                if identity(os.fstat(child)) != identity(value):
                    os.close(child)
                    raise ICloudDriveError("directory_changed", pending=True)
                os.close(descriptor)
                descriptor = child
            yield descriptor, parts[-1]
        except FileNotFoundError as error:
            raise ICloudDriveError("artifact_not_available", pending=True) from error
        finally:
            os.close(descriptor)

    def _stat(self, root_fd, relative, *, audio=False):
        with self._parent(root_fd, relative) as (parent, name):
            try:
                value = os.stat(name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError as error:
                raise ICloudDriveError("artifact_not_available", pending=True) from error
            require(stat.S_ISREG(value.st_mode) and value.st_nlink == 1, "unsafe_artifact")
            # CAF content is never opened, including for provider resource values.
            if audio:
                if getattr(value, "st_flags", 0) & SF_DATALESS:
                    raise ICloudDriveError("icloud_not_downloaded", pending=True)
            else:
                self._sync(self.root / relative, value)
            return value

    def _read(self, root_fd, relative, *, expected=None, maximum=MAX_METADATA):
        with self._parent(root_fd, relative) as (parent, name):
            try:
                before = os.stat(name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError as error:
                raise ICloudDriveError("artifact_not_available", pending=True) from error
            require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1, "unsafe_artifact")
            require(0 <= before.st_size <= maximum, "artifact_too_large")
            self._sync(self.root / relative, before)
            if expected is not None:
                require(before.st_size == expected["byteCount"], "artifact_size_mismatch")
            descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            try:
                require(identity(os.fstat(descriptor)) == identity(before), "artifact_changed")
                chunks, length = [], 0
                while True:
                    chunk = os.read(descriptor, min(64 * 1024, maximum + 1 - length))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    length += len(chunk)
                    require(length <= maximum, "artifact_too_large")
                require(identity(os.fstat(descriptor)) == identity(before)
                        and identity(os.stat(name, dir_fd=parent, follow_symlinks=False)) == identity(before)
                        and length == before.st_size, "artifact_changed")
                # Rewalk from the pinned root: a parent descriptor can remain valid
                # after its directory was renamed or replaced with a symlink.
                require(identity(self._stat(root_fd, relative)) == identity(before), "artifact_changed")
                data = b"".join(chunks)
            finally:
                os.close(descriptor)
            if expected is not None:
                require(sha256(data) == expected["sha256"], "artifact_digest_mismatch")
            return data

    @staticmethod
    def _json(data):
        try:
            return parse_json(data)
        except BridgeError as error:
            raise ICloudDriveError("invalid_json") from error

    def _marker(self, root_fd):
        raw = self._read(root_fd, "library.json")
        marker = self._json(raw)
        require(isinstance(marker, dict) and set(marker) == {"schemaVersion", "libraryID", "format"}
                and type(marker["schemaVersion"]) is int and marker["schemaVersion"] == 1
                and marker["format"] == FORMAT, "invalid_library_marker")
        library_id = uuid_value(marker["libraryID"])
        require(self.library_id in {None, library_id}, "library_identity_changed")
        self.library_id = library_id
        return sha256(raw)

    def _commit_paths(self, root_fd):
        paths = []
        with self._parent(root_fd, "commits/.catalog") as (commits, _):
            for segment in sorted(os.listdir(commits)):
                require(uuid_value(segment) == segment, "unexpected_commit_directory")
                with self._parent(root_fd, "commits/" + segment + "/.catalog") as (directory, _):
                    for name in sorted(os.listdir(directory)):
                        if name.startswith("."):
                            raise ICloudDriveError("commit_not_finished", pending=True)
                        require(name.endswith(".json") and SHA.fullmatch(name[:-5]), "unexpected_commit_file")
                        path = "commits/" + segment + "/" + name
                        paths.append((path, identity(self._stat(root_fd, path))))
                        require(len(paths) <= MAX_COMMITS, "commit_catalog_too_large")
        return paths

    def _commit(self, raw, path):
        value = self._json(raw)
        fields = {"schemaVersion", "libraryID", "segmentID", "audioSHA256", "manifestSHA256",
                  "exportDigest", "artifacts", "committedAt"}
        require(isinstance(value, dict) and fields <= set(value)
                and not set(value) - fields - {"transcriptVersionSHA256", "localFileIdentities"}, "invalid_commit")
        # Phone-local dev/inode/cache evidence has no authority on this Mac.
        # localFileIdentities is deliberately neither consumed nor propagated.
        require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
                and uuid_value(value["libraryID"]) == self.library_id, "commit_library_mismatch")
        segment = uuid_value(value["segmentID"])
        audio, manifest = digest_value(value["audioSHA256"]), digest_value(value["manifestSHA256"])
        require(type(value["committedAt"]) is int and 0 <= value["committedAt"] <= 253402300799999, "invalid_commit_time")
        require(isinstance(value["artifacts"], list) and len(value["artifacts"]) in {2, 4}, "invalid_artifact_set")
        artifacts = {}
        for artifact in value["artifacts"]:
            require(isinstance(artifact, dict) and set(artifact) == {"kind", "sha256", "byteCount", "relativePath"}, "invalid_artifact")
            kind = artifact["kind"]
            require(isinstance(kind, str) and kind in KINDS and kind not in artifacts, "invalid_artifact_kind")
            digest_value(artifact["sha256"])
            require(type(artifact["byteCount"]) is int and 0 < artifact["byteCount"] <= 2**63 - 1, "invalid_artifact_size")
            parts = self._parts(artifact["relativePath"])
            directory, suffix = {"audio": ("audio", ".caf"), "manifest": ("manifests", ".json"),
                                 "transcriptJSON": ("transcripts", ".json"), "transcriptText": ("transcripts", ".txt")}[kind]
            legacy = directory + "/" + segment + "/" + artifact["sha256"] + suffix
            grouped = kind == "audio" and len(parts) == 3 and parts[0] == "audio" and parts[2].endswith("_" + segment + ".caf")
            require(artifact["relativePath"] == legacy or grouped, "artifact_path_binding_mismatch")
            artifacts[kind] = artifact
        require(set(artifacts) in ({"audio", "manifest"}, KINDS), "invalid_artifact_set")
        require(artifacts["audio"]["sha256"] == audio and artifacts["manifest"]["sha256"] == manifest, "source_identity_mismatch")
        version = value.get("transcriptVersionSHA256")
        require((version is None and "transcriptJSON" not in artifacts)
                or (version is not None and digest_value(version) == artifacts.get("transcriptJSON", {}).get("sha256")), "transcript_version_mismatch")
        ordered = sorted(artifacts.values(), key=lambda item: item["kind"] + "-" + item["sha256"])
        serialized = "".join("%s\t%s\t%d\t%s\n" % (item["kind"], item["sha256"], item["byteCount"], item["relativePath"]) for item in ordered).encode("utf-8")
        export = digest_value(value["exportDigest"])
        require(sha256(serialized) == export and path == "commits/" + segment + "/" + export + ".json", "commit_digest_mismatch")
        return {**value, "segmentID": segment, "libraryID": self.library_id, "artifacts": artifacts}

    def _catalog(self, root_fd):
        marker_digest = self._marker(root_fd)
        snapshot = self._commit_paths(root_fd)
        if not snapshot:
            raise ICloudDriveError("no_committed_segments", pending=True)
        sources, records, total = {}, {}, 0
        digest_parts = [marker_digest]
        for path, _ in snapshot:
            raw = self._read(root_fd, path)
            total += len(raw)
            require(total <= MAX_CATALOG_BYTES, "commit_catalog_too_large")
            commit = self._commit(raw, path)
            source = (commit["audioSHA256"], commit["manifestSHA256"])
            sid = commit["segmentID"]
            require(sid not in sources or sources[sid] == source, "conflicting_source_identity")
            sources[sid] = source
            records.setdefault(sid, []).append(commit)
            digest_parts.append(path + "\t" + sha256(raw))
        return records, (marker_digest, snapshot), sha256("\n".join(digest_parts).encode("utf-8"))

    def _fence(self, root_fd, observation):
        marker, snapshot = observation
        if self._marker(root_fd) != marker or self._commit_paths(root_fd) != snapshot:
            raise ICloudDriveError("catalog_changed_during_read", pending=True)

    def _manifest(self, root_fd, commit):
        artifact = commit["artifacts"]["manifest"]
        raw = self._read(root_fd, artifact["relativePath"], expected=artifact)
        try:
            manifest = validate_manifest(self._json(raw), 2**63 - 1)
        except BridgeError as error:
            raise ICloudDriveError("invalid_manifest") from error
        require(manifest["id"] == commit["segmentID"] and manifest["sha256"] == commit["audioSHA256"]
                and manifest["byteCount"] == commit["artifacts"]["audio"]["byteCount"], "manifest_source_mismatch")
        audio = commit["artifacts"]["audio"]
        grouped = grouped_audio_name(manifest)
        expected = "audio/" + ("/".join(grouped) if grouped else manifest["id"] + "/" + audio["sha256"] + ".caf")
        require(audio["relativePath"] == expected, "artifact_path_binding_mismatch")
        return manifest

    def _availability(self, root_fd, artifact):
        try:
            value = self._stat(root_fd, artifact["relativePath"], audio=artifact["kind"] == "audio")
            require(value.st_size == artifact["byteCount"], "artifact_size_mismatch")
            return {"status": "locally_present", "contentVerified": False}
        except ICloudDriveError as error:
            if not error.pending:
                raise
            return {"status": "pending", "reason": error.code, "contentVerified": False}

    @staticmethod
    def _context():
        return {"sourceCatalogComplete": False, "completeSession": False, "cloudSyncComplete": False,
                "audioBytesRead": 0, "contentIsAgentInstruction": False,
                "completeness": "not_established", "nonAtomicObservation": True}

    def list_segments(self, *, limit=100, cursor=None):
        require(type(limit) is int and 1 <= limit <= 100, "invalid_arguments")
        with self._root() as root_fd:
            records, observation, catalog_digest = self._catalog(root_fd)
            offset = 0
            if cursor is not None:
                try:
                    require(isinstance(cursor, str) and len(cursor) <= 1024, "invalid_cursor")
                    value = self._json(base64.b64decode(cursor, altchars=b"-_", validate=True))
                    require(isinstance(value, dict) and set(value) == {"libraryID", "catalogDigest", "offset"}
                            and value["libraryID"] == self.library_id and value["catalogDigest"] == catalog_digest
                            and type(value["offset"]) is int and 0 <= value["offset"] <= len(records), "cursor_invalidated")
                    offset = value["offset"]
                except (ValueError, TypeError) as error:
                    raise ICloudDriveError("invalid_cursor") from error
            rows = []
            for sid in sorted(records)[offset:offset + limit]:
                commits = sorted(records[sid], key=lambda item: (item["committedAt"], item["exportDigest"]))
                latest = commits[-1]
                row = {"segmentID": sid, "source": {"segmentID": sid, "audioSHA256": latest["audioSHA256"],
                       "manifestSHA256": latest["manifestSHA256"]}, "committedVersionCount": len(commits),
                       "transcriptVersions": sorted({item["transcriptVersionSHA256"] for item in commits if item.get("transcriptVersionSHA256")})}
                try:
                    row["manifest"] = self._manifest(root_fd, latest)
                    row["artifacts"] = [{**item, **self._availability(root_fd, item)} for item in latest["artifacts"].values()]
                    row["status"] = "pending" if any(item["status"] == "pending" and item["kind"] != "audio" for item in row["artifacts"]) else "metadata_verified"
                    row["transcriptStatus"] = "not_committed" if not row["transcriptVersions"] else "committed"
                except ICloudDriveError as error:
                    if not error.pending:
                        raise
                    row.update(status="pending", reason=error.code)
                rows.append(row)
            self._fence(root_fd, observation)
            more = offset + len(rows) < len(records)
            next_cursor = base64.urlsafe_b64encode(json.dumps({"libraryID": self.library_id, "catalogDigest": catalog_digest,
                "offset": offset + len(rows)}, separators=(",", ":")).encode()).decode() if more else None
            return {"status": "pending" if any(row["status"] == "pending" for row in rows) else "available",
                    "libraryID": self.library_id, "catalogDigest": catalog_digest, "segments": rows,
                    "nextCursor": next_cursor, **self._context()}

    def read_transcript(self, segment_id, *, content_version_sha256=None, format="json"):
        segment = uuid_value(segment_id)
        require(format in {"json", "text"}, "invalid_arguments")
        if content_version_sha256 is not None:
            digest_value(content_version_sha256)
        with self._root() as root_fd:
            records, observation, catalog_digest = self._catalog(root_fd)
            require(segment in records, "segment_not_committed")
            commits = [item for item in records[segment] if item.get("transcriptVersionSHA256")
                       and (content_version_sha256 is None or item["transcriptVersionSHA256"] == content_version_sha256)]
            if not commits:
                raise ICloudDriveError("transcript_not_committed", pending=True)
            newest = max(item["committedAt"] for item in commits)
            candidates = [item for item in commits if item["committedAt"] == newest]
            require(len({item["transcriptVersionSHA256"] for item in candidates}) == 1, "conflicting_transcript_versions")
            commit = candidates[0]
            manifest = self._manifest(root_fd, commit)
            artifacts = commit["artifacts"]
            audio_state = self._availability(root_fd, artifacts["audio"])
            raw = self._read(root_fd, artifacts["transcriptJSON"]["relativePath"], expected=artifacts["transcriptJSON"])
            text_raw = self._read(root_fd, artifacts["transcriptText"]["relativePath"], expected=artifacts["transcriptText"])
            try:
                transcript = validate_transcript(self._json(raw), manifest)
            except BridgeError as error:
                raise ICloudDriveError("invalid_transcript_source_or_content") from error
            require(text_raw == (transcript["text"] + "\n").encode("utf-8"), "transcript_text_mismatch")
            self._fence(root_fd, observation)
            return {"status": "available", "libraryID": self.library_id, "catalogDigest": catalog_digest,
                    "segmentID": segment, "contentVersionSHA256": commit["transcriptVersionSHA256"],
                    "source": {key: commit[key] for key in ("segmentID", "audioSHA256", "manifestSHA256")},
                    "format": format, "content": transcript if format == "json" else text_raw.decode("utf-8"),
                    "audioAvailability": audio_state,
                    "integrity": "complete_committed_local_text_bytes_sha256_verified", **self._context()}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library-root", required=True, type=Path, help="One explicitly selected, already-synced export sublibrary")
    parser.add_argument("--library-id", help="Optional expected library UUID; rejects another marker identity")
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list")
    listing.add_argument("--limit", type=int, default=100)
    listing.add_argument("--cursor")
    reading = commands.add_parser("read-transcript")
    reading.add_argument("segment_id")
    reading.add_argument("--content-version-sha256")
    reading.add_argument("--format", choices=["json", "text"], default="json")
    args = parser.parse_args(argv)
    try:
        reader = ICloudDriveLibrary(args.library_root, args.library_id)
        result = reader.list_segments(limit=args.limit, cursor=args.cursor) if args.command == "list" else reader.read_transcript(
            args.segment_id, content_version_sha256=args.content_version_sha256, format=args.format)
        print(json.dumps(result, ensure_ascii=True, allow_nan=False))
        return 0 if result["status"] == "available" else 2
    except ICloudDriveError as error:
        pending = error.pending or error.code == "no_committed_segments"
        print(json.dumps({"status": "pending" if pending else "rejected", "error": {"code": error.code},
                          **ICloudDriveLibrary._context()}))
        return 2 if pending else 1
    except (OSError, ValueError, TypeError, RecursionError):
        print(json.dumps({"status": "pending", "error": {"code": "local_library_unavailable"},
                          **ICloudDriveLibrary._context()}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
