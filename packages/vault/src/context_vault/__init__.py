"""Vault for Agent — Per-record AES-256-GCM encrypted personal asset & zero-exposure CLI package."""

from .crypto import VaultAuthError
from .store import VaultStore, default_vault_dir, redact_secrets

__version__ = "0.3.0"
__all__ = ["VaultAuthError", "VaultStore", "default_vault_dir", "redact_secrets"]
