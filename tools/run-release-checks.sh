#!/bin/bash
# The release commit is ONE LINE — `.claude-plugin/plugin.json`'s version — and
# it is the only thing that reaches an install. Nothing in CI had ever parsed
# that file: thirty-four releases shipped it unchecked, so a stray comma would
# have taken the marketplace down for every user with a green tick beside it.
# This repo IS the marketplace, so the version landing on main IS the publish;
# there is no staging where a bad manifest could be caught later, and like every
# other job in harnesses.yml this one reports AFTER a direct push. Running it by
# hand before pushing a release is the only pre-publish check there is.
#
# Shell and python3 only — no Swift, nothing compiled, nothing launched. python3
# rather than jq because it is what the rest of tools/ already depends on.
#
# Takes PERCHLING_PLUGIN_JSON / PERCHLING_MARKETPLACE_JSON so it can be pointed
# at a mutant carrying exactly the defect each line is named after and shown to
# FAIL. That is the only reason to believe any of them:
#     sed 's/"version": "1\./"version": "0./' .claude-plugin/plugin.json > /tmp/back.json
#     PERCHLING_PLUGIN_JSON=/tmp/back.json bash tools/run-release-checks.sh
# The recipe anchors on the version line's SHAPE, not on today's number: a
# worked example that silently stops matching prints "6 passed, 0 failed" and
# becomes a demonstration that the check does nothing.
#
# An unusable baseline is an ERROR: it exits 1 WITHOUT printing a FAIL line,
# because run-mutation-gate.sh scores a catch by counting red assertions, and
# infra death that spells itself FAIL is exactly how a broken toolchain once
# reported "10 mutants caught".
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLUGIN="${PERCHLING_PLUGIN_JSON:-$ROOT/.claude-plugin/plugin.json}"
MARKET="${PERCHLING_MARKETPLACE_JSON:-$ROOT/.claude-plugin/marketplace.json}"

pass=0; fail=0
ok(){ printf '  ok   %-38s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no(){ printf '  FAIL %-38s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
die(){ printf 'perchling: %s\n' "$1" >&2; exit 1; }

# Not `command -v python3`: on a Mac without Command Line Tools that shim EXISTS
# and exits 1 when run, so the probe passes and the script dies three FAIL lines
# later — the one thing the header promises it will not do.
python3 -c 'import json, re, sys' >/dev/null 2>&1 \
  || die "python3 is present but not usable — this script parses JSON with it"

semver(){ python3 -c 'import re, sys
sys.exit(0 if re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", sys.argv[1]) else 1)' "$1"; }

ver_ge(){ python3 -c 'import sys
a = [int(x) for x in sys.argv[1].split(".")]
b = [int(x) for x in sys.argv[2].split(".")]
sys.exit(0 if a >= b else 1)' "$1" "$2"; }

# jget <file> <key>...  -> the value on stdout. rc 2 = the file is not JSON,
# rc 3 = the path is not in it. Both are distinguished because "unparseable"
# and "missing a field" are different defects with different fixes.
jget() {
  python3 - "$@" <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(2)
for k in sys.argv[2:]:
    try:
        v = v[int(k)] if k.lstrip("-").isdigit() else v[k]
    except Exception:
        sys.exit(3)
print(v if isinstance(v, str) else json.dumps(v, sort_keys=True))
PY
}

# --- both manifests are JSON at all ------------------------------------------
# A comma the CLI's parser rejects does not degrade the plugin, it removes it:
# the marketplace entry stops resolving for everyone who updates.
#
# These two lines are a DIAGNOSTIC, not an independent guard, and they have no
# mutation case on purpose. Every assertion below reads one of these files, so
# an unparseable manifest reds them anyway; what these buy is the decoder's line
# and column instead of four downstream "could not read" messages. A mutation
# case aimed at them would score a catch off that cascade — it stays green when
# these two lines are deleted — which is a case that tests nothing.
for pair in "plugin.json:$PLUGIN" "marketplace.json:$MARKET"; do
  label=${pair%%:*}; file=${pair#*:}
  if [ ! -f "$file" ]; then
    no "$label parses as JSON" "no such file: $file"
  elif err=$(python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$file" 2>&1); then
    ok "$label parses as JSON"
  else
    no "$label parses as JSON" "$(printf '%s' "$err" | tail -1)"
  fi
done

# --- the version is a version ------------------------------------------------
version=$(jget "$PLUGIN" version); rc=$?
if [ "$rc" -ne 0 ]; then
  no "plugin.json declares a version" "$([ "$rc" = 2 ] && echo 'file is not JSON' || echo 'no version key')"
  version=
elif semver "$version"; then
  ok "plugin.json declares a version" "$version"
else
  no "plugin.json declares a version" "not X.Y.Z with no leading zeros: '$version'"
  version=
fi

# --- and it never goes backwards ---------------------------------------------
# Non-decreasing, NOT strictly increasing: most commits do not touch this line,
# and a gate that demanded a bump on every commit would be red on all of them.
# The failure this catches is a version that REGRESSES — every user who already
# has the newer build then sees no update at all.
#
# The baseline is the highest version among ALL of HEAD's parents, not HEAD~1.
# HEAD~1 is only the FIRST parent, and that hole was measured rather than
# imagined: a feature branch that merged main, resolved this line keep-ours and
# was then fast-forwarded onto main takes main from 1.16.0 back to 1.15.1 while
# HEAD~1 reports 1.15.1 -> 1.15.1 and the whole gate stays green. Walking every
# parent also covers `pull_request`, where the merge commit's parents include
# the base tip, and it works unchanged at fetch-depth 2.
#
# KNOWN LIMIT, measured rather than assumed: a regression buried mid-push is
# invisible here. A two-commit push whose FIRST commit regresses the version and
# whose second leaves it alone compares HEAD against its own parent and passes.
# Closing that needs the published baseline, which CI does not have.
parents=$(cd "$ROOT" && git rev-parse HEAD^@ 2>/dev/null)
[ $? -eq 0 ] || die "git could not read HEAD's parents: $(cd "$ROOT" && git rev-parse HEAD^@ 2>&1 >/dev/null | tail -1)"
[ -n "$parents" ] || die "HEAD has no parent — a root commit, an orphan branch, or a fetch-depth 1 checkout"

prev_version=
for p in $parents; do
  blob=$(cd "$ROOT" && git show "$p:.claude-plugin/plugin.json" 2>/dev/null) \
    || die "cannot read .claude-plugin/plugin.json at $p: $(cd "$ROOT" && git show "$p:.claude-plugin/plugin.json" 2>&1 >/dev/null | tail -1)"
  pv=$(printf '%s' "$blob" | python3 -c 'import io, json, sys
print(json.load(io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8")).get("version", ""))' 2>/dev/null) \
    || die "the .claude-plugin/plugin.json at $p is not JSON — the baseline cannot be trusted"
  [ -n "$pv" ] || die "the .claude-plugin/plugin.json at $p declares no version"
  semver "$pv" || die "the baseline version at $p is not X.Y.Z: '$pv'"
  if [ -z "$prev_version" ] || ! ver_ge "$prev_version" "$pv"; then prev_version=$pv; fi
done

if [ -z "$version" ]; then
  no "the version never goes backwards" "current version is unusable; nothing to compare"
elif ver_ge "$version" "$prev_version"; then
  ok "the version never goes backwards" "$prev_version -> $version"
else
  no "the version never goes backwards" "$prev_version -> $version"
fi

# --- the two manifests agree on what this plugin is --------------------------
# plugin.json's name and the marketplace entry's name are two copies of one
# fact, and the entry is what resolves on install. The marketplace's OWN
# top-level name is deliberately not checked: it has no second copy anywhere to
# disagree with, so the only available assertion is that it equals a literal,
# which pins a constant rather than catching a drift.
p_name=$(jget "$PLUGIN" name) && m_name=$(jget "$MARKET" plugins 0 name)
if [ -z "${p_name:-}" ] || [ -z "${m_name:-}" ]; then
  no "both manifests name the same plugin" "could not read one of the names"
elif [ "$p_name" = "$m_name" ]; then
  ok "both manifests name the same plugin" "$p_name"
else
  no "both manifests name the same plugin" "plugin.json '$p_name' vs marketplace.json '$m_name'"
fi

# The descriptions are two copies of one claim and they HAVE drifted before:
# one promised half a megabyte while the other promised a megabyte, and the
# unchecked claim outlived the thing it described. Both were rewritten to the
# same sentence; nothing held them there until this line. The evidence is the
# first differing region, not the tail — that historical drift sat at index 132
# of 180 and the two strings' last 40 characters were byte-identical.
p_desc=$(jget "$PLUGIN" description) && m_desc=$(jget "$MARKET" plugins 0 description)
if [ -z "${p_desc:-}" ] || [ -z "${m_desc:-}" ]; then
  no "the two descriptions still agree" "could not read one of the descriptions"
elif [ "$p_desc" = "$m_desc" ]; then
  ok "the two descriptions still agree"
else
  no "the two descriptions still agree" "$(python3 -c 'import sys
a, b = sys.argv[1], sys.argv[2]
n = min(len(a), len(b))
i = next((k for k in range(n) if a[k] != b[k]), n)
print("first differ at %d: %r vs %r" % (i, a[i:i+28], b[i:i+28]))' "$p_desc" "$m_desc")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
