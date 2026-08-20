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
# motionOK is pinned true in the scratch copy — the tool drives `tick` itself,
# so the machine's Reduce Motion setting has no business deciding whether the
# hero animates, and CI runners ship with it ON.
head -n $((cut - 1)) "$src" \
  | sed 's/var motionOK: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }/var motionOK: Bool { true }/' \
  > "$work/gen.swift"
grep -q 'var motionOK: Bool { true }' "$work/gen.swift" || { echo "motionOK patch did not apply" >&2; exit 1; }
cat "$here/moods-gif.swift" >> "$work/gen.swift"

swiftc -O -o "$work/gen" "$work/gen.swift"
# The built-in loads its art from the runtime home now, so the hero would
# otherwise be regenerated from whatever the USER has installed rather than
# from this checkout. Point the runtime home at a scratch copy of this
# checkout's art — which also keeps the generator from touching the live one.
mkdir -p "$work/home"
cp "$repo/examples/${PERCHLING_BUILTIN:-husky}.json" "$work/home/builtin.json"
PERCHLING_HOME="$work/home" "$work/gen" "$out"
