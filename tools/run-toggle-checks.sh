#!/usr/bin/env bash
# disable / enable / wake: the three commands that take the pet off the screen
# and put it back. A fourth property of a different pair of functions than the
# three cmd_up harnesses cover, so it is a fourth file for the same reason they
# are three — a failure here must name the toggle, not cmd_up.
#
# What is under test is the ORDER of two lines and one guard, and all three
# fail silently:
#   * cmd_up refuses outright while `disabled` exists, so cmd_enable's `rm -f`
#     has to land BEFORE its cmd_up or `enable` prints its line and starts
#     nothing.
#   * cmd_wake must refuse on a disabled install rather than becoming a
#     backdoor around `disable`.
#   * neither may claim an outcome it cannot see. cmd_up backgrounds the launch
#     and exits, so a leaked fresh lock stops the pet coming up with nobody the
#     wiser; the wording is what was fixed, and nothing pinned it.
#
# Nothing here can open a window. CLAUDE_CONFIG_DIR points at a scratch home
# whose binary is a compiled C stub — compiled rather than a shebang script
# because `pgrep -x -f "$BIN"` correctly refuses to match a script's
# `/bin/bash <path>` argv, and long-lived because a stub that exits is never
# visible to running(). It is deliberately NOT a copy of the real binary: that
# copy is an executable which stays alive by opening a pet on the desktop.
#
# The script under test is COPIED beside a dummy pet.swift, so $SRC is a file
# this harness owns. Pointed at the checkout in place, cmd_up's rebuild gate
# compares against a pet.swift somebody may be editing, and a save landing
# mid-run turns an assertion into a 30-second `swiftc -O`.
#
# Takes PERCHLING_PET_SH so it can be pointed at a mutant carrying exactly the
# defect each line is named after and shown to FAIL. That is the only reason to
# believe any of them:
#     git show <before>:scripts/pet.sh > /tmp/old.sh
#     PERCHLING_PET_SH=/tmp/old.sh bash tools/run-toggle-checks.sh
set -uo pipefail
PET_SH="${PERCHLING_PET_SH:-$(cd "$(dirname "$0")/.." && pwd)/scripts/pet.sh}"

W=$(mktemp -d) || exit 1
# Escaped the way pet.sh escapes $BIN, and for the same reason: pkill matches a
# REGEX, and a /var/folders temp name is not guaranteed to be free of the
# characters that are operators in one.
W_RE=$(printf '%s' "$W" | sed 's/[][(){}.*+?^$|\\]/\\&/g')
# The stubs cmd_up launches are nohup'd, so they are not this shell's children
# and outlive it by whatever is left of their sleep.
trap 'pkill -x -f "$W_RE/.*/perchling" 2>/dev/null; rm -rf "$W"' EXIT
pass=0; fail=0
ok(){ printf '  ok   %-34s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no(){ printf '  FAIL %-34s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# A missing script must die here rather than as two dozen red lines about
# nothing: the mutation gate scores a catch by counting red assertions, and
# infra death that spells itself FAIL is how a broken toolchain once reported
# "10 mutants caught".
[ -f "$PET_SH" ] || { echo "no pet.sh at $PET_SH" >&2; exit 1; }
mkdir -p "$W/scripts"
cp "$PET_SH" "$W/scripts/pet.sh" || exit 1
PET="$W/scripts/pet.sh"
printf 'let x = 1\n' > "$W/scripts/pet.swift"
cat > "$W/stub.c" <<'C'
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
cc -O0 -o "$W/stub" "$W/stub.c" 2>/dev/null || { echo "cannot compile the stub" >&2; exit 1; }

# Each case gets its own config dir: these commands exist to leave files
# behind, so a shared one would let an earlier case answer a later assertion.
# Both mtimes are fixed with `touch -t`, never by writing: letting `cc` and the
# dummy source land inside the same second makes `-nt` answer differently run
# to run, and the verdict is then about the machine rather than the code.
home() { # home <case> -> prints the config dir, stub already in place
  local h="$W/$1"
  mkdir -p "$h/perchling/bin" "$h/perchling/sessions" "$h/perchling/owners"
  cp "$W/stub" "$h/perchling/bin/perchling"
  touch -t 202608190100 "$W/scripts/pet.swift"
  touch -t 202608190200 "$h/perchling/bin/perchling"
  : > "$h/launches.log"
  printf '%s' "$h"
}

# Redirected to files rather than captured with $(…): cmd_up backgrounds
# launch_once, and a command substitution waits on every inherited descriptor —
# one unredirected child and the harness blocks for the stub's full 25 seconds.
RC=0
fire() { # fire <home> <subcommand>
  CLAUDE_CONFIG_DIR="$1" STUB_LOG="$1/launches.log" \
    bash "$PET" "$2" > "$1/out.txt" 2> "$1/err.txt"
  RC=$?
}
launched() { local n; n=$(grep -c launched "$1/launches.log" 2>/dev/null); printf '%s' "${n:-0}"; }
# `kill -0` cannot answer this: a stub the harness backgrounded stays a zombie
# after pkill until it is reaped, and a zombie accepts signal 0. The pid is
# exact where a pgrep pattern would be one more path this harness has to escape.
alive() { local st; st=$(ps -p "$1" -o state= 2>/dev/null | tr -d ' []+<>NLsw'); [ -n "$st" ] && [ "${st#Z}" = "$st" ]; }

echo "toggle:"

# --- enable, on an install that is actually disabled -------------------------
# The order of cmd_enable's two lines is the whole test. cmd_up's own
# `[ -e "$ROOT/disabled" ] && exit 0` fires before it does anything, so an
# enable that echoes and launches before clearing the flag prints its line,
# exits 0, leaves the flag set and starts nothing at all.
h=$(home enable)
touch "$h/perchling/disabled"
printf 'running\n/x\nlive' > "$h/perchling/sessions/live-one"
fire "$h" enable
sleep 2
[ ! -e "$h/perchling/disabled" ] \
  && ok "enable clears the flag" \
  || no "enable clears the flag" "disabled still there"
[ "$(launched "$h")" -eq 1 ] \
  && ok "and gets past cmd_up's own refusal" \
  || no "and gets past cmd_up's own refusal" "launched=$(launched "$h"), want 1"
[ -e "$h/perchling/sessions/manual" ] \
  && ok "leaving the manual bridge behind" \
  || no "leaving the manual bridge behind" "no sessions/manual"
# Not `stop`. A live session's refcount is not enable's to touch, and the
# session cannot restore it itself — state.sh is gated on the same flag, so
# nothing re-stamps until that session's next hook.
[ -e "$h/perchling/sessions/live-one" ] \
  && ok "a live refcount survives enable" \
  || no "a live refcount survives enable" "cmd_up deleted it"
grep -q 'pet.sh status' "$h/out.txt" \
  && ok "and it points at status" \
  || no "and it points at status" "said: $(head -1 "$h/out.txt")"

# --- wake must not be a way around disable -----------------------------------
h=$(home wake-disabled)
touch "$h/perchling/disabled"
fire "$h" wake
sleep 2
[ "$RC" -ne 0 ] \
  && ok "wake on a disabled install fails" \
  || no "wake on a disabled install fails" "exit 0"
[ ! -e "$h/perchling/wake" ] \
  && ok "and drops no wake marker" \
  || no "and drops no wake marker" "wrote the marker anyway"
[ -e "$h/perchling/disabled" ] \
  && ok "and does not clear the flag" \
  || no "and does not clear the flag" "wake undid disable"
# The refusal is a diagnostic, not the success line. Anything reading stdout to
# find out what happened must come away with nothing.
[ ! -s "$h/out.txt" ] && [ -s "$h/err.txt" ] \
  && ok "refusing on stderr, stdout empty" \
  || no "refusing on stderr, stdout empty" "out='$(head -1 "$h/out.txt")' err='$(head -1 "$h/err.txt")'"
# NEGATIVE CONTROL: cmd_up refuses on the same flag, so this stays green even
# with cmd_wake's guard deleted. It is here to bound the damage, not to cover it.
[ "$(launched "$h")" -eq 0 ] \
  && ok "and starts nothing (neg. control)" \
  || no "and starts nothing (neg. control)" "launched=$(launched "$h")"

# --- wake with nothing running -----------------------------------------------
h=$(home wake-cold)
fire "$h" wake
sleep 2
[ -e "$h/perchling/wake" ] \
  && ok "wake drops the marker" \
  || no "wake drops the marker" "no wake file"
[ "$(launched "$h")" -eq 1 ] \
  && ok "and starts the pet when none is up" \
  || no "and starts the pet when none is up" "launched=$(launched "$h"), want 1"
[ -e "$h/perchling/sessions/manual" ] \
  && ok "with the manual bridge to hold it" \
  || no "with the manual bridge to hold it" "no sessions/manual"
[ "$RC" -eq 0 ] \
  && ok "exit 0" \
  || no "exit 0" "exit $RC"

# --- wake with a pet already on screen ---------------------------------------
# The marker is the point: a TUCKED pet is running and has no window to
# right-click, so wake's whole job here is to leave the file the render loop
# polls for. NEGATIVE CONTROL on the count — dropping cmd_wake's `running ||`
# short-circuit does not add a pet either, because launch_once checks running()
# again inside the lock. It pins the observable a "wake restarts the pet" change
# would break, and nothing finer.
h=$(home wake-hot)
# disowned so bash does not print a "Terminated" job notice into the middle of
# the assertions when this stub is killed; alive() reads ps, not the jobs table.
STUB_LOG="$h/launches.log" "$h/perchling/bin/perchling" >/dev/null 2>&1 & hot=$!
disown "$hot" 2>/dev/null
sleep 0.5
fire "$h" wake
sleep 2
[ -e "$h/perchling/wake" ] \
  && ok "a tucked pet still gets its marker" \
  || no "a tucked pet still gets its marker" "no wake file"
[ "$(launched "$h")" -eq 1 ] \
  && ok "and no second pet (neg. control)" \
  || no "and no second pet (neg. control)" "launched=$(launched "$h"), want 1"
kill "$hot" 2>/dev/null

# --- the leaked fresh lock ---------------------------------------------------
# Recorded finding, and this pins the shape of the answer rather than a fix.
# A lock younger than a minute is honoured for its full minute, so launch_once
# returns without launching; cmd_up backgrounds it and exits 0, so nothing
# upstream can see that. Reporting the truth would mean cmd_up not exiting,
# which is the one thing the SessionStart hook needs it to do. So the contract
# is the WORDING: say what was asked for, and name the command that knows.
h=$(home wake-locked)
mkdir "$h/perchling/.launch.lock"
fire "$h" wake
sleep 2
[ "$(launched "$h")" -eq 0 ] \
  && ok "a fresh lock stops the launch" \
  || no "a fresh lock stops the launch" "launched=$(launched "$h"), want 0"
[ "$RC" -eq 0 ] \
  && ok "and wake cannot tell, so exits 0" \
  || no "and wake cannot tell, so exits 0" "exit $RC"
grep -q 'pet.sh status' "$h/out.txt" \
  && ok "so it claims intent, not outcome" \
  || no "so it claims intent, not outcome" "said: $(head -1 "$h/out.txt")"

# --- disable, and the round trip back ----------------------------------------
# enable only means anything against a disable that meant it, so the pair is
# one case. disable is `stop` minus the refcounts on purpose: it takes the pet
# off the screen and leaves the session list for enable to come back to.
h=$(home disable)
STUB_LOG="$h/launches.log" "$h/perchling/bin/perchling" >/dev/null 2>&1 & hot=$!
disown "$hot" 2>/dev/null
sleep 0.5
printf 'running\n/x\nlive' > "$h/perchling/sessions/live-one"
fire "$h" disable
sleep 1
[ -e "$h/perchling/disabled" ] \
  && ok "disable sets the flag" \
  || no "disable sets the flag" "no flag file"
alive "$hot" \
  && no "and takes the pet off the screen" "the stub is still running" \
  || ok "and takes the pet off the screen"
[ -e "$h/perchling/sessions/live-one" ] \
  && ok "but leaves the refcounts to stop" \
  || no "but leaves the refcounts to stop" "disable deleted a live refcount"
# Never waited on: a disable that failed to kill leaves a stub with 25 seconds
# still to sleep, and a bare `wait` would turn that FAIL into a hang.
kill "$hot" 2>/dev/null
fire "$h" enable
sleep 2
[ "$(launched "$h")" -eq 2 ] \
  && ok "and enable brings one back" \
  || no "and enable brings one back" "launched=$(launched "$h"), want 2"

# --- the dispatch ------------------------------------------------------------
# A mistyped subcommand must be inert. `pet.sh` with no argument at all is
# `status`, so the fall-through arm is the only thing standing between a typo
# and whatever the next-nearest behaviour happens to be.
h=$(home typo)
fire "$h" wke
sleep 1
[ "$RC" -eq 2 ] \
  && ok "an unknown subcommand exits 2" \
  || no "an unknown subcommand exits 2" "exit $RC"
grep -q '^usage:' "$h/err.txt" \
  && ok "with the usage line on stderr" \
  || no "with the usage line on stderr" "err='$(head -1 "$h/err.txt")'"
[ "$(launched "$h")" -eq 0 ] && [ ! -e "$h/perchling/wake" ] && [ ! -e "$h/perchling/disabled" ] \
  && ok "and changes nothing" \
  || no "and changes nothing" "launched=$(launched "$h")"

# --- and it has to mean it on an install that has never run -------------------
#
# `disable` is the command someone reaches for when they want the pet GONE, and
# on a fresh install it used to print its success line while `touch` failed to
# stderr and nothing was written: the next session start launched a pet the user
# had just disabled. cmd_up is the only other thing that creates $ROOT, and its
# first line is `macos || exit 0`, so "the home does not exist yet" is the
# ordinary state before a Mac session has started, not a corner.
for pair in disable:disabled wake:wake; do
  cold=${pair%%:*}; flag=${pair#*:}
  h="$W/cold-$cold"; mkdir -p "$h"
  CLAUDE_CONFIG_DIR="$h" bash "$PET_SH" "$cold" >/dev/null 2>&1
  [ -e "$h/perchling/$flag" ] \
    && ok "$cold means it on a fresh install" \
    || no "$cold means it on a fresh install" "no runtime home, no flag, and it said yes"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
