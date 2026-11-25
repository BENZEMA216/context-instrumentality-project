"""Channel/rule-based privacy policy engine and secret firewall."""

from __future__ import annotations

import re
from typing import Any
from urllib.parse import urlsplit

from .models import PrivacyTier

# High-confidence secret detectors: never allow raw secrets to become shareable
SECRET_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("openai_key", re.compile(r"\bsk-(?:proj-|live-|test-)?[A-Za-z0-9_-]{20,}\b")),
    ("anthropic_key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b")),
    ("github_token", re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b")),
    ("github_pat", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{30,}\b")),
    ("aws_key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("private_key", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("bearer_jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\b")),
]

SENSITIVE_DOMAINS: tuple[str, ...] = (
    "mail.google.com",
    "outlook.live.com",
    "icbc.com.cn",
    "cmbchina.com",
    "alipay.com",
    "paypal.com",
    "1password.com",
    "bitwarden.com",
)

# Default channel policies tuned for real daily utility while respecting sensitivity
DEFAULT_CHANNEL_POLICIES: list[dict[str, Any]] = [
    {
        "id": "default-clipboard",
        "scope": "source",
        "match_value": "clipboard",
        "default_tier": "shareable",
        "priority": 100,
        "description": "剪贴板（已过滤密码管理器与高熵密钥）默认对本机 Agent 可见",
    },
    {
        "id": "default-browser",
        "scope": "source",
        "match_value": "browser",
        "default_tier": "shareable",
        "priority": 100,
        "description": "浏览器有效阅读摘录（已排除敏感域名与 URL 凭证）默认对本机 Agent 可见",
    },
    {
        "id": "default-ai-chat",
        "scope": "source",
        "match_value": "ai_chat",
        "default_tier": "shareable",
        "priority": 100,
        "description": "AI 对话历史默认对本机 Agent 可见，便于跨工具延续决策",
    },
    {
        "id": "default-voice",
        "scope": "source",
        "match_value": "voice",
        "default_tier": "shareable",
        "priority": 100,
        "description": "录音转写与片段默认对本机 Agent 可见",
    },
    {
        "id": "default-window",
        "scope": "source",
        "match_value": "window",
        "default_tier": "shareable",
        "priority": 100,
        "description": "窗口焦点时间骨架默认对本机 Agent 可见",
    },
    {
        "id": "default-location",
        "scope": "source",
        "match_value": "location",
        "default_tier": "local_only",
        "priority": 100,
        "description": "物理位置轨迹默认仅本机可见，按需开启共享",
    },
    {
        "id": "default-wechat",
        "scope": "source",
        "match_value": "wechat",
        "default_tier": "local_only",
        "priority": 100,
        "description": "微信聊天默认仅本机可见；工作群/项目对话可按项目或联系人规则放行",
    },
    {
        "id": "default-vault",
        "scope": "source",
        "match_value": "vault",
        "default_tier": "redacted",
        "priority": 100,
        "description": "Vault 进入 Hub 的均为不含明文的脱敏操作回执与结构化指针",
    },
    {
        "id": "default-im",
        "scope": "source",
        "match_value": "im",
        "default_tier": "local_only",
        "priority": 100,
        "description": "所有 IM 聊天渠道（飞书/Telegram/Slack 等）默认仅本机可见，按白名单群组放行",
    },
    {
        "id": "default-email",
        "scope": "source",
        "match_value": "email",
        "default_tier": "local_only",
        "priority": 100,
        "description": "邮件通道默认仅本机可见，按发件人/主题白名单放行",
    },
    {
        "id": "default-notes",
        "scope": "source",
        "match_value": "notes",
        "default_tier": "shareable",
        "priority": 100,
        "description": "本地知识库（如 Obsidian Markdown）默认对本机 Agent 可见",
    },
    {
        "id": "default-calendar",
        "scope": "source",
        "match_value": "calendar",
        "default_tier": "shareable",
        "priority": 100,
        "description": "日程与会议元数据默认对本机 Agent 可见",
    },
]


def detect_secrets(text: str) -> list[str]:
    if not text:
        return []
    found: list[str] = []
    for tag, pattern in SECRET_PATTERNS:
        if pattern.search(text):
            found.append(tag)
    return found


def extract_domain(event: dict[str, Any]) -> str | None:
    url = event.get("content", {}).get("url_norm") or event.get("content", {}).get("url")
    if not isinstance(url, str) or not url:
        return None
    try:
        host = urlsplit(url).hostname
        return host.lower() if host else None
    except ValueError:
        return None


def resolve_privacy_tier(
    event: dict[str, Any],
    rules: list[dict[str, Any]],
) -> tuple[PrivacyTier, list[str]]:
    """Determine effective privacy tier and detected pii_tags for an incoming event."""
    privacy = event.get("privacy") or {}
    existing_tags = list(dict.fromkeys(privacy.get("pii_tags") or []))
    text_parts = [
        str(event.get("content", {}).get("text") or ""),
        str(event.get("content", {}).get("summary") or ""),
        str(event.get("content", {}).get("title") or ""),
    ]
    for ex in event.get("content", {}).get("excerpts") or []:
        if isinstance(ex, dict) and ex.get("text"):
            text_parts.append(str(ex["text"]))
    combined_text = "\n".join(text_parts)

    secret_tags = detect_secrets(combined_text)
    all_tags = list(dict.fromkeys(existing_tags + secret_tags))

    # Hard firewall: detected raw credentials are ALWAYS locked to local_only
    if secret_tags or any(
        tag.casefold() in {"secret", "password", "credential", "api_key", "access_token"}
        for tag in all_tags
    ):
        return "local_only", all_tags

    # Sensitive domains default to local_only unless explicitly overridden as redacted
    domain = extract_domain(event)
    if (
        domain
        and any(domain == d or domain.endswith("." + d) for d in SENSITIVE_DOMAINS)
        and privacy.get("tier") != "redacted"
    ):
        return "local_only", list(dict.fromkeys(all_tags + ["sensitive_domain"]))

    # Explicit tier provided on the event takes precedence (except secret firewall above)
    explicit = privacy.get("tier")
    if explicit in ("local_only", "redacted", "shareable"):
        return explicit, all_tags

    # Otherwise evaluate user-configured rules ordered by priority (lower number = higher priority)
    source = str(event.get("source") or "")
    source_root = source.split(".")[0]
    connector = str((event.get("provenance") or {}).get("connector") or "")
    project = str(event.get("project") or (event.get("context") or {}).get("project") or "")

    sorted_rules = sorted(rules, key=lambda r: (r.get("priority", 100), r.get("id", "")))
    for rule in sorted_rules:
        scope = rule.get("scope")
        val = str(rule.get("match_value") or "").lower()
        tier = rule.get("default_tier")
        if tier not in ("local_only", "redacted", "shareable"):
            continue
        if scope == "domain" and domain and (domain == val or domain.endswith("." + val)):
            return tier, all_tags
        if scope == "project" and project and project.lower() == val:
            return tier, all_tags
        if scope == "connector" and connector and connector.lower() == val:
            return tier, all_tags
        if scope == "source" and (source.lower() == val or source_root.lower() == val):
            return tier, all_tags

    return "local_only", all_tags
