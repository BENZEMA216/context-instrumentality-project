"""Unified Consumer-Cloud Audio Sync Adapters (Google Drive, WebDAV/坚果云, Packet Codec).

Why Codex's cloud sync stalled:
- Uploaded 11.25 MB/min uncompressed 48kHz Float32 `.caf` files.
- Split every 60-second recording into 4 unlinked files (leaving 171 orphaned
  `manifest_not_ready` candidates in Google Drive and 9,052 evicted stubs in iCloud).

How Hub v2 fixes it for ordinary users (zero self-hosted cloud required):
1. Compress voice audio to 48-64 kbps mono AAC `.m4a` (~360-480 KB/min, 25x-30x smaller).
2. Pack `manifest.json` + `audio.m4a` into ONE atomic immutable `.ctxaudio.zip` packet
   (1 single upload request, zero orphaned manifests).
3. Support interchangeable consumer-cloud adapters that drop unpacked `.m4a` + `.json`
   into `<data_dir>/inbox/audio/` for `AudioCollector` + `SenseVoice-Small`:
   - Apple CloudKit Private DB (`CKSyncEngine` via macOS companion — zero config)
   - WebDAV (`dav.jianguoyun.com` 坚果云 / NAS / Nextcloud — best domestic zero-proxy cloud)
   - Google Drive (`changes.list` incremental delta + proxy-friendly single multipart upload)
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ..runtime import CheckpointBackend

PACKET_SUFFIX = ".ctxaudio.zip"
DEFAULT_AAC_BITRATE = 48_000  # ~360 KB/min, ~31x smaller than 11.25 MB/min 48kHz Float32 CAF


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 256), b""):
            h.update(chunk)
    return h.hexdigest()


def _atomic_write_bytes(dest: Path, data: bytes) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(dir=dest.parent, prefix=".tmp-", delete=False) as tmp:
        tmp_path = Path(tmp.name)
        try:
            tmp.write(data)
            tmp.flush()
            os.fsync(tmp.fileno())
        except BaseException:
            tmp_path.unlink(missing_ok=True)
            raise
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, dest)


def compress_to_m4a(
    src_audio: Path,
    dest_m4a: Path,
    *,
    bitrate: int = DEFAULT_AAC_BITRATE,
) -> dict[str, Any]:
    """Transcode `.caf`/`.wav`/`.m4a` voice audio into compact mono AAC `.m4a`."""
    if not src_audio.is_file():
        raise FileNotFoundError(f"Source audio not found: {src_audio}")
    dest_m4a.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    afconvert = shutil.which("afconvert")
    ffmpeg = shutil.which("ffmpeg")
    if afconvert:
        cmd = [
            afconvert,
            "-f",
            "m4af",
            "-d",
            "aac",
            "-b",
            str(bitrate),
            "-c",
            "1",
            str(src_audio),
            str(dest_m4a),
        ]
    elif ffmpeg:
        cmd = [
            ffmpeg,
            "-y",
            "-v",
            "error",
            "-i",
            str(src_audio),
            "-ac",
            "1",
            "-c:a",
            "aac",
            "-b:a",
            str(bitrate),
            str(dest_m4a),
        ]
    else:
        raise RuntimeError("Neither macOS `afconvert` nor `ffmpeg` is available.")

    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if proc.returncode != 0 or not dest_m4a.is_file():
        raise RuntimeError(f"M4A compression failed: {proc.stderr.strip()[:240]}")

    src_bytes = src_audio.stat().st_size
    dst_bytes = dest_m4a.stat().st_size
    return {
        "src_bytes": src_bytes,
        "dst_bytes": dst_bytes,
        "compression_ratio": round(src_bytes / max(1, dst_bytes), 2),
        "sha256": _sha256_file(dest_m4a),
    }


def pack_audio_packet(
    audio_path: Path,
    manifest: dict[str, Any],
    dest_packet: Path,
    *,
    compress: bool = True,
    bitrate: int = DEFAULT_AAC_BITRATE,
) -> dict[str, Any]:
    """Bundle `manifest.json` + compressed `.m4a` audio into ONE atomic `.ctxaudio.zip`."""
    seg_id = str(manifest.get("id") or audio_path.stem)
    out_manifest = dict(manifest)
    out_manifest["id"] = seg_id

    with tempfile.TemporaryDirectory(prefix="ctx-pack-") as td:
        td_path = Path(td)
        if compress and audio_path.suffix.lower() != ".m4a":
            m4a_path = td_path / f"{seg_id}.m4a"
            comp = compress_to_m4a(audio_path, m4a_path, bitrate=bitrate)
            payload_audio = m4a_path
            out_manifest["fileName"] = f"{seg_id}.m4a"
            out_manifest["audioFormat"] = "m4a"
            out_manifest["audioBitrate"] = bitrate
            out_manifest["sha256"] = comp["sha256"]
            out_manifest["byteCount"] = comp["dst_bytes"]
            out_manifest["originalByteCount"] = comp["src_bytes"]
        else:
            payload_audio = audio_path
            ext = audio_path.suffix.lower() or ".m4a"
            out_manifest["fileName"] = f"{seg_id}{ext}"
            out_manifest["audioFormat"] = ext.lstrip(".")
            out_manifest["sha256"] = _sha256_file(audio_path)
            out_manifest["byteCount"] = audio_path.stat().st_size

        dest_packet.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with tempfile.NamedTemporaryFile(
            dir=dest_packet.parent, prefix=".pkt-", delete=False
        ) as tmp:
            tmp_zip = Path(tmp.name)
        try:
            with zipfile.ZipFile(tmp_zip, "w", compression=zipfile.ZIP_STORED) as zf:
                zf.writestr(
                    "manifest.json",
                    json.dumps(out_manifest, ensure_ascii=False, sort_keys=True, indent=2),
                )
                zf.write(payload_audio, arcname=out_manifest["fileName"])
            os.chmod(tmp_zip, 0o600)
            os.replace(tmp_zip, dest_packet)
        except BaseException:
            tmp_zip.unlink(missing_ok=True)
            raise

    return {
        "segment_id": seg_id,
        "packet_path": str(dest_packet),
        "packet_bytes": dest_packet.stat().st_size,
        "audio_sha256": out_manifest["sha256"],
    }


def unpack_audio_packet(packet_bytes: bytes, inbox_dir: Path) -> dict[str, Any]:
    """Safely verify and atomically unpack a `.ctxaudio.zip` packet into `inbox_dir`."""
    inbox_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as tmp:
        tmp_path = Path(tmp.name)
        tmp.write(packet_bytes)

    try:
        with zipfile.ZipFile(tmp_path, "r") as zf:
            names = zf.namelist()
            if "manifest.json" not in names:
                raise ValueError("Packet missing manifest.json")
            manifest = json.loads(zf.read("manifest.json").decode("utf-8"))
            seg_id = str(manifest.get("id") or "").strip()
            if not seg_id or "/" in seg_id or "\\" in seg_id or ".." in seg_id:
                raise ValueError("Invalid segment ID in packet manifest")
            audio_name = Path(str(manifest.get("fileName") or "")).name
            if not audio_name or audio_name not in names:
                # Fallback to first non-manifest file in zip
                other = [n for n in names if n != "manifest.json" and not n.endswith("/")]
                if not other:
                    raise ValueError("Packet missing audio payload")
                audio_name = other[0]
            audio_bytes = zf.read(audio_name)
            expected_sha = manifest.get("sha256")
            actual_sha = hashlib.sha256(audio_bytes).hexdigest()
            if expected_sha and actual_sha != expected_sha:
                raise ValueError(f"Audio SHA-256 mismatch: expected {expected_sha}, got {actual_sha}")

            safe_audio_name = f"{seg_id}{Path(audio_name).suffix or '.m4a'}"
            manifest["fileName"] = safe_audio_name
            manifest["sha256"] = actual_sha
            manifest["byteCount"] = len(audio_bytes)

            # Write audio first, then manifest sidecar atomically so AudioCollector never sees half-unpacked items
            _atomic_write_bytes(inbox_dir / safe_audio_name, audio_bytes)
            _atomic_write_bytes(
                inbox_dir / f"{seg_id}.json",
                json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8"),
            )
            return {"segment_id": seg_id, "audio_file": safe_audio_name, "bytes": len(audio_bytes)}
    finally:
        tmp_path.unlink(missing_ok=True)


@dataclass
class CloudPullReport:
    provider: str
    downloaded: int = 0
    skipped_existing: int = 0
    errors: list[str] = field(default_factory=list)
    cursor: str | None = None
    elapsed_ms: int = 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "provider": self.provider,
            "downloaded": self.downloaded,
            "skipped_existing": self.skipped_existing,
            "errors": self.errors[:20],
            "cursor": self.cursor,
            "elapsed_ms": self.elapsed_ms,
        }


# ----------------------------------------------------------------------
# Adapter 1: WebDAV (坚果云 Nutstore / 群晖 NAS / Nextcloud / Alist)
# ----------------------------------------------------------------------
class WebDAVAudioTransport:
    """Zero-proxy domestic consumer cloud adapter over standard RFC 4918 WebDAV."""

    def __init__(
        self,
        base_url: str,
        *,
        username: str,
        password: str,
        use_system_proxy: bool = False,
        timeout: float = 30.0,
    ):
        self.base_url = base_url.rstrip("/") + "/"
        self.username = username
        self.password = password
        self.timeout = timeout
        auth = base64.b64encode(f"{username}:{password}".encode()).decode("ascii")
        self._auth_header = f"Basic {auth}"
        self._opener = (
            urllib.request.build_opener()
            if use_system_proxy
            else urllib.request.build_opener(urllib.request.ProxyHandler({}))
        )

    def _request(
        self,
        method: str,
        url: str,
        *,
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, bytes, dict[str, str]]:
        req_headers = {"Authorization": self._auth_header, **(headers or {})}
        req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
        with self._opener.open(req, timeout=self.timeout) as resp:
            return resp.status, resp.read(), dict(resp.headers.items())

    def ensure_collection(self) -> None:
        try:
            self._request("MKCOL", self.base_url)
        except urllib.error.HTTPError as exc:
            # 405 Method Not Allowed or 301/409 means collection already exists
            if exc.code not in (405, 301, 409):
                raise

    def upload_packet(self, packet_path: Path) -> str:
        """Single-request atomic PUT upload to WebDAV (e.g. Nutstore)."""
        target = urllib.parse.urljoin(self.base_url, urllib.parse.quote(packet_path.name))
        status, _, headers = self._request(
            "PUT",
            target,
            data=packet_path.read_bytes(),
            headers={"Content-Type": "application/zip"},
        )
        if status not in (200, 201, 204):
            raise RuntimeError(f"WebDAV PUT failed with HTTP {status}")
        return headers.get("ETag") or headers.get("etag") or ""

    def list_remote_packets(self) -> list[dict[str, str]]:
        """PROPFIND Depth: 1 listing `.ctxaudio.zip` packets with ETag & size."""
        body = (
            b'<?xml version="1.0" encoding="utf-8"?>'
            b'<d:propfind xmlns:d="DAV:"><d:prop>'
            b"<d:getetag/><d:getcontentlength/><d:getlastmodified/>"
            b"</d:prop></d:propfind>"
        )
        _, raw, _ = self._request(
            "PROPFIND",
            self.base_url,
            data=body,
            headers={"Depth": "1", "Content-Type": "application/xml; charset=utf-8"},
        )
        root = ET.fromstring(raw)
        ns = {"d": "DAV:"}
        items: list[dict[str, str]] = []
        for resp in root.findall("d:response", ns):
            href_el = resp.find("d:href", ns)
            if href_el is None or not href_el.text:
                continue
            name = urllib.parse.unquote(href_el.text.rstrip("/").rsplit("/", 1)[-1])
            if not name.endswith(PACKET_SUFFIX):
                continue
            etag = (resp.findtext(".//d:getetag", default="", namespaces=ns) or "").strip('"')
            size = resp.findtext(".//d:getcontentlength", default="0", namespaces=ns) or "0"
            items.append({"name": name, "etag": etag, "size": size})
        items.sort(key=lambda x: x["name"])
        return items

    def pull_to_inbox(
        self,
        inbox_dir: Path,
        checkpoints: CheckpointBackend | None = None,
    ) -> CloudPullReport:
        t0 = time.perf_counter()
        report = CloudPullReport(provider="webdav")
        cp_key = f"webdav:{self.base_url}"
        prior = (checkpoints.get("audio_cloud", cp_key) if checkpoints else None) or {}
        seen_etags: dict[str, str] = dict((prior.get("cursor") or {}).get("etags") or {})

        try:
            remote = self.list_remote_packets()
        except Exception as exc:  # noqa: BLE001
            report.errors.append(f"PROPFIND failed: {exc}")
            report.elapsed_ms = round((time.perf_counter() - t0) * 1000)
            return report

        for entry in remote:
            name = entry["name"]
            sig = entry["etag"] or f"size:{entry['size']}"
            if seen_etags.get(name) == sig:
                report.skipped_existing += 1
                continue
            url = urllib.parse.urljoin(self.base_url, urllib.parse.quote(name))
            try:
                _, raw, _ = self._request("GET", url)
                unpack_audio_packet(raw, inbox_dir)
                seen_etags[name] = sig
                report.downloaded += 1
            except Exception as exc:  # noqa: BLE001
                report.errors.append(f"{name}: {exc}")

        if checkpoints is not None:
            checkpoints.put("audio_cloud", cp_key, cursor={"etags": seen_etags})
        report.cursor = f"etags={len(seen_etags)}"
        report.elapsed_ms = round((time.perf_counter() - t0) * 1000)
        return report


# ----------------------------------------------------------------------
# Adapter 2: Google Drive (Proxy-Friendly Incremental `changes.list` + Single Multipart Upload)
# ----------------------------------------------------------------------
class GoogleDriveAudioTransport:
    """Proxy-aware incremental Google Drive adapter supporting v2 packets & legacy folders."""

    DRIVE_API = "https://www.googleapis.com/drive/v3"
    UPLOAD_API = "https://www.googleapis.com/upload/drive/v3"

    def __init__(
        self,
        access_token: str,
        folder_id: str,
        *,
        timeout: float = 30.0,
    ):
        self.access_token = access_token.strip()
        self.folder_id = folder_id.strip()
        self.timeout = timeout
        # Respect system HTTPS_PROXY / ALL_PROXY (e.g. Clash Verge 127.0.0.1:7897)
        self._opener = urllib.request.build_opener()

    def _request(
        self,
        method: str,
        url: str,
        *,
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> bytes:
        req_headers = {"Authorization": f"Bearer {self.access_token}", **(headers or {})}
        req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
        with self._opener.open(req, timeout=self.timeout) as resp:
            return resp.read()

    def upload_packet_multipart(self, packet_path: Path) -> dict[str, Any]:
        """Upload `.ctxaudio.zip` in ONE single multipart HTTP request (vs 10+ legacy calls)."""
        boundary = f"ctxhub-{hashlib.sha256(packet_path.name.encode()).hexdigest()[:16]}"
        meta = json.dumps(
            {
                "name": packet_path.name,
                "parents": [self.folder_id],
                "mimeType": "application/zip",
                "appProperties": {"ctxAudioPacket": "v2"},
            }
        ).encode("utf-8")
        payload = packet_path.read_bytes()
        body = (
            f"--{boundary}\r\n"
            "Content-Type: application/json; charset=UTF-8\r\n\r\n"
        ).encode() + meta + (
            f"\r\n--{boundary}\r\n"
            "Content-Type: application/zip\r\n\r\n"
        ).encode() + payload + f"\r\n--{boundary}--\r\n".encode()

        url = f"{self.UPLOAD_API}/files?uploadType=multipart&fields=id,name,size,sha256Checksum"
        raw = self._request(
            "POST",
            url,
            data=body,
            headers={"Content-Type": f"multipart/related; boundary={boundary}"},
        )
        return json.loads(raw.decode("utf-8"))

    def _get_start_page_token(self) -> str:
        raw = self._request("GET", f"{self.DRIVE_API}/changes/startPageToken")
        return str(json.loads(raw.decode("utf-8"))["startPageToken"])

    def _list_folder_files(self) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        page_token: str | None = None
        q = f"'{self.folder_id}' in parents and trashed=false"
        fields = "nextPageToken,files(id,name,size,sha256Checksum,mimeType,parents,trashed)"
        while True:
            params = {"q": q, "pageSize": "100", "fields": fields, "spaces": "drive"}
            if page_token:
                params["pageToken"] = page_token
            url = f"{self.DRIVE_API}/files?{urllib.parse.urlencode(params)}"
            data = json.loads(self._request("GET", url).decode("utf-8"))
            out.extend(data.get("files") or [])
            page_token = data.get("nextPageToken")
            if not page_token:
                break
        return out

    def _list_changes(self, page_token: str) -> tuple[list[dict[str, Any]], str]:
        changed_files: list[dict[str, Any]] = []
        cursor = page_token
        fields = "nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,size,sha256Checksum,mimeType,parents,trashed))"
        while True:
            params = {
                "pageToken": cursor,
                "pageSize": "100",
                "fields": fields,
                "spaces": "drive",
            }
            url = f"{self.DRIVE_API}/changes?{urllib.parse.urlencode(params)}"
            data = json.loads(self._request("GET", url).decode("utf-8"))
            for ch in data.get("changes") or []:
                f = ch.get("file")
                if (
                    not ch.get("removed")
                    and isinstance(f, dict)
                    and not f.get("trashed")
                    and self.folder_id in (f.get("parents") or [])
                ):
                    changed_files.append(f)
            if data.get("nextPageToken"):
                cursor = str(data["nextPageToken"])
            else:
                return changed_files, str(data.get("newStartPageToken") or cursor)

    def pull_to_inbox(
        self,
        inbox_dir: Path,
        checkpoints: CheckpointBackend | None = None,
    ) -> CloudPullReport:
        """Incrementally pull new `.ctxaudio.zip` packets from Google Drive into `inbox_dir`."""
        t0 = time.perf_counter()
        report = CloudPullReport(provider="google_drive")
        cp_key = f"gdrive:{self.folder_id}"
        prior = (checkpoints.get("audio_cloud", cp_key) if checkpoints else None) or {}
        prior_cursor = dict(prior.get("cursor") or {})
        change_token: str | None = prior_cursor.get("change_token")
        seen_ids: dict[str, str] = dict(prior_cursor.get("seen_ids") or {})

        try:
            if change_token:
                files, next_token = self._list_changes(change_token)
            else:
                next_token = self._get_start_page_token()
                files = self._list_folder_files()
        except Exception as exc:  # noqa: BLE001
            report.errors.append(f"Drive discovery failed: {exc}")
            report.elapsed_ms = round((time.perf_counter() - t0) * 1000)
            return report

        for f in files:
            name = str(f.get("name") or "")
            fid = str(f.get("id") or "")
            if not fid or not name.endswith(PACKET_SUFFIX):
                continue
            checksum = str(f.get("sha256Checksum") or f.get("size") or "")
            if seen_ids.get(fid) == checksum:
                report.skipped_existing += 1
                continue
            try:
                raw = self._request("GET", f"{self.DRIVE_API}/files/{fid}?alt=media")
                if f.get("sha256Checksum"):
                    actual = hashlib.sha256(raw).hexdigest()
                    if actual != f["sha256Checksum"]:
                        raise ValueError("Google Drive sha256Checksum mismatch")
                unpack_audio_packet(raw, inbox_dir)
                seen_ids[fid] = checksum
                report.downloaded += 1
            except Exception as exc:  # noqa: BLE001
                report.errors.append(f"{name}: {exc}")

        if checkpoints is not None:
            checkpoints.put(
                "audio_cloud",
                cp_key,
                cursor={"change_token": next_token, "seen_ids": seen_ids},
            )
        report.cursor = next_token
        report.elapsed_ms = round((time.perf_counter() - t0) * 1000)
        return report


def probe_cloud_endpoints() -> list[dict[str, Any]]:
    """Measure live reachability & latency of consumer cloud transports from this Mac."""
    targets = [
        ("Apple CloudKit (iCloud Private DB)", "https://api.apple-cloudkit.com/database/1/", False, "HEAD"),
        ("坚果云 WebDAV (Nutstore)", "https://dav.jianguoyun.com/dav/", False, "HEAD"),
        ("Google Drive API (via system proxy)", "https://www.googleapis.com/discovery/v1/apis/drive/v3/rest", True, "GET"),
        ("Google Drive API (direct, no proxy)", "https://www.googleapis.com/discovery/v1/apis/drive/v3/rest", False, "GET"),
    ]
    results: list[dict[str, Any]] = []
    for name, url, use_proxy, method in targets:
        opener = (
            urllib.request.build_opener()
            if use_proxy
            else urllib.request.build_opener(urllib.request.ProxyHandler({}))
        )
        t0 = time.perf_counter()
        try:
            req = urllib.request.Request(url, method=method)
            with opener.open(req, timeout=6) as resp:
                results.append(
                    {
                        "name": name,
                        "reachable": True,
                        "http_status": resp.status,
                        "latency_ms": round((time.perf_counter() - t0) * 1000),
                        "via_proxy": use_proxy,
                    }
                )
        except urllib.error.HTTPError as exc:
            # 401/403/501 still prove direct TLS + endpoint reachability
            results.append(
                {
                    "name": name,
                    "reachable": True,
                    "http_status": exc.code,
                    "latency_ms": round((time.perf_counter() - t0) * 1000),
                    "via_proxy": use_proxy,
                }
            )
        except Exception as exc:  # noqa: BLE001
            results.append(
                {
                    "name": name,
                    "reachable": False,
                    "error": f"{type(exc).__name__}: {exc}",
                    "latency_ms": round((time.perf_counter() - t0) * 1000),
                    "via_proxy": use_proxy,
                }
            )
    return results


def _percentile(sorted_values: list[float], p: float) -> float | None:
    if not sorted_values:
        return None
    idx = min(len(sorted_values) - 1, max(0, int(round((len(sorted_values) - 1) * p))))
    return round(sorted_values[idx], 2)


def build_audio_soak_report(
    *,
    inbox_dir: Path | None = None,
    companion_state_dir: Path | None = None,
    since_hours: float = 72.0,
    verify_sha256: bool = True,
    probe_cloud: bool = True,
) -> dict[str, Any]:
    """Audit real-world iCloud/WebDAV audio sync health, integrity, compression, and SLA latency."""
    hub_root = Path.home() / ".local" / "share" / "context-hub-v2"
    inbox = inbox_dir or (hub_root / "inbox" / "audio")
    comp_dir = companion_state_dir or (hub_root / "mac-companion")
    now = time.time()
    cutoff = now - max(0.0, since_hours) * 3600.0

    # 1. Mac Companion process & CloudKit engine state
    companion_running = False
    try:
        ps = subprocess.run(["pgrep", "-x", "ContextAudioCompanion"], capture_output=True, text=True, timeout=3)
        companion_running = ps.returncode == 0 and bool(ps.stdout.strip())
    except Exception:  # noqa: BLE001
        companion_running = False

    state_file = comp_dir / "ck-engine-state.bin"
    ledger_file = comp_dir / "synced-ids.json"
    synced_ledger_count = 0
    if ledger_file.is_file():
        try:
            loaded = json.loads(ledger_file.read_text(encoding="utf-8"))
            if isinstance(loaded, list):
                synced_ledger_count = len(loaded)
        except Exception:  # noqa: BLE001
            pass

    companion_info = {
        "process_running": companion_running,
        "ck_engine_state_exists": state_file.is_file(),
        "ck_engine_state_bytes": state_file.stat().st_size if state_file.is_file() else 0,
        "ck_engine_state_age_seconds": (
            round(max(0.0, now - state_file.stat().st_mtime), 1) if state_file.is_file() else None
        ),
        "synced_ledger_count": synced_ledger_count,
    }

    # 2. Inbox segments integrity, compression ratio, latency & sequence gaps
    sidecars = sorted(p for p in inbox.glob("*.json") if p.is_file() and not p.is_symlink()) if inbox.is_dir() else []
    missing_audio: list[str] = []
    sha_mismatches: list[str] = []
    parse_errors: list[str] = []
    total_compressed = 0
    total_original = 0
    recent_landed = 0
    latencies_s: list[float] = []
    sessions: dict[str, set[int]] = {}
    newest_landed_at: float | None = None

    for meta_path in sidecars:
        try:
            m = json.loads(meta_path.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            parse_errors.append(f"{meta_path.name}: {exc}")
            continue

        seg_id = str(m.get("id") or meta_path.stem)
        fname = str(m.get("fileName") or f"{seg_id}.m4a")
        audio_path = inbox / Path(fname).name
        if not audio_path.is_file():
            missing_audio.append(seg_id)
            continue

        audio_size = audio_path.stat().st_size
        total_compressed += audio_size
        orig_size = int(m.get("originalByteCount") or audio_size)
        total_original += orig_size

        expected_sha = str(m.get("sha256") or "").strip().lower()
        if verify_sha256 and expected_sha:
            actual_sha = _sha256_file(audio_path).lower()
            if actual_sha != expected_sha:
                sha_mismatches.append(seg_id)

        landed_ts = meta_path.stat().st_mtime
        if newest_landed_at is None or landed_ts > newest_landed_at:
            newest_landed_at = landed_ts

        ended_raw = m.get("endedAt")
        ended_s: float | None = None
        if isinstance(ended_raw, (int, float)):
            ended_s = float(ended_raw) / 1000.0 if ended_raw > 1e11 else float(ended_raw)

        if ended_s is not None and ended_s >= cutoff:
            recent_landed += 1
            delta = landed_ts - ended_s
            # Exclude huge negative clock skew; include positive real delivery latencies
            if -5.0 <= delta <= 7 * 86400:
                latencies_s.append(max(0.0, delta))

        sess_id = str(m.get("sessionID") or "")
        seq = m.get("sequence")
        if sess_id and isinstance(seq, int):
            sessions.setdefault(sess_id, set()).add(seq)

    sequence_gaps: list[dict[str, Any]] = []
    for sess_id, seqs in sessions.items():
        if len(seqs) >= 2:
            lo, hi = min(seqs), max(seqs)
            missing_seqs = sorted(set(range(lo, hi + 1)) - seqs)
            if missing_seqs:
                sequence_gaps.append({"session_id": sess_id, "missing_sequences": missing_seqs})

    latencies_s.sort()
    report: dict[str, Any] = {
        "window_hours": since_hours,
        "companion": companion_info,
        "inbox": {
            "path": str(inbox),
            "segments_total": len(sidecars),
            "segments_recorded_in_window": recent_landed,
            "missing_audio_pairs": len(missing_audio),
            "sha256_mismatches": len(sha_mismatches),
            "parse_errors": len(parse_errors),
            "sequence_gap_sessions": len(sequence_gaps),
            "sequence_gaps": sequence_gaps[:10],
            "total_compressed_bytes": total_compressed,
            "total_original_bytes": total_original,
            "compression_ratio": round(total_original / max(1, total_compressed), 2) if total_compressed else None,
            "newest_landed_age_seconds": (
                round(max(0.0, now - newest_landed_at), 1) if newest_landed_at is not None else None
            ),
            "delivery_latency_seconds": {
                "samples": len(latencies_s),
                "p50": _percentile(latencies_s, 0.50),
                "p95": _percentile(latencies_s, 0.95),
                "max": round(latencies_s[-1], 2) if latencies_s else None,
            },
        },
        "healthy": (
            companion_info["process_running"]
            and companion_info["ck_engine_state_exists"]
            and not missing_audio
            and not sha_mismatches
            and not parse_errors
        ),
    }
    if probe_cloud:
        report["cloud_endpoints"] = probe_cloud_endpoints()
    return report
