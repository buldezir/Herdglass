#!/bin/sh
# Writes a Mac app's Sparkle appcast, its update feed, for one release: the
# version from the app's Info.plist, the zip's URL with its size and EdDSA
# signature, and the release's notes. The release workflow uploads it as
# <name>-appcast.xml, which the app's SUFeedURL reads from the latest release.
#
#   SPARKLE_PRIVATE_KEY=… appcast.sh <app> <zip> <zip url> <release page url> [notes.md] > appcast.xml
#
# sign_update comes with the Sparkle package, which xcodebuild resolves into
# build/SourcePackages or build/DerivedData/SourcePackages, and swift build
# into .build/artifacts; SIGN_UPDATE names another copy.
set -eu

app=$1 zip=$2 url=$3 page=$4 notes=${5:-}
root=$(cd "$(dirname "$0")/.." && pwd)
sign_update=${SIGN_UPDATE:-}
if [ -z "$sign_update" ]; then
	for artifacts in "$root/build/SourcePackages/artifacts" "$root/build/DerivedData/SourcePackages/artifacts" "$root/.build/artifacts"; do
		if [ -x "$artifacts/sparkle/Sparkle/bin/sign_update" ]; then
			sign_update=$artifacts/sparkle/Sparkle/bin/sign_update
			break
		fi
	done
fi
if [ -z "$sign_update" ]; then
	echo "error: no sign_update; build the app first, or set SIGN_UPDATE" >&2
	exit 1
fi

info="$app/Contents/Info.plist"
name=$(plutil -extract CFBundleDisplayName raw "$info" 2>/dev/null || plutil -extract CFBundleName raw "$info")
version=$(plutil -extract CFBundleShortVersionString raw "$info")
build=$(plutil -extract CFBundleVersion raw "$info")
minimum=$(plutil -extract LSMinimumSystemVersion raw "$info")

# The app installs only updates that its own public key verifies, so a
# release whose key doesn't match the private one could never update again.
public=$(swift - <<'SWIFT'
import CryptoKit
import Foundation
let key = ProcessInfo.processInfo.environment["SPARKLE_PRIVATE_KEY"]!.trimmingCharacters(in: .whitespacesAndNewlines)
let data = Data(base64Encoded: key) ?? Data()
// generate_keys exports the 32-byte seed; older keys are 96 bytes, ending with the public key.
let publicKey = data.count == 96 ? data.suffix(32) : (try? Curve25519.Signing.PrivateKey(rawRepresentation: data))?.publicKey.rawRepresentation
print(publicKey?.base64EncodedString() ?? "")
SWIFT
)
if [ "$public" != "$(plutil -extract SUPublicEDKey raw "$info")" ]; then
	echo "error: $app's SUPublicEDKey isn't the public half of SPARKLE_PRIVATE_KEY ($public)" >&2
	exit 1
fi

# sparkle:edSignature="…" length="…"
signature=$(printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$zip")

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$name</title>
    <item>
      <title>$name $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$page</sparkle:fullReleaseNotesLink>
EOF
if [ -n "$notes" ] && [ -s "$notes" ]; then
	# Markdown, which Sparkle's update dialog renders. ]]> would end the CDATA.
	printf '      <description sparkle:format="markdown"><![CDATA[\n'
	sed 's/]]>/]]]]><![CDATA[>/g' "$notes"
	printf ']]></description>\n'
fi
cat <<EOF
      <enclosure url="$url" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
EOF
