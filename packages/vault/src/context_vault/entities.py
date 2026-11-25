"""Structured Identity, Partner, Company, Business License & Form-Fill Schemas for Vault for Agent.

Supports:
  - Multiple subjects (`self`, `partner:<slug>`, `company:<slug>`, `family:<slug>`).
  - Multi-valued contact fields (multiple phone numbers, emails, addresses, bank accounts per person/company).
  - Automatic field extraction from linked documents (e.g., 身份证 / 护照 / 营业执照 -> unified Form-Fill bundle).
  - Deterministic masking (`mask_value`) so Raw Memory & Agents only see structural pointers until authorized.
"""

from __future__ import annotations

import re
from typing import Any, Literal

from pydantic import BaseModel, Field

SubjectType = Literal["self", "partner", "company", "family", "other"]


class PhoneEntry(BaseModel):
    label: str = "主力"
    number: str
    country_code: str = "+86"
    primary: bool = False
    note: str = ""


class EmailEntry(BaseModel):
    label: str = "个人"
    address: str
    primary: bool = False
    note: str = ""


class AddressEntry(BaseModel):
    label: str = "现居"
    full_address: str
    country: str = "中国"
    province: str = ""
    city: str = ""
    postal_code: str = ""
    primary: bool = False


class BankAccountEntry(BaseModel):
    label: str = "主账户"
    bank_name: str = ""
    account_name: str = ""
    account_number: str = ""
    branch: str = ""
    swift_code: str = ""


class PersonProfilePayload(BaseModel):
    full_name: str = ""
    legal_name_en: str = ""
    nickname: str = ""
    role_relation: str = ""  # e.g. "本人" / "联合创始人" / "合伙人"
    birth_date: str = ""  # YYYY-MM-DD
    gender: str = ""
    nationality: str = ""
    phones: list[PhoneEntry] = Field(default_factory=list)
    emails: list[EmailEntry] = Field(default_factory=list)
    addresses: list[AddressEntry] = Field(default_factory=list)
    bank_accounts: list[BankAccountEntry] = Field(default_factory=list)
    custom_fields: dict[str, str] = Field(default_factory=dict)


class CompanyEntityPayload(BaseModel):
    company_name: str = ""
    company_name_en: str = ""
    unified_social_credit_code: str = ""  # 统一社会信用代码
    company_type: str = ""  # e.g. 有限责任公司
    legal_representative: str = ""  # 法定代表人
    registered_capital: str = ""
    established_date: str = ""
    registered_address: str = ""
    operating_address: str = ""
    business_scope: str = ""
    tax_id: str = ""
    phones: list[PhoneEntry] = Field(default_factory=list)
    emails: list[EmailEntry] = Field(default_factory=list)
    bank_accounts: list[BankAccountEntry] = Field(default_factory=list)
    custom_fields: dict[str, str] = Field(default_factory=dict)


class IdentityDocPayload(BaseModel):
    doc_type: Literal["cn_id_card", "passport", "hk_macau_pass", "driver_license", "other"] = "cn_id_card"
    holder_name: str = ""
    holder_name_en: str = ""
    doc_number: str = ""
    birth_date: str = ""
    gender: str = ""
    nationality: str = ""
    address: str = ""
    issue_date: str = ""
    expiry_date: str = ""
    issuing_authority: str = ""
    notes: str = ""


class BusinessLicensePayload(BaseModel):
    company_name: str = ""
    unified_social_credit_code: str = ""
    company_type: str = ""
    legal_representative: str = ""
    registered_capital: str = ""
    established_date: str = ""
    valid_until: str = ""
    registered_address: str = ""
    business_scope: str = ""
    registration_authority: str = ""
    notes: str = ""


_CN_ID_RE = re.compile(r"^[1-9]\d{5}((?:19|20)\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])\d{2}(\d)[0-9Xx]$")


def extract_cn_id_metadata(id_number: str) -> dict[str, str]:
    """Deterministically parse birth_date and gender from an 18-digit Chinese Resident ID number."""
    cleaned = id_number.strip().upper()
    m = _CN_ID_RE.match(cleaned)
    if not m:
        return {}
    year, month, day, seq_digit = m.groups()
    return {
        "birth_date": f"{year}-{month}-{day}",
        "gender": "男" if int(seq_digit) % 2 == 1 else "女",
    }


def mask_value(kind: str, value: str) -> str:
    """Return a privacy-preserving masked display string for Agents or preview UI."""
    s = (value or "").strip()
    if not s:
        return ""
    if kind == "name":
        if len(s) <= 1:
            return "*"
        return s[0] + "*" * (len(s) - 1) if len(s) <= 4 else f"{s[:2]}***{s[-1]}"
    if kind == "phone":
        digits = re.sub(r"\s+", "", s)
        if len(digits) <= 4:
            return "****"
        return f"{digits[:3]}****{digits[-4:]}"
    if kind == "email":
        if "@" in s:
            local, domain = s.split("@", 1)
            prefix = local[:2] if len(local) > 2 else local[:1]
            return f"{prefix}***@{domain}"
        return "***"
    if kind == "address":
        return f"{s[:6]}***" if len(s) > 8 else "***"
    # doc_number / credit_code / bank_account / generic secret
    if len(s) <= 6:
        return "***"
    return f"{s[:4]}{'*' * min(10, len(s) - 8)}{s[-4:]}"


def merge_autofill_bundle(
    subject_id: str,
    decrypted_records: list[dict[str, Any]],
    *,
    masked: bool = False,
) -> dict[str, Any]:
    """Aggregate base profile + extracted document fields for one subject into a unified Form-Fill sheet.

    Supports multi-valued phones, emails, addresses, bank accounts, and linked documents
    (`cn_id_card`, `passport`, `business_license`, etc.).
    """
    is_company = subject_id.startswith("company:") or any(
        r.get("kind") in {"company_entity", "business_license"} for r in decrypted_records
    )

    def _m(kind: str, val: str) -> str:
        return mask_value(kind, val) if masked else val

    base: dict[str, Any] = {
        "subject_id": subject_id,
        "entity_type": "company" if is_company else "person",
        "masked": masked,
        "basic_fields": {},
        "phones": [],
        "emails": [],
        "addresses": [],
        "bank_accounts": [],
        "documents": [],
        "custom_fields": {},
        "record_count": len(decrypted_records),
    }

    seen_phones: set[str] = set()
    seen_emails: set[str] = set()
    seen_addrs: set[str] = set()
    seen_banks: set[str] = set()

    def _set_basic(key: str, val: str, mask_kind: str = "generic", *, overwrite: bool = False) -> None:
        v = (val or "").strip()
        if not v:
            return
        if overwrite or key not in base["basic_fields"]:
            base["basic_fields"][key] = _m(mask_kind, v) if mask_kind != "plain" else v

    def _add_phone(item: dict[str, Any]) -> None:
        num = str(item.get("number") or "").strip()
        if not num or num in seen_phones:
            return
        seen_phones.add(num)
        base["phones"].append(
            {
                "label": str(item.get("label") or "电话"),
                "country_code": str(item.get("country_code") or "+86"),
                "number": _m("phone", num),
                "primary": bool(item.get("primary")),
                "note": str(item.get("note") or ""),
            }
        )

    def _add_email(item: dict[str, Any]) -> None:
        addr = str(item.get("address") or "").strip()
        if not addr or addr.casefold() in seen_emails:
            return
        seen_emails.add(addr.casefold())
        base["emails"].append(
            {
                "label": str(item.get("label") or "邮箱"),
                "address": _m("email", addr),
                "primary": bool(item.get("primary")),
                "note": str(item.get("note") or ""),
            }
        )

    def _add_addr(item: dict[str, Any]) -> None:
        full = str(item.get("full_address") or item.get("address") or "").strip()
        if not full or full in seen_addrs:
            return
        seen_addrs.add(full)
        base["addresses"].append(
            {
                "label": str(item.get("label") or "地址"),
                "full_address": _m("address", full),
                "country": str(item.get("country") or ""),
                "province": str(item.get("province") or ""),
                "city": str(item.get("city") or ""),
                "postal_code": str(item.get("postal_code") or ""),
                "primary": bool(item.get("primary")),
            }
        )

    def _add_bank(item: dict[str, Any]) -> None:
        acct = str(item.get("account_number") or item.get("account_no") or "").strip()
        if not acct or acct in seen_banks:
            return
        seen_banks.add(acct)
        base["bank_accounts"].append(
            {
                "label": str(item.get("label") or "账户"),
                "bank_name": str(item.get("bank_name") or ""),
                "account_name": _m("name", str(item.get("account_name") or "")),
                "account_number": _m("generic", acct),
                "branch": str(item.get("branch") or ""),
                "swift_code": str(item.get("swift_code") or ""),
            }
        )

    # Pass 1: Base entity profiles take priority for user-curated fields
    for rec in decrypted_records:
        kind = rec.get("kind")
        sec = rec.get("secret") or {}
        if kind == "person_profile":
            _set_basic("full_name", str(sec.get("full_name") or ""), "name", overwrite=True)
            _set_basic("legal_name_en", str(sec.get("legal_name_en") or ""), "name", overwrite=True)
            _set_basic("nickname", str(sec.get("nickname") or ""), "plain", overwrite=True)
            _set_basic("role_relation", str(sec.get("role_relation") or ""), "plain", overwrite=True)
            _set_basic("birth_date", str(sec.get("birth_date") or ""), "plain", overwrite=True)
            _set_basic("gender", str(sec.get("gender") or ""), "plain", overwrite=True)
            _set_basic("nationality", str(sec.get("nationality") or ""), "plain", overwrite=True)
            for p in sec.get("phones") or []:
                if isinstance(p, dict):
                    _add_phone(p)
            for e in sec.get("emails") or []:
                if isinstance(e, dict):
                    _add_email(e)
            for a in sec.get("addresses") or []:
                if isinstance(a, dict):
                    _add_addr(a)
            for b in sec.get("bank_accounts") or []:
                if isinstance(b, dict):
                    _add_bank(b)
            for ck, cv in (sec.get("custom_fields") or {}).items():
                base["custom_fields"][str(ck)] = _m("generic", str(cv))

        elif kind == "company_entity":
            _set_basic("company_name", str(sec.get("company_name") or ""), "plain", overwrite=True)
            _set_basic("company_name_en", str(sec.get("company_name_en") or ""), "plain", overwrite=True)
            _set_basic(
                "unified_social_credit_code",
                str(sec.get("unified_social_credit_code") or ""),
                "generic",
                overwrite=True,
            )
            _set_basic("company_type", str(sec.get("company_type") or ""), "plain", overwrite=True)
            _set_basic(
                "legal_representative",
                str(sec.get("legal_representative") or ""),
                "name",
                overwrite=True,
            )
            _set_basic("registered_capital", str(sec.get("registered_capital") or ""), "plain", overwrite=True)
            _set_basic("established_date", str(sec.get("established_date") or ""), "plain", overwrite=True)
            _set_basic("tax_id", str(sec.get("tax_id") or ""), "generic", overwrite=True)
            _set_basic("business_scope", str(sec.get("business_scope") or ""), "plain", overwrite=True)
            if sec.get("registered_address"):
                _add_addr({"label": "注册地址", "full_address": sec["registered_address"], "primary": True})
            if sec.get("operating_address"):
                _add_addr({"label": "办公地址", "full_address": sec["operating_address"]})
            for p in sec.get("phones") or []:
                if isinstance(p, dict):
                    _add_phone(p)
            for e in sec.get("emails") or []:
                if isinstance(e, dict):
                    _add_email(e)
            for b in sec.get("bank_accounts") or []:
                if isinstance(b, dict):
                    _add_bank(b)
            for ck, cv in (sec.get("custom_fields") or {}).items():
                base["custom_fields"][str(ck)] = _m("generic", str(cv))

    # Pass 2: Extract & backfill missing autofill fields from linked Identity Docs & Business Licenses!
    for rec in decrypted_records:
        kind = rec.get("kind")
        sec = rec.get("secret") or {}
        if kind == "identity_doc":
            doc_type = str(sec.get("doc_type") or "other")
            doc_num = str(sec.get("doc_number") or "")
            auto_cn = extract_cn_id_metadata(doc_num) if doc_type == "cn_id_card" else {}
            _set_basic("full_name", str(sec.get("holder_name") or ""), "name")
            _set_basic("legal_name_en", str(sec.get("holder_name_en") or ""), "name")
            _set_basic("birth_date", str(sec.get("birth_date") or auto_cn.get("birth_date") or ""), "plain")
            _set_basic("gender", str(sec.get("gender") or auto_cn.get("gender") or ""), "plain")
            _set_basic("nationality", str(sec.get("nationality") or ""), "plain")
            if sec.get("address"):
                _add_addr({"label": f"证件住址({doc_type})", "full_address": sec["address"]})
            base["documents"].append(
                {
                    "record_id": rec["id"],
                    "kind": kind,
                    "label": rec["label"],
                    "doc_type": doc_type,
                    "holder_name": _m("name", str(sec.get("holder_name") or "")),
                    "doc_number": _m("generic", doc_num),
                    "issue_date": str(sec.get("issue_date") or ""),
                    "expiry_date": str(sec.get("expiry_date") or ""),
                    "issuing_authority": str(sec.get("issuing_authority") or ""),
                    "attachments": rec.get("attachments") or [],
                }
            )
        elif kind == "business_license":
            _set_basic("company_name", str(sec.get("company_name") or ""), "plain")
            _set_basic(
                "unified_social_credit_code",
                str(sec.get("unified_social_credit_code") or ""),
                "generic",
            )
            _set_basic("company_type", str(sec.get("company_type") or ""), "plain")
            _set_basic("legal_representative", str(sec.get("legal_representative") or ""), "name")
            _set_basic("registered_capital", str(sec.get("registered_capital") or ""), "plain")
            _set_basic("established_date", str(sec.get("established_date") or ""), "plain")
            _set_basic("business_scope", str(sec.get("business_scope") or ""), "plain")
            if sec.get("registered_address"):
                _add_addr({"label": "营业执照注册地址", "full_address": sec["registered_address"], "primary": True})
            base["documents"].append(
                {
                    "record_id": rec["id"],
                    "kind": kind,
                    "label": rec["label"],
                    "doc_type": "business_license",
                    "company_name": str(sec.get("company_name") or ""),
                    "doc_number": _m("generic", str(sec.get("unified_social_credit_code") or "")),
                    "issue_date": str(sec.get("established_date") or ""),
                    "expiry_date": str(sec.get("valid_until") or ""),
                    "issuing_authority": str(sec.get("registration_authority") or ""),
                    "attachments": rec.get("attachments") or [],
                }
            )

    return base
