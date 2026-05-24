#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_LOG="$ROOT_DIR/build/codex-watch-bridge.log"
RESTART_DELAY="${CODEX_WATCH_RESTART_DELAY:-2}"

mkdir -p "$ROOT_DIR/build"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

{
  echo "[$(timestamp)] bridge supervisor started"
  while true; do
    echo "[$(timestamp)] starting Codex Watch bridge"
    set +e
    (cd "$ROOT_DIR" && node bridge/codex-watch-bridge.mjs)
    status=$?
    set -e
    echo "[$(timestamp)] bridge exited with status $status; restarting in ${RESTART_DELAY}s"
    sleep "$RESTART_DELAY"
  done
} >> "$BRIDGE_LOG" 2>&1
