import type { ExtensionSettings } from './types';

async function refresh(): Promise<void> {
  const statusEl = document.getElementById('status')!;
  const spoolEl = document.getElementById('spool')!;
  const hubInput = document.getElementById('hubUrl') as HTMLInputElement;
  const enabledInput = document.getElementById('enabled') as HTMLInputElement;
  const sidebarInput = document.getElementById('sidebar') as HTMLInputElement;

  const res = await chrome.runtime.sendMessage({ type: 'GET_STATUS' });
  const settings = res.settings as ExtensionSettings;

  statusEl.textContent = res.online ? '● Hub 在线 (127.0.0.1)' : '○ Hub 离线（已启用本地队列缓冲）';
  statusEl.className = res.online ? 'pill ok' : 'pill warn';
  spoolEl.textContent = `离线待补传队列：${res.queuedCount} 条`;
  hubInput.value = settings.hubUrl;
  enabledInput.checked = settings.enabled;
  sidebarInput.checked = settings.sidebarEnabled;
}

document.addEventListener('DOMContentLoaded', () => {
  void refresh();

  document.getElementById('saveBtn')?.addEventListener('click', async () => {
    const hubUrl = (document.getElementById('hubUrl') as HTMLInputElement).value.trim();
    const enabled = (document.getElementById('enabled') as HTMLInputElement).checked;
    const sidebarEnabled = (document.getElementById('sidebar') as HTMLInputElement).checked;
    await chrome.runtime.sendMessage({
      type: 'SAVE_CONFIG',
      patch: { hubUrl, enabled, sidebarEnabled },
    });
    await refresh();
  });

  document.getElementById('captureBtn')?.addEventListener('click', async () => {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (tab?.id !== undefined) {
      await chrome.tabs.sendMessage(tab.id, { type: 'CAPTURE_NOW' }).catch(() => {});
    }
    await refresh();
  });

  document.getElementById('flushBtn')?.addEventListener('click', async () => {
    await chrome.runtime.sendMessage({ type: 'FLUSH_SPOOL' });
    await refresh();
  });

  document.getElementById('openBtn')?.addEventListener('click', async () => {
    const hubUrl = (document.getElementById('hubUrl') as HTMLInputElement).value.trim();
    await chrome.tabs.create({ url: `${hubUrl.replace(/\/$/, '')}/#/timeline` });
  });
});
