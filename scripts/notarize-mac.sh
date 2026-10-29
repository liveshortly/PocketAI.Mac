#!/usr/bin/env bash
# Mac-direct distribution: archive -> export (Developer ID) -> notarize -> staple -> DMG.
# No App Store, no Apple cut. Run after enrolling + creating a "Developer ID Application" cert.
# Prereqs (owner, one-time):
#   - Apple Developer Program membership (Team 4RK6YA795V)
#   - "Developer ID Application" cert in the login keychain (Xcode > Settings > Accounts > Manage Certificates)
#   - A notarytool keychain profile:  xcrun notarytool store-credentials pocketai-notary \
#        --apple-id <APPLE_ID> --team-id 4RK6YA795V --password <APP_SPECIFIC_PASSWORD>
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM_ID="${TEAM_ID:-4RK6YA795V}"
NOTARY_PROFILE="${NOTARY_PROFILE:-pocketai-notary}"
OUT="build/dist"; rm -rf "$OUT"; mkdir -p "$OUT"

echo "==> xcodegen + archive"
xcodegen generate
# ARCHS pinned here as well as in project.yml: the SwiftPM dependencies do not
# inherit project build settings and would otherwise compile an x86_64 slice
# that nothing links — several minutes of MLX built for an architecture the app
# cannot run on.
xcodebuild -scheme PocketAI -destination 'generic/platform=macOS' \
  -archivePath "$OUT/PocketAI.xcarchive" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" \
  archive

echo "==> export (Developer ID)"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/PocketAI.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export"

APP="$OUT/export/PocketAI.app"
echo "==> zip + notarize (waits for Apple)"
ditto -c -k --keepParent "$APP" "$OUT/PocketAI.zip"
# `notarytool submit --wait` exits 0 even when Apple rejects the build, so the
# status has to be read. Without this the script walked on and tried to staple
# a ticket that was never issued.
SUBMIT_JSON="$OUT/notarize.json"
xcrun notarytool submit "$OUT/PocketAI.zip" --keychain-profile "$NOTARY_PROFILE" \
  --wait --output-format json | tee "$SUBMIT_JSON"
SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -expect string - <<<"$(cat "$SUBMIT_JSON")" 2>/dev/null || python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' < "$SUBMIT_JSON")"
STATUS="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' < "$SUBMIT_JSON")"
if [[ "$STATUS" != "Accepted" ]]; then
  echo "error: notarization returned $STATUS — Apple's reasons follow" >&2
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  exit 1
fi

echo "==> staple + DMG"
xcrun stapler staple "$APP"
hdiutil create -volname "PocketAI" -srcfolder "$APP" -ov -format UDZO "$OUT/PocketAI.dmg"
echo "DONE -> $OUT/PocketAI.dmg (notarized, ready to ship from getpocketai.app)"
