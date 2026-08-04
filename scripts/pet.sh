#!/bin/bash
# perchling control script: build, session refcounting, launch, teardown.
# Runtime home (binary, state, session refcounts) lives outside the plugin
# directory because the plugin path changes on every update.
set -u

ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/perchling"
SRC="$(cd "$(dirname "$0")" && pwd)/pet.swift"
BIN="$ROOT/bin/perchling"
SESSIONS="$ROOT/sessions"

read_session_id() {
  # Hook payload arrives as one JSON blob on stdin. The harness keeps the pipe
  # open after writing, so never read until EOF — dd does exactly one read()
  # and returns whatever the first write delivered. No jq dependency.
  dd bs=65536 count=1 2>/dev/null | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

supported() { [ "$(uname)" = Darwin ] && command -v swiftc >/dev/null 2>&1; }
running() { pgrep -f "$BIN" >/dev/null 2>&1; }

cmd_build() {
  supported || { echo "perchling needs macOS + Xcode Command Line Tools (swiftc)" >&2; return 1; }
  mkdir -p "$ROOT/bin"
  swiftc -O -o "$BIN" "$SRC" || return 1
  echo "built: $BIN"
}

cmd_up() {
  supported || exit 0
  mkdir -p "$SESSIONS"
  sid="${1:-}"
  [ -n "$sid" ] || sid="$(read_session_id)"
  [ -n "$sid" ] || sid="manual"
  touch "$SESSIONS/$sid"
  # (Re)build when missing or when a plugin update shipped newer source.
  if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    pkill -f "$BIN" 2>/dev/null
    cmd_build >/dev/null 2>&1 || exit 0
  fi
  running || PERCHLING_HOME="$ROOT" nohup "$BIN" </dev/null >/dev/null 2>&1 &
  exit 0
}

cmd_down() {
  sid="${1:-}"
  [ -n "$sid" ] || sid="$(read_session_id)"
  [ -n "$sid" ] && rm -f "$SESSIONS/$sid"
  exit 0
}

cmd_status() {
  echo "binary:   $BIN $([ -x "$BIN" ] && echo '(built)' || echo '(not built)')"
  echo "process:  $(running && echo running || echo stopped)"
  echo "state:    $(cat "$ROOT/state" 2>/dev/null || echo '-')"
  echo "sessions: $(ls -1 "$SESSIONS" 2>/dev/null | wc -l | tr -d ' ')"
}

cmd_stop() {
  rm -f "$SESSIONS"/* 2>/dev/null
  pkill -f "$BIN" 2>/dev/null
  echo "perchling stopped"
}

case "${1:-status}" in
  build)  cmd_build ;;
  up)     shift; cmd_up "${1:-}" ;;
  down)   shift; cmd_down "${1:-}" ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *) echo "usage: pet.sh {build|up|down|stop|status}" >&2; exit 2 ;;
esac
