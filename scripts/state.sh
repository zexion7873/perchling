#!/bin/bash
# Hot path: fires on every prompt / tool batch. Keep it cheap and never fail a hook.
[ "$(uname)" = Darwin ] || exit 0
d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/perchling"
[ -d "$d" ] || mkdir -p "$d"
printf '%s' "${1:-idle}" > "$d/.state.$$" 2>/dev/null && mv -f "$d/.state.$$" "$d/state" 2>/dev/null
# Re-stamp this session's refcount so the app's 1h staleness guard trusts a
# session for as long as it keeps talking, not just at SessionStart.
if [ ! -t 0 ]; then
  # dd: exactly one read() — the harness keeps stdin open, so reading to EOF hangs.
  sid=$(dd bs=65536 count=1 2>/dev/null | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$sid" ] && touch "$d/sessions/$sid" 2>/dev/null
fi
exit 0
