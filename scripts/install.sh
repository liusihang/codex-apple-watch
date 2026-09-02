#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/CodexWatchCompanion.xcodeproj"
SCHEME="CodexWatchCompanion"
BUNDLE_ID="${CODEX_WATCH_BUNDLE_ID:-dev.codexwatchcompanion}"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
WATCH_APP="$DERIVED_DATA/Build/Products/Debug-watchos/CodexWatchCompanion.app"
SIM_APP="$DERIVED_DATA/Build/Products/Debug-watchsimulator/CodexWatchCompanion.app"
BRIDGE_SESSION="codex-watch-bridge"
BRIDGE_LOG="$ROOT_DIR/build/codex-watch-bridge.log"
SIMULATOR_NAME="${CODEX_WATCH_SIMULATOR_NAME:-Apple Watch Series 11 (46mm)}"
DEVICE_ID="${CODEX_WATCH_DEVICE_ID:-}"
MODE="device"
START_BRIDGE=1
RUN_TESTS=0
BRIDGE_ENV_NAMES=(
  CODEX_WATCH_AUTH_TOKEN
  CODEX_SESSIONS_DIR
  CODEX_WATCH_CODEX_API_BASE_URL
  CODEX_WATCH_HOST
  CODEX_WATCH_LOCAL_HOSTNAME
  CODEX_WATCH_OPEN_CODEX
  CODEX_WATCH_PORT
  CODEX_WATCH_RESTART_DELAY
  CODEX_WATCH_SHOW_NETWORK_HINTS
  CODEX_WATCH_TRANSCRIBE_PROVIDER
  CODEX_WATCH_VERBOSE
)

usage() {
  cat <<USAGE
Usage:
  scripts/install.sh --device <devicectl-device-id>
  scripts/install.sh --simulator
  scripts/install.sh --bridge-only

Options:
  --device <id>     Build, install, and launch on a physical Apple Watch.
  --simulator       Build, install, and launch on the configured watch simulator.
  --bridge-only     Start/restart the Mac bridge only.
  --skip-bridge     Do not start/restart the Mac bridge.
  --test            Run bridge and watch simulator tests before installing.
  --help            Show this help.

Environment:
  CODEX_WATCH_AUTH_TOKEN        Require this bearer token for Watch bridge requests.
  CODEX_WATCH_DEVICE_ID         Physical watch CoreDevice identifier.
  CODEX_WATCH_SIMULATOR_NAME    watchOS simulator name. Default: Apple Watch Series 11 (46mm).
  CODEX_WATCH_BUNDLE_ID         Bundle identifier to launch. Default: dev.codexwatchcompanion.
  CODEX_WATCH_SHOW_NETWORK_HINTS=1
                                Print LAN/hostname bridge URLs in the bridge log.
  CODEX_WATCH_OPEN_CODEX=1      Open /Applications/Codex.app when the watch connects.
  CODEX_WATCH_RESTART_DELAY     Seconds before restarting a crashed bridge. Default: 2.

Find a physical device id:
  xcrun devicectl list devices
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      MODE="device"
      DEVICE_ID="${2:-}"
      shift 2
      ;;
    --simulator)
      MODE="simulator"
      shift
      ;;
    --bridge-only)
      MODE="bridge"
      shift
      ;;
    --skip-bridge)
      START_BRIDGE=0
      shift
      ;;
    --test)
      RUN_TESTS=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

bridge_command() {
  local command
  local name
  printf -v command 'cd %q && exec env CODEX_WATCH_BRIDGE_SUPERVISOR=1' "$ROOT_DIR"
  for name in "${BRIDGE_ENV_NAMES[@]}"; do
    if [[ -n "${!name+x}" ]]; then
      printf -v command '%s %q' "$command" "$name=${!name}"
    fi
  done
  printf -v command '%s bash scripts/run-bridge-supervisor.sh' "$command"
  printf '%s' "$command"
}

start_bridge() {
  mkdir -p "$ROOT_DIR/build"
  : > "$BRIDGE_LOG"
  local command
  command="$(bridge_command)"
  pkill -f "CODEX_WATCH_BRIDGE_SUPERVISOR=1" >/dev/null 2>&1 || true
  pkill -f "node .*bridge/codex-watch-bridge.mjs" >/dev/null 2>&1 || true
  if command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t "$BRIDGE_SESSION" >/dev/null 2>&1 || true
    tmux new-session -d -s "$BRIDGE_SESSION" "$command"
  else
    pkill -f "node .*codex-watch-bridge.mjs" >/dev/null 2>&1 || true
    nohup bash -lc "$command" >/dev/null 2>&1 &
  fi
  wait_for_bridge
  tail -n 3 "$BRIDGE_LOG" || true
}

wait_for_bridge() {
  local health_url="http://127.0.0.1:${CODEX_WATCH_PORT:-17842}/"
  local attempts=40
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if node -e 'fetch(process.argv[1]).then(response => process.exit(response.ok ? 0 : 1)).catch(() => process.exit(1))' "$health_url" >/dev/null 2>&1; then
      echo "Bridge health check passed: $health_url"
      return 0
    fi
    sleep 0.25
  done
  echo "Bridge did not pass health check: $health_url" >&2
  tail -n 40 "$BRIDGE_LOG" >&2 || true
  exit 1
}

run_tests() {
  (cd "$ROOT_DIR" && node --check bridge/codex-watch-bridge.mjs && npm test)
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=watchOS Simulator,name=$SIMULATOR_NAME" \
    -derivedDataPath "$DERIVED_DATA" \
    test
}

install_device() {
  if [[ -z "$DEVICE_ID" ]]; then
    echo "No physical watch device id provided." >&2
    echo "Run: xcrun devicectl list devices" >&2
    echo "Then: scripts/install.sh --device <id>" >&2
    exit 2
  fi

  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "generic/platform=watchOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    build

  xcrun devicectl device install app \
    --device "$DEVICE_ID" \
    --timeout 180 \
    "$WATCH_APP"

  xcrun devicectl device process launch \
    --device "$DEVICE_ID" \
    --timeout 60 \
    "$BUNDLE_ID"
}

install_simulator() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=watchOS Simulator,name=$SIMULATOR_NAME" \
    -derivedDataPath "$DERIVED_DATA" \
    build

  xcrun simctl boot "$SIMULATOR_NAME" >/dev/null 2>&1 || true
  open -a Simulator
  xcrun simctl install "$SIMULATOR_NAME" "$SIM_APP"
  xcrun simctl launch "$SIMULATOR_NAME" "$BUNDLE_ID"
}

require node
if [[ "$MODE" != "bridge" || "$RUN_TESTS" -eq 1 ]]; then
  require xcodebuild
  require xcrun
fi

if [[ "$START_BRIDGE" -eq 1 ]]; then
  start_bridge
fi

if [[ "$RUN_TESTS" -eq 1 ]]; then
  run_tests
fi

case "$MODE" in
  bridge)
    echo "Bridge is running. Log: $BRIDGE_LOG"
    ;;
  simulator)
    install_simulator
    ;;
  device)
    install_device
    ;;
esac
