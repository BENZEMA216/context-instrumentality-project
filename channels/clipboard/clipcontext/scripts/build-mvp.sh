#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

# Validate documentation before building or replacing an installed application.
for document in "使用说明.md" "Bug 反馈说明.md" "Distribution-README.md"; do
  if [[ ! -f "$root/docs/$document" ]]; then
    printf 'Missing release documentation: %s\n' "$root/docs/$document" >&2
    exit 1
  fi
done

build=${CLIPCONTEXT_DERIVED_DATA:-"$root/.build/DerivedData"}
dist="$root/Dist"
install_root=${CLIPCONTEXT_INSTALL_DIR:-"$HOME/Applications"}
mkdir -p "$dist" "$install_root"
if [[ ${1:-} != --package-existing ]]; then
  xcodebuild -scheme Maccy -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$build" CODE_SIGNING_ALLOWED=NO build
fi

staging=$(mktemp -d "$install_root/.clipcontext-build.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/ClipContext.app"
ditto --noextattr --norsrc "$build/Build/Products/Debug/ClipContext.app" "$app"
# Keep an in-app copy so documentation links still work after installation.
cp "$root/docs/使用说明.md" "$app/Contents/Resources/使用说明.md"
cp "$root/docs/Bug 反馈说明.md" "$app/Contents/Resources/Bug 反馈说明.md"
cp "$root/docs/Distribution-README.md" "$app/Contents/Resources/README.md"
xattr -rc "$app"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

delivery="$install_root/ClipContext.app"
if [[ -e "$delivery" ]]; then
  bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$delivery/Contents/Info.plist")
  [[ "$bundle_id" == com.benzema.ClipContext ]]
  mv "$delivery" "$staging/Previous.app"
fi
if ! mv "$app" "$delivery" || ! codesign --verify --deep --strict "$delivery"; then
  if [[ -e "$delivery" ]]; then mv "$delivery" "$staging/Failed.app"; fi
  if [[ -e "$staging/Previous.app" ]]; then mv "$staging/Previous.app" "$delivery"; fi
  exit 1
fi

# Archive the directory contents: users see both Markdown files beside the app.
package_root="$staging/package"
mkdir -p "$package_root"
ditto --noextattr --norsrc "$delivery" "$package_root/ClipContext.app"
cp "$root/docs/使用说明.md" "$package_root/使用说明.md"
cp "$root/docs/Bug 反馈说明.md" "$package_root/Bug 反馈说明.md"
ditto -c -k --noextattr --norsrc "$package_root" "$staging/ClipContext.zip"
python3 "$root/scripts/normalize-zip-utf8.py" "$staging/ClipContext.zip"
mv -f "$staging/ClipContext.zip" "$dist/ClipContext.zip"
printf '%s\n' "$delivery"
