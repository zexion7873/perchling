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


# parseGrid walks utf8 bytes through a 128-entry table, because iterating a row
# by Character costs grapheme-cluster segmentation on every pixel and that alone
# was 140ms of the 220ms it took to parse a twelve-file examples/ (six ship
# today, so that total is an upper bound on what a user pays). The table
# cannot represent a palette key outside ASCII, and a row byte over 127 cannot
# index it, so both fall back to the original Character walk. These pin the two
# paths together: the fast one must never accept what the slow one rejects, and
# a rejection must still name the CHARACTER the author wrote rather than one
# byte of it. Every case here was also diffed against the pre-change binary,
# whole output and exit status, and matched.
glyphs() { # glyphs <char> -> an 8x8 idle grid of that character, JSON
  local c="$1" row=""
  local i; for i in 1 2 3 4 5 6 7 8; do row="$row$c"; done
  printf '["%s","%s","%s","%s","%s","%s","%s","%s"]' "$row" "$row" "$row" "$row" "$row" "$row" "$row" "$row"
}
petfile() { # petfile <name> <palette-json> <idle-grid-json> -> path
  local path="$SCRATCH/$1.json"
  printf '{ "name": "%s", "palette": %s, "moods": { "idle": %s } }\n' "$1" "$2" "$3" > "$path"
  printf '%s' "$path"
}

check "non-ascii palette key loads" 0 \
  "$(petfile star '{ "★": "#FF0000" }' "$(glyphs '★')")" "8x8"
check "cjk palette key loads" 0 \
  "$(petfile cjk '{ "貓": "#00FF00" }' "$(glyphs '貓')")" "8x8"
check "emoji palette key loads" 0 \
  "$(petfile emoji '{ "🐶": "#0000FF" }' "$(glyphs '🐶')")" "8x8"
# An ASCII palette takes the byte path; a non-ASCII glyph in the row must still
# be reported as that glyph, which is the whole reason the fallback exists.
check "non-ascii glyph names the character" 1 \
  "$(petfile mixed '{ "a": "#FF0000" }' '["aaaaaaaa","aaaaaaaa","aaaaaaa★","aaaaaaaa","aaaaaaaa","aaaaaaaa","aaaaaaaa","aaaaaaaa"]')" \
  'idle row 2' 'is not in the palette'
check "unknown ascii glyph still rejected" 1 \
  "$(petfile unk '{ "a": "#FF0000" }' '["aaaaaaaa","aaaaaaaz","aaaaaaaa","aaaaaaaa","aaaaaaaa","aaaaaaaa","aaaaaaaa","aaaaaaaa"]')" \
  'idle row 1' '"z" is not in the palette'
check "short row still rejected" 1 \
  "$(petfile short '{ "a": "#FF0000" }' '["aaaaaaaa","aaaaaaaa","aaaaaaaa","aaaaa","aaaaaaaa","aaaaaaaa","aaaaaaaa","aaaaaaaa"]')" \
  'idle row 3' 'length 5 != 8'
# Both transparent glyphs are known to the byte table, not just ".".
check "0 and . both transparent" 0 \
  "$(petfile clear '{ "a": "#FF0000" }' '["a.0a.0a.","a.0a.0a.","a.0a.0a.","a.0a.0a.","a.0a.0a.","a.0a.0a.","a.0a.0a.","a.0a.0a."]')" "8x8"

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
