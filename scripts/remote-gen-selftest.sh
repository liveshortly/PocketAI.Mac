#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

STDERR_LOG="/tmp/pocket_remote_gen_selftest.stderr"
rm -f "$STDERR_LOG"

echo "==> Building PocketAI macOS app..."
xcodebuild -scheme PocketAI -destination 'platform=macOS' -derivedDataPath build build

APP_DIR="build/Build/Products/Debug/PocketAI.app"
APP_BIN="$APP_DIR/Contents/MacOS/PocketAI"

if [ ! -f "$APP_BIN" ]; then
    echo "APL-11 FAIL binary not found at $APP_BIN"
    exit 1
fi

echo "==> Launching $APP_BIN with -PocketRemoteGenSelfTest..."
"$APP_BIN" -PocketRemoteGenSelfTest 2>"$STDERR_LOG" &
APP_PID=$!

# Bounded wait up to 150s
WAITED=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$WAITED" -lt 150 ]; do
    sleep 1
    WAITED=$((WAITED + 1))
done

if kill -0 "$APP_PID" 2>/dev/null; then
    kill -9 "$APP_PID" 2>/dev/null || true
    echo "==> Process timed out after 150s"
fi

wait "$APP_PID" 2>/dev/null || true

if [ -f "$STDERR_LOG" ]; then
    echo "--- stderr output ---"
    cat "$STDERR_LOG"
    echo "---------------------"
fi

# Classify APL-11 (RemoteEngine generate over pinned TLS)
if [ -f "$STDERR_LOG" ] && grep -q "REMOTE_GEN_ERROR=" "$STDERR_LOG"; then
    ERR=$(grep "REMOTE_GEN_ERROR=" "$STDERR_LOG" | head -n 1 | sed 's/^REMOTE_GEN_ERROR=//')
    echo "APL-11 FAIL $ERR"
    exit 1
elif [ -f "$STDERR_LOG" ] && grep -q "REMOTE_GEN_TOKENS=" "$STDERR_LOG"; then
    TOKENS=$(grep "REMOTE_GEN_TOKENS=" "$STDERR_LOG" | head -n 1 | sed 's/^REMOTE_GEN_TOKENS=//')
    TEXT=$(grep "REMOTE_GEN_TEXT=" "$STDERR_LOG" | head -n 1 | sed 's/^REMOTE_GEN_TEXT=//')
    if [ -n "$TOKENS" ] && [ "$TOKENS" -gt 0 ] && [ -n "$TEXT" ]; then
        echo "APL-11 PASS tokens=$TOKENS text=\"$TEXT\""
        exit 0
    else
        echo "APL-11 FAIL tokens=${TOKENS:-0} text=\"${TEXT:-}\""
        exit 1
    fi
else
    echo "APL-11 FAIL missing REMOTE_GEN markers"
    exit 1
fi
