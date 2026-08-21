#!/bin/bash
# Optimized build of Herdglass.app for local use: no notarization, no
# distribution — just the app you keep in /Applications.
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
BIN="$(swift build -c release --show-bin-path)/Herdglass"
APP=".build/release-app/Herdglass.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Herdglass"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Herdglass.icns "$APP/Contents/Resources/Herdglass.icns"

# Stamp the commit into CFBundleVersion so a stale /Applications copy is
# recognisable from About / `mdls`.
if REV="$(git rev-parse --short HEAD 2>/dev/null)"; then
  [ -z "$(git status --porcelain 2>/dev/null)" ] || REV="$REV-dirty"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $REV" "$APP/Contents/Info.plist" >/dev/null
fi

# Ad-hoc signature: unsigned bundles get a fresh identity on every build, so
# macOS re-asks for notification permission each time.
codesign --force --sign - "$APP" >/dev/null
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
