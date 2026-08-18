#!/bin/bash
# Runs the shipped-art assertions in tools/art-harness.swift against this
# checkout's pet.swift and every manifest in examples/.
#
# The cut point is the runtime-home block, the same one run-session-harness.sh
# uses and for the same reason: `let argv` still leaves the block that resolves
# ~/.claude/perchling and creates directories inside it, and a test run must not
# touch the live install. BUILTIN_MANIFEST and `builtinPet` both sit above that
# line, which is what lets this check the string that actually ships rather than
# a copy of it.
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
cat "$here/art-harness.swift" >> "$work/gen.swift"

swiftc -o "$work/gen" "$work/gen.swift"
"$work/gen" "$repo"/examples/*.json
