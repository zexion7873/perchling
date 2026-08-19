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
#                 The window is a property of the machine and it MOVES: catch
#                 rate against a naked TOCTOU, 6 runs each against two race-y
#                 scripts, was 4 ms 10/10, 8 ms 10/10, 12 ms 8/10, 16 ms 1/10,
#                 20 ms 0/10 — so its top now sits between 12 and 16 ms here,
#                 where an earlier comment claimed 16. Past the top the first
#                 pet is already visible and the rest correctly stand down, so
#                 those offsets pass against a broken script too and a sweep
#                 that starts too coarse reports a green that means nothing.
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
# FAIL. Green assertions prove nothing on their own — every one of them
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
# The three offsets inside the window, because a fix can close the top of it and
# leave the bottom open. 16 and 20 are kept as NEGATIVE controls: they assert
# correct behaviour but no longer discriminate, so they must not be counted as
# coverage — the summary line counts all thirteen, and only eleven of those
# are guarantees.
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
  # Wait on the CALLERS by pid, never bare. A bare `wait` also waits for the
  # stub above, which sleeps 25 seconds on purpose so it stays visible to
  # running() — so this one case cost 27 of the harness's 83 seconds while
  # measuring nothing during 25 of them.
  local pids=""
  for i in $(seq 1 8); do
    CLAUDE_CONFIG_DIR="$home" STUB_LOG="$log" bash "$PET" up "s$i" >/dev/null 2>&1 &
    pids="$pids $!"
  done
  wait $pids; sleep 2
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

# Reclaiming a stale lock is itself a critical section, and the two cases above
# cannot see that: both run a SINGLE caller, so the reclaim never contends with
# anything. Under concurrency every caller that finds the same stale lock runs
# its own reclaim, and the second one removes the FRESH lock the first has
# already taken — so the pet the first caller is still launching is joined by a
# second. This is the assertion the 1.13.0 fix shipped without.
stale_lock_race() {
  local home="$SCRATCH/stale-lock-race" log i
  mkdir -p "$home/perchling/bin"
  log="$home/launches.log"; : > "$log"
  cp "$SCRATCH/stub" "$home/perchling/bin/perchling"
  touch "$home/perchling/bin/perchling"
  mkdir -p "$home/perchling/.launch.lock"
  touch -t 202001010000 "$home/perchling/.launch.lock"
  for i in $(seq 1 8); do
    CLAUDE_CONFIG_DIR="$home" STUB_LOG="$log" bash "$PET" up "s$i" >/dev/null 2>&1 &
  done
  wait; sleep 3
  local got; got=$(grep -c launched "$log" 2>/dev/null); got=${got:-0}
  if [ "$got" -eq 1 ]; then printf '  ok   %-26s 8 callers, one reclaim, launched=1\n' "stale-lock-contended"; pass=$((pass + 1))
  else printf '  FAIL %-26s launched=%s, want 1\n' "stale-lock-contended" "$got"; fail=$((fail + 1)); fi
  pkill -x -f "$home/perchling/bin/perchling" 2>/dev/null
}
stale_lock_race

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
    # running() is not self-contained — it matches on a pattern the script
    # derives from $BIN — so the derivation is extracted too rather than
    # restated here, for the same reason the function itself is.
    eval "$(sed -n '/^BIN_RE=/p;/^running()/p' "$PET")"
    # Extracting a rule from the code under test needs a precondition check, or
    # it is the same failure the hardcoded version had, wearing a better
    # argument. This `sed` prints ONE line, so it only reconstructs a running()
    # that is written on one: a two-line body yields `running() {`, whose eval
    # is a parse error; an indented one or `function running {` matches nothing
    # and evals the empty string. All three leave `running` undefined, all 8
    # probes exit 127 and print `miss`, and this assertion reports "0 false
    # hits" having tested nothing at all. Four of the five ways to spell the
    # function disarm it that way, and a mutant carrying the released bug
    # reformatted onto two lines scored a clean 10 passed, three runs of three.
    # Asserting the name is callable closes every spelling; widening the sed
    # closes only the first.
    declare -F running >/dev/null 2>&1 || { echo NOTAFUNCTION; exit 0; }
    for _ in 1 2 3 4 5 6 7 8; do
      ( running && echo HIT || echo miss ) &
    done
    wait
  )
  if grep -q NOTAFUNCTION <<<"$out"; then
    printf '  FAIL %-26s no callable running() extracted from %s\n' "probe-self-match" "$PET"
    fail=$((fail + 1)); return
  fi
  # Every probe must come back with a verdict. `declare -F` above proves the
  # name exists; only this proves calling it does anything. Both times this
  # assertion has silently stopped testing, the cause was an extracted function
  # that could not RUN — first undefined, then referencing a variable the probe
  # had not set — and both times it scored a clean pass by counting zero hits
  # among zero verdicts.
  local verdicts; verdicts=$(grep -c -E '^(HIT|miss)$' <<<"$out"); verdicts=${verdicts:-0}
  if [ "$verdicts" -ne 8 ]; then
    printf '  FAIL %-26s %s of 8 probes returned a verdict — running() did not run\n' "probe-self-match" "$verdicts"
    fail=$((fail + 1)); return
  fi
  hits=$(grep -c HIT <<<"$out"); hits=${hits:-0}
  # No process is running from that path, so every hit is one probe seeing another.
  if [ "$hits" -eq 0 ]; then printf '  ok   %-26s 8 concurrent running() calls, 0 false hits\n' "probe-self-match"; pass=$((pass + 1))
  else printf '  FAIL %-26s %s of 8 running() calls matched each other\n' "probe-self-match" "$hits"; fail=$((fail + 1)); fi
}
probe_selfmatch

# `$BIN` is interpolated straight into a pgrep/pkill pattern, and those match a
# REGEX. A config directory the user named `cfg+test (1)` turns `+` into a
# quantifier and `(1)` into a group, so the pattern matches nothing at all —
# measured against a process genuinely running from such a path, `pgrep -x -f
# "$BIN"` reports NOT FOUND, and `running()` reports stopped beside a visible
# pet.
#
# This has to be the already-running shape, not the stampede one. A stampede
# cannot see the defect: the lock serialises the callers, the one holder spins
# out its full five seconds waiting for a pet running() will never admit to, and
# the other seven stand down against a lock that is genuinely fresh — exactly
# one launch, green, against the broken script. The damage lands BETWEEN session
# starts, where no lock is left to mask it. The first version of this assertion
# was the stampede and scored 13/13 against the mutant it was written to catch.
regex_home() {
  local home="$SCRATCH/cfg+test (1)" log i
  mkdir -p "$home/perchling/bin"
  log="$home/launches.log"; : > "$log"
  cp "$SCRATCH/stub" "$home/perchling/bin/perchling"
  touch "$home/perchling/bin/perchling"
  STUB_LOG="$log" "$home/perchling/bin/perchling" & sleep 0.5
  # Wait on the CALLERS by pid, never bare. A bare `wait` also waits for the
  # stub above, which sleeps 25 seconds on purpose so it stays visible to
  # running() — so this one case cost 27 of the harness's 83 seconds while
  # measuring nothing during 25 of them.
  local pids=""
  for i in $(seq 1 8); do
    CLAUDE_CONFIG_DIR="$home" STUB_LOG="$log" bash "$PET" up "s$i" >/dev/null 2>&1 &
    pids="$pids $!"
  done
  wait $pids; sleep 2
  local got; got=$(grep -c launched "$log" 2>/dev/null); got=${got:-0}
  if [ "$got" -eq 1 ]; then printf '  ok   %-26s metacharacters in the path, 8 calls added none\n' "regex-safe-path"; pass=$((pass + 1))
  else printf '  FAIL %-26s launched=%s, want 1 — running() cannot see the pet\n' "regex-safe-path" "$got"; fail=$((fail + 1)); fi
  pkill -x -f "$SCRATCH/.*/perchling" 2>/dev/null
}
regex_home

# `rmdir` refuses a non-empty directory. Nothing writes inside the lock, so this
# needs an outside cause — but a lock that cannot be reclaimed blocks every
# future launch FOREVER, which is the one failure the reclaim exists to prevent.
# Distinguishable from "the lock is honoured" only by the age: this one is
# stale, so it must be got out of the way rather than waited on.
wedged_lock() {
  local home="$SCRATCH/wedged-lock" log
  mkdir -p "$home/perchling/bin" "$home/perchling/.launch.lock"
  log="$home/launches.log"; : > "$log"
  cp "$SCRATCH/stub" "$home/perchling/bin/perchling"
  touch "$home/perchling/bin/perchling"
  touch "$home/perchling/.launch.lock/debris"
  touch -t 202001010000 "$home/perchling/.launch.lock"
  CLAUDE_CONFIG_DIR="$home" STUB_LOG="$log" bash "$PET" up s1 >/dev/null 2>&1
  sleep 2
  local got; got=$(grep -c launched "$log" 2>/dev/null); got=${got:-0}
  if [ "$got" -eq 1 ]; then printf '  ok   %-26s stale lock with a file in it, launched=1\n' "wedged-lock-cleared"; pass=$((pass + 1))
  else printf '  FAIL %-26s launched=%s, want 1\n' "wedged-lock-cleared" "$got"; fail=$((fail + 1)); fi
  pkill -x -f "$home/perchling/bin/perchling" 2>/dev/null
}
wedged_lock

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
