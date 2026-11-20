"use strict";

const byId = id => document.getElementById(id);
const PAGE_SIZE = 12;
const labels = {memory: "记忆", raw: "原始记录"};
const sources = {voice: "录音", clipboard: "剪贴板", browser: "浏览器", ai_chat: "AI 对话", window: "窗口"};
const kinds = {voice: "transcript_segment", clipboard: "copy", browser: "page_read", ai_chat: "chat_turn", window: "focus"};
const tiers = {local_only: "仅本机", redacted: "已脱敏", shareable: "可共享"};
const origins = {manual: "手动整理", extracted: "自动提取"};
const state = {
  view: "memory", q: "", offset: 0, rows: [], more: false, record: null, selected: null,
  connected: false, cloud: false, token: "", listVersion: 0, detailVersion: 0,
  editor: null, deletion: null, back: null, mobileDetail: false
};
let searchTimer, pickerVersion = 0;

function element(tag, className, value) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (value !== undefined) node.textContent = value;
  return node;
}
function glyph(name, className = "") {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  if (className) svg.setAttribute("class", className);
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(svg.namespaceURI, "use");
  use.setAttribute("href", "#i-" + name);
  svg.append(use);
  return svg;
}
function button(label, run, className = "button", icon = "") {
  const node = element("button", className);
  node.type = "button";
  if (icon) node.append(glyph(icon));
  if (className.includes("icon-button")) { node.title = label; node.setAttribute("aria-label", label); }
  else node.append(document.createTextNode(label));
  node.addEventListener("click", run);
  return node;
}
function notice(message = "", isError = false, action = null) {
  const node = byId("notice");
  node.replaceChildren(document.createTextNode(message));
  node.classList.toggle("error", isError);
  if (action) node.append(action);
  node.hidden = !message;
}
function formError(id, message = "", action = null) {
  const node = byId(id);
  node.textContent = message;
  if (action) node.append(action);
  node.hidden = !message;
}
function setToken(value) {
  state.token = value;
  try {
    if (value) sessionStorage.setItem("context-hub-token", value);
    else sessionStorage.removeItem("context-hub-token");
  } catch { /* The current page can still use its in-memory credential. */ }
}
function authorizationAtStart() {
  const hash = new URLSearchParams(location.hash.slice(1));
  if (hash.has("token")) {
    setToken(hash.get("token").trim());
    history.replaceState(null, "", location.pathname + location.search);
  } else {
    try { state.token = sessionStorage.getItem("context-hub-token") || ""; } catch { /* Optional storage. */ }
  }
}
function connection(status) {
  state.connected = status === "ready";
  byId("connection").dataset.state = status;
  byId("connection-label").textContent = {ready: state.cloud ? "云端服务已连接" : "服务已连接", busy: "正在连接", offline: "未连接"}[status];
  byId("create").disabled = byId("extract").disabled = !state.connected;
}
async function request(path, method = "GET", payload = undefined, credential = state.token) {
  const headers = {Accept: "application/json"};
  if (credential) headers.Authorization = "Bearer " + credential;
  if (payload !== undefined) headers["Content-Type"] = "application/json";
  let response;
  try {
    response = await fetch(path, {method, headers, body: payload === undefined ? undefined : JSON.stringify(payload),
      credentials: "omit", cache: "no-store", redirect: "error"});
  } catch { throw new Error("无法连接服务，请检查服务地址与网络后重试。"); }
  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    const err = new Error(result.error || "服务请求失败（HTTP " + response.status + "）");
    err.status = response.status;
    if (err.status === 401 && credential === state.token) connection("offline");
    throw err;
  }
  return result;
}
function itemPath(view, id) { return "/api/" + view + "/" + encodeURIComponent(id); }
function listPath(view, q, limit, offset = 0) {
  return "/api/" + view + "?" + new URLSearchParams({q, limit, offset});
}
function datetime(value, compact = false) {
  if (value === undefined || value === null || value === "") return "";
  const date = new Date(value);
  if (!Number.isFinite(date.valueOf())) return String(value);
  const two = number => String(number).padStart(2, "0");
  return (compact ? "" : date.getFullYear() + "-") + two(date.getMonth() + 1) + "-" + two(date.getDate())
    + " " + two(date.getHours()) + ":" + two(date.getMinutes());
}
function titleOf(view, record) {
  if (view === "memory") return record.title || record.id;
  return record.content?.title || record.context?.window_title || record.content?.text?.split("\n")[0]
    || record.content?.summary || record.provenance?.source_id || record.id;
}
function bodyOf(view, record) {
  if (view === "memory") return record.body || "";
  return record.content?.text || record.content?.summary || record.content?.excerpts?.map(x => x.text).join("\n\n") || "";
}
function typeOf(view, record) {
  if (view === "memory") return origins[record.origin] || record.origin || labels.memory;
  return Object.hasOwn(sources, record.source) ? sources[record.source] : record.source;
}
function empty(title, explanation, icon, actions = [], compact = false) {
  const box = element("div", "empty" + (compact ? " compact" : ""));
  const mark = element("span", "illustration");
  mark.append(glyph(icon)); box.append(mark, element("h2", "", title), element("p", "", explanation));
  if (actions.length) { const row = element("div", "empty-actions"); row.append(...actions); box.append(row); }
  return box;
}
function accessDialog() {
  byId("token").value = "";
  byId("disconnect").hidden = !state.token;
  formError("access-error");
  if (!byId("access").open) byId("access").showModal();
  byId("token").focus();
}
function disconnected(message = "输入管理令牌，打开你的上下文资料库。") {
  state.rows = []; state.record = null; state.selected = null;
  byId("workspace").replaceChildren(empty("连接上下文服务", message, "key", [button("连接服务", accessDialog, "button", "key")]));
}
function nav(view, options = {}) {
  clearTimeout(searchTimer);
  state.view = view;
  state.q = options.q || ""; state.offset = options.offset || 0;
  state.selected = options.id || null; state.record = null;
  state.mobileDetail = Boolean(options.id);
  if (!options.keepBack) state.back = null;
  byId("search").value = state.q;
  byId("search").setAttribute("aria-label", "搜索" + labels[view]);
  byId("search").placeholder = view === "memory" ? "搜索记忆标题或正文" : "搜索原始记录";
  byId("page-title").textContent = labels[view];
  document.title = labels[view] + " · Context";
  byId("page-description").textContent = view === "memory" ? "查看、整理并回溯已保存的记忆。" : "查看各渠道捕获的内容、时间与来源。";
  byId("create-label").textContent = "新建" + (view === "memory" ? "记忆" : "记录");
  for (const tab of document.querySelectorAll("[data-tab]")) {
    if (tab.dataset.tab === view) tab.setAttribute("aria-current", "page");
    else tab.removeAttribute("aria-current");
  }
  notice();
  return loadList();
}
async function loadList() {
  const version = ++state.listVersion;
  ++state.detailVersion;
  if (!state.token) { connection("offline"); disconnected(); return; }
  const workspace = byId("workspace");
  workspace.setAttribute("aria-busy", "true");
  try {
    const result = await request(listPath(state.view, state.q, PAGE_SIZE + 1, state.offset));
    if (version !== state.listVersion) return;
    connection("ready");
    if (!Array.isArray(result.items)) throw new Error("服务返回了无法识别的列表。");
    if (!result.items.length && state.offset) { state.offset = Math.max(0, state.offset - PAGE_SIZE); return loadList(); }
    state.more = result.items.length > PAGE_SIZE;
    state.rows = result.items.slice(0, PAGE_SIZE);
    if (!state.rows.length && !state.selected) { renderEmpty(); return; }
    state.selected ||= state.rows[0]?.id;
    renderList();
    if (state.selected) await select(state.selected, false);
  } catch (err) {
    if (version !== state.listVersion) return;
    if (err.status === 401) { disconnected(err.message); return; }
    workspace.replaceChildren(empty("未能加载记录", err.message, "refresh", [button("重试", loadList)]));
  } finally { if (version === state.listVersion) workspace.removeAttribute("aria-busy"); }
}
function renderEmpty() {
  let box;
  if (state.q) {
    box = empty("没有匹配的" + labels[state.view], "试试其他关键词，或清除搜索条件。", "search",
      [button("清除搜索", () => nav(state.view))]);
  } else if (state.view === "memory") {
    box = empty("还没有记忆", "先添加一条原始记录，就可以提取记忆，或手动整理并关联来源。", "memory",
      [button("查看原始记录", () => nav("raw"), "button", "raw")]);
  } else {
    box = empty("还没有原始记录", "手动添加一条记录，或通过采集工具导入。", "raw",
      [button("添加第一条记录", () => openEditor("raw"), "button", "plus")]);
  }
  byId("workspace").replaceChildren(box);
}
function pageBy(delta) {
  state.selected = null; state.record = null; state.mobileDetail = false;
  state.offset = Math.max(0, state.offset + delta * PAGE_SIZE);
  loadList();
}
function renderList() {
  const split = element("div", "split" + (state.mobileDetail ? " show-detail" : ""));
  const list = element("section", "list");
  list.setAttribute("aria-label", labels[state.view] + "列表");
  const listHead = element("div", "list-title");
  listHead.append(element("strong", "", state.q ? "搜索结果" : "全部" + labels[state.view]),
    element("span", "", state.view === "memory" ? "按更新时间" : "按事件时间"));
  list.append(listHead);
  const rows = element("ul", "rows");
  for (const row of state.rows) {
    const line = element("li");
    const entry = button("", () => select(row.id, true), "row");
    entry.dataset.id = row.id;
    entry.setAttribute("aria-current", String(row.id === state.selected));
    const tail = element("span", "row-tail");
    tail.append(element("span", "", row.needs_review ? "待复核" : typeOf(state.view, row)),
      element("time", "", datetime(row.updated_at ?? row.t_start, true)));
    const title = titleOf(state.view, row), preview = bodyOf(state.view, row);
    entry.append(element("span", "row-title", title));
    entry.append(element("span", "row-preview", preview && preview !== title ? preview : row.provenance?.connector || row.id));
    entry.append(tail); line.append(entry); rows.append(line);
  }
  list.append(rows);
  const pager = element("div", "pager");
  const range = state.rows.length ? (state.offset + 1) + "–" + (state.offset + state.rows.length) + " 条" : "0 条";
  const prev = button("上一页", () => pageBy(-1), "icon-button prev", "chevron");
  const next = button("下一页", () => pageBy(1), "icon-button", "chevron");
  prev.disabled = !state.offset; next.disabled = !state.more;
  pager.append(element("span", "range", range), prev, next); list.append(pager);
  const detail = element("article", "detail"); detail.id = "detail";
  detail.setAttribute("aria-label", "记录详情"); split.append(list, detail); byId("workspace").replaceChildren(split);
}
async function select(id, mobile) {
  const version = ++state.detailVersion, view = state.view, node = byId("detail");
  if (!node) return;
  state.selected = id;
  if (mobile) state.mobileDetail = true;
  node.parentElement.classList.toggle("show-detail", state.mobileDetail);
  for (const row of document.querySelectorAll(".row")) row.setAttribute("aria-current", String(row.dataset.id === id));
  node.setAttribute("aria-busy", "true");
  node.replaceChildren(element("p", "hint", "正在读取详情…"));
  try {
    const record = await request(itemPath(view, id));
    if (version !== state.detailVersion) return;
    state.record = record;
    renderDetail(node, view, record);
  } catch (err) {
    if (version !== state.detailVersion) return;
    state.record = null;
    if (err.status === 401) { disconnected(err.message); return; }
    node.replaceChildren(empty(err.status === 404 ? "记录已不可用" : "未能读取详情", err.message, "raw",
      [button("返回列表", () => nav(view)), button("重试", () => select(id, true))], true));
  } finally { if (version === state.detailVersion) node.removeAttribute("aria-busy"); }
}
function evidenceLink(id) {
  if (state.view === "memory") state.back = {view: "memory", q: state.q, offset: state.offset, id: state.selected};
  nav("raw", {id, keepBack: true});
}
function addSection(node, title) {
  const section = element("section", "section");
  section.append(element("h3", "", title)); node.append(section);
  return section;
}
function addMetadata(node, pairs) {
  const grid = element("dl");
  for (const [key, value] of pairs) {
    if (value === undefined || value === null || value === "") continue;
    grid.append(element("dt", "", key), element("dd", "", value));
  }
  node.append(grid);
}
function renderDetail(node, view, record) {
  node.replaceChildren();
  const close = () => { state.mobileDetail = false; node.parentElement.classList.remove("show-detail"); };
  node.append(button("返回列表", close, "text-button mobile-back"));
  if (state.back && view === "raw") {
    node.append(button("返回引用此记录的记忆", () => { const back = state.back; nav(back.view, back); }, "text-button"));
  }
  const head = element("div", "body-head"), label = element("span", "meta-label");
  label.append(glyph(view), document.createTextNode(typeOf(view, record)));
  const actions = element("div", "detail-actions");
  actions.append(button("编辑", () => openEditor(view, record), "icon-button", "edit"),
    button("删除", () => askDelete(view, record), "icon-button", "trash")); head.append(label, actions);
  node.append(head, element("h2", "", titleOf(view, record)));
  const meta = element("div", "metadata-line");
  const time = datetime(record.updated_at ?? record.t_start);
  if (time) meta.append(element("span", "", (view === "memory" ? "更新于 " : "发生于 ") + time));
  meta.append(element("span", "mono", "v" + record.revision));
  if (record.needs_review) meta.append(element("span", "", "来源已变更 · 待复核"));
  node.append(meta, element("div", "content", bodyOf(view, record) || "此条目仅有元数据。"));
  if (view === "memory") {
    const ids = record.evidence_ids || [], section = addSection(node, "来源记录 · " + ids.length);
    const refs = element("div", "refs");
    for (const [index, id] of ids.entries()) {
      const ref = button("", () => evidenceLink(id), "ref");
      const caption = element("span", "id", id);
      ref.replaceChildren(glyph("raw"), caption, glyph("arrow", "jump")); refs.append(ref);
      if (index < 6) request(itemPath("raw", id)).then(raw => {
        if (ref.isConnected) {
          caption.className = "";
          caption.textContent = typeOf("raw", raw) + " · " + titleOf("raw", raw);
          ref.title = id;
        }
      }).catch(() => {});
    }
    section.append(refs);
    addMetadata(addSection(node, "记录信息"), [["记忆 ID", record.id], ["创建时间", datetime(record.created_at)]]);
  } else {
    addMetadata(addSection(node, "来源信息"), [["记录 ID", record.id], ["渠道", typeOf(view, record)],
      ["事件类型", record.kind], ["连接器", record.provenance?.connector], ["来源 ID", record.provenance?.source_id],
      ["原始定位", record.provenance?.locator], ["网址", record.content?.url_norm], ["设备", record.device_id],
      ["可见范围", tiers[record.privacy?.tier]], ["记录时间", datetime(record.t_observed)]]);
    if (record.links?.length) {
      const refs = addSection(node, "关联记录");
      for (const link of record.links) refs.append(button(link.relation + " · " + link.target_id, () => evidenceLink(link.target_id), "ref", "link"));
    }
    const details = element("details", "section extra");
    details.append(element("summary", "", "查看完整 JSON"), element("pre", "", JSON.stringify(record, null, 2))); node.append(details);
  }
}

function field(container, name, caption, value = "", options = {}) {
  const label = element("label", "field", caption);
  const control = element(options.tag || "input");
  control.name = name;
  if (options.choices) {
    for (const [key, text] of Object.entries(options.choices)) {
      const option = element("option", "", text); option.value = key; control.append(option);
    }
  }
  if (options.required) control.required = true;
  if (options.rows) control.rows = options.rows;
  if (options.max) control.maxLength = options.max;
  if (options.placeholder) control.placeholder = options.placeholder;
  control.value = value ?? "";
  label.append(control); container.append(label); return control;
}
function rawTemplate() {
  const now = Date.now();
  const random = crypto.getRandomValues(new Uint32Array(2));
  return {source: "clipboard", kind: "copy", t_start: now, t_end: now, t_observed: now,
    content: {}, provenance: {connector: "manual", source_id: "manual-" + now.toString(36) + "-" + random[0].toString(36) + random[1].toString(36)},
    privacy: {tier: state.cloud ? "" : "local_only"}};
}
function evidenceIds(text) { return [...new Set(text.split(/\r?\n/).map(id => id.trim()).filter(Boolean))]; }
function memoryFields(container, draft) {
  field(container, "title", "标题", draft.title, {required: true, max: 512});
  field(container, "body", "正文", draft.body, {tag: "textarea", rows: 5, required: true, max: 65536});
  const ids = field(container, "evidence_ids", "来源记录 ID（每行一条）", (draft.evidence_ids || []).join("\n"),
    {tag: "textarea", rows: 2, required: true, placeholder: "从下方选取记录，或粘贴至少一个 ID"});
  const picker = element("details", "picker");
  const heading = element("summary", "", "查找并添加来源记录");
  const query = element("input"); query.type = "search"; query.placeholder = "搜索原始记录";
  query.setAttribute("aria-label", "查找要关联的原始记录");
  const matches = element("div", "suggestions"); picker.append(heading, query, matches); container.append(picker);
  let debounce;
  async function findSources() {
    const version = ++pickerVersion;
    matches.textContent = "读取中…";
    try {
      const result = await request(listPath("raw", query.value.trim(), 8));
      if (version !== pickerVersion || !picker.isConnected) return;
      matches.replaceChildren();
      for (const row of result.items) {
        const added = evidenceIds(ids.value).includes(row.id);
        const choice = button((added ? "已选 · " : "") + titleOf("raw", row) + " · " + (sources[row.source] || row.source),
          () => {
            ids.value = [...new Set([...evidenceIds(ids.value), row.id])].join("\n");
            ids.setCustomValidity(""); choice.disabled = true; choice.textContent = "已选 · " + titleOf("raw", row);
          }, "");
        choice.disabled = added; choice.title = row.id; matches.append(choice);
      }
      if (!result.items.length) matches.textContent = "没有找到原始记录。";
    } catch (err) { if (version === pickerVersion) matches.textContent = err.message; }
  }
  picker.addEventListener("toggle", () => { if (picker.open) findSources(); });
  query.addEventListener("input", () => { ++pickerVersion; clearTimeout(debounce); debounce = setTimeout(findSources, 180); });
  ids.addEventListener("input", () => { ids.setCustomValidity(""); if (picker.open) findSources(); });
}
function formValues() { return Object.fromEntries(new FormData(byId("editor-form"))); }
function rawFromForm() {
  const draft = structuredClone(state.editor.draft), f = formValues();
  if (state.editor.jsonMode) {
    const event = JSON.parse(f.json);
    if (!event || Array.isArray(event) || typeof event !== "object") throw new Error("请输入一个 JSON 对象。");
    delete event.revision;
    return event;
  }
  draft.source = f.source; draft.kind = f.kind.trim();
  draft.provenance = {...draft.provenance, connector: f.connector.trim(), source_id: f.source_id.trim()};
  draft.privacy = {...draft.privacy, tier: f.tier};
  const content = {...draft.content};
  for (const key of ["title", "text"]) {
    if (f[key] !== "" || Object.hasOwn(content, key)) content[key] = f[key];
  }
  if (Object.keys(content).length || draft.content) draft.content = content;
  return draft;
}
function rawFields(container, draft, jsonMode) {
  const toggle = button(jsonMode ? "返回基本字段" : "编辑完整 JSON", () => {
    try {
      state.editor.draft = rawFromForm();
      state.editor.jsonMode = !state.editor.jsonMode; renderEditor();
    } catch (err) { formError("editor-error", "无法切换：" + err.message); }
  }, "text-button mode-switch");
  if (jsonMode) {
    const area = field(container, "json", "ContextEvent JSON", JSON.stringify(draft, null, 2),
      {tag: "textarea", rows: 15, required: true});
    area.className = "json"; area.spellcheck = false;
    container.append(toggle); return;
  }
  const pair = element("div", "field-pair"); container.append(pair);
  const choicesForSource = {...sources};
  if (draft.source && !Object.hasOwn(sources, draft.source)) choicesForSource[draft.source] = draft.source;
  const source = field(pair, "source", "来源渠道", draft.source, {tag: "select", choices: choicesForSource, required: true});
  const kind = field(pair, "kind", "事件类型", draft.kind, {required: true});
  source.addEventListener("change", () => { kind.value = kinds[source.value] || draft.kind || ""; });
  field(container, "title", "标题", draft.content?.title);
  field(container, "text", "原文", draft.content?.text, {tag: "textarea", rows: 4});
  const provenance = element("div", "field-pair"); container.append(provenance);
  field(provenance, "connector", "连接器", draft.provenance?.connector, {required: true});
  field(provenance, "source_id", "来源 ID", draft.provenance?.source_id, {required: true});
  const choices = state.cloud ? {"": "请选择可同步范围", redacted: tiers.redacted, shareable: tiers.shareable} : tiers;
  field(container, "tier", "隐私范围", draft.privacy?.tier, {tag: "select", choices, required: true});
  container.append(element("p", "hint", state.cloud ? "云端仅接受已脱敏或可共享的记录。" : "仅本机的记录只对所有者可见。Agent 可以读取标记为已脱敏或可共享的记录。"));
  container.append(toggle);
}
function renderEditor() {
  const current = state.editor;
  byId("editor-title").textContent = (current.original ? "编辑" : "新建") + labels[current.view];
  formError("editor-error");
  const container = byId("editor-fields"); container.replaceChildren();
  if (current.view === "raw") rawFields(container, current.draft, current.jsonMode);
  else memoryFields(container, current.draft);
}
function openEditor(view, record = null) {
  const draft = record ? structuredClone(record) : (view === "raw" ? rawTemplate() : {title: "", body: "", evidence_ids: []});
  delete draft.revision;
  state.editor = {view, original: record, draft, jsonMode: false};
  renderEditor();
  if (!byId("editor").open) byId("editor").showModal();
}
async function reloadDraft() {
  const current = state.editor;
  if (!current?.original || !window.confirm("载入服务端最新版本会替换当前未保存的修改。继续吗？")) return;
  try {
    const record = await request(itemPath(current.view, current.original.id));
    if (current === state.editor && byId("editor").open) openEditor(current.view, record);
  } catch (err) { formError("editor-error", err.message); }
}
function busy(dialogId, yes) {
  const dialog = byId(dialogId);
  dialog.dataset.busy = String(yes);
  for (const control of dialog.querySelectorAll('button[type="submit"],[data-close]')) control.disabled = yes;
}
function conflict(err) { return err.status === 409; }
async function saveRecord(e) {
  e.preventDefault();
  if (byId("editor").dataset.busy === "true") return;
  const current = state.editor;
  let payload;
  try {
    if (current.view === "raw") payload = rawFromForm();
    else {
      const f = formValues();
      payload = {title: f.title.trim(), body: f.body.trim(), evidence_ids: evidenceIds(f.evidence_ids)};
      if (!payload.evidence_ids.length) throw new Error("请关联至少一条原始记录。");
      if (payload.evidence_ids.length > 256) throw new Error("最多可关联 256 条原始记录。");
    }
    if (current.original) payload.revision = current.original.revision;
    busy("editor", true); formError("editor-error");
    const record = await request(current.original ? itemPath(current.view, current.original.id) : "/api/" + current.view,
      current.original ? "PUT" : "POST", payload);
    byId("editor").close();
    await nav(current.view, {id: record.id});
    notice("已保存" + labels[current.view] + "。");
  } catch (err) {
    if (conflict(err) && current.original) {
      formError("editor-error", "记录已在其他位置修改。当前草稿仍可复制，载入最新版本后可重新编辑。",
        button("载入最新版本", reloadDraft));
    } else formError("editor-error", err.message);
  } finally { busy("editor", false); }
}
function askDelete(view, record) {
  state.deletion = {view, record};
  byId("delete-title").textContent = "删除这条" + labels[view] + "？";
  byId("delete-description").textContent = "“" + titleOf(view, record) + "”" + (view === "raw" ? " 将被删除，引用它的记忆也会相应更新。" : " 将从记忆库移除，原始记录仍可查阅。");
  formError("delete-error"); byId("confirm-delete").showModal();
}
async function deleteRecord(e) {
  e.preventDefault();
  if (byId("confirm-delete").dataset.busy === "true") return;
  const {view, record} = state.deletion;
  busy("confirm-delete", true); formError("delete-error");
  try {
    await request(itemPath(view, record.id), "DELETE", {revision: record.revision});
    byId("confirm-delete").close();
    await nav(view, {q: state.q, offset: state.offset});
    notice("已删除" + labels[view] + "。");
  } catch (err) {
    if (conflict(err)) formError("delete-error", "这条记录已发生变化，请查看最新内容后重新确认。",
      button("查看最新内容", () => { byId("confirm-delete").close(); nav(view, {id: record.id}); }));
    else formError("delete-error", err.message);
  } finally { busy("confirm-delete", false); }
}
let extracting = false;
async function extract() {
  if (extracting) return;
  extracting = true; byId("extract").disabled = true;
  notice("正在从原始记录提取记忆…");
  try {
    const result = await request("/api/extract", "POST", {});
    await nav("memory");
    const n = (result.created || 0) + (result.updated || 0) + (result.skipped || 0);
    notice(n ? "提取完成，新增 " + result.created + " 条，更新 " + result.updated + " 条，跳过 " + result.skipped + " 条。" : "所有原始记录均已处理。");
  } catch (err) { notice(err.message, true, button("重试", extract, "text-button")); }
  finally { extracting = false; byId("extract").disabled = !state.connected; }
}
async function connect(e) {
  e.preventDefault();
  if (byId("access").dataset.busy === "true") return;
  const value = byId("token").value.trim(); if (!value) return;
  busy("access", true); formError("access-error");
  try {
    await request(listPath("memory", "", 1), "GET", undefined, value);
    setToken(value); byId("access").close(); await nav("memory");
  } catch (err) { formError("access-error", err.message); }
  finally { busy("access", false); }
}
for (const tab of document.querySelectorAll("[data-tab]")) tab.addEventListener("click", () => nav(tab.dataset.tab));
for (const closer of document.querySelectorAll("[data-close]")) closer.addEventListener("click", () => byId(closer.dataset.close).close());
for (const dialog of document.querySelectorAll("dialog")) dialog.addEventListener("cancel", e => {
  if (dialog.dataset.busy === "true") e.preventDefault();
});
byId("editor-form").addEventListener("submit", saveRecord);
byId("delete-form").addEventListener("submit", deleteRecord);
byId("access-form").addEventListener("submit", connect);
byId("connection").addEventListener("click", accessDialog);
byId("disconnect").addEventListener("click", () => {
  setToken(""); byId("access").close(); nav("memory");
});
byId("extract").addEventListener("click", extract);
byId("create").addEventListener("click", () => openEditor(state.view));
byId("refresh").addEventListener("click", () => { notice(); loadList(); });
byId("search").addEventListener("input", () => {
  state.q = byId("search").value.trim(); state.offset = 0;
  state.selected = null; state.record = null; state.mobileDetail = false; state.back = null;
  ++state.listVersion; ++state.detailVersion;
  clearTimeout(searchTimer); searchTimer = setTimeout(loadList, 180);
});
document.addEventListener("keydown", event => {
  if (event.key === "/" && !event.ctrlKey && !event.metaKey && !event.altKey &&
      !document.querySelector("dialog[open]") && !event.target.closest("input,textarea,select")) {
    event.preventDefault(); byId("search").focus();
  }
});
authorizationAtStart();
connection(state.token ? "busy" : "offline");
request("/health", "GET", undefined, "").then(info => {
  state.cloud = info.mode === "cloud";
  if (state.connected) connection("ready");
}).catch(() => {});
nav("memory");
