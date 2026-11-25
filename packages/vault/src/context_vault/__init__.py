"""Vault for Agent — Encrypted Entity, Identity Doc, Business License, Autofill & Secret Store."""

from .crypto import VaultAuthError
from .entities import (
    AddressEntry,
    BankAccountEntry,
    BusinessLicensePayload,
    CompanyEntityPayload,
    EmailEntry,
    IdentityDocPayload,
    PersonProfilePayload,
    PhoneEntry,
    extract_cn_id_metadata,
    mask_value,
    merge_autofill_bundle,
)
from .store import VaultStore, default_vault_dir, redact_secrets

__version__ = "0.4.0"
__all__ = [
    "AddressEntry",
    "BankAccountEntry",
    "BusinessLicensePayload",
    "CompanyEntityPayload",
    "EmailEntry",
    "IdentityDocPayload",
    "PersonProfilePayload",
    "PhoneEntry",
    "VaultAuthError",
    "VaultStore",
    "default_vault_dir",
    "extract_cn_id_metadata",
    "mask_value",
    "merge_autofill_bundle",
    "redact_secrets",
]
