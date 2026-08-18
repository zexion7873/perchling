#!/bin/bash
# Hot path: fires on every prompt / tool batch. Keep it cheap and never fail a hook.
[ "$(uname)" = Darwin ] || exit 0
d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/perchling"
# `disable` has to reach the hot path or it only half means it. `cmd_up` has
# always honoured this flag, so a disabled install launched no pet — but every
# prompt and every tool batch of every session still ran a dd, five seds and
# three writes on behalf of a user who turned the pet off, for as long as the
# flag stayed. One builtin test, no fork, which is the whole budget this file
# has. Before the mkdir, so a disabled install stops recreating the runtime
# home; after `$d`, because the flag lives inside it.
#
# Refcounts stop being re-stamped while disabled and that is the intended
# shape: `cmd_down` still removes them at SessionEnd, so nothing leaks, and a
# session that is still alive when `enable` runs re-announces itself on its
# next hook. A session too stale to do that is one the staleness window would
# have retired anyway.
[ -e "$d/disabled" ] && exit 0
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
  # The extraction is greedy and takes the LAST match, so a payload carrying a
  # nested object with its own "session_id" wins over the top-level one. For
  # every other field that is a cosmetic wrong answer; for this one it is a
  # FILENAME, written with mv below and removed with rm in pet.sh. A nested
  # `"session_id":"../../../evil"` resolves three levels above the sessions
  # directory and clobbers an arbitrary file whose third line the same payload
  # chose. Real ids are UUIDs, so the shape is checkable without a parser.
  # Rejected rather than repaired: an empty sid degrades to no refcount for
  # this hook, where a sanitised one still names a file somebody else picked.
  case "$sid" in ''|*[!A-Za-z0-9_-]*) sid= ;; esac
  # Verified against a real payload, not assumed: every hook event carries cwd.
  # Same greedy shape as the extractions around it — a tool payload with its
  # own "cwd" key would win and put a wrong directory name on one menu row
  # until the next hook fires, which is not worth a second parser. That
  # tradeoff holds only because this value is drawn, never resolved: it is a
  # label on a tray row, not a path this script opens.
  cwd=$(printf '%s' "$payload" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  # UserPromptSubmit payloads carry the prompt; snippet it for the speech
  # bubble. Stops at the first escaped quote — it's a teaser, not a transcript.
  # The 300 is BYTES and will land mid-codepoint on CJK about two times in
  # three. `cut -c1-300` is not the fix: hooks run with LANG, LC_ALL and
  # LC_CTYPE all unset, and measured under that C locale `cut -c` counts bytes
  # exactly like `head -c` — it only splits characters correctly on a developer
  # machine with a UTF-8 locale, which is the worst possible place for a test
  # to pass. The repair belongs to the reader, and `liveSessions` decodes
  # leniently so a dangling continuation byte costs one replacement character
  # instead of the whole file. The stderr redirect matters for the same reason
  # from the other side: under a UTF-8 locale this sed refuses invalid bytes
  # with `illegal byte sequence`, and this script must never write to a hook's
  # stderr. Losing the snippet there is already handled — line 3 is re-read.
  snippet=$(printf '%s' "$payload" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | head -c 300 | sed 's/\\*$//' 2>/dev/null)
  # Not every UserPromptSubmit is a person typing. The harness re-enters the
  # session with its own machinery — a finished background task, a reminder, a
  # slash command's stdout — through the same event, so the bubble was showing
  # "<task-notification> <task-id>w0o…" over the pet's head. The mood is still
  # right for those (the session really is running again); only the caption is
  # wrong, so this drops the snippet and leaves the previous one up rather than
  # skipping the whole hook. Matched on the specific tags, not a bare leading
  # "<", so a prompt that opens with markup still reaches the bubble.
  case "$snippet" in
    '<task-notification>'*|'<system-reminder>'*|'<local-command-'*|'<command-name>'*|'<command-message>'*)
      snippet= ;;
  esac
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
        | head -c 300 | sed 's/\\*$//' 2>/dev/null)
      [ -n "$reply" ] && snippet="$reply"
    fi
  fi
  if [ -n "$snippet" ]; then
    printf '%s' "$snippet" > "$d/.say.$$" 2>/dev/null && mv -f "$d/.say.$$" "$d/say" 2>/dev/null
  fi
  # Written LAST, because line 3 is the caption and the caption is not known
  # until the `done` branch above has had its chance to replace the prompt with
  # the reply.
  if [ -n "$sid" ]; then
    mkdir -p "$d/sessions" 2>/dev/null
    # An empty snippet must not erase the last one. Only a prompt and a reply
    # produce text; a tool batch produces none, and a session file is rewritten
    # whole on every hook, so writing the empty value would blank the bubble
    # halfway through a turn. The global `say` never had this problem because it
    # is only written when non-empty. The read costs one fork, and only on the
    # hooks that have nothing to say.
    [ -n "$snippet" ] || snippet=$(sed -n 3p "$d/sessions/$sid" 2>/dev/null)
    # Line 1 mood, line 2 cwd, line 3 caption. One write, one file: all three are
    # published by the same atomic mv and removed by the same rm, so the mood,
    # the label and the text can never disagree about whose they are. Always
    # three lines, empty ones included — `Mood.parse` reads line one and the
    # reader maps an empty line to nil, so the shorter forms `pet.sh` writes
    # stay valid.
    printf '%s\n%s\n%s' "${1:-idle}" "$cwd" "$snippet" > "$d/.sess.$$" 2>/dev/null
    mv -f "$d/.sess.$$" "$d/sessions/$sid" 2>/dev/null
  fi
fi
exit 0
