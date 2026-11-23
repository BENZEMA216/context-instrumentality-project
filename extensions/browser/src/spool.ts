/**
 * Durable offline spool queue for Browser MV3 Extension.
 * Persists unsent events into storage (capped with LRU eviction) and flushes in
 * batches whenever Context Hub v2 is reachable on localhost.
 */

import type { BrowserRawEvent } from './types';

export interface KeyValueStorage {
  get(key: string): Promise<unknown>;
  set(key: string, value: unknown): Promise<void>;
}

export const SPOOL_STORAGE_KEY = 'context_hub_event_spool_v1';
export const MAX_SPOOL_EVENTS = 500;

export class EventSpool {
  private readonly storage: KeyValueStorage;
  private readonly maxItems: number;

  constructor(storage: KeyValueStorage, maxItems = MAX_SPOOL_EVENTS) {
    this.storage = storage;
    this.maxItems = maxItems;
  }

  async list(): Promise<BrowserRawEvent[]> {
    const raw = await this.storage.get(SPOOL_STORAGE_KEY);
    return Array.isArray(raw) ? (raw as BrowserRawEvent[]) : [];
  }

  async enqueue(event: BrowserRawEvent): Promise<number> {
    const items = await this.list();
    // Deduplicate by provenance.source_id (keep latest revision with richer dwell/excerpts)
    const filtered = items.filter((it) => it.provenance.source_id !== event.provenance.source_id);
    filtered.push(event);
    const trimmed =
      filtered.length > this.maxItems ? filtered.slice(filtered.length - this.maxItems) : filtered;
    await this.storage.set(SPOOL_STORAGE_KEY, trimmed);
    return trimmed.length;
  }

  async flush(
    sender: (batch: BrowserRawEvent[]) => Promise<boolean>,
    batchSize = 25,
  ): Promise<{ sent: number; remaining: number }> {
    const items = await this.list();
    if (items.length === 0) {
      return { sent: 0, remaining: 0 };
    }
    let sent = 0;
    let remaining: BrowserRawEvent[] = [];
    for (let i = 0; i < items.length; i += batchSize) {
      const chunk = items.slice(i, i + batchSize);
      const ok = await sender(chunk);
      if (ok) {
        sent += chunk.length;
      } else {
        remaining = items.slice(i);
        break;
      }
    }
    await this.storage.set(SPOOL_STORAGE_KEY, remaining);
    return { sent, remaining: remaining.length };
  }
}

export function chromeLocalStorageAdapter(): KeyValueStorage {
  return {
    async get(key: string): Promise<unknown> {
      const obj = await chrome.storage.local.get(key);
      return obj[key];
    },
    async set(key: string, value: unknown): Promise<void> {
      await chrome.storage.local.set({ [key]: value });
    },
  };
}
