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
  [ -e "$ROOT/disabled" ] && exit 0
  mkdir -p "$SESSIONS"
  sid="${1:-}"
  [ -n "$sid" ] || sid="$(read_session_id)"
  [ -n "$sid" ] || sid="manual"
  # Write a fresh neutral mood, never bare-touch: the file's content is the
  # session's mood now, and touching a stale waiting/error would resurrect it
  # with a full TTL on session resume.
  printf idle > "$ROOT/.up.$$" 2>/dev/null && mv -f "$ROOT/.up.$$" "$SESSIONS/$sid" 2>/dev/null
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
  echo "disabled: $([ -e "$ROOT/disabled" ] && echo yes || echo no)"
}

cmd_stop() {
  rm -f "$SESSIONS"/* 2>/dev/null
  pkill -f "$BIN" 2>/dev/null
  echo "perchling stopped"
}

cmd_disable() {
  touch "$ROOT/disabled"
  pkill -f "$BIN" 2>/dev/null
  echo "perchling disabled ('pet.sh enable' to undo)"
}

cmd_enable() {
  rm -f "$ROOT/disabled"
  echo "perchling enabled"
  cmd_up manual
}

cmd_wake() {
  if [ -e "$ROOT/disabled" ]; then
    echo "perchling is disabled — run 'pet.sh enable' first" >&2
    exit 1
  fi
  touch "$ROOT/wake"
  echo "perchling waking"
  running || cmd_up manual
}

case "${1:-status}" in
  build)   cmd_build ;;
  up)      shift; cmd_up "${1:-}" ;;
  down)    shift; cmd_down "${1:-}" ;;
  stop)    cmd_stop ;;
  disable) cmd_disable ;;
  enable)  cmd_enable ;;
  wake)    cmd_wake ;;
  status)  cmd_status ;;
  *) echo "usage: pet.sh {build|up|down|stop|disable|enable|wake|status}" >&2; exit 2 ;;
esac
