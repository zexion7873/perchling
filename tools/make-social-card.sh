#!/bin/bash
# Regenerate docs/social-card.png from this checkout's pet.swift.
#
# Same cut as make-moods-gif.sh, for the same reason: the card has to show the
# pet the shipped draw() draws, or it advertises a creature that does not
# exist. GitHub has no API for the social preview — the PNG this writes is
# uploaded by hand at Settings → General → Social preview.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
src="$repo/scripts/pet.swift"
out="${1:-$repo/docs/social-card.png}"

command -v swiftc >/dev/null || { echo "needs Xcode Command Line Tools (swiftc)" >&2; exit 1; }

# `|| true`, or a missing anchor fails the substitution under pipefail and the
# script exits 1 in silence before the message below can say why.
cut=$(grep -n '^let argv = CommandLine.arguments' "$src" | cut -d: -f1 || true)
[ -n "$cut" ] || { echo "cannot find the CLI dispatch in $src" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# motionOK pinned true, as the GIF tool does: the card is one tick of a
# timeline this tool picks itself, and Reduce Motion on the machine that
# renders it has no business choosing a different frame.
head -n $((cut - 1)) "$src" \
  | sed 's/var motionOK: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }/var motionOK: Bool { true }/' \
  > "$work/gen.swift"
grep -q 'var motionOK: Bool { true }' "$work/gen.swift" || { echo "motionOK patch did not apply" >&2; exit 1; }
cat "$here/social-card.swift" >> "$work/gen.swift"

swiftc -O -o "$work/gen" "$work/gen.swift"
# Render from this checkout's art, never from whatever the user has installed.
mkdir -p "$work/home"
cp "$repo/examples/${PERCHLING_BUILTIN:-husky}.json" "$work/home/builtin.json"
PERCHLING_HOME="$work/home" "$work/gen" "$out" "$repo/.claude-plugin/plugin.json"
