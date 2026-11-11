#!/usr/bin/env bash
# Signed paired device build. This script never installs or starts an app.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" != 3 || ! "$1" =~ ^[0-9]+$ ]]; then
  echo 'Usage: scripts/build-device.sh BUILD_NUMBER ABSOLUTE_DERIVED_DATA ABSOLUTE_BASELINE_PHONE_APP' >&2
  exit 2
fi
BUILD_NUMBER="$1"
DERIVED_DATA="$2"
BASELINE_APP="$3"
if [[ "$DERIVED_DATA" != /* || "$BASELINE_APP" != /* || ! -f "$BASELINE_APP/Info.plist" ]]; then
  echo 'Absolute output and existing baseline Phone app paths are required.' >&2
  exit 2
fi
if [[ ! -f "$PROJECT_ROOT/Config/GoogleDrive.local.xcconfig" ]]; then
  echo 'Missing private Google Drive build configuration; no device build started.' >&2
  exit 3
fi
if [[ -z "${DEVELOPER_DIR:-}" || ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo 'Set DEVELOPER_DIR to the intended Xcode developer directory.' >&2
  exit 2
fi

# Validate the known working baseline before an expensive build. No values print.
python3 -B "$PROJECT_ROOT/scripts/verify_google_oauth_bundle.py" --app "$BASELINE_APP"
python3 -B "$PROJECT_ROOT/scripts/generate_project.py" --check
"$DEVELOPER_DIR/usr/bin/xcodebuild" -project "$PROJECT_ROOT/WristRecord.xcodeproj" \
  -scheme WristRecordPhone -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" build
PHONE_APP="$DERIVED_DATA/Build/Products/Debug-iphoneos/WristRecordPhone.app"
python3 -B "$PROJECT_ROOT/scripts/verify_google_oauth_bundle.py" \
  --app "$PHONE_APP" --baseline-app "$BASELINE_APP"
/usr/bin/codesign --verify --deep --strict "$PHONE_APP"
/usr/bin/codesign --verify --deep --strict "$PHONE_APP/Watch/WristRecordWatch.app"
echo 'Signed paired build and OAuth configuration parity passed; no app installed.'
