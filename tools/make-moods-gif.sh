#!/bin/bash
# Regenerate docs/moods.gif from this checkout's pet.swift.
#
# The frames have to come from the shipped draw(), or the README hero drifts
# away from the pet it advertises. pet.swift is a single file that ends in CLI
# dispatch and launches an overlay, so the only way to reuse its renderer is to
# cut the dispatch off and append a different main — which is exactly what
# AGENTS.md prescribes for looking at a rendered frame.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
src="$repo/scripts/pet.swift"
out="${1:-$repo/docs/moods.gif}"

command -v swiftc >/dev/null || { echo "needs Xcode Command Line Tools (swiftc)" >&2; exit 1; }

# The cut point is the first line of CLI dispatch. Matching the assignment
# rather than a line number keeps this working when the file above it grows.
cut=$(grep -n '^let argv = CommandLine.arguments' "$src" | cut -d: -f1)
[ -n "$cut" ] || { echo "cannot find the CLI dispatch in $src" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
head -n $((cut - 1)) "$src" > "$work/gen.swift"
cat "$here/moods-gif.swift" >> "$work/gen.swift"

swiftc -O -o "$work/gen" "$work/gen.swift"
"$work/gen" "$out"
