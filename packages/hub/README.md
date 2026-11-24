# Raw Memory Hub (`packages/hub`)

Local-first personal raw data & evidence-gated memory engine implementing [RFC-0002](../../docs/rfc/0002-hub-v2-agent-curator.md):

- **L0 Immutable Archive (`raw/`) & L0.5 Content-Addressed Blobs (`blobs/`)**: Append-only JSONL partitioned by UTC date & source, replayable anytime via `raw-memory rebuild`.
- **L1 SQLite WAL + Hybrid BM25/RRF Search + Cross-Channel Linker**: Stopword-aware CJK/EN FTS5 with two-stage `AND → BM25 OR` retrieval, Episode↔Turn Reciprocal Rank Fusion (LongMemEval-S `96.6%` Sess R@5 @ `1.93 ms` p50), URL canonicalization, and 5-tier cross-channel linking.
- **Project Profiles (`project_profiles`)**: First-class static entity registry (official product name, repos, domains, live status lookup pointers, repo tech notes) cleanly separated from personal long-term memory.
- **L2 Episodes & Markdown Artifacts (`markdown/`)**: Automatic Episode grouping + Obsidian-friendly `MEMORY.md`, `episodes/`, `projects/`, `daily/`.
- **L3 Bi-Temporal Decisions & Personal Memories**: `active` / `superseded` / `retracted` lifecycle, `user_confirmed` vs `assistant_suggested` authority gating, and `±1`-turn conversational Q&A exchange context windows (`get_evidence_context_window`).
- **L4 Dual-Loop stdio MCP + Agent-as-Curator**: Exposes consumption tools (`get_context_pack`, `search_context`, `get_project_state`, `list_project_profiles`, `get_evidence_context`, `what_was_i_doing`, `related`, `expand`) and verified curation tools (`get_curation_rules`, `get_curation_queue`, `commit_curation_batch`, `upsert_project_profile`, `record_memory`, `correct_decision`).

## Quickstart

```sh
uv sync --extra dev
uv run raw-memory serve               # Start Hub HTTP API + Workbench on http://127.0.0.1:8741
uv run raw-memory reconcile-projects  # Re-normalize historical projects using project_aliases.json
uv run raw-memory-eval workbench      # Launch Human-in-the-Loop Debug Workbench on http://127.0.0.1:8765
```

## Connect Antigravity / Codex / Claude Code via stdio MCP

```json
{
  "mcpServers": {
    "raw-memory": {
      "command": "uv",
      "args": ["run", "--project", "/absolute/path/to/context-instrumentality-project", "raw-memory", "mcp"]
    }
  }
}
```
