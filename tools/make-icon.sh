#!/bin/bash
# Regenerate .claude-plugin/icon.png — the plugin directory's listing icon,
# named by plugin.json's `icon` — from this checkout's pet.swift. Same cut as
# make-social-card.sh, for the same reason: the icon has to show the pet the
# shipped draw() draws.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
src="$repo/scripts/pet.swift"
out="${1:-$repo/.claude-plugin/icon.png}"

command -v swiftc >/dev/null || { echo "needs Xcode Command Line Tools (swiftc)" >&2; exit 1; }

# `|| true`, or a missing anchor fails the substitution under pipefail and the
# script exits 1 in silence before the message below can say why.
cut=$(grep -n '^let argv = CommandLine.arguments' "$src" | cut -d: -f1 || true)
[ -n "$cut" ] || { echo "cannot find the CLI dispatch in $src" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# motionOK pinned true, as the card tool does: Reduce Motion on the machine
# that renders it has no business choosing a different frame.
head -n $((cut - 1)) "$src" \
  | sed 's/var motionOK: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }/var motionOK: Bool { true }/' \
  > "$work/gen.swift"
grep -q 'var motionOK: Bool { true }' "$work/gen.swift" || { echo "motionOK patch did not apply" >&2; exit 1; }
cat "$here/icon.swift" >> "$work/gen.swift"

swiftc -O -o "$work/gen" "$work/gen.swift"
# Render from this checkout's art, never from whatever the user has installed.
mkdir -p "$work/home"
cp "$repo/examples/${PERCHLING_BUILTIN:-husky}.json" "$work/home/builtin.json"
PERCHLING_HOME="$work/home" "$work/gen" "$out"
