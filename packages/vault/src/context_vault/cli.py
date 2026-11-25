"""CLI for Vault for Agent (`raw-vault` / `context-vault`)."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import sys
from pathlib import Path

from context_hub.mcp_server import default_data_dir
from context_hub.store import HubStore

from .crypto import VaultAuthError
from .store import VaultStore, default_vault_dir


def _resolve_passphrase(args: argparse.Namespace) -> str:
    if getattr(args, "passphrase_env", None):
        val = os.environ.get(args.passphrase_env, "")
        if val:
            return val
    if env := os.environ.get("RAW_VAULT_PASSPHRASE"):
        return env
    return getpass.getpass("Vault passphrase: ")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="raw-vault",
        description="Vault for Agent — Per-record AES-256-GCM personal secret store & zero-exposure CLI injector",
    )
    parser.add_argument("--vault-dir", type=Path, default=None)
    parser.add_argument("--data-dir", type=Path, default=None)
    parser.add_argument(
        "--passphrase-env",
        type=str,
        default=None,
        help="Read vault passphrase from this environment variable (or RAW_VAULT_PASSPHRASE)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("init", help="Initialize a new AES-256-GCM encrypted vault")

    set_p = sub.add_parser("set", help="Store or update an encrypted secret/entity/document record")
    set_p.add_argument(
        "--kind",
        default="api_key",
        choices=(
            "person_profile",
            "company_entity",
            "identity_doc",
            "business_license",
            "api_key",
            "credential",
            "address",
            "payment_card",
            "note",
        ),
    )
    set_p.add_argument("--subject", default="self", help="Entity subject ID (e.g. self, partner:zheng, company:rawmemory)")
    set_p.add_argument("--label", required=True)
    set_p.add_argument("--id", dest="record_id", default=None)
    set_p.add_argument("--project", default=None)
    set_p.add_argument("--value-env", default=None, help="Read simple secret value from an env var")
    set_p.add_argument("--json-file", type=Path, default=None, help="Read structured JSON payload (person_profile/company_entity/identity_doc/business_license)")
    set_p.add_argument("--allow-cmd", action="append", default=[], help="Allowlist executable name for `run`")
    set_p.add_argument("--tag", action="append", default=[])

    att_p = sub.add_parser("attach", help="Encrypt and attach a scan/PDF/photo (e.g. 营业执照/身份证) to a vault record")
    att_p.add_argument("record_id")
    att_p.add_argument("file", type=Path)
    att_p.add_argument("--mime", default="application/octet-stream")

    sub.add_parser("subjects", help="List subjects (self / partner:* / company:*) with document counts (no plaintext)")

    af_p = sub.add_parser("autofill", help="Build unified Form-Fill bundle (profile + extracted ID/license fields)")
    af_p.add_argument("--subject", default="self")
    af_p.add_argument("--masked", action="store_true", help="Mask PII values for safe preview")

    list_p = sub.add_parser("list", help="List non-secret metadata of vault records")
    list_p.add_argument("--subject", default=None)
    list_p.add_argument("--project", default=None)
    list_p.add_argument("--kind", default=None)

    get_p = sub.add_parser("get", help="Decrypt and print a secret record")
    get_p.add_argument("record_id")

    del_p = sub.add_parser("delete", help="Delete a secret record and wipe its ciphertext")
    del_p.add_argument("record_id")

    run_p = sub.add_parser(
        "run",
        help="Run a command with decrypted vault secrets injected into env and redacted from stdout/stderr",
    )
    run_p.add_argument(
        "--secret",
        action="append",
        required=True,
        help="Binding in the form ENV_VAR=vault_record_id (or ENV_VAR=vault_record_id:field)",
    )
    run_p.add_argument("cmd", nargs=argparse.REMAINDER, help="Command after `--`")

    sub.add_parser("sync-receipts", help="Sync non-secret masked pointer receipts into Raw Memory Hub")
    sub.add_parser("audit", help="Show recent vault access audit log")

    args = parser.parse_args(argv)
    vdir = args.vault_dir or default_vault_dir(args.data_dir)
    vault = VaultStore(vdir)

    try:
        if args.command == "init":
            pw = _resolve_passphrase(args)
            print(json.dumps(vault.init_vault(pw), ensure_ascii=False, indent=2))
            return 0

        if args.command == "list":
            print(
                json.dumps(
                    {
                        "records": vault.list_records(
                            subject_id=args.subject, project=args.project, kind=args.kind
                        )
                    },
                    ensure_ascii=False,
                    indent=2,
                )
            )
            return 0

        if args.command == "subjects":
            print(json.dumps({"subjects": vault.list_subjects()}, ensure_ascii=False, indent=2))
            return 0

        if args.command == "autofill":
            pw = _resolve_passphrase(args)
            bundle = vault.build_autofill_bundle(pw, args.subject, masked=args.masked)
            print(json.dumps(bundle, ensure_ascii=False, indent=2))
            return 0

        if args.command == "attach":
            pw = _resolve_passphrase(args)
            raw_bytes = args.file.expanduser().read_bytes()
            att = vault.add_attachment(
                pw,
                record_id=args.record_id,
                filename=args.file.name,
                data=raw_bytes,
                mime_type=args.mime,
            )
            print(json.dumps(att, ensure_ascii=False, indent=2))
            return 0

        if args.command == "audit":
            print(json.dumps({"audit": vault.list_audit_log()}, ensure_ascii=False, indent=2))
            return 0

        if args.command == "delete":
            print(json.dumps(vault.delete_record(args.record_id), ensure_ascii=False, indent=2))
            return 0

        if args.command == "sync-receipts":
            hub = HubStore(args.data_dir or default_data_dir())
            res = vault.sync_masked_receipts_to_hub(hub)
            print(json.dumps(res, ensure_ascii=False, indent=2))
            return 0

        if args.command == "set":
            pw = _resolve_passphrase(args)
            if args.json_file:
                payload = json.loads(args.json_file.expanduser().read_text(encoding="utf-8"))
                if not isinstance(payload, dict):
                    raise ValueError("--json-file must contain a JSON object")
            elif args.value_env:
                payload = {"value": os.environ.get(args.value_env, "")}
            else:
                payload = {"value": getpass.getpass("Secret value: ")}
            meta = vault.put_record(
                pw,
                kind=args.kind,
                subject_id=args.subject,
                label=args.label,
                secret_payload=payload,
                record_id=args.record_id,
                project=args.project,
                tags=args.tag,
                allowed_commands=args.allow_cmd,
            )
            print(json.dumps(meta, ensure_ascii=False, indent=2))
            return 0

        if args.command == "get":
            pw = _resolve_passphrase(args)
            rec = vault.get_record(pw, args.record_id)
            print(json.dumps(rec, ensure_ascii=False, indent=2))
            return 0

        if args.command == "run":
            pw = _resolve_passphrase(args)
            cmd = list(args.cmd)
            if cmd and cmd[0] == "--":
                cmd = cmd[1:]
            bindings: dict[str, str] = {}
            for item in args.secret:
                if "=" not in item:
                    raise ValueError(f"Invalid --secret binding '{item}', expected ENV=record_id")
                k, v = item.split("=", 1)
                bindings[k.strip()] = v.strip()
            res = vault.run_with_injected_secrets(pw, env_bindings=bindings, command=cmd)
            if res["stdout"]:
                sys.stdout.write(res["stdout"])
            if res["stderr"]:
                sys.stderr.write(res["stderr"])
            return int(res["returncode"])
    except (VaultAuthError, KeyError, PermissionError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
