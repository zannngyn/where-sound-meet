#!/bin/bash
# Build the SwiftPM executable and wrap it into build/WhereSoundMeet.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
swift build -c "$CONFIG" --package-path "$ROOT"
make -C "$ROOT/Driver" >/dev/null
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/WhereSoundMeet"
APP="$ROOT/build/WhereSoundMeet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WhereSoundMeet"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/build/WhereSoundMeetDriver.driver" "$APP/Contents/Resources/WhereSoundMeetDriver.driver"
codesign --force --sign - --identifier com.zan.wheresoundmeet "$APP"
echo "Built $APP"
