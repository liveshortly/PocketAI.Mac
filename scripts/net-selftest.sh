#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

STDERR_LOG="/tmp/pocket_net_selftest.stderr"
rm -f "$STDERR_LOG"

echo "==> Building PocketAI macOS app..."
xcodebuild -scheme PocketAI -destination 'platform=macOS' -derivedDataPath build build

APP_DIR="build/Build/Products/Debug/PocketAI.app"
APP_BIN="$APP_DIR/Contents/MacOS/PocketAI"

if [ ! -f "$APP_BIN" ]; then
    echo "APL-08 FAIL binary not found at $APP_BIN"
    echo "APL-09 FAIL binary not found at $APP_BIN"
    echo "NET-10/APL-10 FAIL binary not found at $APP_BIN"
    exit 1
fi

echo "==> Launching $APP_BIN with -PocketNetSelfTest..."
"$APP_BIN" -PocketNetSelfTest 2>"$STDERR_LOG" &
APP_PID=$!

# Bounded wait up to 90s
WAITED=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$WAITED" -lt 90 ]; do
    sleep 1
    WAITED=$((WAITED + 1))
done

if kill -0 "$APP_PID" 2>/dev/null; then
    kill -9 "$APP_PID" 2>/dev/null || true
    echo "==> Process timed out after 90s"
fi

wait "$APP_PID" 2>/dev/null || true

if [ -f "$STDERR_LOG" ]; then
    echo "--- stderr output ---"
    cat "$STDERR_LOG"
    echo "---------------------"
fi

# Classify APL-08 (Bonjour discovery)
if [ -f "$STDERR_LOG" ] && grep -q "NET_DISCOVER=" "$STDERR_LOG"; then
    DISCO=$(grep "NET_DISCOVER=" "$STDERR_LOG" | head -n 1 | sed 's/^NET_DISCOVER=//')
    if [ "$DISCO" = "ok" ]; then
        echo "APL-08 PASS"
    elif [ "$DISCO" = "timeout" ]; then
        echo "APL-08 GATED local-network-permission"
    else
        echo "APL-08 FAIL $DISCO"
    fi
else
    echo "APL-08 FAIL missing NET_DISCOVER marker"
fi

# Classify APL-09 (Pinned TLS RTT)
if [ -f "$STDERR_LOG" ] && grep -q "NET_RTT=" "$STDERR_LOG"; then
    RTT=$(grep "NET_RTT=" "$STDERR_LOG" | head -n 1 | sed 's/^NET_RTT=//')
    if [ "$RTT" != "nil" ] && [ -n "$RTT" ]; then
        echo "APL-09 PASS rtt=${RTT}s"
    else
        echo "APL-09 FAIL rtt=nil"
    fi
else
    echo "APL-09 FAIL missing NET_RTT marker"
fi

# Classify NET-10/APL-10 (Pairing handshake)
if [ -f "$STDERR_LOG" ] && grep -q "NET_PAIRED=" "$STDERR_LOG"; then
    PAIRED=$(grep "NET_PAIRED=" "$STDERR_LOG" | head -n 1 | sed 's/^NET_PAIRED=//')
    if [ "$PAIRED" -gt 0 ]; then
        echo "NET-10/APL-10 PASS devices=$PAIRED"
    else
        echo "NET-10/APL-10 FAIL devices=0"
    fi
else
    if [ -f "$STDERR_LOG" ] && grep -q "NET_SELFTEST_ERROR=" "$STDERR_LOG"; then
        ERR=$(grep "NET_SELFTEST_ERROR=" "$STDERR_LOG" | head -n 1 | sed 's/^NET_SELFTEST_ERROR=//')
        echo "NET-10/APL-10 FAIL $ERR"
    else
        echo "NET-10/APL-10 FAIL missing NET_PAIRED marker"
    fi
fi
