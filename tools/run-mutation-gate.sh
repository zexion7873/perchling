#!/usr/bin/env bash
# The harnesses guard the code; this guards the harnesses. This repo has
# shipped green assertions that tested nothing at least four times, twice in
# one afternoon — so a CI that only runs the harnesses would have passed every
# one of those. Each case here generates a mutant from HEAD carrying a defect
# a harness exists to catch, and asserts the harness goes RED against it.
#
# Mutants are generated fresh with a textual replacement, never committed as
# copies (copies drift from HEAD silently). Two guards per case, both learned
# the hard way: the anchor must be FOUND (a replacement that matches nothing
# tests the clean tree and passes forever), and the output must DIFFER.
#
# Runs locally exactly as it runs in CI: bash tools/run-mutation-gate.sh
set -u
cd "$(dirname "$0")/.."

SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

pass=0; fail=0

mutate() { # mutate <src> <out> <old> <new>  -> 0 ok, 2 anchor missing
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import io, sys
src, out, old, new = sys.argv[1:5]
s = io.open(src, encoding="utf-8").read()
if old not in s: sys.exit(2)
io.open(out, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
}

gate() { # gate <name> <src> <envvar> <harness> <old> <new>
  local name="$1" src="$2" envvar="$3" harness="$4" old="$5" new="$6"
  local out="$SCRATCH/$name.${src##*.}"
  if ! mutate "$src" "$out" "$old" "$new"; then
    echo "FAIL $name: anchor not found in $src — this case is testing the clean tree"
    fail=$((fail + 1)); return
  fi
  if cmp -s "$src" "$out"; then
    echo "FAIL $name: mutation left $src unchanged"
    fail=$((fail + 1)); return
  fi
  env "$envvar=$out" bash "$harness" > "$SCRATCH/$name.log" 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL $name: $harness stayed GREEN against this mutant"
    sed 's/^/    /' "$SCRATCH/$name.log" | tail -5
    fail=$((fail + 1)); return
  fi
  # Exit 2 is this repo's "skipped, not run" convention. A harness that refused
  # to run proves nothing about the mutant — counting it as a catch is how the
  # first CI run passed mirror-without-consent on a runner where the pose
  # harness had skipped under Reduce Motion.
  if [ "$rc" -eq 2 ]; then
    echo "FAIL $name: $harness SKIPPED (exit 2) — nothing was tested"
    sed 's/^/    /' "$SCRATCH/$name.log" | tail -3
    fail=$((fail + 1)); return
  fi
  # A nonzero exit alone is not a catch: every harness's infra guard also
  # exits 1, before any assertion runs. A broken toolchain once turned all
  # nine harnesses into preflight deaths and this gate reported "10 caught,
  # 0 escaped". Count what came back, not what the exit code implies.
  local red; red=$(grep -c '^FAIL\|^  FAIL' "$SCRATCH/$name.log" 2>/dev/null)
  if [ "${red:-0}" -eq 0 ]; then
    echo "FAIL $name: $harness exited $rc with no red assertion — infra died before testing"
    sed 's/^/    /' "$SCRATCH/$name.log" | tail -5
    fail=$((fail + 1)); return
  fi
  echo "ok   $name (harness went red: $red assertions)"
  pass=$((pass + 1))
}

# --- shell layer (cheap, first) ----------------------------------------------

gate sid-shape-unchecked scripts/state.sh PERCHLING_STATE_SH tools/run-state-checks.sh \
  '  case "$sid" in '"''"'|*[!A-Za-z0-9_-]*) sid= ;; esac' \
  '  :'

gate prune-never-retires scripts/pet.sh PERCHLING_PET_SH tools/run-prune-checks.sh \
  '  find "$SESSIONS" -maxdepth 1 -type f -mmin +60 -exec rm -f {} + 2>/dev/null' \
  '  :'

gate rebuild-loop scripts/pet.sh PERCHLING_PET_SH tools/run-build-gate.sh \
  '  if { [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; } && { [ ! -s "$BUILDLOG" ] || [ ! "$BUILDLOG" -nt "$SRC" ]; }; then' \
  '  if { [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; }; then'

# The other direction on the same line: a gate that honours an EMPTY log as a
# recorded failure lets a compile killed midway (empty log newer than source)
# block every future rebuild, silently.
gate empty-log-blocks-rebuild scripts/pet.sh PERCHLING_PET_SH tools/run-build-gate.sh \
  '  if { [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; } && { [ ! -s "$BUILDLOG" ] || [ ! "$BUILDLOG" -nt "$SRC" ]; }; then' \
  '  if { [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; } && [ ! "$BUILDLOG" -nt "$SRC" ]; then'

# LAST-match sid extraction: a well-formed UUID inside a nested payload object
# takes the refcount filename from the real session. The shape check cannot
# see this — the ghost id is a perfectly shaped UUID — so only the routing
# assertion catches it.
gate sid-misrouted scripts/state.sh PERCHLING_STATE_SH tools/run-state-checks.sh \
  "    *'\"session_id\"'*) sid=\${payload#*'\"session_id\"'}; sid=\${sid#*'\"'}; sid=\${sid%%'\"'*} ;;" \
  "    *'\"session_id\"'*) sid=\$(printf '%s' \"\$payload\" | sed -n 's/.*\"session_id\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' | head -1) ;;"

# --- swift layer -------------------------------------------------------------

gate eyes-box-overflows scripts/pet.swift PERCHLING_PET_SWIFT tools/run-manifest-checks.sh \
  'b[0] <= dims.w - b[2], b[1] <= dims.h - b[3] else {' \
  'b[0] + b[2] <= dims.w, b[1] + b[3] <= dims.h else {'

# Without the palette guard, the CR/LF fixture is not "accepted": it traps in
# synthBlinkFrame (exit 133) — the byte fast path counted its row as 8 cells,
# the grapheme walk builds 7, and the eye box indexes the 8th.
gate crlf-palette-key scripts/pet.swift PERCHLING_PET_SWIFT tools/run-manifest-checks.sh \
  '        guard ch != "\r", ch != "\n" else {
            throw PetError("palette keys must not be CR/LF line-break characters")
        }' \
  '        _ = ch'

# Liveness decided from file mtime alone: an idle-but-open session (a long
# meeting) crosses the staleness cutoff beside a provably live owner, and the
# pet self-terminates 30 seconds later with only SessionStart able to bring
# it back.
gate live-owner-ignored scripts/pet.swift PERCHLING_PET_SWIFT tools/run-session-harness.sh \
  '            owners.insert(pid)
            live = true
            continue' \
  '            owners.insert(pid)'

# A clamp that never fires restores a saved origin onto a display that is no
# longer there — menu, tap and drag all unreachable.
gate stranded-restore-unclamped scripts/pet.swift PERCHLING_PET_SWIFT tools/run-session-harness.sh \
  '    guard !screens.contains(where: { $0.intersects(frame) }), let vf = home else { return nil }' \
  '    guard screens.isEmpty, let vf = home else { return nil }'

gate blank-frame-collapses scripts/pet.swift PERCHLING_PET_SWIFT tools/run-manifest-checks.sh \
  'frames.compactMap { $0.firstIndex { $0.contains { $0 != nil } } }.min()' \
  'frames.map { $0.firstIndex { $0.contains { $0 != nil } } ?? 0 }.min()'

gate rescue-swallowed scripts/pet.swift PERCHLING_PET_SWIFT tools/run-session-harness.sh \
  '    try migrateLoosePet(root: root)' \
  '    try? migrateLoosePet(root: root)'

gate nudge-never-fires scripts/pet.swift PERCHLING_PET_SWIFT tools/run-session-harness.sh \
  '    if wasLooking, nudged != display { return (true, display) }' \
  '    if false, nudged != display { return (true, display) }'

gate state-leash-unclamped scripts/pet.swift PERCHLING_PET_SWIFT tools/run-session-harness.sh \
  '        let ttl = min(moodTTL[s.mood] ?? 0, 300)' \
  '        let ttl = moodTTL[s.mood] ?? 0'

gate mirror-without-consent scripts/pet.swift PERCHLING_PET_SWIFT tools/run-pose-harness.sh \
  'flipped: s.mirror && dragFacingLeft)' \
  'flipped: dragFacingLeft)'

# --- the expensive one, last -------------------------------------------------
# launch-race is ~34s; every cheap case above has already reported by the time
# this starts. The mutant is the UNESCAPED pattern, not the missing -x: a raw
# path in a regex makes running() blind under `cfg+test (1)` — the + becomes a
# quantifier — so the regex-safe-path scenario reds deterministically. The -x
# removal was tried here first and ESCAPED: probe-self-match detects it only
# when two concurrent pgreps happen to overlap, and on the run that decided
# this comment, none did. A gate case that fails only sometimes teaches people
# to re-run the gate, which is worse than not having the case.

gate binre-unescaped scripts/pet.sh PERCHLING_PET_SH tools/run-launch-race.sh \
  "BIN_RE=\$(printf '%s' \"\$BIN\" | sed 's/[][(){}.*+?^\$|\\\\]/\\\\&/g')" \
  'BIN_RE="$BIN"'

# The self-match probe evals running() out of pet.sh by sed. A legitimate
# refactor that makes the body delegate to a helper leaves the extraction
# callable but blind — every probe exits 127 into a clean "miss", and the
# assertion scores 0 hits among 8 verdicts having run no pgrep. Only the
# positive control (a stub genuinely live at $BIN must produce a HIT) can go
# red here: the delegated running() works fine inside pet.sh itself, so every
# launch scenario stays green against this mutant.
gate running-delegated scripts/pet.sh PERCHLING_PET_SH tools/run-launch-race.sh \
  'running() { pgrep -x -f "$BIN_RE" >/dev/null 2>&1; }' \
  'running() { __rn; }
__rn() { pgrep -x -f "$BIN_RE" >/dev/null 2>&1; }'

echo "---"
echo "$pass mutants caught, $fail escaped"
[ "$fail" = 0 ]
