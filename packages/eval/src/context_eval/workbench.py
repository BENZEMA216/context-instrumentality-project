"""Interactive Human-in-the-Loop Memory Testing & Debugging Workbench (`raw-memory-eval workbench`).

Starts a localhost-only FastAPI debug studio allowing the user to directly inspect, test,
and adjudicate Raw Memory:
  1. Project Profiles: static entity registry (official product name, repos, domains,
     live status pointers, repo-local tech notes) cleanly separated from personal memories.
  2. Compression Fidelity, Exchange-Pair Provenance & Human Adjudication: inspect compressed
     Decisions/Memories side-by-side with full Q&A Exchange Context Windows (`±1` turns),
     unsupported-claim highlights, and Anti-Noise flags.
  3. Omitted High-Signal Turn Review: inspect user turns dropped during compression (with Q&A
     context) and mark `must_capture` vs `safe_to_skip`.
  4. Live Retrieval & Context Pack Debugger: run arbitrary natural-language queries against
     the real `HubStore`, inspect exactly what an Agent sees (Project Profiles, Active Decisions,
     Memories, Episodes, Direct Raw Matches, Suppressed Superseded items, token cost, latency),
     and save rated queries into a personal regression test suite (`human_queries.jsonl`).
  5. Public Benchmark Scorecard & Failure Case Explorer: browse LoCoMo / LongMemEval results
     and inspect failure samples.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, Literal

from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from context_hub.models import now_ms
from context_hub.store import HubStore
from context_hub.tokenizer import fts_match_query

from .fidelity import inspect_compression_fidelity
from .workbench_channels_vault import build_channels_and_vault_router

VerdictType = Literal[
    "accurate",
    "over_extrapolated",
    "incomplete_citation",
    "wrong_supersession",
    "noise",
    "must_capture",
    "safe_to_skip",
]
QueryRating = Literal["good", "missed_info", "stale_leak", "noisy"]


class AdjudicationIn(BaseModel):
    target_kind: Literal["decision", "memory", "omitted_turn"]
    target_id: str
    verdict: VerdictType
    note: str = ""
    project: str | None = None
    snapshot_summary: str = ""


class DebugQueryIn(BaseModel):
    query: str
    project: str | None = None
    max_tokens: int = Field(default=2500, ge=400, le=12000)
    limit: int = Field(default=10, ge=1, le=30)


class QueryFeedbackIn(BaseModel):
    query: str
    project: str | None = None
    rating: QueryRating
    expected_note: str = ""
    returned_decision_ids: list[str] = Field(default_factory=list)
    returned_memory_ids: list[str] = Field(default_factory=list)
    returned_raw_ids: list[str] = Field(default_factory=list)
    latency_ms: float = 0.0
    approx_tokens: int = 0


def _eval_dir(data_dir: Path) -> Path:
    d = Path(data_dir).expanduser() / "eval"
    d.mkdir(parents=True, exist_ok=True)
    return d


def load_adjudications(data_dir: Path) -> dict[str, dict[str, Any]]:
    """Load latest human adjudication per `(target_kind, target_id)` from JSONL."""
    path = _eval_dir(data_dir) / "human_adjudications.jsonl"
    latest: dict[str, dict[str, Any]] = {}
    if not path.is_file():
        return latest
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        key = f"{obj.get('target_kind')}:{obj.get('target_id')}"
        latest[key] = obj
    return latest


def append_adjudication(data_dir: Path, payload: AdjudicationIn) -> dict[str, Any]:
    path = _eval_dir(data_dir) / "human_adjudications.jsonl"
    record = {
        **payload.model_dump(),
        "recorded_at_ms": now_ms(),
    }
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    return record


def load_query_feedback(data_dir: Path) -> list[dict[str, Any]]:
    path = _eval_dir(data_dir) / "human_queries.jsonl"
    rows: list[dict[str, Any]] = []
    if not path.is_file():
        return rows
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return list(reversed(rows))


def append_query_feedback(data_dir: Path, payload: QueryFeedbackIn) -> dict[str, Any]:
    path = _eval_dir(data_dir) / "human_queries.jsonl"
    record = {
        **payload.model_dump(),
        "recorded_at_ms": now_ms(),
    }
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    return record


def summarize_adjudications(data_dir: Path) -> dict[str, Any]:
    latest = load_adjudications(data_dir)
    counts: dict[str, int] = {}
    open_fixes: list[dict[str, Any]] = []
    for rec in latest.values():
        v = str(rec.get("verdict") or "unknown")
        counts[v] = counts.get(v, 0) + 1
        if v in {
            "over_extrapolated",
            "incomplete_citation",
            "wrong_supersession",
            "noise",
            "must_capture",
        }:
            open_fixes.append(rec)
    queries = load_query_feedback(data_dir)
    q_counts: dict[str, int] = {}
    for q in queries:
        r = str(q.get("rating") or "unknown")
        q_counts[r] = q_counts.get(r, 0) + 1
    return {
        "total_adjudicated": len(latest),
        "verdict_counts": counts,
        "open_fix_count": len(open_fixes),
        "open_fixes": open_fixes,
        "latest_by_key": latest,
        "query_feedback_count": len(queries),
        "query_rating_counts": q_counts,
        "recent_queries": queries[:30],
    }


def _discover_benchmark_results(results_dir: Path | None) -> list[dict[str, Any]]:
    candidates: list[Path] = []
    if results_dir and results_dir.is_dir():
        candidates.append(results_dir)
    here = Path(__file__).resolve()
    for parent in here.parents:
        cand = parent / "benchmarks" / "results"
        if cand.is_dir() and cand not in candidates:
            candidates.append(cand)
            break

    reports: list[dict[str, Any]] = []
    seen_files: set[str] = set()
    for folder in candidates:
        for jp in sorted(folder.glob("*.json")):
            if jp.name in seen_files:
                continue
            seen_files.add(jp.name)
            try:
                data = json.loads(jp.read_text(encoding="utf-8"))
                data["_filename"] = jp.name
                reports.append(data)
            except Exception:
                continue
    return reports


def create_workbench_app(
    data_dir: Path,
    *,
    results_dir: Path | None = None,
) -> FastAPI:
    """Create the localhost-only Raw Memory Human-in-the-Loop Debug Workbench FastAPI app."""
    root = Path(data_dir).expanduser()
    store = HubStore(root)

    app = FastAPI(title="Raw Memory — Human-in-the-Loop Debug Workbench")
    app.include_router(build_channels_and_vault_router(root, store))

    @app.get("/", response_class=HTMLResponse)
    def index() -> HTMLResponse:
        return HTMLResponse(_WORKBENCH_HTML)

    @app.get("/api/debug/overview")
    def debug_overview(project: str | None = None) -> dict[str, Any]:
        fidelity = inspect_compression_fidelity(root, include_quotes=True, project=project)
        adjudications = summarize_adjudications(root)
        projects = store.list_projects(agent=True)
        profiles = store.list_project_profiles()
        if project:
            profiles = [p for p in profiles if p["project"] == project]
        return {
            "data_dir": str(root),
            "projects": projects,
            "project_profiles": profiles,
            "fidelity": fidelity.model_dump(),
            "adjudications": adjudications,
        }

    @app.post("/api/debug/adjudicate")
    def post_adjudicate(body: AdjudicationIn) -> dict[str, Any]:
        saved = append_adjudication(root, body)
        return {"saved": saved, "summary": summarize_adjudications(root)}

    @app.get("/api/debug/adjudications")
    def get_adjudications() -> dict[str, Any]:
        return summarize_adjudications(root)

    @app.post("/api/debug/query")
    def post_debug_query(body: DebugQueryIn) -> dict[str, Any]:
        q = body.query.strip()
        t0 = time.perf_counter()
        pack = store.get_context_pack(
            query=q,
            project=body.project or None,
            max_tokens=body.max_tokens,
            agent=True,
        )
        raw_search = store.search_context(
            q,
            project=body.project or None,
            limit=body.limit,
            agent=True,
            max_tokens=body.max_tokens,
        )
        latency_ms = round((time.perf_counter() - t0) * 1000.0, 2)
        superseded = [
            d for d in (raw_search.get("decisions") or []) if d.get("status") != "active"
        ]
        return {
            "query": q,
            "project": body.project or None,
            "fts_expression": fts_match_query(q),
            "latency_ms": latency_ms,
            "pack": pack,
            "superseded_filtered_out": superseded,
            "raw_search_hits": raw_search.get("raw_matches") or [],
        }

    @app.post("/api/debug/query-feedback")
    def post_query_feedback(body: QueryFeedbackIn) -> dict[str, Any]:
        saved = append_query_feedback(root, body)
        return {"saved": saved, "summary": summarize_adjudications(root)}

    @app.get("/api/debug/benchmarks")
    def get_benchmarks() -> dict[str, Any]:
        return {"reports": _discover_benchmark_results(results_dir)}

    return app


_WORKBENCH_HTML = r"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<meta name="color-scheme" content="light dark" />
<title>Raw Memory</title>
<style>
  /* Raw Memory — quiet native-macOS surface inspired by yetone/magpie:
     one calm canvas, crisp hairline-grouped cards, real vector marks, pop-up pill controls. */
  :root {
    color-scheme: light dark;
    --bg: #f4f4f6;
    --card: #ffffff;
    --card-2: #f9f9fb;
    --pill: #f1f1f4;
    --pill-hover: #e7e7ec;
    --seg-track: #e6e6eb;
    --seg-thumb: #ffffff;
    --seg-edge: 0 1px 2px rgba(0, 0, 0, .12), 0 0 0 .5px rgba(0, 0, 0, .07);
    --line: #e3e3e8;
    --line-2: #ececf0;
    --fg: #1c1c21;
    --fg-2: #4b4b53;
    --ctl-fg: #63636b;
    --muted: #85858d;
    --faint: #b4b4be;
    --accent: #4f46e5;
    --accent-soft: #eeedfd;
    --accent-fg: #ffffff;
    --green: #189a58;
    --green-soft: #e4f6ec;
    --amber: #b45309;
    --amber-soft: #fbf0df;
    --red: #d64545;
    --red-soft: #fbe9e9;
    --switch-on: #1c1c21;
    --switch-off: #d4d4dc;
    --switch-knob: #ffffff;
    --shadow: 0 12px 32px rgba(20, 22, 30, .12), 0 1px 4px rgba(20, 22, 30, .06);
    --font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Segoe UI", system-ui, sans-serif;
    --code: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
    --ease: cubic-bezier(.22, 1, .36, 1);
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --bg: #1a1a1e;
      --card: #232327;
      --card-2: #1f1f23;
      --pill: #2d2d33;
      --pill-hover: #36363d;
      --seg-track: rgba(255, 255, 255, .04);
      --seg-thumb: rgba(255, 255, 255, .14);
      --seg-edge: inset 0 .5px 0 rgba(255, 255, 255, .08), 0 1px 2px rgba(0, 0, 0, .3);
      --line: #333339;
      --line-2: #2c2c32;
      --fg: #ededf1;
      --fg-2: #b9b9c1;
      --ctl-fg: #a1a1aa;
      --muted: #9c9ca6;
      --faint: #6c6c76;
      --accent: #a5b4fc;
      --accent-soft: #2b2c47;
      --accent-fg: #14142a;
      --green: #6fd99b;
      --green-soft: #1e3a2b;
      --amber: #f2b544;
      --amber-soft: #3f3220;
      --red: #f28b82;
      --red-soft: #45272a;
      --switch-on: #ededf1;
      --switch-off: #3c3c44;
      --switch-knob: #1a1a1e;
      --shadow: 0 16px 40px rgba(0, 0, 0, .48), 0 2px 8px rgba(0, 0, 0, .28);
    }
  }
  :root[data-theme="dark"] {
    color-scheme: dark;
    --bg: #1a1a1e; --card: #232327; --card-2: #1f1f23; --pill: #2d2d33; --pill-hover: #36363d;
    --seg-track: rgba(255, 255, 255, .04); --seg-thumb: rgba(255, 255, 255, .14);
    --seg-edge: inset 0 .5px 0 rgba(255, 255, 255, .08), 0 1px 2px rgba(0, 0, 0, .3);
    --line: #333339; --line-2: #2c2c32; --fg: #ededf1; --fg-2: #b9b9c1; --ctl-fg: #a1a1aa;
    --muted: #9c9ca6; --faint: #6c6c76; --accent: #a5b4fc; --accent-soft: #2b2c47; --accent-fg: #14142a;
    --green: #6fd99b; --green-soft: #1e3a2b; --amber: #f2b544; --amber-soft: #3f3220; --red: #f28b82; --red-soft: #45272a;
    --switch-on: #ededf1; --switch-off: #3c3c44; --switch-knob: #1a1a1e;
    --shadow: 0 16px 40px rgba(0, 0, 0, .48), 0 2px 8px rgba(0, 0, 0, .28);
  }
  :root[data-theme="light"] { color-scheme: light only; }

  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { min-height: 100%; }
  body {
    font: 13px/1.48 var(--font);
    background: var(--bg);
    color: var(--fg);
    -webkit-font-smoothing: antialiased;
    padding-bottom: 56px;
  }
  button, input, select, textarea { font: inherit; color: inherit; }
  button { background: none; border: 0; cursor: pointer; -webkit-appearance: none; appearance: none; }
  button:focus:not(:focus-visible) { outline: none; }
  button:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
  code { font-family: var(--code); font-size: 11.5px; }
  .mono { font-family: var(--code); font-variant-numeric: tabular-nums; }

  /* ---- Top bar (Magpie frameless centered segmented nav) ---- */
  .topbar {
    position: sticky; top: 0; z-index: 20;
    height: 52px;
    background: color-mix(in srgb, var(--bg) 88%, transparent);
    -webkit-backdrop-filter: saturate(1.4) blur(14px);
    backdrop-filter: saturate(1.4) blur(14px);
  }
  .topbar-inner {
    max-width: 980px; margin: 0 auto; height: 100%; padding: 0 18px;
    display: flex; align-items: center; justify-content: space-between; position: relative;
  }
  .brand {
    display: inline-flex; align-items: center; gap: 8px;
    font-size: 13.5px; font-weight: 600; letter-spacing: -.01em; color: var(--fg);
    user-select: none;
  }
  .brand-mark { width: 20px; height: 20px; display: inline-flex; align-items: center; justify-content: center; color: var(--fg); }
  .seg-nav {
    position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%);
    display: inline-flex; align-items: center; gap: 2px; padding: 2px; border-radius: 8px;
  }
  .seg-nav button {
    height: 26px; padding: 0 12px; border-radius: 6px;
    font-size: 12.5px; font-weight: 500; color: var(--ctl-fg); white-space: nowrap;
    transition: color .14s var(--ease), background-color .14s var(--ease), box-shadow .14s var(--ease);
  }
  .seg-nav button:hover:not(.on) { color: var(--fg); }
  .seg-nav button.on {
    background: var(--seg-thumb); color: var(--fg); box-shadow: var(--seg-edge);
  }
  .top-actions { display: flex; align-items: center; gap: 4px; }
  .icon-btn {
    width: 28px; height: 28px; border-radius: 7px;
    display: inline-flex; align-items: center; justify-content: center;
    color: var(--muted); transition: background-color .12s, color .12s;
  }
  .icon-btn:hover { background: var(--pill); color: var(--fg); }
  .icon-btn.spin svg { animation: spin .75s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* ---- Centered Page Frame ---- */
  .page { max-width: 980px; margin: 0 auto; padding: 4px 18px 24px; }
  .view { animation: view-in .18s var(--ease); }
  .view.hidden { display: none; }
  @keyframes view-in { from { opacity: 0; transform: translateY(4px); } }

  .lead {
    font-size: 12.5px; color: var(--fg-2); margin: 2px 2px 14px;
    display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap;
  }
  .lead strong { font-weight: 600; color: var(--fg); }

  /* ---- Magpie Grouped List & Rows ---- */
  .list {
    background: var(--card); border: 1px solid var(--line); border-radius: 12px;
    overflow: hidden; margin-bottom: 14px;
  }
  .list-pad { padding: 14px 16px; }
  .row {
    display: flex; align-items: center; gap: 12px; min-height: 54px;
    padding: 9px 14px; transition: background-color .12s;
  }
  .row + .row, .row-sep { border-top: 1px solid var(--line-2); }
  .row-ic {
    width: 28px; height: 28px; border-radius: 7px; flex: none;
    display: inline-flex; align-items: center; justify-content: center;
    background: var(--pill); color: var(--fg-2);
  }
  .row-ic.ok { background: var(--green-soft); color: var(--green); }
  .row-ic.accent { background: var(--accent-soft); color: var(--accent); }
  .row-ic.amber { background: var(--amber-soft); color: var(--amber); }
  .row-who { min-width: 0; flex: 1 1 auto; }
  .row-title {
    font-size: 13.5px; font-weight: 560; letter-spacing: -.01em; color: var(--fg);
    display: flex; align-items: center; gap: 7px; flex-wrap: wrap;
  }
  .row-sub {
    font-size: 11.5px; color: var(--muted); margin-top: 2px;
    display: flex; align-items: center; gap: 6px; flex-wrap: nowrap; min-width: 0;
  }
  .row-sub.wrap { flex-wrap: wrap; }
  .row-sub > .sub-txt { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  /* ---- Lightbox Modal for Encrypted Vault Image/PDF Preview ---- */
  .modal-bg {
    position: fixed; inset: 0; z-index: 80;
    background: rgba(15, 15, 20, .66);
    -webkit-backdrop-filter: blur(8px); backdrop-filter: blur(8px);
    display: flex; align-items: center; justify-content: center; padding: 24px;
  }
  .modal-bg.hidden { display: none; }
  .modal-box {
    background: var(--card); border: 1px solid var(--line); border-radius: 14px;
    box-shadow: var(--shadow); max-width: min(920px, 94vw); max-height: 90vh;
    width: auto; display: flex; flex-direction: column; overflow: hidden;
  }
  .modal-head {
    display: flex; align-items: center; justify-content: space-between; gap: 12px;
    padding: 10px 14px; border-bottom: 1px solid var(--line-2);
  }
  .modal-body { padding: 14px; overflow: auto; display: flex; align-items: center; justify-content: center; background: var(--card-2); }
  .modal-body img { max-width: 100%; max-height: 76vh; border-radius: 8px; display: block; }
  .modal-body iframe { width: min(820px, 86vw); height: 74vh; border: 0; border-radius: 8px; background: #fff; }
  .dot { width: 6px; height: 6px; border-radius: 50%; display: inline-block; flex: none; background: var(--faint); }
  .dot.ok { background: var(--green); }
  .dot.amber { background: var(--amber); }
  .dot.bad { background: var(--red); }
  .dot.accent { background: var(--accent); }

  .row-right { display: flex; align-items: center; gap: 10px; flex: none; }
  .meta-link {
    font-size: 12px; color: var(--ctl-fg); font-variant-numeric: tabular-nums;
    display: inline-flex; align-items: center; gap: 3px; white-space: nowrap;
  }
  .meta-link .chev { color: var(--faint); font-size: 13px; }

  /* ---- Pop-up Pill Controls & Buttons ---- */
  .pill {
    display: inline-flex; align-items: center; gap: 6px;
    height: 28px; padding: 0 11px; border-radius: 7px;
    background: var(--pill); color: var(--fg); font-size: 12px; font-weight: 500;
    border: 1px solid transparent; white-space: nowrap;
    transition: background-color .12s, border-color .12s, transform .1s;
  }
  .pill:hover { background: var(--pill-hover); }
  .pill:active { transform: scale(.98); }
  .pill.sm { height: 24px; padding: 0 9px; font-size: 11.5px; border-radius: 6px; }
  .pill.primary { background: var(--fg); color: var(--card); }
  .pill.primary:hover { opacity: .9; background: var(--fg); }
  .pill.accent { background: var(--accent-soft); color: var(--accent); }
  .pill.accent:hover { background: color-mix(in srgb, var(--accent) 18%, var(--accent-soft)); }
  .pill.selected { background: var(--accent-soft); color: var(--accent); border-color: color-mix(in srgb, var(--accent) 40%, transparent); }
  .pill.outline { background: var(--card); border-color: var(--line); color: var(--fg-2); }
  .pill.outline:hover { background: var(--pill); color: var(--fg); }
  .pill.danger { color: var(--red); }
  .pill.danger:hover { background: var(--red-soft); }

  /* Subtle status chip */
  .chip {
    display: inline-flex; align-items: center; gap: 5px;
    height: 21px; padding: 0 8px; border-radius: 999px;
    font-size: 11px; font-weight: 500; background: var(--pill); color: var(--fg-2);
    white-space: nowrap;
  }
  .chip.ok { background: var(--green-soft); color: var(--green); }
  .chip.amber { background: var(--amber-soft); color: var(--amber); }
  .chip.bad { background: var(--red-soft); color: var(--red); }
  .chip.accent { background: var(--accent-soft); color: var(--accent); }
  .chip.mono { font-family: var(--code); }

  /* ---- Monochrome macOS Toggle Switch (exact Magpie agents-light aesthetic) ---- */
  .switch {
    position: relative; width: 34px; height: 20px; border-radius: 999px;
    background: var(--switch-off); transition: background-color .18s var(--ease);
    flex: none; padding: 0; border: 0;
  }
  .switch::after {
    content: ""; position: absolute; top: 2px; left: 2px; width: 16px; height: 16px;
    border-radius: 50%; background: var(--switch-knob);
    box-shadow: 0 1px 2px rgba(0,0,0,.2);
    transition: transform .18s var(--ease);
  }
  .switch.on { background: var(--switch-on); }
  .switch.on::after { transform: translateX(14px); }
  .switch:disabled { opacity: .45; cursor: not-allowed; }

  /* ---- Collapsible "Show more" Row ---- */
  .fold-btn {
    width: 100%; border-top: 1px solid var(--line-2); padding: 10px;
    display: flex; align-items: center; justify-content: center; gap: 5px;
    font-size: 12px; color: var(--muted); transition: color .14s, background-color .14s;
  }
  .fold-btn:hover { color: var(--fg); background: var(--card-2); }
  .fold-panel.hidden { display: none; }
  .fold-panel > .row:first-child { border-top: 1px solid var(--line-2); }

  /* ---- Section Label & Sub-segmented Switch ---- */
  .sec-head {
    display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap;
    margin: 18px 2px 8px;
  }
  .sec-title {
    font-size: 11.5px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--muted);
  }
  .sub-seg {
    display: inline-flex; align-items: center; gap: 2px; padding: 2px;
    border-radius: 8px; background: var(--seg-track);
  }
  .sub-seg button {
    height: 24px; padding: 0 11px; border-radius: 6px; font-size: 12px; font-weight: 500; color: var(--ctl-fg);
    transition: color .12s, background-color .12s;
  }
  .sub-seg button:hover:not(.on) { color: var(--fg); }
  .sub-seg button.on { background: var(--seg-thumb); color: var(--fg); box-shadow: var(--seg-edge); }

  /* ---- Magpie Usage-Style Unified Stat Strip ---- */
  .stat-strip {
    display: grid; grid-template-columns: repeat(4, minmax(0, 1fr));
    background: var(--card); border: 1px solid var(--line); border-radius: 12px;
    overflow: hidden; margin-bottom: 14px;
  }
  .stat-cell { padding: 14px 16px; min-width: 0; }
  .stat-cell + .stat-cell { border-left: 1px solid var(--line-2); }
  .stat-num { font-size: 22px; font-weight: 650; letter-spacing: -.03em; font-variant-numeric: tabular-nums; line-height: 1.15; }
  .stat-lbl { font-size: 10.5px; font-weight: 600; letter-spacing: .05em; text-transform: uppercase; color: var(--muted); margin-top: 4px; }
  .stat-sub { font-size: 11.5px; color: var(--ctl-fg); margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

  /* ---- Inputs, Selects, Textareas ---- */
  input[type=text], input[type=password], select, textarea {
    background: var(--card); color: var(--fg); border: 1px solid var(--line);
    border-radius: 7px; padding: 6px 10px; font-size: 12.5px; outline: none;
    transition: border-color .12s, box-shadow .12s;
  }
  input[type=text]:focus, input[type=password]:focus, select:focus, textarea:focus {
    border-color: var(--accent); box-shadow: 0 0 0 2.5px var(--accent-soft);
  }
  select.pill-sel {
    height: 28px; padding: 0 24px 0 10px; background: var(--pill); border: 1px solid var(--line);
    font-size: 12px; font-weight: 500; cursor: pointer; line-height: 1;
  }
  select.pill-sel:hover { background: var(--pill-hover); }

  /* ---- Detail Panes & Exchange Pairs ---- */
  .split { display: grid; grid-template-columns: 1fr 1.15fr; gap: 12px; }
  .pane {
    background: var(--card-2); border: 1px solid var(--line-2); border-radius: 9px;
    padding: 11px 12px; font-size: 12.5px;
  }
  .pane-h {
    font-size: 10.5px; font-weight: 600; letter-spacing: .05em; text-transform: uppercase;
    color: var(--muted); margin-bottom: 7px;
  }
  .exchange {
    border: 1px solid var(--line-2); border-radius: 8px; padding: 6px 8px;
    margin-bottom: 8px; background: var(--card);
  }
  .turn { border-left: 2.5px solid var(--line); padding: 4px 9px; margin: 4px 0; font-size: 12px; color: var(--muted); }
  .turn.cited {
    border-left-color: var(--accent); background: var(--accent-soft); color: var(--fg);
    border-radius: 0 6px 6px 0;
  }
  .turn-meta { font-family: var(--code); font-size: 10.5px; color: var(--muted); margin-bottom: 2px; }
  .pill-row { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 8px; }
  .act-bar {
    display: flex; flex-wrap: wrap; gap: 6px; align-items: center;
    margin-top: 12px; padding-top: 10px; border-top: 1px solid var(--line-2);
  }
  .note-in { flex: 1; min-width: 200px; height: 28px; }

  pre.code-out {
    background: var(--card-2); border: 1px solid var(--line-2); border-radius: 9px;
    padding: 12px 14px; overflow-x: auto; font-family: var(--code); font-size: 11.5px;
    line-height: 1.55; white-space: pre-wrap; word-break: break-word; color: var(--fg-2);
  }

  /* ---- Tables inside Cards ---- */
  table.clean { width: 100%; border-collapse: collapse; font-size: 12.5px; }
  table.clean th, table.clean td { padding: 8px 12px; text-align: left; border-top: 1px solid var(--line-2); vertical-align: top; }
  table.clean thead th { border-top: 0; font-size: 11px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; background: var(--card-2); }

  /* ---- Magpie Bottom Scope Bar (like PROFILES Budget · Focus) ---- */
  .scope-bar {
    max-width: 980px; margin: 4px auto 0; padding: 10px 20px 0;
    display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap;
  }
  .scope-left { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .scope-lbl { font-size: 11px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; color: var(--muted); }
  .scope-pill {
    display: inline-flex; align-items: center; gap: 6px;
    height: 28px; padding: 0 12px; border-radius: 999px;
    background: var(--card); border: 1px solid var(--line); color: var(--fg-2);
    font-size: 12px; font-weight: 500; transition: border-color .12s, color .12s, background-color .12s;
  }
  .scope-pill:hover { border-color: var(--faint); color: var(--fg); }
  .scope-pill.on { border-color: var(--fg); color: var(--fg); }
  .scope-pill .pdot { width: 5px; height: 5px; border-radius: 50%; background: var(--accent); opacity: .75; }
  .scope-right { font-size: 12px; color: var(--muted); font-variant-numeric: tabular-nums; }

  /* ---- Quiet Floating Toast (replaces browser alert) ---- */
  .toast {
    position: fixed; left: 50%; bottom: 20px; transform: translateX(-50%) translateY(10px);
    background: var(--fg); color: var(--card);
    padding: 7px 14px; border-radius: 999px; font-size: 12px; font-weight: 500;
    box-shadow: var(--shadow); opacity: 0; pointer-events: none; z-index: 60;
    transition: opacity .18s var(--ease), transform .18s var(--ease);
    max-width: min(560px, calc(100vw - 32px)); text-align: center;
  }
  .toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }

  /* ---- Vault Form Grid & Profile Cards ---- */
  .grid-2 { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
  .prof-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(290px, 1fr)); gap: 12px; }
  .prof-card {
    background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 15px 16px;
  }
  ul.pts { margin: 6px 0 0 16px; font-size: 12.5px; color: var(--fg-2); }
  ul.pts li { margin: 4px 0; }
  .empty { padding: 34px 20px; text-align: center; color: var(--muted); font-size: 12.5px; }
  .empty strong { display: block; color: var(--fg); font-weight: 560; margin-bottom: 4px; }

  @media (max-width: 780px) {
    .seg-nav { position: static; transform: none; overflow-x: auto; max-width: 100%; }
    .topbar { height: auto; padding: 6px 0; }
    .topbar-inner { flex-wrap: wrap; gap: 6px; }
    .stat-strip { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .stat-cell:nth-child(3) { border-left: 0; border-top: 1px solid var(--line-2); }
    .stat-cell:nth-child(4) { border-top: 1px solid var(--line-2); }
    .split, .grid-2 { grid-template-columns: 1fr; }
    .row { flex-wrap: wrap; }
    .row-right { width: 100%; justify-content: flex-end; }
  }
</style>
</head>
<body>

<header class="topbar">
  <div class="topbar-inner">
    <div class="brand" title="Raw Memory · Every agent's context, one place.">
      <span class="brand-mark" aria-hidden="true">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M12 3L3 8l9 5 9-5-9-5z"/>
          <path d="M3 13l9 5 9-5"/>
          <path d="M3 18l9 5 9-5" opacity=".45"/>
        </svg>
      </span>
      <span>raw memory</span>
    </div>

    <nav class="seg-nav" id="mainNav" role="tablist">
      <button class="on" data-tab="channels" onclick="switchTab('channels')">通道</button>
      <button data-tab="vault" onclick="switchTab('vault')">资料库</button>
      <button data-tab="memory" onclick="switchTab('memory')">记忆</button>
      <button data-tab="profiles" onclick="switchTab('profiles')">档案</button>
      <button data-tab="query" onclick="switchTab('query')">检索</button>
      <button data-tab="benchmarks" onclick="switchTab('benchmarks')">评测</button>
    </nav>

    <div class="top-actions">
      <button class="icon-btn" id="themeBtn" onclick="cycleTheme()" title="切换浅色 / 深色主题">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41"/></svg>
      </button>
      <button class="icon-btn" id="refreshBtn" onclick="reloadAll(true)" title="刷新状态">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg>
      </button>
    </div>
  </div>
</header>

<main class="page">
  <section id="tab-channels" class="view"></section>
  <section id="tab-vault" class="view hidden"></section>
  <section id="tab-memory" class="view hidden"></section>
  <section id="tab-profiles" class="view hidden"></section>
  <section id="tab-query" class="view hidden"></section>
  <section id="tab-benchmarks" class="view hidden"></section>
</main>

<footer class="scope-bar" id="scopeBar"></footer>
<div class="toast" id="toast"></div>
<div class="modal-bg hidden" id="previewModal" onclick="if(event.target===this) closePreviewModal()">
  <div class="modal-box">
    <div class="modal-head">
      <strong id="previewTitle" style="font-size:13px;">加密附件预览</strong>
      <div style="display:flex;gap:6px;align-items:center;">
        <a id="previewOpenLink" href="#" target="_blank" class="pill sm outline" style="text-decoration:none;">新标签打开</a>
        <button class="pill sm" onclick="closePreviewModal()">关闭</button>
      </div>
    </div>
    <div class="modal-body" id="previewBody"></div>
  </div>
</div>

<script>
const STATE = {
  tab: "channels",
  memSub: "fidelity",
  project: "",
  showPlannedChannels: false,
  showVaultForm: false,
  overview: null,
  benchmarks: null,
  channels: null,
  vault: null,
  vaultSubject: "self",
  vaultMasked: true,
  lastQuery: null,
  queryDraft: "",
  theme: localStorage.getItem("rm_theme") || "system",
};

function applyTheme() {
  const root = document.documentElement;
  if (STATE.theme === "light" || STATE.theme === "dark") {
    root.setAttribute("data-theme", STATE.theme);
  } else {
    root.removeAttribute("data-theme");
  }
  const btn = document.getElementById("themeBtn");
  if (!btn) return;
  const isDark = STATE.theme === "dark" || (STATE.theme === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches);
  btn.title = `主题: ${STATE.theme}（点击切换）`;
  btn.innerHTML = isDark
    ? `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>`
    : `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41"/></svg>`;
}

function cycleTheme() {
  const isDark = STATE.theme === "dark" || (STATE.theme === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches);
  STATE.theme = isDark ? "light" : "dark";
  localStorage.setItem("rm_theme", STATE.theme);
  applyTheme();
  showToast(STATE.theme === "dark" ? "已切换深色模式" : "已切换浅色模式");
}

let _toastTimer = null;
function showToast(msg) {
  const el = document.getElementById("toast");
  if (!el) return;
  el.textContent = msg;
  el.classList.add("show");
  clearTimeout(_toastTimer);
  _toastTimer = setTimeout(() => el.classList.remove("show"), 2600);
}

function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
}
function pct(v) { return (Number(v || 0) * 100).toFixed(1) + "%"; }
function fmtNum(n) { return Number(n || 0).toLocaleString("en-US"); }

function channelIconSvg(source) {
  const map = {
    ai_chat: `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>`,
    clipboard: `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="8" y="2" width="8" height="4" rx="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/></svg>`,
    voice: `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" y1="19" x2="12" y2="22"/></svg>`,
    browser: `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>`,
    wechat: `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M17 10c0-3.3-3.1-6-7-6S3 6.7 3 10c0 1.8.9 3.4 2.4 4.5L4.5 17l2.9-1.2c.8.2 1.7.2 2.6.2"/><path d="M21 15c0-2.5-2.5-4.5-5.5-4.5S10 12.5 10 15s2.5 4.5 5.5 4.5c.7 0 1.4-.1 2-.3L20 20l-.7-2c1-.8 1.7-1.8 1.7-3z"/></svg>`,
    "im.lark": `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M22 2L11 13"/><path d="M22 2l-7 20-4-9-9-4 20-7z"/></svg>`,
    "im.telegram": `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21.5 4.5L2.5 11.5l6.5 2.5L18 7.5l-6.5 8 5.5 4 4.5-15z"/></svg>`,
    window: `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2"/><line x1="3" y1="9" x2="21" y2="9"/></svg>`,
    vault: `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>`,
    "email.local": `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="4" width="20" height="16" rx="2"/><path d="M22 7l-10 6L2 7"/></svg>`,
    "calendar.local": `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="18" rx="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/></svg>`,
    "notes.obsidian": `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>`,
    location: `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z"/><circle cx="12" cy="10" r="3"/></svg>`,
  };
  return map[source] || `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="8"/></svg>`;
}

function privacyLabel(tier) {
  if (tier === "shareable") return "Agent 可见";
  if (tier === "redacted") return "脱敏指针";
  return "仅本机私密";
}

function switchTab(name) {
  STATE.tab = name;
  document.querySelectorAll("#mainNav button").forEach(el => el.classList.toggle("on", el.dataset.tab === name));
  ["channels", "vault", "memory", "profiles", "query", "benchmarks"].forEach(t => {
    document.getElementById("tab-" + t).classList.toggle("hidden", t !== name);
  });
  if (name === "channels") loadChannels();
  if (name === "vault") loadVault();
  if (name === "query") renderQuery();
}

function setProjectScope(proj) {
  STATE.project = proj;
  reloadAll(false);
}

async function reloadAll(announce) {
  const btn = document.getElementById("refreshBtn");
  if (btn) btn.classList.add("spin");
  try {
    const qs = STATE.project ? ("?project=" + encodeURIComponent(STATE.project)) : "";
    const [ov, bm, ch, vt] = await Promise.all([
      fetch("/api/debug/overview" + qs).then(r => r.json()),
      fetch("/api/debug/benchmarks").then(r => r.json()),
      fetch("/api/channels/status").then(r => r.json()),
      fetch("/api/vault/status").then(r => r.json()),
    ]);
    STATE.overview = ov;
    STATE.benchmarks = bm;
    STATE.channels = ch;
    STATE.vault = vt;
    renderChannels();
    renderVault();
    if (vt.unlocked) loadAutofillPreview();
    renderMemory();
    renderProfiles();
    renderQuery();
    renderBenchmarks();
    renderScopeBar();
    if (announce) showToast("已刷新本地状态");
  } finally {
    if (btn) btn.classList.remove("spin");
  }
}

function renderScopeBar() {
  const bar = document.getElementById("scopeBar");
  const ov = STATE.overview || {};
  const chs = (STATE.channels || {}).channels || [];
  const totalEvents = chs.reduce((s, c) => s + ((c.counts || {}).total || 0), 0);
  const projs = (ov.projects || []).filter(p => p.project && p.project !== "unassigned").slice(0, 6);
  const f = ov.fidelity || {};
  const pills = [
    `<button class="scope-pill ${STATE.project === "" ? "on" : ""}" onclick="setProjectScope('')">全部项目</button>`,
    ...projs.map(p => `<button class="scope-pill ${STATE.project === p.project ? "on" : ""}" onclick="setProjectScope('${esc(p.project)}')">${esc(p.project)}<span class="pdot"></span></button>`),
  ].join("");
  bar.innerHTML = `
    <div class="scope-left">
      <span class="scope-lbl">Projects</span>
      ${pills}
    </div>
    <div class="scope-right">${fmtNum(totalEvents)} events · 忠实度 ${pct(f.avg_claim_support_rate)} · 127.0.0.1</div>
  `;
}

// ==================== View 1: Channels (Magpie Agents aesthetic) ====================
async function loadChannels() {
  STATE.channels = await fetch("/api/channels/status").then(r => r.json());
  renderChannels();
  renderScopeBar();
}

function renderChannelRow(c) {
  const counts = c.counts || { total: 0, shareable: 0, local_only: 0 };
  const isActive = c.category === "active" || counts.total > 0;
  const isReady = c.category === "ready";
  const dotCls = isActive ? "ok" : (isReady ? "amber" : "");
  const icCls = isActive ? "ok" : (c.source === "vault" ? "accent" : (isReady ? "amber" : ""));
  const statusText = isActive
    ? `已接入 · ${fmtNum(counts.total)} 条（共享 ${fmtNum(counts.shareable)} / 仅本机 ${fmtNum(counts.local_only)}）`
    : (isReady ? `就绪 · ${c.description}` : `预留通道 · ${c.description}`);

  let actionHtml = `<span class="chip">${esc(privacyLabel(c.default_privacy))}</span>`;
  if (c.source === "vault") {
    const unlocked = (STATE.vault || {}).unlocked;
    actionHtml = `
      <span class="chip ${unlocked ? "ok" : ""}">${unlocked ? "已解锁" : "已锁定"}</span>
      <button class="pill sm" style="min-width:74px;justify-content:center;" onclick="switchTab('vault')">打开资料库</button>
    `;
  } else if (c.collector_name && ["browser", "clipcontext", "window", "chat", "lark_im"].includes(c.collector_name)) {
    actionHtml = `
      <span class="meta-link">${fmtNum(counts.total)} 条 <span class="chev">›</span></span>
      <span class="chip ${c.default_privacy === "local_only" ? "amber" : "ok"}">${esc(privacyLabel(c.default_privacy))}</span>
      <button class="pill sm" style="min-width:74px;justify-content:center;" onclick="triggerChannelSync('${esc(c.collector_name)}', this)">立即同步</button>
    `;
  } else if (c.category === "reserved" || c.category === "planned") {
    actionHtml = `
      <span class="chip ${c.default_privacy === "local_only" ? "amber" : ""}">${esc(privacyLabel(c.default_privacy))}</span>
      <span class="chip" style="min-width:74px;justify-content:center;">已预留</span>
    `;
  } else {
    actionHtml = `
      <span class="meta-link">${fmtNum(counts.total)} 条</span>
      <span class="chip ok">${esc(privacyLabel(c.default_privacy))}</span>
      <span class="chip" style="min-width:74px;justify-content:center;">自动同步</span>
    `;
  }

  return `<div class="row">
    <div class="row-ic ${icCls}">${channelIconSvg(c.source)}</div>
    <div class="row-who">
      <div class="row-title">${esc(c.product_name)} <span class="chip mono">${esc(c.source)}</span></div>
      <div class="row-sub" title="${esc(statusText)}"><span class="dot ${dotCls}"></span><span class="sub-txt">${esc(statusText)}</span></div>
    </div>
    <div class="row-right">${actionHtml}</div>
  </div>`;
}

function renderChannels() {
  const el = document.getElementById("tab-channels");
  const data = STATE.channels;
  if (!data) { el.innerHTML = `<div class="list"><div class="empty">加载通道状态中…</div></div>`; return; }

  const all = data.channels || [];
  const isReserved = c => c.category === "reserved" || c.category === "planned";
  const primary = all.filter(c => !isReserved(c));
  const planned = all.filter(isReserved);

  const allowSet = new Set(((data.chat_allowlist || {}).allow_sessions || []).map(x => String(x)));
  const pmap = (data.chat_allowlist || {}).project_map || {};
  const sessions = data.im_sessions || [];
  const browserDoc = (data.doctors || {}).browser || {};
  const larkDoc = (data.doctors || {}).lark_im || {};

  const imRows = sessions.map(s => {
    const allowed = allowSet.has(s.session_id) || s.privacy_tier !== "local_only";
    const pid = `improj_${s.session_id.replace(/[^a-zA-Z0-9_-]/g, "_")}`;
    return `<div class="row">
      <div class="row-ic ${allowed ? "ok" : "amber"}">${channelIconSvg(s.source === "im.lark" ? "im.lark" : "wechat")}</div>
      <div class="row-who">
        <div class="row-title">${esc(s.session_name)} <span class="chip mono">${esc(s.source)}</span></div>
        <div class="row-sub"><span class="dot ${allowed ? "ok" : "amber"}"></span><span>${allowed ? "已放行给 Agent" : "仅本机私密"} · ${fmtNum(s.message_count)} 条消息 · ${esc(s.session_id)}</span></div>
      </div>
      <div class="row-right">
        <input id="${pid}" type="text" style="width:142px;height:26px;font-size:12px;" value="${esc(pmap[s.session_id] || s.project || "")}" placeholder="归属项目 slug" />
        <button class="switch ${allowed ? "on" : ""}" role="switch" aria-checked="${allowed}" title="${allowed ? "切回仅本机" : "放行给 Agent"}" onclick="toggleChatAllow('${esc(s.session_id)}', ${!allowed}, '${pid}')"></button>
      </div>
    </div>`;
  }).join("");

  el.innerHTML = `
    <div class="lead">
      <span>所有上下文通道统一汇总到本机 <strong>raw memory</strong>；隐私边界按通道独立控制，IM 记录默认全部仅本机。</span>
      <span class="chip">Browser 档案 ${browserDoc.readable_profiles || 0} · 飞书 ${larkDoc.user_ready ? "已授权" : "待授权"}</span>
    </div>

    <div class="list">
      ${primary.map(renderChannelRow).join("")}
      <div class="fold-panel ${STATE.showPlannedChannels ? "" : "hidden"}" id="plannedFold">
        ${planned.map(renderChannelRow).join("")}
      </div>
      <button class="fold-btn" onclick="togglePlannedChannels()">
        <span>${STATE.showPlannedChannels ? "收起预留通道" : `显示其余 ${planned.length} 条已预留通道`}</span>
        <span>${STATE.showPlannedChannels ? "▴" : "▾"}</span>
      </button>
    </div>

    <div class="sec-head">
      <span class="sec-title">IM 聊天记录接入与会话放行（微信 / WeFlow / Telegram / CSV）</span>
      <div style="display:flex;align-items:center;gap:8px;">
        <label class="pill primary" style="cursor:pointer;">
          + 导入聊天导出文件
          <input id="chatFileInput" type="file" accept=".json,.jsonl,.csv" style="display:none;" onchange="uploadChatExport(this)" />
        </label>
      </div>
    </div>

    <div class="list">
      ${imRows || `<div class="empty">
        <strong>暂未导入微信 / IM 会话</strong>
        合规模式：不做微信数据库破解。点击右上角「+ 导入聊天导出文件」上传 WeFlow JSON、Telegram JSON 或 CSV，默认全部以 <code>local_only</code> 入库，再按群逐一拨动开关放行。
      </div>`}
    </div>
  `;
}

function togglePlannedChannels() {
  STATE.showPlannedChannels = !STATE.showPlannedChannels;
  renderChannels();
}

async function triggerChannelSync(collector, btnEl) {
  if (btnEl) { btnEl.disabled = true; btnEl.textContent = "同步中…"; }
  try {
    const res = await fetch("/api/channels/sync", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({ collector, since_days: 14.0 }),
    }).then(r => r.json());
    const rep = res.report || {};
    await loadChannels();
    showToast(`${collector} 同步完成 · 新增 ${rep.created || 0} 条，已有 ${rep.existing || 0} 条`);
  } catch (e) {
    showToast(`同步失败: ${e}`);
    if (btnEl) { btnEl.disabled = false; btnEl.textContent = "立即同步"; }
  }
}

async function uploadChatExport(input) {
  if (!input || !input.files || !input.files.length) return;
  const file = input.files[0];
  showToast(`正在导入 ${file.name}…`);
  const content = await file.text();
  const res = await fetch("/api/channels/chat/upload", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ filename: file.name, content }),
  }).then(r => r.json());
  const rep = res.report || {};
  await loadChannels();
  showToast(`导入完成 · 新增 ${rep.created || 0} 条（默认 local_only）`);
}

async function toggleChatAllow(sessionId, allow, projInputId) {
  const project = document.getElementById(projInputId)?.value?.trim() || null;
  await fetch("/api/channels/chat/allowlist", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ session_id: sessionId, allow, project, tier: "shareable" }),
  });
  await loadChannels();
  showToast(allow ? "已放行该会话给 Agent" : "已切回仅本机私密");
}

// ==================== View 2: Vault (Magpie Masking + Providers aesthetic) ====================
async function loadVault() {
  STATE.vault = await fetch("/api/vault/status").then(r => r.json());
  renderVault();
  if (STATE.vault.unlocked) await loadAutofillPreview();
}

function renderVault() {
  const el = document.getElementById("tab-vault");
  const v = STATE.vault;
  if (!v) { el.innerHTML = `<div class="list"><div class="empty">加载加密资料库中…</div></div>`; return; }

  if (!v.initialized || !v.unlocked) {
    const mode = v.initialized ? "unlock" : "init";
    el.innerHTML = `
      <div class="lead">
        <span>本人与合伙人身份信息、营业执照原件、多手机号/邮箱/住址均逐条 <strong>AES-256-GCM</strong> 加密存放于本机独立 Vault。</span>
      </div>
      <div class="list" style="max-width:460px;margin:28px auto;">
        <div class="list-pad" style="padding:24px 22px;">
          <div style="display:flex;align-items:center;gap:10px;margin-bottom:10px;">
            <div class="row-ic accent">${channelIconSvg("vault")}</div>
            <div>
              <div class="row-title">${v.initialized ? "解锁本地加密资料库" : "初始化 Vault for Agent"}</div>
              <div class="row-sub">口令仅驻留进程内存 · 绝不写入磁盘或 Git</div>
            </div>
          </div>
          <div style="font-size:12px;color:var(--muted);margin-bottom:14px;">
            存储路径：<code>${esc(v.vault_path)}</code>
          </div>
          <div style="display:flex;gap:8px;">
            <input id="vaultPw" type="password" style="flex:1;height:34px;" placeholder="${v.initialized ? "输入主口令解锁" : "设置一个主口令（请妥善牢记）"}" onkeydown="if(event.key==='Enter') vaultAuth('${mode}')" />
            <button class="pill primary" style="height:34px;padding:0 14px;" onclick="vaultAuth('${mode}')">${v.initialized ? "解锁" : "初始化"}</button>
          </div>
          <div id="vaultAuthErr" style="margin-top:8px;font-size:12px;color:var(--red);"></div>
        </div>
      </div>
    `;
    return;
  }

  const subjects = v.subjects || [];
  const subjOpts = Array.from(new Set(["self", ...subjects.map(s => s.subject_id)]));
  if (!subjOpts.includes(STATE.vaultSubject)) STATE.vaultSubject = subjOpts[0];
  const recs = v.records || [];
  const showForm = STATE.showVaultForm || recs.length === 0;

  const recRows = recs.map(r => {
    const atts = (r.attachments || []).map(a => {
      const url = `/api/vault/attachment/${encodeURIComponent(a.id)}`;
      const isImg = String(a.mime_type || "").startsWith("image/");
      const isPdf = String(a.mime_type || "") === "application/pdf";
      const kb = Math.max(1, Math.round(a.byte_size / 1024));
      if (isImg || isPdf) {
        return `<button class="chip accent" style="cursor:pointer;" onclick="openPreviewModal(${esc(JSON.stringify(url))}, ${esc(JSON.stringify(a.filename))}, ${esc(JSON.stringify(a.mime_type))})">${esc(a.filename)} · ${kb}KB</button>`;
      }
      return `<a href="${url}" target="_blank" class="chip accent" style="text-decoration:none;">${esc(a.filename)} · ${kb}KB</a>`;
    }).join("");
    return `<div class="row">
      <div class="row-ic accent">${channelIconSvg("vault")}</div>
      <div class="row-who">
        <div class="row-title">${esc(r.label)} <span class="chip mono">${esc(r.subject_id)}</span> <span class="chip">${esc(r.kind)}</span></div>
        <div class="row-sub wrap">${atts || "暂无加密原件附件（可上传身份证/营业执照扫描件）"}</div>
      </div>
      <div class="row-right">
        <label class="pill sm" style="cursor:pointer;">+ 上传原件<input type="file" style="display:none;" onchange="uploadVaultAtt('${esc(r.id)}', this)" /></label>
        <button class="pill sm danger" onclick="deleteVaultRec('${esc(r.id)}')">删除</button>
      </div>
    </div>`;
  }).join("");

  el.innerHTML = `
    <div class="lead">
      <span>支持同一主体维护多个电话/邮箱/住址，并自动把身份证与营业执照聚合进下方一键填表视图。</span>
      <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;">
        <button class="pill sm outline" onclick="syncVaultReceipts()">同步脱敏指针</button>
        <button class="pill sm ${showForm ? "accent" : "primary"}" onclick="toggleVaultForm()">${showForm ? "收起录入面板" : "+ 录入资料"}</button>
        <button class="pill sm outline" onclick="vaultLock()">锁定</button>
      </div>
    </div>

    ${showForm ? `
    <div class="list">
      <div class="list-pad">
        <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:10px;">
          <strong style="font-size:13px;">新增实体档案 / 证件 / 营业执照</strong>
          <select id="vFormKind" class="pill-sel" onchange="renderVaultFormFields()">
            <option value="person_profile">个人 / 合伙人基础资料（多电话/邮箱/地址）</option>
            <option value="identity_doc">身份证 / 护照（18位自动抽生日性别）</option>
            <option value="business_license">营业执照（可附加密原件）</option>
            <option value="company_entity">企业实体档案</option>
            <option value="api_key">API Key / 凭据</option>
          </select>
        </div>
        <div class="grid-2" style="margin-bottom:8px;">
          <input id="vSubj" type="text" value="${esc(STATE.vaultSubject)}" placeholder="主体 ID：self / partner:name / company:rawmemory" />
          <input id="vLabel" type="text" placeholder="记录名称（如：本人档案 / 营业执照正本）" />
        </div>
        <div id="vFormFields"></div>
        <div style="margin-top:10px;display:flex;justify-content:flex-end;gap:8px;">
          ${recs.length > 0 ? `<button class="pill outline" onclick="toggleVaultForm()">取消</button>` : ""}
          <button class="pill primary" onclick="saveVaultForm()">加密保存</button>
        </div>
      </div>
    </div>` : ""}

    <div class="sec-head">
      <div class="sub-seg">
        ${subjOpts.map(s => `<button class="${s === STATE.vaultSubject ? "on" : ""}" onclick="selectVaultSubject('${esc(s)}')">${esc(s)}</button>`).join("")}
      </div>
      <div style="display:flex;align-items:center;gap:8px;">
        <span style="font-size:12px;color:var(--muted);">明文显示</span>
        <button class="switch ${!STATE.vaultMasked ? "on" : ""}" role="switch" aria-checked="${!STATE.vaultMasked}" onclick="STATE.vaultMasked=!STATE.vaultMasked; renderVault(); loadAutofillPreview();"></button>
      </div>
    </div>

    <div class="list" id="autofillView">
      <div class="empty">加载填表视图中…</div>
    </div>

    <div class="sec-head">
      <span class="sec-title">已加密存储记录与扫描原件（${recs.length}）</span>
    </div>
    <div class="list">
      ${recRows || `<div class="empty"><strong>尚未录入任何加密记录</strong>先在上方录入一份本人基础资料、合伙人信息或营业执照。</div>`}
    </div>
  `;
  if (showForm) renderVaultFormFields();
}

function toggleVaultForm() {
  STATE.showVaultForm = !STATE.showVaultForm;
  renderVault();
  if (STATE.vault?.unlocked) loadAutofillPreview();
}

function selectVaultSubject(s) {
  STATE.vaultSubject = s;
  renderVault();
  loadAutofillPreview();
}

function renderVaultFormFields() {
  const kind = document.getElementById("vFormKind")?.value || "person_profile";
  const box = document.getElementById("vFormFields");
  if (!box) return;
  if (kind === "person_profile") {
    box.innerHTML = `
      <div class="grid-2">
        <input id="vf_full_name" type="text" placeholder="姓名（中文）" />
        <input id="vf_legal_name_en" type="text" placeholder="英文法定名 / 拼音" />
        <input id="vf_birth_date" type="text" placeholder="出生日期 YYYY-MM-DD" />
        <input id="vf_role_relation" type="text" placeholder="身份关系（本人 / 合伙人）" />
      </div>
      <div style="margin-top:8px;font-size:11.5px;color:var(--muted);">多个电话（每行一条：标签|号码，例如 <code>国内主力|13800138000</code>）</div>
      <textarea id="vf_phones" rows="2" style="width:100%;margin-top:4px;"></textarea>
      <div style="margin-top:6px;font-size:11.5px;color:var(--muted);">多个邮箱（每行一条：标签|邮箱）</div>
      <textarea id="vf_emails" rows="2" style="width:100%;margin-top:4px;"></textarea>
      <div style="margin-top:6px;font-size:11.5px;color:var(--muted);">多个住址（每行一条：标签|完整地址|邮编）</div>
      <textarea id="vf_addresses" rows="2" style="width:100%;margin-top:4px;"></textarea>
    `;
  } else if (kind === "identity_doc") {
    box.innerHTML = `
      <div class="grid-2">
        <select id="vf_doc_type"><option value="cn_id_card">中国居民身份证</option><option value="passport">护照</option><option value="hk_macau_pass">港澳通行证</option><option value="driver_license">驾照</option><option value="other">其他证件</option></select>
        <input id="vf_holder_name" type="text" placeholder="持证人姓名" />
        <input id="vf_doc_number" type="text" placeholder="证件号码（18位自动抽生日性别）" />
        <input id="vf_birth_date" type="text" placeholder="出生日期（身份证可留空自动解析）" />
        <input id="vf_issue_date" type="text" placeholder="签发日期" />
        <input id="vf_expiry_date" type="text" placeholder="有效期至" />
      </div>
      <input id="vf_address" type="text" style="width:100%;margin-top:8px;" placeholder="证件住址（如户籍地址）" />
    `;
  } else if (kind === "company_entity" || kind === "business_license") {
    box.innerHTML = `
      <div class="grid-2">
        <input id="vf_company_name" type="text" placeholder="企业全称" />
        <input id="vf_credit_code" type="text" placeholder="统一社会信用代码" />
        <input id="vf_legal_rep" type="text" placeholder="法定代表人" />
        <input id="vf_capital" type="text" placeholder="注册资本" />
        <input id="vf_established" type="text" placeholder="成立日期 YYYY-MM-DD" />
        <input id="vf_valid_until" type="text" placeholder="营业期限 / 长期" />
      </div>
      <input id="vf_reg_addr" type="text" style="width:100%;margin-top:8px;" placeholder="注册地址" />
      <input id="vf_scope" type="text" style="width:100%;margin-top:8px;" placeholder="经营范围（选填）" />
    `;
  } else {
    box.innerHTML = `<input id="vf_secret_val" type="password" style="width:100%;" placeholder="输入密钥或凭据值" />`;
  }
}

function parseLines(raw, keys) {
  return String(raw || "").split("\n").map(l => l.trim()).filter(Boolean).map((line, idx) => {
    const parts = line.split("|").map(x => x.trim());
    const obj = { primary: idx === 0 };
    if (parts.length === 1) { obj[keys[0]] = "默认"; obj[keys[1]] = parts[0]; }
    else { keys.forEach((k, i) => { if (parts[i] !== undefined) obj[k] = parts[i]; }); }
    return obj;
  });
}

async function saveVaultForm() {
  const kind = document.getElementById("vFormKind").value;
  const subject_id = document.getElementById("vSubj").value.trim() || "self";
  const label = document.getElementById("vLabel").value.trim() || `${subject_id} · ${kind}`;
  let payload = {};
  const g = id => document.getElementById(id)?.value?.trim() || "";
  if (kind === "person_profile") {
    payload = {
      full_name: g("vf_full_name"), legal_name_en: g("vf_legal_name_en"),
      birth_date: g("vf_birth_date"), role_relation: g("vf_role_relation"),
      phones: parseLines(g("vf_phones"), ["label", "number"]),
      emails: parseLines(g("vf_emails"), ["label", "address"]),
      addresses: parseLines(g("vf_addresses"), ["label", "full_address", "postal_code"]),
    };
  } else if (kind === "identity_doc") {
    payload = {
      doc_type: g("vf_doc_type"), holder_name: g("vf_holder_name"), doc_number: g("vf_doc_number"),
      birth_date: g("vf_birth_date"), issue_date: g("vf_issue_date"), expiry_date: g("vf_expiry_date"),
      address: g("vf_address"),
    };
  } else if (kind === "company_entity" || kind === "business_license") {
    payload = {
      company_name: g("vf_company_name"), unified_social_credit_code: g("vf_credit_code"),
      legal_representative: g("vf_legal_rep"), registered_capital: g("vf_capital"),
      established_date: g("vf_established"), valid_until: g("vf_valid_until"),
      registered_address: g("vf_reg_addr"), business_scope: g("vf_scope"),
    };
  } else {
    payload = { value: g("vf_secret_val") };
  }
  const r = await fetch("/api/vault/record", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ kind, subject_id, label, payload }),
  });
  if (!r.ok) { showToast("保存失败: " + await r.text()); return; }
  STATE.vaultSubject = subject_id;
  STATE.showVaultForm = false;
  await loadVault();
  showToast(`已加密保存「${label}」`);
}

let _COPY_BUF = [];
function copyFieldIdx(idx, btn) {
  const val = _COPY_BUF[idx] ?? "";
  navigator.clipboard.writeText(val).then(() => {
    const prev = btn.textContent;
    btn.textContent = "已复制";
    setTimeout(() => { btn.textContent = prev; }, 1200);
    showToast(STATE.vaultMasked ? "已复制脱敏值（开启「明文显示」可复制原值）" : "已复制明文到剪贴板");
  }).catch(() => showToast("浏览器阻止了剪贴板写入"));
}

function openPreviewModal(url, filename, mimeType) {
  const modal = document.getElementById("previewModal");
  const title = document.getElementById("previewTitle");
  const link = document.getElementById("previewOpenLink");
  const body = document.getElementById("previewBody");
  if (!modal || !body) return;
  title.textContent = filename || "加密附件预览";
  link.href = url;
  if (String(mimeType || "").startsWith("image/")) {
    body.innerHTML = `<img src="${esc(url)}" alt="${esc(filename)}" />`;
  } else {
    body.innerHTML = `<iframe src="${esc(url)}" title="${esc(filename)}"></iframe>`;
  }
  modal.classList.remove("hidden");
}

function closePreviewModal() {
  const modal = document.getElementById("previewModal");
  const body = document.getElementById("previewBody");
  if (modal) modal.classList.add("hidden");
  if (body) body.innerHTML = "";
}

document.addEventListener("keydown", e => { if (e.key === "Escape") closePreviewModal(); });

async function loadAutofillPreview() {
  const box = document.getElementById("autofillView");
  if (!box || !STATE.vault?.unlocked) return;
  const res = await fetch(`/api/vault/autofill/${encodeURIComponent(STATE.vaultSubject)}?masked=${STATE.vaultMasked}`).then(r => r.json());
  const fieldLabels = {
    full_name: "姓名",
    legal_name_en: "英文法定名",
    nickname: "常用称呼",
    role_relation: "身份 / 关系",
    birth_date: "出生日期",
    gender: "性别",
    nationality: "国籍 / 民族",
    company_name: "企业全称",
    company_name_en: "英文企业名",
    unified_social_credit_code: "统一社会信用代码",
    company_type: "企业类型",
    legal_representative: "法定代表人",
    registered_capital: "注册资本",
    established_date: "成立日期",
    tax_id: "纳税人识别号",
    business_scope: "经营范围",
  };
  const docLabels = {
    cn_id_card: "居民身份证",
    passport: "护照",
    hk_macau_pass: "港澳通行证",
    driver_license: "驾驶证",
    business_license: "营业执照",
  };
  _COPY_BUF = [];
  const row = (tag, tagCls, val, copyVal, sub) => {
    const idx = _COPY_BUF.push(String(copyVal ?? val)) - 1;
    return `<div class="row" style="min-height:46px;">
      <div style="width:168px;flex:none;"><span class="chip ${tagCls}">${esc(tag)}</span></div>
      <div class="row-who" style="font-size:13px;font-variant-numeric:tabular-nums;word-break:break-all;">
        <div>${esc(val)}</div>
        ${sub ? `<div style="font-size:11.5px;color:var(--muted);margin-top:1px;">${esc(sub)}</div>` : ""}
      </div>
      <div class="row-right"><button class="pill sm" onclick="copyFieldIdx(${idx}, this)">复制</button></div>
    </div>`;
  };
  const rows = [];
  for (const [k, v] of Object.entries(res.basic_fields || {})) rows.push(row(fieldLabels[k] || k, "", v, v));
  for (const p of (res.phones || [])) {
    const val = `${p.country_code ? p.country_code + " " : ""}${p.number}`.trim();
    rows.push(row(`电话 · ${p.label}`, "accent", val, p.number, p.note || ""));
  }
  for (const e of (res.emails || [])) rows.push(row(`邮箱 · ${e.label}`, "accent", e.address, e.address, e.note || ""));
  for (const a of (res.addresses || [])) rows.push(row(`地址 · ${a.label}`, "", `${a.full_address} ${a.postal_code || ""}`.trim(), a.full_address));
  for (const d of (res.documents || [])) {
    const sub = [d.issuing_authority, d.issue_date && d.expiry_date ? `有效期 ${d.issue_date} ~ ${d.expiry_date}` : (d.expiry_date ? `有效至 ${d.expiry_date}` : "")].filter(Boolean).join(" · ");
    rows.push(row(docLabels[d.doc_type] || d.doc_type, "amber", d.doc_number, d.doc_number, sub));
  }
  for (const b of (res.bank_accounts || [])) {
    const sub = [b.bank_name, b.swift_code ? `SWIFT/ACH: ${b.swift_code}` : "", b.account_name ? `户名: ${b.account_name}` : ""].filter(Boolean).join(" · ");
    rows.push(row(`银行 · ${b.label}`, "ok", b.account_number, b.account_number, sub));
  }
  for (const [k, v] of Object.entries(res.custom_fields || {})) rows.push(row(k, "mono", v, v));
  box.innerHTML = rows.join("") || `<div class="empty">主体 <code>${esc(STATE.vaultSubject)}</code> 暂无可填表字段，点击右上角「+ 录入资料」添加。</div>`;
}

async function vaultAuth(mode) {
  const pw = document.getElementById("vaultPw")?.value || "";
  const err = document.getElementById("vaultAuthErr");
  const r = await fetch(`/api/vault/${mode}`, {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ passphrase: pw }),
  });
  if (!r.ok) { const j = await r.json().catch(() => ({})); if (err) err.textContent = j.detail || "口令错误"; return; }
  await loadVault();
  showToast(mode === "init" ? "加密资料库已初始化并解锁" : "资料库已解锁");
}

async function vaultLock() {
  await fetch("/api/vault/lock", { method: "POST" });
  await loadVault();
  showToast("资料库已锁定");
}

async function uploadVaultAtt(recordId, input) {
  if (!input.files || !input.files.length) return;
  const file = input.files[0];
  try {
    const dataUrl = await new Promise((resolve, reject) => {
      const fr = new FileReader();
      fr.onload = () => resolve(String(fr.result || ""));
      fr.onerror = () => reject(fr.error || new Error("读取文件失败"));
      fr.readAsDataURL(file);
    });
    const content_b64 = dataUrl.includes(",") ? dataUrl.split(",", 2)[1] : "";
    const r = await fetch(`/api/vault/record/${encodeURIComponent(recordId)}/attach`, {
      method: "POST", headers: {"Content-Type": "application/json"},
      body: JSON.stringify({ filename: file.name, mime_type: file.type || "application/octet-stream", content_b64 }),
    });
    if (!r.ok) {
      const j = await r.json().catch(() => ({}));
      showToast("加密上传失败: " + (j.detail || r.status));
      return;
    }
    await loadVault();
    showToast(`已加密保存原件 ${file.name}`);
  } finally {
    input.value = "";
  }
}

async function deleteVaultRec(recordId) {
  if (!confirm("确定删除该加密记录并擦除密文附件？")) return;
  await fetch(`/api/vault/record/${encodeURIComponent(recordId)}`, { method: "DELETE" });
  await loadVault();
  showToast("已删除加密记录");
}

async function syncVaultReceipts() {
  const res = await fetch("/api/vault/sync-receipts", { method: "POST" }).then(r => r.json());
  showToast(`脱敏指针已同步 · 新增 ${res.created || 0} 条，已有 ${res.existing || 0} 条`);
}

// ==================== View 3: Memory & Adjudication ====================
function renderExchangeBlock(q) {
  const win = q.exchange_window || [];
  if (win.length > 1) {
    return `<div class="exchange">${win.map(t => {
      const cls = t.role === "cited" ? "cited" : "";
      const tag = t.role === "cited" ? "命中证据" : (t.role === "prev_context" ? "上文" : "下文");
      return `<div class="turn ${cls}"><div class="turn-meta">${tag} · ${esc(t.raw_id)} · ${esc(t.actor)} (${esc(t.source)})</div>${esc(t.quote)}</div>`;
    }).join("")}</div>`;
  }
  return `<div class="exchange"><div class="turn cited"><div class="turn-meta">命中证据 · ${esc(q.raw_id)} · ${esc(q.actor)} (${esc(q.source)})</div>${esc(q.quote)}</div></div>`;
}

function renderMemory() {
  const el = document.getElementById("tab-memory");
  const ov = STATE.overview;
  if (!ov) { el.innerHTML = `<div class="list"><div class="empty">加载长期记忆中…</div></div>`; return; }
  const f = ov.fidelity || {};
  const a = ov.adjudications || {};
  const latest = a.latest_by_key || {};

  const statsHtml = `
    <div class="stat-strip">
      <div class="stat-cell">
        <div class="stat-num">${pct(f.avg_claim_support_rate)}</div>
        <div class="stat-lbl">Claim Support</div>
        <div class="stat-sub">${(f.total_claims_checked || 0) - (f.total_unsupported_claims || 0)}/${f.total_claims_checked || 0} claims verified</div>
      </div>
      <div class="stat-cell">
        <div class="stat-num">${pct(f.durability_hygiene_rate)}</div>
        <div class="stat-lbl">Anti-Noise</div>
        <div class="stat-sub">${f.total_noise_flags || 0} noise flags</div>
      </div>
      <div class="stat-cell">
        <div class="stat-num">${pct(f.avg_episode_signal_coverage)}</div>
        <div class="stat-lbl">Signal Coverage</div>
        <div class="stat-sub">${(f.episode_omissions || []).length} curated episodes</div>
      </div>
      <div class="stat-cell">
        <div class="stat-num">${a.total_adjudicated || 0}</div>
        <div class="stat-lbl">Adjudicated</div>
        <div class="stat-sub">${a.query_feedback_count || 0} rated queries</div>
      </div>
    </div>
  `;

  const subBar = `
    <div class="lead">
      <div class="sub-seg">
        <button class="${STATE.memSub === "fidelity" ? "on" : ""}" onclick="STATE.memSub='fidelity'; renderMemory();">长期记忆与裁决 (${(f.items || []).length})</button>
        <button class="${STATE.memSub === "omissions" ? "on" : ""}" onclick="STATE.memSub='omissions'; renderMemory();">遗漏原话抽查 (${(f.episode_omissions || []).length})</button>
      </div>
      <span style="font-size:12px;color:var(--muted);">每条记忆均附 ±1 轮问答上下文窗口，便于人工复核</span>
    </div>
  `;

  let bodyHtml = "";
  if (STATE.memSub === "fidelity") {
    const verdicts = [
      ["accurate", "准确"],
      ["over_extrapolated", "脑补越权"],
      ["incomplete_citation", "缺引用"],
      ["wrong_supersession", "覆盖关系错"],
      ["noise", "噪声应删"],
    ];
    bodyHtml = (f.items || []).map(it => {
      const key = `${it.item_kind}:${it.item_id}`;
      const existing = latest[key];
      const cls = it.claim_support_rate >= 0.99 ? "ok" : (it.claim_support_rate >= 0.6 ? "amber" : "bad");
      const unsup = (it.unsupported_claims || []).map(c => `<span class="chip bad">未证实: ${esc(c)}</span>`).join("");
      const sup = (it.supported_claims || []).map(c => `<span class="chip ok">${esc(c)}</span>`).join("");
      const noiseChips = (it.noise_flags || []).map(fl => `<span class="chip amber">${esc(fl)}</span>`).join("");
      const quotes = (it.evidence_quotes || []).map(renderExchangeBlock).join("") || `<div class="exchange"><div class="turn">无非隐私引用摘录</div></div>`;
      const noteId = `note_${it.item_id}`;
      const btns = verdicts.map(([v, lbl]) =>
        `<button class="pill sm ${existing && existing.verdict === v ? "selected" : "outline"}" onclick="submitVerdict('${it.item_kind}','${esc(it.item_id)}','${v}','${noteId}','${esc(it.project || "")}','${esc(it.topic_or_title)}')">${lbl}</button>`
      ).join("");
      return `<div class="list"><div class="list-pad">
        <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;margin-bottom:10px;">
          <div style="display:flex;align-items:center;gap:7px;flex-wrap:wrap;">
            <strong style="font-size:13.5px;">${esc(it.topic_or_title)}</strong>
            <span class="chip mono">${esc(it.item_kind)}:${esc(it.status)}</span>
            <span class="chip accent">${esc(it.project || "global")}</span>
          </div>
          <div style="display:flex;gap:5px;flex-wrap:wrap;">
            <span class="chip ${cls}">Support ${pct(it.claim_support_rate)}</span>
            ${noiseChips || `<span class="chip ok">Clean</span>`}
            ${existing ? `<span class="chip ok">已裁决: ${esc(existing.verdict)}</span>` : ""}
          </div>
        </div>
        <div class="split">
          <div class="pane">
            <div class="pane-h">压缩后的长期记忆</div>
            <div style="line-height:1.6;">${esc(it.statement)}</div>
            <div class="pill-row">${sup}${unsup}</div>
          </div>
          <div class="pane">
            <div class="pane-h">原始问答证据窗口 (${(it.evidence_ids || []).length})</div>
            ${quotes}
          </div>
        </div>
        <div class="act-bar">
          ${btns}
          <input id="${noteId}" class="note-in" type="text" value="${esc(existing ? existing.note : "")}" placeholder="写下纠偏备注或讨论" />
        </div>
      </div></div>`;
    }).join("") || `<div class="list"><div class="empty">当前范围暂无已整理的长期记忆。</div></div>`;
  } else {
    bodyHtml = (f.episode_omissions || []).map(ep => {
      const cls = ep.coverage_rate >= 0.85 ? "ok" : (ep.coverage_rate >= 0.5 ? "amber" : "bad");
      const turns = (ep.omitted_turns || []).map(t => {
        const key = `omitted_turn:${t.raw_id}`;
        const existing = latest[key];
        const noteId = `om_${t.raw_id}`;
        return `<div class="pane" style="margin-top:10px;">
          <div style="display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap;margin-bottom:6px;">
            <span class="chip mono">${esc(t.raw_id)} · ${esc(t.source)}</span>
            ${existing ? `<span class="chip ok">已标记: ${esc(existing.verdict)}</span>` : ""}
          </div>
          ${renderExchangeBlock({ raw_id: t.raw_id, actor: "self", source: t.source, quote: t.quote || "(no quote)", exchange_window: t.exchange_window || [] })}
          <div style="display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin-top:8px;">
            <button class="pill sm ${existing && existing.verdict === "must_capture" ? "selected" : "outline"}" onclick="submitVerdict('omitted_turn','${esc(t.raw_id)}','must_capture','${noteId}','${esc(ep.project||"")}','${esc(ep.title)}')">漏记了，需补入</button>
            <button class="pill sm ${existing && existing.verdict === "safe_to_skip" ? "selected" : "outline"}" onclick="submitVerdict('omitted_turn','${esc(t.raw_id)}','safe_to_skip','${noteId}','${esc(ep.project||"")}','${esc(ep.title)}')">可忽略</button>
            <input id="${noteId}" class="note-in" type="text" value="${esc(existing ? existing.note : "")}" placeholder="备注归属个人记忆或项目档案" />
          </div>
        </div>`;
      }).join("") || `<div style="font-size:12.5px;color:var(--green);margin-top:6px;">无高信号遗漏</div>`;
      return `<div class="list"><div class="list-pad">
        <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;">
          <div style="display:flex;align-items:center;gap:7px;flex-wrap:wrap;">
            <strong>${esc(ep.title)}</strong>
            <span class="chip mono">${esc(ep.episode_id)}</span>
            <span class="chip accent">${esc(ep.project || "unassigned")}</span>
          </div>
          <span class="chip ${cls}">覆盖 ${ep.covered_high_signal_turns}/${ep.high_signal_human_turns} (${pct(ep.coverage_rate)})</span>
        </div>
        ${turns}
      </div></div>`;
    }).join("") || `<div class="list"><div class="empty">暂无待抽查的 Episode。</div></div>`;
  }

  el.innerHTML = statsHtml + subBar + bodyHtml;
}

async function submitVerdict(kind, id, verdict, noteId, project, summary) {
  const note = document.getElementById(noteId)?.value || "";
  await fetch("/api/debug/adjudicate", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ target_kind: kind, target_id: id, verdict, note, project: project || null, snapshot_summary: summary }),
  });
  await reloadAll(false);
  showToast(`已保存人工裁决：${verdict}`);
}

// ==================== View 4: Project Profiles ====================
function renderProfiles() {
  const el = document.getElementById("tab-profiles");
  const profs = (STATE.overview || {}).project_profiles || [];
  if (!profs.length) {
    el.innerHTML = `<div class="list"><div class="empty"><strong>暂无项目静态档案</strong>产品名、仓库、域名与实时状态查询指针应存放在项目档案，与个人长期记忆分离。</div></div>`;
    return;
  }
  el.innerHTML = `
    <div class="lead"><span>静态实体档案：存放官方命名、代码仓库、线上域名与 <strong>Live Status Pointers</strong>（实时状态去哪查，绝不存过时快照）。</span></div>
    <div class="prof-grid">
      ${profs.map(p => {
        const ptrs = (p.status_pointers || []).map(sp => `<li><strong>${esc(sp.label)}</strong> — ${esc(sp.how_to_check)}</li>`).join("");
        const notes = (p.tech_notes || []).map(n => `<li>${esc(n)}</li>`).join("");
        return `<div class="prof-card">
          <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:6px;">
            <strong style="font-size:14px;">${esc(p.display_name)}</strong>
            <span class="chip mono accent">${esc(p.project)}</span>
          </div>
          <div style="font-size:12.5px;color:var(--fg-2);margin-bottom:10px;">${esc(p.summary)}</div>
          <div class="pill-row">
            ${(p.domains || []).map(d => `<span class="chip accent">${esc(d)}</span>`).join("")}
            ${(p.repos || []).map(r => `<span class="chip mono">${esc(r)}</span>`).join("")}
          </div>
          ${ptrs ? `<div style="margin-top:12px;"><div class="pane-h">Live Status Pointers</div><ul class="pts">${ptrs}</ul></div>` : ""}
          ${notes ? `<div style="margin-top:12px;"><div class="pane-h">Project Tech Notes</div><ul class="pts">${notes}</ul></div>` : ""}
        </div>`;
      }).join("")}
    </div>
  `;
}

// ==================== View 5: Live Retrieval Debugger ====================
function renderQuery() {
  const el = document.getElementById("tab-query");
  const projs = (STATE.overview || {}).projects || [];
  const res = STATE.lastQuery;
  const samples = ["手表录音界面怎么改？", "App Store 状态去哪查？", "品牌怎么命名的？"];

  let resultHtml = "";
  if (res) {
    const pack = res.pack || {};
    const sup = res.superseded_filtered_out || [];
    const rawHits = res.raw_search_hits || [];
    resultHtml = `
      <div class="list"><div class="list-pad">
        <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;margin-bottom:10px;">
          <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
            <strong>Agent 实际收到的 Context Pack</strong>
            <span class="chip mono">${res.latency_ms} ms</span>
            <span class="chip mono">${pack.approx_tokens}/${pack.max_tokens} tok</span>
            <span class="chip">Profiles ${(pack.project_profiles || []).length}</span>
            ${sup.length ? `<span class="chip amber">已拦截过时决策 ${sup.length}</span>` : ""}
          </div>
          <div style="display:flex;gap:5px;flex-wrap:wrap;">
            <button class="pill sm outline" onclick="saveQueryRating('good')">命中准确</button>
            <button class="pill sm outline" onclick="saveQueryRating('missed_info')">漏了信息</button>
            <button class="pill sm outline" onclick="saveQueryRating('stale_leak')">混入过时</button>
            <button class="pill sm outline" onclick="saveQueryRating('noisy')">噪声偏多</button>
          </div>
        </div>
        <input id="qNote" type="text" style="width:100%;margin-bottom:10px;" placeholder="如需沉淀进个人回归测试集，可在此填写期望召回的关键事实后点击上方评分" />
        <pre class="code-out">${esc(pack.rendered_markdown || "")}</pre>
      </div></div>
      ${sup.length ? `<div class="list"><div class="list-pad"><div class="pane-h">已拦截的过时决策 (Superseded)</div>${sup.map(d => `<div class="exchange"><div class="turn"><span class="chip amber">${esc(d.status)}</span> <strong>${esc(d.topic)}</strong>: ${esc(d.statement)}</div></div>`).join("")}</div></div>` : ""}
      <div class="list"><div class="list-pad">
        <div class="pane-h">直接命中的 L1 Raw Matches (${rawHits.length})</div>
        ${rawHits.map(r => `<div class="exchange"><div class="turn cited"><div class="turn-meta">${esc(r.id)} · ${esc(r.source)} · ${esc(r.project || "unassigned")}</div><strong>${esc(r.title)}</strong> — ${esc(r.snippet)}</div></div>`).join("") || `<div class="empty" style="padding:14px;">无直接 Raw 命中</div>`}
      </div></div>
    `;
  }

  el.innerHTML = `
    <div class="lead"><span>输入任意自然语言问题，透视 <strong>HubStore</strong> 实时拼装给 Agent 的 Context Pack、Token 消耗与延迟。</span></div>
    <div class="list"><div class="list-pad">
      <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;">
        <input id="qInput" type="text" style="flex:1;min-width:260px;height:34px;" value="${esc(STATE.queryDraft)}" placeholder="输入自然语言测试问题…" onkeydown="if(event.key==='Enter') runDebugQuery()" oninput="STATE.queryDraft=this.value" />
        <select id="qProject" class="pill-sel" style="height:34px;">
          <option value="">全部项目</option>
          ${projs.map(p => `<option value="${esc(p.project)}" ${p.project === STATE.project ? "selected" : ""}>${esc(p.project)} (${p.event_count || 0})</option>`).join("")}
        </select>
        <button class="pill primary" style="height:34px;padding:0 14px;" onclick="runDebugQuery()">运行检索</button>
      </div>
      <div class="pill-row">
        ${samples.map(s => `<button class="pill sm" onclick="STATE.queryDraft='${esc(s)}'; renderQuery(); runDebugQuery();">${esc(s)}</button>`).join("")}
      </div>
    </div></div>
    ${resultHtml}
  `;
}

async function runDebugQuery() {
  const input = document.getElementById("qInput");
  const query = (input ? input.value : STATE.queryDraft).trim();
  if (!query) return;
  STATE.queryDraft = query;
  const project = document.getElementById("qProject")?.value || null;
  const res = await fetch("/api/debug/query", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ query, project, max_tokens: 2500, limit: 10 }),
  }).then(r => r.json());
  STATE.lastQuery = res;
  renderQuery();
}

async function saveQueryRating(rating) {
  if (!STATE.lastQuery) return;
  const pack = STATE.lastQuery.pack || {};
  const note = document.getElementById("qNote")?.value || "";
  await fetch("/api/debug/query-feedback", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({
      query: STATE.lastQuery.query,
      project: STATE.lastQuery.project,
      rating,
      expected_note: note,
      returned_decision_ids: (pack.active_decisions || []).map(x => x.id),
      returned_memory_ids: (pack.memories || []).map(x => x.id),
      returned_raw_ids: (pack.raw_evidence || []).map(x => x.id),
      latency_ms: STATE.lastQuery.latency_ms,
      approx_tokens: pack.approx_tokens,
    }),
  });
  await reloadAll(false);
  showToast("已保存到 eval/human_queries.jsonl");
}

// ==================== View 6: Benchmarks ====================
function renderBenchmarks() {
  const el = document.getElementById("tab-benchmarks");
  const reports = (STATE.benchmarks || {}).reports || [];
  if (!reports.length) {
    el.innerHTML = `<div class="list"><div class="empty">暂无已保存的 Benchmark 结果。</div></div>`;
    return;
  }
  const cards = reports.map(r => {
    // Shape A: Reflexive Meta Benchmark (`baselines` array)
    if (Array.isArray(r.baselines)) {
      const rows = r.baselines.map(b =>
        `<tr>
          <td><span class="chip ${b.baseline === "curated_pack" ? "ok" : ""}">${esc(b.baseline)}</span></td>
          <td class="mono">${pct(b.overall_fact_recall)}</td>
          <td class="mono">${pct(b.current_truth_accuracy)}</td>
          <td class="mono">${pct(b.stale_leakage_rate)}</td>
          <td class="mono">${Math.round(b.avg_tokens || 0)} tok</td>
          <td class="mono">${Number(b.p50_latency_ms || 0).toFixed(2)} ms</td>
        </tr>`
      ).join("");
      return `<div class="list">
        <div class="list-pad">
          <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;">
            <div style="display:flex;align-items:center;gap:7px;">
              <strong style="font-size:13.5px;">Reflexive Meta Benchmark</strong>
              <span class="chip mono">${esc(r.dataset_name || "reflexive")}</span>
            </div>
            <span class="chip mono">${r.total_cases || 0} cases · v${esc(r.dataset_version || "1.0")}</span>
          </div>
        </div>
        <table class="clean">
          <thead><tr><th>Baseline</th><th>Fact Recall</th><th>Truth Accuracy</th><th>Stale Leakage</th><th>Avg Tokens</th><th>p50 Latency</th></tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </div>`;
    }
    // Shape B: Pre-upgrade Baseline Summary (`suites` dict)
    if (r.suites && !r.overall) {
      const rows = Object.entries(r.suites).map(([name, m]) =>
        `<tr>
          <td><code>${esc(name)}</code></td>
          <td>${m.scored_questions || "-"}</td>
          <td>${Object.entries(m).filter(([k]) => !["scored_questions","abstention_questions","latency_p50_ms"].includes(k)).map(([k,v]) => `<span class="chip mono">${esc(k)} ${pct(v)}</span>`).join(" ")}</td>
          <td class="mono">${m.latency_p50_ms != null ? m.latency_p50_ms + " ms" : "-"}</td>
        </tr>`
      ).join("");
      return `<div class="list">
        <div class="list-pad">
          <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;">
            <div style="display:flex;align-items:center;gap:7px;">
              <strong style="font-size:13.5px;">Pre-Upgrade Baseline</strong>
              <span class="chip mono">${esc(r.engine_label || r._filename)}</span>
            </div>
            <span class="chip amber">v0.2.0 升级前对照基线</span>
          </div>
          ${r.description ? `<div style="font-size:12px;color:var(--muted);margin-top:6px;">${esc(r.description)}</div>` : ""}
        </div>
        <table class="clean">
          <thead><tr><th>Suite</th><th>Scored Qs</th><th>Metrics</th><th>p50</th></tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </div>`;
    }
    // Shape C: Standard LoCoMo / LongMemEval Report
    const o = r.overall || {};
    const metrics = Object.entries(o).map(([k, v]) => `<span class="chip ok mono">${esc(k)} ${pct(v)}</span>`).join("");
    const failures = (r.sample_failures || []).slice(0, 8).map(f =>
      `<tr><td><span class="chip">${esc(f.category)}</span></td><td>${esc(f.question)}</td><td>${esc(f.expected_answer)}</td><td><code>${esc((f.gold_ids||[]).join(","))}</code></td><td><code>${esc((f.retrieved_top_ids||[]).slice(0,3).join(",") || "∅")}</code></td></tr>`
    ).join("");
    return `<div class="list">
      <div class="list-pad">
        <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;">
          <div style="display:flex;align-items:center;gap:7px;flex-wrap:wrap;">
            <strong style="font-size:13.5px;">${esc(r.suite || r._filename)}</strong>
            ${r.mode ? `<span class="chip">${esc(r.mode)}</span>` : ""}
            <span class="chip mono">${esc(r.engine_label || "")}</span>
          </div>
          <span class="chip mono">N=${r.scored_questions ?? "-"}/${r.total_questions ?? "-"} · p50 ${r.latency_p50_ms ?? "-"}ms</span>
        </div>
        <div class="pill-row">${metrics}</div>
      </div>
      ${failures ? `<table class="clean"><thead><tr><th>类别</th><th>问题</th><th>标准答案</th><th>Gold</th><th>Top-3 命中</th></tr></thead><tbody>${failures}</tbody></table>` : ""}
    </div>`;
  }).join("");
  el.innerHTML = `
    <div class="lead"><span>公开记忆基准测试（LoCoMo · LongMemEval-S · LongMemEval-Oracle）与 Reflexive Meta 基准本地成绩。</span></div>
    ${cards}
  `;
}

applyTheme();
reloadAll(false);
</script>
</body>
</html>
"""
