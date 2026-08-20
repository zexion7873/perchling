#!/bin/bash
# perchling control script: build, session refcounting, launch, teardown.
# Runtime home (binary, state, session refcounts) lives outside the plugin
# directory because the plugin path changes on every update.
set -u

ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/perchling"
SRC="$(cd "$(dirname "$0")" && pwd)/pet.swift"
EXAMPLES="$(cd "$(dirname "$0")/.." && pwd)/examples"
# The built-in's art is a file now, not 449KB compiled into the binary, and
# WHICH shipped pet it is comes from a name rather than a path — so changing the
# default creature is this one line, and no file moves. The menu follows on its
# own: petChoices hides whichever shipped pet matches builtinPet.name, so the
# new built-in leaves the list and the old one joins it.
BUILTIN_PET="${PERCHLING_BUILTIN:-husky}"
BUILTIN_SRC="$EXAMPLES/$BUILTIN_PET.json"
# Copied into the runtime home rather than read from the plugin directory, so an
# overlay launched by hand — with no idea which plugin started it — still finds
# its art. Same reason the binary is compiled to there: the plugin path carries
# a version and is replaced wholesale on update.
BUILTIN="$ROOT/builtin.json"
BIN="$ROOT/bin/perchling"
# pgrep and pkill match a REGEX, never a literal, so every metacharacter in this
# path is an operator. A config directory called `cfg+test (1)` makes `+` a
# quantifier and `(1)` a group, and the pattern then matches nothing: measured
# against a process genuinely running from that path, `pgrep -x -f "$BIN"`
# reports NOT FOUND. Both halves of the script break at once and neither says
# so — `running()` reports stopped beside a visible pet, so every session start
# launches another one, and all three `pkill` sites match nothing, so `stop`
# and `disable` stop nothing. Escaped once here rather than at each of the four
# uses. Matching literally with `ps -Awwo args= | grep -qxF` was the runner-up
# and removes the whole class of bug rather than escaping it, but it costs
# 33.9ms against pgrep's 20.7 per call, and `running()` is polled up to 50
# times per launch.
BIN_RE=$(printf '%s' "$BIN" | sed 's/[][(){}.*+?^$|\\]/\\&/g')
SESSIONS="$ROOT/sessions"
OWNERS="$ROOT/owners"
BUILDLOG="$ROOT/build.log"

payload=""

read_payload() {
  # Hook payload arrives as one JSON blob on stdin. The harness keeps the pipe
  # open after writing, so never read until EOF — dd does exactly one read()
  # and returns whatever the first write delivered. No jq dependency.
  # A terminal is not a hook. `up` and `down` are both in the usage line, and
  # dd on a tty blocks until the user types EOF — which reads as a hang with no
  # output at all, from a command whose whole job is to return immediately.
  if [ -t 0 ]; then return 0; fi
  payload=$(dd bs=65536 count=1 2>/dev/null)
}

payload_field() {
  printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# The one payload field that becomes a FILENAME, so the only one whose shape
# has to be checked — this value reaches `mv -f "$ROOT/.up.$$"
# "$SESSIONS/$sid"` and `rm -f "$SESSIONS/$sid" "$OWNERS/$sid"`, where
# `../../../evil` resolves three levels above the sessions directory. Unlike
# the cosmetic fields it also takes the FIRST match, not payload_field's LAST:
# the CLI writes its own session_id as the leading key and everything an
# embedded object carries serialises after it, so the last match let a nested
# UUID become the refcount filename (state.sh had the same bug; the two
# extractions stay mirrored). Real ids are UUIDs. An id that fails the shape
# test yields nothing, and cmd_up's own `|| sid="manual"` then covers it: a
# launch with no usable session behind it is exactly what the manual bridge is
# for, where a sanitised id would still name a file the payload picked.
payload_sid() {
  case "$payload" in
    *'"session_id"'*) sid_raw=${payload#*'"session_id"'}; sid_raw=${sid_raw#*'"'}; sid_raw=${sid_raw%%'"'*} ;;
    *) return 0 ;;
  esac
  case "$sid_raw" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  printf '%s' "$sid_raw"
}

# The outermost process this session hangs off — Claude desktop for a session
# started there, the terminal app for one started from a shell. Its death is
# the one end-of-session signal a missing SessionEnd cannot swallow. One ps,
# walked in awk; printing our own pid means the walk found nothing to climb.
session_owner() {
  ps -Ao pid=,ppid= | awk -v p=$$ '{pp[$1]=$2} END {while (pp[p] && pp[p] != 1) p = pp[p]; print p}'
}

macos() { [ "$(uname)" = Darwin ]; }
# Run the compiler rather than locating it: /usr/bin/swiftc is a stub macOS
# ships whether or not a toolchain is installed, so `command -v` succeeds on
# exactly the machine this guard exists to reject. The probe costs an exec, so
# only the build path pays it — a session start on a machine whose toolchain
# went missing must still launch a binary that is already built. Its output is
# held and re-emitted only as a reason: an unaccepted Xcode licence fails this
# probe too and only the compiler's own words tell that apart from an absent
# toolchain, but `--version` also writes an unterminated driver banner to
# stderr when it SUCCEEDS — and this function's stderr is the build log, so
# passing it through fuses `swift-driver version: …` onto the first diagnostic.
supported() {
  macos || return 1
  probe=$(swiftc --version 2>&1 >/dev/null) && return 0
  [ -n "$probe" ] && printf '%s\n' "$probe" >&2
  return 1
}
# `-x` is load-bearing, not tidiness. Without it `pgrep -f "$BIN"` matches any
# process whose argv merely CONTAINS the path — including the other concurrent
# `pgrep -f "$BIN"` probes, whose own argv is the pattern. Measured with eight
# simultaneous probes against a path no process was running from: all eight
# reported a hit. So several sessions starting at once could each conclude the
# pet was already up and none would launch it, which is the silent inverse of
# the duplicate-pet race launch_once exists for. `-x` requires the whole argv to
# equal "$BIN", which the overlay's does (it is exec'd as `nohup "$BIN"`) and a
# probe's never can.
running() { pgrep -x -f "$BIN_RE" >/dev/null 2>&1; }

# Serialises the check-and-launch. `mkdir` is the atomic primitive available —
# macOS ships no flock(1) — and two details are what make it work:
#
#   * The lock is held until the new process is VISIBLE to running(), not merely
#     until nohup returns. Releasing at spawn time only narrows the window: the
#     next holder's pgrep still runs before the child reaches the process table,
#     sees nothing, and launches a second pet.
#   * A lock left behind by a process killed mid-launch would block every future
#     session start forever, so it is reclaimed once it is older than any launch
#     could legitimately take.
#
# A caller that loses the race returns without launching rather than waiting:
# cmd_up runs on every SessionStart, so a launch that genuinely failed is
# retried by the next session rather than by blocking this one.
#
# Reclaiming is a critical section of its own, and 1.13.0 shipped treating it as
# a plain check-then-act: `[ stale ] && rmdir` ran in EVERY caller that found the
# same stale lock, so the second rmdir removed the FRESH lock the first had just
# taken, and so on down the line. Instrumented at 8 concurrent callers: four
# reclaimed in a chain and four pets launched.
#
# Making the reclaim itself atomic does not fix it, which is worth stating
# because it is the obvious repair and it was measured failing. `rmdir` really
# is an exclusive claim — of N callers only one can remove a given directory —
# but the verdict it acts on comes from a `find`, and a fork+exec is milliseconds
# during which somebody else reclaims and takes the lock. The stale verdict is
# then correct about a directory that no longer exists at that path. That
# version still launched four pets.
#
# So the reclaim gets a lock, and the freshness test is REPEATED inside it: a
# caller that arrives while another is reclaiming must judge the lock that
# caller took, not the one it saw on the way in. Everything above the reclaim
# stays as it was — the outer test is what keeps this second lock off the
# ordinary contended path, where it would be taken on every simultaneous session
# start rather than only after a mid-launch kill.
#
# The reclaim lock expires too, or a caller killed inside those few milliseconds
# would wedge reclaim forever — the exact failure the reclaim exists to clear,
# one level up. An hour, not a minute: nothing inside that section blocks, so an
# hour-old reclaim lock provably has no live holder, where a minute-old launch
# lock only probably has none. Clearing it is a check-then-act like the one
# above and can let two callers reclaim at once; it takes a stale launch lock AND
# an hour-stale reclaim lock AND an unlucky interleaving to reach, it costs one
# extra pet when it does, and the next session start leaves both locks clean.
launch_once() {
  lock="$ROOT/.launch.lock"
  reclaim="$ROOT/.launch.reclaim"
  if ! mkdir "$lock" 2>/dev/null; then
    # Held. Non-empty output means the lock was created within the minute, so
    # somebody is legitimately inside the section and this caller stands down.
    [ -n "$(find "$lock" -maxdepth 0 -mmin -1 2>/dev/null)" ] && return 0
    [ -d "$reclaim" ] && [ -z "$(find "$reclaim" -maxdepth 0 -mmin -60 2>/dev/null)" ] && rmdir "$reclaim" 2>/dev/null
    mkdir "$reclaim" 2>/dev/null || return 0
    # `rmdir` refuses a non-empty directory, and nothing else here clears the
    # lock, so anything that ever lands inside it wedges every future launch
    # permanently. Nothing writes in there, so this needs an outside cause —
    # which is exactly the kind of thing a lock has to survive. Renaming works
    # on a non-empty directory and is one syscall; `rm -rf` on a path built
    # from an environment variable is not something this script should own, and
    # the debris is inspectable rather than gone.
    [ -z "$(find "$lock" -maxdepth 0 -mmin -1 2>/dev/null)" ] &&
      { rmdir "$lock" 2>/dev/null || mv "$lock" "$ROOT/.launch.wedged.$$" 2>/dev/null; }
    rmdir "$reclaim" 2>/dev/null
    mkdir "$lock" 2>/dev/null || return 0
  fi
  # INT/TERM exit rather than clean up: bash RESUMES the interrupted command
  # list after a signal trap returns, so a handler that removed the lock would
  # free it while this critical section keeps running — a concurrent
  # SessionStart takes it, and the resumed trailing rmdir below then deletes
  # THAT caller's fresh lock (reproduced on /bin/bash 3.2). Exiting from the
  # handler fires the EXIT trap, which cleans up exactly once.
  trap 'rmdir "$lock" 2>/dev/null' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! running; then
    PERCHLING_HOME="$ROOT" PERCHLING_EXAMPLES="$EXAMPLES" nohup "$BIN" </dev/null >/dev/null 2>&1 &
    waited=0
    while [ "$waited" -lt 50 ] && ! running; do sleep 0.1; waited=$((waited + 1)); done
  fi
  rmdir "$lock" 2>/dev/null
  trap - EXIT INT TERM
}

compile() {
  supported || { echo "perchling needs macOS with a working Swift toolchain (xcode-select --install)" >&2; return 1; }
  mkdir -p "$ROOT/bin"
  # Staged and renamed, like every other file this script publishes. Pointing
  # swiftc straight at $BIN makes a failed or interrupted compile leave a
  # truncated 0755 file with an mtime newer than $SRC — which is precisely what
  # the rebuild gate reads as "current", so nothing ever rebuilds it, `status`
  # calls it `(built)`, and the install is wedged with no way back short of
  # deleting the file by hand.
  #
  # The staging name carries $$ instead of taking a lock. Concurrent session
  # starts after a plugin update then each compile their own copy of the same
  # source and the last rename wins, which is harmless because they are the
  # same binary; a lock would be a second wedgeable mutex bought to save CPU in
  # a window that opens once per release.
  stage="$ROOT/bin/.perchling.$$"
  swiftc -O -o "$stage" "$SRC" || { rm -f "$stage"; return 1; }
  # rename() over a RUNNING executable succeeds where a write returns ETXTBSY:
  # the live process keeps the old inode. That is what lets cmd_up build first
  # and retire the old pet only once there is something better to replace it.
  mv -f "$stage" "$BIN"
}

# The log belongs to the build, not to whoever called it: every build writes
# the current reason or removes a superseded one, so status can never report a
# failure a later build already answered. A caller-side redirect cannot do
# this — it holds the file open, so a `rm` inside would unlink the very inode
# the reason is still being written to.
cmd_build() {
  mkdir -p "$ROOT"
  # Staged like everything else this script publishes, and for a sharper
  # reason than tidiness: redirecting straight at $BUILDLOG creates the
  # failure marker the moment compilation STARTS, so a compile killed midway
  # (Ctrl-C, the 30s SessionStart hook timeout on a cold machine) left an
  # empty log newer than $SRC — which the rebuild gate read as "already tried,
  # don't retry", silently, with nothing for status to show. A kill lands
  # before the mv and leaves $BUILDLOG exactly as it was.
  compile 2>"$ROOT/.buildlog.$$"
  rc=$?
  # Whatever the compiler said reaches a human either way — warnings on a build
  # that SUCCEEDED are most of the value of running this by hand, and capturing
  # them to a file that is about to be removed would silently eat them. Only a
  # failure stays on disk, because that file is what status reports.
  cat "$ROOT/.buildlog.$$" >&2
  if [ "$rc" -eq 0 ]; then
    rm -f "$ROOT/.buildlog.$$" "$BUILDLOG"
    echo "built: $BIN"
  else
    # A failure that said nothing (an OOM-killed swiftc) must still leave a
    # non-empty reason: the rebuild gate honours only a non-empty log, so an
    # empty one would re-burn a full compile on every session start.
    [ -s "$ROOT/.buildlog.$$" ] || echo "build failed with no compiler output (exit $rc)" > "$ROOT/.buildlog.$$"
    mv -f "$ROOT/.buildlog.$$" "$BUILDLOG" 2>/dev/null
    return "$rc"
  fi
}

cmd_up() {
  macos || exit 0
  [ -e "$ROOT/disabled" ] && exit 0
  mkdir -p "$SESSIONS"
  sid="${1:-}"
  cwd=""
  if [ -z "$sid" ]; then
    read_payload
    sid="$(payload_sid)"
    cwd="$(payload_field cwd)"
  fi
  [ -n "$sid" ] || sid="manual"
  # Write a fresh neutral mood, never bare-touch: the file's content is the
  # session's mood now, and touching a stale waiting/error would resurrect it
  # with a full TTL on session resume.
  # A session that has started but not been prompted yet would otherwise be an
  # unlabelled row — which for a resumed session sitting idle lasts as long as
  # it sits. cmd_up called with an explicit sid (manual, enable, wake) has no
  # payload and writes the one-line form, which stays valid forever.
  if [ -n "$cwd" ]; then
    printf 'idle\n%s' "$cwd" > "$ROOT/.up.$$" 2>/dev/null
  else
    printf idle > "$ROOT/.up.$$" 2>/dev/null
  fi && mv -f "$ROOT/.up.$$" "$SESSIONS/$sid" 2>/dev/null
  # "manual" is a bridge for launches with no session behind them (enable,
  # wake, an unparseable payload). A real session supersedes it, and nothing
  # else ever deletes it — left alone it holds an idle pet up for the whole
  # staleness hour after the last session ends.
  [ "$sid" = manual ] || rm -f "$SESSIONS/manual" "$OWNERS/manual"
  # Record the owner before the pet can look for it. An unclimbable tree
  # leaves no file rather than a bad one: the pet reads a missing owner as
  # "unknown, fall back to staleness", and a wrong pid as gospel.
  mkdir -p "$OWNERS"
  owner="$(session_owner)"
  if [ -n "$owner" ] && [ "$owner" != "$$" ]; then
    printf '%s' "$owner" > "$ROOT/.own.$$" 2>/dev/null && mv -f "$ROOT/.own.$$" "$OWNERS/$sid" 2>/dev/null
  else
    rm -f "$OWNERS/$sid"
  fi
  # Removal is NOT symmetric on its own, which is the case the owner machinery
  # exists for: a force-quit fires no SessionEnd, so cmd_down never runs, and
  # the loop below then prunes owners/<sid> while sessions/<sid> stays forever.
  # Nothing in the renderer deletes one either — liveSessions and pollSessions
  # compute the staleness predicate and use it only to HIDE. Left alone that
  # retains up to 300 bytes of prompt or reply text per abnormally-ended
  # session indefinitely, and makes `pet.sh status` over-report.
  #
  # The window is the renderer's own hour, so this removes nothing that was
  # still being shown: liveSessions requires the stamp to be inside the cutoff
  # REGARDLESS of whether the owner is alive, so a session too stale to draw is
  # too stale to keep. A session that is genuinely still alive re-announces
  # itself on its next hook. Runs at SessionStart only, never on the hot path,
  # so one `find` is affordable here in a way it would not be in state.sh.
  find "$SESSIONS" -maxdepth 1 -type f -mmin +60 -exec rm -f {} + 2>/dev/null
  # An owner file whose session is already gone is the same leak the manual
  # lease was, one directory over. It runs AFTER the prune above, so a session
  # retired for staleness takes its owner with it and the pair stays matched
  # without this loop needing to know the cutoff.
  for f in "$OWNERS"/*; do
    [ -e "$f" ] || continue
    [ -e "$SESSIONS/${f##*/}" ] || rm -f "$f"
  done
  # Staged through a temp name: the overlay reads this file once at launch, and
  # a launch landing mid-copy would fall back to the placeholder and look like a
  # broken install. Silent because a missing shipped file is survivable — the
  # placeholder is exactly what it is for.
  # Compared by CONTENT, not by mtime. Switching which pet is the built-in
  # points this at a different file that may well be OLDER than the copy already
  # in place, and an mtime test would then decline to update — the swap would
  # silently do nothing. `cmp` also answers "missing" and "changed" in the same
  # breath, so there is one predicate rather than three.
  if [ -f "$BUILTIN_SRC" ] && ! cmp -s "$BUILTIN_SRC" "$BUILTIN"; then
    cp "$BUILTIN_SRC" "$ROOT/.builtin.$$" 2>/dev/null && mv -f "$ROOT/.builtin.$$" "$BUILTIN" 2>/dev/null
  fi
  # (Re)build when missing or when a plugin update shipped newer source —
  # unless this exact source has already been tried and failed, which a
  # $BUILDLOG newer than $SRC records. Without that arm, source that compiles
  # for the author and not on this machine (an SDK bump, a Swift bump) burns a
  # full `swiftc -O` of the whole app inside the 30s hook timeout on EVERY
  # session start, forever, and still ends with no pet. Nothing else on disk
  # can stop that loop: the gate below reads only the exec bit and an mtime,
  # and neither of them moves when a build fails.
  # Only a NON-EMPTY log is a recorded failure: cmd_build stages the log and
  # publishes it whole, so an empty $BUILDLOG can only be debris from a world
  # where something else created it — and debris must not block rebuilds.
  if { [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; } && { [ ! -s "$BUILDLOG" ] || [ ! "$BUILDLOG" -nt "$SRC" ]; }; then
    # Silent here is fine — cmd_build has already put the reason in $BUILDLOG,
    # where `pet.sh status` reads it. Discarding it was what made a failed
    # build indistinguishable from a clean install.
    if cmd_build >/dev/null 2>&1; then
      # Only a build that SUCCEEDED retires the running pet. Killing first
      # means a failed build takes the pet off the screen as well as leaving it
      # unbuilt — and cmd_build's non-zero exit returns before launch_once is
      # ever reached, so nothing puts one back. compile() stages and renames,
      # so there is no ETXTBSY reason to clear the path first either.
      pkill -x -f "$BIN_RE" 2>/dev/null
    fi
  elif [ -x "$BIN" ] && [ ! "$SRC" -nt "$BIN" ]; then
    # A binary that is present and current is proof the recorded reason no
    # longer applies to what the pet runs, and only a build that HAS to happen
    # can retract one. Without this, a failure recorded once outlives whatever
    # caused it: a dev checkout's `pet.sh build` fails against its own $SRC
    # while sharing this runtime home, or a transient breakage is fixed in a
    # way that never moves $SRC's mtime, and every later session start skips
    # the rebuild — so status keeps naming a build nobody can retract, beside a
    # binary it calls `(built)`.
    rm -f "$BUILDLOG"
  fi
  # A build that failed leaves whatever was there before, and an older binary
  # still draws a pet — so it is launched rather than withheld, and only having
  # nothing to launch gives up. The test has to happen HERE rather than inside
  # launch_once: that function spins up to five seconds waiting for `running()`
  # to see a process, holding its lock the whole time, and a $BIN that does not
  # exist can never produce one.
  [ -x "$BIN" ] || exit 0
  # Backgrounded so a SessionStart hook still returns immediately: launch_once
  # blocks until the pet is visible, and the hook must not wait on that.
  launch_once >/dev/null 2>&1 &
  exit 0
}

cmd_down() {
  sid="${1:-}"
  if [ -z "$sid" ]; then read_payload; sid="$(payload_sid)"; fi
  [ -n "$sid" ] && rm -f "$SESSIONS/$sid" "$OWNERS/$sid"
  # A bridge left over from an enable/wake that happened while sessions were
  # live: on its own it is not a reason for the pet to exist.
  [ "$(ls -A "$SESSIONS" 2>/dev/null)" = manual ] && rm -f "$SESSIONS/manual" "$OWNERS/manual"
  exit 0
}

cmd_status() {
  echo "binary:   $BIN $([ -x "$BIN" ] && echo '(built)' || echo '(not built)')"
  # Finding the reason is subtraction, not a pattern. Neither end of the file
  # works — swiftc prints the message first and its source excerpt after, so a
  # tail reports `951 |  }` — and no column anchor works either: the excerpt's
  # line numbers are right-aligned to the width of the WHOLE FILE, so in a
  # four-digit source every quoted line from 1000 up also starts at column 0,
  # and eight of pet.swift's own lines up there contain the text `error:`.
  # What every excerpt line does carry is the ` | ` gutter. Drop those and what
  # remains is messages; the fallbacks cover a log that is all excerpt, and a
  # failure that never reached the compiler and so has no `error:` at all.
  if [ -s "$BUILDLOG" ]; then
    msg=$(grep -vE '^[[:space:]]*[0-9]*[[:space:]]*\|' "$BUILDLOG") || msg=$(cat "$BUILDLOG")
    reason=$(printf '%s\n' "$msg" | grep -m1 'error:') || reason=$(printf '%s\n' "$msg" | head -1)
    echo "build:    failed — $reason"
    echo "          full error: $BUILDLOG"
  fi
  echo "process:  $(running && echo running || echo stopped)"
  echo "state:    $(cat "$ROOT/state" 2>/dev/null || echo '-')"
  echo "sessions: $(ls -1 "$SESSIONS" 2>/dev/null | wc -l | tr -d ' ')"
  echo "disabled: $([ -e "$ROOT/disabled" ] && echo yes || echo no)"
}

cmd_stop() {
  rm -f "$SESSIONS"/* "$OWNERS"/* 2>/dev/null
  pkill -x -f "$BIN_RE" 2>/dev/null
  echo "perchling stopped"
}

cmd_disable() {
  touch "$ROOT/disabled"
  pkill -x -f "$BIN_RE" 2>/dev/null
  echo "perchling disabled ('pet.sh enable' to undo)"
}

cmd_enable() {
  rm -f "$ROOT/disabled"
  # Intent, not outcome. cmd_up backgrounds the launch and exits, so nothing
  # here can see whether it worked: a lock leaked by a process killed
  # mid-launch is honoured for its full minute, and the old wording announced
  # success into that silence. Reporting the truth would mean cmd_up not
  # exiting, which is the one thing the SessionStart hook needs it to do.
  echo "perchling enabled — starting it; 'pet.sh status' says whether it came up"
  cmd_up manual
}

cmd_wake() {
  if [ -e "$ROOT/disabled" ]; then
    echo "perchling is disabled — run 'pet.sh enable' first" >&2
    exit 1
  fi
  touch "$ROOT/wake"
  # Same as enable: this is what we asked for, not what happened.
  echo "perchling waking — 'pet.sh status' says whether it came up"
  running || cmd_up manual
}

case "${1:-status}" in
  build)   cmd_build ;;
  up)      shift; cmd_up "${1:-}" ;;
  down)    shift; cmd_down "${1:-}" ;;
  stop)    cmd_stop ;;
  disable) cmd_disable ;;
  enable)  cmd_enable ;;
  wake)    cmd_wake ;;
  status)  cmd_status ;;
  *) echo "usage: pet.sh {build|up|down|stop|disable|enable|wake|status}" >&2; exit 2 ;;
esac
