import base64
import json
from email.message import EmailMessage

import pytest

from context_vault import discover, intake
from context_vault.storage import Store


def test_scoped_documents_env_and_locked_inbox(tmp_path, capsys):
    chosen = tmp_path / "chosen"
    chosen.mkdir()
    marker = b"private-fixture-contents"
    (chosen / "permit.pdf").write_bytes(b"%PDF-1.7 " + marker)
    (chosen / ".env.local").write_text(
        "export EXAMPLE_API_TOKEN=secret-not-for-output\nCOLOR=other\n"
    )
    (tmp_path / "outside.pdf").write_bytes(b"%PDF-outside")
    (chosen / "escape.pdf").symlink_to(tmp_path / "outside.pdf")
    hidden = chosen / ".ssh"
    hidden.mkdir()
    (hidden / "secret.png").write_bytes(b"DO NOT OPEN")
    data = tmp_path / "local-vault"
    store = Store(data)
    store.create("fixture long passphrase")
    intake.pairing(store, data)
    store.lock()
    cmd = ["--data-dir", str(data), "files", "--root", str(chosen), "--include-env"]
    assert discover.main(cmd) == 0
    out = capsys.readouterr().out
    rows = {r["label"]: r for r in map(json.loads, out.splitlines())}
    assert set(rows) == {"permit.pdf", "EXAMPLE_API_TOKEN"}
    assert not rows["EXAMPLE_API_TOKEN"]["can_stage"]
    assert not (
        marker.decode() in out or "secret-not-for-output" in out or str(tmp_path) in out
    )
    assert discover.main(cmd + ["--stage", rows["permit.pdf"]["ref"]]) == 0
    ref = json.loads(capsys.readouterr().out)["staged"]
    encrypted = (data / "inbox" / (ref + ".cvdrop")).read_bytes()
    assert marker not in encrypted and b"permit.pdf" not in encrypted
    store.unlock("fixture long passphrase")
    document = intake.open_drop(store, json.loads(encrypted))
    assert base64.b64decode(document["value"]) == b"%PDF-1.7 " + marker
    (chosen / "permit.pdf").write_bytes(b"%PDF-2.0 changed")
    with pytest.raises(SystemExit):
        discover.main(cmd + ["--stage", rows["permit.pdf"]["ref"]])


def test_eml_only_supported_named_attachments_and_ssh_only_aliases(tmp_path):
    msg = EmailMessage()
    msg["Subject"] = "secret unrelated subject"
    msg.set_content("private mail body")
    msg.add_attachment(
        b"\x89PNG\r\n\x1a\nsynthetic",
        maintype="image",
        subtype="png",
        filename="identity.png",
    )
    msg.add_attachment(
        b"other", maintype="application", subtype="octet-stream", filename="binary.key"
    )
    path = tmp_path / "selected.eml"
    path.write_bytes(msg.as_bytes())
    candidates = list(discover.mail_candidates(path))
    assert [c.label for c in candidates] == ["identity.png"]
    assert "mail body" not in str(candidates[0].metadata())
    assert base64.b64decode(candidates[0].read()["value"]).endswith(b"synthetic")
    private = tmp_path / "private"
    private.write_text("SYNTHETIC MUST NOT APPEAR")
    config = tmp_path / "config"
    config.write_text(
        "Host=work-demo second-demo\n  HostName hidden.example\n  IdentityFile private\n"
        "Include private\nHost * !except\n"
    )
    ssh = list(discover.ssh_candidates(config))
    assert {c.label for c in ssh} == {"work-demo", "second-demo"}
    assert all(c.read()["value"] == c.label for c in ssh)
    assert "hidden.example" not in str([c.metadata() for c in ssh])


class GoogleFixture:
    def __init__(self):
        self.calls = []
        self.content = b"%PDF-SYNTHETIC"

    def get(self, suffix, params, limit=None):
        self.calls.append((suffix, params))
        if suffix == "":
            return {"messages": [{"id": "m123"}]}
        if suffix == "/m123":
            return {
                "id": "m123",
                "payload": {
                    "parts": [
                        {
                            "partId": "0",
                            "filename": "permit.pdf",
                            "mimeType": "application/pdf",
                            "body": {"attachmentId": "a123", "size": len(self.content)},
                        },
                        {
                            "partId": "1",
                            "filename": "inline.pdf",
                            "mimeType": "application/pdf",
                            "body": {"size": 12},
                        },
                    ]
                },
            }
        if suffix == "/m123/attachments/a123":
            return {
                "data": base64.urlsafe_b64encode(self.content).decode(),
                "size": len(self.content),
            }
        pytest.fail("Unexpected Gmail endpoint")


def test_gmail_listing_excludes_bodies_selected_attachment_only():
    gmail = GoogleFixture()
    candidates = list(
        discover.gmail_candidates(gmail, "newer_than:30d filename:pdf", 2)
    )
    assert len(candidates) == 2
    assert candidates[1].read is None
    assert len(gmail.calls) == 2
    assert "has:attachment" in gmail.calls[0][1]["q"]
    assert not any(
        s in gmail.calls[1][1]["fields"] for s in ("data", "headers", "snippet")
    )
    assert not any(
        s in str(candidates[0].metadata()) for s in ("m123", "a123", "SYNTHETIC")
    )
    assert base64.b64decode(candidates[0].read()["value"]) == gmail.content
    assert gmail.calls[-1][0] == "/m123/attachments/a123"


def test_reject_substituted_or_disguised_document(tmp_path):
    source = tmp_path / "sample.pdf"
    source.write_bytes(b"not pdf")
    item = next(discover.file_candidates([tmp_path]))
    with pytest.raises(ValueError, match="format"):
        item.read()
    source.unlink()
    source.symlink_to(tmp_path / "outside")
    with pytest.raises(OSError):
        item.read()


def test_gmail_keychain_pair_refresh_discover_and_forget(tmp_path, monkeypatch, capsys):
    flow_module = pytest.importorskip("google_auth_oauthlib.flow")
    from google.oauth2.credentials import Credentials
    from datetime import datetime, timedelta, timezone
    from urllib.parse import urlsplit, parse_qs
    from context_vault import gmail_auth as auth

    class FakeKeychain:
        values = {}

        def get_password(self, service, account):
            return self.values.get((service, account))

        def set_password(self, service, account, value):
            self.values[service, account] = value

        def delete_password(self, service, account):
            del self.values[service, account]

    ring = FakeKeychain()
    monkeypatch.setattr(auth, "_keychain", lambda: ring)
    monkeypatch.delenv("CONTEXT_VAULT_GMAIL_TOKEN", raising=False)
    client = tmp_path / "client.json"
    client_id = "123-fixture.apps.googleusercontent.com"
    client_secret = "synthetic-desktop-secret"
    client.write_text(
        json.dumps(
            {
                "installed": {
                    "client_id": client_id,
                    "client_secret": client_secret,
                    "auth_uri": "https://untrusted.example",
                    "token_uri": "https://untrusted.example",
                }
            }
        )
    )

    def simulate_consent(flow, **kwargs):
        assert kwargs["host"] == "127.0.0.1" and kwargs["port"] == 0
        assert kwargs["open_browser"] and kwargs["authorization_prompt_message"] is None
        assert (
            kwargs["access_type"] == "offline"
            and kwargs["include_granted_scopes"] == "false"
        )
        assert flow.oauth2session.trust_env is False
        assert flow.client_config["token_uri"] == auth.TOKEN_URI
        url, state = flow.authorization_url()
        assert state and url.startswith(auth.AUTH_URI + "?")
        params = parse_qs(urlsplit(url).query)
        assert params["scope"] == [auth.SCOPE] and params["code_challenge_method"] == [
            "S256"
        ]
        assert params["code_challenge"] and flow.code_verifier
        c = Credentials(
            "synthetic-first-token",
            refresh_token="synthetic-refresh",
            scopes=[auth.SCOPE],
            token_uri=auth.TOKEN_URI,
            client_id=client_id,
            client_secret=client_secret,
        )
        c.expiry = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(
            seconds=30
        )
        return c

    monkeypatch.setattr(
        flow_module.InstalledAppFlow, "run_local_server", simulate_consent
    )
    prefix = ["--data-dir", str(tmp_path / "vault")]
    assert discover.main(prefix + ["gmail-connect", "--client", str(client)]) == 0
    assert not (tmp_path / "vault").exists()
    assert len(ring.values) == 1
    refreshed = []

    def refresh(credential, request):
        assert (
            credential.refresh_token == "synthetic-refresh"
            and request.session.trust_env is False
        )
        refreshed.append(True)
        credential.token = "synthetic-refreshed-token"
        credential.expiry = datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(
            hours=1
        )

    monkeypatch.setattr(Credentials, "refresh", refresh)
    google = GoogleFixture()

    def fake_get(client, suffix, params, limit=None):
        assert client._token == "synthetic-refreshed-token"
        return google.get(suffix, params, limit)

    monkeypatch.setattr(discover.Gmail, "get", fake_get)
    for _ in range(2):
        assert (
            discover.main(prefix + ["gmail", "--query", "filename:pdf", "--limit", "1"])
            == 0
        )
    assert len(refreshed) == 1
    assert discover.main(prefix + ["gmail-disconnect"]) == 0
    assert not ring.values
    out = capsys.readouterr().out
    assert '"source": "gmail"' in out and '"gmail": "disconnected locally"' in out
    assert "synthetic-" not in out and client_id not in out
