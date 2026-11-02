#!/usr/bin/env bash
# Developer ID sign -> notarize -> staple -> DMG, for an UNSIGNED PocketAI.app
# built elsewhere (the MBP builds with CODE_SIGNING_ALLOWED=NO; signing
# material never leaves this machine).
#
#   scripts/sign-notarize-local.sh /path/to/PocketAI.app [out-dir]
#
# Needs: "Developer ID Application" identity in the login keychain and the
# App Store Connect API key (ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:?usage: $0 PocketAI.app [out-dir]}"
OUT="${2:-build/dist}"
ID="${SIGN_ID:-Developer ID Application: Rohit Sehgal (4RK6YA795V)}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.private_keys/AuthKey_784C9X9KK5.p8}"
KEY_ID="${ASC_KEY_ID:-784C9X9KK5}"
ISSUER="${ASC_ISSUER:-4ac4d69c-918c-4e45-a0a3-d84f1b8c8338}"
ENTITLEMENTS="Entitlements/PocketAI.entitlements"

rm -rf "$OUT"; mkdir -p "$OUT"
APP="$OUT/PocketAI.app"
ditto "$SRC" "$APP"

sign() { codesign --force --timestamp --options runtime --sign "$ID" "$@"; }

echo "==> sign (inside out)"
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$SPK" ]]; then
  # Sparkle's own XPC services keep their entitlements (Sparkle docs).
  sign --preserve-metadata=entitlements "$SPK/XPCServices/Downloader.xpc"
  sign "$SPK/XPCServices/Installer.xpc"
  sign "$SPK/Autoupdate"
  sign "$SPK/Updater.app"
  sign "$APP/Contents/Frameworks/Sparkle.framework"
fi
find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.dylib" -print0 | while IFS= read -r -d '' f; do sign "$f"; done
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> notarize (waits for Apple)"
ditto -c -k --keepParent "$APP" "$OUT/PocketAI.zip"
# `notarytool submit --wait` exits 0 even when Apple rejects, so read status.
xcrun notarytool submit "$OUT/PocketAI.zip" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" \
  --wait --output-format json > "$OUT/notarize.json"
STATUS="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' < "$OUT/notarize.json")"
if [[ "$STATUS" != "Accepted" ]]; then
  SUB="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' < "$OUT/notarize.json")"
  echo "error: notarization returned $STATUS" >&2
  xcrun notarytool log "$SUB" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" >&2 || true
  exit 1
fi

echo "==> staple + DMG"
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$OUT/PocketAI-$VERSION-$BUILD.dmg"
hdiutil create -quiet -volname "PocketAI" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$ID" "$DMG"
rm -f "$OUT/PocketAI.zip"
# $OUT is wiped each run; keep every shipped DMG for testers.
mkdir -p build/releases && cp "$DMG" build/releases/
echo "DONE -> $(pwd)/build/releases/$(basename "$DMG") (notarized + stapled, shareable)"
