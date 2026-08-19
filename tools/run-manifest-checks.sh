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
# Takes PERCHLING_PET_SWIFT so it can be pointed at a mutant and shown to FAIL.
swiftc -O "${PERCHLING_PET_SWIFT:-scripts/pet.swift}" -o "$SCRATCH/perchling" || exit 1
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
    # A leading ! inverts: the pattern must be ABSENT. Needed because the
    # interesting half of some rules is a sentence the tool must stop saying.
    case "$pat" in
      '!'*)
        if printf '%s' "$out" | grep -q -- "${pat#!}"; then
          echo "FAIL $label: output must not contain /${pat#!}/"; echo "$out" | sed 's/^/    /'
          fail=$((fail+1)); return
        fi ;;
      *)
        if ! printf '%s' "$out" | grep -q -- "$pat"; then
          echo "FAIL $label: output missing /$pat/"; echo "$out" | sed 's/^/    /'
          fail=$((fail+1)); return
        fi ;;
    esac
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

# --- eyes -------------------------------------------------------------------
#
# The `eyes` block had NO coverage and no shipped pet declares one, so nothing
# here had ever run — in the app or in a test. Two of the eight below were
# process kills before this file existed: an eye box is two untrusted Ints that
# were added before being range-checked, and the lid search force-unwrapped the
# palette for a transparent cell. Both took down `--validate` itself, which is
# the one tool an author has for finding out what is wrong with a manifest.
#
# `o` is the socket and the two `#` pixels on row 3 are the eyes: blink
# synthesis needs pixels brighter than the socket, so this is the smallest grid
# that can produce a blink frame at all.
EYES_ART='["........","........","..oooo..","..#oo#..","..oooo..","..oooo..","........","........"]'

eyefixture() { # eyefixture <name> <eyes-json> -> path
  local path="$SCRATCH/$1.json"
  cat > "$path" <<JSON
{ "name": "$1",
  "palette": { "#": "#FFFFFF", "o": "#888888" },
  "moods": { "idle": $EYES_ART },
  "eyes": $2 }
JSON
  printf '%s' "$path"
}

check "eyes load and synthesise a blink" 0 \
  "$(eyefixture eyes-ok '{ "box": [2,3,4,1], "socket": "o" }')" \
  "eyes 4x1 at 2,3 range 2" "blink ok"

# Declaring a box does not guarantee a blink, and silently having none is the
# failure worth naming: this box sits on a row of pure socket colour.
check "a box with nothing lit says so" 0 \
  "$(eyefixture eyes-dark '{ "box": [2,2,4,1], "socket": "o" }')" \
  "blink UNAVAILABLE"

check "range reaches the box" 0 \
  "$(eyefixture eyes-range '{ "box": [2,3,4,1], "socket": "o", "range": 4 }')" \
  "range 4"

check "a lid outside the palette is rejected" 1 \
  "$(eyefixture eyes-lid '{ "box": [2,3,4,1], "socket": "o", "lid": "z" }')" \
  "eyes.lid must be a palette key"

check "a box off the canvas is rejected" 1 \
  "$(eyefixture eyes-oob '{ "box": [6,3,4,1], "socket": "o" }')" \
  "does not fit"

# The origin is the one that used to trap, and it must be REJECTED rather than
# fatal. The exit status is the assertion: a trap exits 133, which is neither
# the 0 of a load nor the 1 of a rejection, so `check` catches it whatever the
# message says.
#
# The extent case below it is a NEGATIVE CONTROL, not coverage: `0 + Int.max`
# does not overflow, so it was already rejected correctly before the fix and
# passes against the pre-fix parser too. It stays because it records that the
# other field is rejected rather than trapping, which is not obvious from the
# origin case alone.
check "an origin that overflows Int is rejected, not fatal" 1 \
  "$(eyefixture eyes-over-x '{ "box": [9223372036854775807,0,1,1], "socket": "o" }')" \
  "does not fit"

check "an extent that overflows Int is rejected, not fatal" 1 \
  "$(eyefixture eyes-over-w '{ "box": [0,0,9223372036854775807,1], "socket": "o" }')" \
  "does not fit"

# Transparency inside the box beside ONE other ink: two keys are what makes the
# lid search compare at all, so a box over nothing but transparency always
# survived and a realistic one did not.
check "a box over transparency is not fatal" 0 \
  "$(eyefixture eyes-clear '{ "box": [1,3,3,1], "socket": "o" }')" \
  "blink ok"

# --- inkTop -----------------------------------------------------------------
#
# The chrome hangs off inkTop, and it was computed twice — once for the pet and
# once for --validate's explanation of it — so the two could disagree. A frame
# with no ink at all scored as row 0 rather than as nothing, which collapsed the
# measurement and then produced a sentence that could not be true.
BLANK='["........","........","........","........","........","........","........","........"]'

# FLAT's ink starts on row 2 and BLANK has none, so nothing here reaches higher
# than the moods. Before the fix this printed "sequences reach higher, chrome
# moves up 2 rows" — about a frame that is empty.
check "a blank frame does not collapse inkTop" 0 \
  "$(fixture blank-frame "{ \"idle\": { \"frames\": [$FLAT, $BLANK], \"steps\": [[0,200],[1,200]] } }")" \
  '!sequences reach higher'

# The other half: a sequence that genuinely starts higher must STILL be
# reported, or the fix above would have silenced a true warning as well.
check "a sequence that really reaches higher still says so" 0 \
  "$(fixture higher-seq "{ \"idle\": { \"frames\": [$FLAT, $HIGH], \"steps\": [[0,200],[1,200]] } }")" \
  "moods alone: 2" "chrome moves up 2 rows"

# --- the asymmetry every format change depends on -----------------------------
#
# `moods` REJECTS an unrecognised key and `sequences` IGNORES one, and that
# difference is the whole forward-compatibility story. A grid misfiled under
# `moods` must be fatal, because a mood that silently never shows is worse than
# a file that refuses to load — but a sequence name a future perchling adds must
# NOT take the file down on this one, or every manifest written for the newer
# version greys its row out here with no error the user can see.
#
# Neither half had a fixture. Both are one key away from each other, so a
# refactor that unified the two loops would look like a tidy-up and would break
# every manifest written for a later version.
keyfixture() { # keyfixture <name> <extra-moods-json> <extra-top-json> -> path
  local path="$SCRATCH/$1.json"
  cat > "$path" <<JSON
{ "name": "$1",
  "palette": { "#": "#FFFFFF" },
  "moods": { "idle": $FLAT$2 }$3 }
JSON
  printf '%s' "$path"
}

check "an unknown mood is fatal" 1 \
  "$(keyfixture moods-unknown ", \"sparkle\": $FLAT" "")" \
  'unknown mood' 'sparkle' 'idle, running, waiting, done, error'

check "an unknown sequence is not" 0 \
  "$(keyfixture seq-unknown "" ", \"sequences\": { \"sparkle\": { \"frames\": [$FLAT], \"steps\": [[0,200]] } }")" \
  'sequences.sparkle' 'not a recognised sequence' 'ignored'

# And the file it appears in must still LOAD, not merely warn — the warning is
# on stderr beside a successful parse, which is the only reason a manifest from
# a later perchling still renders here.
check "and the manifest still loads" 0 \
  "$(keyfixture seq-unknown-loads "" ", \"sequences\": { \"sparkle\": { \"frames\": [$FLAT], \"steps\": [[0,200]] } }")" \
  'OK' '!invalid pet manifest'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
