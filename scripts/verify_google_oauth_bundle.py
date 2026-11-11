#!/usr/bin/env python3
"""Admit a compiled Phone bundle's Google OAuth configuration, locally only.

This is a static artifact gate, not Google authorization or an installation
test. CLI output contains fixed result/error codes and Info.plist hashes only;
configuration values, callback URLs and filesystem paths are never printed.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import sys


MAX_INFO_BYTES = 1_048_576
MAX_PLIST_OBJECTS = 16_384
MAX_PLIST_DEPTH = 64
CLIENT_KEY = "WRGoogleDriveOAuthClientID"
REGISTERED_KEY = "WRGoogleDriveOAuthRegisteredBundleID"
REVERSED_KEY = "WRGoogleDriveReversedClientID"
UNCONFIGURED_SCHEME = "wr-google-drive-unconfigured"
CLIENT_SUFFIX = ".apps.googleusercontent.com"
CONFIG_KEYS = (
    "CFBundleIdentifier", CLIENT_KEY, REGISTERED_KEY, REVERSED_KEY,
    "CFBundleURLTypes",
)
BUNDLE_ID = re.compile(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\Z")
CLIENT_PREFIX = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*\Z")
URL_SCHEME = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*\Z")


class ConfigurationError(ValueError):
    """Only a fixed, non-sensitive code may reach an error message."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(condition, code):
    if not condition:
        raise ConfigurationError(code)


class UniqueDictionary(dict):
    def __setitem__(self, key, value):
        require(key not in self, "duplicate_plist_key")
        super().__setitem__(key, value)


def _text(value, *, empty=False):
    return (
        isinstance(value, str)
        and (empty or bool(value))
        and len(value) <= 512
        and not any(character.isspace() or ord(character) < 32 or ord(character) == 127
                    for character in value)
        and "$(" not in value and "${" not in value
    )


def _template(value):
    lowered = value.lower()
    return any(marker in lowered for marker in (
        "unconfigured", "replace_with", "placeholder", "change_me", "your_client",
    ))


def _schemes(info):
    entries = info.get("CFBundleURLTypes")
    require(isinstance(entries, list) and 0 < len(entries) <= 64, "invalid_url_types")
    schemes = []
    for entry in entries:
        require(isinstance(entry, dict), "invalid_url_types")
        values = entry.get("CFBundleURLSchemes")
        require(isinstance(values, list) and 0 < len(values) <= 64, "invalid_url_schemes")
        for value in values:
            require(_text(value) and URL_SCHEME.fullmatch(value) is not None,
                    "invalid_url_scheme")
            schemes.append(value)
    return schemes


def validate_info(info, *, allow_unconfigured_development=False):
    """Validate already decoded Info.plist without exposing or changing values.

    The explicit development exception accepts only the complete checked-in
    empty configuration, never a partly configured or malformed application.
    A successful exception is explicitly *not* deployment admission.
    """
    require(isinstance(info, dict), "invalid_info_object")
    bundle = info.get("CFBundleIdentifier")
    require(_text(bundle) and BUNDLE_ID.fullmatch(bundle) is not None
            and not _template(bundle), "invalid_bundle_identifier")
    client, registered, reversed_client = (info.get(key) for key in (
        CLIENT_KEY, REGISTERED_KEY, REVERSED_KEY,
    ))
    require(all(_text(value, empty=True) for value in (client, registered, reversed_client)),
            "invalid_oauth_fields")
    schemes = _schemes(info)
    entirely_unconfigured = (
        client == "" and registered == "" and reversed_client == UNCONFIGURED_SCHEME
        and schemes == [UNCONFIGURED_SCHEME]
    )
    if entirely_unconfigured:
        require(allow_unconfigured_development, "oauth_unconfigured")
        return {"configured": False, "deploymentAllowed": False}

    require(client != "" and registered != "" and reversed_client != "",
            "oauth_configuration_incomplete")
    require(not any(_template(value) for value in (client, registered, reversed_client))
            and not any(_template(value) for value in schemes), "oauth_template_value")
    require(client.endswith(CLIENT_SUFFIX), "invalid_client_id")
    prefix = client[:-len(CLIENT_SUFFIX)]
    require(CLIENT_PREFIX.fullmatch(prefix) is not None, "invalid_client_id")
    require(registered == bundle, "registered_bundle_mismatch")
    require(reversed_client == "com.googleusercontent.apps." + prefix,
            "reversed_client_mismatch")
    require(reversed_client in schemes and
            sum(value.casefold() == reversed_client.casefold() for value in schemes) == 1,
            "callback_scheme_not_registered_once")
    return {"configured": True, "deploymentAllowed": True}


def _check_tree(value):
    count = 0
    ancestors = set()

    def visit(item, depth):
        nonlocal count
        count += 1
        require(count <= MAX_PLIST_OBJECTS and depth <= MAX_PLIST_DEPTH,
                "info_structure_limit")
        if not isinstance(item, (dict, list)):
            return
        require(id(item) not in ancestors, "cyclic_plist")
        ancestors.add(id(item))
        try:
            for child in (item.values() if isinstance(item, dict) else item):
                visit(child, depth + 1)
        finally:
            ancestors.remove(id(item))

    visit(value, 0)


def _check_binary_trailer(data):
    if not data.startswith(b"bplist00"):
        return
    require(len(data) >= 40, "invalid_info_plist")
    offset_size, reference_size, count, top, table = struct.unpack(
        ">6xBBQQQ", data[-32:])
    require(1 <= offset_size <= 8 and 1 <= reference_size <= 8
            and 0 < count <= MAX_PLIST_OBJECTS and top < count
            and 8 <= table <= len(data) - 32
            and count * offset_size <= len(data) - 32 - table,
            "invalid_binary_plist_bounds")


def _exact_values(left, right):
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(
            _exact_values(left[key], right[key]) for key in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(
            _exact_values(a, b) for a, b in zip(left, right))
    return left == right


def read_info(app):
    """Read one fixed compiled Info.plist leaf, with a finite byte bound."""
    app = Path(app)
    require(app.suffix == ".app" and app.is_dir(), "invalid_app_directory")
    try:
        fd = os.open(app / "Info.plist", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            details = os.fstat(stream.fileno())
            require(stat.S_ISREG(details.st_mode), "invalid_info_file")
            require(0 < details.st_size <= MAX_INFO_BYTES, "info_size_limit")
            data = stream.read(MAX_INFO_BYTES + 1)
        require(0 < len(data) <= MAX_INFO_BYTES, "info_size_limit")
    except OSError:
        raise ConfigurationError("app_info_unreadable") from None
    _check_binary_trailer(data)
    try:
        info = plistlib.loads(data, dict_type=UniqueDictionary)
    except ConfigurationError:
        raise
    except Exception:
        raise ConfigurationError("invalid_info_plist") from None
    require(isinstance(info, dict), "invalid_info_object")
    _check_tree(info)
    return info, hashlib.sha256(data).hexdigest()


def verify_app(app, *, baseline_app=None, allow_unconfigured_development=False):
    require(not (baseline_app is not None and allow_unconfigured_development),
            "baseline_and_unconfigured_exception_conflict")
    if baseline_app is not None:
        try:
            require(Path(app).resolve() != Path(baseline_app).resolve(), "baseline_is_target")
        except (OSError, RuntimeError):
            raise ConfigurationError("invalid_app_directory") from None
    info, digest = read_info(app)
    admission = validate_info(info, allow_unconfigured_development=allow_unconfigured_development)
    baseline_digest = None
    if baseline_app is not None:
        baseline, baseline_digest = read_info(baseline_app)
        try:
            validate_info(baseline)
        except ConfigurationError:
            raise ConfigurationError("baseline_oauth_invalid") from None
        require(all(_exact_values(info.get(key), baseline.get(key)) for key in CONFIG_KEYS),
                "baseline_configuration_mismatch")
    return {
        "schemaVersion": 1,
        "status": "google_oauth_bundle_admitted" if admission["deploymentAllowed"]
                  else "unconfigured_development_only",
        **admission,
        "baselineCompared": baseline_app is not None,
        "baselineMatched": True if baseline_app is not None else None,
        "infoPlistSHA256": digest,
        "baselineInfoPlistSHA256": baseline_digest,
        "configurationValuesPrinted": False,
        "deviceAccess": False,
        "networkAccess": False,
    }


class PrivateArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        # argparse's default errors can repeat argument values and private paths.
        raise ConfigurationError("invalid_arguments")


def main(argv=None):
    try:
        parser = PrivateArgumentParser(description=__doc__)
        parser.add_argument("--app", required=True, help="Compiled Phone .app directory")
        parser.add_argument("--baseline-app", help="Previously admitted Phone .app directory")
        parser.add_argument("--allow-unconfigured-development", action="store_true",
                            help="Explicitly allow the wholly unconfigured open-source development build")
        arguments = parser.parse_args(argv)
        result = verify_app(arguments.app, baseline_app=arguments.baseline_app,
                            allow_unconfigured_development=arguments.allow_unconfigured_development)
    except ConfigurationError as error:
        print(json.dumps({"schemaVersion": 1, "status": "failed", "code": error.code,
                          "deploymentAllowed": False, "configurationValuesPrinted": False}),
              file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
