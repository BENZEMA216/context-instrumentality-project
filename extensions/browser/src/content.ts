/**
 * Content script:
 * 1. Drives 3-layer effective dwell timer (page visibility ∩ window focus ∩ chrome.idle)
 *    + scroll depth meter.
 * 2. Captures zero-friction implicit highlights (`selectionchange` held > 1.2s) and `copy`
 *    events, elevating `curation_tier` to `auto_curated`.
 * 3. Extracts clean Markdown via Defuddle/Readability once dwell >= minDwellMs (or on excerpt)
 *    and sends to MV3 background worker (with offline spooling).
 * 4. Renders a non-intrusive Shadow-DOM Promnesia Contextual Sidebar showing cross-channel
 *    Context Hub matches for the current URL with 1-click Workbench deep links.
 */

import { EffectiveDwellTracker } from './dwell';
import { extractPageArticle } from './extractor';
import { canonicalizeUrl, isDomainBlocked, redactInlineSecrets } from './sanitizer';
import type { BrowserRawEvent, Excerpt, ExtensionSettings, RelatedItem } from './types';

let settings: ExtensionSettings | null = null;
let tracker = new EffectiveDwellTracker({ pageVisible: document.visibilityState === 'visible' });
let sessionKey = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
let currentUrl = window.location.href;
let captured = false;
let excerpts: Excerpt[] = [];
let selectionTimer: number | null = null;
let lastSelectionText = '';

function updateScrollDepth(): void {
  const docEl = document.documentElement;
  const scrollHeight = Math.max(1, docEl.scrollHeight - window.innerHeight);
  const ratio = Math.min(1, (window.scrollY + window.innerHeight * 0.2) / scrollHeight);
  tracker.recordScrollDepth(ratio);
}

function captureExcerpt(rawText: string, kind: 'selection' | 'copy'): void {
  const cleaned = redactInlineSecrets(rawText.replace(/\s+/g, ' ').trim());
  if (cleaned.length < 18 || cleaned.length > 2000) return;
  if (excerpts.some((e) => e.text === cleaned)) return;
  excerpts.push({
    text: cleaned,
    kind,
    captured_at: Date.now(),
  });
  if (excerpts.length > 20) {
    excerpts = excerpts.slice(-20);
  }
  // Excerpt or copy is a strong intent signal: emit immediately if dwell >= 3s
  if (tracker.getDwellMs() >= 3_000) {
    void emitPageEvent(true);
  }
}

async function emitPageEvent(force = false): Promise<boolean> {
  if (!settings || !settings.enabled) return false;
  if (isDomainBlocked(currentUrl, settings.blockedDomains)) return false;

  const dwellMs = tracker.getDwellMs();
  if (!force && dwellMs < settings.minDwellMs && excerpts.length === 0) {
    return false;
  }

  const article = extractPageArticle(document, currentUrl);
  if (article.markdown.length < 40 && excerpts.length === 0) {
    return false;
  }

  const normUrl = canonicalizeUrl(currentUrl);
  const bounds = tracker.getBounds();
  const hasExcerpts = excerpts.length > 0;
  const event: BrowserRawEvent = {
    source: 'browser',
    kind: 'page_read',
    t_start: bounds.tStart,
    t_end: bounds.tEnd,
    actor: 'self',
    attention: tracker.computeAttention(Date.now(), hasExcerpts),
    content: {
      title: article.title,
      url: normUrl,
      url_norm: normUrl,
      text: article.markdown,
      summary: article.summary,
      author: article.author,
      site: article.site,
      excerpts: hasExcerpts ? [...excerpts] : undefined,
    },
    context: {
      dwell_ms: Math.round(dwellMs),
      scroll_depth: tracker.getScrollDepth(),
      curation_tier: hasExcerpts ? 'auto_curated' : 'raw',
      extractor: article.extractor,
      word_count: article.wordCount,
    },
    provenance: {
      connector: 'browser-mv3',
      source_id: `${normUrl}#${sessionKey}`,
      locator: normUrl,
    },
  };

  captured = true;
  try {
    const resp = await chrome.runtime.sendMessage({ type: 'INGEST_EVENT', event });
    return Boolean(resp?.ok || resp?.spooled);
  } catch {
    return false;
  }
}

// ---------------- Shadow-DOM Promnesia Contextual Sidebar ----------------
function mountSidebar(items: RelatedItem[], hubUrl: string): void {
  if (!items.length) return;
  const hostId = 'context-hub-contextual-sidebar-host';
  document.getElementById(hostId)?.remove();

  const host = document.createElement('div');
  host.id = hostId;
  host.style.position = 'fixed';
  host.style.right = '16px';
  host.style.bottom = '16px';
  host.style.zIndex = '2147483640';
  document.documentElement.appendChild(host);

  const shadow = host.attachShadow({ mode: 'open' });
  const base = hubUrl.replace(/\/$/, '');
  const style = document.createElement('style');
  style.textContent = `
    .pill {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #1f1a17;
      color: #f6efe4;
      border: 1px solid #d97706;
      border-radius: 999px;
      padding: 8px 14px;
      font-size: 12px;
      font-weight: 600;
      cursor: pointer;
      box-shadow: 0 6px 20px rgba(0,0,0,0.22);
    }
    .drawer {
      margin-top: 8px;
      width: 320px;
      max-height: 420px;
      overflow-y: auto;
      background: #fbf7f0;
      color: #1f1a17;
      border: 1px solid #d6cbb9;
      border-radius: 12px;
      padding: 12px;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      box-shadow: 0 12px 32px rgba(0,0,0,0.2);
      display: none;
    }
    .drawer.open { display: block; }
    .hdr { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
    .hdr strong { font-size: 13px; }
    .card { border-top: 1px solid #e6dccd; padding: 8px 0; font-size: 12px; }
    .badge { display: inline-block; background: #ede3d3; color: #7c3f00; border-radius: 4px; padding: 1px 6px; font-size: 10px; margin-right: 6px; }
    a { color: #b45309; text-decoration: none; font-weight: 600; }
    a:hover { text-decoration: underline; }
    .snip { color: #574c42; margin-top: 4px; line-height: 1.4; }
  `;

  const wrap = document.createElement('div');
  const pill = document.createElement('button');
  pill.className = 'pill';
  pill.textContent = `Context Hub · ${items.length} 条关联`;

  const drawer = document.createElement('div');
  drawer.className = 'drawer';
  const hdr = document.createElement('div');
  hdr.className = 'hdr';
  const hTitle = document.createElement('strong');
  hTitle.textContent = '跨渠道上下文关联';
  const wbLink = document.createElement('a');
  wbLink.href = `${base}/#/timeline`;
  wbLink.target = '_blank';
  wbLink.rel = 'noopener noreferrer';
  wbLink.textContent = '打开工作台 ↗';
  hdr.append(hTitle, wbLink);
  drawer.appendChild(hdr);

  for (const item of items.slice(0, 8)) {
    const card = document.createElement('div');
    card.className = 'card';
    const meta = document.createElement('div');
    const badge = document.createElement('span');
    badge.className = 'badge';
    badge.textContent = item.source || item.kind || 'context';
    const link = document.createElement('a');
    link.href = item.episode_id
      ? `${base}/#/episodes/${encodeURIComponent(item.episode_id)}`
      : `${base}/#/timeline`;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    link.textContent = (item.title || item.id).slice(0, 72);
    meta.append(badge, link);
    card.appendChild(meta);
    if (item.snippet) {
      const snip = document.createElement('div');
      snip.className = 'snip';
      snip.textContent = item.snippet.slice(0, 140);
      card.appendChild(snip);
    }
    drawer.appendChild(card);
  }

  pill.addEventListener('click', () => drawer.classList.toggle('open'));
  wrap.append(drawer, pill);
  shadow.append(style, wrap);
}

async function init(): Promise<void> {
  const cfg = await chrome.runtime.sendMessage({ type: 'GET_CONFIG' }).catch(() => null);
  if (!cfg?.settings) return;
  settings = cfg.settings as ExtensionSettings;
  if (!settings.enabled || isDomainBlocked(currentUrl, settings.blockedDomains)) return;

  tracker = new EffectiveDwellTracker({
    pageVisible: document.visibilityState === 'visible',
    windowFocused: Boolean(cfg.windowFocused),
    userActive: Boolean(cfg.userActive),
  });

  document.addEventListener('visibilitychange', () => {
    tracker.update({ pageVisible: document.visibilityState === 'visible' });
    if (document.visibilityState === 'hidden' && !captured) {
      void emitPageEvent(false);
    }
  });

  window.addEventListener('scroll', updateScrollDepth, { passive: true });
  updateScrollDepth();

  document.addEventListener('selectionchange', () => {
    if (selectionTimer !== null) window.clearTimeout(selectionTimer);
    selectionTimer = window.setTimeout(() => {
      const sel = window.getSelection()?.toString().trim() || '';
      if (sel && sel !== lastSelectionText) {
        lastSelectionText = sel;
        captureExcerpt(sel, 'selection');
      }
    }, 1200);
  });

  document.addEventListener('copy', () => {
    const sel = window.getSelection()?.toString().trim() || '';
    if (sel) {
      captureExcerpt(sel, 'copy');
    }
  });

  window.addEventListener('pagehide', () => {
    if (!captured) {
      void emitPageEvent(false);
    }
  });

  // Periodic dwell threshold check (every 5s)
  window.setInterval(() => {
    if (window.location.href !== currentUrl) {
      // SPA navigation reset
      if (!captured) void emitPageEvent(false);
      currentUrl = window.location.href;
      sessionKey = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
      captured = false;
      excerpts = [];
      tracker = new EffectiveDwellTracker({ pageVisible: document.visibilityState === 'visible' });
      return;
    }
    if (!captured && settings && tracker.getDwellMs() >= settings.minDwellMs) {
      void emitPageEvent(false);
    }
  }, 5000);

  // Query Promnesia-style contextual links for this URL
  if (settings.sidebarEnabled) {
    const rel = await chrome.runtime
      .sendMessage({ type: 'GET_RELATED', url: currentUrl })
      .catch(() => null);
    if (rel?.items?.length) {
      mountSidebar(rel.items as RelatedItem[], settings.hubUrl);
    }
  }
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type === 'SIGNAL_STATE') {
    tracker.update({
      windowFocused: Boolean(msg.windowFocused),
      userActive: Boolean(msg.userActive),
    });
    sendResponse({ dwellMs: tracker.getDwellMs() });
    return true;
  }
  if (msg?.type === 'CAPTURE_NOW') {
    void emitPageEvent(true).then((ok) => sendResponse({ ok }));
    return true;
  }
  return false;
});

void init();
