export type PrivacyTier = "local_only" | "redacted" | "shareable";

export interface HubStats {
  raw_total: number;
  raw_agent_visible: number;
  episodes_total: number;
  episodes_pending_curation: number;
  decisions_active: number;
  memories_total: number;
  links_total: number;
  by_source: Record<string, number>;
  markdown_files: number;
  recent_curation_runs: CurationRun[];
  role: string;
}

export interface CurationRun {
  id: string;
  curator_agent: string;
  episodes_count: number;
  decisions_count: number;
  memories_count: number;
  links_count: number;
  notes: string;
  created_at: number;
}

export interface RawEvent {
  id: string;
  source: string;
  kind: string;
  t_start: number;
  t_end: number;
  actor?: string;
  device_id?: string;
  project?: string | null;
  episode_id?: string | null;
  title: string;
  body_text: string;
  locator?: string | null;
  privacy: { tier: PrivacyTier; pii_tags?: string[] };
  anchors?: string[];
  revision: number;
}

export interface CrossLink {
  id?: string;
  src_id: string;
  dst_id: string;
  relation: string;
  confidence: number;
  evidence: string;
  method?: string;
}

export interface Episode {
  id: string;
  title: string;
  summary: string;
  overview: string;
  project: string | null;
  primary_source: string;
  t_start: number;
  t_end: number;
  status: "pending_curation" | "curated" | "manual";
  entities: string[];
  privacy_tier: PrivacyTier;
  markdown_path: string | null;
  curated_by: string | null;
  revision: number;
  event_ids: string[];
  event_count: number;
  events?: RawEvent[];
  links?: CrossLink[];
}

export interface Decision {
  id: string;
  project: string;
  topic: string;
  statement: string;
  status: "active" | "superseded" | "retracted";
  authority: "user_confirmed" | "assistant_suggested" | "observed";
  confidence: number;
  valid_at: number;
  invalid_at: number | null;
  superseded_by: string | null;
  privacy_tier: PrivacyTier;
  curated_by: string | null;
  evidence_ids: string[];
}

export interface MemoryItem {
  id: string;
  title: string;
  body: string;
  kind: string;
  project: string | null;
  origin: string;
  tags: string[];
  privacy_tier: PrivacyTier;
  evidence_ids: string[];
  updated_at: number;
}

export interface ProjectSummary {
  project: string;
  event_count: number;
  episode_count: number;
  pending_curation: number;
  active_decisions: number;
  last_activity_ms: number;
}

export interface ProjectState {
  project: string;
  active_decisions: Decision[];
  superseded_decisions: Decision[];
  recent_episodes: Episode[];
  memories: MemoryItem[];
}

export interface SearchResult {
  query: string;
  decisions: Decision[];
  episodes: Episode[];
  memories: MemoryItem[];
  raw_matches: Array<{
    id: string;
    source: string;
    kind: string;
    actor?: string;
    project?: string | null;
    episode_id?: string | null;
    t_start: number;
    title: string;
    snippet: string;
    locator?: string | null;
  }>;
  approx_tokens: number;
}

export interface PrivacyRule {
  id: string;
  scope: "source" | "connector" | "project" | "domain";
  match_value: string;
  default_tier: PrivacyTier;
  priority: number;
  description: string;
}

export interface MarkdownFileInfo {
  path: string;
  category: string;
  size_bytes: number;
  updated_at: number;
}

export interface CurationRulesResponse {
  version: string;
  source_path: string;
  rules_markdown: string;
  prompts: Record<string, string>;
}

export interface CurationQueueResponse {
  total_pending: number;
  returned: number;
  remaining_pending: number;
  items: Array<{
    episode: {
      id: string;
      title: string;
      project: string | null;
      primary_source: string;
      t_start: number;
      t_end: number;
      revision: number;
      existing_summary: string;
    };
    events: Array<{
      id: string;
      source: string;
      actor: string;
      t_start: number;
      title: string;
      text: string;
      locator?: string | null;
      privacy_tier: PrivacyTier;
    }>;
    links: CrossLink[];
    existing_project_decisions: Decision[];
  }>;
}

export interface CollectorStatus {
  collector: string;
  source: string;
  status: string;
  items_synced: number;
  watermark: string | null;
  message: string;
  updated_at: number;
}

async function req<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, {
    ...init,
    headers: {
      Accept: "application/json",
      ...(init?.body ? { "Content-Type": "application/json" } : {}),
      ...(init?.headers ?? {}),
    },
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new Error(data.error || data.detail || `HTTP ${res.status}`);
  }
  return res.json() as Promise<T>;
}

export const api = {
  stats: () => req<HubStats>("/api/v2/stats"),
  episodes: (params?: { project?: string; status?: string; source?: string }) => {
    const qs = new URLSearchParams();
    if (params?.project) qs.set("project", params.project);
    if (params?.status) qs.set("status", params.status);
    if (params?.source) qs.set("source", params.source);
    return req<{ items: Episode[] }>(`/api/v2/episodes?${qs}`);
  },
  episode: (id: string) => req<Episode>(`/api/v2/episodes/${encodeURIComponent(id)}`),
  raw: (id: string) => req<RawEvent>(`/api/v2/events/${encodeURIComponent(id)}`),
  createEvent: (payload: Record<string, unknown>) =>
    req<{ status: string; event: RawEvent; episode_id: string }>("/api/v2/events", {
      method: "POST",
      body: JSON.stringify(payload),
    }),
  patchPrivacy: (id: string, tier: PrivacyTier) =>
    req<RawEvent>(`/api/v2/events/${encodeURIComponent(id)}/privacy`, {
      method: "PATCH",
      body: JSON.stringify({ tier }),
    }),
  deleteEvent: (id: string) =>
    req<{ deleted: boolean }>(`/api/v2/events/${encodeURIComponent(id)}`, { method: "DELETE" }),
  projects: () => req<{ items: ProjectSummary[] }>("/api/v2/projects"),
  projectState: (project: string) =>
    req<ProjectState>(`/api/v2/projects/${encodeURIComponent(project)}/state?include_history=true`),
  correctDecision: (id: string, statement: string, evidence_ids: string[]) =>
    req<Decision>(`/api/v2/decisions/${encodeURIComponent(id)}/correct`, {
      method: "POST",
      body: JSON.stringify({ statement, evidence_ids, authority: "user_confirmed" }),
    }),
  search: (q: string, source?: string, project?: string) => {
    const qs = new URLSearchParams({ q });
    if (source) qs.append("source", source);
    if (project) qs.set("project", project);
    return req<SearchResult>(`/api/v2/search?${qs}`);
  },
  curationRules: () => req<CurationRulesResponse>("/api/v2/curation/rules"),
  curationQueue: () => req<CurationQueueResponse>("/api/v2/curation/queue?limit=10&include_local_only=true"),
  markdownList: () => req<{ root: string; items: MarkdownFileInfo[] }>("/api/v2/markdown"),
  markdownFile: async (path: string) => {
    const res = await fetch(`/api/v2/markdown/file?${new URLSearchParams({ path })}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.text();
  },
  privacyRules: () => req<{ items: PrivacyRule[] }>("/api/v2/privacy/rules"),
  savePrivacyRule: (rule: Omit<PrivacyRule, "id">) =>
    req<PrivacyRule>("/api/v2/privacy/rules", { method: "POST", body: JSON.stringify(rule) }),
  deletePrivacyRule: (id: string) =>
    req<{ deleted: boolean }>(`/api/v2/privacy/rules/${encodeURIComponent(id)}`, { method: "DELETE" }),
  collectors: () => req<{ items: CollectorStatus[] }>("/api/v2/collectors/status"),
  seedDemo: () => req<{ seeded: Record<string, number> }>("/api/v2/demo/seed", { method: "POST" }),
};
