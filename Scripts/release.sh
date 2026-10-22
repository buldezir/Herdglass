#!/bin/bash
# Optimized build of Herdglass.app for local use: no notarization, no
# distribution — just the app you keep in /Applications. A release passes
# IDENTITY="Developer ID Application", to sign it for notarization, and
# VERSION, BUILD and BUNDLE_ID to override Resources/Info.plist's.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1; shift ;;
    --run) RUN=1; shift; break ;;
    -h|--help)
      echo "usage: Scripts/release.sh [--install] [--run [args...]]"
      exit 0 ;;
    *) echo "release.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

# libghostty is not in git: build it once from the pinned ghostty checkout.
Scripts/libghostty.sh --check || exit 1

swift build -c release --product Herdglass
BIN_DIR="$(swift build -c release --show-bin-path)"
APP=".build/release-app/Herdglass.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Herdglass" "$APP/Contents/MacOS/Herdglass"
# The updater: swift build leaves it next to the binary, an app keeps it in Frameworks.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Herdglass"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Herdglass.icns "$APP/Contents/Resources/Herdglass.icns"
if [ -n "${VERSION:-}" ]; then plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"; fi
if [ -n "${BUNDLE_ID:-}" ]; then plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"; fi

# A release's CFBundleVersion is the build number Sparkle compares. A local
# build's is the commit, so a stale /Applications copy is recognisable from
# About / `mdls`; it is version 0.1, which doesn't update.
if [ -n "${BUILD:-}" ]; then
  plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
elif REV="$(git rev-parse --short HEAD 2>/dev/null)"; then
  [ -z "$(git status --porcelain 2>/dev/null)" ] || REV="$REV-dirty"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $REV" "$APP/Contents/Info.plist" >/dev/null
fi

# Ad-hoc signature unless IDENTITY names one: unsigned bundles get a fresh
# identity on every build, so macOS re-asks for notification permission each
# time. Notarization needs the hardened runtime and a secure timestamp, on the
# app and on Sparkle's helpers. Under the runtime, a program in a pane asking
# for Apple Events, the camera and the like asks as Herdglass, and is refused
# unless Herdglass's entitlements allow it; they are Ghostty's. An ad hoc
# signature goes without the runtime: its library validation would stop an ad
# hoc app from loading Sparkle.framework, which is signed by Sparkle's team.
case "${IDENTITY:-}" in
"Developer ID"*)
  Scripts/sign-sparkle.sh "$APP" "$IDENTITY"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements Resources/Herdglass.entitlements "$APP"
  ;;
*)
  codesign --force --sign - "$APP" >/dev/null
  ;;
esac
echo "Built $APP"

if [ "$INSTALL" = 1 ]; then
  DEST="/Applications/Herdglass.app"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installed $DEST"
  APP="$DEST"
fi

if [ "$RUN" = 1 ]; then
  # Launch from this shell so SSH_AUTH_SOCK is inherited; `open` loses it.
  exec "$APP/Contents/MacOS/Herdglass" "$@"
fi
