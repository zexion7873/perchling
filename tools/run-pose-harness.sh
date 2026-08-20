#!/usr/bin/env bash
# Sequence precedence assertions over the real pose() — the rule docs/invariants/pose.md used
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
# `motionOK` is pinned true in the scratch copy for the same reason a locale
# gets forced: it reads a SYSTEM setting (Reduce Motion), so the harness's
# coverage would otherwise depend on the machine's accessibility state — and
# GitHub's runners ship with Reduce Motion ON, where every sequence assertion
# would fail for a reason that has nothing to do with the rule under test.
awk '/^let argv = CommandLine.arguments/{exit} {print}' "${PERCHLING_PET_SWIFT:-scripts/pet.swift}" \
  | sed -e 's/^let builtinPet = /var builtinPet = /' \
        -e 's/var motionOK: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }/var motionOK: Bool { true }/' \
  > "$SCRATCH/harness.swift"
# A sed that matched nothing tests the clean tree; both patches must have landed.
grep -q '^var builtinPet = ' "$SCRATCH/harness.swift" || { echo "FAIL: builtinPet patch did not apply"; exit 1; }
grep -q 'var motionOK: Bool { true }' "$SCRATCH/harness.swift" || { echo "FAIL: motionOK patch did not apply"; exit 1; }
cat tools/pose-harness.swift >> "$SCRATCH/harness.swift"

swiftc -O "$SCRATCH/harness.swift" -o "$SCRATCH/pose-harness" || exit 1
"$SCRATCH/pose-harness"
