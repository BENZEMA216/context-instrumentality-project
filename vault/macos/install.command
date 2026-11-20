#!/bin/sh
# Install a user-scoped Mac launcher and an isolated runtime.
set -eu
src=$(cd "$(dirname "$0")/.." && pwd)
runtime="$HOME/.local/share/context-vault/runtime"
bundle="$HOME/Applications/Context Vault.app"
bindir="$HOME/.local/bin"
umask 077
mkdir -p "$(dirname "$runtime")" "$HOME/Applications" "$bindir"
if ! command -v uv >/dev/null 2>&1; then
    echo 'Install uv or use the pip installation in the Vault README.' >&2
    exit 1
fi
if [ ! -x "$runtime/bin/python" ]; then
    uv venv --python 3.12 "$runtime"
fi
uv pip install --python "$runtime/bin/python" --reinstall-package personal-context-vault "${src}[agent,gmail]"

stage=$(mktemp -d "$HOME/Applications/.context-vault-install-XXXXXX")
cleanup() {
    if [ -d "$stage/previous.app" ] && [ ! -e "$bundle" ]; then
        mv "$stage/previous.app" "$bundle"
    fi
    rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
new="$stage/Context Vault.app"
osacompile -o "$new" "$src/macos/ContextVault.applescript"
plist="$new/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string org.contextinstrumentality.vault "$plist"
plutil -replace CFBundleIconFile -string Vault.icns "$plist"
# The stock applet asset catalog otherwise takes precedence over the custom ICNS.
if plutil -extract CFBundleIconName raw "$plist" >/dev/null 2>&1; then
    plutil -remove CFBundleIconName "$plist"
fi
cp "$src/macos/Vault.icns" "$new/Contents/Resources/Vault.icns"
codesign --force --sign - "$new"
codesign --verify --strict "$new"
if [ -d "$bundle" ]; then mv "$bundle" "$stage/previous.app"; fi
mv "$new" "$bundle"

for command in context-vault context-vault-discover; do
    link="$bindir/$command"
    target="$runtime/bin/$command"
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
        ln -s "$target" "$link"
    elif [ "$(readlink "$link" 2>/dev/null || true)" != "$target" ]; then
        echo "Kept existing command at $link" >&2
    fi
done
echo "$bundle"
