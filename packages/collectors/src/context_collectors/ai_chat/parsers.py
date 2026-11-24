"""Multi-provider AI Chat parsers producing Context Hub v2 `RawEventIn` records.

Supported live local stores (incremental):
- Antigravity (`~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`)
- Codex CLI / Desktop (`~/.codex/sessions/**/*.jsonl`, `.zst`/`.zstd`)
- Claude Code (`~/.claude/projects/**/*.jsonl`)
- Cursor (`state.vscdb` + `workspaceStorage/*/workspace.json`)
- OpenCode (`opencode.db`)
- WorkBuddy (JSONL with `<user_query>` unwrapping)
- QClaw (JSONL with fenced untrusted-metadata unwrapping)
- DeepSeek Harness (JSONL)

Supported export archives:
- ChatGPT (`conversations.json`)
- Claude.ai Web (`conversations.json`)
- Gemini CLI / Export JSON
- Generic `transcript` JSON
"""

from __future__ import annotations

import datetime
import hashlib
import json
import math
import re
from collections import defaultdict
from pathlib import Path
from typing import Any

from context_hub.models import RawEventIn
from context_hub.project_resolver import normalize_project_slug, project_from_path

from ..runtime import default_device_id, open_maybe_zstd, open_readonly_sqlite

_ABS_PATH_RE = re.compile(r"(/(?:Users|home|workspace|Volumes)/[^\s\"'`<>|()]+)")
_ANTIGRAVITY_SENDER_RE = re.compile(r"\bsender=([A-Za-z0-9_-]{8,128})\b")

# ----------------------------------------------------------------------
# Reflexive Session Memory Defenses (No-Echo / Anti-Loop) & Signal Hints
# ----------------------------------------------------------------------
_USER_REQUEST_RE = re.compile(
    r"<USER_REQUEST\b[^>]*>(.*?)</USER_REQUEST>",
    re.IGNORECASE | re.DOTALL,
)
_SYSTEM_MESSAGE_BLOCK_RE = re.compile(
    r"(?:The following is a <SYSTEM_MESSAGE>[^\n]*(?:\n|$))?\s*<SYSTEM_MESSAGE\b[^>]*>.*?</SYSTEM_MESSAGE>",
    re.IGNORECASE | re.DOTALL,
)
_REFLEXIVE_PAIRED_TAG_RES: tuple[re.Pattern[str], ...] = (
    _SYSTEM_MESSAGE_BLOCK_RE,
    re.compile(r"<CONTEXT_SUMMARY\b[^>]*>.*?</CONTEXT_SUMMARY>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<ADDITIONAL_METADATA\b[^>]*>.*?</ADDITIONAL_METADATA>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<context_hub_memory\b[^>]*>.*?</context_hub_memory>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<context_pack\b[^>]*>.*?</context_pack>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<memory_index\b[^>]*>.*?</memory_index>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<heartbeat\b[^>]*>.*?</heartbeat>", re.IGNORECASE | re.DOTALL),
)
_USER_ENVELOPE_PAIRED_TAG_RES: tuple[re.Pattern[str], ...] = (
    re.compile(r"(?m)^# AGENTS\.md instructions for [^\n]*\n.*?<INSTRUCTIONS>.*?</INSTRUCTIONS>", re.DOTALL),
    re.compile(r"<environment_context\b[^>]*>.*?</environment_context>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<subagent_notification\b[^>]*>.*?</subagent_notification>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<turn_aborted\b[^>]*>.*?</turn_aborted>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<permissions instructions\b[^>]*>.*?</permissions instructions>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<system-reminder\b[^>]*>.*?</system-reminder>", re.IGNORECASE | re.DOTALL),
    re.compile(
        r"<external_codex_apps_open_page\b[^>]*>.*?</external_codex_apps_open_page>",
        re.IGNORECASE | re.DOTALL,
    ),
    re.compile(
        r"<in-app-browser-context\b[^>]*>.*?</in-app-browser-context>",
        re.IGNORECASE | re.DOTALL,
    ),
    re.compile(r"<task-notification\b[^>]*>.*?</task-notification>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<local-command-caveat\b[^>]*>.*?</local-command-caveat>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<local-command-stdout\b[^>]*>.*?</local-command-stdout>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<command-name\b[^>]*>.*?</command-name>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<command-message\b[^>]*>.*?</command-message>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<command-args\b[^>]*>.*?</command-args>", re.IGNORECASE | re.DOTALL),
)

_MCP_ECHO_FAST_MARKERS: tuple[str, ...] = (
    "content_is_untrusted_data",
    "active_decisions",
    "raw_evidence",
    "raw_matches",
    "workbench_urls",
    "rendered_markdown",
    "get_context_pack",
    "search_context",
    "what_was_i_doing",
    "get_project_state",
    "get_curation_queue",
)
_MCP_TOOL_NAMES = frozenset(
    {
        "get_context_pack",
        "search_context",
        "what_was_i_doing",
        "get_project_state",
        "get_curation_queue",
    }
)
_MCP_PAYLOAD_HINT_KEYS = frozenset(
    {
        "active_decisions",
        "raw_evidence",
        "raw_matches",
        "workbench_urls",
        "rendered_markdown",
        "pending_episodes",
    }
)
_FENCED_JSON_WITH_LABEL_RE = re.compile(
    r"(?:^|\n)(?:(?:(?:#{1,4}\s*)?(?:tool(?:\s+(?:output|result))?\s*[:(\-]?\s*)?"
    r"(?:get_context_pack|search_context|what_was_i_doing|get_project_state|get_curation_queue)"
    r"[^\n]*\n)?)```(?:json)?[ \t]*\n([\s\S]*?)\n```[ \t]*(?=\n|$)",
    re.IGNORECASE,
)
_MCP_INLINE_LABEL_RE = re.compile(
    r"(?m)^(?:(?:#{1,4}\s*)?(?:tool(?:\s+(?:output|result))?\s*[:(\-]?\s*)?"
    r"(?:get_context_pack|search_context|what_was_i_doing|get_project_state|get_curation_queue)"
    r"[^\n{]*:\s*)$",
    re.IGNORECASE,
)
_MEMORY_MD_HEADING_RE = re.compile(
    r"^#{1,2}\s+(?:Context Hub Memory\b|Personal Context Memory Index\b|Context Hub Context Pack\b)",
    re.IGNORECASE,
)
_MEMORY_INDEX_HEADER_RE = re.compile(
    r"^(?:(?:#{1,3}\s*)?(?:(?:MCP\s+)?Resource|Source|Injected\s+Memory)\s*:\s*)?"
    r"`?context://memory-index`?\s*$",
    re.IGNORECASE,
)
_MEMORY_FENCED_RE = re.compile(
    r"(?:^|\n)```(?:markdown|md|yaml)?[ \t]*\n([\s\S]*?)\n```[ \t]*(?=\n|$)",
    re.IGNORECASE,
)
_HR_LINE_RE = re.compile(r"^\s*(?:---+|\*\*\*+|___+)\s*$")
_END_MEMORY_COMMENT_RE = re.compile(
    r"<!--\s*end[_ -]?(?:context[_ -]?hub[_ -]?memory|memory[_ -]?index)\s*-->",
    re.IGNORECASE,
)

# Deterministic high-signal pre-annotation patterns
_USER_CORRECTION_RE = re.compile(
    r"(?:"
    r"(?:^|[\s，。；！？、,!?;:：])(?:不对|搞错了|理解错了|写错了|改错了|说错了|弄错了|错了)"
    r"|(?:^|[\s，。；！？、,!?;:：])(?:不是(?:这[样个里种]|那[样个里种]|要|让你|叫|用|[，,。！!\s])|其实不是|并不是|并非)"
    r"|(?:别用|不要用|不要改|别改|别动|不要动|不要删|别删|别把|不要把)"
    r"|(?:改回|改为|改成|换成|退回|回滚|撤销|恢复成|恢复到|其实应该是|应该是|应该用|应该叫|而不是|而非)"
    r"|\b(?:that'?s\s+wrong|you'?re\s+wrong|(?:that|this|it)\s+is\s+wrong|got\s+it\s+wrong|"
    r"wrong\s+(?:file|path|branch|model|port|dir|directory|approach|version|name|one|choice|answer|repo|table|column|command|tool)|"
    r"no,\s*(?:use|do|don'?t|not|keep|make|switch|change|that'?s|it'?s)|"
    r"don'?t\s+(?:use|change|modify|touch|edit|delete|remove)|"
    r"do\s+not\s+(?:use|change|modify|touch|edit|delete|remove)|"
    r"never\s+use|stop\s+using|instead\s+of|rather\s+than|"
    r"actually,?\s+(?:it'?s|use|it\s+should|we\s+should|no|not)|"
    r"revert|roll\s*back|rollback)\b"
    r"|^\s*wrong\b"
    r")",
    re.IGNORECASE | re.MULTILINE,
)

_USER_DECISION_RE = re.compile(
    r"(?:"
    r"(?:就用|就按|就这么|就这样|那就用|那就按|那就叫|就叫|定了|敲定|拍板|统一叫|统一用|统一改叫|"
    r"确认用|确认按|确认这个|确定用|按这个方案|采纳|锁定方案|锁定架构)"
    r"|\b(?:let'?s\s+go\s+with|we'?ll\s+go\s+with|go\s+with\s+(?:option|plan|approach|this|that|[a-z0-9_-]+)|"
    r"approved|confirmed|ship\s+it|lock\s+(?:it|this)\s+in|lgtm|"
    r"decided\s+(?:on|to\s+use)|standardize\s+on)\b"
    r")",
    re.IGNORECASE,
)

_VERIFIED_OUTCOME_RE = re.compile(
    r"(?:"
    r"\b[1-9]\d*\s+passed\b(?!\s*,?\s*[1-9]\d*\s+(?:failed|errors?))"
    r"|\b(?:pytest|unittest|vitest|jest|cargo\s+test|go\s+test|npm\s+test|pnpm\s+test|"
    r"ruff|mypy|pyright|tsc|eslint|xcodebuild|swift\s+test|swift\s+build|build)\b"
    r"[^\n]{0,80}\b(?:passed(?!\s*,?\s*[1-9]\d*\s+(?:failed|errors?))|succeeded|success|clean|0\s+errors?|all\s+checks\s+passed|green|ok)\b"
    r"(?![^\n]{0,30}\b[1-9]\d*\s+(?:failed|errors?)\b)"
    r"|\b(?:BUILD\s+SUCCEEDED|TEST\s+SUCCEEDED|All\s+checks\s+passed|All\s+[1-9]\d*\s+tests?\s+pass(?:ed)?)\b"
    r"|(?:测试(?:全部)?通过|全部通过|构建成功|编译通过|验证通过|检查通过|ruff\s*通过|pytest\s*通过|[1-9]\d*\s*(?:项|个|条)?测试(?:全部)?通过)"
    r"|\b(?:committed|pushed|merged)\b[^\n]{0,60}\b[0-9a-f]{7,40}\b"
    r"|\b(?:pushed\s+to\s+(?:origin|main|master|[a-zA-Z0-9/_-]+)|(?:created|merged)\s+(?:PR|pull\s+request)\s+#?\d+)\b"
    r"|(?:已提交|已推送|提交\s*(?:SHA|commit)?)\s*[:：]?\s*`?[0-9a-f]{7,40}`?"
    r"|(?:(?:已(?:创建|写入|更新|修改|保存|生成)|(?:created|wrote|written|updated|saved|modified)\s+(?:file|files)?)\s*[:：]?\s*"
    r"(?:`[^`\n]+(?:\.[a-zA-Z0-9]{1,8}|/)[^`\n]*`|\[[^\]]+\]\(file://))"
    r")",
    re.IGNORECASE,
)


def _is_echoed_mcp_payload(obj: Any) -> bool:
    if not isinstance(obj, dict) or not obj:
        return False
    keys = set(obj.keys())
    if obj.get("content_is_untrusted_data") is True and bool(
        keys & (_MCP_PAYLOAD_HINT_KEYS | {"episodes", "decisions", "memories", "window", "project"})
    ):
        return True
    if len(keys & _MCP_PAYLOAD_HINT_KEYS) >= 2:
        return True
    if {"decisions", "episodes", "memories", "raw_matches"}.issubset(keys):
        return True
    if {"window", "episodes", "active_decisions"}.issubset(keys):
        return True
    if {"active_decisions", "memories", "episodes"}.issubset(keys):
        return True
    tool_name = str(obj.get("tool") or obj.get("tool_name") or obj.get("name") or "")
    return tool_name in _MCP_TOOL_NAMES and bool(
        keys & {"result", "output", "payload", "data", "content", "active_decisions", "episodes", "raw_matches"}
    )


def _strip_echoed_mcp_json(text: str) -> tuple[str, bool]:
    if not any(marker in text for marker in _MCP_ECHO_FAST_MARKERS):
        return text, False

    stripped = False

    def _replace_fenced(match: re.Match[str]) -> str:
        nonlocal stripped
        body = match.group(1).strip()
        if not body.startswith("{"):
            return match.group(0)
        try:
            parsed = json.loads(body)
        except ValueError:
            return match.group(0)
        if _is_echoed_mcp_payload(parsed):
            stripped = True
            return "\n"
        return match.group(0)

    out = _FENCED_JSON_WITH_LABEL_RE.sub(_replace_fenced, text)

    # Scan standalone or line-starting raw JSON objects (e.g. pasted tool results without fences)
    if "{" in out and any(marker in out for marker in _MCP_ECHO_FAST_MARKERS):
        decoder = json.JSONDecoder()
        chunks: list[str] = []
        cursor = 0
        idx = 0
        length = len(out)
        while idx < length:
            brace = out.find("{", idx)
            if brace == -1:
                break
            line_start = out.rfind("\n", 0, brace) + 1
            prefix = out[line_start:brace]
            prefix_ok = not prefix.strip() or bool(_MCP_INLINE_LABEL_RE.match(prefix))
            if not prefix_ok:
                idx = brace + 1
                continue
            try:
                parsed, end = decoder.raw_decode(out, brace)
            except ValueError:
                idx = brace + 1
                continue
            if _is_echoed_mcp_payload(parsed):
                cut_start = line_start
                # Also drop an immediately preceding tool-label-only line if present
                if cut_start > cursor:
                    prev_text = out[cursor:cut_start].rstrip("\r\n")
                    prev_nl = prev_text.rfind("\n")
                    prev_line = prev_text[prev_nl + 1 :] if prev_nl != -1 else prev_text
                    if _MCP_INLINE_LABEL_RE.match(prev_line.strip()):
                        cut_start = cursor + (prev_nl + 1 if prev_nl != -1 else 0)
                chunks.append(out[cursor:cut_start])
                cursor = end
                idx = end
                stripped = True
            else:
                idx = brace + 1
        if stripped and cursor > 0:
            chunks.append(out[cursor:])
            out = "".join(chunks)

    return out, stripped


def _strip_injected_memory_markdown(text: str) -> tuple[str, bool]:
    lower = text.lower()
    if not (
        "context hub memory" in lower
        or "personal context memory index" in lower
        or "context hub context pack" in lower
        or "context://memory-index" in lower
        or "type: memory_index" in lower
    ):
        return text, False

    stripped = False

    # 1. Strip fenced markdown blocks carrying injected memory index/pack
    def _replace_fenced_md(match: re.Match[str]) -> str:
        nonlocal stripped
        inner = match.group(1)
        inner_low = inner.lower()
        first_nonempty = next((ln.strip() for ln in inner.splitlines() if ln.strip()), "")
        if (
            _MEMORY_MD_HEADING_RE.match(first_nonempty)
            or _MEMORY_INDEX_HEADER_RE.match(first_nonempty)
            or ("type: memory_index" in inner_low and first_nonempty == "---")
        ):
            stripped = True
            return "\n"
        return match.group(0)

    out = _MEMORY_FENCED_RE.sub(_replace_fenced_md, text)

    # 2. Line-by-line stripping of unfenced injected Memory sections
    lines = out.splitlines()
    kept: list[str] = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        s = line.strip()

        # Detect YAML frontmatter with `type: memory_index` followed by Memory Index markdown
        starts_frontmatter_mem = False
        fm_end = -1
        if s == "---":
            j = i + 1
            saw_mem_type = False
            while j < n and j - i <= 25:
                js = lines[j].strip()
                if js == "---":
                    fm_end = j
                    break
                if re.match(r"^type\s*:\s*memory_index\s*$", js, re.IGNORECASE):
                    saw_mem_type = True
                j += 1
            if saw_mem_type and fm_end != -1:
                starts_frontmatter_mem = True

        if starts_frontmatter_mem or _MEMORY_MD_HEADING_RE.match(s) or _MEMORY_INDEX_HEADER_RE.match(s):
            stripped = True
            i = (fm_end + 1) if starts_frontmatter_mem else (i + 1)
            # Consume optional YAML frontmatter immediately after `context://memory-index` header
            while i < n and not lines[i].strip():
                i += 1
            if i < n and lines[i].strip() == "---":
                j = i + 1
                while j < n and j - i <= 25 and lines[j].strip() != "---":
                    j += 1
                if j < n and lines[j].strip() == "---":
                    i = j + 1

            blank_seen = False
            while i < n:
                cur = lines[i]
                cs = cur.strip()
                if not cs:
                    blank_seen = True
                    i += 1
                    continue
                if _END_MEMORY_COMMENT_RE.search(cs):
                    i += 1
                    break
                if _HR_LINE_RE.match(cs):
                    i += 1
                    break
                if cs.startswith("<USER_REQUEST"):
                    break
                if _MEMORY_MD_HEADING_RE.match(cs) or _MEMORY_INDEX_HEADER_RE.match(cs):
                    blank_seen = False
                    i += 1
                    continue
                if cs.startswith("# "):
                    # New unrelated top-level heading starts user content
                    break
                is_md_struct = (
                    cs.startswith(("##", "###", "####", "- ", "* ", "> ", "|", "_"))
                    or cur.startswith(("  ", "\t"))
                )
                if is_md_struct:
                    blank_seen = False
                    i += 1
                    continue
                if blank_seen:
                    # Plain prose paragraph after a blank line -> real human/assistant content
                    break
                i += 1
            continue

        kept.append(line)
        i += 1

    if stripped:
        return "\n".join(kept), True
    return out, False


def sanitize_turn_text(role: str, text: str) -> tuple[str, bool]:
    """Strip injected runtime/memory/MCP echo blocks and unwrap `<USER_REQUEST>`.

    Returns `(cleaned_text, reflexive_filtered)`:
    - If the turn becomes empty (or only an unclosed blocked envelope remains),
      returns `("", True)` so callers drop it completely.
    - If injected/echoed blocks were stripped while real human/assistant text
      remains, returns `(cleaned_text, True)`.
    - If no injected/echoed blocks were present, returns `(cleaned_text, False)`.
    """
    if not isinstance(text, str) or not text.strip():
        return "", False

    filtered = False
    cur = text

    def _strip_blocks(buf: str) -> str:
        nonlocal filtered
        for pat in _REFLEXIVE_PAIRED_TAG_RES:
            new_buf, cnt = pat.subn("\n", buf)
            if cnt:
                filtered = True
                buf = new_buf
        if role == "user":
            for pat in _USER_ENVELOPE_PAIRED_TAG_RES:
                new_buf, cnt = pat.subn("\n", buf)
                if cnt:
                    filtered = True
                    buf = new_buf
        buf, did_md = _strip_injected_memory_markdown(buf)
        if did_md:
            filtered = True
        buf, did_json = _strip_echoed_mcp_json(buf)
        if did_json:
            filtered = True
        return buf

    cur = _strip_blocks(cur)

    # Unwrap Antigravity `<USER_REQUEST>...</USER_REQUEST>` cleanly
    if role == "user" and "<USER_REQUEST" in cur.upper():
        matches = list(_USER_REQUEST_RE.finditer(cur))
        if matches:
            outside = _USER_REQUEST_RE.sub("", cur).strip()
            inner_parts = [m.group(1).strip() for m in matches if m.group(1).strip()]
            combined = "\n\n".join(inner_parts)
            if outside:
                combined = f"{combined}\n\n{outside}" if combined else outside
            cur = _strip_blocks(combined)

    cur = re.sub(r"\n{3,}", "\n\n", cur).strip()
    if not cur:
        return "", True
    if not is_human_visible_turn(role, cur):
        return "", True
    return cur, filtered


def extract_signal_hints(
    role: str,
    text: str,
    *,
    step_meta: dict[str, Any] | None = None,
) -> list[str]:
    """Attach lightweight deterministic high-signal cues without fabricating memories."""
    hints: list[str] = []
    if role == "user":
        if _USER_CORRECTION_RE.search(text):
            hints.append("user_correction")
        if _USER_DECISION_RE.search(text):
            hints.append("user_decision")
    elif role == "assistant":
        meta_verified = bool(
            step_meta
            and (
                step_meta.get("verified_outcome")
                or step_meta.get("written_files")
                or step_meta.get("checks_passed")
                or step_meta.get("commit_sha")
            )
        )
        if meta_verified or _VERIFIED_OUTCOME_RE.search(text):
            hints.append("verified_outcome")
    return hints


def parse_timestamp_ms(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
        return round(value if abs(value) >= 100_000_000_000 else 1000 * value)
    if isinstance(value, str) and value.strip():
        try:
            dt = datetime.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.UTC)
            return round(dt.timestamp() * 1000)
        except ValueError:
            return None
    return None


def safe_id(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = value.strip()
    if not cleaned or len(cleaned) > 512 or not cleaned.isprintable():
        return None
    return cleaned


def extract_text_blocks(content: Any, allowed_types: tuple[str, ...]) -> str:
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for item in content:
        if isinstance(item, str):
            parts.append(item)
        elif (
            isinstance(item, dict)
            and item.get("type", "") in allowed_types
            and isinstance(item.get("text"), str)
        ):
            parts.append(item["text"])
    return "\n".join(parts).strip()


def is_human_visible_turn(role: str, text: str) -> bool:
    """Filter out injected runtime envelopes that carry `role=user` without human authorship."""
    if not text or not text.strip():
        return False
    if role != "user":
        return True
    stripped = text.lstrip()
    if stripped.startswith("# AGENTS.md instructions for "):
        before, closing, after = stripped.partition("</INSTRUCTIONS>")
        if closing and "<INSTRUCTIONS>" in before and (
            not after.strip()
            or re.fullmatch(
                r"\s*<environment_context>.*?</environment_context>\s*", after, re.S
            )
        ):
            return False
    blocked_prefixes = (
        "<environment_context>",
        "<subagent_notification>",
        "<turn_aborted>",
        "<permissions instructions>",
        "<system-reminder>",
        "<local-command-caveat>",
        "<local-command-stdout>",
        "<CONTEXT_SUMMARY>",
        "<SYSTEM_MESSAGE>",
        "<ADDITIONAL_METADATA>",
        "<context_hub_memory>",
        "<command-name>",
        "<heartbeat>",
        "<external_codex_apps_open_page>",
        "<task-notification>",
    )
    return not stripped.startswith(blocked_prefixes)


def unwrap_workbuddy_user(text: str) -> str:
    if re.match(r"\s*<(?:system-reminder|additional_data)(?=[\s>])", text):
        match = re.search(r"<user_query>(.*?)</user_query>\s*$", text, re.S)
        if not match:
            return ""
        return match.group(1).strip("\r\n")
    return text


def unwrap_qclaw_user(text: str) -> str:
    labels = (
        "Conversation info (untrusted metadata):",
        "Sender (untrusted metadata):",
        "Forwarded message context (untrusted metadata):",
    )
    while text.startswith(labels):
        label, _, rest = text.partition("\n")
        if label not in labels:
            break
        fence = "```"
        opening, _, tail = rest.partition("\n")
        if opening.strip() != fence + "json":
            return ""
        try:
            _, end = json.JSONDecoder().raw_decode(tail.lstrip())
        except ValueError:
            return ""
        remainder = tail.lstrip()[end:].lstrip("\r\n")
        if remainder.split("\n", 1)[0].rstrip("\r") != fence:
            return ""
        text = remainder.partition("\n")[2].lstrip("\r\n")
    return text


def make_chat_event(
    *,
    provider: str,
    session_id: str,
    message_id: str,
    role: str,
    text: str,
    timestamp_ms: int | None,
    project: str | None = None,
    cwd: str | None = None,
    origin: str = "user",
    locator: str | None = None,
    parent_message_id: str | None = None,
    parent_session_id: str | None = None,
    order: int | None = None,
    turn_index: int | None = None,
    is_subagent: bool | None = None,
    reflexive_filtered: bool = False,
    signal_hints: list[str] | None = None,
    step_meta: dict[str, Any] | None = None,
    device_id: str | None = None,
) -> RawEventIn:
    connector = f"chat-history/{provider}"
    source_id = f"{session_id}:{message_id}"
    resolved_project = (
        normalize_project_slug(project) if project else None
    ) or project_from_path(cwd)
    ts = timestamp_ms if timestamp_ms is not None and timestamp_ms >= 0 else 0
    cleaned_text = text.strip()
    first_line = cleaned_text.splitlines()[0][:100] if cleaned_text else f"{provider} turn"
    title = f"[{provider}] {first_line}"

    effective_is_subagent = bool(is_subagent) or origin == "subagent" or bool(parent_session_id)
    effective_origin = "subagent" if effective_is_subagent and origin == "user" else origin
    computed_hints = (
        list(signal_hints)
        if signal_hints is not None
        else extract_signal_hints(role, cleaned_text, step_meta=step_meta)
    )

    context: dict[str, Any] = {
        "session_id": session_id,
        "provider": provider,
        "role": role,
        "origin": effective_origin,
    }
    if resolved_project:
        context["project"] = resolved_project
    if cwd:
        context["cwd"] = cwd
    if parent_session_id:
        context["parent_session_id"] = parent_session_id
    if effective_is_subagent:
        context["is_subagent"] = True
    if reflexive_filtered:
        context["reflexive_filtered"] = True
    if computed_hints:
        context["signal_hints"] = computed_hints
    if timestamp_ms is None:
        context["timestamp_status"] = "missing"
    if order is not None:
        context["source_order"] = order
    if turn_index is not None:
        context["turn_index"] = turn_index

    links: list[dict[str, Any]] = []
    if parent_message_id:
        context["parent_message_id"] = parent_message_id

    return RawEventIn(
        source="ai_chat",
        kind="chat_turn",
        t_start=ts,
        t_end=ts,
        device_id=device_id or default_device_id(),
        actor="self" if role == "user" else provider,
        project=resolved_project,
        content={
            "role": role,
            "title": title,
            "text": cleaned_text,
            "source_hash": hashlib.sha256(cleaned_text.encode("utf-8")).hexdigest(),
        },
        context=context,
        links=links,
        provenance={
            "connector": connector,
            "source_id": source_id,
            "locator": locator or f"{provider}://{session_id}#{message_id}",
        },
    )


# ----------------------------------------------------------------------
# 1. Antigravity Transcript Parser (Incremental JSONL)
# ----------------------------------------------------------------------
def _infer_project_from_antigravity_step(obj: dict[str, Any]) -> tuple[str | None, str | None]:
    """Infer workspace cwd/project from tool_calls or user prompt paths without storing tool dumps."""
    for tc in obj.get("tool_calls") or []:
        if not isinstance(tc, dict):
            continue
        args = tc.get("arguments") or tc.get("args") or {}
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except ValueError:
                args = {}
        if not isinstance(args, dict):
            continue
        for key in ("Path", "path", "CommandLine", "cwd", "Directory"):
            val = args.get(key)
            if isinstance(val, str):
                match = _ABS_PATH_RE.search(val)
                if match:
                    cand = match.group(1).rstrip(".,;:")
                    if "/.gemini/" in cand or "/.local/" in cand:
                        continue
                    proj = project_from_path(cand)
                    if proj:
                        return proj, cand
    content = obj.get("content")
    if isinstance(content, str):
        for match in _ABS_PATH_RE.finditer(content):
            cand = match.group(1).rstrip(".,;:")
            if "/.gemini/" in cand:
                continue
            proj = project_from_path(cand)
            if proj:
                return proj, cand
    return None, None


def parse_antigravity_records(
    records: list[tuple[int, dict[str, Any]]],
    *,
    conversation_id: str,
    path: Path,
    state: dict[str, Any] | None = None,
    project: str | None = None,
) -> tuple[list[RawEventIn], dict[str, Any]]:
    """Parse incremental Antigravity `transcript.jsonl` lines into clean user/assistant turns."""
    meta = dict(state or {})
    known_project = project or meta.get("project")
    known_cwd = meta.get("cwd")
    seen_user_input = bool(meta.get("seen_user_input"))
    is_subagent = bool(meta.get("is_subagent"))
    parent_session_id: str | None = meta.get("parent_session_id")
    turn_index = int(meta.get("turn_index") or 0)
    events: list[RawEventIn] = []

    for line_no, obj in records:
        if not known_project:
            inferred_proj, inferred_cwd = _infer_project_from_antigravity_step(obj)
            if inferred_proj:
                known_project = inferred_proj
                known_cwd = inferred_cwd

        step_type = obj.get("type")
        if step_type == "USER_INPUT":
            seen_user_input = True
        elif step_type == "SYSTEM_MESSAGE" and not seen_user_input:
            raw_sys = obj.get("content")
            if isinstance(raw_sys, str) and "sender=" in raw_sys:
                is_subagent = True
                m_sender = _ANTIGRAVITY_SENDER_RE.search(raw_sys)
                if m_sender and not parent_session_id:
                    parent_session_id = safe_id(m_sender.group(1))
            continue

        if step_type not in ("USER_INPUT", "PLANNER_RESPONSE"):
            continue
        content = obj.get("content")
        if not isinstance(content, str) or not content.strip():
            # Tool-only PLANNER_RESPONSE steps carry thinking/tool_calls without visible content
            continue
        role = "user" if step_type == "USER_INPUT" else "assistant"
        cleaned, reflexive_filtered = sanitize_turn_text(role, content)
        if not cleaned:
            continue
        step_idx = obj.get("step_index")
        msg_id = f"step-{step_idx}" if isinstance(step_idx, int) else f"line-{line_no}"
        ts = parse_timestamp_ms(obj.get("created_at"))
        source_tag = str(obj.get("source") or "")
        if is_subagent:
            origin = "subagent"
        else:
            origin = "user" if source_tag in ("USER_EXPLICIT", "MODEL", "") else "automation"
        step_meta: dict[str, Any] | None = None
        if role == "assistant" and not obj.get("error"):
            written: list[str] = []
            for tc in obj.get("tool_calls") or []:
                if isinstance(tc, dict) and tc.get("name") in ("write_file", "edit_file"):
                    args = tc.get("arguments") or tc.get("args") or {}
                    if isinstance(args, dict):
                        fp = args.get("Path") or args.get("path")
                        if isinstance(fp, str) and fp.strip():
                            written.append(fp.strip())
            if written:
                step_meta = {"written_files": written}
        events.append(
            make_chat_event(
                provider="antigravity",
                session_id=conversation_id,
                message_id=msg_id,
                role=role,
                text=cleaned,
                timestamp_ms=ts,
                project=known_project,
                cwd=known_cwd,
                origin=origin,
                parent_session_id=parent_session_id,
                is_subagent=is_subagent,
                reflexive_filtered=reflexive_filtered,
                step_meta=step_meta,
                locator=f"antigravity://{conversation_id}#{msg_id}",
                order=step_idx if isinstance(step_idx, int) else line_no,
                turn_index=turn_index,
            )
        )
        turn_index += 1

    meta["project"] = known_project
    meta["cwd"] = known_cwd
    meta["seen_user_input"] = seen_user_input
    meta["is_subagent"] = is_subagent
    meta["parent_session_id"] = parent_session_id
    meta["turn_index"] = turn_index
    return events, meta


# ----------------------------------------------------------------------
# 2. Codex CLI / Desktop Rollout Parser (`.jsonl` and `.zst`/`.zstd`)
# ----------------------------------------------------------------------
def parse_codex_file(path: Path, *, project: str | None = None) -> list[RawEventIn]:
    """Parse a Codex rollout file while deduplicating native/legacy/response wire formats."""
    found = re.search(r"([0-9a-fA-F-]{36})\.jsonl(?:\.zstd?)?$", path.name)
    session = found.group(1) if found else None
    origin = "unknown"
    cwd: str | None = None
    parent_session_id: str | None = None
    is_subagent = False
    native: dict[str, tuple[str, str, str, Any, int, bool]] = {}
    legacy: list[tuple[str, str, str, Any, int, bool]] = []
    messages: list[tuple[str, str, str, Any, int, bool]] = []
    own = False

    with open_maybe_zstd(path) as stream:
        for number, raw_line in enumerate(stream, 1):
            if not raw_line.strip():
                continue
            try:
                obj = json.loads(raw_line)
            except (ValueError, UnicodeError):
                continue
            if not isinstance(obj, dict):
                continue
            tag, p = obj.get("type"), obj.get("payload")
            if not isinstance(p, dict):
                continue
            if tag == "session_meta":
                ids = (p.get("id"), p.get("session_id"))
                session = session or next((i for i in ids if isinstance(i, str) and i), None)
                own = bool(session and session in ids)
                if own:
                    if isinstance(p.get("cwd"), str):
                        cwd = p["cwd"]
                    category, src = p.get("thread_source"), p.get("source")
                    subagent_meta = src.get("subagent") if isinstance(src, dict) else None
                    thread_spawn = (
                        subagent_meta.get("thread_spawn")
                        if isinstance(subagent_meta, dict)
                        else None
                    )
                    parent_tid = safe_id(
                        p.get("parent_thread_id")
                        or (thread_spawn.get("parent_thread_id") if isinstance(thread_spawn, dict) else None)
                        or (subagent_meta.get("parent_thread_id") if isinstance(subagent_meta, dict) else None)
                    )
                    if parent_tid:
                        parent_session_id = parent_tid
                    if (
                        parent_tid
                        or p.get("agent_path")
                        or category == "subagent"
                        or (isinstance(src, dict) and "subagent" in src)
                    ):
                        origin = "subagent"
                        is_subagent = True
                    elif category == "automation" or src == "exec":
                        origin = "automation"
                    elif category == "user" or src in ("vscode", "cli", "desktop"):
                        origin = "user"
                continue
            item = p.get("item") or {}
            if (
                tag == "event_msg"
                and p.get("type") == "item_completed"
                and item.get("type") in ("UserMessage", "AgentMessage")
            ):
                if (p.get("thread_id") and session != p["thread_id"]) or (
                    not p.get("thread_id") and not own
                ):
                    continue
                role = "user" if item["type"] == "UserMessage" else "assistant"
                text = extract_text_blocks(item.get("content"), ("text", "Text"))
                cleaned, filtered = sanitize_turn_text(role, text)
                if cleaned:
                    idx = safe_id(item.get("id")) or f"line-{number}"
                    native[idx] = (idx, role, cleaned, obj.get("timestamp"), number, filtered)
            elif own and tag == "event_msg" and p.get("type") in ("user_message", "agent_message"):
                role = "user" if p["type"] == "user_message" else "assistant"
                text = p.get("message")
                if isinstance(text, str):
                    cleaned, filtered = sanitize_turn_text(role, text)
                    if cleaned:
                        idx = safe_id(p.get("id")) or f"line-{number}"
                        legacy.append((idx, role, cleaned, obj.get("timestamp"), number, filtered))
            elif own and tag == "response_item" and p.get("type") == "message":
                role = p.get("role")
                if role not in ("assistant", "user") or p.get("recipient") not in (None, "all"):
                    continue
                text = extract_text_blocks(
                    p.get("content"), ("output_text",) if role == "assistant" else ("input_text",)
                )
                cleaned, filtered = sanitize_turn_text(role, text)
                if cleaned:
                    idx = safe_id(p.get("id")) or f"line-{number}"
                    messages.append((idx, role, cleaned, obj.get("timestamp"), number, filtered))

    if not session:
        return []

    events: list[RawEventIn] = []
    for role in ("user", "assistant"):
        turns = next(
            (
                group
                for group in (
                    [v for v in native.values() if v[1] == role],
                    [v for v in legacy if v[1] == role],
                    [v for v in messages if v[1] == role],
                )
                if group
            ),
            [],
        )
        for idx, _, text, when, line_no, filtered in turns:
            events.append(
                make_chat_event(
                    provider="codex",
                    session_id=session,
                    message_id=idx,
                    role=role,
                    text=text,
                    timestamp_ms=parse_timestamp_ms(when),
                    project=project,
                    cwd=cwd,
                    origin=origin,
                    parent_session_id=parent_session_id,
                    is_subagent=is_subagent,
                    reflexive_filtered=filtered,
                    locator=f"codex://{path.name}#{idx}",
                    order=line_no,
                )
            )
    events.sort(
        key=lambda e: (e.t_start, int(e.context.get("source_order") or 0), e.provenance.source_id)
    )
    for turn_idx, ev in enumerate(events):
        ev.context["turn_index"] = turn_idx
    return events


# ----------------------------------------------------------------------
# 3. Claude Code Incremental JSONL Parser
# ----------------------------------------------------------------------
def parse_claude_code_records(
    records: list[tuple[int, dict[str, Any]]],
    *,
    path: Path,
    state: dict[str, Any] | None = None,
    project: str | None = None,
) -> tuple[list[RawEventIn], dict[str, Any]]:
    meta = dict(state or {})
    turn_index = int(meta.get("turn_index") or 0)
    in_subagents_dir = "subagents" in path.parts
    events: list[RawEventIn] = []
    for line_no, obj in records:
        role = obj.get("type")
        msg = obj.get("message")
        if role not in ("user", "assistant") or not isinstance(msg, dict) or msg.get("role") != role:
            continue
        if (
            obj.get("isMeta")
            or obj.get("isCompactSummary")
            or "toolUseResult" in obj
            or "sourceToolAssistantUUID" in obj
        ):
            continue
        text = extract_text_blocks(msg.get("content"), ("text",))
        cleaned, reflexive_filtered = sanitize_turn_text(role, text)
        if not cleaned:
            continue
        raw_session = safe_id(obj.get("sessionId") or obj.get("session_id")) or path.stem
        agent_id = safe_id(obj.get("agentId"))
        session = f"{raw_session}/{agent_id}" if agent_id else raw_session
        is_subagent = bool(agent_id or obj.get("isSidechain") or in_subagents_dir)
        parent_session_id = raw_session if agent_id else None
        mid = safe_id(obj.get("uuid")) or f"line-{line_no}"
        cwd = obj.get("cwd") if isinstance(obj.get("cwd"), str) else meta.get("cwd")
        if cwd:
            meta["cwd"] = cwd
        events.append(
            make_chat_event(
                provider="claude",
                session_id=session,
                message_id=mid,
                role=role,
                text=cleaned,
                timestamp_ms=parse_timestamp_ms(obj.get("timestamp")),
                project=project,
                cwd=cwd,
                origin="subagent" if is_subagent else "user",
                parent_message_id=safe_id(obj.get("parentUuid")),
                parent_session_id=parent_session_id,
                is_subagent=is_subagent,
                reflexive_filtered=reflexive_filtered,
                locator=f"claude://{session}#{mid}",
                order=line_no,
                turn_index=turn_index,
            )
        )
        turn_index += 1
    meta["turn_index"] = turn_index
    return events, meta


# ----------------------------------------------------------------------
# 4. WorkBuddy & QClaw Incremental JSONL Parser
# ----------------------------------------------------------------------
def parse_workbuddy_or_qclaw_records(
    provider: str,
    records: list[tuple[int, dict[str, Any]]],
    *,
    path: Path,
    state: dict[str, Any] | None = None,
    project: str | None = None,
) -> tuple[list[RawEventIn], dict[str, Any]]:
    is_wb = provider == "workbuddy"
    meta = dict(state or {})
    session_id: str | None = meta.get("session_id")
    cwd: str | None = meta.get("cwd")
    parent_session: str | None = meta.get("parent_session_id")
    turn_index = int(meta.get("turn_index") or 0)
    events: list[RawEventIn] = []

    for line_no, obj in records:
        tag = obj.get("type")
        mid = safe_id(obj.get("id"))
        sid = safe_id(obj.get("sessionId")) if is_wb else (mid if tag == "session" else None)
        if sid:
            session_id = sid
        if isinstance(obj.get("cwd"), str):
            cwd = obj["cwd"]
        if isinstance(obj.get("parentSessionId"), str):
            parent_session = obj["parentSessionId"]
        if tag != "message":
            continue
        visible = obj if is_wb else obj.get("message")
        if not isinstance(visible, dict):
            continue
        role = visible.get("role")
        if role not in ("user", "assistant"):
            continue
        content = visible.get("content")
        if is_wb:
            text = extract_text_blocks(
                content, ("input_text",) if role == "user" else ("output_text",)
            )
            if role == "user":
                text = unwrap_workbuddy_user(text)
        else:
            text = (
                content
                if isinstance(content, str)
                else extract_text_blocks(content, ("text",))
            )
            if role == "user":
                text = unwrap_qclaw_user(text)
        cleaned, reflexive_filtered = sanitize_turn_text(role, text)
        if not cleaned:
            continue
        ts = parse_timestamp_ms(
            obj.get("timestamp") if obj.get("timestamp") is not None else visible.get("timestamp")
        )
        resolved_sid = session_id or path.stem
        resolved_mid = mid or f"line-{line_no}"
        events.append(
            make_chat_event(
                provider=provider,
                session_id=resolved_sid,
                message_id=resolved_mid,
                role=role,
                text=cleaned,
                timestamp_ms=ts,
                project=project,
                cwd=cwd,
                origin="subagent" if parent_session else "user",
                parent_message_id=safe_id(obj.get("parentId")),
                parent_session_id=parent_session,
                is_subagent=bool(parent_session),
                reflexive_filtered=reflexive_filtered,
                locator=f"{provider}://{resolved_sid}#{resolved_mid}",
                order=line_no,
                turn_index=turn_index,
            )
        )
        turn_index += 1

    meta["session_id"] = session_id
    meta["cwd"] = cwd
    meta["parent_session_id"] = parent_session
    meta["turn_index"] = turn_index
    return events, meta


# ----------------------------------------------------------------------
# 5. DeepSeek Harness Incremental JSONL Parser
# ----------------------------------------------------------------------
def parse_deepseek_records(
    records: list[tuple[int, dict[str, Any]]],
    *,
    path: Path,
    state: dict[str, Any] | None = None,
    project: str | None = None,
) -> tuple[list[RawEventIn], dict[str, Any]]:
    meta = dict(state or {})
    session_id: str | None = meta.get("session_id")
    cwd: str | None = meta.get("cwd")
    parent_session: str | None = meta.get("parent_session_id")
    origin: str = meta.get("origin") or "user"
    turn_index = int(meta.get("turn_index") or 0)
    events: list[RawEventIn] = []

    for line_no, record in records:
        kind = record.get("type")
        if kind == "session":
            session_id = safe_id(record.get("id")) or session_id
            if isinstance(record.get("cwd"), str):
                cwd = record["cwd"]
            parent = record.get("parentSession")
            if isinstance(parent, dict):
                parent = parent.get("id") or parent.get("sessionId")
            parent_session = safe_id(parent) or parent_session
            origin = "subagent" if parent_session or record.get("delegationDepth", 0) else "user"
            continue
        if kind not in {"user/message", "assistant/message"}:
            continue
        data = record.get("data") or {}
        message = data if kind == "user/message" else data.get("message") or {}
        role = message.get("role")
        if role != kind.partition("/")[0]:
            continue
        src = message.get("source") or {}
        if role == "user" and (not isinstance(src, dict) or src.get("kind") != "user"):
            continue
        text = extract_text_blocks(message.get("content"), ("text",))
        cleaned, reflexive_filtered = sanitize_turn_text(role, text)
        if not cleaned:
            continue
        resolved_sid = session_id or path.stem
        mid = safe_id(message.get("id")) or f"line-{line_no}"
        events.append(
            make_chat_event(
                provider="deepseek-harness",
                session_id=resolved_sid,
                message_id=mid,
                role=role,
                text=cleaned,
                timestamp_ms=parse_timestamp_ms(record.get("time")),
                project=project,
                cwd=cwd,
                origin=origin,
                parent_session_id=parent_session,
                is_subagent=origin == "subagent",
                reflexive_filtered=reflexive_filtered,
                locator=f"deepseek://{resolved_sid}#{mid}",
                order=record.get("seq", line_no),
                turn_index=turn_index,
            )
        )
        turn_index += 1

    meta["session_id"] = session_id
    meta["cwd"] = cwd
    meta["parent_session_id"] = parent_session
    meta["origin"] = origin
    meta["turn_index"] = turn_index
    return events, meta


# ----------------------------------------------------------------------
# 6. Cursor & OpenCode Read-Only SQLite Readers (Incremental Cursors)
# ----------------------------------------------------------------------
def _cursor_workspace_map(workspaces_dir: Path | None) -> dict[str, set[str]]:
    links: dict[str, set[str]] = defaultdict(set)
    if not workspaces_dir or not workspaces_dir.is_dir():
        return links
    for marker in sorted(workspaces_dir.glob("*/workspace.json")):
        db = marker.with_name("state.vscdb")
        if marker.is_symlink() or not db.is_file() or db.is_symlink():
            continue
        try:
            meta = json.loads(marker.read_bytes())
            uri = meta.get("folder") or meta.get("workspace")
            if not uri:
                continue
            with open_readonly_sqlite(db) as conn:
                row = conn.execute(
                    "SELECT value FROM ItemTable WHERE key='composer.composerData'"
                ).fetchone()
                if row and row[0]:
                    for entry in json.loads(row[0]).get("allComposers", []):
                        if isinstance(entry, dict) and entry.get("composerId"):
                            links[entry["composerId"]].add(uri)
        except (OSError, ValueError):
            continue
    return links


def parse_cursor_db(
    global_vscdb: Path,
    *,
    workspaces_dir: Path | None = None,
    seen_header_counts: dict[str, int] | None = None,
    project: str | None = None,
) -> tuple[list[RawEventIn], dict[str, int]]:
    """Read new visible bubbles from Cursor `globalStorage/state.vscdb` safely read-only."""
    prior_counts = dict(seen_header_counts or {})
    next_counts = dict(prior_counts)
    links = _cursor_workspace_map(workspaces_dir)
    events: list[RawEventIn] = []

    with open_readonly_sqlite(global_vscdb) as db:
        composers = db.execute(
            """SELECT key, json_extract(value,'$.composerId') sid,
                      json_extract(value,'$.fullConversationHeadersOnly') headers,
                      json_extract(value,'$.workspacePath') workspace,
                      json_extract(value,'$.parentComposerId') parent
               FROM cursorDiskKV WHERE key GLOB 'composerData:*' ORDER BY key"""
        ).fetchall()

        for row in composers:
            sid = safe_id(row["sid"])
            if not sid or row["key"] != f"composerData:{sid}":
                continue
            headers = json.loads(row["headers"] or "[]")
            if not isinstance(headers, list):
                continue
            prev_len = prior_counts.get(sid, 0)
            if len(headers) <= prev_len:
                continue

            workspace = row["workspace"]
            if not workspace and len(links[sid]) == 1:
                workspace = next(iter(links[sid]))

            start_idx = prev_len if prev_len < len(headers) else 0
            for idx, header in enumerate(headers[start_idx:], start=start_idx):
                if not isinstance(header, dict):
                    continue
                mid = safe_id(header.get("bubbleId"))
                if not mid:
                    continue
                bubble = db.execute(
                    """SELECT json_extract(value,'$.bubbleId') id,
                              json_extract(value,'$.type') role,
                              json_extract(value,'$.text') text,
                              json_extract(value,'$.createdAt') ts,
                              json_extract(value,'$.parentBubbleId') parent,
                              json_extract(value,'$.skipRendering') hidden,
                              json_extract(value,'$.isNudge') nudge,
                              json_extract(value,'$.isSynthetic') synthetic
                       FROM cursorDiskKV WHERE key=?""",
                    (f"bubbleId:{sid}:{mid}",),
                ).fetchone()
                if bubble is None:
                    continue
                role = {1: "user", 2: "assistant"}.get(bubble["role"])
                text = bubble["text"]
                if (
                    role
                    and isinstance(text, str)
                    and not any(bubble[k] for k in ("hidden", "nudge", "synthetic"))
                ):
                    cleaned, reflexive_filtered = sanitize_turn_text(role, text)
                    if cleaned:
                        events.append(
                            make_chat_event(
                                provider="cursor",
                                session_id=sid,
                                message_id=mid,
                                role=role,
                                text=cleaned,
                                timestamp_ms=parse_timestamp_ms(bubble["ts"]),
                                project=project,
                                cwd=workspace if isinstance(workspace, str) else None,
                                origin="subagent" if row["parent"] else "user",
                                parent_message_id=safe_id(bubble["parent"]),
                                parent_session_id=safe_id(row["parent"]),
                                is_subagent=bool(row["parent"]),
                                reflexive_filtered=reflexive_filtered,
                                locator=f"cursor://{sid}#{mid}",
                                order=idx,
                                turn_index=idx,
                            )
                        )
            next_counts[sid] = len(headers)
    return events, next_counts


def parse_opencode_db(
    db_path: Path,
    *,
    after_time_created: int = 0,
    project: str | None = None,
) -> tuple[list[RawEventIn], int]:
    """Read new visible turns from OpenCode SQLite DB using `time_created` watermark."""
    events: list[RawEventIn] = []
    max_created = after_time_created
    per_session_turn: dict[str, int] = defaultdict(int)
    with open_readonly_sqlite(db_path) as db:
        sessions = {
            row["id"]: (row["directory"] or row["project_id"], row["parent_id"])
            for row in db.execute(
                "SELECT id, project_id, directory, parent_id FROM session"
            ).fetchall()
        }
        msg_rows = db.execute(
            """SELECT id, session_id, time_created,
                      json_extract(data,'$.role') role,
                      json_extract(data,'$.parentID') parent_id,
                      json_extract(data,'$.time.created') ts,
                      json_type(data,'$.summary') generated_summary
               FROM message
               WHERE time_created > ?
               ORDER BY time_created ASC, id ASC""",
            (after_time_created,),
        ).fetchall()

        for row_idx, row in enumerate(msg_rows):
            created = int(row["time_created"] or 0)
            if created > max_created:
                max_created = created
            role = row["role"]
            if role not in ("user", "assistant") or row["generated_summary"] == "true":
                continue
            sid = safe_id(row["session_id"])
            mid = safe_id(row["id"])
            if not sid or not mid:
                continue
            parts = db.execute(
                """SELECT json_extract(data,'$.text') FROM part
                   WHERE session_id=? AND message_id=?
                     AND json_extract(data,'$.type')='text'
                     AND NOT coalesce(json_extract(data,'$.synthetic'), 0)
                     AND NOT coalesce(json_extract(data,'$.ignored'), 0)
                   ORDER BY time_created, id""",
                (sid, mid),
            ).fetchall()
            text = "\n".join(v for (v,) in parts if isinstance(v, str)).strip()
            cleaned, reflexive_filtered = sanitize_turn_text(role, text)
            if not cleaned:
                continue
            directory, parent_session = sessions.get(sid, (None, None))
            ts = row["ts"] if row["ts"] is not None else created
            turn_idx = per_session_turn[sid]
            per_session_turn[sid] = turn_idx + 1
            events.append(
                make_chat_event(
                    provider="opencode",
                    session_id=sid,
                    message_id=mid,
                    role=role,
                    text=cleaned,
                    timestamp_ms=parse_timestamp_ms(ts),
                    project=project,
                    cwd=directory if isinstance(directory, str) else None,
                    origin="subagent" if parent_session else "user",
                    parent_message_id=safe_id(row["parent_id"]),
                    parent_session_id=safe_id(parent_session),
                    is_subagent=bool(parent_session),
                    reflexive_filtered=reflexive_filtered,
                    locator=f"opencode://{sid}#{mid}",
                    order=row_idx,
                    turn_index=turn_idx,
                )
            )
    return events, max_created


# ----------------------------------------------------------------------
# 7. Export Archive Parsers (ChatGPT, Claude Web, Gemini, Generic)
# ----------------------------------------------------------------------
def parse_chatgpt_export(data: Any, *, project: str | None = None) -> list[RawEventIn]:
    events: list[RawEventIn] = []
    chats = data if isinstance(data, list) else [data]
    for chat in chats:
        if not isinstance(chat, dict):
            continue
        session = safe_id(chat.get("conversation_id") or chat.get("id"))
        mapping = chat.get("mapping")
        if not session or not isinstance(mapping, dict):
            continue
        visible: dict[str, tuple[str, str, Any, bool]] = {}
        for node_id, node in mapping.items():
            if not isinstance(node, dict):
                continue
            m = node.get("message") or {}
            role = (m.get("author") or {}).get("role")
            content = m.get("content") or {}
            if role not in ("user", "assistant") or m.get("recipient") not in (None, "all"):
                continue
            if (m.get("metadata") or {}).get("is_visually_hidden_from_conversation"):
                continue
            if content.get("content_type") not in ("text", "multimodal_text"):
                continue
            text = extract_text_blocks(content.get("parts"), ("text",))
            cleaned, filtered = sanitize_turn_text(role, text)
            if cleaned:
                visible[node_id] = (role, cleaned, m.get("create_time"), filtered)
        for order, (node_id, (role, text, when, filtered)) in enumerate(visible.items()):
            parent = mapping[node_id].get("parent")
            seen = {node_id}
            while parent and parent not in visible and parent in mapping:
                if parent in seen:
                    parent = None
                    break
                seen.add(parent)
                parent = mapping[parent].get("parent")
            events.append(
                make_chat_event(
                    provider="chatgpt",
                    session_id=session,
                    message_id=node_id,
                    role=role,
                    text=text,
                    timestamp_ms=parse_timestamp_ms(when),
                    project=project,
                    origin="user",
                    parent_message_id=parent if parent in visible else None,
                    reflexive_filtered=filtered,
                    locator=f"chatgpt://{session}#mapping:{node_id}",
                    order=order,
                    turn_index=order,
                )
            )
    return events


def parse_claude_web_export(data: Any, *, project: str | None = None) -> list[RawEventIn]:
    events: list[RawEventIn] = []
    chats = data if isinstance(data, list) else [data]
    for chat in chats:
        if not isinstance(chat, dict):
            continue
        session = safe_id(chat.get("uuid"))
        if not session:
            continue
        visible: dict[str, tuple[str, str, Any, int, bool]] = {}
        parents: dict[str, str | None] = {}
        for order, msg in enumerate(chat.get("chat_messages") or []):
            mid = safe_id(msg.get("uuid"))
            if not mid:
                continue
            parent = msg.get("parent_message_uuid")
            parents[mid] = None if parent == "00000000-0000-0000-0000-000000000000" else safe_id(parent)
            role = {"human": "user", "assistant": "assistant"}.get(msg.get("sender"))
            if not role:
                continue
            content = msg.get("content")
            text = (
                extract_text_blocks(content, ("text",))
                if content
                else extract_text_blocks(msg.get("text"), ())
            )
            cleaned, filtered = sanitize_turn_text(role, text)
            if cleaned:
                visible[mid] = (role, cleaned, msg.get("created_at"), order, filtered)
        for turn_idx, (mid, (role, text, when, order, filtered)) in enumerate(visible.items()):
            parent, seen = parents.get(mid), {mid}
            while parent in parents and parent not in visible:
                if parent in seen:
                    parent = None
                    break
                seen.add(parent)
                parent = parents.get(parent)
            events.append(
                make_chat_event(
                    provider="claude-web",
                    session_id=session,
                    message_id=mid,
                    role=role,
                    text=text,
                    timestamp_ms=parse_timestamp_ms(when),
                    project=project,
                    origin="user",
                    parent_message_id=parent if parent in visible else None,
                    reflexive_filtered=filtered,
                    locator=f"claude-web://{session}#{mid}",
                    order=order,
                    turn_index=turn_idx,
                )
            )
    return events


def parse_gemini_export(data: Any, *, project: str | None = None) -> list[RawEventIn]:
    events: list[RawEventIn] = []
    sessions = data if isinstance(data, list) else [data]
    for sess in sessions:
        if not isinstance(sess, dict):
            continue
        sid = safe_id(sess.get("sessionId") or sess.get("id"))
        if not sid:
            continue
        turn_idx = 0
        for idx, m in enumerate(sess.get("messages") or []):
            role = {"user": "user", "gemini": "assistant", "model": "assistant"}.get(m.get("type") or m.get("role"))
            text = extract_text_blocks(m.get("content"), ("", "text"))
            if not role:
                continue
            cleaned, filtered = sanitize_turn_text(role, text)
            if cleaned:
                mid = safe_id(m.get("id")) or f"msg-{idx}"
                events.append(
                    make_chat_event(
                        provider="gemini",
                        session_id=sid,
                        message_id=mid,
                        role=role,
                        text=cleaned,
                        timestamp_ms=parse_timestamp_ms(m.get("timestamp")),
                        project=project,
                        origin="user",
                        reflexive_filtered=filtered,
                        locator=f"gemini://{sid}#{mid}",
                        order=idx,
                        turn_index=turn_idx,
                    )
                )
                turn_idx += 1
    return events


def parse_generic_transcript(data: dict[str, Any], *, project: str | None = None) -> list[RawEventIn]:
    provider = data.get("provider", "transcript")
    if not isinstance(provider, str) or not re.fullmatch(r"[a-z][a-z0-9_-]{0,48}", provider):
        raise ValueError("Expected short provider key.")
    sid = safe_id(data.get("session_id"))
    if not sid:
        raise ValueError("Missing session_id.")
    origin = str(data.get("origin") or "user")
    parent_session_id = safe_id(data.get("parent_session_id"))
    is_subagent = bool(data.get("is_subagent")) or origin == "subagent" or bool(parent_session_id)
    events: list[RawEventIn] = []
    turn_idx = 0
    for idx, m in enumerate(data.get("messages") or []):
        role = m.get("role")
        text = m.get("text")
        if role not in ("user", "assistant") or not isinstance(text, str):
            continue
        cleaned, filtered = sanitize_turn_text(role, text)
        if not cleaned:
            continue
        mid = safe_id(m.get("id")) or f"msg-{idx}"
        when = None if m.get("timestamp_status") == "missing" else m.get("timestamp")
        events.append(
            make_chat_event(
                provider=provider,
                session_id=sid,
                message_id=mid,
                role=role,
                text=cleaned,
                timestamp_ms=parse_timestamp_ms(when),
                project=project or data.get("project"),
                cwd=data.get("cwd") if isinstance(data.get("cwd"), str) else None,
                origin=origin,
                parent_message_id=safe_id(m.get("parent_id")),
                parent_session_id=parent_session_id,
                is_subagent=is_subagent,
                reflexive_filtered=filtered,
                locator=f"{provider}://{sid}#{mid}",
                order=idx,
                turn_index=turn_idx,
            )
        )
        turn_idx += 1
    return events


def parse_export_file(path: Path, source: str, *, project: str | None = None) -> list[RawEventIn]:
    """One-off parser dispatcher for CLI import (`context-collectors import-chat`)."""
    if source == "codex":
        return parse_codex_file(path, project=project)
    if source == "claude":
        records: list[tuple[int, dict[str, Any]]] = []
        with open_maybe_zstd(path) as fh:
            for i, line in enumerate(fh, 1):
                if line.strip():
                    records.append((i, json.loads(line)))
        events, _ = parse_claude_code_records(records, path=path, project=project)
        return events
    if source == "deepseek":
        records = []
        with open_maybe_zstd(path) as fh:
            for i, line in enumerate(fh, 1):
                if line.strip():
                    records.append((i, json.loads(line)))
        events, _ = parse_deepseek_records(records, path=path, project=project)
        return events
    if source == "antigravity":
        records = []
        with open_maybe_zstd(path) as fh:
            for i, line in enumerate(fh, 1):
                if line.strip():
                    records.append((i, json.loads(line)))
        conv_id = path.parent.parent.parent.name if path.name == "transcript.jsonl" else path.stem
        events, _ = parse_antigravity_records(
            records, conversation_id=conv_id, path=path, project=project
        )
        return events
    with open_maybe_zstd(path) as fh:
        data = json.load(fh)
    if source == "chatgpt":
        return parse_chatgpt_export(data, project=project)
    if source == "claude-web":
        return parse_claude_web_export(data, project=project)
    if source == "gemini":
        return parse_gemini_export(data, project=project)
    if source == "transcript":
        return parse_generic_transcript(data, project=project)
    raise ValueError(f"Unsupported chat source: {source}")
