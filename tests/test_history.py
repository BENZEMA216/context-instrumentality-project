import json
from pathlib import Path
import shutil
import subprocess

import pytest

from hub.history import brief, import_one, main, sessions, versions
from hub.history_sources import rows
from hub.store import Store, StoreError


STAMP = "2026-01-01T12:00:00Z"


def write(path, data):
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


def lines(path, *items):
    path.write_text("".join(json.dumps(i) + "\n" for i in items), encoding="utf-8")
    return path


def transcript(session, text, provider="example", project="p"):
    return {"provider": provider, "session_id": session, "project": project,
            "messages": [{"id": "m", "timestamp": STAMP, "role": "user", "text": text}]}


def test_replay_visibility_and_revision_history(tmp_path):
    store = Store(tmp_path / "history.sqlite3")
    f = write(tmp_path / "fixture.json", transcript("s", "Use blue."))
    assert import_one(store, f, "transcript")["created"] == 1
    assert import_one(store, f, "transcript")["unchanged"] == 1
    assert store.extract()["created"] == 1
    info, = sessions(store, "p")
    turn, = brief(store, info["episode"])
    assert turn["role"] == "user" and turn["locator"] == "message:m"
    assert "Use blue." in turn["memories"][0]["body"]
    assert not store.list_memory(agent=True) and not store.list_raw(agent=True)
    write(f, transcript("s", "Use green."))
    with pytest.raises(ValueError, match="review"):
        import_one(store, f, "transcript")
    assert import_one(store, f, "transcript", update_existing=True)["updated"] == 1
    assert not store.list_memory()
    store.extract()
    assert "green" in brief(store, info["episode"])[0]["memories"][0]["body"]
    assert versions(store, turn["raw_id"]) == [{"revision": 1, "text": "Use blue."},
                                              {"revision": 2, "text": "Use green."}]
    store.delete_raw(turn["raw_id"], 2)
    assert import_one(store, f, "transcript")["tombstones"] == 1
    assert not store.list_memory() and not sessions(store)
    with pytest.raises(StoreError):
        versions(store, turn["raw_id"])
    with store._transaction(False) as conn:
        assert conn.execute("SELECT count(*) FROM chat_history_versions").fetchone()[0] == 0


def test_same_text_in_other_project_and_other_session_is_separate(tmp_path):
    s = Store(tmp_path / "data.db")
    for i, (provider, project, session) in enumerate([("a","p","s"),("a","p","t"),("b","q","s")]):
        p = write(tmp_path / f"{i}.json", transcript(session, "yes", provider, project))
        import_one(s, p, "transcript")
    assert s.extract()["created"] == 3
    assert sorted(x["turns"] for x in sessions(s, "p")) == [1, 1]
    assert len(sessions(s, "q")) == 1
    for m in s.list_memory():
        assert len(m["evidence_ids"]) == 1


def test_atomic_bad_tail_and_bulk_resume(tmp_path, capsys):
    db = tmp_path / "test.db"
    good = write(tmp_path / "first", transcript("a", "first"))
    bad = transcript("b", "partial")
    bad["messages"].append({"id":"b", "timestamp":"invalid", "role":"user", "text":"hidden-private-text"})
    broken = write(tmp_path / "second", bad)
    filelist = tmp_path / "input"
    filelist.write_text(f"{good}\n{broken}\n")
    assert main(["import", "--database", str(db), "--source", "transcript", "--files-from", str(filelist),
                 "--keep-going", "--defer-memory"]) == 1
    out = capsys.readouterr()
    assert "hidden-private-text" not in out.err and str(broken) not in out.err
    assert json.loads(out.out)["rejected"] == 1
    store = Store(db)
    assert len(store.list_raw()) == 1 and not store.list_memory()
    write(broken, transcript("b", "fixed"))
    assert main(["import", "--database", str(db), "--source", "transcript", "--files-from", str(filelist)]) == 0
    result = json.loads(capsys.readouterr().out)
    assert result["created"] == result["unchanged"] == 1 and len(store.list_memory()) == 2


def codex_ui(session, msg, role, text):
    return {"type":"event_msg", "timestamp": STAMP, "payload":{"type":"item_completed","thread_id":session,
            "item":{"id":msg, "type":role, "content":[{"type":"text", "text":text}]}}}


def test_codex_native_fork_and_metadata_filters(tmp_path):
    session = "00000000-0000-4000-8000-000000000001"
    f = tmp_path / ("rollout-" + session + ".jsonl")
    meta = {"type":"session_meta", "payload":{"id":session, "cwd":"/synthetic/work", "source":"vscode"}}
    user = codex_ui(session, "1", "UserMessage", "Set the date.")
    agent = codex_ui(session, "2", "AgentMessage", "The date is tentative.")
    items = [meta, user, codex_ui("other-thread","x","UserMessage","Inherited duplicate"), user,
             {"type":"event_msg","timestamp":STAMP,"payload":{"type":"user_message","message":"Set the date."}},
             {"type":"response_item","timestamp":STAMP,"payload":{"type":"message","role":"assistant",
              "content":[{"type":"output_text","text":"The date is tentative."}]}},
             {"type":"response_item", "payload":{"type":"reasoning","text":"private"}},
             codex_ui(session,"env","UserMessage","<environment_context>internal"), agent]
    result = list(rows(lines(f,*items), "codex", None))
    assert [(r["content"]["role"],r["content"]["text"]) for r in result] == [
        ("user","Set the date."),("assistant","The date is tentative.")]
    assert all(r["context"]["origin"]=="user" for r in result)
    assert "/synthetic/work" not in json.dumps(result)
    if shutil.which("zstd"):
        za = tmp_path / (f.name + ".zst")
        za.write_bytes(subprocess.check_output(["zstd","-qc",str(f)]))
        assert list(rows(za,"codex",None)) == result


def test_codex_old_wire_and_claude_blocks(tmp_path):
    cod = lines(tmp_path/"old", {"type":"session_meta","payload":{"id":"s"}},
                {"type":"response_item","timestamp":STAMP,"payload":{"id":"i","type":"message","role":"user",
                 "content":[{"type":"input_text","text":"question"},{"type":"input_image","image_url":"private media"}]}})
    assert list(rows(cod,"codex",None))[0]["content"]["text"] == "question"
    m = {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hidden"},
         {"type":"text","text":"answer"},{"type":"tool_use","input":{"private":"secret"}}]},
         "timestamp":STAMP,"uuid":"m","sessionId":"s","cwd":"/private/example"}
    f = lines(tmp_path/"c", m, {**m,"isMeta":True}, {**m,"sourceToolAssistantUUID":"t"})
    r, = rows(f,"claude",None)
    assert r["content"]["text"] == "answer" and "hidden" not in json.dumps(r)


def test_gemini_and_chatgpt_hidden_ancestors_and_branches(tmp_path):
    f = write(tmp_path/"g",{"sessionId":"s","projectHash":"hash","messages":[
        {"id":"m","type":"gemini","timestamp":STAMP,"thoughts":[{"text":"private"}],
         "content":[{"text":"hello"}],"toolCalls":[{"result":"private"}]}]})
    r, = rows(f,"gemini",None)
    assert r["content"] == {"role":"assistant","text":"hello"}
    def node(role,text,parent=None,**more):
        return {"parent":parent,"message":{"author":{"role":role},"create_time":1_700_000_000,
                "content":{"content_type":"text","parts":[text]},**more}}
    tree={"id":"s","mapping":{"a":node("user","choose"),"t":node("tool","hidden","a"),
          "b":node("assistant","first","t"),"c":node("assistant","alternative","a"),
          "d":node("assistant","tool call","t",recipient="python")}}
    group = list(rows(write(tmp_path/"export",[tree]),"chatgpt","example"))
    assert len(group)==3
    assert all(turn["links"]==[{"relation":"reply_to","target_id":group[0]["id"]}] for turn in group[1:])


def test_cross_session_digest_separates_user_changes_from_assistant_reports(tmp_path):
    from hub.history import digest
    store = Store(tmp_path/"db")
    d = {"provider":"example","session_id":"a","project":"suite","origin":"user","messages":[
        {"id":"a","role":"user","timestamp":1,"text":"Please use a blue icon."},
        {"id":"b","role":"user","timestamp":2,"text":"Use a green icon instead."},
        {"id":"c","role":"assistant","timestamp":3,"text":"已验证绿色图标。"}]}
    import_one(store, write(tmp_path/"source",d),"transcript")
    import_one(store, write(tmp_path/"other",transcript("automated","unrelated",project="else")),"transcript")
    store.extract()
    result = digest(store,project="suite",limit=1,origin="user")
    assert result["matched"] == {"user_change_mentions":1,"user_requests":1,"other_user_turns":0,
                                  "assistant_progress_reports":1,"other_assistant_turns":0}
    for group in result["recent_evidence"].values():
        for row in group:
            assert row["id"] in store.get_memory(row["memory_id"])["evidence_ids"]
            assert store.get_raw(row["id"])["content"]["role"] == row["role"]
    assert not any(digest(store,project="suite",origin="automation")["matched"].values())


def test_missing_time_and_parent_session_are_retained_without_fabricated_dates(tmp_path):
    s = Store(tmp_path / "db")
    payload = transcript("child", "first")
    del payload["messages"][0]["timestamp"]
    payload["messages"].append({"id":"n","role":"assistant","text":"next","timestamp_status":"missing"})
    payload["parent_session_id"] = "parent"
    import_one(s,write(tmp_path / "import", payload),"transcript")
    s.extract()
    info, = sessions(s)
    assert info["first_ms"] is None and info["last_ms"] is None and info["unknown_times"] == 2
    turns=brief(s,info["episode"])
    assert [v["at_ms"] for v in turns] == [None,None]
    assert [v["role"] for v in turns] == ["user","assistant"]
    assert all(r["context"]["parent_session_id"] == "parent" and r["context"]["timestamp_status"] == "missing"
               for r in s.list_raw())


def test_claude_web_export_roles_parents_and_exclusions(tmp_path):
    data=[{"uuid":"conversation","account":{"email":"withheld"},
           "chat_messages":[
             {"uuid":"h","sender":"human","created_at":STAMP,"text":"Would blue work?","attachments":["private"]},
             {"uuid":"hidden","sender":"assistant","content":[{"type":"tool_result","text":"private"}],
              "text":"private","parent_message_uuid":"h"},
             {"uuid":"a","sender":"assistant","created_at":STAMP,"content":[
                 {"type":"thinking","thinking":"private"},{"type":"text","text":"Try blue first."}],
              "text":"duplicate","parent_message_uuid":"hidden"}]}]
    projected=list(rows(write(tmp_path/"export.json",data),"claude-web",None))
    assert [r["content"]["text"] for r in projected] == ["Would blue work?","Try blue first."]
    assert projected[1]["links"][0]["target_id"]==projected[0]["id"]
    assert all(s not in json.dumps(projected) for s in ("duplicate","private","withheld"))


def test_mcp_finds_the_authorized_turn_and_loses_it_after_owner_deletion(tmp_path):
    import asyncio
    import sys
    import threading

    pytest.importorskip("mcp")
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client
    from hub.server import HubHTTP

    s = Store(tmp_path/"db")
    import_one(s,write(tmp_path/"input",transcript("s","Synthetic source correction.")),"transcript")
    s.extract()
    raw, = s.list_raw()
    http = HubHTTP(("127.0.0.1",0),s,"synthetic-owner","synthetic-agent")
    server = threading.Thread(target=http.serve_forever,kwargs={"poll_interval":0.02})
    server.start()

    async def check():
        params=StdioServerParameters(command=sys.executable,args=["-m","hub","mcp"],
                                     env={"HUB_URL":f"http://127.0.0.1:{http.server_port}",
                                          "HUB_AGENT_TOKEN":"synthetic-agent","PYTHONPATH":str(Path(__file__).resolve().parents[1])})
        async with stdio_client(params) as (read,send), ClientSession(read,send) as client:
            await client.initialize()
            async def result(tool,data):
                v=await client.call_tool(tool,data)
                assert not v.isError
                return v.structuredContent or json.loads(v.content[0].text)
            assert (await result("search_memory",{"q":"Synthetic"}))["items"] == []
            assert (await client.call_tool("get_raw",{"id":raw["id"]})).isError
            s.put_raw({**raw,"privacy":{"tier":"shareable"}},expected_revision=1)
            s.extract()
            memory,=(await result("search_memory",{"q":"Synthetic"}))["items"]
            cited,=memory["evidence_ids"]
            evidence=await result("get_raw",{"id":cited})
            assert evidence["content"]==raw["content"] and evidence["provenance"]["locator"]=="message:m"
            s.delete_raw(cited,2)
            assert (await result("search_memory",{"q":"Synthetic"}))["items"] == []
            assert (await client.call_tool("get_raw",{"id":cited})).isError
    try:
        asyncio.run(check())
    finally:
        http.shutdown()
        http.server_close()
        server.join()


def test_repository_instructions_wrapper_does_not_swallow_authored_messages():
    from hub.history_sources import participant_text
    wrapped = "# AGENTS.md instructions for example\n\n<INSTRUCTIONS>Fixture rules.</INSTRUCTIONS>"
    assert not participant_text("user", wrapped)
    assert not participant_text("user", wrapped + "\n<environment_context>fixture</environment_context>")
    assert participant_text("user", "Please edit AGENTS.md and preserve its <INSTRUCTIONS> section.")
    assert participant_text("user", wrapped + "\nPlease explain this passage.")
    assert participant_text("assistant", wrapped)
