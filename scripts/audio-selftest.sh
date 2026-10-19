#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_WAV="/tmp/pocket_tts_selftest.wav"
STDERR_LOG="/tmp/pocket_audio_selftest.stderr"
rm -f "$OUT_WAV" "$STDERR_LOG"

echo "==> Building PocketAI macOS app..."
xcodebuild -scheme PocketAI -destination 'platform=macOS' -derivedDataPath build build

APP_DIR="build/Build/Products/Debug/PocketAI.app"
APP_BIN="$APP_DIR/Contents/MacOS/PocketAI"

if [ ! -f "$APP_BIN" ]; then
    echo "APL-13 FAIL binary not found at $APP_BIN"
    exit 1
fi

echo "==> Launching $APP_BIN with -PocketAudioSelfTest $OUT_WAV..."
"$APP_BIN" -PocketAudioSelfTest "$OUT_WAV" 2>"$STDERR_LOG" &
APP_PID=$!

# Bounded wait up to 30s
WAITED=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$WAITED" -lt 30 ]; do
    sleep 1
    WAITED=$((WAITED + 1))
done

if kill -0 "$APP_PID" 2>/dev/null; then
    kill -9 "$APP_PID" 2>/dev/null || true
    echo "APL-13 FAIL timed out after 30s"
    if [ -f "$STDERR_LOG" ]; then
        echo "--- stderr ---" >&2
        cat "$STDERR_LOG" >&2
    fi
    exit 1
fi

if [ -f "$OUT_WAV" ]; then
    BYTES=$(stat -f%z "$OUT_WAV" 2>/dev/null || wc -c < "$OUT_WAV" | tr -d ' ')
    if [ "$BYTES" -gt 2048 ]; then
        echo "APL-13 PASS bytes=$BYTES"
        exit 0
    else
        echo "APL-13 FAIL wav size $BYTES <= 2048 bytes"
        if [ -f "$STDERR_LOG" ]; then
            echo "--- stderr ---" >&2
            cat "$STDERR_LOG" >&2
        fi
        exit 1
    fi
else
    echo "APL-13 FAIL $OUT_WAV not created"
    if [ -f "$STDERR_LOG" ]; then
        echo "--- stderr ---" >&2
        cat "$STDERR_LOG" >&2
    fi
    exit 1
fi
