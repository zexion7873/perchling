#!/usr/bin/env bash
# Guards one silent failure: an event key `hooks/hooks.json` declares that the
# running CLI does not recognise voids EVERY hook in the file, not just that
# entry. The pet then never launches — no SessionStart, no error anywhere the
# user can see. `claude plugin validate` runs the same schema and catches it.
#
# It has to run against a copy: pointed at this repo it finds
# .claude-plugin/marketplace.json first and validates that instead, never
# reaching hooks.json. The copy carries plugin.json and hooks/ and nothing else.
#
# A clean file prints no "Validating hooks:" line at all, so the mutation half
# is what proves the check is live rather than silently skipping.
#
# Both halves grep a captured file rather than a pipe: under `pipefail` the
# status of `claude ... | grep -q` is the validator's, not the grep's, so the
# mutation half read as "not caught" on a run where it plainly was.
set -uo pipefail
cd "$(dirname "$0")/.."

command -v claude >/dev/null || { echo "claude CLI not on PATH"; exit 1; }

SCRATCH="$(mktemp -d)" || exit 1
[ -n "$SCRATCH" ] || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH/plugin/.claude-plugin" || exit 1
cp .claude-plugin/plugin.json "$SCRATCH/plugin/.claude-plugin/" || exit 1
cp -R hooks "$SCRATCH/plugin/" || exit 1

fail=0
VERSION="$(claude --version)"

claude plugin validate "$SCRATCH/plugin" > "$SCRATCH/real.log" 2>&1
if grep -q 'Invalid key in record' "$SCRATCH/real.log"; then
  echo "FAIL: hooks/hooks.json declares an event $VERSION does not know."
  echo "      Every perchling hook is dead on this version, silently."
  grep '❯' "$SCRATCH/real.log"
  fail=1
else
  echo "ok: hooks/hooks.json accepted by $VERSION"
fi

# Mutation: a key no CLI version can know must be rejected. Without this a
# validator that quietly stopped running would leave the check above green.
python3 - "$SCRATCH/plugin/hooks/hooks.json" <<'PY'
import json, sys
p = sys.argv[1]
h = json.load(open(p))
h["hooks"]["ZzzTotallyBogusEvent"] = h["hooks"]["Stop"]
json.dump(h, open(p, "w"), indent=2)
PY

claude plugin validate "$SCRATCH/plugin" > "$SCRATCH/mutated.log" 2>&1
if grep -q 'Invalid key in record' "$SCRATCH/mutated.log"; then
  echo "ok: unknown event key still rejected — the check is live"
else
  echo "FAIL: unknown event key accepted; this check is no longer testing anything"
  fail=1
fi

exit $fail
