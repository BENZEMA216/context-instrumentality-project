import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/verify_google_oauth_bundle.py"
SPEC = importlib.util.spec_from_file_location("verify_google_oauth_bundle", SCRIPT)
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


def configured(prefix="1234567890-fixture"):
    reversed_client = "com.googleusercontent.apps." + prefix
    return {
        "CFBundleIdentifier": "dev.fixture.recorder",
        "CFBundleVersion": "77",
        GUARD.CLIENT_KEY: prefix + ".apps.googleusercontent.com",
        GUARD.REGISTERED_KEY: "dev.fixture.recorder",
        GUARD.REVERSED_KEY: reversed_client,
        "CFBundleURLTypes": [{"CFBundleURLName": "GoogleDriveOAuth",
                              "CFBundleURLSchemes": [reversed_client]}],
    }


def unconfigured():
    result = configured()
    result[GUARD.CLIENT_KEY] = ""
    result[GUARD.REGISTERED_KEY] = ""
    result[GUARD.REVERSED_KEY] = GUARD.UNCONFIGURED_SCHEME
    result["CFBundleURLTypes"][0]["CFBundleURLSchemes"] = [GUARD.UNCONFIGURED_SCHEME]
    return result


class GoogleOAuthBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.info = configured()

    def tearDown(self):
        self.temporary.cleanup()

    def app(self, name="Phone.app", info=None, fmt=plistlib.FMT_XML):
        path = self.root / name
        path.mkdir()
        (path / "Info.plist").write_bytes(plistlib.dumps(
            self.info if info is None else info, fmt=fmt))
        return path

    def rejected(self, code, info=None, **kwargs):
        with self.assertRaises(GUARD.ConfigurationError) as caught:
            GUARD.validate_info(self.info if info is None else info, **kwargs)
        self.assertEqual(caught.exception.code, code)
        self.assertEqual(str(caught.exception), code)
        for value in (self.info[GUARD.CLIENT_KEY], self.info[GUARD.REVERSED_KEY],
                      self.info["CFBundleIdentifier"]):
            self.assertNotIn(value, str(caught.exception))

    def verify_rejected(self, code, path, **kwargs):
        with self.assertRaises(GUARD.ConfigurationError) as caught:
            GUARD.verify_app(path, **kwargs)
        self.assertEqual(caught.exception.code, code)

    def cli(self, *arguments):
        return subprocess.run([sys.executable, "-B", str(SCRIPT), *map(str, arguments)],
                              capture_output=True, text=True, timeout=10)

    def test_valid_configuration_has_no_mutation_or_private_return_values(self):
        original = copy.deepcopy(self.info)
        result = GUARD.validate_info(self.info)
        self.assertEqual(result, {"configured": True, "deploymentAllowed": True})
        self.assertEqual(self.info, original)

    def test_xml_compiled_fixture_admitted(self):
        result = GUARD.verify_app(self.app())
        self.assertTrue(result["deploymentAllowed"])
        self.assertFalse(result["baselineCompared"])
        self.assertEqual(len(result["infoPlistSHA256"]), 64)

    def test_binary_compiled_fixture_admitted(self):
        self.assertTrue(GUARD.verify_app(self.app(fmt=plistlib.FMT_BINARY))["configured"])

    def test_empty_client_and_registered_reproduction_fails_default(self):
        self.rejected("oauth_unconfigured", unconfigured())

    def test_explicit_wholly_unconfigured_development_is_not_deployment_admission(self):
        result = GUARD.verify_app(self.app(info=unconfigured()),
                                  allow_unconfigured_development=True)
        self.assertEqual(result["status"], "unconfigured_development_only")
        self.assertFalse(result["deploymentAllowed"])
        self.assertFalse(result["configured"])

    def test_development_exception_does_not_accept_partial_configuration(self):
        for key in (GUARD.CLIENT_KEY, GUARD.REGISTERED_KEY):
            with self.subTest(key=key):
                info = unconfigured()
                info[key] = self.info[key]
                self.rejected("oauth_configuration_incomplete", info,
                              allow_unconfigured_development=True)

    def test_development_exception_cannot_use_additional_schemes(self):
        info = unconfigured()
        info["CFBundleURLTypes"][0]["CFBundleURLSchemes"].append("another-callback")
        self.rejected("oauth_configuration_incomplete", info,
                      allow_unconfigured_development=True)

    def test_missing_or_non_string_fields_are_rejected(self):
        for key in (GUARD.CLIENT_KEY, GUARD.REGISTERED_KEY, GUARD.REVERSED_KEY):
            for value in (None, 1, True, [], {}):
                with self.subTest(key=key, value=value):
                    info = copy.deepcopy(self.info)
                    info[key] = value
                    self.rejected("invalid_oauth_fields", info)

    def test_blank_individual_oauth_field_is_rejected(self):
        for key in (GUARD.CLIENT_KEY, GUARD.REGISTERED_KEY, GUARD.REVERSED_KEY):
            with self.subTest(key=key):
                info = copy.deepcopy(self.info)
                info[key] = ""
                self.rejected("oauth_configuration_incomplete", info)

    def test_whitespace_control_and_unexpanded_build_setting_are_rejected(self):
        for value in (" ", "\t", "\nprivate", "$(PRIVATE_CLIENT_ID)",
                      "${PRIVATE_CLIENT_ID}", "x\x00y", "x\u2003y"):
            with self.subTest(value=value):
                info = copy.deepcopy(self.info)
                info[GUARD.CLIENT_KEY] = value
                self.rejected("invalid_oauth_fields", info)

    def test_client_id_requires_exact_suffix_and_valid_nonempty_prefix(self):
        for value in ("apps.googleusercontent.com", ".apps.googleusercontent.com",
                      "x.apps.googleusercontent.com.evil", "x/oauth.apps.googleusercontent.com",
                      "x.apps.googleusercontent.COM", "é.apps.googleusercontent.com"):
            with self.subTest(value=value):
                info = copy.deepcopy(self.info)
                info[GUARD.CLIENT_KEY] = value
                self.rejected("invalid_client_id", info)

    def test_example_and_placeholder_configuration_is_rejected(self):
        for prefix in ("REPLACE_WITH_REGISTERED_IOS_CLIENT", "placeholder", "unconfigured"):
            with self.subTest(prefix=prefix):
                # The checked-in example's underscore is already an invalid
                # URL scheme. Other valid-looking placeholders reach the
                # explicit template check; neither form is admitted.
                code = "invalid_url_scheme" if "_" in prefix else "oauth_template_value"
                self.rejected(code, configured(prefix))

    def test_registered_bundle_must_equal_actual_bundle(self):
        info = copy.deepcopy(self.info)
        info[GUARD.REGISTERED_KEY] = "dev.fixture.other"
        self.rejected("registered_bundle_mismatch", info)

    def test_actual_bundle_must_be_nonempty_literal_identifier(self):
        for value in (None, "", "$(PRODUCT_BUNDLE_IDENTIFIER)", "dev. fixture",
                      "dev/fixture", "single", True):
            with self.subTest(value=value):
                info = copy.deepcopy(self.info)
                info["CFBundleIdentifier"] = value
                self.rejected("invalid_bundle_identifier", info)

    def test_reversed_client_is_derived_from_the_same_client(self):
        info = copy.deepcopy(self.info)
        info[GUARD.REVERSED_KEY] = "com.googleusercontent.apps.different"
        self.rejected("reversed_client_mismatch", info)

    def test_correct_callback_must_actually_be_registered(self):
        info = copy.deepcopy(self.info)
        info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] = ["other"]
        self.rejected("callback_scheme_not_registered_once", info)

    def test_callback_duplicate_across_entries_is_rejected(self):
        for scheme in (self.info[GUARD.REVERSED_KEY], self.info[GUARD.REVERSED_KEY].upper()):
            with self.subTest(case_variant=scheme.isupper()):
                info = copy.deepcopy(self.info)
                info["CFBundleURLTypes"].append({"CFBundleURLSchemes": [scheme]})
                self.rejected("callback_scheme_not_registered_once", info)

    def test_only_wrong_case_callback_is_rejected(self):
        info = copy.deepcopy(self.info)
        info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] = [self.info[GUARD.REVERSED_KEY].upper()]
        self.rejected("callback_scheme_not_registered_once", info)

    def test_well_formed_other_callback_is_allowed_when_configured(self):
        info = copy.deepcopy(self.info)
        info["CFBundleURLTypes"].append({"CFBundleURLSchemes": ["other-app-callback"]})
        self.assertTrue(GUARD.validate_info(info)["deploymentAllowed"])

    def test_url_types_and_schemes_fail_closed(self):
        cases = ((None, "invalid_url_types"), ([], "invalid_url_types"),
                 ([True], "invalid_url_types"), ([{}], "invalid_url_schemes"),
                 ([{"CFBundleURLSchemes": []}], "invalid_url_schemes"),
                 ([{"CFBundleURLSchemes": [None]}], "invalid_url_scheme"),
                 ([{"CFBundleURLSchemes": ["scheme:/private"]}], "invalid_url_scheme"),
                 ([{"CFBundleURLSchemes": ["$(CALLBACK)"]}], "invalid_url_scheme"))
        for value, code in cases:
            with self.subTest(code=code, value=value):
                info = copy.deepcopy(self.info)
                info["CFBundleURLTypes"] = value
                self.rejected(code, info)

    def test_baseline_comparison_ignores_unrelated_build_version(self):
        baseline = copy.deepcopy(self.info)
        baseline["CFBundleVersion"] = "75"
        result = GUARD.verify_app(self.app(), baseline_app=self.app("Baseline.app", baseline))
        self.assertTrue(result["baselineMatched"])

    def test_valid_but_different_client_fails_baseline(self):
        self.verify_rejected("baseline_configuration_mismatch", self.app(),
                             baseline_app=self.app("Baseline.app", configured("9876543210-other")))

    def test_url_types_comparison_is_full_and_type_sensitive(self):
        for before, after in (("BeforeName", "AfterName"), (True, 1)):
            with self.subTest(before=before):
                current, baseline = configured(), configured()
                current["CFBundleURLTypes"][0]["FixtureAdditionalValue"] = after
                baseline["CFBundleURLTypes"][0]["FixtureAdditionalValue"] = before
                with tempfile.TemporaryDirectory() as extra:
                    a, b = Path(extra) / "A.app", Path(extra) / "B.app"
                    for path, info in ((a, current), (b, baseline)):
                        path.mkdir()
                        (path / "Info.plist").write_bytes(plistlib.dumps(info))
                    self.verify_rejected("baseline_configuration_mismatch", a, baseline_app=b)

    def test_unconfigured_baseline_cannot_bless_a_configured_app(self):
        self.verify_rejected("baseline_oauth_invalid", self.app(),
                             baseline_app=self.app("Baseline.app", unconfigured()))

    def test_baseline_and_unconfigured_exception_are_mutually_exclusive(self):
        self.verify_rejected("baseline_and_unconfigured_exception_conflict", self.app(),
                             baseline_app=self.app("Baseline.app"),
                             allow_unconfigured_development=True)

    def test_self_baseline_is_rejected(self):
        app = self.app()
        self.verify_rejected("baseline_is_target", app, baseline_app=app)

    def test_missing_wrong_directory_and_missing_info_are_safe_errors(self):
        self.verify_rejected("invalid_app_directory", self.root / "Missing.app")
        wrong = self.root / "NotApp"
        wrong.mkdir()
        self.verify_rejected("invalid_app_directory", wrong)
        empty = self.root / "Empty.app"
        empty.mkdir()
        self.verify_rejected("app_info_unreadable", empty)

    def test_fixed_info_leaf_rejects_symlink_and_fifo(self):
        target = self.root / "private.plist"
        target.write_bytes(plistlib.dumps(self.info))
        for name, creator, code in (("Link.app", lambda p: p.symlink_to(target), "app_info_unreadable"),
                                    ("Fifo.app", lambda p: os.mkfifo(p), "invalid_info_file")):
            with self.subTest(name=name):
                app = self.root / name
                app.mkdir()
                creator(app / "Info.plist")
                self.verify_rejected(code, app)

    def test_malformed_xml_and_non_dictionary_plist_are_rejected(self):
        app = self.app()
        for data, code in ((b"<private malformed&", "invalid_info_plist"),
                           (plistlib.dumps(["private"]), "invalid_info_object")):
            with self.subTest(code=code):
                (app / "Info.plist").write_bytes(data)
                self.verify_rejected(code, app)

    def test_xml_duplicate_keys_are_rejected(self):
        app = self.app()
        data = (app / "Info.plist").read_bytes()
        data = data.replace(b"</dict>\n</plist>",
                            b"<key>WRGoogleDriveOAuthClientID</key><string>private</string>\n</dict>\n</plist>")
        (app / "Info.plist").write_bytes(data)
        self.verify_rejected("duplicate_plist_key", app)

    def test_binary_duplicate_keys_are_rejected(self):
        app = self.app()
        objects = b"\xd2\x01\x01\x02\x03\x53Foo\x51a\x51b"
        data = b"bplist00" + objects + bytes([8, 13, 17, 19])
        data += struct.pack(">6xBBQQQ", 1, 1, 4, 0, 21)
        self.assertEqual(plistlib.loads(data), {"Foo": "b"})
        (app / "Info.plist").write_bytes(data)
        # plistlib's binary parser wraps the duplicate-key ValueError, unlike
        # its XML parser. The static parse failure must still fail closed.
        self.verify_rejected("invalid_info_plist", app)

    def test_large_raw_and_huge_binary_object_count_are_bounded(self):
        app = self.app()
        cases = ((b"x" * (GUARD.MAX_INFO_BYTES + 1), "info_size_limit"),
                 (b"bplist00" + b"\x00" + struct.pack(">6xBBQQQ", 1, 1, 2**63, 0, 8),
                  "invalid_binary_plist_bounds"))
        for data, code in cases:
            with self.subTest(code=code):
                (app / "Info.plist").write_bytes(data)
                self.verify_rejected(code, app)

    def test_cyclic_binary_container_and_deep_tree_are_rejected(self):
        app = self.app()
        cyclic = configured()
        cycle = []
        cycle.append(cycle)
        cyclic["UnrelatedFixture"] = cycle
        (app / "Info.plist").write_bytes(plistlib.dumps(cyclic, fmt=plistlib.FMT_BINARY))
        self.verify_rejected("cyclic_plist", app)
        deep = configured()
        cursor = deep
        for _ in range(GUARD.MAX_PLIST_DEPTH + 1):
            cursor["Nested"] = {}
            cursor = cursor["Nested"]
        (app / "Info.plist").write_bytes(plistlib.dumps(deep, fmt=plistlib.FMT_BINARY))
        self.verify_rejected("info_structure_limit", app)

    def test_cli_success_does_not_echo_configuration_or_paths(self):
        app = self.app()
        result = self.cli("--app", app)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertTrue(output["deploymentAllowed"])
        self.assertEqual(result.stderr, "")
        for value in (str(app), self.info[GUARD.CLIENT_KEY], self.info[GUARD.REVERSED_KEY],
                      self.info["CFBundleIdentifier"]):
            self.assertNotIn(value, result.stdout)

    def test_cli_errors_are_fixed_json_without_values_or_tracebacks(self):
        app = self.app(info=unconfigured())
        for arguments in (("--app", app), ("--app", self.root / "private-missing.app"),
                          ("--app", app, "--private-unknown", "private-value"),
                          ("--app",)):
            with self.subTest(arguments=arguments):
                result = self.cli(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                output = json.loads(result.stderr)
                self.assertEqual(output["status"], "failed")
                self.assertFalse(output["deploymentAllowed"])
                self.assertNotIn("private", result.stderr)
                self.assertNotIn(str(app), result.stderr)
                self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
