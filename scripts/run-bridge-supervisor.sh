#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_LOG="$ROOT_DIR/build/codex-watch-bridge.log"
RESTART_DELAY="${CODEX_WATCH_RESTART_DELAY:-2}"
BRIDGE_NODE_ARGS=()

if [[ -n "${CODEX_WATCH_PROXY_URL:-}" ]]; then
  if ! node --help | grep -q -- '--use-env-proxy'; then
    echo "Configured outbound proxy requires Node.js with --use-env-proxy support." >&2
    exit 1
  fi
  export HTTP_PROXY="$CODEX_WATCH_PROXY_URL"
  export HTTPS_PROXY="$CODEX_WATCH_PROXY_URL"
  export NO_PROXY="${NO_PROXY:+$NO_PROXY,}127.0.0.1,localhost,::1"
  BRIDGE_NODE_ARGS+=(--use-env-proxy)
fi

mkdir -p "$ROOT_DIR/build"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

{
  echo "[$(timestamp)] bridge supervisor started"
  if [[ ${#BRIDGE_NODE_ARGS[@]} -gt 0 ]]; then
    echo "[$(timestamp)] outbound proxy enabled for Node fetch"
  fi
  while true; do
    echo "[$(timestamp)] starting Codex Watch bridge"
    set +e
    (cd "$ROOT_DIR" && node "${BRIDGE_NODE_ARGS[@]}" bridge/codex-watch-bridge.mjs)
    status=$?
    set -e
    echo "[$(timestamp)] bridge exited with status $status; restarting in ${RESTART_DELAY}s"
    sleep "$RESTART_DELAY"
  done
} >> "$BRIDGE_LOG" 2>&1
