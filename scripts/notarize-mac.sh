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
xcodebuild -scheme PocketAI -destination 'generic/platform=macOS' \
  -archivePath "$OUT/PocketAI.xcarchive" \
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
xcrun notarytool submit "$OUT/PocketAI.zip" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> staple + DMG"
xcrun stapler staple "$APP"
hdiutil create -volname "PocketAI" -srcfolder "$APP" -ov -format UDZO "$OUT/PocketAI.dmg"
echo "DONE -> $OUT/PocketAI.dmg (notarized, ready to ship from getpocketai.app)"
