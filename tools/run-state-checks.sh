#!/bin/bash
# state.sh: what it writes, and what it must refuse to write. Shell only —
# state.sh compiles nothing and launches nothing, so this needs no scratch
# binary and no stub.
#
# Takes PERCHLING_STATE_SH so it can be pointed at a mutant carrying exactly
# the defect each line is named after and shown to FAIL. That is the only
# reason to believe any of them:
#     git show <before>:scripts/state.sh > /tmp/old.sh
#     PERCHLING_STATE_SH=/tmp/old.sh bash tools/run-state-checks.sh
set -uo pipefail
STATE_SH="${PERCHLING_STATE_SH:-$(cd "$(dirname "$0")/.." && pwd)/scripts/state.sh}"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok(){ printf '  ok   %-30s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no(){ printf '  FAIL %-30s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# Each case gets its own config dir: state.sh's whole job is to leave files
# behind, so a shared one would let an earlier case answer a later assertion.
fire() { # fire <case> <mood> <payload>
  home="$W/$1"; mkdir -p "$home"
  printf '%s' "$3" | CLAUDE_CONFIG_DIR="$home" bash "$STATE_SH" "$2" >/dev/null 2>&1
  printf '%s' "$home"
}

# --- the ordinary path, so a harness that breaks everything still fails ---
h=$(fire benign running '{"session_id":"abc-123","cwd":"/Users/x/proj","prompt":"hello there"}')
[ -f "$h/perchling/sessions/abc-123" ] \
  && ok "a real session id is written" \
  || no "a real session id is written" "no session file appeared"
[ "$(sed -n 1p "$h/perchling/sessions/abc-123" 2>/dev/null)" = running ] \
  && ok "line 1 is the mood" \
  || no "line 1 is the mood"
[ "$(sed -n 2p "$h/perchling/sessions/abc-123" 2>/dev/null)" = /Users/x/proj ] \
  && ok "line 2 is the cwd" \
  || no "line 2 is the cwd"
[ "$(sed -n 3p "$h/perchling/sessions/abc-123" 2>/dev/null)" = "hello there" ] \
  && ok "line 3 is the caption" \
  || no "line 3 is the caption"

# --- the injection the shape check exists for ---
# The id is a FILENAME, and ../../../ from <cfg>/perchling/sessions lands one
# level ABOVE <cfg> — an arbitrary-file clobber whose third line the same
# payload chose. The traversal sits in the TOP-LEVEL id here because that is
# the only position the first-match extraction reads from; the nested case
# below asserts the position rule itself.
#
# The victim is a real file at the resolved target, and the assertion is on its
# CONTENT. Asserting "sessions/ is empty" instead is what the first version of
# this check did, and it passed against the unguarded script: the write lands
# outside sessions/ by construction, so an empty sessions/ is exactly what a
# successful attack leaves behind. The victim's name must also differ from any
# directory on that path, or `mv` moves the file INTO the directory rather than
# over it and the clobber never happens.
mkdir -p "$W/blast/cfg"
printf 'PRECIOUS\n' > "$W/blast/victim"
printf '%s' '{"session_id":"../../../victim","cwd":"/pwned","prompt":"HIJACKED"}' \
  | CLAUDE_CONFIG_DIR="$W/blast/cfg" bash "$STATE_SH" running >/dev/null 2>&1
[ "$(cat "$W/blast/victim" 2>/dev/null)" = PRECIOUS ] \
  && ok "a traversing session id clobbers nothing" \
  || no "a traversing session id clobbers nothing" "victim now: $(head -1 "$W/blast/victim")"
h="$W/blast/cfg"
[ -z "$(ls -A "$h/perchling/sessions" 2>/dev/null)" ] \
  && ok "and no session file at all" \
  || no "and no session file at all" "wrote $(ls "$h/perchling/sessions")"
# The mood still reaches the global state file: rejecting the id costs that
# hook its refcount and nothing else.
[ "$(cat "$h/perchling/state" 2>/dev/null)" = running ] \
  && ok "the global mood still lands" \
  || no "the global mood still lands"

# Shapes that are not path traversal but are still not session ids. `a/b` and
# `..` are NEGATIVE CONTROLS against an unguarded script — the first fails
# because sessions/a/ does not exist and the second because `mv` into a
# directory keeps the source name — so they assert correct behaviour without
# discriminating. The other three do discriminate.
for bad in 'a/b' '..' 'a b' 'a;rm' '$(id)'; do
  h=$(fire "shape-$(printf '%s' "$bad" | tr -c 'a-z0-9' _)" running \
        "{\"session_id\":\"$bad\",\"cwd\":\"/x\"}")
  [ -z "$(ls -A "$h/perchling/sessions" 2>/dev/null)" ] \
    && ok "rejected: $bad" \
    || no "rejected: $bad" "wrote $(ls "$h/perchling/sessions")"
done

# --- a nested id must not out-rank the real one ---
# The CLI's own session_id leads the payload, and everything an embedded
# object carries — tool_input, tool_response, a pasted transcript — serialises
# after it. The old LAST-match extraction let a well-formed UUID inside a
# nested object take the refcount: the ghost held the pet up for the whole
# staleness hour while the real session's row went stale mid-wait, hiding a
# blocked session's "waiting" — the pet's core job. Delivery is measured, not
# hypothetical: this repo's own hook captures carry nested ids.
h=$(fire nested waiting '{"session_id":"real-abc","cwd":"/x","tool_input":{"session_id":"aaaabbbb-1111-2222-3333-ccccddddeeee"},"prompt":"hi"}')
[ "$(sed -n 1p "$h/perchling/sessions/real-abc" 2>/dev/null)" = waiting ] \
  && ok "the real id gets the refcount" \
  || no "the real id gets the refcount" "sessions/: $(ls "$h/perchling/sessions" 2>/dev/null | tr '\n' ' ')"
[ ! -e "$h/perchling/sessions/aaaabbbb-1111-2222-3333-ccccddddeeee" ] \
  && ok "the nested ghost gets nothing" \
  || no "the nested ghost gets nothing"

# --- disable has to reach the hot path ---
h="$W/disabled"; mkdir -p "$h/perchling"; touch "$h/perchling/disabled"
printf '%s' '{"session_id":"abc-123","cwd":"/x","prompt":"hi"}' \
  | CLAUDE_CONFIG_DIR="$h" bash "$STATE_SH" running >/dev/null 2>&1
[ ! -e "$h/perchling/state" ] && [ ! -e "$h/perchling/sessions" ] \
  && ok "disabled writes nothing at all" \
  || no "disabled writes nothing at all" "left $(ls -A "$h/perchling" | tr '\n' ' ')"

# --- a hook with nothing to say must not blank the caption ---
h=$(fire carry running '{"session_id":"abc-123","cwd":"/x","prompt":"the first thing"}')
printf '%s' '{"session_id":"abc-123","cwd":"/x"}' \
  | CLAUDE_CONFIG_DIR="$h" bash "$STATE_SH" running >/dev/null 2>&1
[ "$(sed -n 3p "$h/perchling/sessions/abc-123" 2>/dev/null)" = "the first thing" ] \
  && ok "a tool batch carries the caption forward" \
  || no "a tool batch carries the caption forward" "got '$(sed -n 3p "$h/perchling/sessions/abc-123")'"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
