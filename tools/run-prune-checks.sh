#!/bin/bash
# cmd_up's housekeeping: what it removes from sessions/ and owners/, and what
# it must not. Separate from run-launch-race.sh (which is about launching
# exactly once) and run-build-gate.sh (about a failed build) because they are
# three unrelated properties of the same function and a single file would make
# a failure ambiguous.
#
# Takes PERCHLING_PET_SH so it can be pointed at a mutant and shown to FAIL.
# The stub is a compiled C binary that stays alive: cmd_up ends in launch_once,
# which spins for five seconds waiting for `running()` to see a process, and a
# stub that is a script or exits immediately is invisible to `pgrep -x -f`. It
# is deliberately NOT a copy of the real binary — that copy is an executable
# that stays alive by opening a pet window on the user's desktop.
set -uo pipefail
PET_SH="${PERCHLING_PET_SH:-$(cd "$(dirname "$0")/.." && pwd)/scripts/pet.sh}"

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

"$W/cfg/perchling/bin/perchling" & stub=$!
sleep 0.2
CLAUDE_CONFIG_DIR="$W/cfg" bash "$W/scripts/pet.sh" up newsession >/dev/null 2>&1
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
[ -e "$O/fresh" ] \
  && ok "a live session keeps its owner" \
  || no "a live session keeps its owner"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
