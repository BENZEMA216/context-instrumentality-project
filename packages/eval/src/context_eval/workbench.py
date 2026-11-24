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


_WORKBENCH_HTML = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>Raw Memory · Human-in-the-Loop Debug Workbench</title>
<style>
  :root {
    --bg: #0d1117; --panel: #161b22; --panel2: #1c222b; --border: #30363d;
    --text: #e6edf3; --muted: #8b949e; --accent: #58a6ff; --green: #3fb950;
    --amber: #d29922; --red: #f85149; --purple: #a371f7;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
    background: var(--bg); color: var(--text); line-height: 1.5;
  }
  header {
    display: flex; align-items: center; justify-content: space-between;
    padding: 14px 24px; border-bottom: 1px solid var(--border); background: var(--panel);
    position: sticky; top: 0; z-index: 10;
  }
  header h1 { margin: 0; font-size: 16px; font-weight: 600; display: flex; align-items: center; gap: 10px; }
  .badge {
    font-size: 11px; padding: 2px 8px; border-radius: 999px; border: 1px solid var(--border);
    background: var(--panel2); color: var(--muted); font-family: ui-monospace, SFMono-Regular, monospace;
  }
  .badge.ok { border-color: rgba(63,185,80,.4); color: var(--green); background: rgba(63,185,80,.1); }
  .badge.warn { border-color: rgba(210,153,34,.4); color: var(--amber); background: rgba(210,153,34,.1); }
  .badge.bad { border-color: rgba(248,81,73,.4); color: var(--red); background: rgba(248,81,73,.1); }
  .badge.info { border-color: rgba(88,166,255,.4); color: var(--accent); background: rgba(88,166,255,.1); }
  .tabs { display: flex; gap: 6px; padding: 12px 24px 0; border-bottom: 1px solid var(--border); background: var(--panel); flex-wrap: wrap; }
  .tab {
    padding: 8px 14px; cursor: pointer; border: 1px solid transparent; border-bottom: none;
    border-radius: 8px 8px 0 0; color: var(--muted); font-size: 13px; font-weight: 500;
  }
  .tab.active { background: var(--bg); color: var(--text); border-color: var(--border); }
  main { max-width: 1280px; margin: 0 auto; padding: 20px 24px 60px; }
  .kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(185px, 1fr)); gap: 12px; margin-bottom: 20px; }
  .kpi { background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; }
  .kpi .label { font-size: 12px; color: var(--muted); }
  .kpi .val { font-size: 24px; font-weight: 700; margin-top: 4px; }
  .card { background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 16px; margin-bottom: 14px; }
  .card-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap; margin-bottom: 10px; }
  .split { display: grid; grid-template-columns: 1fr 1.15fr; gap: 14px; }
  @media (max-width: 900px) { .split { grid-template-columns: 1fr; } }
  .pane { background: var(--panel2); border: 1px solid var(--border); border-radius: 8px; padding: 12px; font-size: 13px; }
  .pane h4 { margin: 0 0 8px; font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); }
  .pill-row { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
  .exchange { border: 1px solid var(--border); border-radius: 8px; padding: 8px 10px; margin-bottom: 10px; background: rgba(255,255,255,.015); }
  .turn { border-left: 3px solid var(--border); padding: 5px 10px; margin: 5px 0; font-size: 12px; color: #8b949e; }
  .turn.cited { border-left-color: var(--accent); background: rgba(88,166,255,.08); color: var(--text); border-radius: 0 6px 6px 0; }
  .turn.prev { border-left-color: #6e7681; }
  .turn.next { border-left-color: #6e7681; }
  .turn .meta { color: var(--muted); font-family: ui-monospace, monospace; font-size: 11px; margin-bottom: 2px; }
  .actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 12px; padding-top: 12px; border-top: 1px solid var(--border); }
  button {
    background: var(--panel2); color: var(--text); border: 1px solid var(--border);
    padding: 6px 11px; border-radius: 7px; font-size: 12px; cursor: pointer; font-weight: 500;
  }
  button:hover { border-color: var(--accent); }
  button.primary { background: #1f6feb; border-color: #388bfd; color: #fff; }
  button.selected { border-color: var(--accent); background: rgba(88,166,255,.18); color: #fff; }
  input[type=text], select {
    background: var(--bg); color: var(--text); border: 1px solid var(--border);
    border-radius: 7px; padding: 7px 10px; font-size: 13px;
  }
  input[type=text].note { flex: 1; min-width: 220px; }
  .hidden { display: none; }
  pre {
    background: var(--bg); border: 1px solid var(--border); border-radius: 8px;
    padding: 12px; overflow-x: auto; font-size: 12px; white-space: pre-wrap; word-break: break-word;
  }
  table { width: 100%; border-collapse: collapse; font-size: 13px; margin-top: 8px; }
  th, td { padding: 8px 10px; border-bottom: 1px solid var(--border); text-align: left; }
  th { color: var(--muted); font-weight: 600; }
  .prof-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 14px; }
  ul.clean { margin: 6px 0 0 18px; padding: 0; font-size: 13px; }
  ul.clean li { margin: 4px 0; }
</style>
</head>
<body>
<header>
  <h1>🧠 Raw Memory <span class="badge">v2.1 · Human-in-the-Loop Debug Workbench</span></h1>
  <div style="display:flex;gap:8px;align-items:center;">
    <select id="projectFilter"><option value="">All Projects</option></select>
    <button onclick="reloadAll()">↻ Refresh</button>
  </div>
</header>
<div class="tabs">
  <div class="tab active" data-tab="fidelity" onclick="switchTab('fidelity')">1. 长期记忆忠实度 & 人工裁决</div>
  <div class="tab" data-tab="profiles" onclick="switchTab('profiles')">2. 项目静态档案 (Project Profiles)</div>
  <div class="tab" data-tab="omissions" onclick="switchTab('omissions')">3. 遗漏原话抽查</div>
  <div class="tab" data-tab="query" onclick="switchTab('query')">4. 实时检索调试器</div>
  <div class="tab" data-tab="benchmarks" onclick="switchTab('benchmarks')">5. 公开 Benchmark 跑分 & 错题本</div>
</div>
<main>
  <div id="kpis" class="kpi-grid"></div>

  <section id="tab-fidelity"></section>
  <section id="tab-profiles" class="hidden"></section>
  <section id="tab-omissions" class="hidden"></section>

  <section id="tab-query" class="hidden">
    <div class="card">
      <div style="display:flex;gap:10px;flex-wrap:wrap;align-items:center;">
        <input id="qInput" type="text" style="flex:1;min-width:300px;" placeholder="输入自然语言测试问题，例如：手表录音界面怎么改？ / App Store 状态去哪查？ / 品牌怎么命名的？" />
        <select id="qProject"><option value="">Any Project</option></select>
        <button class="primary" onclick="runDebugQuery()">Run Retrieval</button>
      </div>
      <div id="qMeta" style="margin-top:10px;font-size:12px;color:var(--muted);"></div>
    </div>
    <div id="qResult"></div>
  </section>

  <section id="tab-benchmarks" class="hidden"></section>
</main>

<script>
let STATE = { overview: null, benchmarks: null, lastQuery: null };

function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
}
function pct(v) { return (Number(v || 0) * 100).toFixed(1) + "%"; }

function switchTab(name) {
  document.querySelectorAll(".tab").forEach(el => el.classList.toggle("active", el.dataset.tab === name));
  ["fidelity","profiles","omissions","query","benchmarks"].forEach(t => {
    document.getElementById("tab-" + t).classList.toggle("hidden", t !== name);
  });
}

async function reloadAll() {
  const proj = document.getElementById("projectFilter").value;
  const qs = proj ? ("?project=" + encodeURIComponent(proj)) : "";
  const [ov, bm] = await Promise.all([
    fetch("/api/debug/overview" + qs).then(r => r.json()),
    fetch("/api/debug/benchmarks").then(r => r.json()),
  ]);
  STATE.overview = ov;
  STATE.benchmarks = bm;
  populateProjectSelects(ov.projects || [], proj);
  renderKPIs();
  renderFidelity();
  renderProfiles();
  renderOmissions();
  renderBenchmarks();
}

function populateProjectSelects(projects, current) {
  for (const id of ["projectFilter", "qProject"]) {
    const sel = document.getElementById(id);
    const keep = id === "projectFilter" ? current : sel.value;
    sel.innerHTML = `<option value="">${id === "projectFilter" ? "All Projects" : "Any Project"}</option>` +
      projects.map(p => `<option value="${esc(p.project)}" ${p.project === keep ? "selected" : ""}>${esc(p.project)} (${p.event_count || 0})</option>`).join("");
  }
}

document.getElementById("projectFilter").addEventListener("change", reloadAll);
document.getElementById("qInput").addEventListener("keydown", e => { if (e.key === "Enter") runDebugQuery(); });

function renderKPIs() {
  const f = STATE.overview.fidelity;
  const a = STATE.overview.adjudications;
  const profs = STATE.overview.project_profiles || [];
  document.getElementById("kpis").innerHTML = `
    <div class="kpi"><div class="label">Claim-to-Evidence 忠实度</div><div class="val">${pct(f.avg_claim_support_rate)}</div>
      <div class="label">${f.total_claims_checked - f.total_unsupported_claims}/${f.total_claims_checked} claims verified</div></div>
    <div class="kpi"><div class="label">Anti-Noise 抗噪纯度</div><div class="val">${pct(f.durability_hygiene_rate)}</div>
      <div class="label">${f.total_noise_flags} noise/duplicate/isolated flags</div></div>
    <div class="kpi"><div class="label">项目静态档案 Profiles</div><div class="val">${profs.length}</div>
      <div class="label">身份 / 仓库 / 实时状态指针</div></div>
    <div class="kpi"><div class="label">Episode 高信号覆盖率</div><div class="val">${pct(f.avg_episode_signal_coverage)}</div>
      <div class="label">${(f.episode_omissions || []).length} curated episodes</div></div>
    <div class="kpi"><div class="label">人工裁决 / 调试提问</div><div class="val">${a.total_adjudicated} / ${a.query_feedback_count}</div>
      <div class="label">持久化于 eval/*.jsonl</div></div>
  `;
}

function renderExchangeBlock(q) {
  const win = q.exchange_window || [];
  if (win.length > 1) {
    const turnsHtml = win.map(t => {
      const cls = t.role === "cited" ? "cited" : (t.role === "prev_context" ? "prev" : "next");
      const tag = t.role === "cited" ? "★ 命中证据" : (t.role === "prev_context" ? "↑ 上文语境" : "↓ 下文回应");
      return `<div class="turn ${cls}"><div class="meta">${tag} · ${esc(t.raw_id)} · ${esc(t.actor)} (${esc(t.source)})</div>${esc(t.quote)}</div>`;
    }).join("");
    return `<div class="exchange">${turnsHtml}</div>`;
  }
  return `<div class="exchange"><div class="turn cited"><div class="meta">★ 命中证据 · ${esc(q.raw_id)} · ${esc(q.actor)} (${esc(q.source)})</div>${esc(q.quote)}</div></div>`;
}

function renderNoiseBadge(flag) {
  if (flag === "volatile_status_snapshot") return `<span class="badge bad">⚠️ 瞬时外部状态噪音</span>`;
  if (flag === "isolated_short_reply") return `<span class="badge warn">⚠️ 孤立短回复(缺问答对)</span>`;
  if (flag.startsWith("duplicate_of:")) return `<span class="badge warn">⚠️ 与 ${esc(flag.split(":")[1])} 同义重复</span>`;
  return `<span class="badge warn">⚠️ ${esc(flag)}</span>`;
}

function renderFidelity() {
  const f = STATE.overview.fidelity;
  const latest = (STATE.overview.adjudications || {}).latest_by_key || {};
  const verdicts = [
    ["accurate", "✅ 准确"],
    ["over_extrapolated", "❌ 脑补越权"],
    ["incomplete_citation", "⚠️ 缺引用"],
    ["wrong_supersession", "🔁 覆盖关系错"],
    ["noise", "🗑 噪声应删"],
  ];
  const html = (f.items || []).map(it => {
    const key = `${it.item_kind}:${it.item_id}`;
    const existing = latest[key];
    const cls = it.claim_support_rate >= 0.99 ? "ok" : (it.claim_support_rate >= 0.6 ? "warn" : "bad");
    const unsup = (it.unsupported_claims || []).map(c => `<span class="badge bad">未证实: ${esc(c)}</span>`).join("");
    const sup = (it.supported_claims || []).map(c => `<span class="badge ok">${esc(c)}</span>`).join("");
    const noiseBadges = (it.noise_flags || []).map(renderNoiseBadge).join("");
    const quotes = (it.evidence_quotes || []).map(renderExchangeBlock).join("") || `<div class="exchange">无非隐私引用摘录</div>`;
    const noteId = `note_${it.item_id}`;
    const btns = verdicts.map(([v, lbl]) =>
      `<button class="${existing && existing.verdict === v ? "selected" : ""}" onclick="submitVerdict('${it.item_kind}','${esc(it.item_id)}','${v}','${noteId}','${esc(it.project || "")}','${esc(it.topic_or_title)}')">${lbl}</button>`
    ).join("");
    return `<div class="card">
      <div class="card-head">
        <div>
          <span class="badge">${esc(it.item_kind)}:${esc(it.status)}</span>
          <span class="badge info">${esc(it.project || "global")}</span>
          <strong style="margin-left:6px;">${esc(it.topic_or_title)}</strong>
        </div>
        <div style="display:flex;gap:6px;flex-wrap:wrap;">
          <span class="badge ${cls}">Claim Support ${pct(it.claim_support_rate)}</span>
          ${noiseBadges || `<span class="badge ok">Anti-Noise Clean</span>`}
          ${existing ? `<span class="badge ok">已标记: ${esc(existing.verdict)}</span>` : ""}
        </div>
      </div>
      <div class="split">
        <div class="pane">
          <h4>压缩后的长期记忆正文</h4>
          <div>${esc(it.statement)}</div>
          <div class="pill-row">${sup}${unsup}</div>
        </div>
        <div class="pane">
          <h4>原始对话证据 · 一问一答上下文窗口 (${(it.evidence_ids || []).length})</h4>
          ${quotes}
        </div>
      </div>
      <div class="actions">
        ${btns}
        <input id="${noteId}" class="note" type="text" value="${esc(existing ? existing.note : "")}" placeholder="写下你的纠偏或讨论备注" />
      </div>
    </div>`;
  }).join("");
  document.getElementById("tab-fidelity").innerHTML = html || `<div class="card">暂无已整理 Decision / Memory</div>`;
}

function renderProfiles() {
  const profs = STATE.overview.project_profiles || [];
  if (!profs.length) {
    document.getElementById("tab-profiles").innerHTML = `<div class="card">暂无 Project Profile（项目名、仓库、实时状态查询指针应存放在这里，而非塞进个人长期记忆）。</div>`;
    return;
  }
  const cards = profs.map(p => {
    const ptrs = (p.status_pointers || []).map(sp => `<li><strong>${esc(sp.label)}</strong>：${esc(sp.how_to_check)}</li>`).join("");
    const notes = (p.tech_notes || []).map(n => `<li>${esc(n)}</li>`).join("");
    return `<div class="card">
      <div class="card-head">
        <div><strong>${esc(p.display_name)}</strong> <span class="badge info">${esc(p.project)}</span></div>
        <span class="badge ok">Project Profile</span>
      </div>
      <div style="font-size:13px;margin-bottom:10px;">${esc(p.summary)}</div>
      <div class="pill-row">
        ${(p.domains || []).map(d => `<span class="badge info">🌐 ${esc(d)}</span>`).join("")}
        ${(p.repos || []).map(r => `<span class="badge">📦 ${esc(r)}</span>`).join("")}
      </div>
      ${ptrs ? `<div style="margin-top:12px;"><strong style="font-size:12px;color:var(--muted);">LIVE STATUS POINTERS（实时真相查询入口）</strong><ul class="clean">${ptrs}</ul></div>` : ""}
      ${notes ? `<div style="margin-top:12px;"><strong style="font-size:12px;color:var(--muted);">REPO / PROJECT TECH NOTES（项目内工程约定）</strong><ul class="clean">${notes}</ul></div>` : ""}
    </div>`;
  }).join("");
  document.getElementById("tab-profiles").innerHTML = `<div class="prof-grid">${cards}</div>`;
}

function renderOmissions() {
  const f = STATE.overview.fidelity;
  const latest = (STATE.overview.adjudications || {}).latest_by_key || {};
  const html = (f.episode_omissions || []).map(ep => {
    const cls = ep.coverage_rate >= 0.85 ? "ok" : (ep.coverage_rate >= 0.5 ? "warn" : "bad");
    const turns = (ep.omitted_turns || []).map(t => {
      const key = `omitted_turn:${t.raw_id}`;
      const existing = latest[key];
      const noteId = `om_${t.raw_id}`;
      return `<div class="pane" style="margin-top:10px;">
        <div style="display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap;margin-bottom:6px;">
          <span class="badge">${esc(t.raw_id)} · ${esc(t.source)} · hints=${esc((t.hints||[]).join(",") || "substantive")}</span>
          ${existing ? `<span class="badge ok">已标记: ${esc(existing.verdict)}</span>` : ""}
        </div>
        ${renderExchangeBlock({ raw_id: t.raw_id, actor: "self", source: t.source, quote: t.quote || "(no quote)", exchange_window: t.exchange_window || [] })}
        <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;">
          <button class="${existing && existing.verdict === "must_capture" ? "selected" : ""}" onclick="submitVerdict('omitted_turn','${esc(t.raw_id)}','must_capture','${noteId}','${esc(ep.project||"")}','${esc(ep.title)}')">📌 漏记了！必须补入</button>
          <button class="${existing && existing.verdict === "safe_to_skip" ? "selected" : ""}" onclick="submitVerdict('omitted_turn','${esc(t.raw_id)}','safe_to_skip','${noteId}','${esc(ep.project||"")}','${esc(ep.title)}')">👌 可忽略</button>
          <input id="${noteId}" class="note" type="text" value="${esc(existing ? existing.note : "")}" placeholder="备注应归入个人长期记忆还是项目档案" />
        </div>
      </div>`;
    }).join("") || `<div style="color:var(--green);font-size:13px;">✅ 无高信号遗漏</div>`;
    return `<div class="card">
      <div class="card-head">
        <div><strong>${esc(ep.title)}</strong> <span class="badge">${esc(ep.episode_id)}</span> <span class="badge info">${esc(ep.project || "unassigned")}</span></div>
        <span class="badge ${cls}">高信号覆盖 ${ep.covered_high_signal_turns}/${ep.high_signal_human_turns} (${pct(ep.coverage_rate)}) · 共 ${ep.total_events} 条事件</span>
      </div>
      ${turns}
    </div>`;
  }).join("");
  document.getElementById("tab-omissions").innerHTML = html;
}

async function submitVerdict(kind, id, verdict, noteId, project, summary) {
  const note = document.getElementById(noteId)?.value || "";
  await fetch("/api/debug/adjudicate", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ target_kind: kind, target_id: id, verdict, note, project: project || null, snapshot_summary: summary }),
  });
  await reloadAll();
}

async function runDebugQuery() {
  const query = document.getElementById("qInput").value.trim();
  if (!query) return;
  const project = document.getElementById("qProject").value || null;
  const res = await fetch("/api/debug/query", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ query, project, max_tokens: 2500, limit: 10 }),
  }).then(r => r.json());
  STATE.lastQuery = res;
  const pack = res.pack;
  document.getElementById("qMeta").innerHTML =
    `Latency: <strong>${res.latency_ms} ms</strong> · Tokens: <strong>${pack.approx_tokens}/${pack.max_tokens}</strong> · Project Profiles: <strong>${(pack.project_profiles || []).length}</strong> · FTS: <code>${esc(res.fts_expression || "(empty)")}</code> · Suppressed Superseded: <strong>${(res.superseded_filtered_out || []).length}</strong>`;
  const supHtml = (res.superseded_filtered_out || []).length
    ? `<div class="card"><h4>🛡 已拦截的过时决策 (Bi-Temporal Superseded)</h4>` +
      res.superseded_filtered_out.map(d => `<div class="exchange"><div class="turn"><span class="badge warn">${esc(d.status)}</span> <strong>${esc(d.topic)}</strong>: ${esc(d.statement)}</div></div>`).join("") + `</div>`
    : "";
  document.getElementById("qResult").innerHTML = `
    <div class="card">
      <div class="card-head"><strong>Agent 实际收到的 Context Pack</strong>
        <div style="display:flex;gap:6px;flex-wrap:wrap;">
          <button onclick="saveQueryRating('good')">👍 命中准确</button>
          <button onclick="saveQueryRating('missed_info')">👎 漏了关键信息</button>
          <button onclick="saveQueryRating('stale_leak')">⚠️ 混入过时信息</button>
          <button onclick="saveQueryRating('noisy')">🌫 噪声太多</button>
        </div>
      </div>
      <input id="qNote" class="note" style="width:100%;margin-bottom:10px;" type="text" placeholder="如果点了 👎/⚠️，写下期望召回的关键事实，自动沉淀进个人回归测试集" />
      <pre>${esc(pack.rendered_markdown)}</pre>
    </div>
    ${supHtml}
    <div class="card">
      <h4>直接命中的 L1 Raw Matches (${(res.raw_search_hits || []).length})</h4>
      ${(res.raw_search_hits || []).map(r => `<div class="exchange"><div class="turn cited"><div class="meta">${esc(r.id)} · ${esc(r.source)} · ${esc(r.project || "unassigned")}</div><strong>${esc(r.title)}</strong> — ${esc(r.snippet)}</div></div>`).join("") || "<div class='exchange'>无直接 Raw 命中</div>"}
    </div>
  `;
}

async function saveQueryRating(rating) {
  if (!STATE.lastQuery) return;
  const pack = STATE.lastQuery.pack;
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
  await reloadAll();
  alert("已保存到 eval/human_queries.jsonl！");
}

function renderBenchmarks() {
  const reports = (STATE.benchmarks || {}).reports || [];
  if (!reports.length) {
    document.getElementById("tab-benchmarks").innerHTML = `<div class="card">暂无已保存的 Benchmark JSON 结果。</div>`;
    return;
  }
  document.getElementById("tab-benchmarks").innerHTML = reports.map(r => {
    const o = r.overall || {};
    const metricBadges = Object.entries(o).map(([k, v]) => `<span class="badge ok">${esc(k)}: ${pct(v)}</span>`).join(" ");
    const failures = (r.sample_failures || []).slice(0, 10).map(f =>
      `<tr><td><span class="badge">${esc(f.category)}</span></td><td>${esc(f.question)}</td><td>${esc(f.expected_answer)}</td><td><code>${esc((f.gold_ids||[]).join(","))}</code></td><td><code>${esc((f.retrieved_top_ids||[]).slice(0,3).join(",") || "∅")}</code></td></tr>`
    ).join("");
    return `<div class="card">
      <div class="card-head">
        <div><strong>${esc(r.suite)}</strong> <span class="badge">${esc(r.mode)}</span> <span class="badge">${esc(r.engine_label)}</span></div>
        <span class="badge">N=${r.scored_questions}/${r.total_questions} · p50=${r.latency_p50_ms}ms</span>
      </div>
      <div class="pill-row">${metricBadges}</div>
      ${failures ? `<h4 style="margin:14px 0 4px;font-size:12px;color:var(--muted);">错题本 (Sample Failures for Debugging)</h4>
        <table><thead><tr><th>Category</th><th>Question</th><th>Expected</th><th>Gold</th><th>Got</th></tr></thead><tbody>${failures}</tbody></table>` : ""}
    </div>`;
  }).join("");
}

reloadAll();
</script>
</body>
</html>
"""
