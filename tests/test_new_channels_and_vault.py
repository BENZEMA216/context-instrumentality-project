"""Comprehensive tests for Read/Focus/Chat/Vault for Agent channels and Antigravity sanitization."""

from __future__ import annotations

import base64
import json
import sqlite3
import sys
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from context_collectors.ai_chat.parsers import sanitize_turn_text
from context_collectors.browser import (
    _CHROMIUM_EPOCH_OFFSET_MS,
    _SAFARI_EPOCH_OFFSET_SEC,
    BrowserHistoryCollector,
    BrowserProfileSource,
)
from context_collectors.chat import ChatInboxCollector, parse_chat_export_file
from context_collectors.lark_im import parse_lark_messages
from context_collectors.registry import list_channel_specs
from context_collectors.runtime import DirectHubSink, HubCheckpointStore, run_collector
from context_collectors.window import (
    WindowFocusCollector,
    WindowSample,
    coalesce_window_samples,
    infer_project_from_window,
    is_blocked_window,
)
from context_eval.workbench import create_workbench_app
from context_hub.store import HubStore
from context_vault import VaultAuthError, VaultStore, extract_cn_id_metadata


def _make_chromium_history_db(path: Path) -> None:
    conn = sqlite3.connect(str(path))
    conn.executescript(
        """
        CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER);
        CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER, visit_duration INTEGER);
        """
    )
    now_ms = int(time.time() * 1000)
    t1_us = (now_ms - 120_000 + _CHROMIUM_EPOCH_OFFSET_MS) * 1000
    t2_us = (now_ms - 90_000 + _CHROMIUM_EPOCH_OFFSET_MS) * 1000
    t3_us = (now_ms - 60_000 + _CHROMIUM_EPOCH_OFFSET_MS) * 1000
    t4_us = (now_ms - 30_000 + _CHROMIUM_EPOCH_OFFSET_MS) * 1000

    conn.executemany(
        "INSERT INTO urls(id, url, title, visit_count) VALUES (?, ?, ?, ?)",
        [
            (1, "https://github.com/rawmemory/context-instrumentality-project?utm_source=test", "Raw Memory Repo", 3),
            (2, "https://accounts.google.com/signin/oauth", "Sign in", 1),
            (3, "https://mail.google.com/mail/u/0/#inbox", "Gmail Inbox", 4),
            (4, "https://docs.python.org/3/library/sqlite3.html", "sqlite3 — DB-API", 1),
        ],
    )
    conn.executemany(
        "INSERT INTO visits(id, url, visit_time, visit_duration) VALUES (?, ?, ?, ?)",
        [
            (101, 1, t1_us, 45_000_000),  # 45s dwell -> shareable & auto_curated
            (102, 2, t2_us, 20_000_000),  # auth noise -> dropped
            (103, 3, t3_us, 30_000_000),  # sensitive mail domain -> local_only
            (104, 4, t4_us, 1_500_000),   # 1.5s bounce (< 5s min_dwell) -> dropped
        ],
    )
    conn.commit()
    conn.close()


def _make_safari_history_db(path: Path) -> None:
    conn = sqlite3.connect(str(path))
    conn.executescript(
        """
        CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);
        CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, title TEXT, visit_time REAL);
        """
    )
    mac_sec = time.time() - _SAFARI_EPOCH_OFFSET_SEC - 60.0
    conn.execute(
        "INSERT INTO history_items(id, url, visit_count) VALUES (1, 'https://rawmemory.app/docs', 2)"
    )
    conn.execute(
        "INSERT INTO history_visits(id, history_item, title, visit_time) VALUES (1, 1, 'Raw Memory Docs', ?)",
        (mac_sec,),
    )
    conn.commit()
    conn.close()


def test_browser_history_collector_chromium_safari_privacy_and_dedup(tmp_path: Path) -> None:
    chrome_db = tmp_path / "History"
    safari_db = tmp_path / "History.db"
    _make_chromium_history_db(chrome_db)
    _make_safari_history_db(safari_db)

    store = HubStore(tmp_path / "hub")
    sink = DirectHubSink(store)
    cps = HubCheckpointStore(store)

    col = BrowserHistoryCollector(
        sources=[
            BrowserProfileSource("chrome", "chromium", "Default", chrome_db),
            BrowserProfileSource("safari", "safari", "Default", safari_db),
        ],
        since_days=7.0,
        min_dwell_ms=5_000,
    )
    doc = col.doctor()
    assert doc["available"] is True
    assert doc["readable_profiles"] == 2

    rep1 = run_collector(col, sink, cps)
    assert rep1.status == "ok"
    assert rep1.created == 3  # GitHub repo (shareable), Gmail (local_only), Safari docs (shareable)

    # Agent sees only the 2 shareable URLs, NEVER Gmail
    agent_raw = store.list_raw(sources=["browser"], agent=True, limit=20)
    assert len(agent_raw) == 2
    urls = {r["content"]["url_norm"] for r in agent_raw}
    assert "https://github.com/rawmemory/context-instrumentality-project" in urls
    assert "https://rawmemory.app/docs" in urls

    # Owner sees Gmail marked local_only
    owner_raw = store.list_raw(sources=["browser"], agent=False, limit=20)
    assert len(owner_raw) == 3
    gmail = next(r for r in owner_raw if "mail.google.com" in r["content"]["url"])
    assert gmail["privacy"]["tier"] == "local_only"

    # Incremental second sync skips unchanged DB files
    rep2 = run_collector(col, sink, cps)
    assert rep2.created == 0
    assert rep2.sources_unchanged == 2


def test_window_focus_coalescing_privacy_and_project_inference(tmp_path: Path) -> None:
    assert is_blocked_window("1Password", "com.1password.1password", "Vault") is True
    assert is_blocked_window("Google Chrome", "com.google.Chrome", "New Tab - Incognito") is True
    assert is_blocked_window("Cursor", "com.todesktop.cursor", "store.py — raw-memory — Cursor") is False
    assert infer_project_from_window("Cursor", "store.py — raw-memory — Cursor") == "raw-memory"

    base = 1_764_200_000_000
    samples = [
        WindowSample("Cursor", "com.todesktop.cursor", "store.py — raw-memory — Cursor", base, base + 8_000),
        WindowSample("Cursor", "com.todesktop.cursor", "store.py — raw-memory — Cursor", base + 10_000, base + 25_000),
        WindowSample("1Password", "com.1password.1password", "Unlock", base + 26_000, base + 50_000),
        WindowSample("Finder", "com.apple.finder", "Downloads", base + 55_000, base + 58_000),  # < 10s flicker
        WindowSample("WeChat", "com.tencent.xinWeChat", "Team Group", base + 60_000, base + 85_000),
    ]
    merged = coalesce_window_samples(samples, min_dwell_ms=10_000)
    assert len(merged) == 2
    assert merged[0].app_name == "Cursor" and merged[0].dwell_ms == 25_000
    assert merged[1].app_name == "WeChat" and merged[1].dwell_ms == 25_000

    # Feed via sample_log_path into WindowFocusCollector
    log_path = tmp_path / "window_samples.jsonl"
    log_path.write_text(
        "\n".join(
            json.dumps(
                {
                    "app_name": s.app_name,
                    "app_bundle": s.app_bundle,
                    "window_title": s.window_title,
                    "t_start": s.t_start,
                    "t_end": s.t_end,
                }
            )
            for s in samples
        )
        + "\n",
        encoding="utf-8",
    )
    store = HubStore(tmp_path / "hub")
    col = WindowFocusCollector(
        activitywatch_url="http://127.0.0.1:1",  # unreachable
        min_dwell_ms=10_000,
        sample_log_path=log_path,
    )
    rep = run_collector(col, DirectHubSink(store), HubCheckpointStore(store))
    assert rep.created == 2
    # WeChat window is local_only; Cursor window is shareable
    agent_wins = store.list_raw(sources=["window"], agent=True)
    assert len(agent_wins) == 1
    assert agent_wins[0]["context"]["app_name"] == "Cursor"
    assert agent_wins[0]["project"] == "raw-memory"


def test_chat_for_agent_weflow_privacy_default_and_allowlist(tmp_path: Path) -> None:
    inbox = tmp_path / "inbox" / "chat"
    inbox.mkdir(parents=True)

    # 1. Personal DM (NOT allowlisted -> MUST remain local_only)
    dm_file = inbox / "personal_dm.json"
    dm_file.write_text(
        json.dumps(
            {
                "session": {"accountId": "wxid_personal_friend", "name": "私聊好友", "isGroup": False},
                "messages": [
                    {"id": "m1", "createTime": 1764200000, "senderName": "好友", "isSelf": False, "content": "周末去哪吃饭？"},
                    {"id": "m2", "createTime": 1764200060, "senderName": "我", "isSelf": True, "content": "老地方见"},
                ],
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    # 2. Opted-in Project Group (allowlisted -> shareable & mapped to project `record-for-agent`)
    grp_file = inbox / "project_group.json"
    grp_file.write_text(
        json.dumps(
            {
                "session": {"accountId": "123456@chatroom", "name": "录音产品讨论群", "isGroup": True},
                "messages": [
                    {"id": "g1", "createTime": 1764201000, "senderName": "政哥", "isSelf": False, "content": "建议周五做手表端验收"},
                    {"id": "g2", "createTime": 1764201120, "senderName": "我", "isSelf": True, "content": "确认改到周一验收，并精简波形状态", "replyTo": "g1"},
                    {"id": "g3", "createTime": 1764201150, "senderName": "政哥", "isSelf": False, "content": "[动画表情]"},
                ],
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    (inbox / "chat_allowlist.json").write_text(
        json.dumps(
            {
                "allow_sessions": ["123456@chatroom"],
                "default_allowed_tier": "shareable",
                "project_map": {"123456@chatroom": "record-for-agent"},
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    # Direct parser check
    parsed = parse_chat_export_file(grp_file)
    assert len(parsed) == 2  # sticker noise filtered out
    assert all(ev.privacy.tier == "local_only" for ev in parsed)  # without allowlist -> strictly local_only

    # Collector run with allowlist
    store = HubStore(tmp_path / "hub")
    col = ChatInboxCollector(inbox_dir=inbox)
    rep = run_collector(col, DirectHubSink(store), HubCheckpointStore(store))
    assert rep.status == "ok"
    assert rep.created == 4

    # Agent sees ONLY the 2 allowlisted project group messages, NEVER the personal DM
    agent_msgs = store.list_raw(sources=["wechat"], agent=True)
    assert len(agent_msgs) == 2
    assert all(m["project"] == "record-for-agent" for m in agent_msgs)
    assert any(m["actor"] == "self" and "周一验收" in m["body_text"] for m in agent_msgs)

    # Owner sees all 4 including local_only DM
    assert len(store.list_raw(sources=["wechat"], agent=False)) == 4


def test_vault_for_agent_encryption_redaction_and_hub_receipts(tmp_path: Path) -> None:
    vault = VaultStore(tmp_path / "vault")
    assert vault.is_initialized() is False
    vault.init_vault("correct-horse-battery-staple")
    assert vault.is_initialized() is True

    with pytest.raises(VaultAuthError):
        vault.unlock_key("wrong-passphrase")

    secret_token = "sk-live-SUPERSECRET987654321"
    meta = vault.put_record(
        "correct-horse-battery-staple",
        kind="api_key",
        label="OpenAI Production Key",
        secret_payload={"value": secret_token},
        project="raw-memory",
        allowed_commands=[Path(sys.executable).name],
        tags=["llm"],
    )
    rid = meta["id"]
    assert secret_token not in json.dumps(meta)

    # Raw SQLite file MUST NOT contain plaintext secret anywhere
    raw_bytes = vault.db_path.read_bytes()
    assert secret_token.encode("utf-8") not in raw_bytes

    # Decrypt succeeds with right passphrase
    dec = vault.get_record("correct-horse-battery-staple", rid)
    assert dec["secret"]["value"] == secret_token

    # Zero-exposure subprocess injection + automatic stdout/stderr redaction
    run_res = vault.run_with_injected_secrets(
        "correct-horse-battery-staple",
        env_bindings={"TEST_API_KEY": rid},
        command=[
            sys.executable,
            "-c",
            "import os; v=os.environ['TEST_API_KEY']; print('LEN=', len(v), 'LEAK=', v)",
        ],
    )
    assert run_res["returncode"] == 0
    assert f"LEN= {len(secret_token)}" in run_res["stdout"]
    assert secret_token not in run_res["stdout"]
    assert "***VAULT_REDACTED***" in run_res["stdout"]

    # Command allowlist enforcement blocks unauthorized executables
    with pytest.raises(PermissionError):
        vault.run_with_injected_secrets(
            "correct-horse-battery-staple",
            env_bindings={"TEST_API_KEY": rid},
            command=["/bin/echo", "nope"],
        )

    # Sync masked pointer receipt into Raw Memory Hub (zero plaintext leakage!)
    hub = HubStore(tmp_path / "hub")
    sync_res = vault.sync_masked_receipts_to_hub(hub)
    assert sync_res["created"] == 1
    receipts = hub.list_raw(sources=["vault"], agent=True)
    assert len(receipts) == 1
    assert rid in receipts[0]["body_text"]
    assert secret_token not in receipts[0]["body_text"]

    # Delete wipes ciphertext
    vault.delete_record(rid)
    assert vault.list_records() == []
    assert len(vault.list_audit_log()) >= 4


def test_antigravity_user_settings_change_envelope_stripped() -> None:
    raw = (
        "<USER_SETTINGS_CHANGE>\nSwitched model tier\n</USER_SETTINGS_CHANGE>\n"
        "请只保留真正有长期价值的记忆。"
    )
    cleaned, stripped = sanitize_turn_text("user", raw)
    assert "USER_SETTINGS_CHANGE" not in cleaned
    assert "Switched model tier" not in cleaned
    assert "请只保留真正有长期价值的记忆" in cleaned
    assert stripped is True


def test_channel_registry_and_lark_im_privacy_gating() -> None:
    specs = list_channel_specs()
    sources = {s["source"] for s in specs}
    assert {"ai_chat", "clipboard", "voice", "browser", "wechat", "im.lark", "vault", "window", "notes.obsidian"} <= sources

    msgs = [
        {"message_id": "om_1", "create_time": "1764200000000", "sender": {"id": "ou_self", "name": "Me"}, "content": '{"text": "确认本周接入飞书通道"}'},
        {"message_id": "om_2", "create_time": "1764200060000", "sender": {"id": "ou_peer", "name": "Partner"}, "content": '{"text": "好的"}'},
    ]
    # Without allowlist -> strictly local_only
    ev_locked = parse_lark_messages("oc_proj_1", "项目群", msgs, self_open_id="ou_self")
    assert len(ev_locked) == 2
    assert all(e.privacy.tier == "local_only" for e in ev_locked)
    assert ev_locked[0].actor == "self"

    # With allowlist -> promoted to shareable + mapped project
    ev_allowed = parse_lark_messages(
        "oc_proj_1",
        "项目群",
        msgs,
        self_open_id="ou_self",
        allowlist={"allow_sessions": ["oc_proj_1"], "default_allowed_tier": "shareable", "project_map": {"oc_proj_1": "raw-memory"}},
    )
    assert all(e.privacy.tier == "shareable" and e.project == "raw-memory" for e in ev_allowed)


def test_vault_entities_multi_phone_cn_id_attachments_and_autofill(tmp_path: Path) -> None:
    # Verify deterministic 18-digit Chinese ID birth_date & gender parser
    meta = extract_cn_id_metadata("31010119920518123X")
    assert meta == {"birth_date": "1992-05-18", "gender": "男"}

    vault = VaultStore(tmp_path / "vault")
    pw = "strong-local-passphrase"
    vault.init_vault(pw)

    # 1. Self profile with MULTIPLE phone numbers, emails, and addresses
    vault.put_record(
        pw,
        kind="person_profile",
        subject_id="self",
        label="本人基础资料",
        secret_payload={
            "full_name": "测试用户",
            "legal_name_en": "Test User",
            "phones": [
                {"label": "国内主力", "number": "13800138000", "country_code": "+86", "primary": True},
                {"label": "海外工作", "number": "6505550199", "country_code": "+1", "primary": False},
            ],
            "emails": [
                {"label": "个人", "address": "me@example.com", "primary": True},
                {"label": "公司", "address": "founder@rawmemory.app", "primary": False},
            ],
            "addresses": [
                {"label": "现居", "full_address": "上海市静安区示例路88号", "postal_code": "200040", "primary": True},
            ],
        },
    )

    # 2. Linked CN ID Card -> automatically contributes birth_date, gender, and 户籍地址
    id_rec = vault.put_record(
        pw,
        kind="identity_doc",
        subject_id="self",
        label="本人身份证",
        secret_payload={
            "doc_type": "cn_id_card",
            "holder_name": "测试用户",
            "doc_number": "31010119920518123X",
            "address": "浙江省杭州市西湖区示例路1号",
            "expiry_date": "2036-05-18",
        },
    )

    # 3. Company Business License + encrypted binary scan attachment
    lic_rec = vault.put_record(
        pw,
        kind="business_license",
        subject_id="company:rawmemory",
        label="营业执照正本",
        secret_payload={
            "company_name": "示例智能科技有限公司",
            "unified_social_credit_code": "91310106MA12345678",
            "legal_representative": "测试用户",
            "registered_address": "上海市静安区示例大厦10楼",
            "established_date": "2025-01-15",
        },
    )
    fake_pdf = b"%PDF-1.4\nBUSINESS_LICENSE_SECRET_BYTES_999"
    att = vault.add_attachment(
        pw,
        record_id=lic_rec["id"],
        filename="business_license.pdf",
        data=fake_pdf,
        mime_type="application/pdf",
    )
    # Encrypted blob on disk MUST NOT contain plaintext bytes
    blob_file = vault.blobs_dir / f"{att['id']}.enc"
    assert b"BUSINESS_LICENSE_SECRET_BYTES_999" not in blob_file.read_bytes()
    att_meta, decrypted_bytes = vault.get_attachment_bytes(pw, att["id"])
    assert att_meta["filename"] == "business_license.pdf"
    assert decrypted_bytes == fake_pdf

    # 4. Unified Form-Fill Bundle merges profile + extracted ID fields + all multiple phones/addresses
    af_plain = vault.build_autofill_bundle(pw, "self", masked=False)
    assert af_plain["basic_fields"]["full_name"] == "测试用户"
    assert af_plain["basic_fields"]["birth_date"] == "1992-05-18"
    assert af_plain["basic_fields"]["gender"] == "男"
    assert len(af_plain["phones"]) == 2
    assert len(af_plain["emails"]) == 2
    assert len(af_plain["addresses"]) == 2  # 现居 + 证件住址(cn_id_card)
    assert len(af_plain["documents"]) == 1 and af_plain["documents"][0]["record_id"] == id_rec["id"]

    af_masked = vault.build_autofill_bundle(pw, "self", masked=True)
    assert "13800138000" not in json.dumps(af_masked)
    assert "31010119920518123X" not in json.dumps(af_masked)

    # 5. Company autofill bundle includes business license credit code & attachment metadata
    co_af = vault.build_autofill_bundle(pw, "company:rawmemory", masked=False)
    assert co_af["entity_type"] == "company"
    assert co_af["basic_fields"]["unified_social_credit_code"] == "91310106MA12345678"
    assert len(co_af["documents"][0]["attachments"]) == 1

    # 6. Sync masked pointers to Hub (zero PII leaks!)
    hub = HubStore(tmp_path / "hub")
    res = vault.sync_masked_receipts_to_hub(hub)
    assert res["created"] == 3
    all_receipts = hub.list_raw(sources=["vault"], agent=True)
    assert len(all_receipts) == 3
    joined = json.dumps(all_receipts, ensure_ascii=False)
    assert "31010119920518123X" not in joined
    assert "91310106MA12345678" not in joined
    assert "13800138000" not in joined


def test_workbench_channels_and_vault_endpoints(tmp_path: Path) -> None:
    hub_dir = tmp_path / "hub_wb"
    HubStore(hub_dir)
    app = create_workbench_app(hub_dir)
    client = TestClient(app)

    # Channels status exposes all 13 reserved/active channels
    r_ch = client.get("/api/channels/status")
    assert r_ch.status_code == 200
    assert len(r_ch.json()["channels"]) >= 12

    # Upload a WeFlow chat export -> defaults to local_only -> toggle allowlist -> promoted to shareable!
    weflow = json.dumps(
        {
            "session": {"accountId": "999@chatroom", "name": "核心产品群", "isGroup": True},
            "messages": [
                {"id": "w1", "createTime": 1764202000, "senderName": "合伙人", "isSelf": False, "content": "周三看新版"},
            ],
        },
        ensure_ascii=False,
    )
    r_up = client.post("/api/channels/chat/upload", json={"filename": "group.json", "content": weflow})
    assert r_up.status_code == 200
    assert r_up.json()["report"]["created"] == 1

    r_allow = client.post(
        "/api/channels/chat/allowlist",
        json={"session_id": "999@chatroom", "allow": True, "project": "raw-memory"},
    )
    assert r_allow.status_code == 200
    assert r_allow.json()["updated_messages"] == 1

    # Vault init -> save partner record -> attach file -> autofill -> lock -> 403 enforced!
    assert client.post("/api/vault/init", json={"passphrase": "wb-secret-pass"}).status_code == 200
    r_rec = client.post(
        "/api/vault/record",
        json={
            "kind": "person_profile",
            "subject_id": "partner:zheng",
            "label": "合伙人政哥档案",
            "payload": {
                "full_name": "政哥示例",
                "phones": [{"label": "主力", "number": "13900139000", "primary": True}],
            },
        },
    )
    assert r_rec.status_code == 200
    rid = r_rec.json()["record"]["id"]

    r_att = client.post(
        f"/api/vault/record/{rid}/attach",
        json={
            "filename": "id_scan.txt",
            "mime_type": "text/plain",
            "content_b64": base64.b64encode(b"encrypted-scan").decode("ascii"),
        },
    )
    assert r_att.status_code == 200
    att_id = r_att.json()["attachment"]["id"]
    assert client.get(f"/api/vault/attachment/{att_id}").content == b"encrypted-scan"

    r_af = client.get("/api/vault/autofill/partner:zheng?masked=false")
    assert r_af.status_code == 200
    assert r_af.json()["phones"][0]["number"] == "13900139000"

    assert client.post("/api/vault/sync-receipts").json()["created"] == 1
    assert client.post("/api/vault/lock").json()["unlocked"] is False
    assert client.get("/api/vault/autofill/partner:zheng").status_code == 403

