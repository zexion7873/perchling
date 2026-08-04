#!/bin/bash
# Hot path: fires on every prompt / tool batch. Keep it cheap and never fail a hook.
[ "$(uname)" = Darwin ] || exit 0
d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/perchling"
[ -d "$d" ] || mkdir -p "$d"
printf '%s' "${1:-idle}" > "$d/.state.$$" 2>/dev/null && mv -f "$d/.state.$$" "$d/state" 2>/dev/null
if [ ! -t 0 ]; then
  # Hook payload arrives as one JSON blob on stdin. The harness keeps the pipe
  # open after writing, so never read until EOF — dd does exactly one read().
  payload=$(dd bs=65536 count=1 2>/dev/null)
  # The session refcount file doubles as this session's mood: the app folds
  # all live sessions by attention priority (waiting > error > done > running)
  # so one session's "running" can't stomp another's "waiting". The write also
  # re-stamps mtime, which the 1h staleness guard reads as liveness.
  sid=$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [ -n "$sid" ]; then
    mkdir -p "$d/sessions" 2>/dev/null
    printf '%s' "${1:-idle}" > "$d/.sess.$$" 2>/dev/null && mv -f "$d/.sess.$$" "$d/sessions/$sid" 2>/dev/null
  fi
  # UserPromptSubmit payloads carry the prompt; snippet it for the speech
  # bubble. Stops at the first escaped quote — it's a teaser, not a transcript.
  snippet=$(printf '%s' "$payload" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | head -c 300 | sed 's/\\*$//')
  if [ -n "$snippet" ]; then
    printf '%s' "$snippet" > "$d/.say.$$" 2>/dev/null && mv -f "$d/.say.$$" "$d/say" 2>/dev/null
  fi
fi
exit 0
