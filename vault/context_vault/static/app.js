"use strict";

const byId = (id) => document.getElementById(id);
const kinds = {
  document: {
    name: "证照与文件",
    singular: "证件或文件",
    empty: "身份证、营业执照、学位证书或工资证明",
  },
  key: { name: "API 密钥", singular: "API 密钥", empty: "项目使用的 API Key" },
  payment: { name: "支付方式", singular: "支付方式", empty: "由支付钱包保管的卡片别名" },
  profile: { name: "个人信息", singular: "个人信息", empty: "地址、手机号或身份字段" },
  ssh: { name: "SSH 身份", singular: "SSH 身份", empty: "SSH Host 别名或公钥指纹" },
};
const wallets = { "": "未指定", "apple-pay": "Apple Pay", link: "Link", other: "其他钱包" };
const actions = { use_key: "使用凭据", deliver_document: "交付文件", fill_profile: "填写信息" };
const methods = {
  use_key: "GET · Bearer 认证",
  deliver_document: "POST · 文件原文",
  fill_profile: "POST · 纯文本字段",
};
const statuses = {
  pending: "待确认",
  approved: "已授权",
  denied: "已拒绝",
  revoked: "已撤销",
  used: "已使用",
  failed: "执行失败",
  expired: "已到期",
  executing: "执行中",
  consumed: "已使用",
};
const maxFile = 8 * 1024 * 1024;
const allowedMime = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/heic",
  "image/heif",
  "application/pdf",
  "application/octet-stream",
]);
const liveDownloads = new Set();
const state = {
  items: [],
  requests: [],
  inbox: [],
  health: {},
  token: "",
  tab: "library",
  screen: "",
  gate: "",
  version: 0,
};
const sheet = byId("sheet");
let refreshSeq = 0;
let refreshing = false;

function element(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined) el.textContent = text;
  return el;
}
function button(label, handler, classes = "button") {
  const el = element("button", classes, label);
  el.type = "button";
  el.addEventListener("click", handler);
  return el;
}
function mark(kind) {
  const el = element("span", "mark m-" + (kinds[kind] ? kind : "document"));
  el.setAttribute("aria-hidden", "true");
  el.append(element("i"));
  return el;
}
let fieldCount = 0;
function field(parent, label, tag = "input", type = "text") {
  const wrapper = element("label", "field");
  const caption = element("span", "", label);
  caption.id = "field-label-" + ++fieldCount;
  wrapper.append(caption);
  const el = element(tag);
  el.setAttribute("aria-labelledby", caption.id);
  if (tag === "input") el.type = type;
  el.autocomplete = "off";
  el.spellcheck = false;
  wrapper.append(el);
  parent.append(wrapper);
  return el;
}
function hint(parent, text) {
  parent.append(element("p", "hint", text));
}
function meta(parent, rows) {
  const dl = element("dl", "item-meta");
  for (const [label, value] of rows) {
    if (value === undefined || value === null || value === "") continue;
    const line = element("div");
    line.append(element("dt", "", label), element("dd", "", String(value)));
    dl.append(line);
  }
  parent.append(dl);
}
function notice(text) {
  byId("notice").textContent = text;
}
function showDate(input) {
  if (!input) return "";
  const date = new Date(typeof input === "number" && input < 1e12 ? input * 1000 : input);
  return Number.isNaN(date.valueOf())
    ? ""
    : date.toLocaleString("zh-CN", {
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
      });
}
function urlFor(id) {
  return "/api/items/" + encodeURIComponent(id);
}
function requestURL(id, decision) {
  return "/api/requests/" + encodeURIComponent(id) + "/" + decision;
}
class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}
async function api(path, method = "GET", body) {
  const headers = {};
  if (path !== "/health" && state.token) headers.Authorization = "Bearer " + state.token;
  if (body !== undefined) headers["Content-Type"] = "application/json";
  let response;
  try {
    response = await fetch(path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: "no-store",
      redirect: "error",
      credentials: "same-origin",
      referrerPolicy: "no-referrer",
    });
  } catch {
    throw new Error("无法连接到本机 Vault。请检查服务是否正在运行。");
  }
  let data = {};
  try {
    data = await response.json();
  } catch {
    /* HTTP status still describes this response. */
  }
  if (!response.ok) {
    const fallback = {
      401: "管理令牌无效，请重新连接。",
      403: "当前凭据没有操作权限。",
      404: "这条记录已不存在。",
      409: "资料状态已变化，请刷新后重新打开。",
      413: "文件超过容量限制。",
      423: "保险库已锁定，请重新解锁。",
    };
    const detail =
      typeof data.error === "string" ? data.error : typeof data.detail === "string" ? data.detail : "";
    throw new HttpError(
      response.status,
      [fallback[response.status], detail].filter(Boolean).join(" ") || "操作失败，请重试。",
    );
  }
  return data;
}
function wipeSheet() {
  byId("sheet-content").replaceChildren();
  byId("sheet-error").textContent = "";
  state.screen = "";
  state.version++;
}
function closeSheet() {
  if (sheet.open) sheet.close();
  wipeSheet();
}
function showSheet(label, title, kicker) {
  wipeSheet();
  state.screen = label;
  byId("sheet-title").textContent = title;
  byId("sheet-kicker").textContent = kicker;
  if (!sheet.open) sheet.showModal();
  return byId("sheet-content");
}
function resetPrivate() {
  closeSheet();
  state.items = [];
  state.requests = [];
  state.inbox = [];
  byId("item-search").value = "";
  byId("clear-search").hidden = true;
  byId("search-result").textContent = "";
  byId("inbox-banner").replaceChildren();
  byId("groups").replaceChildren();
  byId("requests").replaceChildren();
  byId("request-banner").replaceChildren();
  for (const url of liveDownloads) URL.revokeObjectURL(url);
  liveDownloads.clear();
  notice("");
}
function showGate(mode) {
  resetPrivate();
  state.gate = mode;
  for (const name of ["library", "top-actions", "lock"]) byId(name).hidden = true;
  byId("gate").hidden = false;
  byId("gate-error").textContent = "";
  byId("gate-fields").replaceChildren();
  const copy = {
    connect: ["连接本机保险库", "在 Mac 的「应用程序」中打开 Context Vault，或在终端运行 context-vault open。已有管理令牌也可在此输入。", "连接"],
    setup: [
      "创建保险库",
      "设定独立的解锁口令，并把它保存在安全的地方。恢复加密备份时也需要这份口令。",
      "创建并解锁",
    ],
    unlock: ["解锁保险库", "输入保险库口令，在此设备上访问私密资料。", "解锁"],
    unavailable: ["暂时无法连接", "确认本机 Vault 服务正在运行，然后重试。", "重试"],
  }[mode];
  byId("gate-title").textContent = copy[0];
  byId("gate-info").textContent = copy[1];
  byId("gate-submit").textContent = copy[2];
  const fs = byId("gate-fields");
  if (mode !== "unavailable") {
    const input = field(fs, mode === "connect" ? "管理令牌" : "解锁口令", "input", "password");
    input.id = "gate-value";
    input.required = true;
    input.autocomplete = mode === "setup" ? "new-password" : "off";
    if (mode === "setup") {
      input.minLength = 12;
      input.placeholder = "至少 12 个字符";
      const repeat = field(fs, "确认口令", "input", "password");
      repeat.id = "gate-repeat";
      repeat.required = true;
      repeat.autocomplete = "new-password";
    }
  }
}
function displayTab(tab) {
  state.tab = tab;
  byId("library-view").hidden = tab !== "library";
  byId("requests-view").hidden = tab !== "requests";
  byId("tab-library").setAttribute("aria-pressed", String(tab === "library"));
  byId("tab-requests").setAttribute("aria-pressed", String(tab === "requests"));
}
function itemLabel(item) {
  return String(item.label || kinds[item.kind]?.singular || "资料");
}
function targetHost(target) {
  try {
    return new URL(target).host;
  } catch {
    return "";
  }
}
function renderItems() {
  const grid = byId("groups");
  const rawSearch = byId("item-search").value;
  const normalize = (text) => text.normalize("NFKC").toLowerCase();
  const terms = normalize(rawSearch).trim().split(/\s+/).filter(Boolean);
  let matches = 0;
  byId("clear-search").hidden = !rawSearch;
  grid.replaceChildren();
  for (const [kind, spec] of Object.entries(kinds)) {
    const items = state.items.filter((item) => {
      if (item.kind !== kind) return false;
      if (!terms.length) return true;
      const summary = normalize([itemLabel(item), spec.name, spec.singular, kind].join(" "));
      return terms.every((term) => summary.includes(term));
    });
    if (terms.length && !items.length) continue;
    matches += items.length;
    const section = element("section", "group");
    const header = element("div", "group-head");
    const add = button("+", () => editItem(kind), "plus");
    add.setAttribute("aria-label", "添加" + spec.singular);
    header.append(element("h2", "", spec.name), add);
    section.append(header);
    if (!items.length) section.append(element("span", "empty", spec.empty));
    for (const item of items) {
      const row = button("", () => showItem(item), "row");
      const label = element("span", "row-label");
      const tag = item.target
        ? targetHost(item.target)
        : {
            document: "加密文件",
            key: "密钥已隐藏",
            payment: "钱包别名",
            profile: "字段已隐藏",
            ssh: "公开引用",
          }[kind];
      label.append(element("strong", "", itemLabel(item)), element("small", "", tag));
      row.append(mark(kind), label);
      section.append(row);
    }
    grid.append(section);
  }
  byId("search-result").textContent = !terms.length
    ? ""
    : matches
      ? `找到 ${matches} 项资料`
      : "没有匹配的资料。请试试其他名称或类别。";
}
function renderRequests() {
  const pending = state.requests.filter((r) => r.state === "pending");
  const counter = byId("request-count");
  counter.textContent = String(pending.length);
  counter.hidden = !pending.length;
  const slot = byId("request-banner");
  slot.replaceChildren();
  if (pending.length) {
    const req = pending[0],
      banner = button("", () => showRequest(req), "banner");
    const copy = element("span", "banner-text");
    copy.append(
      element("small", "", pending.length + " 个请求待确认"),
      element("strong", "", (req.agent || "Agent") + " 请求" + (actions[req.operation] || "使用资料")),
    );
    banner.append(element("span", "dot"), copy, element("span", "trailing", "↗"));
    slot.append(banner);
  }
  const box = byId("requests");
  box.replaceChildren();
  if (!state.requests.length) {
    box.append(element("p", "empty", "Agent 发起的使用请求和执行结果会出现在这里。"));
    return;
  }
  for (const req of state.requests) {
    const row = button("", () => showRequest(req), "row request-row"),
      label = element("span", "row-label");
    const suffix = [req.agent, showDate(req.created_at)].filter(Boolean).join(" · ");
    label.append(
      element(
        "strong",
        "",
        (actions[req.operation] || "使用资料") + " · " + (req.label || "资料已移除"),
      ),
      element("small", "", suffix),
    );
    const tag = element("span", "state", statuses[req.state] || req.state);
    tag.dataset.state = req.state;
    row.append(mark(req.kind), label, tag);
    box.append(row);
  }
}
function showOpen() {
  state.gate = "";
  byId("gate").hidden = true;
  byId("gate-fields").replaceChildren();
  for (const name of ["library", "top-actions", "lock"]) byId(name).hidden = false;
  byId("backup").disabled = !state.health.icloud_available;
  byId("backup").title = state.health.icloud_available
    ? "设置自动备份或创建单独的加密快照"
    : "本机未检测到 iCloud Drive";
  displayTab(state.tab);
  renderItems();
  renderRequests();
  renderInbox();
}
async function refresh(quiet = false) {
  const seq = ++refreshSeq;
  try {
    const health = await api("/health");
    if (seq !== refreshSeq) return;
    state.health = health;
    if (!state.token) {
      if (state.gate !== "connect") showGate("connect");
      return;
    }
    if (!health.initialized || !health.unlocked) {
      const next = health.initialized ? "unlock" : "setup";
      if (next !== state.gate) showGate(next);
      return;
    }
    const [items, requests, inbox] = await Promise.all([
      api("/api/items"),
      api("/api/requests"),
      api("/api/inbox"),
    ]);
    if (seq !== refreshSeq) return;
    state.inbox = inbox.items || [];
    state.items = items.items || [];
    state.requests = sortedRequests(requests.items || []);
    showOpen();
    if (!quiet) notice("");
  } catch (error) {
    if (seq !== refreshSeq) return;
    if (error.status === 401) {
      state.token = "";
      showGate("connect");
      byId("gate-error").textContent = error.message;
    } else if (error.status === 423 || error.status === 403) {
      showGate("unlock");
    } else if (state.gate || byId("library").hidden) {
      showGate("unavailable");
      byId("gate-error").textContent = error.message;
    } else {
      notice(error.message);
    }
  } finally {
    if (seq === refreshSeq) byId("app").setAttribute("aria-busy", "false");
  }
}
function sortedRequests(requests) {
  const ms = (x) => (typeof x === "number" ? x : new Date(x).valueOf() || 0);
  return [...requests].sort((a, b) => ms(b.created_at) - ms(a.created_at));
}
async function formWork(control, errorSlot, task) {
  control.disabled = true;
  errorSlot.textContent = "";
  try {
    await task();
  } catch (error) {
    if (
      (error.status === 423 || (error.status === 403 && /session|解锁/i.test(error.message))) &&
      !state.gate
    ) {
      showGate("unlock");
    } else {
      errorSlot.textContent = error.message || "操作失败，请重试。";
    }
  } finally {
    control.disabled = false;
  }
}
byId("gate-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const mode = state.gate;
  formWork(byId("gate-submit"), byId("gate-error"), async () => {
    const input = byId("gate-value");
    if (mode === "connect") {
      state.token = input.value.trim();
      input.value = "";
    }
    if (mode === "unlock" || mode === "setup") {
      if (mode === "setup" && byId("gate-repeat").value !== input.value)
        throw new Error("两次输入的口令不一致。");
      try {
        await api("/api/" + mode, "POST", { password: input.value });
      } catch (err) {
        if (
          err.status === 401 &&
          /token|令牌/i.test(err.message) &&
          !/password|passphrase|口令/i.test(err.message)
        ) {
          state.token = "";
          showGate("connect");
        }
        throw err;
      }
      input.value = "";
    }
    await refresh();
  });
});
function footer(parent, ...buttons) {
  const n = element("div", "actions");
  n.append(...buttons);
  parent.append(n);
  return n;
}
function hero(parent, item) {
  const n = element("div", "item-hero");
  n.append(mark(item.kind), element("span", "", itemLabel(item)));
  parent.append(n);
}
function docType(file) {
  const extensions = {
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
    png: "image/png",
    webp: "image/webp",
    heic: "image/heic",
    heif: "image/heif",
    pdf: "application/pdf",
  };
  const mime =
    file.type || extensions[file.name.split(".").pop().toLowerCase()] || "application/octet-stream";
  return allowedMime.has(mime) ? mime : "application/octet-stream";
}
async function fileValue(file) {
  if (!file.size || file.size > maxFile) throw new Error("文件必须非空且不超过 8 MiB。");
  const bytes = new Uint8Array(await file.arrayBuffer());
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000)
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}
function saveDocument(item) {
  const bytes = Uint8Array.from(atob(item.value), (ch) => ch.charCodeAt(0));
  const mime = allowedMime.has(item.mime) ? item.mime : "application/octet-stream";
  const ext =
    {
      "image/jpeg": ".jpg",
      "image/png": ".png",
      "image/webp": ".webp",
      "image/heic": ".heic",
      "image/heif": ".heif",
      "application/pdf": ".pdf",
    }[mime] || ".bin";
  const url = URL.createObjectURL(new Blob([bytes], { type: "application/octet-stream" }));
  liveDownloads.add(url);
  const a = element("a");
  a.href = url;
  a.download = "Vault-" + itemLabel(item).replace(/[^\p{L}\p{N} _-]/gu, "_") + ext;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => {
    URL.revokeObjectURL(url);
    liveDownloads.delete(url);
  }, 1000);
}
function showItem(item) {
  const body = showSheet("item", itemLabel(item), kinds[item.kind].name);
  meta(body, [
    ["类型", kinds[item.kind].singular],
    ["授权目标", item.target || "仅本人查看"],
    ["版本", item.revision],
  ]);
  const isDoc = item.kind === "document";
  const reveal = button(
    isDoc ? "导出明文文件" : "显示内容",
    async () => {
      const output = body.querySelector(".secret-result");
      if (output) {
        output.remove();
        reveal.textContent = "显示内容";
        return;
      }
      await formWork(reveal, byId("sheet-error"), async () => {
        const version = state.version,
          full = await api(urlFor(item.id));
        if (version !== state.version) return;
        if (isDoc) {
          saveDocument(full);
          return;
        }
        const value = full.kind === "payment" ? wallets[full.value] || "未指定" : full.value;
        const clear = element("div", "secret-result", value);
        reveal.after(clear);
        reveal.textContent = "隐藏内容";
      });
    },
    "button",
  );
  body.append(reveal);
  if (isDoc) hint(body, "导出的副本会保存在浏览器下载位置。");
  footer(
    body,
    button("删除", () => confirmDelete(item), "button danger spacer"),
    button("编辑", () => editItem(item.kind, item), "button"),
    button("完成", closeSheet, "button primary"),
  );
}
function confirmDelete(item) {
  const body = showSheet("delete", "删除这项资料？", kinds[item.kind].name);
  hero(body, item);
  hint(body, "旧的加密备份和已经交付给接收方的副本由各自持有者保存。");
  const remove = button(
    "确认删除",
    () =>
      formWork(remove, byId("sheet-error"), async () => {
        await api(urlFor(item.id), "DELETE", { revision: item.revision });
        closeSheet();
        await refresh();
        notice("已删除资料。");
      }),
    "button primary",
  );
  footer(
    body,
    button("返回", () => showItem(item)),
    remove,
  );
}
// Accept one-line literal assignments only. Quoted multiline blocks and escaped continuations
// are consumed together so their contents cannot appear as independent variable names.
function envVariables(text) {
  const result = new Map();
  const seen = new Set();
  const lines = text.replace(/^\uFEFF/, "").split(/\r\n?|\n/);
  const closingQuote = (part, quote, start) => {
    for (let n = start; n < part.length; n++) {
      if (part[n] === "\\") n++;
      else if (part[n] === quote) return n;
    }
    return -1;
  };
  for (let i = 0; i < lines.length; i++) {
    const match = lines[i].match(/^\s*(?:export[ \t]+)?([A-Za-z_][A-Za-z_0-9]*)[ \t]*=[ \t]*(.*)$/);
    if (!match) continue;
    const [, name, raw] = match;
    const duplicate = seen.has(name);
    seen.add(name);
    result.delete(name);
    let value = raw;
    if (raw.startsWith("'") || raw.startsWith('"')) {
      const quote = raw[0],
        end = closingQuote(raw, quote, 1);
      if (end < 0) {
        while (++i < lines.length && closingQuote(lines[i], quote, 0) < 0) {
          /* skip block */
        }
        continue;
      }
      if (!/^[ \t]*(?:#.*)?$/.test(raw.slice(end + 1))) continue;
      value = raw.slice(1, end);
    } else {
      if (raw.endsWith("\\")) {
        while (++i < lines.length && lines[i].endsWith("\\")) {
          /* skip continuation */
        }
        continue;
      }
      value = raw.replace(/[ \t]+#.*$/, "").trimEnd();
      if (!/^[A-Za-z0-9._~+/@%,:=#-]+$/.test(value) || value.startsWith("#")) continue;
    }
    if (
      !duplicate &&
      value.trim() &&
      !/[\u0000-\u001f\u007f$\x60\\]/.test(value) &&
      value.length <= 32768
    )
      result.set(name, value);
  }
  return result;
}

function envPicker(parent, label, password) {
  const panel = element("details", "env-picker");
  panel.append(element("summary", "", "从本机 .env 文件选择"));
  const controls = element("div", "fields");
  panel.append(controls);
  parent.append(panel);
  hint(
    controls,
    "支持 64 KiB 以内的 .env、.env.local 等文件。仅识别单行字面值，点保存后才写入选中的密钥。",
  );
  const file = field(controls, "选择 .env 文件", "input", "file");
  const variable = field(controls, "变量名", "select");
  const message = element("span", "hint");
  message.setAttribute("role", "status");
  controls.append(message);

  let choices = new Map();
  let generation = 0;
  let filledName = "";
  let filledPassword = false;
  password.addEventListener("input", () => {
    filledPassword = false;
  });
  function resetSelection() {
    if (filledPassword) password.value = "";
    if (filledName && label.value === filledName) label.value = "";
    filledName = "";
    filledPassword = false;
  }
  function resetOptions() {
    const placeholder = element("option", "", "请选择一个变量");
    placeholder.value = "";
    variable.replaceChildren(placeholder);
    variable.disabled = true;
  }
  resetOptions();
  file.addEventListener("change", async () => {
    const current = ++generation;
    const source = file.files[0];
    choices.clear();
    resetSelection();
    resetOptions();
    message.textContent = "";
    if (!source) return;
    if (!/(^\.env(?:\..+)?$|\.env$)/i.test(source.name) || !source.size || source.size > 64 * 1024) {
      message.textContent = "请选择非空且不超过 64 KiB 的 .env 文件。";
      file.value = "";
      return;
    }
    try {
      const content = new TextDecoder("utf-8", { fatal: true }).decode(await source.arrayBuffer());
      if (current !== generation || !panel.isConnected) return;
      choices = envVariables(content);
      for (const name of choices.keys()) variable.append(element("option", "", name));
      variable.disabled = !choices.size;
      if (!choices.size) message.textContent = "未找到可导入的单行变量。";
    } catch {
      if (current !== generation || !panel.isConnected) return;
      message.textContent = "无法读取这个文件。请选择 UTF-8 文本文件。";
    } finally {
      if (current === generation) file.value = "";
    }
  });
  variable.addEventListener("change", () => {
    resetSelection();
    if (!choices.has(variable.value)) return;
    password.value = choices.get(variable.value);
    filledPassword = true;
    if (!label.value) label.value = filledName = variable.value;
  });
}

function editItem(kind, existing = null) {
  const spec = kinds[kind],
    body = showSheet("edit", (existing ? "编辑" : "添加") + spec.singular, spec.name);
  const form = element("form");
  form.autocomplete = "off";
  body.append(form);
  const fs = element("div", "fields");
  form.append(fs);
  const label = field(fs, "名称");
  label.required = true;
  label.value = existing?.label || "";
  label.placeholder = {
    document: "例如：营业执照 · 青屿工作室",
    key: "例如：地图服务测试密钥",
    profile: "例如：默认收货地址",
    payment: "例如：商务卡",
    ssh: "例如：工作站 SSH 身份",
  }[kind];
  let valueInput = null,
    fileInput = null,
    camera = null,
    selectedFile = null,
    changed = false,
    targetInput = null;
  if (kind === "document") {
    fileInput = field(fs, existing ? "替换文件（可选）" : "选择照片或文件", "input", "file");
    fileInput.accept = "image/*,application/pdf,application/octet-stream";
    const tools = element("div", "file-tools"),
      selected = element("span", "hint");
    camera = element("input");
    camera.type = "file";
    camera.accept = "image/*";
    camera.setAttribute("capture", "environment");
    camera.hidden = true;
    const take = button("使用相机拍摄", () => camera.click(), "button");
    function choose(file) {
      if (!file) return;
      selectedFile = file;
      selected.textContent = file.name + " · " + Math.max(1, Math.round(file.size / 1024)) + " KB";
      if (!label.value) label.value = file.name;
    }
    fileInput.addEventListener("change", () => choose(fileInput.files[0]));
    camera.addEventListener("change", () => {
      if (camera.files[0]) {
        fileInput.value = "";
        choose(camera.files[0]);
      }
    });
    tools.append(take, selected, camera);
    fs.append(tools);
    hint(
      fs,
      existing
        ? "保留当前文件可直接保存。新文件最多 8 MiB。"
        : "可选择身份证、营业执照、学位证书或工资证明。每份最多 8 MiB。",
    );
  } else if (kind === "payment") {
    valueInput = field(fs, "支付钱包", "select");
    for (const [v, t] of Object.entries(wallets)) {
      const o = element("option", "", t);
      o.value = v;
      valueInput.append(o);
    }
    valueInput.addEventListener("change", () => {
      changed = true;
    });
    if (existing) hint(fs, "保留原钱包可直接保存。需要更换时，从下拉菜单选择。");
    else hint(fs, "只记录钱包与卡片别名。请把卡号和安全码留在原支付钱包。");
  } else {
    const titles = { key: "API Key", profile: "字段内容", ssh: "SSH Host 别名或 SHA256 公钥指纹" };
    valueInput = field(
      fs,
      titles[kind] + (existing ? "（留空保留原值）" : ""),
      kind === "profile" ? "textarea" : "input",
      kind === "key" ? "password" : "text",
    );
    valueInput.required = !existing;
    if (kind === "key" && !existing) envPicker(fs, label, valueInput);
    if (kind === "ssh") hint(fs, "私钥由系统 SSH Agent 或原密钥提供方持有。");
  }
  if (["document", "key", "profile"].includes(kind)) {
    targetInput = field(fs, "允许的 HTTPS 接收地址（可选）", "input", "url");
    targetInput.placeholder = "https://service.example/path";
    targetInput.value = existing?.target || "";
    hint(fs, "Agent 请求绑定到这个完整地址。留空时仅本人可用。");
  }
  const controls = element("div", "actions");
  form.append(controls);
  const save = element("button", "button primary", existing ? "保存修改" : "保存资料");
  save.type = "submit";
  controls.append(button("取消", closeSheet), save);
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    const opened = state.version;
    formWork(save, byId("sheet-error"), async () => {
      const old = existing ? await api(urlFor(existing.id)) : null;
      if (opened !== state.version) return;
      if (existing && old.revision !== existing.revision)
        throw new Error("资料已在另一处更新。请关闭此窗口并刷新，核对新版本后再修改。");
      const item = {
        kind,
        label: label.value.trim(),
        target: targetInput?.value.trim() || "",
        value: old?.value || "",
      };
      if (kind === "document") {
        if (!selectedFile && !old) throw new Error("请选择要保存的文件。");
        item.mime = selectedFile ? docType(selectedFile) : old.mime;
        if (selectedFile) item.value = await fileValue(selectedFile);
      } else if (kind === "payment") {
        if (!existing || changed) item.value = valueInput.value;
      } else if (!old || valueInput.value !== "") {
        item.value = valueInput.value;
      }
      if (opened !== state.version) return;
      if (existing) item.revision = existing.revision;
      await api(existing ? urlFor(existing.id) : "/api/items", existing ? "PUT" : "POST", item);
      closeSheet();
      await refresh();
      notice("资料已保存。");
    });
  });
  if (kind === "payment" && existing) {
    const opened = state.version;
    api(urlFor(existing.id))
      .then((item) => {
        if (opened === state.version && !changed) valueInput.value = item.value || "";
      })
      .catch(() => {});
  }
}
function showRequest(req) {
  const body = showSheet("request", actions[req.operation] || "使用资料", req.agent || "Agent");
  hero(body, { kind: req.kind, label: req.label || "资料已移除" });
  meta(body, [
    ["状态", statuses[req.state] || req.state],
    ["资料版本", req.asset_revision && String(req.asset_revision)],
    ["请求方", req.agent],
    ["用途", req.purpose],
    ["接收地址", req.target],
    ["操作", methods[req.operation] || req.operation],
    ["有效至", showDate(req.expires_at)],
    ["发起于", showDate(req.created_at)],
    ["请求编号", req.id],
  ]);
  async function decide(control, verb, success) {
    await formWork(control, byId("sheet-error"), async () => {
      await api(requestURL(req.id, verb), "POST", {});
      if (verb === "share") {
        notice(success);
        closeSheet();
        return;
      }
      closeSheet();
      await refresh();
      notice(success);
    });
  }
  if (req.state === "pending") {
    hint(body, "批准后，请求方可在有效期内执行一次上述操作。");
    const deny = button("拒绝", () => decide(deny, "deny", "已拒绝此次请求。"));
    const approve = button(
      "仅批准本次",
      () => decide(approve, "approve", "已批准一次使用。执行前仍可撤销。"),
      "button primary",
    );
    footer(body, deny, approve);
  } else if (req.state === "approved") {
    const revoke = button(
      "撤销授权",
      () => decide(revoke, "revoke", "已撤销尚未执行的授权。"),
      "button danger",
    );
    footer(body, revoke, button("完成", closeSheet, "button primary"));
  } else if (["used", "failed"].includes(req.state)) {
    const share = button("将脱敏回执发给 Context", () =>
      decide(share, "share", "脱敏回执已发送至 Context。"),
    );
    footer(body, share, button("完成", closeSheet, "button primary"));
  } else footer(body, button("完成", closeSheet, "button primary"));
}
function renderInbox() {
  const slot = byId("inbox-banner");
  slot.replaceChildren();
  if (!state.inbox.length) return;
  const b = button("", showPhone, "banner"),
    t = element("span", "banner-text");
  t.append(
    element("small", "", "加密收件箱"),
    element("strong", "", state.inbox.length + " 份资料待接收"),
  );
  b.append(element("span", "dot"), t, element("span", "trailing", "↗"));
  slot.append(b);
}
function showPhone() {
  const body = showSheet("phone", "手机收件", "加密收件箱");
  hint(body, "在 iPhone 的扫描工具中导入本机的配对信息。扫描件会以加密文件传回。");
  const fs = element("div", "fields");
  body.append(fs);
  const pair = button("显示配对信息", () =>
    formWork(pair, byId("sheet-error"), async () => {
      const version = state.version,
        info = await api("/api/phone-key");
      if (version !== state.version) return;
      pair.hidden = true;
      const code = field(fs, "配对信息", "textarea");
      code.value = info.pairing;
      code.readOnly = true;
      meta(fs, [["公钥指纹", info.fingerprint]]);
      fs.append(
        button("复制配对信息", async () => {
          try {
            await navigator.clipboard.writeText(info.pairing);
            byId("sheet-error").textContent = "";
          } catch {
            code.focus();
            code.select();
            byId("sheet-error").textContent = "请复制已选中的配对信息。";
          }
        }),
      );
    }),
  );
  fs.append(pair);
  const pkg = field(fs, "选择手机导出的加密扫描件", "input", "file");
  pkg.accept = ".cvdrop,application/json";
  const importFile = button("导入所选扫描件", () =>
    formWork(importFile, byId("sheet-error"), async () => {
      const file = pkg.files[0];
      if (!file) throw new Error("请选择 .cvdrop 扫描件。");
      if (file.size > 18 * 1024 * 1024) throw new Error("加密扫描件超过大小限制。");
      let data;
      try {
        data = JSON.parse(await file.text());
      } catch {
        throw new Error("文件不是有效的加密扫描件。");
      }
      await api("/api/phone-import", "POST", { package: data });
      closeSheet();
      await refresh();
      notice("手机扫描件已存入保险库。");
    }),
  );
  fs.append(importFile);
  if (state.inbox.length) {
    const h = element("h3", "", "待接收的资料");
    fs.append(h);
    for (const item of state.inbox) {
      const row = element("div", "item-hero");
      row.append(mark(item.kind), element("span", "", itemLabel(item)));
      fs.append(row);
      const accept = button("接收入库", () => inboxAction(accept, item, "import"));
      const discard = button("移除此件", () => confirmDismiss(item), "button danger");
      footer(fs, discard, accept);
    }
  }
  footer(body, button("完成", closeSheet, "button primary"));
}
function confirmDismiss(item) {
  const body = showSheet("dismiss", "移除待收件？", "加密收件箱");
  hero(body, item);
  const remove = button("确认移除", () => inboxAction(remove, item, "dismiss"), "button danger");
  footer(body, button("返回", showPhone), remove);
}
async function inboxAction(control, item, action) {
  await formWork(control, byId("sheet-error"), async () => {
    const path = "/api/inbox/" + encodeURIComponent(item.id);
    await api(
      action === "import" ? path + "/import" : path,
      action === "import" ? "POST" : "DELETE",
      {},
    );
    closeSheet();
    await refresh();
    notice(action === "import" ? "资料已从收件箱导入。" : "已移除待收件。");
  });
}
function backup() {
  const body = showSheet("backup", "iCloud Drive", "加密备份");
  const version = state.version;
  const fs = element("div", "fields");
  body.append(fs);
  const choice = element("label", "inline-choice"),
    toggle = element("input");
  toggle.type = "checkbox";
  toggle.disabled = true;
  choice.append(toggle, element("span", "", "自动备份并接收手机扫描件"));
  fs.append(choice);
  hint(
    fs,
    "开启后会维护本机的最新加密副本。iPhone 可将加密扫描件存到 iCloud Drive / Context Vault / Inbox，待同步后在收件箱确认。",
  );
  const summary = element("p", "hint");
  fs.append(summary);
  function display(info) {
    toggle.checked = Boolean(info.enabled);
    toggle.disabled = !info.available;
    const time = info.last_backup ? showDate(info.last_backup) : "";
    summary.textContent = info.error
      ? "最近备份未成功，请检查 iCloud Drive。"
      : time
        ? "最近写入备份文件 · " + time
        : info.enabled
          ? "自动备份已启用。"
          : "自动备份已关闭。";
    const providerStatus = {
      uploaded: "iCloud 已确认上传。",
      uploading: "iCloud 正在上传。",
      pending: "iCloud 正在等待上传。",
      unavailable: "iCloud 服务暂时不可用，云端上传待确认。",
      quota: "iCloud 空间不足，云端上传待确认。",
      provider_error: "iCloud 报告错误，云端上传待确认。",
    }[info.provider_state];
    if (providerStatus) summary.textContent += " " + providerStatus;
  }
  api("/api/cloud")
    .then((info) => {
      if (state.version === version) display(info);
    })
    .catch((error) => {
      if (state.version === version) summary.textContent = error.message;
    });
  toggle.addEventListener("change", async () => {
    const next = toggle.checked;
    toggle.disabled = true;
    try {
      await api("/api/cloud", "POST", { enabled: next });
      const info = await api("/api/cloud");
      if (state.version === version) display(info);
    } catch (error) {
      if (state.version === version) {
        toggle.checked = !next;
        toggle.disabled = false;
        summary.textContent = error.message;
      }
    }
  });
  hint(fs, "也可以单独保留一份加密快照。恢复时仍需要原保险库口令。");
  const primary = button(
    "创建加密备份",
    () =>
      formWork(primary, byId("sheet-error"), async () => {
        const saved = await api("/api/backup", "POST", {});
        closeSheet();
        notice("已写入 iCloud Drive 文件夹：" + (saved.name || "加密快照") + "。上传状态以访达为准。");
      }),
    "button primary",
  );
  footer(body, button("完成", closeSheet), primary);
}
byId("backup").addEventListener("click", backup);
byId("phone").addEventListener("click", showPhone);
byId("tab-library").addEventListener("click", () => displayTab("library"));
byId("tab-requests").addEventListener("click", () => {
  displayTab("requests");
  refresh(true);
});
byId("refresh").addEventListener("click", () => refresh());
byId("item-search").addEventListener("input", renderItems);
byId("clear-search").addEventListener("click", () => {
  const search = byId("item-search");
  search.value = "";
  renderItems();
  search.focus();
});
byId("sheet-close").addEventListener("click", closeSheet);
sheet.addEventListener("cancel", (e) => {
  e.preventDefault();
  closeSheet();
});
byId("lock").addEventListener("click", () =>
  formWork(byId("lock"), byId("notice"), async () => {
    await api("/api/lock", "POST", {});
    refreshSeq++;
    showGate("unlock");
  }),
);
async function poll() {
  if (refreshing || document.hidden) return;
  refreshing = true;
  try {
    const h = await api("/health");
    if (h.initialized && !h.unlocked && !state.gate) {
      refreshSeq++;
      state.health = h;
      showGate("unlock");
      return;
    }
    if (!state.gate && h.unlocked && state.token && !sheet.open) {
      const [requests, inbox] = await Promise.all([api("/api/requests"), api("/api/inbox")]);
      if (state.gate) return;
      state.requests = sortedRequests(requests.items || []);
      state.inbox = inbox.items || [];
      renderRequests();
      renderInbox();
    }
  } catch (err) {
    if ((err.status === 403 || err.status === 423) && !state.gate) showGate("unlock");
  } finally {
    refreshing = false;
  }
}
window.addEventListener("pagehide", () => {
  state.token = "";
  refreshSeq++;
  resetPrivate();
});
window.addEventListener("pageshow", (event) => {
  if (event.persisted) refresh();
});
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) poll();
});
const fragment = new URLSearchParams(location.hash.slice(1));
state.token = fragment.get("token") || "";
if (location.hash) history.replaceState(null, "", location.pathname + location.search);
refresh();
setInterval(poll, 11000);
