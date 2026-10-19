#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_WAV="/tmp/pocket_stt_selftest.wav"
STDERR_LOG="/tmp/pocket_speech_selftest.stderr"
rm -f "$OUT_WAV" "$STDERR_LOG"

echo "==> Building PocketAI macOS app..."
xcodebuild -scheme PocketAI -destination 'platform=macOS' -derivedDataPath build build

APP_DIR="build/Build/Products/Debug/PocketAI.app"
APP_BIN="$APP_DIR/Contents/MacOS/PocketAI"

if [ ! -f "$APP_BIN" ]; then
    echo "APL-12 FAIL binary not found at $APP_BIN"
    exit 1
fi

echo "==> Launching $APP_BIN with -PocketSpeechSelfTest $OUT_WAV..."
"$APP_BIN" -PocketSpeechSelfTest "$OUT_WAV" 2>"$STDERR_LOG" &
APP_PID=$!

# Bounded wait up to 45s
WAITED=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$WAITED" -lt 45 ]; do
    sleep 1
    WAITED=$((WAITED + 1))
done

if kill -0 "$APP_PID" 2>/dev/null; then
    kill -9 "$APP_PID" 2>/dev/null || true
    echo "APL-12 FAIL timed out after 45s"
    if [ -f "$STDERR_LOG" ]; then
        echo "--- stderr ---" >&2
        cat "$STDERR_LOG" >&2
    fi
    exit 1
fi

wait "$APP_PID" 2>/dev/null || true

# Classify based on stderr output and exit code
if [ -f "$STDERR_LOG" ]; then
    if grep -q "STT_SELFTEST_AUTH=" "$STDERR_LOG"; then
        AUTH_STATUS=$(grep "STT_SELFTEST_AUTH=" "$STDERR_LOG" | head -n 1 | sed 's/^STT_SELFTEST_AUTH=//')
        echo "APL-12 GATED auth=$AUTH_STATUS"
        exit 0
    fi

    if grep -q "STT_SELFTEST_TEXT=" "$STDERR_LOG"; then
        TEXT=$(grep "STT_SELFTEST_TEXT=" "$STDERR_LOG" | head -n 1 | sed 's/^STT_SELFTEST_TEXT=//')
        LOWER_TEXT=$(echo "$TEXT" | tr '[:upper:]' '[:lower:]')
        if echo "$LOWER_TEXT" | grep -Eq 'fox|quick|brown|dog'; then
            echo "APL-12 PASS text=\"$TEXT\""
            exit 0
        else
            echo "APL-12 FAIL text=\"$TEXT\" does not contain expected phrase tokens"
            exit 1
        fi
    fi

    if grep -q "STT_SELFTEST_ERROR=" "$STDERR_LOG"; then
        ERR=$(grep "STT_SELFTEST_ERROR=" "$STDERR_LOG" | head -n 1 | sed 's/^STT_SELFTEST_ERROR=//')
        echo "APL-12 FAIL $ERR"
        exit 1
    fi
fi

echo "APL-12 FAIL process exited without writing a selftest marker"
if [ -f "$STDERR_LOG" ]; then
    echo "--- stderr ---" >&2
    cat "$STDERR_LOG" >&2
fi
exit 1
