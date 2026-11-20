"""Opt-in publication of a non-identifying execution receipt to Context Hub."""

import json
import os
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, ProxyHandler, HTTPRedirectHandler, build_opener
from urllib.parse import urlsplit

from .storage import VaultError


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def share_receipt(record):
    state = record["state"]
    if state not in ("used", "failed"):
        raise VaultError("Only completed operations have a delivery receipt", 409)
    root = os.getenv("CONTEXT_VAULT_HUB_URL", "http://127.0.0.1:8741").rstrip("/")
    url = urlsplit(root)
    token = os.getenv("CONTEXT_VAULT_HUB_AGENT_TOKEN")
    local = url.hostname in ("localhost", "127.0.0.1", "::1")
    if (
        url.username
        or url.password
        or url.query
        or url.fragment
        or url.path
        or not url.hostname
        or url.scheme not in (("http", "https") if local else ("https",))
    ):
        raise VaultError("Invalid Hub origin")
    if not token and local:
        path = (
            Path.home() / "Library/Application Support/Context Hub"
            if sys.platform == "darwin"
            else Path(os.getenv("XDG_DATA_HOME", Path.home() / ".local/share"))
            / "context-hub"
        ) / "agent.token"
        try:
            token = path.read_text(encoding="ascii").strip()
        except OSError:
            pass
    if not token:
        raise VaultError("Configure a Context Hub agent credential", 503)
    ident = "vault-" + record["id"]
    ms = record["created_at"] * 1000
    event = {
        "id": ident,
        "source": "vault.receipt",
        "kind": "action_receipt",
        "t_start": ms,
        "t_end": ms,
        "t_observed": ms,
        "privacy": {"tier": "redacted"},
        "provenance": {"connector": "context-vault", "source_id": ident},
        "content": {
            "title": "私密资料操作回执",
            "text": record["operation"] + " / " + state,
        },
    }
    request = Request(
        root + "/api/raw",
        data=json.dumps(event).encode(),
        method="POST",
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
        },
    )
    try:
        with build_opener(ProxyHandler({}), NoRedirect()).open(
            request, timeout=5
        ) as response:
            if response.status not in (200, 201):
                raise VaultError("Hub did not accept the receipt", 502)
    except (HTTPError, URLError, OSError):
        raise VaultError("Could not publish receipt to Context Hub", 502) from None
    return {"receipt_id": ident, "shared": True}
