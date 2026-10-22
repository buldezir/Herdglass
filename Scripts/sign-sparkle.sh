#!/bin/sh
# Signs the helpers inside an app's Sparkle.framework with the app's Developer
# ID. Xcode signs the framework it embeds but not the code nested in it, and
# notarization wants every binary signed with Developer ID, the hardened
# runtime and a secure timestamp.
#
#   sign-sparkle.sh                       as a target's last build phase, after
#                                         the framework is embedded and before
#                                         Xcode signs the app
#   sign-sparkle.sh <app> <identity>      for an app a script puts together,
#                                         before it signs the app
set -eu

if [ $# -ge 2 ]; then
	framework="$1/Contents/Frameworks/Sparkle.framework" identity=$2 name=$2
else
	framework="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
	identity=${EXPANDED_CODE_SIGN_IDENTITY:-}
	name=${EXPANDED_CODE_SIGN_IDENTITY_NAME:-${CODE_SIGN_IDENTITY:-}}
fi
case "$name" in
"Developer ID"*) ;;
*) exit 0 ;; # other builds don't update, and keep Sparkle's own signatures
esac

sign() { codesign --force --sign "$identity" --options runtime --timestamp "$@"; }
sign "$framework/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
sign "$framework/Versions/B/Autoupdate"
sign "$framework/Versions/B/Updater.app"
sign "$framework"
