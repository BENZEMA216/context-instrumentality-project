"""FastAPI HTTP API and FastMCP dual-loop integration tests for Context Hub v2."""

from __future__ import annotations

import asyncio
from pathlib import Path

from fastapi.testclient import TestClient

from context_hub.api import create_app, seed_demo_data
from context_hub.mcp_server import build_mcp_server
from context_hub.store import HubStore


def test_http_api_demo_seed_search_and_role_isolation(tmp_path: Path) -> None:
    app = create_app(tmp_path)
    client = TestClient(app)

    assert client.get("/api/v2/health").status_code == 200

    # Seed realistic cross-channel demo data as loopback owner
    seeded = client.post("/api/v2/demo/seed")
    assert seeded.status_code == 200
    assert seeded.json()["seeded"]["created"] == 5

    stats = client.get("/api/v2/stats").json()
    assert stats["raw_total"] == 5
    assert stats["decisions_active"] == 2
    assert stats["episodes_pending_curation"] >= 1
    assert stats["links_total"] >= 2

    # Ingest a local_only record and verify agent token cannot read it
    priv_ev = {
        "id": "ev_private_only",
        "source": "wechat",
        "kind": "message",
        "t_start": 1_763_626_000_000,
        "content": {"text": "个人私密备注：家庭门禁密码提醒"},
        "provenance": {"connector": "wechat", "source_id": "priv-1"},
    }
    created = client.post("/api/v2/events", json=priv_ev)
    assert created.status_code == 201
    assert created.json()["event"]["privacy"]["tier"] == "local_only"

    agent_headers = {"Authorization": f"Bearer {app.state.agent_token}"}
    assert client.get("/api/v2/events/ev_private_only", headers=agent_headers).status_code == 404
    assert client.get("/api/v2/events/ev_demo_voice_01", headers=agent_headers).status_code == 200
    # Agent cannot modify privacy rules
    assert client.get("/api/v2/privacy/rules", headers=agent_headers).status_code == 403

    # Search works for Chinese & English terms
    search = client.get("/api/v2/search", params={"q": "Agent-as-Curator"}, headers=agent_headers)
    assert search.status_code == 200
    body = search.json()
    assert body["decisions"]
    assert body["raw_matches"]

    # Markdown artifacts listed and readable by owner
    md_list = client.get("/api/v2/markdown").json()
    assert md_list["items"]
    first_md = md_list["items"][0]["path"]
    md_resp = client.get("/api/v2/markdown/file", params={"path": first_md})
    assert md_resp.status_code == 200
    assert md_resp.text.startswith("---")


def test_mcp_dual_loop_tools_resources_and_prompt(tmp_path: Path) -> None:
    store = HubStore(tmp_path)
    seed_demo_data(store)
    mcp = build_mcp_server(store)

    async def _exercise():
        tools = await mcp.list_tools()
        tool_names = {t.name for t in tools}
        expected = {
            "get_context_pack",
            "what_was_i_doing",
            "search_context",
            "get_project_state",
            "list_project_profiles",
            "upsert_project_profile",
            "get_user_profile",
            "upsert_user_profile",
            "get_evidence_context",
            "related",
            "expand",
            "get_curation_rules",
            "get_curation_queue",
            "commit_curation_batch",
            "record_memory",
            "correct_decision",
        }
        assert expected == tool_names

        resources = await mcp.list_resources()
        res_uris = {str(r.uri) for r in resources}
        assert {
            "context://now",
            "context://curation-rules",
            "context://projects",
            "context://memory-index",
        } <= res_uris

        prompts = await mcp.list_prompts()
        assert any(p.name == "curate_pending_context" for p in prompts)

        # Call consumption + curation tools via MCP
        _, queue_payload = await mcp.call_tool("get_curation_queue", {"limit": 3})
        assert queue_payload["total_pending"] >= 1
        ep_id = queue_payload["items"][0]["episode"]["id"]

        _, commit_payload = await mcp.call_tool(
            "commit_curation_batch",
            {
                "curator_agent": "antigravity",
                "episodes": [
                    {
                        "episode_id": ep_id,
                        "title": "Context OS v2 架构定案",
                        "summary": "确立 Agent-as-Curator 范式并保留微信与 Vault 为主线。",
                        "project": "context-os",
                        "entities": ["Antigravity", "Defuddle", "SenseVoice-Small"],
                        "evidence_ids": ["ev_demo_voice_01", "ev_demo_chat_01"],
                    }
                ],
            },
        )
        assert commit_payload["committed"]["episodes"] == [ep_id]

        _, state_payload = await mcp.call_tool(
            "get_project_state", {"project": "context-os", "include_history": True}
        )
        assert len(state_payload["active_decisions"]) == 2
        assert len(state_payload["superseded_decisions"]) == 1

        _, raw_payload = await mcp.call_tool(
            "expand", {"id": "ev_demo_voice_01", "level": "raw"}
        )
        assert "Agent-as-Curator" in raw_payload["record"]["body_text"]

        _, pack_payload = await mcp.call_tool(
            "get_context_pack", {"project": "context-os", "query": "Agent-as-Curator"}
        )
        assert len(pack_payload["active_decisions"]) == 2
        assert "workbench_urls" in pack_payload
        assert "/#/projects/context-os" in pack_payload["workbench_urls"]["project"]
        assert "Active Decisions" in pack_payload["rendered_markdown"]

    asyncio.run(_exercise())
