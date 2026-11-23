# Context Hub · Agent-Rooted Plugin (`plugins/context-hub`)

Context Hub is designed around two primary user experiences:
1. **Desktop Client / Background Collectors** (`context-collectors watch` + upcoming macOS menu bar helper)
2. **An Agent-Rooted Plugin** that gives your AI Agent (Antigravity / Codex / Claude Code / WorkBuddy) both structured Memory recall + curation tools (MCP) and **deep-linkable local Web Workbench views** opened directly from chat.

## What's Inside

- `plugin.json` — Plugin manifest declaring MCP server, skills, and Workbench deep-link routes.
- `mcp.json` — Drop-in stdio MCP configuration (`context-hub mcp`).
- `skills/context-recall/SKILL.md` — Progressive-disclosure retrieval & in-chat deep-link behavior.
- `../../skills/context-curator/SKILL.md` — Agent-as-Curator synthesis rules & evidence-gating invariants.

## Quick Setup

1. Ensure the local Hub + Collectors are installed:
   ```bash
   uv sync
   uv run context-collectors doctor
   uv run context-collectors sync
   ```
2. Optional: start the local Web Workbench server so in-chat deep links open instantaneously:
   ```bash
   uv run context-hub serve --port 8741
   ```
3. Mount `mcp.json` into your Agent host (Antigravity, Codex `.codex/config.toml`, Claude Code `.mcp.json`, or WorkBuddy MCP settings) and load `skills/context-recall/SKILL.md` + `skills/context-curator/SKILL.md`.
