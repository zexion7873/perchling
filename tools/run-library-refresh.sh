#!/bin/bash
# cmd_up's library refresh: a picked shipped pet whose pets/ copy still matches
# its pick-time snapshot takes the current shipped bytes; everything else is
# left alone. Separate from run-prune-checks.sh, run-launch-race.sh and
# run-build-gate.sh for the reason those three are separate: a fourth unrelated
# property of the same function, and one file would make a failure ambiguous.
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
ok(){ printf '  ok   %-44s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no(){ printf '  FAIL %-44s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
ino(){ stat -f %i "$1" 2>/dev/null; }

mkdir -p "$W/scripts" "$W/examples" "$W/cfg/perchling/bin"
P="$W/cfg/perchling/pets"; SNAPS="$P/.shipped"
mkdir -p "$SNAPS"
cp "$PET_SH" "$W/scripts/pet.sh"
printf '#include <unistd.h>\nint main(void){ sleep(90); return 0; }\n' > "$W/stub.c"
cc -o "$W/cfg/perchling/bin/perchling" "$W/stub.c" 2>/dev/null || { echo "cc unavailable"; exit 1; }

# The binary must look current or cmd_up tries to build a pet.swift that is not
# beside the copied script.
printf 'let x = 1\n' > "$W/scripts/pet.swift"
touch -t 202608190100 "$W/scripts/pet.swift"
touch -t 202608190200 "$W/cfg/perchling/bin/perchling"

# The refresh compares bytes and never parses, so the fixtures are plain text.
printf 'shipped v1' > "$W/v1"
printf 'shipped v2' > "$W/v2"
printf 'hand-tuned' > "$W/edit"

# stale: copy == snapshot, shipped moved on — the headline case.
cp "$W/v1" "$P/stale.json";    cp "$W/v1" "$SNAPS/stale.json";    cp "$W/v2" "$W/examples/stale.json"
# edited: the user's own bytes; snapshot proves it, nothing may touch it.
cp "$W/edit" "$P/edited.json"; cp "$W/v1" "$SNAPS/edited.json";   cp "$W/v2" "$W/examples/edited.json"
# current: everything already agrees; a needless rewrite would repaint the pet.
cp "$W/v2" "$P/current.json";  cp "$W/v2" "$SNAPS/current.json";  cp "$W/v2" "$W/examples/current.json"
# healme: the kill-window state — copy refreshed, snapshot not yet.
cp "$W/v2" "$P/healme.json";   cp "$W/v1" "$SNAPS/healme.json";   cp "$W/v2" "$W/examples/healme.json"
# retired: shipped source gone; the copy may be someone's only one.
cp "$W/v1" "$P/retired.json";  cp "$W/v1" "$SNAPS/retired.json"
# ghost: a record whose pet is gone.
cp "$W/v1" "$SNAPS/ghost.json"
# norecord: a pick that predates the record — no proof, no refresh.
cp "$W/v1" "$P/norecord.json"; cp "$W/v2" "$W/examples/norecord.json"

edited_ino=$(ino "$P/edited.json")
current_ino=$(ino "$P/current.json")
current_snap_ino=$(ino "$SNAPS/current.json")
healme_ino=$(ino "$P/healme.json")

"$W/cfg/perchling/bin/perchling" & stub=$!
sleep 0.2
CLAUDE_CONFIG_DIR="$W/cfg" bash "$W/scripts/pet.sh" up refresh-test >/dev/null 2>&1
sleep 0.4

cmp -s "$P/stale.json" "$W/v2" \
  && ok "a pristine copy takes the shipped update" \
  || no "a pristine copy takes the shipped update" "still $(cat "$P/stale.json")"
cmp -s "$SNAPS/stale.json" "$W/v2" \
  && ok "and its snapshot follows" \
  || no "and its snapshot follows" "still $(cat "$SNAPS/stale.json")"

cmp -s "$P/edited.json" "$W/edit" \
  && ok "a hand-edited copy is never touched" \
  || no "a hand-edited copy is never touched" "clobbered to $(cat "$P/edited.json")"
[ "$(ino "$P/edited.json")" = "$edited_ino" ] \
  && ok "not even rewritten in place" \
  || no "not even rewritten in place" "inode moved"
cmp -s "$SNAPS/edited.json" "$W/v1" \
  && ok "and its pick-time record is kept as evidence" \
  || no "and its pick-time record is kept as evidence" "record changed"

[ "$(ino "$P/current.json")" = "$current_ino" ] && [ "$(ino "$SNAPS/current.json")" = "$current_snap_ino" ] \
  && ok "a current copy is not needlessly rewritten" \
  || no "a current copy is not needlessly rewritten" "an inode moved — pollPet repaints for nothing"

cmp -s "$SNAPS/healme.json" "$W/v2" \
  && ok "a refresh killed mid-way heals its snapshot" \
  || no "a refresh killed mid-way heals its snapshot" "still $(cat "$SNAPS/healme.json")"
[ "$(ino "$P/healme.json")" = "$healme_ino" ] \
  && ok "without rewriting the copy" \
  || no "without rewriting the copy" "inode moved"

cmp -s "$P/retired.json" "$W/v1" && [ -e "$SNAPS/retired.json" ] \
  && ok "a retired pet keeps both files" \
  || no "a retired pet keeps both files"

[ ! -e "$SNAPS/ghost.json" ] \
  && ok "a record whose pet is gone is pruned" \
  || no "a record whose pet is gone is pruned" "still there"

cmp -s "$P/norecord.json" "$W/v1" \
  && ok "a copy with no record stays frozen" \
  || no "a copy with no record stays frozen" "refreshed without proof"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
