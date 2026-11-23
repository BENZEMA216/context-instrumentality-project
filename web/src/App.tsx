import { useCallback, useEffect, useRef, useState } from "react";
import {
  Activity,
  Bot,
  Check,
  Copy,
  FileText,
  FolderGit2,
  Link2,
  Lock,
  Plus,
  RefreshCw,
  Search,
  Shield,
  Sparkles,
  Trash2,
} from "lucide-react";
import {
  api,
  type CollectorStatus,
  type CurationQueueResponse,
  type CurationRulesResponse,
  type Episode,
  type HubStats,
  type MarkdownFileInfo,
  type PrivacyRule,
  type PrivacyTier,
  type ProjectState,
  type ProjectSummary,
  type SearchResult,
} from "./api";

type Tab = "timeline" | "projects" | "curator" | "markdown" | "channels" | "vault";

const SOURCE_LABELS: Record<string, string> = {
  ai_chat: "AI 对话",
  clipboard: "剪贴板",
  browser: "浏览器",
  wechat: "微信",
  voice: "录音",
  window: "窗口焦点",
  location: "位置轨迹",
  vault: "Vault 回执",
};

const TIER_LABELS: Record<PrivacyTier, string> = {
  shareable: "Agent 可见",
  redacted: "已脱敏可见",
  local_only: "仅本机私密",
};

const AUTHORITY_LABELS: Record<string, string> = {
  user_confirmed: "用户拍板",
  assistant_suggested: "助手提议",
  observed: "客观观察",
};

function fmtTime(ms: number): string {
  if (!ms) return "";
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

export function App() {
  const [tab, setTab] = useState<Tab>("timeline");
  const [stats, setStats] = useState<HubStats | null>(null);
  const [notice, setNotice] = useState<{ msg: string; err?: boolean } | null>(null);
  const [loading, setLoading] = useState(false);

  // Timeline state
  const [episodes, setEpisodes] = useState<Episode[]>([]);
  const [selectedEpId, setSelectedEpId] = useState<string | null>(null);
  const [selectedEp, setSelectedEp] = useState<Episode | null>(null);
  const [sourceFilter, setSourceFilter] = useState<string>("");
  const [query, setQuery] = useState("");
  const [searchRes, setSearchRes] = useState<SearchResult | null>(null);
  const searchInputRef = useRef<HTMLInputElement>(null);

  // Projects & Decisions state
  const [projects, setProjects] = useState<ProjectSummary[]>([]);
  const [selectedProj, setSelectedProj] = useState<string | null>(null);
  const [projectState, setProjectState] = useState<ProjectState | null>(null);

  // Curator state
  const [curationRules, setCurationRules] = useState<CurationRulesResponse | null>(null);
  const [curationQueue, setCurationQueue] = useState<CurationQueueResponse | null>(null);
  const [curatorHost, setCuratorHost] = useState<"antigravity" | "codex" | "workbuddy">("antigravity");
  const [copiedKey, setCopiedKey] = useState<string | null>(null);

  // Markdown state
  const [mdRoot, setMdRoot] = useState("");
  const [mdFiles, setMdFiles] = useState<MarkdownFileInfo[]>([]);
  const [selectedMd, setSelectedMd] = useState<string | null>(null);
  const [mdContent, setMdContent] = useState("");

  // Channels & Privacy state
  const [privacyRules, setPrivacyRules] = useState<PrivacyRule[]>([]);
  const [collectors, setCollectors] = useState<CollectorStatus[]>([]);
  const [newRule, setNewRule] = useState({
    scope: "project" as PrivacyRule["scope"],
    match_value: "",
    default_tier: "shareable" as PrivacyTier,
    priority: 50,
    description: "",
  });

  // New event modal
  const [showNewEvent, setShowNewEvent] = useState(false);
  const [draftEvent, setDraftEvent] = useState({
    source: "ai_chat",
    project: "context-os",
    title: "",
    text: "",
    tier: "shareable" as PrivacyTier,
  });

  const flash = useCallback((msg: string, err = false) => {
    setNotice({ msg, err });
  }, []);

  const copyText = useCallback(async (key: string, text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopiedKey(key);
      setTimeout(() => setCopiedKey(null), 1800);
    } catch {
      flash("浏览器阻止了剪贴板写入，请手动选中复制。", true);
    }
  }, [flash]);

  const refreshCore = useCallback(async () => {
    setLoading(true);
    try {
      const [s, eps, projs] = await Promise.all([
        api.stats(),
        api.episodes({ source: sourceFilter || undefined }),
        api.projects(),
      ]);
      setStats(s);
      setEpisodes(eps.items);
      setProjects(projs.items);
      if (eps.items.length > 0 && !selectedEpId) {
        setSelectedEpId(eps.items[0].id);
      }
      if (projs.items.length > 0 && !selectedProj) {
        setSelectedProj(projs.items[0].project);
      }
    } catch (e) {
      flash(`无法连接 Hub 服务：${(e as Error).message}`, true);
    } finally {
      setLoading(false);
    }
  }, [sourceFilter, selectedEpId, selectedProj, flash]);

  const applyHashRoute = useCallback(() => {
    const raw = window.location.hash.replace(/^#\/?/, "");
    if (!raw) return;
    const [head, ...rest] = raw.split("/");
    const tail = decodeURIComponent(rest.join("/"));
    if (head === "episodes" && tail) {
      setTab("timeline");
      setSelectedEpId(tail);
    } else if (head === "projects") {
      setTab("projects");
      if (tail) setSelectedProj(tail);
    } else if (head === "artifacts" || head === "markdown") {
      setTab("markdown");
      if (tail) setSelectedMd(tail);
    } else if (head === "curator") {
      setTab("curator");
    } else if (head === "channels") {
      setTab("channels");
    } else if (head === "vault") {
      setTab("vault");
    } else if (head === "timeline") {
      setTab("timeline");
    }
  }, []);

  useEffect(() => {
    applyHashRoute();
    window.addEventListener("hashchange", applyHashRoute);
    return () => window.removeEventListener("hashchange", applyHashRoute);
  }, [applyHashRoute]);

  useEffect(() => {
    refreshCore();
  }, [refreshCore]);

  useEffect(() => {
    if (!selectedEpId) {
      setSelectedEp(null);
      return;
    }
    api.episode(selectedEpId).then(setSelectedEp).catch(() => setSelectedEp(null));
  }, [selectedEpId]);

  useEffect(() => {
    if (tab === "projects" && selectedProj) {
      api.projectState(selectedProj).then(setProjectState).catch((e) => flash((e as Error).message, true));
    }
  }, [tab, selectedProj, flash]);

  useEffect(() => {
    if (tab === "curator") {
      Promise.all([api.curationRules(), api.curationQueue()])
        .then(([r, q]) => {
          setCurationRules(r);
          setCurationQueue(q);
        })
        .catch((e) => flash((e as Error).message, true));
    } else if (tab === "markdown") {
      api
        .markdownList()
        .then((res) => {
          setMdRoot(res.root);
          setMdFiles(res.items);
          if (res.items.length > 0 && !selectedMd) {
            setSelectedMd(res.items[0].path);
          }
        })
        .catch((e) => flash((e as Error).message, true));
    } else if (tab === "channels") {
      Promise.all([api.privacyRules(), api.collectors()])
        .then(([pr, col]) => {
          setPrivacyRules(pr.items);
          setCollectors(col.items);
        })
        .catch((e) => flash((e as Error).message, true));
    }
  }, [tab, selectedMd, flash]);

  useEffect(() => {
    if (!selectedMd) return;
    api.markdownFile(selectedMd).then(setMdContent).catch(() => setMdContent("读取文件失败"));
  }, [selectedMd]);

  useEffect(() => {
    const trimmed = query.trim();
    if (!trimmed) {
      setSearchRes(null);
      return;
    }
    const timer = setTimeout(() => {
      api
        .search(trimmed, sourceFilter || undefined)
        .then(setSearchRes)
        .catch((e) => flash((e as Error).message, true));
    }, 180);
    return () => clearTimeout(timer);
  }, [query, sourceFilter, flash]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "/" && document.activeElement?.tagName !== "INPUT" && document.activeElement?.tagName !== "TEXTAREA") {
        e.preventDefault();
        setTab("timeline");
        searchInputRef.current?.focus();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const handleSeedDemo = async () => {
    try {
      await api.seedDemo();
      flash("已载入跨渠道合成示例（录音 + 浏览器 + 剪贴板 + AI 对话 + 微信），含自动链接与双时序决策。");
      setSelectedEpId(null);
      setSelectedProj(null);
      await refreshCore();
    } catch (e) {
      flash((e as Error).message, true);
    }
  };

  const handleCreateEvent = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      const now = Date.now();
      const res = await api.createEvent({
        source: draftEvent.source,
        kind: draftEvent.source === "clipboard" ? "copy" : draftEvent.source === "browser" ? "page_read" : "note",
        t_start: now,
        t_end: now,
        actor: "self",
        project: draftEvent.project.trim() || undefined,
        content: { title: draftEvent.title.trim(), text: draftEvent.text.trim() },
        provenance: { connector: "workbench-manual", source_id: `manual-${now}`, locator: `workbench://manual/${now}` },
        privacy: { tier: draftEvent.tier },
      });
      setShowNewEvent(false);
      setDraftEvent({ ...draftEvent, title: "", text: "" });
      setSelectedEpId(res.episode_id);
      flash("已写入 L0 原档并建立 FTS5 索引与情景归组。");
      await refreshCore();
    } catch (err) {
      flash((err as Error).message, true);
    }
  };

  const handlePrivacyChange = async (rawId: string, tier: PrivacyTier) => {
    try {
      await api.patchPrivacy(rawId, tier);
      flash(`已更新记录 ${rawId.slice(-8)} 权限为「${TIER_LABELS[tier]}」，关联情景/决策已同步重算。`);
      if (selectedEpId) {
        setSelectedEp(await api.episode(selectedEpId));
      }
      await refreshCore();
    } catch (e) {
      flash((e as Error).message, true);
    }
  };

  const handleDeleteRaw = async (rawId: string) => {
    if (!window.confirm("确认彻底删除此条原始记录？删除后 L0 会写入墓碑，重放也不会恢复。")) return;
    try {
      await api.deleteEvent(rawId);
      flash("已删除该原始记录并清理 FTS5 索引。");
      if (selectedEpId) {
        api.episode(selectedEpId).then(setSelectedEp).catch(() => setSelectedEp(null));
      }
      await refreshCore();
    } catch (e) {
      flash((e as Error).message, true);
    }
  };

  const handleAddRule = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newRule.match_value.trim()) return;
    try {
      await api.savePrivacyRule(newRule);
      setNewRule({ ...newRule, match_value: "", description: "" });
      const pr = await api.privacyRules();
      setPrivacyRules(pr.items);
      flash("已保存隐私策略规则。");
    } catch (err) {
      flash((err as Error).message, true);
    }
  };

  const mcpSnippet = `{
  "mcpServers": {
    "context_hub": {
      "command": "uv",
      "args": ["run", "--project", "<repo-path>", "context-hub", "mcp"]
    }
  }
}`;

  return (
    <div className="shell">
      <aside className="rail">
        <div className="brand">
          <span className="seal" aria-hidden="true">
            <i />
            <i />
            <i />
          </span>
          <div className="brand-text">
            <strong>Context OS</strong>
            <span>Hub v2 · Agent-as-Curator</span>
          </div>
        </div>

        <nav className="nav-group" aria-label="主导航">
          <div className="nav-label">工作台</div>
          <button className={`nav-btn ${tab === "timeline" ? "active" : ""}`} onClick={() => setTab("timeline")}>
            <Activity size={16} /> 时间线与情景
            {stats ? <span className="nav-badge">{stats.episodes_total}</span> : null}
          </button>
          <button className={`nav-btn ${tab === "projects" ? "active" : ""}`} onClick={() => setTab("projects")}>
            <FolderGit2 size={16} /> 项目与决策
            {stats ? <span className="nav-badge">{stats.decisions_active}</span> : null}
          </button>
          <button className={`nav-btn ${tab === "curator" ? "active" : ""}`} onClick={() => setTab("curator")}>
            <Bot size={16} /> Agent 整理台
            {stats && stats.episodes_pending_curation > 0 ? (
              <span className="nav-badge">{stats.episodes_pending_curation}</span>
            ) : null}
          </button>
          <button className={`nav-btn ${tab === "markdown" ? "active" : ""}`} onClick={() => setTab("markdown")}>
            <FileText size={16} /> Markdown 产物
            {stats ? <span className="nav-badge">{stats.markdown_files}</span> : null}
          </button>
        </nav>

        <nav className="nav-group" aria-label="系统与安全">
          <div className="nav-label">接入与安全</div>
          <button className={`nav-btn ${tab === "channels" ? "active" : ""}`} onClick={() => setTab("channels")}>
            <Shield size={16} /> 渠道与隐私策略
          </button>
          <button className={`nav-btn ${tab === "vault" ? "active" : ""}`} onClick={() => setTab("vault")}>
            <Lock size={16} /> Context Vault
          </button>
        </nav>

        <div className="rail-foot">
          <div className="status-dot-row">
            <span className="dot" />
            <span>本机 Hub v2 运行中</span>
          </div>
          <span className="mono">127.0.0.1:8741 · L0→L4</span>
        </div>
      </aside>

      <main className="main">
        {notice && (
          <div className={`toast ${notice.err ? "error" : ""}`}>
            <span>{notice.msg}</span>
            <button className="btn small" onClick={() => setNotice(null)}>
              关闭
            </button>
          </div>
        )}

        {/* ==================== TIMELINE TAB ==================== */}
        {tab === "timeline" && (
          <>
            <header className="topbar">
              <div>
                <h1>时间线与情景</h1>
                <p>L0 不可变原档 → L1 FTS5 毫秒检索与跨源链接 → L2 情景与 Markdown 产物。</p>
              </div>
              <div className="top-actions">
                <button className="btn" onClick={handleSeedDemo}>
                  <Sparkles size={15} /> 载入跨渠道示例
                </button>
                <button className="btn" onClick={refreshCore} disabled={loading}>
                  <RefreshCw size={15} /> 刷新
                </button>
                <button className="btn primary" onClick={() => setShowNewEvent(true)}>
                  <Plus size={15} /> 录入记录
                </button>
              </div>
            </header>

            {stats && (
              <div className="kpi-grid">
                <div className="kpi">
                  <div className="kpi-label">L0/L1 原始记录</div>
                  <div className="kpi-val mono">{stats.raw_total}</div>
                  <div className="kpi-sub">Agent 可见 {stats.raw_agent_visible} 条</div>
                </div>
                <div className="kpi">
                  <div className="kpi-label">跨源确定性链接</div>
                  <div className="kpi-val mono">{stats.links_total}</div>
                  <div className="kpi-sub">copy_of · during · anchor</div>
                </div>
                <div className="kpi">
                  <div className="kpi-label">待 Agent 整理情景</div>
                  <div className="kpi-val mono" style={{ color: stats.episodes_pending_curation ? "var(--signal)" : undefined }}>
                    {stats.episodes_pending_curation}
                  </div>
                  <div className="kpi-sub">共 {stats.episodes_total} 个情景</div>
                </div>
                <div className="kpi">
                  <div className="kpi-label">生效项目决策</div>
                  <div className="kpi-val mono">{stats.decisions_active}</div>
                  <div className="kpi-sub">已生成 {stats.markdown_files} 份 .md</div>
                </div>
              </div>
            )}

            <section className="panel">
              <div className="toolbar">
                <div className="search-box">
                  <Search size={15} color="var(--muted)" />
                  <input
                    ref={searchInputRef}
                    value={query}
                    onChange={(e) => setQuery(e.target.value)}
                    placeholder="全局中英文 FTS5 检索决策、情景、记忆与原文…（按 / 聚焦）"
                  />
                  {query && (
                    <button className="btn small" onClick={() => setQuery("")}>
                      清除
                    </button>
                  )}
                </div>
                <div className="pill-row">
                  {["", "ai_chat", "clipboard", "browser", "wechat", "voice", "window"].map((src) => (
                    <button
                      key={src || "all"}
                      className={`pill ${sourceFilter === src ? "active" : ""}`}
                      onClick={() => setSourceFilter(src)}
                    >
                      {src ? SOURCE_LABELS[src] || src : "全部渠道"}
                    </button>
                  ))}
                </div>
              </div>

              {searchRes ? (
                <div style={{ padding: 20 }}>
                  <div className="row-head" style={{ marginBottom: 14 }}>
                    <strong>检索「{searchRes.query}」结果</strong>
                    <span className="mono">
                      决策 {searchRes.decisions.length} · 情景 {searchRes.episodes.length} · 记忆 {searchRes.memories.length} · 原文 {searchRes.raw_matches.length}
                    </span>
                  </div>
                  {searchRes.decisions.length > 0 && (
                    <div className="section" style={{ marginTop: 0, paddingTop: 0, borderTop: 0 }}>
                      <h3>命中的项目决策</h3>
                      {searchRes.decisions.map((d) => (
                        <div key={d.id} className="ev-card">
                          <div className="ev-meta">
                            <span className={`badge ${d.status === "active" ? "ok" : "warn"}`}>{d.status}</span>
                            <span className="badge signal">{AUTHORITY_LABELS[d.authority] || d.authority}</span>
                            <strong>{d.project} · {d.topic}</strong>
                          </div>
                          <div className="ev-body">{d.statement}</div>
                        </div>
                      ))}
                    </div>
                  )}
                  {searchRes.raw_matches.length > 0 ? (
                    <div className="section">
                      <h3>命中的原始证据</h3>
                      {searchRes.raw_matches.map((r) => (
                        <div key={r.id} className="ev-card">
                          <div className="ev-meta">
                            <span className="badge">{SOURCE_LABELS[r.source] || r.source}</span>
                            <strong>{r.title}</strong>
                            <span className="mono">{fmtTime(r.t_start)}</span>
                          </div>
                          <div className="ev-body">{r.snippet}</div>
                          <div className="ev-foot">
                            <span className="mono">{r.id} · {r.locator}</span>
                            {r.episode_id && (
                              <button
                                className="btn small"
                                onClick={() => {
                                  setQuery("");
                                  setSelectedEpId(r.episode_id!);
                                }}
                              >
                                打开所属情景
                              </button>
                            )}
                          </div>
                        </div>
                      ))}
                    </div>
                  ) : (
                    searchRes.decisions.length === 0 && <div className="empty">未找到匹配记录。</div>
                  )}
                </div>
              ) : episodes.length === 0 ? (
                <div className="empty">
                  <Sparkles size={28} />
                  <strong>还没有上下文记录</strong>
                  <span>你可以点击右上角「载入跨渠道示例」立即体验，或手动录入第一条记录。</span>
                  <button className="btn signal" onClick={handleSeedDemo}>
                    一键载入跨渠道示例
                  </button>
                </div>
              ) : (
                <div className="split">
                  <div className="list-col">
                    {episodes.map((ep) => (
                      <button
                        key={ep.id}
                        className={`row-card ${selectedEpId === ep.id ? "active" : ""}`}
                        onClick={() => setSelectedEpId(ep.id)}
                      >
                        <div className="row-head">
                          <span className={`badge ${ep.status === "curated" ? "ok" : "signal"}`}>
                            {ep.status === "curated" ? "已整理" : ep.status === "manual" ? "人工定稿" : "待 Agent 整理"}
                          </span>
                          <span className="mono">{fmtTime(ep.t_end)}</span>
                        </div>
                        <div className="row-title">{ep.title}</div>
                        <div className="row-preview">
                          {ep.summary || `${SOURCE_LABELS[ep.primary_source] || ep.primary_source} · ${ep.event_count} 条原档`}
                        </div>
                        <div className="row-head">
                          <span>{ep.project ? `#${ep.project}` : "未归属项目"}</span>
                          <span className="mono">{ep.event_count} 条 · {TIER_LABELS[ep.privacy_tier]}</span>
                        </div>
                      </button>
                    ))}
                  </div>

                  <div className="detail-col">
                    {selectedEp ? (
                      <>
                        <div className="ev-meta">
                          <span className={`badge ${selectedEp.status === "curated" ? "ok" : "signal"}`}>
                            {selectedEp.status === "curated" ? `已由 ${selectedEp.curated_by} 整理` : "等待 Agent 整理"}
                          </span>
                          {selectedEp.project && <span className="badge">项目：{selectedEp.project}</span>}
                          <span className="badge">{TIER_LABELS[selectedEp.privacy_tier]}</span>
                          <span className="mono">{fmtTime(selectedEp.t_start)} ~ {fmtTime(selectedEp.t_end)}</span>
                        </div>
                        <h2>{selectedEp.title}</h2>
                        {selectedEp.summary ? (
                          <p style={{ margin: "6px 0 12px" }}>{selectedEp.summary}</p>
                        ) : (
                          <p style={{ margin: "6px 0 12px", color: "var(--muted)" }}>
                            此情景尚未经过 Agent-as-Curator 整理。可前往「Agent 整理台」让 Antigravity / Codex / WorkBuddy 拉取归纳。
                          </p>
                        )}
                        {selectedEp.entities.length > 0 && (
                          <div className="pill-row" style={{ marginBottom: 10 }}>
                            {selectedEp.entities.map((ent) => (
                              <span key={ent} className="badge">
                                {ent}
                              </span>
                            ))}
                          </div>
                        )}
                        {selectedEp.overview && (
                          <div className="section">
                            <h3>整理详述</h3>
                            <div className="ev-body">{selectedEp.overview}</div>
                          </div>
                        )}

                        {selectedEp.links && selectedEp.links.length > 0 && (
                          <div className="section">
                            <h3>跨渠道确定性链接 ({selectedEp.links.length})</h3>
                            {selectedEp.links.map((lk, idx) => (
                              <div key={lk.id || idx} className="ev-meta" style={{ padding: "5px 0" }}>
                                <Link2 size={14} color="var(--signal)" />
                                <span className="badge signal">{lk.relation}</span>
                                <span className="mono">{lk.src_id.slice(-10)} → {lk.dst_id.slice(-10)}</span>
                                <span>{lk.evidence}</span>
                                <span className="mono">({Math.round(lk.confidence * 100)}%)</span>
                              </div>
                            ))}
                          </div>
                        )}

                        <div className="section">
                          <h3>L0 原始证据流 ({selectedEp.events?.length || 0})</h3>
                          {(selectedEp.events || []).map((ev) => (
                            <div key={ev.id} className="ev-card">
                              <div className="ev-meta">
                                <span className="badge">{SOURCE_LABELS[ev.source] || ev.source}</span>
                                <span>{ev.actor || "unknown"}</span>
                                <span className="mono">{fmtTime(ev.t_start)}</span>
                                <select
                                  aria-label="修改可见范围"
                                  value={ev.privacy.tier}
                                  onChange={(e) => handlePrivacyChange(ev.id, e.target.value as PrivacyTier)}
                                  style={{
                                    marginLeft: "auto",
                                    fontSize: 12,
                                    padding: "2px 6px",
                                    borderRadius: 6,
                                    border: "1px solid var(--rule)",
                                    background: "var(--surface)",
                                  }}
                                >
                                  <option value="shareable">Agent 可见</option>
                                  <option value="redacted">已脱敏可见</option>
                                  <option value="local_only">仅本机私密</option>
                                </select>
                                <button
                                  className="btn small danger"
                                  onClick={() => handleDeleteRaw(ev.id)}
                                  title="删除此原始记录"
                                >
                                  <Trash2 size={13} />
                                </button>
                              </div>
                              <div className="ev-body">{ev.body_text || ev.title}</div>
                              <div className="ev-foot">
                                <span className="mono">{ev.id}</span>
                                <span className="mono">{ev.locator}</span>
                              </div>
                            </div>
                          ))}
                        </div>
                      </>
                    ) : (
                      <div className="empty">选择左侧情景查看跨源证据链</div>
                    )}
                  </div>
                </div>
              )}
            </section>
          </>
        )}

        {/* ==================== PROJECTS & DECISIONS TAB ==================== */}
        {tab === "projects" && (
          <>
            <header className="topbar">
              <div>
                <h1>项目与双时序决策台账</h1>
                <p>区分「用户拍板」与「助手提议」；推翻旧方案时以 superseded_by 保留完整变更史。</p>
              </div>
              <button className="btn" onClick={refreshCore}>
                <RefreshCw size={15} /> 刷新
              </button>
            </header>

            {projects.length === 0 ? (
              <div className="panel empty">暂无项目数据，请先在时间线载入示例或接入渠道。</div>
            ) : (
              <div className="panel split">
                <div className="list-col">
                  {projects.map((p) => (
                    <button
                      key={p.project}
                      className={`row-card ${selectedProj === p.project ? "active" : ""}`}
                      onClick={() => setSelectedProj(p.project)}
                    >
                      <div className="row-title">{p.project}</div>
                      <div className="row-head">
                        <span className="badge ok">{p.active_decisions} 条生效决策</span>
                        {p.pending_curation > 0 && <span className="badge signal">{p.pending_curation} 待整理</span>}
                      </div>
                      <div className="row-head">
                        <span className="mono">{p.event_count} 条原档 · {p.episode_count} 情景</span>
                        <span className="mono">{fmtTime(p.last_activity_ms)}</span>
                      </div>
                    </button>
                  ))}
                </div>
                <div className="detail-col">
                  {projectState ? (
                    <>
                      <h2>{projectState.project}</h2>
                      <div className="section">
                        <h3>当前生效决策 ({projectState.active_decisions.length})</h3>
                        {projectState.active_decisions.length === 0 ? (
                          <p style={{ color: "var(--muted)" }}>暂无已整理的生效决策。</p>
                        ) : (
                          projectState.active_decisions.map((d) => (
                            <div key={d.id} className="ev-card">
                              <div className="ev-meta">
                                <span className="badge ok">生效中</span>
                                <span className="badge signal">{AUTHORITY_LABELS[d.authority] || d.authority}</span>
                                <strong>{d.topic}</strong>
                                <span className="mono">{fmtTime(d.valid_at)}</span>
                              </div>
                              <div className="ev-body">{d.statement}</div>
                              <div className="ev-foot">
                                <span className="mono">证据：{d.evidence_ids.join(", ")}</span>
                                <span className="mono">整理者：{d.curated_by || "manual"}</span>
                              </div>
                            </div>
                          ))
                        )}
                      </div>

                      {projectState.superseded_decisions.length > 0 && (
                        <div className="section">
                          <h3>历史已被取代的决策 ({projectState.superseded_decisions.length})</h3>
                          {projectState.superseded_decisions.map((d) => (
                            <div key={d.id} className="ev-card" style={{ opacity: 0.72 }}>
                              <div className="ev-meta">
                                <span className="badge warn">已取代</span>
                                <span>{d.topic}</span>
                                <span className="mono">→ {d.superseded_by}</span>
                              </div>
                              <div className="ev-body" style={{ textDecoration: "line-through" }}>
                                {d.statement}
                              </div>
                            </div>
                          ))}
                        </div>
                      )}

                      {projectState.memories.length > 0 && (
                        <div className="section">
                          <h3>项目记忆 ({projectState.memories.length})</h3>
                          {projectState.memories.map((m) => (
                            <div key={m.id} className="ev-card">
                              <div className="ev-meta">
                                <span className="badge">{m.kind}</span>
                                <strong>{m.title}</strong>
                              </div>
                              <div className="ev-body">{m.body}</div>
                            </div>
                          ))}
                        </div>
                      )}
                    </>
                  ) : (
                    <div className="empty">选择左侧项目查看决策与演进历史</div>
                  )}
                </div>
              </div>
            )}
          </>
        )}

        {/* ==================== AGENT CURATOR TAB ==================== */}
        {tab === "curator" && (
          <>
            <header className="topbar">
              <div>
                <h1>Agent 整理台 · Agent-as-Curator</h1>
                <p>不消耗额外 API Key，把整理规则与待处理队列通过 MCP 暴露给你的 Antigravity / Codex / WorkBuddy。</p>
              </div>
              <div className="pill-row">
                {(["antigravity", "codex", "workbuddy"] as const).map((h) => (
                  <button
                    key={h}
                    className={`pill ${curatorHost === h ? "active" : ""}`}
                    onClick={() => setCuratorHost(h)}
                  >
                    {h === "antigravity" ? "Antigravity" : h === "codex" ? "Codex" : "WorkBuddy"}
                  </button>
                ))}
              </div>
            </header>

            <div className="grid-2" style={{ marginBottom: 16 }}>
              <div className="card">
                <div className="row-head" style={{ marginBottom: 8 }}>
                  <h3>一键复制整理指令（交给 {curatorHost}）</h3>
                  <button
                    className="btn small signal"
                    onClick={() => copyText("prompt", curationRules?.prompts[curatorHost] || "")}
                  >
                    {copiedKey === "prompt" ? <Check size={13} /> : <Copy size={13} />}
                    {copiedKey === "prompt" ? "已复制" : "复制提示词"}
                  </button>
                </div>
                <div className="code-block">{curationRules?.prompts[curatorHost] || "加载中…"}</div>
              </div>

              <div className="card">
                <div className="row-head" style={{ marginBottom: 8 }}>
                  <h3>MCP 接入配置（stdio）</h3>
                  <button className="btn small" onClick={() => copyText("mcp", mcpSnippet)}>
                    {copiedKey === "mcp" ? <Check size={13} /> : <Copy size={13} />}
                    {copiedKey === "mcp" ? "已复制" : "复制配置"}
                  </button>
                </div>
                <div className="code-block">{mcpSnippet}</div>
                <p style={{ fontSize: 12, color: "var(--muted)", marginTop: 10 }}>
                  支持交互式调用，也可用 Antigravity <code>/schedule</code> 或 <code>codex exec</code> 在夜间自动巡检整理待处理队列。
                </p>
              </div>
            </div>

            <div className="grid-2">
              <div className="card">
                <h3>待整理队列 ({curationQueue?.total_pending ?? 0})</h3>
                {curationQueue && curationQueue.items.length > 0 ? (
                  curationQueue.items.map((item) => (
                    <div key={item.episode.id} className="ev-card">
                      <div className="ev-meta">
                        <span className="badge signal">待整理</span>
                        <strong>{item.episode.title}</strong>
                        <span className="mono">{item.events.length} 条证据</span>
                      </div>
                      <div className="ev-foot">
                        <span>项目：{item.episode.project || "未归属"}</span>
                        <span className="mono">已有生效决策：{item.existing_project_decisions.length}</span>
                      </div>
                    </div>
                  ))
                ) : (
                  <p style={{ color: "var(--muted)" }}>当前没有待整理的情景，队列已清空。</p>
                )}
              </div>

              <div className="card">
                <h3>整理规则原文（skills/context-curator/SKILL.md）</h3>
                <div className="code-block">{curationRules?.rules_markdown || "加载中…"}</div>
              </div>
            </div>
          </>
        )}

        {/* ==================== MARKDOWN ARTIFACTS TAB ==================== */}
        {tab === "markdown" && (
          <>
            <header className="topbar">
              <div>
                <h1>L2 Markdown 产物库</h1>
                <p>带 YAML Frontmatter 的人机共读档案，可直接作为 Obsidian Vault 目录打开。</p>
              </div>
              {mdRoot && (
                <button className="btn" onClick={() => copyText("mdroot", mdRoot)}>
                  {copiedKey === "mdroot" ? <Check size={14} /> : <Copy size={14} />}
                  <span className="mono">{mdRoot}</span>
                </button>
              )}
            </header>

            {mdFiles.length === 0 ? (
              <div className="panel empty">尚未生成 Markdown 产物。完成一次整理或载入示例后将自动产出。</div>
            ) : (
              <div className="panel split">
                <div className="list-col">
                  {mdFiles.map((f) => (
                    <button
                      key={f.path}
                      className={`row-card ${selectedMd === f.path ? "active" : ""}`}
                      onClick={() => setSelectedMd(f.path)}
                    >
                      <div className="row-head">
                        <span className="badge">{f.category}</span>
                        <span className="mono">{f.size_bytes} B</span>
                      </div>
                      <div className="row-title mono" style={{ fontSize: 12.5 }}>
                        {f.path}
                      </div>
                    </button>
                  ))}
                </div>
                <div className="detail-col">
                  <div className="code-block" style={{ maxHeight: "64vh" }}>
                    {mdContent}
                  </div>
                </div>
              </div>
            )}
          </>
        )}

        {/* ==================== CHANNELS & PRIVACY TAB ==================== */}
        {tab === "channels" && (
          <>
            <header className="topbar">
              <div>
                <h1>渠道接入与隐私策略</h1>
                <p>用渠道/项目/域名规则自动控制 Agent 可见性，高熵密钥与密码管理器硬防火墙永不放行。</p>
              </div>
            </header>

            <div className="kpi-grid">
              {(["ai_chat", "clipboard", "browser", "wechat", "voice", "window"] as const).map((src) => {
                const count = stats?.by_source[src] || 0;
                const live = collectors.find((c) => c.source === src);
                return (
                  <div key={src} className="kpi">
                    <div className="row-head">
                      <span>{SOURCE_LABELS[src]}</span>
                      <span className={`badge ${live?.status === "ok" || count > 0 ? "ok" : ""}`}>
                        {live?.status || (count > 0 ? "已有数据" : "待接采集器")}
                      </span>
                    </div>
                    <div className="kpi-val mono">{count}</div>
                    <div className="kpi-sub">{live?.message || `source=${src}`}</div>
                  </div>
                );
              })}
            </div>

            <div className="grid-2">
              <div className="card">
                <h3>当前生效隐私规则 ({privacyRules.length})</h3>
                {privacyRules.map((r) => (
                  <div key={r.id} className="ev-card" style={{ display: "flex", alignItems: "center", gap: 10 }}>
                    <span className="badge">{r.scope}</span>
                    <strong className="mono">{r.match_value}</strong>
                    <span className={`badge ${r.default_tier === "local_only" ? "warn" : "ok"}`}>
                      {TIER_LABELS[r.default_tier]}
                    </span>
                    <span style={{ fontSize: 12, color: "var(--muted)", flex: 1 }}>{r.description}</span>
                    <button
                      className="btn small danger"
                      onClick={async () => {
                        await api.deletePrivacyRule(r.id);
                        setPrivacyRules((await api.privacyRules()).items);
                      }}
                    >
                      <Trash2 size={13} />
                    </button>
                  </div>
                ))}
              </div>

              <div className="card">
                <h3>新增 / 覆盖隐私规则</h3>
                <form className="form-grid" onSubmit={handleAddRule}>
                  <div className="form-row">
                    <div className="field">
                      <label>匹配维度</label>
                      <select
                        value={newRule.scope}
                        onChange={(e) => setNewRule({ ...newRule, scope: e.target.value as PrivacyRule["scope"] })}
                      >
                        <option value="project">项目 (project)</option>
                        <option value="source">渠道 (source)</option>
                        <option value="domain">网页域名 (domain)</option>
                        <option value="connector">连接器 (connector)</option>
                      </select>
                    </div>
                    <div className="field">
                      <label>默认权限</label>
                      <select
                        value={newRule.default_tier}
                        onChange={(e) => setNewRule({ ...newRule, default_tier: e.target.value as PrivacyTier })}
                      >
                        <option value="shareable">Agent 可见</option>
                        <option value="redacted">已脱敏可见</option>
                        <option value="local_only">仅本机私密</option>
                      </select>
                    </div>
                  </div>
                  <div className="field">
                    <label>匹配值（例如工作微信群项目名 work-group 或域名）</label>
                    <input
                      value={newRule.match_value}
                      onChange={(e) => setNewRule({ ...newRule, match_value: e.target.value })}
                      placeholder="例如：context-os 或 internal.company.com"
                      required
                    />
                  </div>
                  <div className="field">
                    <label>规则说明</label>
                    <input
                      value={newRule.description}
                      onChange={(e) => setNewRule({ ...newRule, description: e.target.value })}
                      placeholder="便于日后核对的简短说明"
                    />
                  </div>
                  <button type="submit" className="btn primary">
                    保存隐私规则
                  </button>
                </form>
              </div>
            </div>
          </>
        )}

        {/* ==================== VAULT TAB ==================== */}
        {tab === "vault" && (
          <>
            <header className="topbar">
              <div>
                <h1>Context Vault v2 · 私密资料与安全代办</h1>
                <p>独立逐条 AES-256-GCM 加密库，明文永不进入 Hub 数据库，仅向 Hub 回写脱敏审计回执。</p>
              </div>
              <span className="badge signal">Phase 4 主线接入</span>
            </header>
            <div className="grid-2">
              <div className="card">
                <h3>为什么重构 Vault v2？</h3>
                <p style={{ color: "var(--muted)" }}>
                  旧版单文件 64 MiB 密文与吞掉响应体的固定 URL 代理难以满足日常工作。v2 将在同一工作台内提供：
                </p>
                <ul>
                  <li>逐条加密存储 + 分块证件附件 + macOS Keychain / Touch ID 流畅解锁</li>
                  <li>保留 RFC 9180 HPKE 手机端扫描投递与本地/Gmail/SSH 发现收件箱</li>
                  <li><strong>域名白名单 HTTP 凭据代理</strong>（防密钥回显脱敏后返回真实业务响应）</li>
                  <li><strong>本机 CLI 安全注入</strong>（<code>context-vault run</code> 审批后临时注入环境变量）</li>
                </ul>
              </div>
              <div className="card">
                <h3>与 Context Hub 的安全边界</h3>
                <p style={{ color: "var(--muted)" }}>
                  Vault 解锁密钥与加密文件保存在独立目录。每次 Agent 发起的凭据或证件使用申请都在此页面弹窗/卡片审批，执行后仅把操作类型、别名、时间与结果写入 Hub 时间线。
                </p>
              </div>
            </div>
          </>
        )}
      </main>

      {/* ==================== NEW EVENT MODAL ==================== */}
      {showNewEvent && (
        <div className="modal-backdrop" onClick={() => setShowNewEvent(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <div className="modal-head">
              <h2>录入原始记录（写入 L0 原档）</h2>
              <button className="btn small" onClick={() => setShowNewEvent(false)}>
                关闭
              </button>
            </div>
            <form className="form-grid" onSubmit={handleCreateEvent}>
              <div className="form-row">
                <div className="field">
                  <label>来源渠道</label>
                  <select
                    value={draftEvent.source}
                    onChange={(e) => setDraftEvent({ ...draftEvent, source: e.target.value })}
                  >
                    <option value="ai_chat">AI 对话</option>
                    <option value="clipboard">剪贴板</option>
                    <option value="browser">浏览器</option>
                    <option value="wechat">微信</option>
                    <option value="voice">录音</option>
                    <option value="window">窗口焦点</option>
                  </select>
                </div>
                <div className="field">
                  <label>归属项目</label>
                  <input
                    value={draftEvent.project}
                    onChange={(e) => setDraftEvent({ ...draftEvent, project: e.target.value })}
                    placeholder="例如 context-os"
                  />
                </div>
                <div className="field">
                  <label>可见范围</label>
                  <select
                    value={draftEvent.tier}
                    onChange={(e) => setDraftEvent({ ...draftEvent, tier: e.target.value as PrivacyTier })}
                  >
                    <option value="shareable">Agent 可见</option>
                    <option value="redacted">已脱敏可见</option>
                    <option value="local_only">仅本机私密</option>
                  </select>
                </div>
              </div>
              <div className="field">
                <label>标题</label>
                <input
                  value={draftEvent.title}
                  onChange={(e) => setDraftEvent({ ...draftEvent, title: e.target.value })}
                  placeholder="简短标题"
                  required
                />
              </div>
              <div className="field">
                <label>原文内容</label>
                <textarea
                  rows={5}
                  value={draftEvent.text}
                  onChange={(e) => setDraftEvent({ ...draftEvent, text: e.target.value })}
                  placeholder="粘贴或输入原始内容（若包含 API Key 将自动触发防火墙锁定为仅本机）"
                  required
                />
              </div>
              <div style={{ display: "flex", justifyContent: "flex-end", gap: 8 }}>
                <button type="button" className="btn" onClick={() => setShowNewEvent(false)}>
                  取消
                </button>
                <button type="submit" className="btn primary">
                  保存到 Hub
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}
