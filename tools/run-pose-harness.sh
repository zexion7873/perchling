#!/usr/bin/env bash
# Sequence precedence assertions over the real pose() — the rule AGENTS.md used
# to claim was pinned and was not. Cuts pet.swift at `let argv` rather than
# before `// Runtime home:` the way the session harness does, because PetView
# lives below that block and the earlier cut cannot reach it. PERCHLING_HOME
# points at a scratch directory so the one `createDirectory` the block performs
# never touches ~/.claude/perchling.
set -uo pipefail
cd "$(dirname "$0")/.."

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export PERCHLING_HOME="$SCRATCH/home"

awk '/^let argv = CommandLine.arguments/{exit} {print}' scripts/pet.swift > "$SCRATCH/harness.swift"
cat tools/pose-harness.swift >> "$SCRATCH/harness.swift"

swiftc -O "$SCRATCH/harness.swift" -o "$SCRATCH/pose-harness" || exit 1
"$SCRATCH/pose-harness"
