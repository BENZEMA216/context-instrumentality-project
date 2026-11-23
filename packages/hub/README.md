# Context Hub v2

Local-first personal context engine implementing [RFC-0002](../../docs/rfc/0002-hub-v2-agent-curator.md):

- **L0 Immutable Archive (`raw/`)**: Append-only JSONL partitioned by UTC date & source, replayable anytime via `context-hub rebuild`.
- **L1 SQLite WAL + CJK/EN FTS5 + Deterministic Cross-Channel Linker**: Sub-50ms search, URL canonicalization, `same_anchor`, `copy_of`, `during`, and `related` links.
- **L2 Episodes & Markdown Artifacts (`markdown/`)**: Automatic Episode grouping + YAML Frontmatter `.md` notes (`episodes/`, `projects/`, `daily/`) ready for Obsidian.
- **L3 Bi-Temporal Decisions (`decisions`)**: Tracks `active` vs `superseded` (`superseded_by`) decisions distinguishing `user_confirmed` vs `assistant_suggested`.
- **L4 Dual-Loop MCP + Agent-as-Curator**: Exposes both high-level consumption tools (`what_was_i_doing`, `search_context`, `get_project_state`, `related`, `expand`) and verified curation tools (`get_curation_rules`, `get_curation_queue`, `commit_curation_batch`) so **Antigravity / Codex / WorkBuddy / Claude Code** curate your context using your existing Agent compute.

## Quickstart

```sh
# From repository root
uv sync --all-extras
npm --prefix web install && npm --prefix web run build

# Start Hub + Workbench UI on http://127.0.0.1:8741
uv run context-hub serve

# Optional: load synthetic cross-channel demo data
uv run context-hub seed-demo

# Open Workbench in browser
uv run context-hub open
```

## Connect Antigravity / Codex / WorkBuddy via stdio MCP

```json
{
  "mcpServers": {
    "context_hub": {
      "command": "uv",
      "args": ["run", "--project", "/absolute/path/to/context-instrumentality-project", "context-hub", "mcp"]
    }
  }
}
```

Print a ready-to-use Agent-as-Curator prompt:

```sh
uv run context-hub curate-prompt --agent antigravity
```
