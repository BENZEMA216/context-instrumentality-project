"""Extensible Channel Registry for Raw Memory & the `X for Agent` product family.

Explicitly reserves canonical source namespaces, default privacy tiers, and collector slots
so new personal context channels can be plugged in without schema migrations or privacy drift.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any


@dataclass(frozen=True, slots=True)
class ChannelSpec:
    channel_id: str
    product_name: str
    source: str
    category: str  # "active" | "ready" | "reserved"
    default_privacy: str  # "shareable" | "redacted" | "local_only"
    collector_name: str | None
    description: str


CHANNEL_REGISTRY: tuple[ChannelSpec, ...] = (
    ChannelSpec(
        channel_id="ai_chat",
        product_name="AI Session Collector",
        source="ai_chat",
        category="active",
        default_privacy="shareable",
        collector_name="ai_chat",
        description="11-provider local AI coding/chat transcripts (Antigravity, Codex, Claude, Cursor, OpenCode, etc.) with No-Echo stripping",
    ),
    ChannelSpec(
        channel_id="clipboard",
        product_name="Clip for Agent",
        source="clipboard",
        category="active",
        default_privacy="shareable",
        collector_name="clipcontext",
        description="macOS clipboard collector with lossless PNG compaction, Chromium source-URL anchors, and revocation sync",
    ),
    ChannelSpec(
        channel_id="voice",
        product_name="Record for Agent",
        source="voice",
        category="active",
        default_privacy="shareable",
        collector_name="audio",
        description="Apple Watch / iPhone audio library with local SenseVoice-Small + Silero-VAD offline transcription",
    ),
    ChannelSpec(
        channel_id="browser",
        product_name="Read for Agent",
        source="browser",
        category="active",
        default_privacy="shareable",
        collector_name="browser",
        description="Lock-free local Chrome/Arc/Brave/Edge/Safari history sync + MV3 Defuddle Markdown & dwell reader extension",
    ),
    ChannelSpec(
        channel_id="wechat",
        product_name="Chat for Agent · WeChat",
        source="wechat",
        category="ready",
        default_privacy="local_only",
        collector_name="chat",
        description="Compliant WeFlow / WeChat export archive collector with privacy-by-default local_only & per-group allowlist",
    ),
    ChannelSpec(
        channel_id="im_lark",
        product_name="Chat for Agent · Lark / Feishu",
        source="im.lark",
        category="ready",
        default_privacy="local_only",
        collector_name="lark_im",
        description="Official lark-cli compliant Feishu/Lark chat collector with per-chat allowlist & project mapping",
    ),
    ChannelSpec(
        channel_id="im_telegram",
        product_name="Chat for Agent · Telegram",
        source="im.telegram",
        category="ready",
        default_privacy="local_only",
        collector_name="chat",
        description="Telegram Desktop JSON archive importer with strict local_only default and allowlist promotion",
    ),
    ChannelSpec(
        channel_id="vault",
        product_name="Vault for Agent",
        source="vault",
        category="active",
        default_privacy="redacted",
        collector_name=None,
        description="Isolated AES-256-GCM encrypted store for Self/Partner/Company profiles, ID docs, Business Licenses, autofill fields & API keys (syncs masked pointers only)",
    ),
    ChannelSpec(
        channel_id="window",
        product_name="Focus for Agent",
        source="window",
        category="ready",
        default_privacy="shareable",
        collector_name="window",
        description="Native macOS frontmost-window focus & ActivityWatch bridge with dwell coalescing & password/incognito blocking",
    ),
    ChannelSpec(
        channel_id="notes_obsidian",
        product_name="Notes for Agent (Reserved)",
        source="notes.obsidian",
        category="reserved",
        default_privacy="shareable",
        collector_name=None,
        description="Reserved channel for local Obsidian / Markdown knowledge vault incremental sync",
    ),
    ChannelSpec(
        channel_id="calendar",
        product_name="Calendar for Agent (Reserved)",
        source="calendar.local",
        category="reserved",
        default_privacy="shareable",
        collector_name=None,
        description="Reserved channel for macOS EventKit / Google / Lark calendar schedules and meeting metadata",
    ),
    ChannelSpec(
        channel_id="email",
        product_name="Mail for Agent (Reserved)",
        source="email.local",
        category="reserved",
        default_privacy="local_only",
        collector_name=None,
        description="Reserved channel for local Mail / IMAP / Lark Mail threads (strict local_only default)",
    ),
    ChannelSpec(
        channel_id="location",
        product_name="Location for Agent (Reserved)",
        source="location",
        category="reserved",
        default_privacy="local_only",
        collector_name=None,
        description="Reserved channel for Overland / local dwell-place clustering (strict local_only default)",
    ),
)


def list_channel_specs() -> list[dict[str, Any]]:
    return [asdict(spec) for spec in CHANNEL_REGISTRY]
