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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
