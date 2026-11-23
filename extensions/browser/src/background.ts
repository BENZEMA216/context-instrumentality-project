/**
 * MV3 Service Worker:
 * - Coordinates window focus (`chrome.windows.onFocusChanged`) and user activity (`chrome.idle`)
 *   to power the 3-layer effective dwell gate in content scripts.
 * - Accepts captured BrowserRawEvents, pushes to Context Hub v2 `/api/v2/events/batch`, and
 *   spools offline events reliably in `chrome.storage.local` with alarm-based retry.
 * - Proxies `/api/v2/related?url=...` queries for the Promnesia-style Contextual Sidebar.
 */

import { canonicalizeUrl, isDomainBlocked } from './sanitizer';
import { chromeLocalStorageAdapter, EventSpool } from './spool';
import {
  DEFAULT_SETTINGS,
  type BrowserRawEvent,
  type ExtensionSettings,
  type RelatedResponse,
} from './types';

const SETTINGS_KEY = 'context_hub_settings_v1';
const FLUSH_ALARM = 'context_hub_spool_flush';
const spool = new EventSpool(chromeLocalStorageAdapter());

let windowFocused = true;
let userActive = true;

async function loadSettings(): Promise<ExtensionSettings> {
  const res = await chrome.storage.local.get(SETTINGS_KEY);
  return { ...DEFAULT_SETTINGS, ...(res[SETTINGS_KEY] || {}) };
}

async function saveSettings(patch: Partial<ExtensionSettings>): Promise<ExtensionSettings> {
  const next = { ...(await loadSettings()), ...patch };
  await chrome.storage.local.set({ [SETTINGS_KEY]: next });
  return next;
}

function authHeaders(settings: ExtensionSettings): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (settings.ownerToken.trim()) {
    headers.Authorization = `Bearer ${settings.ownerToken.trim()}`;
  }
  return headers;
}

async function postBatchToHub(
  settings: ExtensionSettings,
  events: BrowserRawEvent[],
): Promise<boolean> {
  try {
    const resp = await fetch(`${settings.hubUrl.replace(/\/$/, '')}/api/v2/events/batch`, {
      method: 'POST',
      headers: authHeaders(settings),
      body: JSON.stringify({ events }),
    });
    return resp.ok;
  } catch {
    return false;
  }
}

async function flushSpool(): Promise<{ sent: number; remaining: number }> {
  const settings = await loadSettings();
  return spool.flush((batch) => postBatchToHub(settings, batch));
}

async function checkHubHealth(settings: ExtensionSettings): Promise<boolean> {
  try {
    const resp = await fetch(`${settings.hubUrl.replace(/\/$/, '')}/api/v2/health`, {
      method: 'GET',
    });
    return resp.ok;
  } catch {
    return false;
  }
}

async function fetchRelated(url: string): Promise<RelatedResponse> {
  const settings = await loadSettings();
  if (isDomainBlocked(url, settings.blockedDomains)) {
    return { items: [], hubOnline: true };
  }
  try {
    const norm = canonicalizeUrl(url);
    const endpoint = `${settings.hubUrl.replace(/\/$/, '')}/api/v2/related?url=${encodeURIComponent(norm)}&limit=10`;
    const resp = await fetch(endpoint, { headers: authHeaders(settings) });
    if (!resp.ok) {
      return { items: [], hubOnline: false };
    }
    const data = (await resp.json()) as { items?: RelatedResponse['items'] };
    return { items: data.items || [], hubOnline: true };
  } catch {
    return { items: [], hubOnline: false };
  }
}

async function broadcastSignalState(): Promise<void> {
  const tabs = await chrome.tabs.query({ active: true });
  for (const tab of tabs) {
    if (tab.id !== undefined) {
      chrome.tabs
        .sendMessage(tab.id, {
          type: 'SIGNAL_STATE',
          windowFocused,
          userActive,
        })
        .catch(() => {});
    }
  }
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create(FLUSH_ALARM, { periodInMinutes: 1 });
  chrome.idle.setDetectionInterval(60);
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === FLUSH_ALARM) {
    void flushSpool();
  }
});

chrome.windows.onFocusChanged.addListener((windowId) => {
  windowFocused = windowId !== chrome.windows.WINDOW_ID_NONE;
  void broadcastSignalState();
});

chrome.idle.onStateChanged.addListener((state) => {
  userActive = state === 'active';
  void broadcastSignalState();
});

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  void (async () => {
    switch (msg?.type) {
      case 'GET_CONFIG': {
        const settings = await loadSettings();
        sendResponse({ settings, windowFocused, userActive });
        return;
      }
      case 'SAVE_CONFIG': {
        const settings = await saveSettings(msg.patch || {});
        sendResponse({ settings });
        return;
      }
      case 'INGEST_EVENT': {
        const settings = await loadSettings();
        if (!settings.enabled) {
          sendResponse({ ok: false, reason: 'disabled' });
          return;
        }
        const ev = msg.event as BrowserRawEvent;
        if (isDomainBlocked(ev.content.url, settings.blockedDomains)) {
          sendResponse({ ok: false, reason: 'blocked_domain' });
          return;
        }
        const ok = await postBatchToHub(settings, [ev]);
        if (!ok) {
          const queued = await spool.enqueue(ev);
          sendResponse({ ok: false, spooled: true, queued });
          return;
        }
        void flushSpool();
        sendResponse({ ok: true, spooled: false });
        return;
      }
      case 'GET_RELATED': {
        const related = await fetchRelated(String(msg.url || ''));
        sendResponse(related);
        return;
      }
      case 'GET_STATUS': {
        const settings = await loadSettings();
        const [online, queued] = await Promise.all([checkHubHealth(settings), spool.list()]);
        sendResponse({
          online,
          queuedCount: queued.length,
          settings,
        });
        return;
      }
      case 'FLUSH_SPOOL': {
        const result = await flushSpool();
        sendResponse(result);
        return;
      }
      default:
        sendResponse({ ok: false, error: 'unknown_message' });
    }
  })();
  return true;
});
