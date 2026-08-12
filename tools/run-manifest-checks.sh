#!/usr/bin/env bash
# Manifest-parser checks. Compiles a throwaway binary rather than rebuilding the
# installed one, and points PERCHLING_HOME at a scratch directory, because the
# runtime-home block runs at load and must never touch ~/.claude/perchling.
#
# The fixtures are written here rather than kept as files: five of the six are
# the same 8x8 pet with one field changed, so as separate files the difference
# between "valid" and "frameIndex out of range" lives two files apart from the
# assertion about it.
set -uo pipefail
cd "$(dirname "$0")/.."

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export PERCHLING_HOME="$SCRATCH/home"

echo "compiling..."
swiftc -O scripts/pet.swift -o "$SCRATCH/perchling" || exit 1
BIN="$SCRATCH/perchling"

# One 8x8 pet, two poses. 8 is the smallest canvas the parser accepts.
FLAT='["........","........","..####..","..####..","..####..","..####..","........","........"]'
GREY='["........","........","..oooo..","..oooo..","..oooo..","..oooo..","........","........"]'
HIGH='["..####..","..####..","..oooo..","..oooo..","........","........","........","........"]'

fixture() { # fixture <name> <sequences-json> -> path
  local path="$SCRATCH/$1.json"
  cat > "$path" <<JSON
{ "name": "$1",
  "palette": { "#": "#FFFFFF", "o": "#888888" },
  "moods": { "idle": $FLAT },
  "sequences": $2 }
JSON
  printf '%s' "$path"
}

pass=0; fail=0
check() { # check <label> <expected-exit> <fixture-path> <grep-pattern...>
  local label="$1" want="$2" path="$3"; shift 3
  local out rc
  out="$("$BIN" --validate "$path" 2>&1)"; rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL $label: exit $rc, wanted $want"; echo "$out" | sed 's/^/    /'
    fail=$((fail+1)); return
  fi
  local pat
  for pat in "$@"; do
    if ! printf '%s' "$out" | grep -q -- "$pat"; then
      echo "FAIL $label: output missing /$pat/"; echo "$out" | sed 's/^/    /'
      fail=$((fail+1)); return
    fi
  done
  echo "ok   $label"; pass=$((pass+1))
}

# A timeline that replays pose 0 and needs rounding on every step.
check "valid timeline" 0 \
  "$(fixture ok "{ \"idle\": { \"frames\": [$FLAT, $GREY], \"steps\": [[0,280],[1,110],[0,140]] } }")" \
  "3 steps" "280/110/140ms -> 300/100/150ms" "(11 ticks, 0.55s loop)"

# Every rejection below differs from the line above by one value.
check "frameIndex range" 1 \
  "$(fixture bad-index "{ \"idle\": { \"frames\": [$FLAT, $GREY], \"steps\": [[0,280],[1,110],[2,140]] } }")" \
  "steps\[2\]" "out of range"

check "ms range" 1 \
  "$(fixture bad-ms "{ \"idle\": { \"frames\": [$FLAT, $GREY], \"steps\": [[0,280],[1,20]] } }")" \
  "steps\[1\]" "50...1000"

check "step shape" 1 \
  "$(fixture bad-shape "{ \"idle\": { \"frames\": [$FLAT, $GREY], \"steps\": [[0,280],[1]] } }")" \
  "steps\[1\]" "two-element array"

check "steps required" 1 \
  "$(fixture missing "{ \"idle\": { \"frames\": [$FLAT, $GREY] } }")" \
  "steps is required"

# A leftover key from before timelines: loud once, never fatal.
check "stale ms warns" 0 \
  "$(fixture stale-ms "{ \"idle\": { \"frames\": [$FLAT, $GREY], \"ms\": 200, \"steps\": [[0,280],[1,110]] } }")" \
  "warning: sequences.idle.ms is ignored"

# hover and tap together, which is the pairing the precedence rule exists for.
# Built into a variable first: nesting a multi-line string inside $(...) inside
# quotes is a way to lose a brace without being told which one.
TAP_SEQS="{ \"hover\": { \"frames\": [$FLAT, $GREY], \"steps\": [[0,140],[1,140]] },"
TAP_SEQS="$TAP_SEQS \"tap\": { \"frames\": [$FLAT, $HIGH], \"steps\": [[0,140],[1,140],[0,280]], \"plays\": 2 } }"
check "tap is recognised" 0 "$(fixture tap "$TAP_SEQS")" \
  "tap     2 frames, 3 steps x2" "(12 ticks, 1.20s total)"

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
