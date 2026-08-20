#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product HerdrTerm
BIN="$(swift build --show-bin-path)/HerdrTerm"
APP=".build/HerdrTerm.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HerdrTerm"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature: unsigned bundles get a fresh identity on every build, so
# macOS re-asks for notification permission each time.
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [ "${1:-}" = "--run" ]; then
  shift
  # Launch from this shell so SSH_AUTH_SOCK is inherited; `open` loses it.
  exec "$APP/Contents/MacOS/HerdrTerm" "$@"
fi
