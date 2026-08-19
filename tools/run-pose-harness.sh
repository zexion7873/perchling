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

# `let builtinPet` becomes `var` in the scratch copy only, so a harness can give
# the BUILT-IN a sequence. Without that there is no way to exercise the
# `activePet` path at all: PetView is final, so overriding `activePet` is not
# open either, and a rule that cannot be tested is a rule that silently rots.
# Takes PERCHLING_PET_SWIFT so it can be pointed at a mutant and shown to FAIL.
awk '/^let argv = CommandLine.arguments/{exit} {print}' "${PERCHLING_PET_SWIFT:-scripts/pet.swift}" \
  | sed 's/^let builtinPet = /var builtinPet = /' > "$SCRATCH/harness.swift"
cat tools/pose-harness.swift >> "$SCRATCH/harness.swift"

swiftc -O "$SCRATCH/harness.swift" -o "$SCRATCH/pose-harness" || exit 1
"$SCRATCH/pose-harness"
