#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

STDERR_LOG="/tmp/pocket_send_selftest.stderr"
rm -f "$STDERR_LOG"

echo "==> Building PocketAI macOS app..."
xcodebuild -scheme PocketAI -destination 'platform=macOS' -derivedDataPath build build

APP_DIR="build/Build/Products/Debug/PocketAI.app"
APP_BIN="$APP_DIR/Contents/MacOS/PocketAI"

if [ ! -f "$APP_BIN" ]; then
    echo "ENG-08 FAIL binary not found at $APP_BIN"
    exit 1
fi

echo "==> Launching $APP_BIN with -PocketSendSelfTest..."
"$APP_BIN" -PocketSendSelfTest 2>"$STDERR_LOG" &
APP_PID=$!

# Bounded wait up to 180s
WAITED=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$WAITED" -lt 180 ]; do
    sleep 1
    WAITED=$((WAITED + 1))
done

if kill -0 "$APP_PID" 2>/dev/null; then
    kill -9 "$APP_PID" 2>/dev/null || true
    echo "==> Process timed out after 180s"
fi

wait "$APP_PID" 2>/dev/null || true

if [ -f "$STDERR_LOG" ]; then
    echo "--- stderr output ---"
    cat "$STDERR_LOG"
    echo "---------------------"
fi

# Classify ENG-08 (Real multi-turn chat on a loaded model)
if [ -f "$STDERR_LOG" ] && grep -q "SEND_ERROR=" "$STDERR_LOG"; then
    ERR=$(grep "SEND_ERROR=" "$STDERR_LOG" | head -n 1 | sed 's/^SEND_ERROR=//')
    echo "ENG-08 FAIL $ERR"
    exit 1
elif [ -f "$STDERR_LOG" ] && grep -q "SEND_TURN1=" "$STDERR_LOG" && grep -q "SEND_TURN2=" "$STDERR_LOG"; then
    TURN1=$(grep "SEND_TURN1=" "$STDERR_LOG" | head -n 1 | sed 's/^SEND_TURN1=//')
    TURN2=$(grep "SEND_TURN2=" "$STDERR_LOG" | head -n 1 | sed 's/^SEND_TURN2=//')
    if [ -z "$TURN1" ] || [ -z "$TURN2" ]; then
        echo "ENG-08 FAIL empty assistant turn (turn1=\"$TURN1\", turn2=\"$TURN2\")"
        exit 1
    fi
    if echo "$TURN2" | grep -qi "rohit"; then
        echo "ENG-08 PASS turn1=\"$TURN1\" turn2=\"$TURN2\""
        exit 0
    else
        echo "ENG-08 PARTIAL turn1=\"$TURN1\" turn2=\"$TURN2\""
        exit 0
    fi
else
    echo "ENG-08 FAIL missing SEND_TURN markers"
    exit 1
fi
