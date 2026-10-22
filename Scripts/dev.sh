#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# libghostty is not in git: build it once from the pinned ghostty checkout.
Scripts/libghostty.sh --check || exit 1

swift build --product Herdglass
BIN_DIR="$(swift build --show-bin-path)"
APP=".build/Herdglass.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Herdglass" "$APP/Contents/MacOS/Herdglass"
# The updater, which a dev build links but never starts (its version is 0.1).
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Herdglass"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Herdglass.icns "$APP/Contents/Resources/Herdglass.icns"
# Ad-hoc signature: unsigned bundles get a fresh identity on every build, so
# macOS re-asks for notification permission each time.
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [ "${1:-}" = "--run" ]; then
  shift
  # Launch from this shell so SSH_AUTH_SOCK is inherited; `open` loses it.
  exec "$APP/Contents/MacOS/Herdglass" "$@"
fi
