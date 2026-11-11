import copy
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "provisioning_profile_guard", ROOT / "scripts/provisioning_profile_guard.py"
)
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


class ProfileMembershipTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 10, 30, 5, 0, tzinfo=timezone.utc)
        self.watch = "00000000-0000000000000001"
        self.phone = "00000000-0000000000000002"
        self.team = "TESTTEAM01"
        self.application = self.team + ".test.recorder.watchkitapp"
        self.profile = {
            "ExpirationDate": (self.now + timedelta(days=7)).replace(tzinfo=None),
            "ProvisionedDevices": [self.phone, self.watch],
            "TeamIdentifier": [self.team],
            "Platform": ["iOS", "xrOS", "visionOS"],
            "Entitlements": {
                "application-identifier": self.application,
                "com.apple.developer.team-identifier": self.team,
            },
        }

    def validate(self, profile=None, **overrides):
        arguments = {
            "expected_udid": self.watch,
            "expected_application_identifier": self.application,
            "expected_team_identifier": self.team,
            "now": self.now,
        }
        arguments.update(overrides)
        return GUARD.validate_profile(self.profile if profile is None else profile, **arguments)

    def rejected(self, code, profile=None, **overrides):
        with self.assertRaises(GUARD.ProfileValidationError) as caught:
            self.validate(profile, **overrides)
        self.assertEqual(caught.exception.code, code)
        self.assertEqual(str(caught.exception), code)
        for secret in (self.watch, self.phone, self.team, self.application):
            self.assertNotIn(secret, str(caught.exception))

    def test_exact_watch_membership_admitted_without_mutation(self):
        before = copy.deepcopy(self.profile)
        result = self.validate()
        self.assertEqual(result["status"], "profile_admitted")
        self.assertEqual(result["provisionedDeviceCount"], 2)
        self.assertFalse(result["platformUsedForAdmission"])
        self.assertFalse(result["dataContainerPreservedProven"])
        self.assertEqual(self.profile, before)

    def test_phone_only_replacement_same_watch_entitlements_is_rejected(self):
        # The observed failure structure: a new Watch profile retained Phone
        # membership, the same team/app entitlement and labels, but omitted Watch.
        wrong = copy.deepcopy(self.profile)
        wrong["ProvisionedDevices"] = [self.phone]
        self.rejected("device_not_provisioned", wrong)
        self.assertEqual(self.validate(wrong, expected_udid=self.phone)["status"], "profile_admitted")

    def test_platform_is_not_a_watch_membership_heuristic(self):
        for platform in (["iOS", "xrOS", "visionOS"], ["watchOS"], None, ["future-platform"]):
            with self.subTest(platform=platform):
                profile = copy.deepcopy(self.profile)
                if platform is None:
                    profile.pop("Platform")
                else:
                    profile["Platform"] = platform
                self.assertFalse(self.validate(profile)["platformUsedForAdmission"])

    def test_missing_empty_and_distribution_devices_fail_closed(self):
        for devices in (None, [], "not-a-list"):
            with self.subTest(devices=devices):
                profile = copy.deepcopy(self.profile)
                if devices is None:
                    profile.pop("ProvisionedDevices")
                else:
                    profile["ProvisionedDevices"] = devices
                profile["ProvisionsAllDevices"] = True
                self.rejected("missing_provisioned_devices", profile)

    def test_duplicate_or_invalid_devices_fail_closed(self):
        for devices, code in (([self.watch, self.watch], "ambiguous_provisioned_devices"), ([self.watch, 1], "invalid_provisioned_devices"), ([self.watch, "private\nvalue"], "invalid_provisioned_devices")):
            with self.subTest(code=code, devices=devices):
                profile = copy.deepcopy(self.profile)
                profile["ProvisionedDevices"] = devices
                self.rejected(code, profile)

    def test_expiry_boundary_and_old_profile_are_rejected(self):
        for expiry in (self.now, self.now - timedelta(microseconds=1)):
            with self.subTest(expiry=expiry):
                profile = copy.deepcopy(self.profile)
                profile["ExpirationDate"] = expiry
                self.rejected("profile_expired", profile)

    def test_invalid_expiration_and_clock_are_rejected(self):
        profile = copy.deepcopy(self.profile)
        profile["ExpirationDate"] = "2026-11-06"
        self.rejected("invalid_expiration", profile)
        self.rejected("invalid_check_time", now=0)

    def test_aware_dates_compare_absolute_time(self):
        profile = copy.deepcopy(self.profile)
        profile["ExpirationDate"] = (self.now + timedelta(seconds=1)).astimezone(timezone(timedelta(hours=8)))
        self.assertTrue(self.validate(profile)["expirationVerified"])

    def test_exact_application_identifier_required(self):
        for application in (None, self.team + ".*", self.team + ".test.recorder.phone"):
            with self.subTest(application=application):
                profile = copy.deepcopy(self.profile)
                profile["Entitlements"]["application-identifier"] = application
                self.rejected("application_identifier_mismatch", profile)

    def test_profile_and_entitlement_team_must_both_match(self):
        for teams in (None, ["OTHERTEAM1"], [self.team, "OTHERTEAM1"]):
            with self.subTest(teams=teams):
                profile = copy.deepcopy(self.profile)
                profile["TeamIdentifier"] = teams
                self.rejected("team_identifier_mismatch", profile)
        profile = copy.deepcopy(self.profile)
        profile["Entitlements"]["com.apple.developer.team-identifier"] = "OTHERTEAM1"
        self.rejected("entitlement_team_mismatch", profile)

    def test_malformed_input_and_expectations_are_rejected(self):
        self.rejected("invalid_profile", profile=[])
        profile = copy.deepcopy(self.profile)
        profile["Entitlements"] = []
        self.rejected("invalid_entitlements", profile)
        for key, value in (("expected_udid", ""), ("expected_udid", self.watch + "\n"), ("expected_team_identifier", None), ("expected_application_identifier", True)):
            with self.subTest(key=key, value=value):
                self.rejected("invalid_expected_identity", **{key: value})


if __name__ == "__main__":
    unittest.main()
