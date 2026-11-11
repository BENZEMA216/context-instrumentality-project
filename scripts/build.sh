#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-all}"
if [[ "$MODE" != "all" && "$MODE" != "phone" && "$MODE" != "watch" && "$MODE" != "companion" ]]; then
  echo "Usage: scripts/build.sh [all|phone|watch|companion]" >&2
  echo "phone = iOS Simulator validation without an embedded Watch app" >&2
  echo "companion = full iOS + embedded watchOS device-SDK build, without signing" >&2
  exit 2
fi

python3 "$PROJECT_ROOT/scripts/generate_project.py" --check

if [[ "$MODE" == "all" || "$MODE" == "phone" ]]; then
  echo "Building phone simulator validation only; Watch pairing/embedding is not covered."
  xcodebuild -project "$PROJECT_ROOT/WristRecord.xcodeproj" \
    -scheme WristRecordPhoneValidation -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$PROJECT_ROOT/build/DerivedDataPhoneValidation" \
    CODE_SIGNING_ALLOWED=NO build
fi

if [[ "$MODE" == "companion" ]]; then
  xcodebuild -project "$PROJECT_ROOT/WristRecord.xcodeproj" \
    -scheme WristRecordPhone -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$PROJECT_ROOT/build/DerivedDataCompanion" \
    CODE_SIGNING_ALLOWED=NO build
fi

if [[ "$MODE" == "all" || "$MODE" == "watch" ]]; then
  xcodebuild -project "$PROJECT_ROOT/WristRecord.xcodeproj" \
    -scheme WristRecordWatch -configuration Debug \
    -destination 'generic/platform=watchOS' \
    -derivedDataPath "$PROJECT_ROOT/build/DerivedDataWatch" \
    CODE_SIGNING_ALLOWED=NO build
fi
