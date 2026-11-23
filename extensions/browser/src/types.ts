export interface Excerpt {
  text: string;
  kind: 'selection' | 'copy';
  captured_at: number;
  context?: string;
}

export interface BrowserRawEvent {
  source: 'browser';
  kind: 'page_read' | 'excerpt';
  t_start: number;
  t_end: number;
  device_id?: string;
  actor: 'self';
  attention?: number;
  content: {
    title: string;
    url: string;
    url_norm: string;
    text: string;
    summary?: string;
    author?: string;
    site?: string;
    excerpts?: Excerpt[];
  };
  context: {
    dwell_ms: number;
    scroll_depth: number;
    curation_tier: 'raw' | 'auto_curated';
    extractor: 'defuddle' | 'readability' | 'dom_fallback';
    word_count: number;
  };
  provenance: {
    connector: 'browser-mv3';
    source_id: string;
    locator: string;
  };
}

export interface ExtensionSettings {
  hubUrl: string;
  ownerToken: string;
  enabled: boolean;
  sidebarEnabled: boolean;
  minDwellMs: number;
  blockedDomains: string[];
}

export const DEFAULT_SETTINGS: ExtensionSettings = {
  hubUrl: 'http://127.0.0.1:8741',
  ownerToken: '',
  enabled: true,
  sidebarEnabled: true,
  minDwellMs: 30_000,
  blockedDomains: [],
};

export interface RelatedItem {
  id: string;
  kind?: string;
  source?: string;
  title?: string;
  snippet?: string;
  project?: string;
  relation?: string;
  t_start?: number;
  episode_id?: string;
}

export interface RelatedResponse {
  items: RelatedItem[];
  hubOnline: boolean;
}
