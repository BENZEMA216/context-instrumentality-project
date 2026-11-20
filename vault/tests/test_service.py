import base64
from concurrent.futures import ThreadPoolExecutor
from functools import partial
import json
import threading
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

from context_vault import intake
from context_vault.service import Service, VaultHTTP
from context_vault.storage import Store, VaultError


PASSWORD = "synthetic sample passphrase"


class Client:
    def __init__(self, server):
        self.url = f"http://127.0.0.1:{server.server_port}"
        self.session = None

    def call(self, method, path, body=None, owner=True, cookie=True, headers=None):
        data = None if body is None else json.dumps(body).encode()
        fields = {
            "Authorization": "Bearer "
            + ("owner-fixture" if owner else "agent-fixture"),
            "Content-Type": "application/json",
            **(headers or {}),
        }
        if cookie and owner and self.session:
            fields["Cookie"] = self.session
        try:
            reply = urlopen(
                Request(self.url + path, data=data, method=method, headers=fields),
                timeout=10,
            )
        except HTTPError as error:
            reply = error
        with reply:
            if "Set-Cookie" in reply.headers:
                self.session = reply.headers["Set-Cookie"].split(";")[0]
            return reply.status, json.load(reply)


@pytest.fixture
def runtime(tmp_path):
    dispatched = []

    def deliver(item):
        dispatched.append(item["value"])
        return 204

    service = Service(
        tmp_path / "private",
        "owner-fixture",
        "agent-fixture",
        backups=tmp_path / "cloud",
        transport=deliver,
    )
    with VaultHTTP(("127.0.0.1", 0), service) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            yield Client(server), service, dispatched
        finally:
            server.shutdown()
            worker.join()
            service.lock()


def test_approval_chain(runtime):
    client, service, dispatched = runtime
    assert client.call("GET", "/api/catalog", owner=False)[0] == 423
    assert client.call("POST", "/api/setup", {"password": PASSWORD})[0] == 200
    item = {
        "kind": "key",
        "label": "Example API",
        "target": "https://example.com/account",
        "value": "synthetic-private-key",
    }
    created = client.call("POST", "/api/items", item)
    assert created[0] == 200 and "value" not in created[1]
    ident = created[1]["id"]
    assert client.call("GET", "/api/items/" + ident, cookie=False)[0] == 403
    assert client.call("GET", "/api/items/" + ident, owner=False)[0] == 403
    assert client.call("GET", "/api/items/" + ident)[1]["value"] == item["value"]
    assert (
        client.call("GET", "/api/items", headers={"Origin": "https://other.example"})[0]
        == 403
    )
    assert client.call("GET", "/health", headers={"Host": "other.example"})[0] == 403
    assert (
        client.call("POST", "/api/items", dict(item, target="https://127.0.0.1/"))[0]
        == 400
    )
    assert client.call("GET", "/api/catalog", owner=False)[1] == {
        "items": [{"id": ident, "kind": "key", "label": "Example API"}]
    }
    claim = {"asset_id": ident, "purpose": "Check the test API"}
    path = (
        "/api/requests/"
        + client.call("POST", "/api/requests", claim, owner=False)[1]["id"]
    )
    assert client.call("POST", path + "/use", {}, owner=False)[0] == 409
    assert client.call("POST", path + "/approve", {}, owner=False)[0] == 403
    assert client.call("POST", path + "/approve", {})[0] == 200
    execute = partial(client.call, "POST", path + "/use", {}, owner=False)
    with ThreadPoolExecutor(2) as pool:
        results = list(pool.map(lambda _: execute(), range(2)))
    assert sorted(status for status, _ in results) == [200, 409]
    assert dispatched == [item["value"]] and item["value"] not in str(results)
    second = (
        "/api/requests/"
        + client.call("POST", "/api/requests", claim, owner=False)[1]["id"]
    )
    assert client.call("POST", second + "/approve", {})[0] == 200
    assert client.call("POST", second + "/revoke", {})[0] == 200
    assert client.call("POST", second + "/use", {}, owner=False)[0] == 409
    assert client.call("POST", "/api/lock", {})[0] == 200
    assert client.call("GET", path, owner=False)[0] == 423
    assert client.call("POST", "/api/unlock", {"password": PASSWORD})[0] == 200
    assert client.call("GET", path, owner=False)[0] == 404


def test_cloud_intake_and_recovery(runtime, tmp_path):
    c, svc, _ = runtime
    c.call("POST", "/api/setup", {"password": PASSWORD})
    assert not (tmp_path / "cloud").exists()
    public = c.call("GET", "/api/phone-key")[1]["pairing"]
    payload = {
        "kind": "document",
        "label": "Synthetic degree",
        "mime": "application/pdf",
        "value": base64.b64encode(b"%PDF-1.7 synthetic exact file").decode(),
    }
    package = intake.seal_item(public, payload)
    assert "degree" not in str(package) and payload["value"] not in str(package)
    tampered = {**package, "ct": package["ct"][4:]}
    assert c.call("POST", "/api/phone-import", {"package": tampered})[0] == 400
    assert c.call("POST", "/api/cloud", {"enabled": True})[1]["last_backup"]
    input_file = tmp_path / "cloud/Inbox/context-test.cvdrop"
    input_file.write_text(json.dumps(package))
    item = c.call("GET", "/api/inbox")[1]["items"][0]
    assert item["label"] == payload["label"]
    res = c.call("POST", "/api/inbox/" + item["id"] + "/import", {})
    assert res[0] == 200 and res[1]["kind"] == "document"
    ident = res[1]["id"]
    assert c.call("GET", "/api/inbox")[1] == {"items": []} and input_file.exists()
    assert c.call("POST", "/api/phone-import", {"package": package})[1]["id"] == ident
    local_id = intake.stage_item(svc.directory, payload)
    assert c.call("POST", "/api/inbox/" + local_id + "/import", {})[1]["id"] == ident
    assert c.call("GET", "/api/catalog", owner=False)[1] == {"items": []}
    assert c.call("GET", "/api/phone-key", owner=False)[0] == 403
    svc.cloud.tick(svc.store, force=True)
    remote = next((tmp_path / "cloud/Devices").glob("*/latest.cvault"))
    restored = Store(tmp_path / "new-device")
    with pytest.raises(VaultError):
        restored.restore(remote, "wrong password")
    restored.restore(remote, PASSWORD)
    assert restored.get_item(ident)["value"] == payload["value"]
    assert intake.pairing(restored, tmp_path / "new-device")["pairing"] == public
    restored.lock()
    c.call("DELETE", "/api/items/" + ident, {"revision": 1})
    assert c.call("POST", "/api/phone-import", {"package": package})[0] == 410
    svc.deadline = 0
    assert c.call("GET", "/api/items")[0] == 423


def test_hub_receipt_integration(runtime, tmp_path, monkeypatch):
    from hub.server import HubHTTP
    from hub.store import Store as HubStore

    c, svc, _ = runtime
    hub_store = HubStore(tmp_path / "hub.db")
    with HubHTTP(
        ("127.0.0.1", 0), hub_store, "hub-owner", "hub-agent", "local"
    ) as http:
        th = threading.Thread(target=http.serve_forever, daemon=True)
        th.start()
        try:
            monkeypatch.setenv(
                "CONTEXT_VAULT_HUB_URL", f"http://127.0.0.1:{http.server_port}"
            )
            monkeypatch.setenv("CONTEXT_VAULT_HUB_AGENT_TOKEN", "hub-agent")
            c.call("POST", "/api/setup", {"password": PASSWORD})
            secret = "unique-private-content"
            _, item = c.call(
                "POST",
                "/api/items",
                {
                    "label": "private-name",
                    "kind": "key",
                    "value": secret,
                    "target": "https://example.com/private-path",
                },
            )
            _, req = c.call(
                "POST",
                "/api/requests",
                {"asset_id": item["id"], "purpose": "private-purpose"},
                owner=False,
            )
            path = "/api/requests/" + req["id"]
            c.call("POST", path + "/approve", {})
            c.call("POST", path + "/use", {}, owner=False)
            assert not hub_store.list_raw()
            status, receipt = c.call("POST", path + "/share", {})
            assert status == 200
            assert c.call("POST", path + "/share", {}) == (200, receipt)
            event = hub_store.get_raw(receipt["receipt_id"], agent=True)
            assert (
                event["source"] == "vault.receipt"
                and event["privacy"]["tier"] == "redacted"
            )
            assert all(
                text not in str(event)
                for text in (secret, "private-name", "private-path", "private-purpose")
            )
            hub_store.extract()
            assert len(hub_store.list_memory(agent=True)) == 1
        finally:
            http.shutdown()
            th.join()


def test_cloud_approval_matches_the_reviewed_ciphertext(runtime, tmp_path):
    client, service, _ = runtime
    client.call("POST", "/api/setup", {"password": PASSWORD})
    client.call("POST", "/api/cloud", {"enabled": True})
    public = client.call("GET", "/api/phone-key")[1]["pairing"]
    path = tmp_path / "cloud/Inbox/unchanged-name.cvdrop"

    def replace(label):
        parcel = intake.seal_item(
            public, {"kind": "profile", "label": label, "value": label}
        )
        path.write_text(json.dumps(parcel))

    replace("Synthetic A")
    offered = client.call("GET", "/api/inbox")[1]["items"][0]
    replace("Synthetic B")
    assert client.call("POST", "/api/inbox/" + offered["id"] + "/import", {})[0] in (
        404,
        409,
    )
    assert service.store.list_items() == []
    fresh = client.call("GET", "/api/inbox")[1]["items"][0]
    assert fresh["id"] != offered["id"] and fresh["label"] == "Synthetic B"
    assert client.call("POST", "/api/inbox/" + fresh["id"] + "/import", {})[0] == 200
