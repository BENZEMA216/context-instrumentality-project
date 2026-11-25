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
  <div class="tab active" data-tab="fidelity" onclick="switchTab('fidelity')">1. 长期记忆 & 人工裁决</div>
  <div class="tab" data-tab="profiles" onclick="switchTab('profiles')">2. 项目档案 (Profiles)</div>
  <div class="tab" data-tab="omissions" onclick="switchTab('omissions')">3. 遗漏原话抽查</div>
  <div class="tab" data-tab="query" onclick="switchTab('query')">4. 实时检索调试器</div>
  <div class="tab" data-tab="benchmarks" onclick="switchTab('benchmarks')">5. Benchmark & 错题本</div>
  <div class="tab" data-tab="channels" onclick="switchTab('channels')">6. 📡 通道总控 (IM / 浏览器)</div>
  <div class="tab" data-tab="vault" onclick="switchTab('vault')">7. 🔐 关键资料与填表库 (Vault)</div>
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
  <section id="tab-channels" class="hidden"></section>
  <section id="tab-vault" class="hidden"></section>
</main>

<script>
let STATE = { overview: null, benchmarks: null, channels: null, vault: null, vaultSubject: "self", vaultMasked: true, lastQuery: null };

function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
}
function pct(v) { return (Number(v || 0) * 100).toFixed(1) + "%"; }

function switchTab(name) {
  document.querySelectorAll(".tab").forEach(el => el.classList.toggle("active", el.dataset.tab === name));
  ["fidelity","profiles","omissions","query","benchmarks","channels","vault"].forEach(t => {
    document.getElementById("tab-" + t).classList.toggle("hidden", t !== name);
  });
  if (name === "channels") loadChannels();
  if (name === "vault") loadVault();
}

async function reloadAll() {
  const proj = document.getElementById("projectFilter").value;
  const qs = proj ? ("?project=" + encodeURIComponent(proj)) : "";
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
  populateProjectSelects(ov.projects || [], proj);
  renderKPIs();
  renderFidelity();
  renderProfiles();
  renderOmissions();
  renderBenchmarks();
  renderChannels();
  renderVault();
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

// ---------------- Tab 6: Channels Control ----------------
async function loadChannels() {
  STATE.channels = await fetch("/api/channels/status").then(r => r.json());
  renderChannels();
}

function renderChannels() {
  const el = document.getElementById("tab-channels");
  const data = STATE.channels;
  if (!data) { el.innerHTML = `<div class="card">加载通道状态中…</div>`; return; }

  const rows = (data.channels || []).map(c => {
    const stCls = c.category === "active" ? "ok" : (c.category === "ready" ? "info" : "");
    const privCls = c.default_privacy === "local_only" ? "warn" : (c.default_privacy === "redacted" ? "info" : "ok");
    const syncBtn = c.collector_name && ["browser","clipcontext","window","chat","lark_im"].includes(c.collector_name)
      ? `<button onclick="triggerChannelSync('${esc(c.collector_name)}')">↻ Sync</button>`
      : `<span class="badge">${esc(c.category)}</span>`;
    return `<tr>
      <td><strong>${esc(c.product_name)}</strong><div style="font-size:11px;color:var(--muted);">${esc(c.description)}</div></td>
      <td><code>${esc(c.source)}</code></td>
      <td><span class="badge ${stCls}">${esc(c.category)}</span></td>
      <td><span class="badge ${privCls}">${esc(c.default_privacy)}</span></td>
      <td><strong>${c.counts.total}</strong> <span style="font-size:11px;color:var(--muted);">(可共享 ${c.counts.shareable} / 仅本机 ${c.counts.local_only})</span></td>
      <td>${syncBtn}</td>
    </tr>`;
  }).join("");

  const allowSet = new Set(((data.chat_allowlist || {}).allow_sessions || []).map(x => String(x)));
  const pmap = (data.chat_allowlist || {}).project_map || {};
  const imRows = (data.im_sessions || []).map(s => {
    const allowed = allowSet.has(s.session_id) || s.privacy_tier !== "local_only";
    const pid = `improj_${s.session_id.replace(/[^a-zA-Z0-9_-]/g, "_")}`;
    return `<tr>
      <td><strong>${esc(s.session_name)}</strong> <span class="badge">${esc(s.source)}</span><div style="font-size:11px;color:var(--muted);">${esc(s.session_id)}</div></td>
      <td>${s.message_count}</td>
      <td><span class="badge ${allowed ? "ok" : "warn"}">${allowed ? "✅ shareable" : "🔒 local_only"}</span></td>
      <td><input id="${pid}" type="text" style="width:150px;" value="${esc(pmap[s.session_id] || s.project || "")}" placeholder="项目 slug (如 record-for-agent)" /></td>
      <td>
        <button onclick="toggleChatAllow('${esc(s.session_id)}', ${!allowed}, '${pid}')">${allowed ? "切回 🔒 仅本机" : "放行给 Agent ✅"}</button>
      </td>
    </tr>`;
  }).join("");

  const larkDoc = (data.doctors || {}).lark_im || {};
  const browserDoc = (data.doctors || {}).browser || {};

  el.innerHTML = `
    <div class="card">
      <div class="card-head">
        <div><strong>📡 全量通道注册表（已预留 13 条标准通道）</strong></div>
        <div id="syncFeedback" class="badge info">Browser 可读配置: ${browserDoc.readable_profiles || 0} · 飞书 User 态: ${larkDoc.user_ready ? "✅ 已登录" : "待授权 (lark-cli auth login --domain im)"}</div>
      </div>
      <table>
        <thead><tr><th>通道与产品</th><th>Source</th><th>阶段</th><th>默认隐私</th><th>入库量</th><th>操作</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>

    <div class="split">
      <div class="card">
        <div class="card-head"><strong>💬 微信 / WeFlow / Telegram / CSV 合规导入</strong><span class="badge warn">默认全部 local_only</span></div>
        <div style="font-size:12px;color:var(--muted);margin-bottom:10px;">
          合规路径（不做微信加密库破解）：将 WeFlow 导出的 JSON、Telegram Desktop JSON、或 JSONL/CSV 拖选上传，将保存到 <code>${esc(data.chat_inbox_dir)}</code> 并立即入库。
        </div>
        <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">
          <input id="chatFileInput" type="file" accept=".json,.jsonl,.csv" />
          <button class="primary" onclick="uploadChatExport()">上传并同步入库</button>
        </div>
        <div id="chatUploadOut" style="margin-top:8px;font-size:12px;color:var(--muted);"></div>
      </div>

      <div class="card">
        <div class="card-head"><strong>🌐 Read for Agent · 浏览器通道提示</strong><span class="badge ok">已接入</span></div>
        <div style="font-size:12px;color:var(--muted);">
          <div>1. <strong>本地历史直采</strong>：点击上表 <code>browser</code> 行的 <strong>↻ Sync</strong> 即可无锁增量同步 Chrome / Arc 最近 14 天阅读记录（自动过滤登录/OAuth 并隔离邮箱网银）。</div>
          <div style="margin-top:6px;">2. <strong>深度正文 MV3 扩展</strong>：Chrome/Arc 打开 <code>chrome://extensions</code> → 开发者模式 → 加载已解压的扩展 → 选择 <code>extensions/browser/dist/</code>，获得 Defuddle 全文 Markdown 与划词高亮采集。</div>
        </div>
      </div>
    </div>

    <div class="card">
      <div class="card-head"><strong>🛡 IM 会话白名单与项目映射（chat_allowlist.json）</strong><span class="badge">${(data.im_sessions || []).length} 个已导入会话</span></div>
      ${imRows
        ? `<table><thead><tr><th>会话 / 群聊</th><th>消息数</th><th>当前隐私</th><th>归属项目</th><th>权限开关</th></tr></thead><tbody>${imRows}</tbody></table>`
        : `<div style="font-size:13px;color:var(--muted);">暂未导入任何微信/IM 会话。在上方上传一份 WeFlow JSON 或 CSV 导出即可在此逐群勾选放行。</div>`}
    </div>
  `;
}

async function triggerChannelSync(collector) {
  const fb = document.getElementById("syncFeedback");
  if (fb) fb.textContent = `正在同步 ${collector}...`;
  const res = await fetch("/api/channels/sync", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ collector, since_days: 14.0 }),
  }).then(r => r.json());
  const rep = res.report || {};
  await loadChannels();
  alert(`同步完成 [${collector}]: status=${rep.status}, 新增=${rep.created || 0}, 已存在=${rep.existing || 0}${rep.message ? " · " + rep.message : ""}`);
}

async function uploadChatExport() {
  const input = document.getElementById("chatFileInput");
  const out = document.getElementById("chatUploadOut");
  if (!input || !input.files || !input.files.length) { alert("请先选择一个 .json / .jsonl / .csv 文件"); return; }
  const file = input.files[0];
  const content = await file.text();
  out.textContent = `正在上传并解析 ${file.name}...`;
  const res = await fetch("/api/channels/chat/upload", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ filename: file.name, content }),
  }).then(r => r.json());
  const rep = res.report || {};
  out.textContent = `✅ 已保存并同步：新增 ${rep.created || 0} 条，已存在 ${rep.existing || 0} 条（默认 local_only）。`;
  await loadChannels();
}

async function toggleChatAllow(sessionId, allow, projInputId) {
  const project = document.getElementById(projInputId)?.value?.trim() || null;
  await fetch("/api/channels/chat/allowlist", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ session_id: sessionId, allow, project, tier: "shareable" }),
  });
  await loadChannels();
}

// ---------------- Tab 7: Encrypted Vault & Form-Fill Studio ----------------
async function loadVault() {
  STATE.vault = await fetch("/api/vault/status").then(r => r.json());
  renderVault();
  if (STATE.vault.unlocked) await loadAutofillPreview();
}

function renderVault() {
  const el = document.getElementById("tab-vault");
  const v = STATE.vault;
  if (!v) { el.innerHTML = `<div class="card">加载 Vault 中…</div>`; return; }

  if (!v.initialized || !v.unlocked) {
    const mode = v.initialized ? "unlock" : "init";
    el.innerHTML = `
      <div class="card" style="max-width:560px;margin:20px auto;">
        <div class="card-head">
          <strong>🔐 Vault for Agent · ${v.initialized ? "解锁加密资料库" : "首次初始化 AES-256-GCM 资料库"}</strong>
          <span class="badge info">独立存储 · 绝不入 Git</span>
        </div>
        <div style="font-size:13px;color:var(--muted);margin-bottom:12px;">
          独立存放本人/合伙人身份信息、营业执照原件与多手机号/邮箱/住址填表档案（逐条 AES-256-GCM 加密，存储于 <code>${esc(v.vault_path)}</code>）。口令仅保存在本机进程内存中，可随时一键锁定。
        </div>
        <div style="display:flex;gap:8px;">
          <input id="vaultPw" type="password" style="flex:1;" placeholder="${v.initialized ? "输入 Vault 主口令解锁" : "设置一个 Vault 主口令（请牢记）"}" />
          <button class="primary" onclick="vaultAuth('${mode}')">${v.initialized ? "🔓 解锁" : "🚀 初始化并解锁"}</button>
        </div>
        <div id="vaultAuthErr" style="margin-top:8px;font-size:12px;color:var(--red);"></div>
      </div>
    `;
    return;
  }

  const subjects = v.subjects || [];
  const subjOpts = Array.from(new Set(["self", ...subjects.map(s => s.subject_id)]));
  if (!subjOpts.includes(STATE.vaultSubject)) STATE.vaultSubject = subjOpts[0];

  const recCards = (v.records || []).map(r => {
    const atts = (r.attachments || []).map(a =>
      `<a href="/api/vault/attachment/${esc(a.id)}" target="_blank" class="badge info" style="text-decoration:none;">📎 ${esc(a.filename)} (${Math.round(a.byte_size/1024)}KB)</a>`
    ).join(" ");
    return `<tr>
      <td><span class="badge info">${esc(r.subject_id)}</span></td>
      <td><span class="badge">${esc(r.kind)}</span></td>
      <td><strong>${esc(r.label)}</strong><div class="pill-row">${atts}</div></td>
      <td style="display:flex;gap:6px;flex-wrap:wrap;">
        <label style="cursor:pointer;" class="badge">📎 加密上传原件<input type="file" style="display:none;" onchange="uploadVaultAtt('${esc(r.id)}', this)" /></label>
        <button onclick="deleteVaultRec('${esc(r.id)}')">删除</button>
      </td>
    </tr>`;
  }).join("");

  el.innerHTML = `
    <div class="card">
      <div class="card-head">
        <div><strong>🔐 Vault for Agent · 关键身份 / 合伙人 / 营业执照 & 一键填表库</strong> <span class="badge ok">🔓 已解锁</span></div>
        <div style="display:flex;gap:8px;flex-wrap:wrap;">
          <button onclick="syncVaultReceipts()">↻ 同步脱敏指针到 Raw Memory</button>
          <button onclick="vaultLock()">🔒 立即锁定</button>
        </div>
      </div>
      <div style="font-size:12px;color:var(--muted);">
        支持同一主体维护多个手机号、多个邮箱、多个住址，并自动把关联的身份证/护照/营业执照字段合并进下方「一键填表视图」。同步到 Raw Memory 的永远只有脱敏指针，绝不泄露明文。
      </div>
    </div>

    <div class="split">
      <div class="card">
        <div class="card-head">
          <strong>📋 一键填表视图（自动聚合基础档案 + 证件/执照字段）</strong>
          <div style="display:flex;gap:6px;align-items:center;">
            <select id="afSubjectSel" onchange="STATE.vaultSubject=this.value; loadAutofillPreview();">
              ${subjOpts.map(s => `<option value="${esc(s)}" ${s === STATE.vaultSubject ? "selected" : ""}>${esc(s)}</option>`).join("")}
            </select>
            <button onclick="STATE.vaultMasked=!STATE.vaultMasked; loadAutofillPreview();">${STATE.vaultMasked ? "👁 显示明文" : "🙈 切回掩码"}</button>
          </div>
        </div>
        <div id="autofillView"><div style="color:var(--muted);font-size:13px;">选择主体后自动聚合…</div></div>
      </div>

      <div class="card">
        <div class="card-head">
          <strong>➕ 录入实体档案 / 证件 / 营业执照</strong>
          <select id="vFormKind" onchange="renderVaultFormFields()">
            <option value="person_profile">👤 个人/合伙人基础资料（多电话/多邮箱/多地址）</option>
            <option value="identity_doc">🪪 身份证 / 护照（18位身份证自动抽生日性别）</option>
            <option value="company_entity">🏢 企业实体档案</option>
            <option value="business_license">📜 营业执照（可附加密原件扫描件）</option>
            <option value="api_key">🔑 API Key / 凭据</option>
          </select>
        </div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:8px;">
          <input id="vSubj" type="text" value="self" placeholder="主体 ID：self / partner:zheng / company:rawmemory" />
          <input id="vLabel" type="text" placeholder="记录名称（如：本人基础档案 / 营业执照正本）" />
        </div>
        <div id="vFormFields"></div>
        <div style="margin-top:10px;display:flex;gap:8px;">
          <button class="primary" onclick="saveVaultForm()">加密保存到 Vault</button>
          <span id="vSaveMsg" style="font-size:12px;color:var(--green);"></span>
        </div>
      </div>
    </div>

    <div class="card">
      <div class="card-head"><strong>🗂 已加密存储记录 & 原件附件（${(v.records || []).length} 条）</strong></div>
      ${recCards
        ? `<table><thead><tr><th>主体</th><th>类型</th><th>名称与加密附件</th><th>操作</th></tr></thead><tbody>${recCards}</tbody></table>`
        : `<div style="font-size:13px;color:var(--muted);">还没有记录，先在右上角录入一份「本人基础资料」或「营业执照」试试！</div>`}
    </div>
  `;
  renderVaultFormFields();
}

function renderVaultFormFields() {
  const kind = document.getElementById("vFormKind")?.value || "person_profile";
  const box = document.getElementById("vFormFields");
  if (!box) return;
  if (kind === "person_profile") {
    box.innerHTML = `
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;">
        <input id="vf_full_name" type="text" placeholder="姓名（中文）" />
        <input id="vf_legal_name_en" type="text" placeholder="英文法定名 / 拼音" />
        <input id="vf_birth_date" type="text" placeholder="出生日期 YYYY-MM-DD" />
        <input id="vf_role_relation" type="text" placeholder="身份/关系（本人 / 合伙人）" />
      </div>
      <div style="margin-top:8px;font-size:12px;color:var(--muted);">多个电话（每行一条，格式：标签|号码，如 <code>国内主力|13800138000</code>）</div>
      <textarea id="vf_phones" rows="2" style="width:100%;margin-top:4px;background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:6px;padding:6px;"></textarea>
      <div style="margin-top:6px;font-size:12px;color:var(--muted);">多个邮箱（每行一条，格式：标签|邮箱）</div>
      <textarea id="vf_emails" rows="2" style="width:100%;margin-top:4px;background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:6px;padding:6px;"></textarea>
      <div style="margin-top:6px;font-size:12px;color:var(--muted);">多个住址（每行一条，格式：标签|完整地址|邮编）</div>
      <textarea id="vf_addresses" rows="2" style="width:100%;margin-top:4px;background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:6px;padding:6px;"></textarea>
    `;
  } else if (kind === "identity_doc") {
    box.innerHTML = `
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;">
        <select id="vf_doc_type"><option value="cn_id_card">中国居民身份证</option><option value="passport">护照</option><option value="hk_macau_pass">港澳通行证</option><option value="driver_license">驾照</option><option value="other">其他证件</option></select>
        <input id="vf_holder_name" type="text" placeholder="持证人姓名" />
        <input id="vf_doc_number" type="text" placeholder="证件号码（18位身份证自动抽生日性别）" />
        <input id="vf_birth_date" type="text" placeholder="出生日期（可选，身份证自动填）" />
        <input id="vf_issue_date" type="text" placeholder="签发日期" />
        <input id="vf_expiry_date" type="text" placeholder="有效期至" />
      </div>
      <input id="vf_address" type="text" style="width:100%;margin-top:6px;" placeholder="证件住址（如户籍地址）" />
    `;
  } else if (kind === "company_entity" || kind === "business_license") {
    box.innerHTML = `
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;">
        <input id="vf_company_name" type="text" placeholder="企业全称" />
        <input id="vf_credit_code" type="text" placeholder="统一社会信用代码" />
        <input id="vf_legal_rep" type="text" placeholder="法定代表人" />
        <input id="vf_capital" type="text" placeholder="注册资本" />
        <input id="vf_established" type="text" placeholder="成立日期 YYYY-MM-DD" />
        <input id="vf_valid_until" type="text" placeholder="营业期限 / 长期" />
      </div>
      <input id="vf_reg_addr" type="text" style="width:100%;margin-top:6px;" placeholder="注册地址" />
      <input id="vf_scope" type="text" style="width:100%;margin-top:6px;" placeholder="经营范围（选填）" />
    `;
  } else {
    box.innerHTML = `<input id="vf_secret_val" type="password" style="width:100%;" placeholder="输入密钥或敏感值" />`;
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
  if (!r.ok) { alert("保存失败: " + await r.text()); return; }
  STATE.vaultSubject = subject_id;
  await loadVault();
}

async function loadAutofillPreview() {
  const box = document.getElementById("autofillView");
  if (!box || !STATE.vault?.unlocked) return;
  const res = await fetch(`/api/vault/autofill/${encodeURIComponent(STATE.vaultSubject)}?masked=${STATE.vaultMasked}`).then(r => r.json());
  const copyBtn = val => `<button style="padding:2px 7px;font-size:11px;" onclick="navigator.clipboard.writeText(${JSON.stringify(val)})">Copy</button>`;
  const rows = [];
  for (const [k, v] of Object.entries(res.basic_fields || {})) {
    rows.push(`<tr><td><code>${esc(k)}</code></td><td>${esc(v)}</td><td>${copyBtn(v)}</td></tr>`);
  }
  for (const p of (res.phones || [])) {
    const val = `${p.country_code ? p.country_code + " " : ""}${p.number}`.trim();
    rows.push(`<tr><td><span class="badge info">电话·${esc(p.label)}</span></td><td>${esc(val)}</td><td>${copyBtn(p.number)}</td></tr>`);
  }
  for (const e of (res.emails || [])) {
    rows.push(`<tr><td><span class="badge info">邮箱·${esc(e.label)}</span></td><td>${esc(e.address)}</td><td>${copyBtn(e.address)}</td></tr>`);
  }
  for (const a of (res.addresses || [])) {
    rows.push(`<tr><td><span class="badge info">地址·${esc(a.label)}</span></td><td>${esc(a.full_address)} ${esc(a.postal_code)}</td><td>${copyBtn(a.full_address)}</td></tr>`);
  }
  for (const d of (res.documents || [])) {
    rows.push(`<tr><td><span class="badge warn">${esc(d.doc_type)}</span></td><td>${esc(d.doc_number)} ${d.expiry_date ? "(有效至 " + esc(d.expiry_date) + ")" : ""}</td><td>${copyBtn(d.doc_number)}</td></tr>`);
  }
  box.innerHTML = rows.length
    ? `<table><thead><tr><th>字段</th><th>值 (${res.masked ? "已掩码" : "明文"})</th><th>复制</th></tr></thead><tbody>${rows.join("")}</tbody></table>`
    : `<div style="font-size:13px;color:var(--muted);">主体 <code>${esc(STATE.vaultSubject)}</code> 暂无数据，可在右侧录入。</div>`;
}

async function vaultAuth(mode) {
  const pw = document.getElementById("vaultPw")?.value || "";
  const err = document.getElementById("vaultAuthErr");
  const r = await fetch(`/api/vault/${mode}`, {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ passphrase: pw }),
  });
  if (!r.ok) { const j = await r.json().catch(() => ({})); err.textContent = j.detail || "口令错误"; return; }
  await loadVault();
}

async function vaultLock() {
  await fetch("/api/vault/lock", { method: "POST" });
  await loadVault();
}

async function uploadVaultAtt(recordId, input) {
  if (!input.files || !input.files.length) return;
  const file = input.files[0];
  const buf = await file.arrayBuffer();
  const bytes = new Uint8Array(buf);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  const content_b64 = btoa(bin);
  const r = await fetch(`/api/vault/record/${encodeURIComponent(recordId)}/attach`, {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ filename: file.name, mime_type: file.type || "application/octet-stream", content_b64 }),
  });
  if (!r.ok) { alert("加密上传失败: " + await r.text()); return; }
  await loadVault();
}

async function deleteVaultRec(recordId) {
  if (!confirm("确定删除该加密记录并擦除密文附件？")) return;
  await fetch(`/api/vault/record/${encodeURIComponent(recordId)}`, { method: "DELETE" });
  await loadVault();
}

async function syncVaultReceipts() {
  const res = await fetch("/api/vault/sync-receipts", { method: "POST" }).then(r => r.json());
  alert(`已同步脱敏指针回执到 Raw Memory：新增 ${res.created || 0} 条，已存在 ${res.existing || 0} 条（零明文泄露）。`);
}

reloadAll();
</script>
</body>
</html>
"""
