#!/bin/bash
# cmd_up's build gate: what a FAILED build is allowed to do to a working
# install. Takes PERCHLING_PET_SH so it can be pointed at a mutant and shown to
# FAIL — the only reason to believe any of the lines below.
#
# Every mtime here is set with `touch -t`, never by writing the file. The first
# version of this harness let `cc`, `touch` and swiftc land in the same second
# and `-nt` then answered differently run to run: three runs, three verdicts,
# none of them about the code.
set -u
PET_SH="${PERCHLING_PET_SH:-$(cd "$(dirname "$0")/.." && pwd)/scripts/pet.sh}"
W=$(mktemp -d)
stub=""
# `wait` inside the same redirect as the kill, or bash announces `Terminated`
# on its own stderr after the summary line and a green run reads like a crash.
cleanup() { [ -n "$stub" ] && { kill "$stub"; wait "$stub"; } 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
pass=0; fail=0
ok(){ printf '  ok   %-26s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no(){ printf '  FAIL %-26s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

mkdir -p "$W/scripts" "$W/cfg/perchling/bin"
cp "$PET_SH" "$W/scripts/pet.sh"
# Real Swift that really does not compile. A hand-written fake compiler is how
# two earlier checks in this repo shipped green against the wrong output shape.
printf 'let x: Int = "nope"\n' > "$W/scripts/pet.swift"
# Stands in for an already-built, already-running pet: COMPILED, so
# `pgrep -x -f` matches its argv; long-lived, so `running()` can see it; and
# deliberately not a copy of the real binary, which would open a pet window.
printf '#include <unistd.h>\nint main(void){ sleep(90); return 0; }\n' > "$W/stub.c"
cc -o "$W/cfg/perchling/bin/perchling" "$W/stub.c" 2>/dev/null || { echo "cc unavailable"; exit 1; }
BIN="$W/cfg/perchling/bin/perchling"
touch -t 202608190100 "$BIN"
touch -t 202608190200 "$W/scripts/pet.swift"
before=$(shasum "$BIN" | cut -d' ' -f1)

export CLAUDE_CONFIG_DIR="$W/cfg"
"$BIN" & stub=$!
sleep 0.2
bash "$W/scripts/pet.sh" up manual >/dev/null 2>&1
sleep 0.3
LOG="$W/cfg/perchling/build.log"

kill -0 "$stub" 2>/dev/null && ok "pet-survives-failed-build" "stub still alive" \
                            || no "pet-survives-failed-build" "a failed build took the pet off the screen"
[ "$before" = "$(shasum "$BIN" 2>/dev/null | cut -d' ' -f1)" ] \
  && ok "binary-untouched" "checksum unchanged" \
  || no "binary-untouched" "a failed build overwrote the live binary"
[ -s "$LOG" ] && ok "reason-recorded" "$(grep -c 'error:' "$LOG") compiler lines on disk" \
              || no "reason-recorded" "nothing explains the failure"
[ -z "$(ls "$W/cfg/perchling/bin"/.perchling.* 2>/dev/null)" ] \
  && ok "no-staging-debris" "staged output cleaned up" \
  || no "no-staging-debris" "a half-built binary was left in bin/"

s1=$(stat -f '%Fm' "$LOG" 2>/dev/null || echo 0)
bash "$W/scripts/pet.sh" up manual >/dev/null 2>&1
bash "$W/scripts/pet.sh" up manual >/dev/null 2>&1
s2=$(stat -f '%Fm' "$LOG" 2>/dev/null || echo 0)
[ "$s1" = "$s2" ] && ok "no-rebuild-loop" "two more starts did not re-run swiftc" \
                  || no "no-rebuild-loop" "every session start recompiles a source known to fail"

# --- what `status` reports as the reason --------------------------------------
#
# Finding the reason in a swiftc log is SUBTRACTION, not a pattern, and the
# argument for that was 580 words of prose with nothing exercising it. This is
# the missing fixture: a real log, captured from a real compile, not written by
# hand — a hand-written fake is how two earlier checks in this repo shipped
# green against an output shape the compiler never produces.
#
# tools/fixtures/swiftc-error.log is that log. Its LAST line is
# `1267 | // Four words of UI...`, so `tail -1` reports a comment. Three of its
# seven lines contain `error:` and two of those are excerpt lines — the quoted
# `moodTTL` row, which really does contain `.error: 3600`, and the caret line
# under the diagnostic.
#
# One of the three assertions below is a NEGATIVE CONTROL, and saying so is the
# point of writing them. Removing the ` | ` gutter filter from pet.sh changes no
# verdict here, and no log could be built where it does: swiftc emits NO
# warnings once it has an error, so the output is always one diagnostic followed
# by its own excerpt, and `grep -m1` therefore reaches the real message first.
# Every construction was tried — a warning sited on the `moodTTL` row so its
# excerpt would precede the error, twice, with different warning kinds — and the
# compiler printed no warning at all. So `reason-skips-the-excerpt` passes
# against a pet.sh with no gutter filter. `reason-is-not-the-last-line` and
# `reason-is-the-diagnostic` are the two that discriminate: both go red against
# a `tail -1` extraction.
R="$W/reason"; mkdir -p "$R/perchling"
cp "$(dirname "$0")/fixtures/swiftc-error.log" "$R/perchling/build.log"
line=$(CLAUDE_CONFIG_DIR="$R" bash "$W/scripts/pet.sh" status 2>/dev/null | grep '^build: ' || true)

case "$line" in
  *"cannot convert value of type 'String'"*)
    ok "reason-is-the-diagnostic" "status named the compiler's own message" ;;
  *) no "reason-is-the-diagnostic" "got: $line" ;;
esac
case "$line" in
  *moodTTL*) no "reason-skips-the-excerpt" "reported the quoted source line an unanchored grep finds" ;;
  *)         ok "reason-skips-the-excerpt" "the quoted moodTTL row did not win" ;;
esac
case "$line" in
  *"Four words of UI"*) no "reason-is-not-the-last-line" "reported what tail -1 would give" ;;
  *)                    ok "reason-is-not-the-last-line" "the log's last line did not win" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
