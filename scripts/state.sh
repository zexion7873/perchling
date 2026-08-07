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
  # Verified against a real payload, not assumed: every hook event carries cwd.
  # Same greedy shape as the extractions around it — a tool payload with its
  # own "cwd" key would win and put a wrong directory name on one menu row
  # until the next hook fires, which is not worth a second parser.
  cwd=$(printf '%s' "$payload" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [ -n "$sid" ]; then
    mkdir -p "$d/sessions" 2>/dev/null
    # Line 1 mood, line 2 cwd. One write, one file: the mood and its label are
    # published by the same atomic mv and removed by the same rm, so they can
    # never disagree.
    if [ -n "$cwd" ]; then
      printf '%s\n%s' "${1:-idle}" "$cwd" > "$d/.sess.$$" 2>/dev/null
    else
      printf '%s' "${1:-idle}" > "$d/.sess.$$" 2>/dev/null
    fi
    mv -f "$d/.sess.$$" "$d/sessions/$sid" 2>/dev/null
  fi
  # UserPromptSubmit payloads carry the prompt; snippet it for the speech
  # bubble. Stops at the first escaped quote — it's a teaser, not a transcript.
  snippet=$(printf '%s' "$payload" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | head -c 300 | sed 's/\\*$//')
  # On Stop, the reply is better bubble material than an echo of the prompt the
  # user already typed. Each content block is its own transcript record, so
  # match the text-block signature — the final record is usually a tool_use or
  # a thinking block, never the prose. The role filter matters too: tool
  # results and image attachments are also text blocks, and a base64 payload in
  # the bubble helps nobody. 64KB of tail covers it: the p95 record is a few KB
  # and the reply is the last thing written.
  if [ "${1:-}" = done ]; then
    tp=$(printf '%s' "$payload" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    if [ -n "$tp" ] && [ -r "$tp" ]; then
      # Drop the leading line only when the tail actually cut one in half. On a
      # transcript smaller than the window the tail IS the whole file, and
      # discarding line one throws away the only reply of a session's first turn.
      if [ "$(wc -c < "$tp" 2>/dev/null || echo 0)" -gt 65536 ]; then
        chunk=$(tail -c 65536 "$tp" 2>/dev/null | tail -n +2)
      else
        chunk=$(cat "$tp" 2>/dev/null)
      fi
      # ERE, not BRE: the body has to accept escaped quotes, and a plain
      # [^"]* stops at the first one — turning a sentence into one word.
      reply=$(printf '%s\n' "$chunk" \
        | grep '"role":"assistant"' | grep '"type":"text","text":"' | tail -1 \
        | sed -nE 's/.*"type":"text","text":"(([^"\]|\\.)*)".*/\1/p' \
        | head -c 300 | sed 's/\\*$//')
      [ -n "$reply" ] && snippet="$reply"
    fi
  fi
  if [ -n "$snippet" ]; then
    printf '%s' "$snippet" > "$d/.say.$$" 2>/dev/null && mv -f "$d/.say.$$" "$d/say" 2>/dev/null
  fi
fi
exit 0
