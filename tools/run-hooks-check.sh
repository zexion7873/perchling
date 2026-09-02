#!/usr/bin/env bash
# Guards an event key in `hooks/hooks.json` that the running CLI does not
# recognise. What that costs depends on the CLI, so the check outlives the
# consequence: up to some version between 2.1.109 and 2.1.258 an unknown key
# voided EVERY hook in the file — the pet never launched, no SessionStart, no
# error anywhere the user could see. 2.1.258 downgrades it to a warning and
# drops only that entry, measured at RUNTIME rather than taken from the
# message: a plugin declaring one bogus event beside a real `SessionStart`
# still fired the real one. Users on older CLIs keep the total failure, so an
# unknown key stays a release blocker either way.
#
# Both message shapes are matched because both are live in the wild — older
# CLIs say `Invalid key in record`, 2.1.258 says `unknown hook event`.
# `claude plugin validate` runs the same schema the runtime does.
#
# It has to run against a copy: pointed at this repo it finds
# .claude-plugin/marketplace.json first and validates that instead, never
# reaching hooks.json. The copy carries plugin.json and hooks/ and nothing else.
#
# The mutation half is what proves the check is live rather than silently
# skipping — and it has now caught the validator's wording changing under it
# once, which is the whole reason it exists.
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
if grep -qE 'Invalid key in record|unknown hook event' "$SCRATCH/real.log"; then
  echo "FAIL: hooks/hooks.json declares an event $VERSION does not know."
  echo "      That entry is dead here, and on a CLI old enough, so is every"
  echo "      other hook in the file — silently."
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
if grep -qE 'Invalid key in record|unknown hook event' "$SCRATCH/mutated.log"; then
  echo "ok: unknown event key still flagged — the check is live"
else
  echo "FAIL: unknown event key passed silently; this check is no longer testing"
  echo "      anything. The validator's wording moved again — find what it says"
  echo "      now with: claude plugin validate <a plugin with a bogus event>"
  fail=1
fi

exit $fail
