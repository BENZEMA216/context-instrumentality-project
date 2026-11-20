"""Owner-run, single-account Gmail OAuth pairing in the macOS Keychain."""

import hashlib
import json
import re
import sys
from pathlib import Path


SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
TOKEN_URI = "https://oauth2.googleapis.com/token"
AUTH_URI = "https://accounts.google.com/o/oauth2/auth"
SERVICE = "Context Vault Gmail OAuth"
EXTRA = "Install personal-context-vault[gmail] to use Gmail pairing."


def _account(directory):
    # A different vault directory can use a different Google account.
    return hashlib.sha256(
        str(Path(directory).expanduser().resolve()).encode()
    ).hexdigest()


def _keychain():
    if sys.platform != "darwin":
        raise ValueError(
            "Gmail pairing requires macOS Keychain. Use an owner-provided access token or .eml."
        )
    try:
        # Never select a fallback keyring backend via config, entry points, or env.
        from keyring.backends.macOS import Keyring
    except ImportError:
        raise ValueError(EXTRA) from None
    return Keyring()


def _read(ring, account):
    try:
        return ring.get_password(SERVICE, account)
    except Exception:
        raise ValueError("Could not access the macOS Keychain.") from None


def _save(ring, account, credential):
    granted = credential.granted_scopes or credential.scopes
    if isinstance(granted, str):
        granted = granted.split()
    if (
        set(granted or []) != {SCOPE}
        or not credential.refresh_token
        or not credential.token
    ):
        raise ValueError(
            "Google must grant exactly Gmail read-only access and offline refresh."
        )
    try:
        ring.set_password(
            SERVICE, account, credential.to_json(strip=["account", "rapt_token"])
        )
    except Exception:
        raise ValueError(
            "Could not save the Gmail authorization in macOS Keychain."
        ) from None


def _desktop_client(path):
    path = Path(path).expanduser()
    if path.suffix.lower() != ".json" or path.is_symlink() or not path.is_file():
        raise ValueError("Select a Google Desktop OAuth client JSON file.")
    with path.open("rb") as file:
        raw = file.read(65537)
    try:
        if len(raw) > 65536:
            raise ValueError
        config = json.loads(raw)["installed"]
        client_id = config["client_id"]
        if not re.fullmatch(r"[A-Za-z0-9-]+\.apps\.googleusercontent\.com", client_id):
            raise ValueError
        secret = config["client_secret"]
        if not re.fullmatch(r"[!-~]{1,512}", secret):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        raise ValueError(
            "Select a valid Google Desktop OAuth client JSON file."
        ) from None
    # Disregard all URI fields in the supplied file. Consent and token exchange
    # have exactly two Google-owned endpoints.
    return {
        "installed": {
            "client_id": client_id,
            "client_secret": secret,
            "auth_uri": AUTH_URI,
            "token_uri": TOKEN_URI,
        }
    }


def connect(directory, path):
    ring, account = _keychain(), _account(directory)
    if _read(ring, account):
        raise ValueError(
            "This vault already has a Gmail pairing. Disconnect it before pairing another account."
        )
    config = _desktop_client(path)
    try:
        from google_auth_oauthlib.flow import InstalledAppFlow
    except ImportError:
        raise ValueError(EXTRA) from None
    try:
        flow = InstalledAppFlow.from_client_config(
            config, [SCOPE], autogenerate_code_verifier=True
        )
        flow.oauth2session.trust_env = False
        credential = flow.run_local_server(
            host="127.0.0.1",
            port=0,
            open_browser=True,
            timeout_seconds=180,
            authorization_prompt_message=None,
            prompt="consent",
            access_type="offline",
            include_granted_scopes="false",
            success_message="Return to Context Vault to finish Gmail pairing. You may close this tab.",
        )
    except Exception:
        # SDK failures may quote tokens, callback addresses or client secrets.
        raise ValueError(
            "Gmail sign-in did not finish. Check the desktop client, consent and Gmail API settings."
        ) from None
    _save(ring, account, credential)


def access_token(directory):
    ring, account = _keychain(), _account(directory)
    saved = _read(ring, account)
    if not saved:
        raise ValueError(
            "Pair Gmail with gmail-connect --client FILE or supply an owner-authorized token locally."
        )
    try:
        from google.auth.transport.requests import Request
        from google.oauth2.credentials import Credentials
        from requests import Session
    except ImportError:
        raise ValueError(EXTRA) from None
    try:
        info = json.loads(saved)
        if info.get("scopes") != [SCOPE] or info.get("token_uri") != TOKEN_URI:
            raise ValueError
        credential = Credentials.from_authorized_user_info(info, scopes=[SCOPE])
        if not credential.valid:
            with Session() as session:
                session.trust_env = False
                credential.refresh(Request(session=session))
            _save(ring, account, credential)
        return credential.token
    except Exception:
        raise ValueError(
            "Gmail authorization is unavailable. Reconnect your Gmail account if access expired."
        ) from None


def disconnect(directory):
    ring, account = _keychain(), _account(directory)
    if _read(ring, account):
        try:
            ring.delete_password(SERVICE, account)
        except Exception:
            raise ValueError(
                "Could not remove Gmail authorization from macOS Keychain."
            ) from None
