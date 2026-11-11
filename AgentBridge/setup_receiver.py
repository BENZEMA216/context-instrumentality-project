#!/usr/bin/env python3
"""Prepare private pairing credentials and a pinned TLS certificate, without starting services."""

import argparse
import hashlib
import ipaddress
import os
from pathlib import Path
import re
import secrets
import shutil
import ssl
import subprocess
import tempfile
from urllib.parse import urlsplit
import uuid

from automatic import private_directory, private_file, sync_directory
from library import BridgeError, canonical_json, parse_json


def certificate_name(value):
    try:
        return "IP", str(ipaddress.ip_address(value))
    except ValueError:
        if not isinstance(value, str) or len(value) > 253 or not all(
                re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                for label in value.split(".")):
            raise BridgeError("invalid_arguments", "Use an IP address or a valid DNS hostname for the receiver.")
        return "DNS", value.lower()


def write_private(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(value)
        output.flush()
        os.fsync(output.fileno())


def prepare(state, endpoint, additional_hosts=()):
    value = urlsplit(endpoint)
    if (value.scheme != "https" or not value.hostname or value.username or value.password
            or value.path not in ("", "/") or value.query or value.fragment or not value.port):
        raise BridgeError("invalid_arguments", "Pairing requires an explicit HTTPS origin with a port.")
    names = list(dict.fromkeys([certificate_name(value.hostname)] +
                              [certificate_name(host) for host in additional_hosts]))
    origin = "https://" + value.netloc
    root = private_directory(state)
    pairing_path = root / "pairing.json"
    required = ["pairing.json", "receiver.json", "receiver-token", "receiver.crt", "receiver.key"]
    if any((root / name).exists() or (root / name).is_symlink() for name in required):
        if not all((root / name).exists() for name in required):
            raise BridgeError("incomplete_setup", "Existing pairing files are incomplete; they were not replaced.")
        for name in required:
            private_file(root / name)
        pairing = parse_json(pairing_path.read_bytes())
        receiver = parse_json((root / "receiver.json").read_bytes())
        token = (root / "receiver-token").read_text().strip()
        cert_der = ssl.PEM_cert_to_DER_cert((root / "receiver.crt").read_text())
        if (set(pairing) != {"schemaVersion", "endpoint", "receiverID", "token", "certificateSHA256"}
                or pairing.get("schemaVersion") != 1 or pairing.get("endpoint") != origin
                or not re.fullmatch(r"[A-Za-z0-9_-]{43}", token) or pairing.get("token") != token
                or pairing.get("certificateSHA256") != hashlib.sha256(cert_der).hexdigest()
                or receiver != {key: value for key, value in pairing.items() if key != "token"}):
            raise BridgeError("pairing_mismatch", "Existing pairing identity does not match; automatic replacement is disabled.")
        try:
            if str(uuid.UUID(pairing["receiverID"])) != pairing["receiverID"]:
                raise ValueError()
            # Loading checks both PEM files and that the private key belongs to
            # this certificate. A partially written key is never a valid setup.
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(str(root / "receiver.crt"), str(root / "receiver.key"))
            checked = subprocess.run(["/usr/bin/openssl", "verify", "-CAfile", str(root / "receiver.crt"),
                                      str(root / "receiver.crt")], stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, timeout=10, check=False)
            if checked.returncode != 0:
                raise ValueError()
        except (OSError, ValueError, TypeError, subprocess.SubprocessError) as error:
            raise BridgeError("incomplete_setup", "Existing TLS identity is invalid or incomplete; it was not replaced.") from error
        return {"receiverID": pairing["receiverID"], "endpoint": origin, "status": "existing",
                "pairingFile": str(pairing_path)}
    with tempfile.TemporaryDirectory(prefix=".pairing-", dir=str(root)) as temporary:
        staging = Path(temporary)
        counts = {}
        alternatives = []
        for kind, name in names:
            counts[kind] = counts.get(kind, 0) + 1
            alternatives.append("%s.%d = %s" % (kind, counts[kind], name))
        config = ("[req]\nprompt = no\ndistinguished_name = dn\nx509_extensions = extensions\n"
                  "[dn]\nCN = Record for Agent paired receiver\n"
                  "[extensions]\nsubjectAltName = @names\nbasicConstraints = critical,CA:true,pathlen:0\n"
                  "subjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid:always\n"
                  "keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage = serverAuth\n"
                  "[names]\n" + "\n".join(alternatives) + "\n")
        write_private(staging / "openssl.cnf", config.encode())
        result = subprocess.run(["/usr/bin/openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048",
                                 "-days", "365", "-sha256", "-config", str(staging / "openssl.cnf"),
                                 "-keyout", str(staging / "receiver.key"), "-out", str(staging / "receiver.crt")],
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=False, timeout=30)
        if result.returncode != 0:
            raise BridgeError("certificate_failed", "The paired TLS certificate could not be generated.")
        for name in ("receiver.key", "receiver.crt"):
            os.chmod(staging / name, 0o600)
            with (staging / name).open("rb") as handle:
                os.fsync(handle.fileno())
        token = secrets.token_urlsafe(32)
        identifier = str(uuid.uuid4())
        certificate = hashlib.sha256(ssl.PEM_cert_to_DER_cert((staging / "receiver.crt").read_text())).hexdigest()
        pairing = {"schemaVersion": 1, "endpoint": origin, "receiverID": identifier,
                   "token": token, "certificateSHA256": certificate}
        receiver = {"schemaVersion": 1, "endpoint": origin, "receiverID": identifier,
                    "certificateSHA256": certificate}
        write_private(staging / "receiver-token", (token + "\n").encode())
        write_private(staging / "pairing.json", (canonical_json(pairing) + "\n").encode())
        write_private(staging / "receiver.json", (canonical_json(receiver) + "\n").encode())
        for name in required:
            # All paths were absent; refuse overwrite if another setup raced us.
            with (staging / name).open("rb") as source:
                write_private(root / name, source.read())
        sync_directory(root)
    return {"receiverID": identifier, "endpoint": origin, "status": "prepared", "pairingFile": str(pairing_path)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--additional-host", action="append", default=[])
    args = parser.parse_args()
    try:
        # Never print the token, private key or complete pairing payload.
        print(canonical_json(prepare(args.state, args.endpoint, args.additional_host)))
        return 0
    except (BridgeError, OSError, ValueError, subprocess.SubprocessError) as error:
        code = error.code if isinstance(error, BridgeError) else type(error).__name__
        print(canonical_json({"error": code}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
