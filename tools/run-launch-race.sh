#!/usr/bin/env bash
# cmd_up must launch exactly one overlay however many sessions start at once.
#
# Two distinct bugs live here and a harness that only covers one is worthless,
# because they are opposites and the naive fix for either can reintroduce the
# other:
#
#   SIMULTANEOUS  every caller's `pgrep -f "$BIN"` sees the OTHER callers'
#                 pgrep processes — whose own argv is the pattern — so all of
#                 them report "already running" and NONE launches. Silent: the
#                 user gets no pet and `pet.sh status` says `running`.
#   STAGGERED     callers offset by less than the time it takes the child to
#                 reach the process table each see nothing and each launch.
#                 Measured window on the machine this was written on: 4-16 ms.
#                 At 20 ms the first pet is already visible and the rest
#                 correctly stand down, so a stagger sweep that starts too
#                 coarse will report a green that means nothing.
#
# Nothing here can open a window: CLAUDE_CONFIG_DIR points at a scratch home and
# the binary is a stub. The stub is COMPILED rather than a shebang script on
# purpose — a script's argv is "/bin/bash <path>", which `pgrep -x -f "$BIN"`
# correctly refuses to match, so a script stub would be invisible to the very
# check under test and every assertion would pass for the wrong reason. It also
# has to OUTLIVE the run: a stub that exits immediately is never visible to
# `running()`, so every caller would legitimately launch one.
set -uo pipefail
cd "$(dirname "$0")/.."

# Overridable so the harness can be pointed at an older pet.sh and shown to
# FAIL. Ten green assertions prove nothing on their own — every one of them
# would also pass against a `running()` that always returned false — so the
# check that matters is:
#     git show <before>:scripts/pet.sh > /tmp/old.sh
#     PERCHLING_PET_SH=/tmp/old.sh bash tools/run-launch-race.sh
# which must fail. A copy outside the repo resolves $SRC to a pet.swift that
# does not exist, so cmd_up skips its rebuild branch exactly as it does here.
PET="${PERCHLING_PET_SH:-$PWD/scripts/pet.sh}"
SCRATCH="$(mktemp -d)"
trap 'pkill -x -f "$SCRATCH/.*/perchling" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

cat > "$SCRATCH/stub.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(void) {
    const char *log = getenv("STUB_LOG");
    if (log) { FILE *f = fopen(log, "a"); if (f) { fprintf(f, "launched pid=%d\n", getpid()); fclose(f); } }
    sleep(25);
    return 0;
}
C
cc -O0 -o "$SCRATCH/stub" "$SCRATCH/stub.c" || { echo "cannot compile the stub" >&2; exit 1; }

pass=0; fail=0
# $1 label  $2 callers  $3 stagger seconds  $4 expected launches
scenario() {
  local label="$1" n="$2" stag="$3" want="$4" i
  local home="$SCRATCH/$label" log
  mkdir -p "$home/perchling/bin"
  log="$home/launches.log"; : > "$log"
  cp "$SCRATCH/stub" "$home/perchling/bin/perchling"
  # Newer than pet.swift, so cmd_up skips its rebuild branch and never compiles.
  touch "$home/perchling/bin/perchling"
  for i in $(seq 1 "$n"); do
    CLAUDE_CONFIG_DIR="$home" STUB_LOG="$log" bash "$PET" up "sess$i" >/dev/null 2>&1 &
    [ "$stag" = 0 ] || sleep "$stag"
  done
  wait
  sleep 3
  local got; got=$(grep -c launched "$log" 2>/dev/null); got=${got:-0}
  if [ "$got" -eq "$want" ]; then
    printf '  ok   %-26s callers=%-3s stagger=%-6s launched=%s\n' "$label" "$n" "$stag" "$got"
    pass=$((pass + 1))
  else
    printf '  FAIL %-26s callers=%-3s stagger=%-6s launched=%s, want %s\n' "$label" "$n" "$stag" "$got" "$want"
    fail=$((fail + 1))
  fi
  pkill -x -f "$home/perchling/bin/perchling" 2>/dev/null
}

echo "launch race:"
scenario simultaneous       8 0     1
# Every offset inside the measured window, because a fix can close the top of it
# and leave the bottom open.
scenario staggered-4ms      4 0.004 1
scenario staggered-8ms      4 0.008 1
scenario staggered-12ms     4 0.012 1
scenario staggered-16ms     4 0.016 1
scenario staggered-20ms     4 0.020 1

# A pet that is already up must not be joined by another, which is the assertion
# that fails if someone "fixes" the race by always launching.
already_up() {
  local home="$SCRATCH/already-up" log i
  mkdir -p "$home/perchling/bin"
  log="$home/launches.log"; : > "$log"
  cp "$SCRATCH/stub" "$home/perchling/bin/perchling"
  touch "$home/perchling/bin/perchling"
  STUB_LOG="$log" "$home/perchling/bin/perchling" & sleep 0.5
  for i in $(seq 1 8); do
    CLAUDE_CONFIG_DIR="$home" STUB_LOG="$log" bash "$PET" up "s$i" >/dev/null 2>&1 &
  done
  wait; sleep 2
  local got; got=$(grep -c launched "$log" 2>/dev/null); got=${got:-0}
  if [ "$got" -eq 1 ]; then printf '  ok   %-26s 8 more calls added none\n' "already-running"; pass=$((pass + 1))
  else printf '  FAIL %-26s launched=%s, want 1\n' "already-running" "$got"; fail=$((fail + 1)); fi
  pkill -x -f "$home/perchling/bin/perchling" 2>/dev/null
}
already_up

# The lock must not be able to wedge startup forever, and must not be ignored
# while somebody is legitimately holding it. Both directions, or the TTL is
# indistinguishable from no lock at all.
lock_case() {
  local label="$1" age="$2" want="$3"
  local home="$SCRATCH/$label" log
  mkdir -p "$home/perchling/bin"
  log="$home/launches.log"; : > "$log"
  cp "$SCRATCH/stub" "$home/perchling/bin/perchling"
  touch "$home/perchling/bin/perchling"
  mkdir -p "$home/perchling/.launch.lock"
  [ -z "$age" ] || touch -t "$age" "$home/perchling/.launch.lock"
  CLAUDE_CONFIG_DIR="$home" STUB_LOG="$log" bash "$PET" up s1 >/dev/null 2>&1
  sleep 2
  local got; got=$(grep -c launched "$log" 2>/dev/null); got=${got:-0}
  if [ "$got" -eq "$want" ]; then printf '  ok   %-26s launched=%s\n' "$label" "$got"; pass=$((pass + 1))
  else printf '  FAIL %-26s launched=%s, want %s\n' "$label" "$got" "$want"; fail=$((fail + 1)); fi
  pkill -x -f "$home/perchling/bin/perchling" 2>/dev/null
}
lock_case stale-lock-is-stolen  202001010000 1
lock_case fresh-lock-is-honoured ""           0

# `running()` must not be satisfied by the probes themselves. Asserted directly,
# because every scenario above would also go green on a running() that simply
# always returned false.
#
# It pulls the REAL definition out of the pet.sh under test rather than
# restating it. A hardcoded `pgrep -x -f` here was the first version and it was
# worthless: it passed against the broken pet.sh too, because it was asserting
# its own text instead of the script's.
probe_selfmatch() {
  local out hits
  out=$(
    BIN="$SCRATCH/no-such-binary"
    eval "$(sed -n '/^running()/p' "$PET")"
    for _ in 1 2 3 4 5 6 7 8; do
      ( running && echo HIT || echo miss ) &
    done
    wait
  )
  hits=$(grep -c HIT <<<"$out"); hits=${hits:-0}
  # No process is running from that path, so every hit is one probe seeing another.
  if [ "$hits" -eq 0 ]; then printf '  ok   %-26s 8 concurrent running() calls, 0 false hits\n' "probe-self-match"; pass=$((pass + 1))
  else printf '  FAIL %-26s %s of 8 running() calls matched each other\n' "probe-self-match" "$hits"; fail=$((fail + 1)); fi
}
probe_selfmatch

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
