#!/usr/bin/env bash
# Signs a built DMG and writes/updates the Sparkle appcast for it.
#
# Run AFTER scripts/notarize-mac.sh has produced a notarized, stapled DMG:
#   scripts/notarize-mac.sh
#   scripts/make-appcast.sh            # uses build/dist/PocketAI.dmg
#
# One-time setup, by the owner, before this works at all:
#
#   1. Generate the EdDSA key pair. Sparkle ships the tool; with the SPM
#      dependency resolved it lands under the build directory:
#        find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f
#      Run it once. The PRIVATE key is stored in your login keychain — it is
#      never written to this repo, and losing it means you can never ship an
#      update your installed apps will accept. Back it up (`generate_keys -x`)
#      somewhere safe.
#   2. It prints the PUBLIC key. Put that in project.yml as SUPublicEDKey.
#   3. Decide where the appcast and the DMGs are hosted, then set SUFeedURL in
#      project.yml to the appcast's URL and DOWNLOAD_BASE below to the
#      directory the DMGs sit in. Both must be HTTPS.
#
# Until SUFeedURL and SUPublicEDKey are set, the shipped app disables its
# "Check for Updates…" item (see Sources/Updates/Updater.swift) and this
# script refuses to pretend otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-build/dist/PocketAI.dmg}"
APPCAST="${APPCAST:-build/dist/appcast.xml}"
# The directory the DMGs are served from, no trailing slash. Must match where
# you actually upload them.
DOWNLOAD_BASE="${DOWNLOAD_BASE:-}"

if [ ! -f "$DMG" ]; then
  echo "error: no DMG at $DMG — run scripts/notarize-mac.sh first" >&2
  exit 1
fi

if [ -z "$DOWNLOAD_BASE" ]; then
  cat >&2 <<'EOF'
error: DOWNLOAD_BASE is not set, so the appcast would carry no usable download URL.

  DOWNLOAD_BASE=https://downloads.example.com/mac scripts/make-appcast.sh

This is the open decision on the Sparkle task: where the appcast and the DMGs
are hosted. Nothing else is blocking.
EOF
  exit 2
fi

SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f -perm +111 2>/dev/null | head -1)"
if [ -z "$SIGN_UPDATE" ]; then
  echo "error: sign_update not found — build the app once so SPM resolves Sparkle," >&2
  echo "       then: find ~/Library/Developer/Xcode/DerivedData -name sign_update" >&2
  exit 3
fi

# Version comes from the built app, not from a value typed twice.
APP="build/dist/PocketAI.app"
if [ ! -d "$APP" ]; then
  APP="$(find build/dist -maxdepth 3 -name 'PocketAI.app' -type d | head -1)"
fi
if [ ! -d "$APP" ]; then
  echo "error: PocketAI.app not found under build/dist — cannot read its version" >&2
  exit 4
fi
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 14.0)"

LENGTH="$(stat -f%z "$DMG")"
DMG_NAME="$(basename "$DMG")"
PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

echo "==> signing $DMG_NAME ($SHORT_VERSION build $BUILD_VERSION)"
# Prints e.g.: sparkle:edSignature="..." length="..."
SIG_ATTRS="$("$SIGN_UPDATE" "$DMG")"

mkdir -p "$(dirname "$APPCAST")"
cat > "$APPCAST" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>PocketAI</title>
    <item>
      <title>Version $SHORT_VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD_VERSION</sparkle:version>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure url="$DOWNLOAD_BASE/$DMG_NAME" type="application/octet-stream" $SIG_ATTRS />
    </item>
  </channel>
</rss>
XML

echo "==> wrote $APPCAST"
echo
echo "Single-item appcast: it advertises only this build. Sparkle is happy with"
echo "that — it compares against the running version — but release notes and a"
echo "version history mean keeping older <item> entries, so if you want those,"
echo "append to the file instead of regenerating it."
echo
echo "Upload BOTH to $DOWNLOAD_BASE (and the appcast to whatever SUFeedURL names):"
echo "  $DMG"
echo "  $APPCAST"
