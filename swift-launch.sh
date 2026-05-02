#!/bin/bash
set -euo pipefail

# Launch the locally-built Swift vMLX dev .app from build/xcode/.
# Stops any running instance (Swift app + vmlxctl subprocess + the
# Electron build, in case both are around), then relaunches with
# stdout/stderr captured to a log file. Pass --tail to follow the log.
# Pass --debug to launch the Debug-config build instead of Release
# (Release is the default because Debug is ~1.5x slower on dense
# models and ~3x slower on MoE — verified 2026-04-30 on Qwen3.6-27B
# and Qwen3.6-35B-A3B).

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED="$REPO_DIR/build/xcode"

CONFIG="Release"
TAIL=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="Debug" ;;
    --release) CONFIG="Release" ;;
    --tail) TAIL=1 ;;
    *) echo "swift-launch.sh: unknown arg '$arg' (use --debug, --release, --tail)" >&2; exit 2 ;;
  esac
done

APP_PATH="$DERIVED/Build/Products/$CONFIG/vMLX.app"
LOG_FILE="${TMPDIR:-/tmp}/vmlx-swift-dev.log"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: $APP_PATH not found." >&2
  echo "Build it first: make $([ "$CONFIG" = "Debug" ] && echo build || echo release)" >&2
  exit 1
fi

# Kill any running instance: Swift .app, vmlxctl serve subprocesses, and
# (for safety) the Electron app's binary too so they don't fight over
# bundle id ai.jangq.vmlx in LaunchServices. Try SIGTERM first, then
# SIGKILL anything that survived 2s.
pkill -f "vMLX.app/Contents/MacOS/vMLX" 2>/dev/null || true
pkill -f "vmlxctl serve"                2>/dev/null || true
sleep 2
pkill -9 -f "vMLX.app/Contents/MacOS/vMLX" 2>/dev/null || true
pkill -9 -f "vmlxctl serve"                2>/dev/null || true

echo "Launching: $APP_PATH"
echo "Log file:  $LOG_FILE"
nohup "$APP_PATH/Contents/MacOS/vMLX" > "$LOG_FILE" 2>&1 &
echo "Started pid=$!"

if [[ "$TAIL" -eq 1 ]]; then
  echo "---"
  exec tail -f "$LOG_FILE"
fi
