#!/bin/bash
set -euo pipefail

# Compile once into the per-user runtime directory; the receiver then reuses this
# executable. This command does not download speech models or read recordings.
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
build_dir=${WR_TRANSCRIBER_BUILD_DIR:-"$HOME/Library/Application Support/RecordForAgent/Runtime"}
compiler_path=$(xcrun --find swiftc)
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
target_arch=$(uname -m)
mkdir -p "$build_dir/module-cache"
chmod 700 "$build_dir"
runtime_stage=$(mktemp "$build_dir/.transcribe-on-device.XXXXXX")
trap 'rm -f "$runtime_stage"' EXIT

"$compiler_path" -emit-module -emit-library -static -parse-as-library \
  -module-name RecordingCore -emit-module-path "$build_dir/RecordingCore.swiftmodule" \
  -target "$target_arch-apple-macosx15.0" -sdk "$sdk_path" -swift-version 5 \
  -module-cache-path "$build_dir/module-cache" \
  "$repo_dir"/Sources/RecordingCore/*.swift -o "$build_dir/libRecordingCore.a"
"$compiler_path" -parse-as-library -module-name WristRecordTranscribe \
  -target "$target_arch-apple-macosx15.0" -sdk "$sdk_path" -swift-version 5 \
  -strict-concurrency=complete -module-cache-path "$build_dir/module-cache" \
  -I "$build_dir" -L "$build_dir" -lRecordingCore \
  "$repo_dir/Phone/OnDeviceTranscriber.swift" "$repo_dir/Tools/TranscribeOnDevice.swift" \
  -o "$runtime_stage"
chmod 700 "$runtime_stage"
mv -f "$runtime_stage" "$build_dir/transcribe-on-device"
printf '%s\n' "$build_dir/transcribe-on-device"
