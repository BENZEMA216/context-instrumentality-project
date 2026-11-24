# Read for Agent · Browser MV3 Extension (`extensions/browser`)

Local-first Manifest V3 extension for Chrome / Arc / Edge (part of the **`X for Agent`** family powering **[Raw Memory](../../README.md)**):

> Tip: Even before loading this extension, you can pull local Chrome / Arc / Brave / Edge / Safari reading history via `uv run context-collectors sync --collector browser`. Loading this MV3 extension adds full-page Defuddle Markdown extraction, 3-layer active dwell gating, implicit highlight capture, and the Promnesia contextual sidebar.

- **3-Layer Effective Dwell Gate** (`visibilityState` ∩ `chrome.windows.onFocusChanged` ∩ `chrome.idle` 60s): only captures genuinely read pages (default ≥ 30s active dwell).
- **Defuddle + Readability Markdown Extraction**: preserves headings, lists, links, and code fences while stripping chrome/nav clutter and redacting inline secrets.
- **Zero-Friction Implicit Highlights**: lingering text selections (`> 1.2s`) and `copy` events automatically attach excerpts and elevate `curation_tier` to `auto_curated`.
- **Offline Durable Spool**: queues unsent events in `chrome.storage.local` (capped at 500 with LRU eviction) and automatically flushes when `http://127.0.0.1:8741` comes back online.
- **Promnesia-Style Contextual Sidebar**: queries `/api/v2/related?url=...` and surfaces a subtle Shadow-DOM pill linking back to past chats, clipboard copies, voice notes, and decisions in Context Workbench.

## Build & Load Unpacked

```bash
npm --prefix extensions/browser install
npm --prefix extensions/browser test
npm --prefix extensions/browser run build
```

Then open `chrome://extensions` → enable **Developer Mode** → **Load unpacked** → select `extensions/browser/dist/`.
