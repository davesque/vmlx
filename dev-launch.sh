#!/bin/bash
set -euo pipefail

# Launch the locally-built vMLX dev app from panel/release/mac-arm64/.
# Stops any running instance (panel + engine subprocesses), then relaunches
# with stdout/stderr captured to a log file so engine spawn errors are
# inspectable. Pass --tail to follow the log after launch.

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PANEL_DIR="$REPO_DIR/panel"
APP_PATH="$PANEL_DIR/release/mac-arm64/vMLX.app"
LOG_FILE="${TMPDIR:-/tmp}/vmlx-dev.log"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: $APP_PATH not found." >&2
  echo "Build it first:" >&2
  echo "  cd $PANEL_DIR && npx electron-vite build && npx electron-builder --mac --dir" >&2
  exit 1
fi

pkill -f "vMLX.app/Contents/MacOS/vMLX" 2>/dev/null || true
pkill -f "vmlx-engine" 2>/dev/null || true
pkill -f "vmlx_engine.cli serve" 2>/dev/null || true
sleep 1

echo "Launching: $APP_PATH"
echo "Log file:  $LOG_FILE"
nohup "$APP_PATH/Contents/MacOS/vMLX" > "$LOG_FILE" 2>&1 &
echo "Started pid=$!"

if [[ "${1-}" == "--tail" ]]; then
  echo "---"
  exec tail -f "$LOG_FILE"
fi
