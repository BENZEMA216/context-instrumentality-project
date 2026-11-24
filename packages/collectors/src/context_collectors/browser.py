"""Read for Agent — Local Browser History Collector (Chrome / Arc / Brave / Edge / Safari).

Safely reads local Chromium (`History`) and Safari (`History.db`) databases via temporary
snapshot copies (never locking a running browser), filters out auth/OAuth/redirect noise,
applies privacy tiers to sensitive domains, canonicalizes URLs for cross-channel anchor
linking with Clip for Agent and AI Chat, and syncs incrementally via per-profile watermarks.
"""

from __future__ import annotations

import hashlib
import shutil
import sqlite3
import tempfile
import time
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from context_hub.anchors import canonicalize_url
from context_hub.models import RawEventIn

from .runtime import CheckpointBackend, HubSink, SyncReport, default_device_id

_CHROMIUM_EPOCH_OFFSET_MS = 11_644_473_600_000
_SAFARI_EPOCH_OFFSET_SEC = 978_307_200.0

_NOISE_HOST_PREFIXES = (
    "accounts.",
    "login.",
    "signin.",
    "auth.",
    "sso.",
    "oauth.",
    "id.",
)
_NOISE_HOSTS = frozenset(
    {
        "localhost",
        "127.0.0.1",
        "0.0.0.0",
        "newtab",
        "extensions",
    }
)
_NOISE_PATH_MARKERS = (
    "/oauth",
    "/login",
    "/signin",
    "/sso/",
    "/callback",
    "/authorize",
    "/captcha",
)
_SENSITIVE_DOMAIN_SUBSTRINGS = (
    "mail.google.com",
    "outlook.live.com",
    "outlook.office",
    "mail.qq.com",
    "1password.",
    "bitwarden.",
    "icloud.com",
    "alipay.com",
    "paypal.com",
    "stripe.com/dashboard",
    "chase.com",
    "bankofamerica.com",
    "cmbchina.com",
    "icbc.com.cn",
    "mychart.",
)


@dataclass(slots=True)
class BrowserProfileSource:
    browser: str  # "chrome" | "arc" | "brave" | "edge" | "safari"
    engine: str  # "chromium" | "safari"
    profile: str
    db_path: Path

    @property
    def source_key(self) -> str:
        return f"browser:{self.browser}:{self.profile}:{self.db_path}"


def discover_browser_sources(home: Path | None = None) -> list[BrowserProfileSource]:
    """Discover readable local Chromium & Safari History SQLite databases."""
    root = Path(home or Path.home()).expanduser()
    candidates: list[tuple[str, str, Path]] = [
        ("chrome", "chromium", root / "Library/Application Support/Google/Chrome"),
        ("arc", "chromium", root / "Library/Application Support/Arc/User Data"),
        ("brave", "chromium", root / "Library/Application Support/BraveSoftware/Brave-Browser"),
        ("edge", "chromium", root / "Library/Application Support/Microsoft Edge"),
        # Linux paths for cross-platform support
        ("chrome", "chromium", root / ".config/google-chrome"),
        ("brave", "chromium", root / ".config/BraveSoftware/Brave-Browser"),
    ]
    found: list[BrowserProfileSource] = []

    for browser, engine, base in candidates:
        if not base.is_dir():
            continue
        profile_dirs = [base / "Default"] + sorted(base.glob("Profile *"))
        for pdir in profile_dirs:
            db = pdir / "History"
            if db.is_file():
                found.append(
                    BrowserProfileSource(
                        browser=browser,
                        engine=engine,
                        profile=pdir.name,
                        db_path=db,
                    )
                )

    safari_db = root / "Library/Safari/History.db"
    if safari_db.is_file():
        found.append(
            BrowserProfileSource(
                browser="safari",
                engine="safari",
                profile="Default",
                db_path=safari_db,
            )
        )
    return found


def _chromium_us_to_unix_ms(webkit_us: int) -> int:
    if webkit_us <= 0:
        return 0
    return (webkit_us // 1000) - _CHROMIUM_EPOCH_OFFSET_MS


def _safari_sec_to_unix_ms(mac_sec: float) -> int:
    if mac_sec <= 0:
        return 0
    return int((mac_sec + _SAFARI_EPOCH_OFFSET_SEC) * 1000)


def _is_noise_url(url: str, title: str) -> bool:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        return True
    host = (parsed.hostname or "").casefold()
    if not host or host in _NOISE_HOSTS:
        return True
    if any(host.startswith(pref) for pref in _NOISE_HOST_PREFIXES):
        return True
    path_low = (parsed.path or "").casefold()
    if any(marker in path_low for marker in _NOISE_PATH_MARKERS):
        return True
    # Drop search-engine SERP bounce clutter unless it has a substantial title
    if host in {"www.google.com", "google.com", "www.bing.com", "www.baidu.com"} and path_low in {
        "/search",
        "/s",
        "/url",
    }:
        return True
    return not title.strip()


def _privacy_for_url(url: str) -> dict[str, Any]:
    low = url.casefold()
    if any(sub in low for sub in _SENSITIVE_DOMAIN_SUBSTRINGS):
        return {"tier": "local_only", "pii_tags": ["sensitive_domain"]}
    return {"tier": "shareable", "pii_tags": []}


def _snapshot_sqlite_query(
    db_path: Path,
    sql: str,
    params: tuple[Any, ...],
) -> list[sqlite3.Row]:
    """Copy SQLite DB (+ WAL/SHM if present) into temp dir and query read-only without locking."""
    with tempfile.TemporaryDirectory(prefix="raw-mem-browser-") as td:
        tmp_db = Path(td) / db_path.name
        shutil.copy2(db_path, tmp_db)
        for suffix in ("-wal", "-shm"):
            side = Path(f"{db_path}{suffix}")
            if side.is_file():
                with suppress(OSError):
                    shutil.copy2(side, Path(f"{tmp_db}{suffix}"))
        conn = sqlite3.connect(f"file:{tmp_db}?mode=ro", uri=True, timeout=5)
        conn.row_factory = sqlite3.Row
        try:
            return conn.execute(sql, params).fetchall()
        finally:
            conn.close()


class BrowserHistoryCollector:
    """Read for Agent local Chromium/Safari history collector implementing `Collector`."""

    name = "browser"
    source = "browser"

    def __init__(
        self,
        *,
        sources: list[BrowserProfileSource] | None = None,
        home: Path | None = None,
        since_days: float = 14.0,
        min_dwell_ms: int = 5_000,
        max_events_per_source: int = 500,
    ):
        self._explicit_sources = sources
        self._home = home
        self.since_days = since_days
        self.min_dwell_ms = max(0, min_dwell_ms)
        self.max_events_per_source = max(1, max_events_per_source)

    def _sources(self) -> list[BrowserProfileSource]:
        if self._explicit_sources is not None:
            return list(self._explicit_sources)
        return discover_browser_sources(self._home)

    def doctor(self) -> dict[str, Any]:
        srcs = self._sources()
        details: list[dict[str, Any]] = []
        readable = 0
        for src in srcs:
            ok = False
            err = None
            try:
                with src.db_path.open("rb") as fh:
                    fh.read(16)
                ok = True
                readable += 1
            except OSError as exc:
                err = str(exc)
            details.append(
                {
                    "browser": src.browser,
                    "engine": src.engine,
                    "profile": src.profile,
                    "path": str(src.db_path),
                    "readable": ok,
                    "error": err,
                }
            )
        return {
            "collector": self.name,
            "source": self.source,
            "available": readable > 0,
            "readable_profiles": readable,
            "profiles": details,
        }

    def _read_chromium(
        self,
        src: BrowserProfileSource,
        since_ms: int,
    ) -> tuple[list[RawEventIn], int]:
        since_us = max(0, (since_ms + _CHROMIUM_EPOCH_OFFSET_MS) * 1000)
        sql = """
            SELECT v.id AS visit_id,
                   u.url AS url,
                   u.title AS title,
                   u.visit_count AS visit_count,
                   v.visit_time AS visit_time,
                   COALESCE(v.visit_duration, 0) AS visit_duration_us
            FROM visits v
            JOIN urls u ON u.id = v.url
            WHERE v.visit_time > ?
            ORDER BY v.visit_time ASC
            LIMIT ?
        """
        rows = _snapshot_sqlite_query(src.db_path, sql, (since_us, self.max_events_per_source * 3))
        events: list[RawEventIn] = []
        max_ms = since_ms
        device_id = default_device_id()

        for r in rows:
            t_start = _chromium_us_to_unix_ms(int(r["visit_time"]))
            if t_start <= 0:
                continue
            max_ms = max(max_ms, t_start)
            url = str(r["url"] or "").strip()
            title = str(r["title"] or "").strip()
            dwell_ms = int(r["visit_duration_us"] or 0) // 1000
            visit_count = int(r["visit_count"] or 1)
            if _is_noise_url(url, title):
                continue
            # Filter sub-threshold bounce hops unless revisited repeatedly
            if dwell_ms > 0 and dwell_ms < self.min_dwell_ms and visit_count < 3:
                continue

            url_norm = canonicalize_url(url)
            host = (urlparse(url_norm).hostname or "").casefold()
            attention = min(1.0, round(0.35 + min(dwell_ms, 180_000) / 300_000 + min(visit_count, 5) * 0.05, 3))
            source_id = hashlib.sha256(
                f"{src.browser}:{src.profile}:{r['visit_id']}:{url_norm}".encode()
            ).hexdigest()[:24]
            summary = f"{title} ({host})" + (f" · dwell {dwell_ms // 1000}s" if dwell_ms >= 1000 else "")
            events.append(
                RawEventIn(
                    source="browser",
                    kind="page_visit",
                    t_start=t_start,
                    t_end=t_start + max(0, min(dwell_ms, 3_600_000)),
                    actor="self",
                    device_id=device_id,
                    attention=attention,
                    content={
                        "title": title[:240],
                        "url": url,
                        "url_norm": url_norm,
                        "text": f"{title}\n{url_norm}",
                        "summary": summary,
                    },
                    context={
                        "browser": src.browser,
                        "profile": src.profile,
                        "domain": host,
                        "dwell_ms": dwell_ms,
                        "visit_count": visit_count,
                        "curation_tier": "auto_curated" if dwell_ms >= 30_000 else "raw_history",
                    },
                    provenance={
                        "connector": f"read-for-agent/{src.browser}",
                        "source_id": source_id,
                        "locator": url_norm,
                    },
                    privacy=_privacy_for_url(url_norm),
                )
            )
            if len(events) >= self.max_events_per_source:
                break

        return events, max_ms

    def _read_safari(
        self,
        src: BrowserProfileSource,
        since_ms: int,
    ) -> tuple[list[RawEventIn], int]:
        since_mac_sec = max(0.0, (since_ms / 1000.0) - _SAFARI_EPOCH_OFFSET_SEC)
        sql = """
            SELECT v.id AS visit_id,
                   i.url AS url,
                   COALESCE(v.title, '') AS title,
                   i.visit_count AS visit_count,
                   v.visit_time AS visit_time
            FROM history_visits v
            JOIN history_items i ON i.id = v.history_item
            WHERE v.visit_time > ?
            ORDER BY v.visit_time ASC
            LIMIT ?
        """
        rows = _snapshot_sqlite_query(
            src.db_path, sql, (since_mac_sec, self.max_events_per_source * 3)
        )
        events: list[RawEventIn] = []
        max_ms = since_ms
        device_id = default_device_id()

        for r in rows:
            t_start = _safari_sec_to_unix_ms(float(r["visit_time"] or 0.0))
            if t_start <= 0:
                continue
            max_ms = max(max_ms, t_start)
            url = str(r["url"] or "").strip()
            title = str(r["title"] or "").strip()
            visit_count = int(r["visit_count"] or 1)
            if _is_noise_url(url, title):
                continue

            url_norm = canonicalize_url(url)
            host = (urlparse(url_norm).hostname or "").casefold()
            source_id = hashlib.sha256(
                f"safari:{r['visit_id']}:{url_norm}".encode()
            ).hexdigest()[:24]
            events.append(
                RawEventIn(
                    source="browser",
                    kind="page_visit",
                    t_start=t_start,
                    t_end=t_start,
                    actor="self",
                    device_id=device_id,
                    attention=min(1.0, round(0.4 + min(visit_count, 5) * 0.06, 3)),
                    content={
                        "title": title[:240],
                        "url": url,
                        "url_norm": url_norm,
                        "text": f"{title}\n{url_norm}",
                        "summary": f"{title} ({host})",
                    },
                    context={
                        "browser": "safari",
                        "profile": src.profile,
                        "domain": host,
                        "visit_count": visit_count,
                        "curation_tier": "raw_history",
                    },
                    provenance={
                        "connector": "read-for-agent/safari",
                        "source_id": source_id,
                        "locator": url_norm,
                    },
                    privacy=_privacy_for_url(url_norm),
                )
            )
            if len(events) >= self.max_events_per_source:
                break

        return events, max_ms

    def sync(self, sink: HubSink, checkpoints: CheckpointBackend) -> SyncReport:
        report = SyncReport(collector=self.name, source=self.source)
        default_since_ms = int((time.time() - self.since_days * 86_400.0) * 1000)
        latest_watermark_ms = 0

        for src in self._sources():
            report.sources_scanned += 1
            try:
                st = src.db_path.stat()
            except OSError as exc:
                report.skipped_errors += 1
                report.errors.append(f"{src.browser}:{src.profile}: {exc}")
                continue

            cp = checkpoints.get(self.name, src.source_key)
            if cp and cp.get("inode") == st.st_ino and cp.get("file_size") == st.st_size and cp.get("mtime_ns") == st.st_mtime_ns:
                report.sources_unchanged += 1
                continue

            cursor = (cp or {}).get("cursor") or {}
            since_ms = int(cursor.get("last_visit_ms") or default_since_ms)
            try:
                if src.engine == "chromium":
                    events, max_ms = self._read_chromium(src, since_ms)
                else:
                    events, max_ms = self._read_safari(src, since_ms)
            except (OSError, sqlite3.Error) as exc:
                # e.g. macOS Full Disk Access not granted for Safari/History.db
                report.skipped_errors += 1
                report.errors.append(f"{src.browser}:{src.profile}: {exc}")
                continue

            if events:
                res = sink.emit_batch(self.name, events)
                report.events_emitted += len(events)
                report.created += res.get("created", 0)
                report.existing += res.get("existing", 0)
                report.spooled += res.get("spooled", 0)

            latest_watermark_ms = max(latest_watermark_ms, max_ms)
            checkpoints.put(
                self.name,
                src.source_key,
                inode=st.st_ino,
                file_size=st.st_size,
                mtime_ns=st.st_mtime_ns,
                cursor={"last_visit_ms": max_ms},
            )

        if latest_watermark_ms > 0:
            report.watermark = str(latest_watermark_ms)
        if report.sources_scanned == 0:
            report.status = "unconfigured"
            report.message = "No Chromium or Safari History DB found"
        elif report.skipped_errors > 0 and report.created == 0 and report.existing == 0 and report.sources_unchanged == 0:
            report.status = "degraded"
            report.message = "; ".join(report.errors[:3])
        return report
