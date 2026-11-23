import { describe, expect, it } from 'vitest';
import { EffectiveDwellTracker } from '../src/dwell';
import { extractPageArticle } from '../src/extractor';
import { canonicalizeUrl, isDomainBlocked, redactInlineSecrets } from '../src/sanitizer';
import { EventSpool, type KeyValueStorage } from '../src/spool';
import type { BrowserRawEvent } from '../src/types';

function memoryStorage(): KeyValueStorage {
  const map = new Map<string, unknown>();
  return {
    async get(key) {
      return map.get(key);
    },
    async set(key, value) {
      map.set(key, value);
    },
  };
}

describe('URL sanitizer & domain firewall', () => {
  it('strips tracking and auth tokens while normalizing path and param order', () => {
    const norm = canonicalizeUrl(
      'https://GitHub.com/kepano/defuddle/?utm_source=x&b=2&token=secret123&a=1&fbclid=999',
    );
    expect(norm).toBe('https://github.com/kepano/defuddle?a=1&b=2');
  });

  it('blocks banking, SSO, password managers, localhost, and user-blocked domains', () => {
    expect(isDomainBlocked('http://127.0.0.1:8741/#/timeline')).toBe(true);
    expect(isDomainBlocked('https://accounts.google.com/signin')).toBe(true);
    expect(isDomainBlocked('https://my.1password.com/vault')).toBe(true);
    expect(isDomainBlocked('https://ebank.example.com/transfer')).toBe(true);
    expect(isDomainBlocked('https://internal.corp.io/doc', ['corp.io'])).toBe(true);
    expect(isDomainBlocked('https://github.com/BENZEMA216/context-instrumentality-project')).toBe(
      false,
    );
  });

  it('redacts inline API keys and private keys', () => {
    const cleaned = redactInlineSecrets('Use token sk-abcdefghijklmnopqrstuvwxyz123456 safely');
    expect(cleaned).toContain('[REDACTED_SECRET]');
    expect(cleaned).not.toContain('sk-abcdefghijklmnopqrstuvwxyz');
  });
});

describe('3-layer effective dwell tracker', () => {
  it('counts time only when visible AND focused AND userActive are simultaneously true', () => {
    const tracker = new EffectiveDwellTracker(
      { pageVisible: true, windowFocused: true, userActive: true },
      1000,
    );
    // Active for 10s
    expect(tracker.update({ windowFocused: false }, 11_000)).toBe(10_000);
    // Window unfocused for 40s -> must NOT add dwell
    expect(tracker.update({ windowFocused: true }, 51_000)).toBe(10_000);
    // Active 5s then user goes idle
    expect(tracker.update({ userActive: false }, 56_000)).toBe(15_000);
    // Idle 60s -> must NOT add dwell
    expect(tracker.update({ userActive: true }, 116_000)).toBe(15_000);
    // Tab hidden after 20s active
    expect(tracker.update({ pageVisible: false }, 136_000)).toBe(35_000);
    expect(tracker.getDwellMs(200_000)).toBe(35_000);

    tracker.recordScrollDepth(0.8);
    expect(tracker.computeAttention(200_000, true)).toBeGreaterThan(0.5);
  });
});

describe('Offline event spool', () => {
  const sampleEvent = (id: string): BrowserRawEvent => ({
    source: 'browser',
    kind: 'page_read',
    t_start: 1000,
    t_end: 35_000,
    actor: 'self',
    content: {
      title: `Page ${id}`,
      url: `https://example.com/${id}`,
      url_norm: `https://example.com/${id}`,
      text: 'Sample markdown body',
    },
    context: {
      dwell_ms: 34_000,
      scroll_depth: 0.7,
      curation_tier: 'raw',
      extractor: 'defuddle',
      word_count: 3,
    },
    provenance: {
      connector: 'browser-mv3',
      source_id: `src-${id}`,
      locator: `https://example.com/${id}`,
    },
  });

  it('deduplicates by source_id, caps capacity, and retries flush on recovery', async () => {
    const spool = new EventSpool(memoryStorage(), 3);
    await spool.enqueue(sampleEvent('a'));
    await spool.enqueue(sampleEvent('a')); // deduped
    await spool.enqueue(sampleEvent('b'));
    await spool.enqueue(sampleEvent('c'));
    await spool.enqueue(sampleEvent('d')); // evicts oldest ('a')

    const queued = await spool.list();
    expect(queued.map((e) => e.provenance.source_id)).toEqual(['src-b', 'src-c', 'src-d']);

    // Simulate Hub offline
    const failed = await spool.flush(async () => false);
    expect(failed).toEqual({ sent: 0, remaining: 3 });

    // Simulate Hub back online
    const received: string[] = [];
    const ok = await spool.flush(async (batch) => {
      received.push(...batch.map((b) => b.provenance.source_id));
      return true;
    }, 2);
    expect(ok).toEqual({ sent: 3, remaining: 0 });
    expect(received).toEqual(['src-b', 'src-c', 'src-d']);
  });
});

describe('Article Markdown extractor', () => {
  it('extracts clean article content preserving code blocks and strips secrets', () => {
    document.title = 'Context Hub Architecture Note';
    document.body.innerHTML = `
      <nav><a href="/">Home</a><a href="/pricing">Pricing</a></nav>
      <main>
        <article>
          <h1>Context Hub Architecture Note</h1>
          <p>Context Hub v2 separates raw append-only event logs from curated Markdown memory artifacts so agents can reason over verified evidence.</p>
          <p>Run the local server with the command below and connect your MCP client cleanly without sharing secret key sk-1234567890abcdefghijklmnop.</p>
          <pre><code class="language-bash">uv run context-hub serve --port 8741</code></pre>
        </article>
      </main>
      <footer>Copyright 2026</footer>
    `;
    const extracted = extractPageArticle(document, 'https://docs.example.com/context-hub');
    expect(extracted.title).toContain('Context Hub');
    expect(extracted.markdown).toContain('uv run context-hub serve --port 8741');
    expect(extracted.markdown).toContain('[REDACTED_SECRET]');
    expect(extracted.markdown).not.toContain('sk-1234567890');
    expect(extracted.wordCount).toBeGreaterThan(20);
  });
});
