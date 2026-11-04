#!/bin/bash
# cmd_up's housekeeping: what it removes from sessions/, owners/ and the
# runtime home, and what it must not. Separate from run-launch-race.sh (which is about launching
# exactly once), run-build-gate.sh (about a failed build) and
# run-library-refresh.sh (about the shipped-art refresh) because they are four
# unrelated properties of the same function and a single file would make a
# failure ambiguous.
#
# Takes PERCHLING_PET_SH so it can be pointed at a mutant and shown to FAIL.
# The stub is a compiled C binary that stays alive: cmd_up ends in launch_once,
# which spins for five seconds waiting for `running()` to see a process, and a
# stub that is a script or exits immediately is invisible to `pgrep -x -f`. It
# is deliberately NOT a copy of the real binary — that copy is an executable
# that stays alive by opening a pet window on the user's desktop.
set -uo pipefail
PET_SH="${PERCHLING_PET_SH:-$(cd "$(dirname "$0")/.." && pwd)/plugin/scripts/pet.sh}"

W=$(mktemp -d)
stub=""
cleanup() { [ -n "$stub" ] && { kill "$stub"; wait "$stub"; } 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
pass=0; fail=0
ok(){ printf '  ok   %-32s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no(){ printf '  FAIL %-32s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

mkdir -p "$W/scripts" "$W/cfg/perchling/bin" "$W/cfg/perchling/sessions" "$W/cfg/perchling/owners"
cp "$PET_SH" "$W/scripts/pet.sh"
printf '#include <unistd.h>\nint main(void){ sleep(90); return 0; }\n' > "$W/stub.c"
cc -o "$W/cfg/perchling/bin/perchling" "$W/stub.c" 2>/dev/null || { echo "cc unavailable"; exit 1; }
S="$W/cfg/perchling/sessions"; O="$W/cfg/perchling/owners"

# The binary must look current or cmd_up tries to build a pet.swift that is not
# beside the copied script.
printf 'let x = 1\n' > "$W/scripts/pet.swift"
touch -t 202608190100 "$W/scripts/pet.swift"
touch -t 202608190200 "$W/cfg/perchling/bin/perchling"

# Two stale sessions, one with an owner and one without, plus a fresh one that
# must survive. Ages are set with touch -t rather than by waiting: the cutoff
# is an hour and a harness cannot spend one.
printf 'running\n/x\nold prompt text' > "$S/stale-owned"
printf '%s' 99999 > "$O/stale-owned"
printf 'done\n/x\nalso old' > "$S/stale-orphan"
printf 'running\n/x\nfresh' > "$S/fresh"
printf '%s' 99999 > "$O/fresh"
touch -t 202608190100 "$S/stale-owned" "$S/stale-orphan" "$O/stale-owned"
printf 'a prompt an older release kept' > "$W/cfg/perchling/say"
printf 'running\n/x\na killed hook left this' > "$W/cfg/perchling/.sess.111"
printf 'running\n/x\na write in flight' > "$W/cfg/perchling/.sess.222"
touch -t 202608190100 "$W/cfg/perchling/.sess.111"

"$W/cfg/perchling/bin/perchling" & stub=$!
sleep 0.2
# An install made before umask 077 has a 755 home that mkdir -p leaves alone.
chmod 755 "$W/cfg/perchling"
# umask 022 is the common default; the session file written below must come
# out owner-only whatever umask the hook inherited.
( umask 022; CLAUDE_CONFIG_DIR="$W/cfg" bash "$W/scripts/pet.sh" up newsession >/dev/null 2>&1 )
sleep 0.4

[ ! -e "$S/stale-owned" ] \
  && ok "a session past the cutoff is removed" \
  || no "a session past the cutoff is removed" "still there"
[ ! -e "$S/stale-orphan" ] \
  && ok "even one whose owner already went" \
  || no "even one whose owner already went" "still there"
# The prune runs BEFORE the owner loop precisely so this needs no pairing logic.
[ ! -e "$O/stale-owned" ] \
  && ok "and its owner goes with it" \
  || no "and its owner goes with it" "orphaned owner left behind"

[ -e "$S/fresh" ] \
  && ok "a fresh session survives" \
  || no "a fresh session survives" "cmd_up deleted a live refcount"
[ "$(sed -n 3p "$S/fresh")" = fresh ] \
  && ok "and is not rewritten" \
  || no "and is not rewritten" "got '$(sed -n 3p "$S/fresh")'"
[ -e "$S/newsession" ] \
  && ok "the starting session is written" \
  || no "the starting session is written"
mode=$(stat -f '%Lp' "$S/newsession" 2>/dev/null)
[ "$mode" = 600 ] \
  && ok "and is readable only by its owner" \
  || no "and is readable only by its owner" "mode ${mode:-missing}"
mode=$(stat -f '%Lp' "$W/cfg/perchling" 2>/dev/null)
[ "$mode" = 700 ] \
  && ok "an old 755 home is closed to others" \
  || no "an old 755 home is closed to others" "mode ${mode:-missing}"
[ -e "$O/fresh" ] \
  && ok "a live session keeps its owner" \
  || no "a live session keeps its owner"
# The owner record: the pid on line 1 and, since 1.22.3, the owner's start
# time on line 2 in the CLI's procStart spelling, so the overlay can tell a
# recycled pid from the process that owned the session. The pid is this
# harness's own ancestor, so its start time is whatever ps says for it.
owner1=$(sed -n 1p "$O/newsession" 2>/dev/null); owner2=$(sed -n 2p "$O/newsession" 2>/dev/null)
case "$owner1" in ''|*[!0-9]*) no "the owner record starts with a pid" "line 1: '$owner1'" ;;
  *) ok "the owner record starts with a pid" ;; esac
[ -n "$owner2" ] && [ "$owner2" = "$(LC_ALL=C TZ=UTC ps -o lstart= -p "$owner1" 2>/dev/null)" ] \
  && ok "and carries the owner's start time" \
  || no "and carries the owner's start time" "line 2: '$owner2'"
[ ! -e "$W/cfg/perchling/say" ] \
  && ok "a retired say file is removed" \
  || no "a retired say file is removed" "still there"
[ ! -e "$W/cfg/perchling/.sess.111" ] \
  && ok "an orphaned session temp is removed" \
  || no "an orphaned session temp is removed" "still there"
[ -e "$W/cfg/perchling/.sess.222" ] \
  && ok "a fresh session temp survives" \
  || no "a fresh session temp survives" "cmd_up raced a live write"

# --- a sid typed as an argument is a filename too ---
# `up` and `down` take their sid from $1 before they look at the payload, and
# that value reaches the same `mv -f` and `rm -f` the payload's does. The
# payload path has had a shape check since the ghost-row bug; the argument
# path had none, so `pet.sh down '../../x'` removed a file two levels above
# sessions/. SKILL.md and README.md tell an agent to run this script, and an
# agent's arguments come from a conversation. The victim sits where
# sessions/../.. resolves, and the assertion is on its CONTENT, for the reason
# run-state-checks.sh gives: an empty sessions/ is what a successful traversal
# leaves behind. stdin is /dev/null, not the harness's: a rejected argument
# falls back to the payload, and dd on an inherited pipe would wait on it.
printf 'PRECIOUS\n' > "$W/cfg/victim"
CLAUDE_CONFIG_DIR="$W/cfg" bash "$W/scripts/pet.sh" down '../../victim' </dev/null >/dev/null 2>&1
[ "$(cat "$W/cfg/victim" 2>/dev/null)" = PRECIOUS ] \
  && ok "down with a traversing sid removes nothing" \
  || no "down with a traversing sid removes nothing" "victim now: '$(cat "$W/cfg/victim" 2>/dev/null)'"
CLAUDE_CONFIG_DIR="$W/cfg" bash "$W/scripts/pet.sh" up '../../planted' </dev/null >/dev/null 2>&1
sleep 0.4
[ ! -e "$W/cfg/planted" ] \
  && ok "up with a traversing sid writes nothing there" \
  || no "up with a traversing sid writes nothing there" "wrote $W/cfg/planted"
# Rejected means empty, and an empty sid with no payload is the manual bridge —
# the same place an unparseable payload lands, never a repaired name.
[ -e "$S/manual" ] \
  && ok "and lands on the manual bridge" \
  || no "and lands on the manual bridge" "sessions/: $(ls -A "$S" | tr '\n' ' ')"
rm -f "$W/cfg/victim"

# Auto-compaction fires SessionStart in the middle of a turn that is still working.
printf 'running\n/x\nmid-turn' > "$S/compacted"
printf 'waiting\n/x\nstale' > "$S/resumed"
printf 'done\n/x\nan hour ago' > "$S/away"
touch -t 202608190100 "$S/away"
up() {
  printf '{"session_id":"%s","source":"%s","cwd":"/x"}' "$1" "$2" \
    | CLAUDE_CONFIG_DIR="$W/cfg" bash "$W/scripts/pet.sh" up >/dev/null 2>&1
}
# `away` goes first: any other call's prune would delete it before its own start could.
up away compact; up compacted compact; up resumed resume; up unwritten compact
[ "$(sed -n 1p "$S/compacted")" = running ] \
  && ok "a compaction keeps the mood" \
  || no "a compaction keeps the mood" "got '$(sed -n 1p "$S/compacted")'"
[ "$(sed -n 1p "$S/resumed")" = idle ] \
  && ok "a resume still resets it" \
  || no "a resume still resets it" "got '$(sed -n 1p "$S/resumed")'"
# Unwritten, the prune in the same call deletes an hour-old file and the owner just recorded.
[ "$(sed -n 1p "$S/away" 2>/dev/null)" = idle ] && [ -e "$O/away" ] \
  && ok "an hour-old compaction resets, not pruned" \
  || no "an hour-old compaction resets, not pruned" "got '$(sed -n 1p "$S/away" 2>/dev/null)'"
[ "$(sed -n 1p "$S/unwritten" 2>/dev/null)" = idle ] \
  && ok "a compaction with no file writes one" \
  || no "a compaction with no file writes one" "missing"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
