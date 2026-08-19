#!/bin/bash
# Runs the session-layer assertions in tools/session-harness.swift against this
# checkout's pet.swift.
#
# The cut point is the runtime-home block, not the CLI dispatch that
# make-moods-gif.sh cuts at: `let argv` still leaves the block that resolves
# ~/.claude/perchling and creates directories inside it, and a test run must not
# touch the live install. Everything this harness exercises sits above that line.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
# Takes PERCHLING_PET_SWIFT so it can be pointed at a mutant and shown to FAIL.
# Nothing here is worth believing without that: this repo has shipped green
# assertions that tested nothing at least four times.
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
cat "$here/session-harness.swift" >> "$work/gen.swift"

swiftc -o "$work/gen" "$work/gen.swift"
"$work/gen"
