"""FastAPI HTTP API and embedded Context Workbench static frontend."""

from __future__ import annotations

import hmac
import secrets
from pathlib import Path
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from .curation_rules import build_curator_prompt, load_curation_rules
from .models import (
    CollectorStatusIn,
    CurationBatchIn,
    MemoryCurationIn,
    PrivacyRuleIn,
    PrivacyTier,
    RawEventIn,
    now_ms,
)
from .store import HubStore, HubStoreError

STATIC_DIR = Path(__file__).resolve().parent / "static"


class PrivacyUpdateBody(BaseModel):
    tier: PrivacyTier


class DecisionCorrectBody(BaseModel):
    statement: str
    evidence_ids: list[str]
    authority: str = "user_confirmed"


class BatchIngestBody(BaseModel):
    events: list[RawEventIn]


class RevokeSourceBody(BaseModel):
    source: str
    connector: str
    source_id: str


def _load_or_create_token(data_dir: Path, name: str) -> str:
    path = data_dir / f"{name}.token"
    if path.is_file():
        return path.read_text(encoding="ascii").strip()
    data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    token = secrets.token_urlsafe(32)
    path.write_text(token, encoding="ascii")
    path.chmod(0o600)
    return token


def seed_demo_data(store: HubStore) -> dict[str, Any]:
    """Populate a realistic multi-channel synthetic scenario to showcase L0-L4 & Agent-as-Curator."""
    base = now_ms() - 40 * 60 * 1000
    events = [
        RawEventIn(
            id="ev_demo_voice_01",
            source="voice",
            kind="transcript_segment",
            t_start=base,
            t_end=base + 45_000,
            actor="self",
            device_id="apple-watch-ultra",
            project="context-os",
            content={
                "title": "散步灵感 · 整理算力架构讨论",
                "text": "我们不要在 Hub 里内置付费 API Key 跑摘要，改成 Agent-as-Curator，直接让用户已有的 Antigravity、Codex 或 WorkBuddy 来拉队列按规则整理。",
                "lang": "zh",
            },
            provenance={
                "connector": "record-for-agent",
                "source_id": "demo-rec-001",
                "locator": "record-for-agent://demo-rec-001#t=0,45",
            },
            privacy={"tier": "shareable"},
        ),
        RawEventIn(
            id="ev_demo_browser_01",
            source="browser",
            kind="page_read",
            t_start=base + 8 * 60 * 1000,
            t_end=base + 14 * 60 * 1000,
            actor="self",
            device_id="macbook-pro",
            project="context-os",
            content={
                "title": "Defuddle + SQLite FTS5 个人上下文管线设计参考",
                "url": "https://github.com/kepano/defuddle?utm_source=demo",
                "text": "Defuddle extracts clean Markdown preserving code fences and math. Combine with SQLite FTS5 trigram/bigram indexing for millisecond local search: uv run context-hub serve --port 8741",
                "summary": "使用 Defuddle 抽取干净网页正文并结合 SQLite FTS5 做本地毫秒级检索。",
            },
            context={"dwell_ms": 360_000, "scroll_depth": 0.88, "curation_tier": "auto_curated"},
            provenance={
                "connector": "browser-mv3",
                "source_id": "demo-page-defuddle",
                "locator": "https://github.com/kepano/defuddle",
            },
            privacy={"tier": "shareable"},
        ),
        RawEventIn(
            id="ev_demo_clip_01",
            source="clipboard",
            kind="copy",
            t_start=base + 12 * 60 * 1000,
            t_end=base + 12 * 60 * 1000,
            actor="self",
            device_id="macbook-pro",
            project="context-os",
            content={
                "title": "uv run context-hub serve --port 8741",
                "text": "uv run context-hub serve --port 8741",
            },
            context={"app_bundle": "com.google.Chrome"},
            provenance={
                "connector": "clipcontext",
                "source_id": "demo-clip-001",
                "locator": "Raw/chunks/00000000.json#item=demo-clip-001",
            },
            privacy={"tier": "shareable"},
        ),
        RawEventIn(
            id="ev_demo_chat_01",
            source="ai_chat",
            kind="chat_turn",
            t_start=base + 18 * 60 * 1000,
            t_end=base + 18 * 60 * 1000,
            actor="self",
            device_id="macbook-pro",
            project="context-os",
            content={
                "role": "user",
                "title": "确认微信与 Context Vault 都留在主线",
                "text": "确认：微信渠道和 Context Vault 都是 Context 补全计划的主线核心部分，另外整理模型改用 Agent-as-Curator 复用 Antigravity/Codex/WorkBuddy 算力。",
            },
            provenance={
                "connector": "chat-history/antigravity",
                "source_id": "demo-chat-turn-001",
                "locator": "antigravity://session-demo#turn=1",
            },
            privacy={"tier": "shareable"},
        ),
        RawEventIn(
            id="ev_demo_wechat_01",
            source="wechat",
            kind="message",
            t_start=base + 25 * 60 * 1000,
            t_end=base + 25 * 60 * 1000,
            actor="colleague_lin",
            device_id="macbook-pro",
            project="context-os",
            content={
                "title": "产品研发群 · 微信讨论",
                "text": "周五前把 SenseVoice-Small 本地中文转写接入 Hub 测一下“蓝鲸”那句样本，顺便看看 Vault 代理能不能回传脱敏正文。",
            },
            provenance={
                "connector": "wechat-ax",
                "source_id": "demo-wx-001",
                "locator": "wechat://product-group#msg=001",
            },
            privacy={"tier": "shareable"},
        ),
    ]
    ingest_res = store.ingest_batch(events)

    # Seed one initial decision & supersede it to demonstrate bi-temporal evolution
    ep_list = store.list_episodes(project="context-os", limit=5)
    target_ep = ep_list[0]["id"] if ep_list else None
    if target_ep and not store.list_decisions(project="context-os"):
        initial = store.commit_curation_batch(
            CurationBatchIn(
                curator_agent="antigravity-demo",
                decisions=[
                    {
                        "project": "context-os",
                        "topic": "记忆整理算力策略",
                        "statement": "旧方案：在 Hub 服务端内置本地 Ollama 或外部 LLM API Key 自动跑摘要。",
                        "authority": "assistant_suggested",
                        "valid_at": base - 3_600_000,
                        "evidence_ids": ["ev_demo_voice_01"],
                    }
                ],
                notes="Initial baseline before user confirmation",
            ),
            allow_local_only=True,
        )
        old_dec_id = initial["committed"]["decisions"][0]
        store.commit_curation_batch(
            CurationBatchIn(
                curator_agent="antigravity-demo",
                decisions=[
                    {
                        "project": "context-os",
                        "topic": "记忆整理算力策略",
                        "statement": "采用 Agent-as-Curator 范式：由用户已有 Agent（Antigravity / Codex / WorkBuddy）拉取队列、按显式规则整理并经强校验回写。",
                        "authority": "user_confirmed",
                        "valid_at": base + 18 * 60 * 1000,
                        "supersedes_decision_id": old_dec_id,
                        "evidence_ids": ["ev_demo_voice_01", "ev_demo_chat_01"],
                    },
                    {
                        "project": "context-os",
                        "topic": "主线模块范围",
                        "statement": "微信渠道与 Context Vault v2 均为 Context 补全计划核心主线，统一纳入 Workbench 与主仓架构。",
                        "authority": "user_confirmed",
                        "valid_at": base + 18 * 60 * 1000,
                        "evidence_ids": ["ev_demo_chat_01"],
                    },
                ],
                memories=[
                    {
                        "title": "跨渠道整理防幻觉底线",
                        "body": "每条摘要与决策必须绑定真实 Raw evidence_ids，且自动继承关联证据中最严格的隐私等级。",
                        "kind": "fact",
                        "project": "context-os",
                        "tags": ["architecture", "curation", "privacy"],
                        "evidence_ids": ["ev_demo_voice_01", "ev_demo_browser_01"],
                    }
                ],
                notes="Demo seed curation showing bi-temporal decision evolution",
            ),
            allow_local_only=True,
        )
        # Keep the episode pending_curation so the user can also test live Agent Curation right away!
    return {"seeded": ingest_res, "pending_episode": target_ep}


def create_app(
    data_dir: Path,
    *,
    allow_loopback_owner: bool = True,
) -> FastAPI:
    store = HubStore(data_dir)
    owner_token = _load_or_create_token(data_dir, "owner")
    agent_token = _load_or_create_token(data_dir, "agent")

    app = FastAPI(title="Context Hub v2", version="0.2.0")
    app.state.store = store
    app.state.owner_token = owner_token
    app.state.agent_token = agent_token

    app.add_middleware(
        CORSMiddleware,
        allow_origins=[
            "http://127.0.0.1:8741",
            "http://localhost:8741",
            "http://127.0.0.1:5173",
            "http://localhost:5173",
        ],
        allow_origin_regex=r"^(chrome-extension://[a-z]{32}|moz-extension://[a-f0-9-]+)$",
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.exception_handler(HubStoreError)
    async def _store_error(_: Request, exc: HubStoreError) -> JSONResponse:
        return JSONResponse(status_code=exc.status, content={"error": str(exc)})

    def resolve_role(
        request: Request,
        authorization: str | None = Header(default=None),
    ) -> str:
        if authorization and authorization.startswith("Bearer "):
            token = authorization[7:].strip()
            if hmac.compare_digest(token, owner_token):
                return "owner"
            if hmac.compare_digest(token, agent_token):
                return "agent"
            raise HTTPException(status_code=401, detail="Invalid bearer token")
        client_host = request.client.host if request.client else ""
        if allow_loopback_owner and client_host in ("127.0.0.1", "::1", "testclient", "localhost"):
            return "owner"
        raise HTTPException(status_code=401, detail="Bearer token required")

    def require_owner(role: str = Depends(resolve_role)) -> str:
        if role != "owner":
            raise HTTPException(status_code=403, detail="Owner privileges required")
        return role

    # ---------------- Health & Stats ----------------
    @app.get("/api/v2/health")
    def health() -> dict[str, Any]:
        return {"status": "ok", "version": "0.2.0", "data_dir": str(data_dir)}

    @app.get("/api/v2/stats")
    def stats(role: str = Depends(resolve_role)) -> dict[str, Any]:
        return {**store.stats(), "role": role}

    # ---------------- Raw Events ----------------
    @app.get("/api/v2/events")
    def list_events(
        q: str = "",
        source: Annotated[list[str] | None, Query()] = None,
        project: str | None = None,
        episode_id: str | None = None,
        since_ms: int | None = None,
        until_ms: int | None = None,
        limit: int = 50,
        offset: int = 0,
        role: str = Depends(resolve_role),
    ) -> dict[str, Any]:
        items = store.list_raw(
            q=q,
            sources=source,
            project=project,
            episode_id=episode_id,
            since_ms=since_ms,
            until_ms=until_ms,
            limit=limit,
            offset=offset,
            agent=(role == "agent"),
        )
        return {"items": items}

    @app.post("/api/v2/events", status_code=201)
    def create_event(
        event: RawEventIn,
        _: str = Depends(require_owner),
    ) -> dict[str, Any]:
        return store.ingest_event(event)

    @app.post("/api/v2/events/batch", status_code=201)
    def create_events_batch(
        body: BatchIngestBody,
        _: str = Depends(require_owner),
    ) -> dict[str, Any]:
        return store.ingest_batch(body.events)

    @app.get("/api/v2/events/{raw_id}")
    def get_event(raw_id: str, role: str = Depends(resolve_role)) -> dict[str, Any]:
        return store.get_raw(raw_id, agent=(role == "agent"))

    @app.get("/api/v2/events/{raw_id}/content")
    def get_event_content(
        raw_id: str,
        offset: int = 0,
        limit: int = 8000,
        role: str = Depends(resolve_role),
    ) -> dict[str, Any]:
        return store.get_raw_content(raw_id, offset=offset, limit=limit, agent=(role == "agent"))

    @app.post("/api/v2/events/revoke")
    def revoke_event_by_source(
        body: RevokeSourceBody,
        _: str = Depends(require_owner),
    ) -> dict[str, Any]:
        return store.delete_raw_by_source(body.source, body.connector, body.source_id)

    @app.patch("/api/v2/events/{raw_id}/privacy")
    def patch_event_privacy(
        raw_id: str,
        body: PrivacyUpdateBody,
        _: str = Depends(require_owner),
    ) -> dict[str, Any]:
        return store.update_raw_privacy(raw_id, body.tier)

    @app.delete("/api/v2/events/{raw_id}")
    def delete_event(raw_id: str, _: str = Depends(require_owner)) -> dict[str, Any]:
        return store.delete_raw(raw_id)

    # ---------------- Episodes ----------------
    @app.get("/api/v2/episodes")
    def list_episodes(
        project: str | None = None,
        status: str | None = None,
        source: str | None = None,
        since_ms: int | None = None,
        until_ms: int | None = None,
        limit: int = 30,
        offset: int = 0,
        role: str = Depends(resolve_role),
    ) -> dict[str, Any]:
        return {
            "items": store.list_episodes(
                project=project,
                status=status,
                source=source,
                since_ms=since_ms,
                until_ms=until_ms,
                limit=limit,
                offset=offset,
                agent=(role == "agent"),
            )
        }

    @app.get("/api/v2/episodes/{episode_id}")
    def get_episode(episode_id: str, role: str = Depends(resolve_role)) -> dict[str, Any]:
        return store.get_episode(episode_id, agent=(role == "agent"))

    # ---------------- Decisions & Projects ----------------
    @app.get("/api/v2/projects")
    def list_projects(role: str = Depends(resolve_role)) -> dict[str, Any]:
        return {"items": store.list_projects(agent=(role == "agent"))}

    @app.get("/api/v2/projects/{project}/state")
    def project_state(
        project: str,
        include_history: bool = True,
        role: str = Depends(resolve_role),
    ) -> dict[str, Any]:
        return store.get_project_state(
            project, include_history=include_history, agent=(role == "agent")
        )

    @app.get("/api/v2/decisions")
    def list_decisions(
        project: str | None = None,
        status: str | None = None,
        limit: int = 50,
        role: str = Depends(resolve_role),
    ) -> dict[str, Any]:
        return {
            "items": store.list_decisions(
                project=project, status=status, limit=limit, agent=(role == "agent")
            )
        }

    @app.post("/api/v2/decisions/{decision_id}/correct")
    def correct_decision(
        decision_id: str,
        body: DecisionCorrectBody,
        role: str = Depends(resolve_role),
    ) -> dict[str, Any]:
        return store.correct_decision(
            decision_id,
            statement=body.statement,
            evidence_ids=body.evidence_ids,
            authority=body.authority,
            author=role,
            allow_local_only=(role == "owner"),
        )

    # ---------------- Memories ----------------
    @app.get("/api/v2/memories")
    def list_memories(
        q: str = "",
        project: str | None = None,
        kind: str | None = None,
        limit: int = 50,
        offset: int = 0,
        role: str = Depends(resolve_role),
    ) -> dict[str, Any]:
        return {
            "items": store.list_memories(
                q=q, project=project, kind=kind, limit=limit, offset=offset, agent=(role == "agent")
            )
        }

    @app.post("/api/v2/memories", status_code=201)
    def create_memory(
        body: MemoryCurationIn,
        role: str = Depends(resolve_role),
    ) -> dict[str, Any]:
        return store.save_manual_memory(body, author=role, allow_local_only=(role == "owner"))

    # ---------------- Unified Hybrid Search & Related ----------------
    @app.get("/api/v2/search")
    def search(
        q: str = "",
        source: Annotated[list[str] | None, Query()] = None,
        project: str | None = None,
        since_ms: int | None = None,
        until_ms: int | None = None,
        limit: int = 15,
        max_tokens: int = 3000,
        role: str = Depends(resolve_role),
    ) -> dict[str, Any]:
        return store.search_context(
            q,
            sources=source,
            project=project,
            since_ms=since_ms,
            until_ms=until_ms,
            limit=limit,
            agent=(role == "agent"),
            max_tokens=max_tokens,
        )

    @app.get("/api/v2/related")
    def get_related(
        id: str | None = None,
        url: str | None = None,
        text: str | None = None,
        limit: int = 15,
        role: str = Depends(resolve_role),
    ) -> dict[str, Any]:
        return store.related(item_id=id, url=url, text=text, limit=limit, agent=(role == "agent"))

    @app.get("/api/v2/context-pack")
    def context_pack(
        request: Request,
        q: str | None = None,
        project: str | None = None,
        minutes: int = 240,
        max_tokens: int = 2500,
        role: str = Depends(resolve_role),
    ) -> dict[str, Any]:
        base = str(request.base_url).rstrip("/")
        return store.get_context_pack(
            query=q,
            project=project,
            minutes=minutes,
            max_tokens=max_tokens,
            agent=(role == "agent"),
            workbench_base_url=base,
        )

    # ---------------- Agent-as-Curator Endpoints ----------------
    @app.get("/api/v2/curation/rules")
    def curation_rules(_: str = Depends(resolve_role)) -> dict[str, Any]:
        rules = load_curation_rules()
        return {
            **rules,
            "prompts": {
                "antigravity": build_curator_prompt(curator_agent="antigravity"),
                "codex": build_curator_prompt(curator_agent="codex"),
                "workbuddy": build_curator_prompt(curator_agent="workbuddy"),
            },
        }

    @app.get("/api/v2/curation/queue")
    def curation_queue(
        limit: int = 5,
        project: str | None = None,
        source: str | None = None,
        include_local_only: bool = False,
        role: str = Depends(resolve_role),
    ) -> dict[str, Any]:
        allow_local = include_local_only and role == "owner"
        return store.get_curation_queue(
            limit=limit, project=project, source=source, include_local_only=allow_local
        )

    @app.post("/api/v2/curation/commit")
    def curation_commit(
        batch: CurationBatchIn,
        role: str = Depends(resolve_role),
    ) -> dict[str, Any]:
        return store.commit_curation_batch(batch, allow_local_only=(role == "owner"))

    # ---------------- Markdown Artifacts ----------------
    @app.get("/api/v2/markdown")
    def list_markdown(_: str = Depends(require_owner)) -> dict[str, Any]:
        return {"root": str(store.markdown.root), "items": store.markdown.list_files()}

    @app.get("/api/v2/markdown/file")
    def read_markdown(path: str, _: str = Depends(require_owner)) -> PlainTextResponse:
        try:
            content = store.markdown.read_file(path)
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from None
        return PlainTextResponse(content, media_type="text/markdown; charset=utf-8")

    # ---------------- Privacy Rules & Collectors ----------------
    @app.get("/api/v2/privacy/rules")
    def list_rules(_: str = Depends(require_owner)) -> dict[str, Any]:
        return {"items": store.list_privacy_rules()}

    @app.post("/api/v2/privacy/rules")
    def save_rule(rule: PrivacyRuleIn, _: str = Depends(require_owner)) -> dict[str, Any]:
        return store.upsert_privacy_rule(rule)

    @app.delete("/api/v2/privacy/rules/{rule_id}")
    def delete_rule(rule_id: str, _: str = Depends(require_owner)) -> dict[str, Any]:
        return store.delete_privacy_rule(rule_id)

    @app.get("/api/v2/collectors/status")
    def collectors_status(_: str = Depends(require_owner)) -> dict[str, Any]:
        return {"items": store.list_collector_statuses()}

    @app.get("/api/v2/collectors/checkpoints")
    def collectors_checkpoints(
        collector: str | None = None,
        _: str = Depends(require_owner),
    ) -> dict[str, Any]:
        return {"items": store.list_collector_checkpoints(collector)}

    @app.post("/api/v2/collectors/status")
    def update_collector(
        body: CollectorStatusIn, _: str = Depends(require_owner)
    ) -> dict[str, Any]:
        return store.update_collector_status(body)

    @app.post("/api/v2/maintenance/sync-memory")
    def sync_memory_layer(_: str = Depends(require_owner)) -> dict[str, Any]:
        return {"written": store.sync_markdown_memory_layer()}

    @app.post("/api/v2/demo/seed")
    def demo_seed(_: str = Depends(require_owner)) -> dict[str, Any]:
        return seed_demo_data(store)

    @app.post("/api/v2/maintenance/rebuild")
    def rebuild(_: str = Depends(require_owner)) -> dict[str, Any]:
        return store.rebuild_from_l0()

    # ---------------- Embedded Static Workbench ----------------
    if (STATIC_DIR / "assets").is_dir():
        app.mount("/assets", StaticFiles(directory=STATIC_DIR / "assets"), name="assets")

    @app.get("/{full_path:path}")
    def serve_workbench(full_path: str):
        if full_path.startswith("api/"):
            raise HTTPException(status_code=404, detail="Unknown API endpoint")
        index = STATIC_DIR / "index.html"
        if index.is_file():
            return FileResponse(index)
        return JSONResponse(
            {
                "service": "Context Hub v2",
                "message": "Workbench frontend not built yet. Run `npm --prefix web run build`.",
                "docs": "/docs",
            }
        )

    return app
