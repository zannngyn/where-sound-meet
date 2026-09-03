#!/bin/bash
# Installs build/WhereSoundMeetDriver.driver into the system HAL folder. Requires sudo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/WhereSoundMeetDriver.driver"
DST="/Library/Audio/Plug-Ins/HAL/WhereSoundMeetDriver.driver"
[ -d "$SRC" ] || { echo "missing $SRC, run: make -C Driver" >&2; exit 1; }
sudo rm -rf "$DST" /Library/Audio/Plug-Ins/HAL/LoopbackDriver.driver
sudo cp -R "$SRC" "$DST"
sudo chown -R root:wheel "$DST"
sudo killall coreaudiod
echo "Installed $DST"
