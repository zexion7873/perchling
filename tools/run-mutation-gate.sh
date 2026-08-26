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

# --- release manifests (cheapest of all, first) -------------------------------
# These run in milliseconds and guard the one line that actually reaches an
# install, so they report before anything compiles.

gate manifest-unparseable .claude-plugin/plugin.json PERCHLING_PLUGIN_JSON tools/run-release-checks.sh \
  '  "license": "MIT",' \
  '  "license": "MIT"'

# The anchor is the version line's SHAPE, so it survives every 1.x release and
# needs one edit at 2.0.0 — at which point mutate() reports "anchor not found"
# and this case fails loudly rather than passing against a clean tree.
gate version-goes-backwards .claude-plugin/plugin.json PERCHLING_PLUGIN_JSON tools/run-release-checks.sh \
  '"version": "1.' \
  '"version": "0.'

# plugin.json and marketplace.json carry two copies of one description, and
# they have drifted before: one promised half a megabyte while the other
# promised a megabyte. Nothing held them together until the check this reds.
gate description-drift .claude-plugin/marketplace.json PERCHLING_MARKETPLACE_JSON tools/run-release-checks.sh \
  'no Electron.' \
  'no Electron!'

# The six-space indent is LOAD-BEARING. `"name": "perchling"` occurs twice in
# marketplace.json and mutate() replaces only the first; the top-level one is
# never read by the harness, so the naive anchor leaves it 6 passed, 0 failed
# and this case reports a false "stayed GREEN".
gate name-drift .claude-plugin/marketplace.json PERCHLING_MARKETPLACE_JSON tools/run-release-checks.sh \
  '      "name": "perchling",' \
  '      "name": "perchling-pet",'

# version-goes-backwards cannot reach the semver regex: 0.16.0 satisfies it and
# reds the comparison instead. A leading zero is the shape that fails the regex
# while still comparing forward (01.16.0 parses as [1,16,0] >= [1,15,1]), so
# this is the only one of the five that discriminates that branch.
gate version-not-semver .claude-plugin/plugin.json PERCHLING_PLUGIN_JSON tools/run-release-checks.sh \
  '"version": "1.' \
  '"version": "01.'

# --- shell layer (cheap, first) ----------------------------------------------

gate sid-shape-unchecked scripts/state.sh PERCHLING_STATE_SH tools/run-state-checks.sh \
  '  case "$sid" in '"''"'|*[!A-Za-z0-9_-]*) sid= ;; esac' \
  '  :'

gate prune-never-retires scripts/pet.sh PERCHLING_PET_SH tools/run-prune-checks.sh \
  '  find "$SESSIONS" -maxdepth 1 -type f -mmin +60 -exec rm -f {} + 2>/dev/null' \
  '  :'

# cmd_up refuses on the same flag cmd_enable is there to clear, so an enable
# that stops clearing it prints its line, exits 0, and starts nothing — the
# exact "enable does nothing" report, with no error anywhere.
gate enable-honours-disabled scripts/pet.sh PERCHLING_PET_SH tools/run-toggle-checks.sh \
  '  rm -f "$ROOT/disabled"' \
  '  :'

# The guard, not the block: `  if [ -e "$ROOT/disabled" ]; then` occurs once
# (cmd_up spells its own test `[ -e "$ROOT/disabled" ] && exit 0`). Without it,
# wake writes the marker and reports success on an install the user turned off.
gate wake-ignores-disabled scripts/pet.sh PERCHLING_PET_SH tools/run-toggle-checks.sh \
  '  if [ -e "$ROOT/disabled" ]; then' \
  '  if false; then'

# The lie ac98cee removed, restored. cmd_up backgrounds the launch and exits, so
# a leaked fresh lock stops the pet with nobody able to see it; the only thing
# that can be right here is the wording, and nothing pinned it.
gate wake-claims-success scripts/pet.sh PERCHLING_PET_SH tools/run-toggle-checks.sh \
  "  echo \"perchling waking — 'pet.sh status' says whether it came up\"" \
  '  echo "perchling awake"'

# cmd_up is the only other thing that creates $ROOT and it starts with
# `macos || exit 0`, so on a fresh install `disable` announced success while its
# touch failed to stderr and the next session start launched the pet anyway.
gate disable-needs-no-home scripts/pet.sh PERCHLING_PET_SH tools/run-toggle-checks.sh \
  '  mkdir -p "$ROOT"
  touch "$ROOT/disabled"' \
  '  touch "$ROOT/disabled"'

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

# A refresh that never runs is the pre-record behaviour restored for every
# pet: picked copies frozen at pick time while the shipped art moves on —
# the exact user report (#103) this loop exists to close.
gate library-never-refreshed scripts/pet.sh PERCHLING_PET_SH tools/run-library-refresh.sh \
  '    cp "$src" "$ROOT/.pet.$$" 2>/dev/null && mv -f "$ROOT/.pet.$$" "$lib" 2>/dev/null &&
      cp "$src" "$ROOT/.snap.$$" 2>/dev/null && mv -f "$ROOT/.snap.$$" "$snap" 2>/dev/null' \
  '    :'

# The pristine guard is the one line between "refresh" and "clobber a
# hand-tuned pet" — the loss the whole snapshot mechanism exists to prevent,
# and removing it reads in review like simplifying a redundant cmp.
gate library-clobbers-edits scripts/pet.sh PERCHLING_PET_SH tools/run-library-refresh.sh \
  '    cmp -s "$lib" "$snap" || continue' \
  '    :'

# The heal arm is the kill-window insurance: without it a refresh killed
# between its two writes leaves copy != snapshot, which reads as a user edit,
# and that pet silently freezes forever.
gate library-heal-removed scripts/pet.sh PERCHLING_PET_SH tools/run-library-refresh.sh \
  '      cmp -s "$src" "$snap" || { cp "$src" "$ROOT/.snap.$$" 2>/dev/null && mv -f "$ROOT/.snap.$$" "$snap" 2>/dev/null; }' \
  '      :'

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

# The scale bounds, dropped: 0.9 and 4.1 then load fine, and the failure the
# range exists for — a pet scaled to nothing or to four screens — arrives with
# no error anywhere, on a value the author probably fat-fingered.
gate scale-range-unguarded scripts/pet.swift PERCHLING_PET_SWIFT tools/run-manifest-checks.sh \
  'guard let n = s as? Double, (1.0...4.0).contains(n) else {' \
  'guard let n = s as? Double else {'

# The report regressed to the Int() cast: --validate calls 1.4 "@1x", which is
# the one report an author has about their own scale, wrong by up to a third.
gate scale-report-truncated scripts/pet.swift PERCHLING_PET_SWIFT tools/run-manifest-checks.sh \
  '            let scaleText = pet.scale == pet.scale.rounded()
                ? "\(Int(pet.scale))" : "\(pet.scale)"' \
  '            let scaleText = "\(Int(pet.scale))"'

gate rescue-swallowed scripts/pet.swift PERCHLING_PET_SWIFT tools/run-session-harness.sh \
  '    try migrateLoosePet(root: root)' \
  '    try? migrateLoosePet(root: root)'

# An adopt that stops recording the pick-time bytes leaves cmd_up's refresh
# with no proof for any future pick — the machinery stays green while every
# new pick quietly re-ships the frozen-at-pick-time bug.
gate adopt-records-nothing scripts/pet.swift PERCHLING_PET_SWIFT tools/run-session-harness.sh \
  '        try? fm.copyItem(at: src, to: snap)' \
  '        _ = snap'

gate nudge-never-fires scripts/pet.swift PERCHLING_PET_SWIFT tools/run-session-harness.sh \
  '    if wasLooking, nudged != display { return (true, display) }' \
  '    if false, nudged != display { return (true, display) }'

gate state-leash-unclamped scripts/pet.swift PERCHLING_PET_SWIFT tools/run-session-harness.sh \
  '        let ttl = min(moodTTL[s.mood] ?? 0, 300)' \
  '        let ttl = moodTTL[s.mood] ?? 0'

gate mirror-without-consent scripts/pet.swift PERCHLING_PET_SWIFT tools/run-pose-harness.sh \
  'flipped: s.mirror && dragFacingLeft)' \
  'flipped: dragFacingLeft)'

# The unsorted walk: five defective moods, and an unsorted Dictionary picks a
# different one per process. The case asserts BOTH that eight runs agree and
# that they name `done`, the alphabetically first — agreement alone would let a
# lucky unsorted run pass.
gate moods-walk-unordered scripts/pet.swift PERCHLING_PET_SWIFT tools/run-manifest-checks.sh \
  'for (key, rows) in moodsRaw.sorted(by: { $0.key < $1.key }) {' \
  'for (key, rows) in moodsRaw {'

# No pet.json IS the built-in — removing the link is what `useBuiltIn` does — so
# the old behaviour described a healthy install as broken and put the format's
# only reference behind writing 460KB to disk first.
gate no-petjson-reports-broken scripts/pet.swift PERCHLING_PET_SWIFT tools/run-manifest-checks.sh \
  '        let useBuiltinText = argv.count < 3
            && (try? FileManager.default.attributesOfItem(atPath: installed.path)) == nil' \
  '        let useBuiltinText = false'

# The other direction on the same line. `fileExists` FOLLOWS the link, so a
# dangling pet.json reads as absent and gets answered with a cheerful OK about
# the built-in — a broken install reported as healthy.
gate dangling-petjson-masked scripts/pet.swift PERCHLING_PET_SWIFT tools/run-manifest-checks.sh \
  '(try? FileManager.default.attributesOfItem(atPath: installed.path)) == nil' \
  '!FileManager.default.fileExists(atPath: installed.path)'

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

# `rmdir` refuses a non-empty directory, and the rename is the only thing that
# clears one it refused. Without it a stale lock with anything inside it wedges
# startup permanently — the reclaim runs, the `rmdir` fails silently, the
# re-`mkdir` fails, and every future session start returns having launched
# nothing. Only wedged-lock-cleared reaches the fallback: every other scenario's
# lock is absent, fresh, or empty, and an empty one `rmdir`s fine. The
# replacement keeps the `2>/dev/null` because the line above ends in `&&` — the
# mutant has to stay a valid right-hand side, not merely a different string.
gate wedged-lock-never-cleared scripts/pet.sh PERCHLING_PET_SH tools/run-launch-race.sh \
  '      { rmdir "$lock" 2>/dev/null || mv "$lock" "$ROOT/.launch.wedged.$$" 2>/dev/null; }' \
  '      rmdir "$lock" 2>/dev/null'

echo "---"
echo "$pass mutants caught, $fail escaped"
[ "$fail" = 0 ]
