"""Focus for Agent — Window Focus & Active Dwell Collector (ActivityWatch + Native macOS).

Captures focused application & window dwell blocks with strict privacy filtering:
  1. ActivityWatch local REST bridge (`http://127.0.0.1:5600`) when installed & running.
  2. Native zero-dependency macOS frontmost-window sampler (`osascript` + `ioreg` HIDIdleTime)
     with session coalescing so rapid Alt-Tab switches never spam Raw Memory.
  3. Built-in privacy blocklist: drops password managers, lock screens, and Incognito/Private
     windows completely; marks mail/messaging/banking apps as `local_only`.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import platform
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from context_hub.models import RawEventIn, now_ms

from .runtime import CheckpointBackend, HubSink, SyncReport, default_device_id

_BLOCKED_APP_TOKENS = (
    "1password",
    "bitwarden",
    "keychain",
    "keepass",
    "passwords",
    "loginwindow",
    "screensaver",
    "securityagent",
    "authagent",
)
_BLOCKED_TITLE_TOKENS = (
    "incognito",
    "inprivate",
    "private browsing",
    "无痕",
    "隐私浏览",
    "password",
    "密码",
)
_LOCAL_ONLY_APPS = (
    "mail",
    "outlook",
    "wechat",
    "微信",
    "telegram",
    "messages",
    "whatsapp",
    "slack",
    "lark",
    "feishu",
    "飞书",
)
_IDE_APPS = frozenset(
    {
        "code",
        "visual studio code",
        "cursor",
        "xcode",
        "antigravity",
        "windsurf",
        "zed",
        "pycharm",
        "intellij idea",
        "goland",
    }
)
_HID_IDLE_RE = re.compile(r'"HIDIdleTime"\s*=\s*(\d+)')


@dataclass(slots=True)
class WindowSample:
    app_name: str
    app_bundle: str
    window_title: str
    t_start: int
    t_end: int
    idle_seconds: float = 0.0
    source_kind: str = "macos_native"

    @property
    def dwell_ms(self) -> int:
        return max(0, self.t_end - self.t_start)


def is_blocked_window(app_name: str, app_bundle: str, title: str) -> bool:
    """Return True if the window belongs to a password manager, lock screen, or private browsing."""
    app_low = f"{app_name} {app_bundle}".casefold()
    if any(tok in app_low for tok in _BLOCKED_APP_TOKENS):
        return True
    title_low = title.casefold()
    return any(tok in title_low for tok in _BLOCKED_TITLE_TOKENS)


def privacy_for_window(app_name: str, app_bundle: str) -> dict[str, Any]:
    app_low = f"{app_name} {app_bundle}".casefold()
    if any(tok in app_low for tok in _LOCAL_ONLY_APPS):
        return {"tier": "local_only", "pii_tags": ["sensitive_app"]}
    return {"tier": "shareable", "pii_tags": []}


def infer_project_from_window(app_name: str, title: str) -> str | None:
    """Infer a candidate workspace/project slug from common IDE window title conventions."""
    if not title.strip():
        return None
    if app_name.strip().casefold() not in _IDE_APPS:
        return None
    # Common patterns: "file.py — project-name — Cursor" or "project-name — file.swift"
    parts = [p.strip() for p in re.split(r"\s+[—–-]\s+", title) if p.strip()]
    if len(parts) >= 2:
        # Filter out the IDE name itself if trailing
        filtered = [p for p in parts if p.casefold() not in _IDE_APPS]
        if len(filtered) >= 2:
            # Usually second-to-last or last segment is the workspace folder name
            cand = filtered[-1]
            if "." not in cand or "/" in cand:
                return cand.split("/")[-1][:80]
        if filtered:
            cand = filtered[0]
            if "." not in cand:
                return cand[:80]
    return None


def sample_macos_idle_seconds() -> float:
    """Query macOS HID idle time in seconds via `ioreg` (returns 0.0 on non-macOS or error)."""
    if platform.system() != "Darwin":
        return 0.0
    try:
        proc = subprocess.run(
            ["ioreg", "-c", "IOHIDSystem"],
            capture_output=True,
            text=True,
            timeout=2.0,
            check=False,
        )
        m = _HID_IDLE_RE.search(proc.stdout)
        if m:
            return int(m.group(1)) / 1_000_000_000.0
    except (OSError, subprocess.SubprocessError):
        pass
    return 0.0


def sample_macos_active_window() -> WindowSample | None:
    """Sample frontmost macOS app & window title via zero-dependency `osascript`."""
    if platform.system() != "Darwin":
        return None
    idle = sample_macos_idle_seconds()
    script = (
        'tell application "System Events"\n'
        "  set frontApp to first application process whose frontmost is true\n"
        "  set appName to name of frontApp\n"
        '  set bundleId to ""\n'
        "  try\n"
        "    set bundleId to bundle identifier of frontApp\n"
        "  end try\n"
        '  set winTitle to ""\n'
        "  try\n"
        "    set winTitle to name of front window of frontApp\n"
        "  end try\n"
        '  return appName & "\t" & bundleId & "\t" & winTitle\n'
        "end tell"
    )
    try:
        proc = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=2.5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    line = proc.stdout.strip()
    if not line:
        return None
    parts = line.split("\t")
    app_name = parts[0].strip() if len(parts) > 0 else ""
    app_bundle = parts[1].strip() if len(parts) > 1 else ""
    win_title = parts[2].strip() if len(parts) > 2 else ""
    if not app_name:
        return None
    ts = now_ms()
    return WindowSample(
        app_name=app_name,
        app_bundle=app_bundle,
        window_title=win_title,
        t_start=ts,
        t_end=ts,
        idle_seconds=idle,
        source_kind="macos_native",
    )


def _parse_iso_ms(raw: str) -> int:
    cleaned = raw.strip().replace("Z", "+00:00")
    dt = datetime.datetime.fromisoformat(cleaned)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.UTC)
    return int(dt.timestamp() * 1000)


def fetch_activitywatch_window_samples(
    *,
    base_url: str = "http://127.0.0.1:5600",
    since_ms: int = 0,
    limit: int = 500,
    timeout: float = 2.0,
) -> list[WindowSample]:
    """Pull window focus events from a local ActivityWatch server if running."""
    base = base_url.rstrip("/")
    req = urllib.request.Request(f"{base}/api/0/buckets/", method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        buckets = json.loads(resp.read().decode("utf-8"))
    if not isinstance(buckets, dict):
        return []

    win_buckets = [
        bid
        for bid, meta in buckets.items()
        if isinstance(meta, dict)
        and (meta.get("type") == "currentwindow" or str(bid).startswith("aw-watcher-window"))
    ]
    samples: list[WindowSample] = []
    for bid in win_buckets:
        url = f"{base}/api/0/buckets/{bid}/events?limit={limit}"
        if since_ms > 0:
            iso = datetime.datetime.fromtimestamp(
                since_ms / 1000.0, tz=datetime.UTC
            ).isoformat()
            url += f"&start={urllib.parse.quote(iso)}"  # type: ignore[attr-defined]
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            events = json.loads(resp.read().decode("utf-8"))
        if not isinstance(events, list):
            continue
        for ev in events:
            if not isinstance(ev, dict):
                continue
            ts_str = str(ev.get("timestamp") or "")
            if not ts_str:
                continue
            try:
                t_start = _parse_iso_ms(ts_str)
            except ValueError:
                continue
            dur_ms = int(float(ev.get("duration") or 0.0) * 1000)
            data = ev.get("data") or {}
            app_name = str(data.get("app") or "").strip()
            title = str(data.get("title") or "").strip()
            if not app_name:
                continue
            samples.append(
                WindowSample(
                    app_name=app_name,
                    app_bundle="",
                    window_title=title,
                    t_start=t_start,
                    t_end=t_start + max(0, dur_ms),
                    source_kind="activitywatch",
                )
            )
    samples.sort(key=lambda s: s.t_start)
    return samples


def coalesce_window_samples(
    samples: list[WindowSample],
    *,
    max_gap_ms: int = 45_000,
    min_dwell_ms: int = 10_000,
) -> list[WindowSample]:
    """Merge consecutive identical `(app_name, window_title)` samples and drop short flickers."""
    if not samples:
        return []
    ordered = sorted(samples, key=lambda s: s.t_start)
    merged: list[WindowSample] = []
    for s in ordered:
        if is_blocked_window(s.app_name, s.app_bundle, s.window_title):
            continue
        if (
            merged
            and merged[-1].app_name == s.app_name
            and merged[-1].window_title == s.window_title
            and s.t_start - merged[-1].t_end <= max_gap_ms
        ):
            merged[-1].t_end = max(merged[-1].t_end, s.t_end)
        else:
            merged.append(
                WindowSample(
                    app_name=s.app_name,
                    app_bundle=s.app_bundle,
                    window_title=s.window_title,
                    t_start=s.t_start,
                    t_end=s.t_end,
                    idle_seconds=s.idle_seconds,
                    source_kind=s.source_kind,
                )
            )
    return [m for m in merged if m.dwell_ms >= min_dwell_ms]


def sample_to_raw_event(sample: WindowSample, *, device_id: str | None = None) -> RawEventIn:
    """Convert a coalesced `WindowSample` into a `RawEventIn` (`source='window'`)."""
    dev = device_id or default_device_id()
    title = f"{sample.app_name}: {sample.window_title}" if sample.window_title else sample.app_name
    project = infer_project_from_window(sample.app_name, sample.window_title)
    dwell_sec = round(sample.dwell_ms / 1000.0, 1)
    source_id = hashlib.sha256(
        f"{sample.source_kind}:{sample.app_name}:{sample.window_title}:{sample.t_start}".encode()
    ).hexdigest()[:24]
    attention = min(1.0, round(0.3 + min(sample.dwell_ms, 600_000) / 800_000, 3))
    return RawEventIn(
        source="window",
        kind="window_focus",
        t_start=sample.t_start,
        t_end=max(sample.t_start, sample.t_end),
        actor="self",
        device_id=dev,
        project=project,
        attention=attention,
        content={
            "title": title[:240],
            "text": f"[{sample.app_name}] {sample.window_title} (focus {dwell_sec}s)".strip(),
            "summary": f"Focused {sample.app_name} for {dwell_sec}s",
        },
        context={
            "app_name": sample.app_name,
            "app_bundle": sample.app_bundle,
            "window_title": sample.window_title[:240],
            "dwell_ms": sample.dwell_ms,
            "capture_backend": sample.source_kind,
        },
        provenance={
            "connector": f"focus-for-agent/{sample.source_kind}",
            "source_id": source_id,
            "locator": f"window://{sample.app_bundle or sample.app_name}#{sample.t_start}",
        },
        privacy=privacy_for_window(sample.app_name, sample.app_bundle),
    )


class WindowFocusCollector:
    """Focus for Agent collector supporting ActivityWatch + native macOS sampling."""

    name = "window"
    source = "window"

    def __init__(
        self,
        *,
        activitywatch_url: str = "http://127.0.0.1:5600",
        min_dwell_ms: int = 10_000,
        max_idle_seconds: float = 120.0,
        native_sampler: Any | None = None,
        sample_log_path: Path | None = None,
    ):
        self.activitywatch_url = activitywatch_url.rstrip("/")
        self.min_dwell_ms = max(0, min_dwell_ms)
        self.max_idle_seconds = max_idle_seconds
        self._native_sampler = native_sampler or sample_macos_active_window
        self._sample_log_path = sample_log_path

    def _activitywatch_available(self) -> bool:
        try:
            with urllib.request.urlopen(f"{self.activitywatch_url}/api/0/info", timeout=1.0) as r:
                return r.status == 200
        except (OSError, urllib.error.URLError):
            return False

    def doctor(self) -> dict[str, Any]:
        aw_ok = self._activitywatch_available()
        native_sample = None
        if platform.system() == "Darwin":
            native_sample = self._native_sampler()
        return {
            "collector": self.name,
            "source": self.source,
            "available": aw_ok or native_sample is not None,
            "activitywatch_reachable": aw_ok,
            "activitywatch_url": self.activitywatch_url,
            "native_macos_available": native_sample is not None,
            "native_sample_app": native_sample.app_name if native_sample else None,
        }

    def sync(self, sink: HubSink, checkpoints: CheckpointBackend) -> SyncReport:
        report = SyncReport(collector=self.name, source=self.source)
        samples: list[WindowSample] = []

        # 1. ActivityWatch bridge if running locally
        if self._activitywatch_available():
            report.sources_scanned += 1
            cp = checkpoints.get(self.name, f"aw:{self.activitywatch_url}")
            since_ms = int(((cp or {}).get("cursor") or {}).get("last_ts_ms") or 0)
            try:
                aw_samples = fetch_activitywatch_window_samples(
                    base_url=self.activitywatch_url,
                    since_ms=since_ms,
                )
                samples.extend(aw_samples)
                if aw_samples:
                    max_ts = max(s.t_end for s in aw_samples)
                    checkpoints.put(
                        self.name,
                        f"aw:{self.activitywatch_url}",
                        cursor={"last_ts_ms": max_ts},
                    )
                    report.watermark = str(max_ts)
            except (OSError, urllib.error.URLError, ValueError) as exc:
                report.skipped_errors += 1
                report.errors.append(f"activitywatch: {exc}")

        # 2. Optional JSONL sample spool or single native macOS point sample
        if self._sample_log_path and self._sample_log_path.is_file():
            report.sources_scanned += 1
            for line in self._sample_log_path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                    samples.append(
                        WindowSample(
                            app_name=str(obj["app_name"]),
                            app_bundle=str(obj.get("app_bundle") or ""),
                            window_title=str(obj.get("window_title") or ""),
                            t_start=int(obj["t_start"]),
                            t_end=int(obj.get("t_end") or obj["t_start"]),
                            idle_seconds=float(obj.get("idle_seconds") or 0.0),
                            source_kind=str(obj.get("source_kind") or "macos_native"),
                        )
                    )
                except (ValueError, KeyError):
                    report.skipped_errors += 1
        elif not samples and platform.system() == "Darwin":
            report.sources_scanned += 1
            cur = self._native_sampler()
            if cur is not None and cur.idle_seconds <= self.max_idle_seconds:
                cp = checkpoints.get(self.name, "macos_native:active")
                prev = ((cp or {}).get("cursor") or {}).get("open_session")
                if (
                    isinstance(prev, dict)
                    and prev.get("app_name") == cur.app_name
                    and prev.get("window_title") == cur.window_title
                    and cur.t_start - int(prev.get("t_end") or 0) <= 90_000
                ):
                    prev["t_end"] = cur.t_end
                    checkpoints.put(self.name, "macos_native:active", cursor={"open_session": prev})
                else:
                    if isinstance(prev, dict):
                        samples.append(
                            WindowSample(
                                app_name=str(prev["app_name"]),
                                app_bundle=str(prev.get("app_bundle") or ""),
                                window_title=str(prev.get("window_title") or ""),
                                t_start=int(prev["t_start"]),
                                t_end=int(prev["t_end"]),
                                source_kind="macos_native",
                            )
                        )
                    checkpoints.put(
                        self.name,
                        "macos_native:active",
                        cursor={
                            "open_session": {
                                "app_name": cur.app_name,
                                "app_bundle": cur.app_bundle,
                                "window_title": cur.window_title,
                                "t_start": cur.t_start,
                                "t_end": cur.t_end,
                            }
                        },
                    )

        coalesced = coalesce_window_samples(samples, min_dwell_ms=self.min_dwell_ms)
        if coalesced:
            events = [sample_to_raw_event(s) for s in coalesced]
            res = sink.emit_batch(self.name, events)
            report.events_emitted = len(events)
            report.created = res.get("created", 0)
            report.existing = res.get("existing", 0)
            report.spooled = res.get("spooled", 0)
            report.watermark = str(max(s.t_end for s in coalesced))
        elif report.sources_scanned == 0:
            report.status = "unconfigured"
            report.message = "Neither ActivityWatch nor native macOS window sampler is available"
        return report
