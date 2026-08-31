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

# --- what a waiting session is blocked on rides line 4 ---
# Payload shape measured 2026-08-27, not assumed: "tool_name" is the CLI's own
# top-level key and serialises BEFORE tool_input, which is what makes the
# first-match extraction sound. The detail exists only while the mood is
# waiting; any other mood means the wait ended and retires it.
h=$(fire tool waiting '{"session_id":"abc-123","cwd":"/x","tool_name":"Bash","tool_input":{"command":"echo hi"}}')
[ "$(sed -n 4p "$h/perchling/sessions/abc-123" 2>/dev/null)" = Bash ] \
  && ok "line 4 is the blocking tool" \
  || no "line 4 is the blocking tool" "got '$(sed -n 4p "$h/perchling/sessions/abc-123")'"
# A "tool_name" inside tool_input must not out-rank the CLI's own.
h=$(fire tool-nested waiting '{"session_id":"abc-123","cwd":"/x","tool_name":"Bash","tool_input":{"tool_name":"Evil"}}')
[ "$(sed -n 4p "$h/perchling/sessions/abc-123" 2>/dev/null)" = Bash ] \
  && ok "a nested tool_name does not out-rank it" \
  || no "a nested tool_name does not out-rank it" "got '$(sed -n 4p "$h/perchling/sessions/abc-123")'"
# The token is drawn on screen; anything outside a real tool name's alphabet
# degrades to no detail, never to a repaired one.
h=$(fire tool-shape waiting '{"session_id":"abc-123","cwd":"/x","tool_name":"a;rm -rf /"}')
[ -z "$(sed -n 4p "$h/perchling/sessions/abc-123" 2>/dev/null)" ] \
  && ok "a hostile token degrades to none" \
  || no "a hostile token degrades to none" "got '$(sed -n 4p "$h/perchling/sessions/abc-123")'"
# One permission decision fires PermissionRequest and then Notification on a
# terminal host; the second write carries no tool_name and must keep the first's.
h=$(fire tool-carry waiting '{"session_id":"abc-123","cwd":"/x","tool_name":"Bash"}')
printf '%s' '{"session_id":"abc-123","cwd":"/x"}' \
  | CLAUDE_CONFIG_DIR="$h" bash "$STATE_SH" waiting >/dev/null 2>&1
[ "$(sed -n 4p "$h/perchling/sessions/abc-123" 2>/dev/null)" = Bash ] \
  && ok "a second waiting hook keeps the detail" \
  || no "a second waiting hook keeps the detail" "got '$(sed -n 4p "$h/perchling/sessions/abc-123")'"
printf '%s' '{"session_id":"abc-123","cwd":"/x"}' \
  | CLAUDE_CONFIG_DIR="$h" bash "$STATE_SH" running >/dev/null 2>&1
[ -z "$(sed -n 4p "$h/perchling/sessions/abc-123" 2>/dev/null)" ] \
  && ok "any other mood retires the detail" \
  || no "any other mood retires the detail" "got '$(sed -n 4p "$h/perchling/sessions/abc-123")'"
# The hot path never records one, even when the payload offers it.
h=$(fire tool-hot running '{"session_id":"abc-123","cwd":"/x","tool_name":"Bash"}')
[ -z "$(sed -n 4p "$h/perchling/sessions/abc-123" 2>/dev/null)" ] \
  && ok "a running hook never records one" \
  || no "a running hook never records one" "got '$(sed -n 4p "$h/perchling/sessions/abc-123")'"

# --- the transcript scrape: done gets the reply, error gets the autopsy ---
# One fixture serves both moods, because it is the same branch. The reply
# record's shape is captured from a real transcript, not invented: role and
# the text-block signature on one line, with a tool_use record AFTER it so
# the tail-1-of-text-lines rule is what the assertion exercises. The error
# fixture's last assistant record is the CLI's own <synthetic> one, which a
# hook-time snapshot (2026-08-31) shows is already written when StopFailure
# fires.
tscript="$W/transcript.jsonl"
cat > "$tscript" <<'EOT'
{"type":"user","message":{"role":"user","content":"hi"}}
{"parentUuid":"a1","type":"assistant","message":{"model":"claude-x","role":"assistant","content":[{"type":"text","text":"the reply itself"}]}}
{"parentUuid":"a2","type":"assistant","message":{"model":"claude-x","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash"}]}}
EOT
h=$(fire scrape-done done "{\"session_id\":\"abc-123\",\"cwd\":\"/x\",\"transcript_path\":\"$tscript\"}")
[ "$(sed -n 3p "$h/perchling/sessions/abc-123" 2>/dev/null)" = "the reply itself" ] \
  && ok "done: the reply is the caption" \
  || no "done: the reply is the caption" "got '$(sed -n 3p "$h/perchling/sessions/abc-123")'"

escript="$W/transcript-error.jsonl"
cat > "$escript" <<'EOT'
{"type":"user","message":{"role":"user","content":"hi"}}
{"parentUuid":"a1","type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"API Error: 400 forced failure"}]}}
EOT
h=$(fire scrape-error error "{\"session_id\":\"abc-123\",\"cwd\":\"/x\",\"transcript_path\":\"$escript\"}")
[ "$(sed -n 3p "$h/perchling/sessions/abc-123" 2>/dev/null)" = "API Error: 400 forced failure" ] \
  && ok "error: the autopsy is the caption" \
  || no "error: the autopsy is the caption" "got '$(sed -n 3p "$h/perchling/sessions/abc-123")'"
[ "$(cat "$h/perchling/say" 2>/dev/null)" = "API Error: 400 forced failure" ] \
  && ok "error: the bubble gets it too" \
  || no "error: the bubble gets it too" "say: '$(cat "$h/perchling/say" 2>/dev/null)'"

# The other moods must NOT scrape: a running hook offering a transcript keeps
# the prompt as its caption. Guards the condition against widening — every
# tool batch carries transcript_path, and scraping on the hot path would both
# pay the file read per batch and caption the bubble with a STALE reply while
# the turn is still going.
h=$(fire scrape-hot running "{\"session_id\":\"abc-123\",\"cwd\":\"/x\",\"prompt\":\"typed this\",\"transcript_path\":\"$tscript\"}")
[ "$(sed -n 3p "$h/perchling/sessions/abc-123" 2>/dev/null)" = "typed this" ] \
  && ok "running never scrapes" \
  || no "running never scrapes" "got '$(sed -n 3p "$h/perchling/sessions/abc-123")'"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
