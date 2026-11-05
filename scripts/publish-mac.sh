#!/usr/bin/env bash
# Publish a notarized PocketAI DMG as a GitHub release on liveshortly/pocketai-dist.
# sign-notarize-local.sh calls this after the DMG is stapled; set NO_PUBLISH=1 to skip.
#
#   scripts/publish-mac.sh build/releases/PocketAI-1.0-45.dmg
#
# Two assets per release: the versioned DMG, and PocketAI.dmg (a stable name), so
#   https://github.com/liveshortly/pocketai-dist/releases/latest/download/PocketAI.dmg
# always serves the newest build. The sites link to that URL and never need an edit.
set -euo pipefail
DMG="${1:?usage: $0 PocketAI-<version>-<build>.dmg}"
REPO="${DIST_REPO:-liveshortly/pocketai-dist}"
NAME="$(basename "$DMG" .dmg)"          # PocketAI-1.0-45
TAG="v${NAME#PocketAI-}"                # v1.0-45
spctl --assess --type open --context context:primary-signature "$DMG" ||
  { echo "error: $DMG is not a notarized DMG; refusing to publish" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$DMG" "$TMP/PocketAI.dmg"
shasum -a 256 "$TMP/PocketAI.dmg" | awk '{print $1"  PocketAI.dmg"}' > "$TMP/PocketAI.dmg.sha256"

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" -R "$REPO" --clobber "$DMG" "$TMP/PocketAI.dmg" "$TMP/PocketAI.dmg.sha256"
else
  gh release create "$TAG" -R "$REPO" --latest --title "PocketAI ${TAG#v}" \
    --notes "PocketAI for Mac, build ${TAG##*-}. Notarized by Apple. Requires macOS 14 or later on Apple silicon." \
    "$DMG" "$TMP/PocketAI.dmg" "$TMP/PocketAI.dmg.sha256"
fi
echo "PUBLISHED $TAG -> https://github.com/$REPO/releases/latest/download/PocketAI.dmg"
