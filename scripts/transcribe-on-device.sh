#!/bin/bash
set -euo pipefail

# Compile the shared iPhone actor for this Mac; no package or model downloads.
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
compiler_path=$(xcrun --sdk macosx --find swiftc)
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
build_dir="$repo_dir/build/OnDeviceTranscriber"
mkdir -p "$build_dir/module-cache"
target_arch=$(uname -m)

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
  -o "$build_dir/transcribe-on-device"
exec "$build_dir/transcribe-on-device" "$@"
