import base64
import json
import socket
import threading
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

import pytest

from context_vault import actions
from context_vault.actions import Broker, BrokerError, validate_target
from context_vault.mcp_bridge import AgentClient


class Store:
    def __init__(self):
        self.item = {
            "id": "asset_1",
            "kind": "key",
            "label": "Fixture alias",
            "value": "synthetic-key-xyz",
            "revision": 1,
            "target": "https://trusted.example/read",
        }

    def get_item(self, asset_id):
        if asset_id != self.item["id"]:
            raise KeyError()
        return dict(self.item)


def test_grants_bind_agent_revision_and_expiry():
    store = Store()
    now = [100]
    broker = Broker(store, clock=lambda: now[0], transport=lambda item: 200)
    make = lambda: broker.request("worker", "asset_1", "read availability")["id"]
    request = make()
    for action in [
        lambda: broker.get("other", request),
        lambda: broker.execute("other", request),
        lambda: broker.execute("worker", request),
    ]:
        with pytest.raises(BrokerError):
            action()
    assert not broker.list("other")
    store.item["revision"] += 1
    with pytest.raises(BrokerError):
        broker.decision(request, "approve")
    assert broker.get("worker", request)["state"] == "revoked"
    request = make()
    broker.decision(request, "approve")
    store.item["revision"] += 1
    with pytest.raises(BrokerError):
        broker.execute("worker", request)
    request = make()
    broker.decision(request, "approve")
    now[0] += actions.GRANT_SECONDS
    with pytest.raises(BrokerError):
        broker.execute("worker", request)
    assert broker.get("worker", request)["state"] == "expired"
    for action in ["deny", "revoke"]:
        request = make()
        broker.decision(request, action)
        with pytest.raises(BrokerError):
            broker.execute("worker", request)
    broker.clear()
    assert broker.list() == []
    store.item["kind"] = "payment"
    with pytest.raises(BrokerError):
        make()


def test_once_even_during_delivery_and_when_remote_fails():
    store = Store()
    sent, proceed, entered = [], threading.Event(), threading.Event()

    def transport(item):
        sent.append(item["value"])
        entered.set()
        assert proceed.wait(5)
        return 200

    broker = Broker(store, transport=transport)
    request = broker.request("worker", "asset_1", "one task")["id"]
    broker.decision(request, "approve")
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(broker.execute, "worker", request)
        assert entered.wait(5)
        with pytest.raises(BrokerError):
            broker.execute("worker", request)
        proceed.set()
        assert first.result()["state"] == "used"
    assert len(sent) == 1
    assert sent[0] not in json.dumps(broker.list())
    for returns in [302, 401]:
        other = Broker(store, transport=lambda item: returns)
        req = other.request("worker", "asset_1", "one task")["id"]
        other.decision(req, "approve")
        assert other.execute("worker", req)["state"] == "failed"
        with pytest.raises(BrokerError):
            other.execute("worker", req)


@pytest.mark.parametrize(
    "url",
    [
        "http://api.example/resource",
        "https://127.0.0.1/",
        "https://[::1]/",
        "https://[64:ff9b::8.8.8.8]/",
        "https://api.example/secret?q=secret",
        "https://user@api.example/",
        "https://api.example:5555/",
        "https://api.example/#key",
        "https://api.example/%0d%0a",
        "https://localhost/",
        "https://machine.local/",
        "https://api.example/\\evil",
    ],
)
def test_before_approval_target_validation(url):
    with pytest.raises(BrokerError):
        validate_target(url)


def test_dns_result_may_not_mix_public_and_lan():
    with patch.object(
        socket,
        "getaddrinfo",
        return_value=[
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("8.8.8.8", 443)),
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 443)),
        ],
    ):
        with pytest.raises(OSError):
            actions._resolve("web.example", 5)


def test_wire_injects_bearer_or_exact_file_only():
    target = validate_target("https://example.com/api/fixed")
    head, body = actions._wire_parts(Store().item, target)
    assert (
        b"GET /api/fixed HTTP/1.1" in head
        and b"Authorization: Bearer synthetic-key-xyz" in head
        and body == b""
    )
    head, body = actions._wire_parts(
        {
            "kind": "document",
            "mime": "image/png",
            "value": base64.b64encode(b"synthetic-file").decode(),
        },
        target,
    )
    assert (
        b"POST /api/fixed HTTP/1.1" in head
        and b"Content-Type: image/png" in head
        and body == b"synthetic-file"
    )
    head, body = actions._wire_parts(
        {"kind": "profile", "value": "synthetic address"}, target
    )
    assert b"Content-Type: text/plain" in head and body == b"synthetic address"


def test_mcp_response_field_allowlist_and_remote_origin(monkeypatch):
    for origin in (
        "http://remote.example",
        "https://name:password@example.com/",
        "https://example.com/path",
    ):
        with pytest.raises(ValueError):
            AgentClient(origin, "fixture")
    client = AgentClient("http://127.0.0.1:8743", "fixture")
    monkeypatch.setattr(
        client,
        "_send",
        lambda *args: {"items": [{"id": "1", "label": "alias", "value": "redact"}]},
    )
    assert client.list_assets() == {"items": [{"id": "1", "label": "alias"}]}
    with pytest.raises(ValueError):
        client.status("../other")
    monkeypatch.setattr(
        client, "_send", lambda *args: {"id": "1", "state": "used", "body": "redact"}
    )
    assert client.status("1", execute=True) == {"id": "1", "state": "used"}


@pytest.mark.parametrize(
    ("hostname", "reply", "expected"),
    [
        ("trusted.example", b"200 OK", "used"),
        ("trusted.example", b"302 Found", "failed"),
        ("different.example", b"200 OK", "failed"),
    ],
)
def test_tls_pinned_socket_hostname_and_remote_content_redaction(
    tmp_path, monkeypatch, hostname, reply, expected
):
    import ssl
    from datetime import datetime, timedelta, timezone
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "trusted.example")])
    now = datetime.now(timezone.utc)
    certificate = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=1))
        .not_valid_after(now + timedelta(minutes=5))
        .add_extension(
            x509.SubjectAlternativeName([x509.DNSName("trusted.example")]),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )
    pem = tmp_path / "fixture.pem"
    pem.write_bytes(
        certificate.public_bytes(serialization.Encoding.PEM)
        + key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    server_tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_tls.load_cert_chain(pem)
    client_tls = ssl.create_default_context(
        cadata=certificate.public_bytes(serialization.Encoding.PEM).decode()
    )
    monkeypatch.setattr(ssl, "create_default_context", lambda: client_tls)
    received = []
    with socket.socket() as listener:
        listener.settimeout(4)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        loopback = listener.getsockname()

        def serve_once():
            raw, _ = listener.accept()
            with raw:
                try:
                    with server_tls.wrap_socket(raw, server_side=True) as tls:
                        content = b""
                        while b"\r\n\r\n" not in content:
                            content += tls.recv(4096)
                        received.append(content)
                        tls.sendall(
                            b"HTTP/1.1 "
                            + reply
                            + b"\r\nLocation: https://another.example/\r\n\r\nSECRET ECHO"
                        )
                except ssl.SSLError:
                    assert hostname == "different.example"

        connections, resolutions = [], []

        def dns(host, port, type):
            resolutions.append(host)
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("8.8.8.8", 443))]

        original_connect = socket.socket.connect

        def local_connect(sock, address):
            assert address == ("8.8.8.8", 443)
            connections.append(address)
            return original_connect(sock, loopback)

        monkeypatch.setattr(socket, "getaddrinfo", dns)
        monkeypatch.setattr(socket.socket, "connect", local_connect)
        with ThreadPoolExecutor(max_workers=1) as pool:
            task = pool.submit(serve_once)
            store = Store()
            store.item["target"] = "https://" + hostname + "/fixed"
            broker = Broker(store)
            grant = broker.request("worker", "asset_1", "synthetic transport test")[
                "id"
            ]
            broker.decision(grant, "approve")
            result = broker.execute("worker", grant)
            task.result(timeout=5)
    assert len(connections) == 1 and resolutions == [hostname]
    if hostname == "trusted.example":
        assert (
            len(received) == 1
            and b"Authorization: Bearer synthetic-key-xyz" in received[0]
        )
        assert b"Host: trusted.example" in received[0]
    else:
        assert received == []
    assert result["state"] == expected and "SECRET ECHO" not in json.dumps(result)
    assert store.item["value"] not in json.dumps(result)


def test_stdio_sdk_through_authenticated_vault(tmp_path):
    import asyncio
    import sys
    from datetime import timedelta
    from pathlib import Path

    mcp = pytest.importorskip("mcp")
    from mcp.client.stdio import stdio_client
    from context_vault.service import Service, VaultHTTP

    directory = tmp_path / "vault"
    service = Service(directory, "unit-owner", "unit-agent", transport=lambda item: 204)
    service.dispatch(
        "POST", "/api/setup", "owner", "", {"password": "long synthetic passphrase"}
    )
    created = service.dispatch(
        "POST",
        "/api/items",
        "owner",
        service.session,
        {
            "kind": "key",
            "label": "Sample account",
            "value": "unit-hidden-content",
            "target": "https://trusted.example/fixed",
        },
    )
    token = directory / "agent.token"
    token.write_text("unit-agent")
    token.chmod(0o600)
    with VaultHTTP(("127.0.0.1", 0), service) as http:
        worker = threading.Thread(target=http.serve_forever, daemon=True)
        worker.start()

        async def interact():
            stdio = mcp.StdioServerParameters(
                command=sys.executable,
                args=["-m", "context_vault.mcp_bridge"],
                env={
                    "PYTHONPATH": str(Path(__file__).resolve().parents[1]),
                    "CONTEXT_VAULT_DATA": str(directory),
                    "CONTEXT_VAULT_URL": f"http://127.0.0.1:{http.server_port}",
                    "CONTEXT_VAULT_AGENT_TOKEN": "",
                },
            )
            async with stdio_client(stdio) as (read, write):
                async with mcp.ClientSession(
                    read, write, read_timeout_seconds=timedelta(seconds=15)
                ) as client:
                    await client.initialize()
                    assert {t.name for t in (await client.list_tools()).tools} == {
                        "list_vault_assets",
                        "request_vault_use",
                        "get_vault_request",
                        "use_approved_vault_item",
                    }
                    result = await client.call_tool("list_vault_assets", {})
                    assert not result.isError
                    aliases = json.loads(result.content[0].text)["items"]
                    assert aliases == [
                        {"id": created["id"], "kind": "key", "label": "Sample account"}
                    ]
                    grant = await client.call_tool(
                        "request_vault_use",
                        {"asset_id": created["id"], "purpose": "sample"},
                    )
                    record = json.loads(grant.content[0].text)
                    assert record[
                        "state"
                    ] == "pending" and "unit-hidden-content" not in str(record)
                    args = {"request_id": record["id"]}
                    waiting = await client.call_tool("get_vault_request", args)
                    assert json.loads(waiting.content[0].text)["state"] == "pending"
                    service.dispatch(
                        "POST",
                        "/api/requests/" + record["id"] + "/approve",
                        "owner",
                        service.session,
                        {},
                    )
                    delivered = await client.call_tool("use_approved_vault_item", args)
                    assert json.loads(delivered.content[0].text)["state"] == "used"
                    assert "unit-hidden-content" not in str(delivered)
                    repeated = await client.call_tool("use_approved_vault_item", args)
                    assert repeated.isError and "409" in repeated.content[0].text

        try:
            asyncio.run(interact())
        finally:
            http.shutdown()
            worker.join()
            service.lock()


def test_agent_bridge_rejects_linked_or_public_credential(tmp_path, monkeypatch):
    monkeypatch.setenv("CONTEXT_VAULT_DATA", str(tmp_path))
    monkeypatch.setenv("CONTEXT_VAULT_URL", "http://127.0.0.1:8743")
    monkeypatch.delenv("CONTEXT_VAULT_AGENT_TOKEN", raising=False)
    owner = tmp_path / "owner.token"
    owner.write_text("owner-fixture")
    agent = tmp_path / "agent.token"
    agent.symlink_to(owner)
    with pytest.raises(ValueError, match="private agent"):
        AgentClient.from_env()
    agent.unlink()
    agent.write_text("agent-fixture")
    agent.chmod(0o644)
    with pytest.raises(ValueError, match="private agent"):
        AgentClient.from_env()
