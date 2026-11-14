"""Pure, local admission check for a decoded device provisioning profile.

The caller must authenticate/decode the embedded profile and obtain the hardware
UDID from an independently bound physical target.  CoreDevice target identifiers
are not hardware UDIDs.  This module performs no I/O, signing, device access, or
profile repair.  In particular, Platform is informational: an existing working
Watch profile can carry iOS-family labels, so that label is not a membership test.
"""

from datetime import datetime, timezone


class ProfileValidationError(ValueError):
    """Static, non-sensitive failure code; never includes profile identities."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


def _fail(code):
    raise ProfileValidationError(code)


def _identity(value):
    return (
        isinstance(value, str)
        and 0 < len(value) <= 512
        and value == value.strip()
        and not any(ord(character) < 32 or ord(character) == 127 for character in value)
    )


def _utc(value, code):
    if not isinstance(value, datetime):
        _fail(code)
    try:
        # plistlib decodes Apple plist dates as naive UTC on Python 3.9.
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)
    except (ValueError, OverflowError, TypeError):
        _fail(code)


def validate_profile(
    profile,
    *,
    expected_udid,
    expected_application_identifier,
    expected_team_identifier,
    now,
):
    """Validate one already decoded development/ad-hoc device profile.

    Every expected identity is explicit and matched exactly.  ``now`` is required
    so callers can bind the check to their actual pre-install time and tests are
    deterministic.  Missing/ambiguous device membership, expired profiles, and
    identity conflicts fail closed.  No profile fields or expectations are
    returned in exceptions, and neither input is modified.

    Success is profile admission only, not evidence that installation preserved a
    data container, that a certificate is trusted, or that the OS accepted a
    profile.  CMS authenticity/code-signature checks remain the caller's duty.
    """
    if not all(
        _identity(value)
        for value in (
            expected_udid,
            expected_application_identifier,
            expected_team_identifier,
        )
    ):
        _fail("invalid_expected_identity")
    if not isinstance(profile, dict):
        _fail("invalid_profile")

    checked_at = _utc(now, "invalid_check_time")
    expiration = _utc(profile.get("ExpirationDate"), "invalid_expiration")
    if expiration <= checked_at:
        _fail("profile_expired")

    devices = profile.get("ProvisionedDevices")
    if not isinstance(devices, list) or not devices:
        _fail("missing_provisioned_devices")
    if not all(_identity(value) for value in devices):
        _fail("invalid_provisioned_devices")
    if len(set(devices)) != len(devices):
        _fail("ambiguous_provisioned_devices")
    if expected_udid not in devices:
        _fail("device_not_provisioned")

    teams = profile.get("TeamIdentifier")
    if not isinstance(teams, list) or teams != [expected_team_identifier]:
        _fail("team_identifier_mismatch")
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        _fail("invalid_entitlements")
    if entitlements.get("application-identifier") != expected_application_identifier:
        _fail("application_identifier_mismatch")
    if (
        entitlements.get("com.apple.developer.team-identifier")
        != expected_team_identifier
    ):
        _fail("entitlement_team_mismatch")

    return {
        "status": "profile_admitted",
        "deviceMembershipVerified": True,
        "applicationIdentifierVerified": True,
        "teamIdentifierVerified": True,
        "expirationVerified": True,
        "provisionedDeviceCount": len(devices),
        "checkedAtUTC": checked_at.isoformat(),
        "expirationUTC": expiration.isoformat(),
        "platformUsedForAdmission": False,
        "dataContainerPreservedProven": False,
    }
