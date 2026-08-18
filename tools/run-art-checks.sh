#!/bin/bash
# Runs the shipped-art assertions in tools/art-harness.swift against this
# checkout's pet.swift and every manifest in examples/.
#
# The cut point is the runtime-home block, the same one run-session-harness.sh
# uses and for the same reason: `let argv` still leaves the block that resolves
# ~/.claude/perchling and creates directories inside it, and a test run must not
# touch the live install — and `builtinPet` now sits BELOW it, because it needs
# the runtime home to know which file to load. The shipped art is therefore
# passed in as a path rather than read out of the binary; the placeholder still
# comes from the binary, since nothing else carries it.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
# Overridable so the harness can be pointed at a pet.swift with a hole punched
# back into BUILTIN_MANIFEST and shown to FAIL. Six green lines prove nothing on
# their own — they would also all pass against an `enclosed()` that returned 0:
#     python3 - <<'P'   # reopen one interior pixel
#     ...rewrite one row of moods.waiting with a '.' inside the sprite...
#     P
#     PERCHLING_PET_SWIFT=/tmp/holed.swift bash tools/run-art-checks.sh
# which must fail, and must name the grid it was punched into.
src="${PERCHLING_PET_SWIFT:-$repo/scripts/pet.swift}"

command -v swiftc >/dev/null || { echo "needs Xcode Command Line Tools (swiftc)" >&2; exit 1; }

cut=$(grep -n '^// Runtime home:' "$src" | head -1 | cut -d: -f1 || true)
[ -n "$cut" ] || { echo "cannot find the runtime-home block in $src" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
head -n $((cut - 1)) "$src" > "$work/gen.swift"
# The one global a still-included type reaches for: the Controller's pet menu
# reads examplesRoot, whose definition lives below the cut.
echo 'let examplesRoot: URL? = nil' >> "$work/gen.swift"
# Two more globals the still-included code reaches for. They moved BELOW this
# cut when the built-in's art left the binary — `builtinPet` needs the runtime
# home to know which file to load — so the harness supplies the no-home answer,
# which is the embedded placeholder.
echo 'let builtinLoaded = builtinFrom(nil)' >> "$work/gen.swift"
echo 'let builtinText = builtinLoaded.text' >> "$work/gen.swift"
echo 'let builtinPet = builtinLoaded.pet' >> "$work/gen.swift"
cat "$here/art-harness.swift" >> "$work/gen.swift"

swiftc -o "$work/gen" "$work/gen.swift"
"$work/gen" "$repo"/examples/*.json
