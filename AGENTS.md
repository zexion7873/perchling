# Working on perchling

A Claude Code plugin: one Swift file compiled to an accessory-app
overlay, driven by hook scripts that write mood files. No package manager, no
test framework, no dependencies. `README.md` covers what it does for a user —
this file covers what will waste your time if you assume it.

What earns a place here: the command, what it covers, and the trap. Rationale
does not — a harness's argument for itself belongs in the script it justifies
and CI's in the workflow. This file is loaded into every session in the repo,
and the last time that rule went unwritten it grew from 211 lines to 310 in
nineteen days.

## Changes reach the running system by two different paths

- **`scripts/pet.swift`** — `bash scripts/pet.sh build` recompiles
  `~/.claude/perchling/bin/perchling` from *this* checkout. Live on next
  launch. Fast loop.
- **the built-in's art** — `examples/$PERCHLING_BUILTIN.json`, copied into the
  runtime home by `cmd_up` and ONLY by `cmd_up`, which ends in a launch: there
  is no art-only install. The two paths also differ in how they revert. The
  binary is gated on mtime, so a dev `pet.sh build` IS what the next hook-driven
  session launches, until something newer replaces it. The art is gated on
  CONTENT, so the marketplace clone's next `cmd_up` silently puts the published
  art back. To install a checkout's art without launching anything:
  `cp examples/$PERCHLING_BUILTIN.json ~/.claude/perchling/builtin.json`.
- **`scripts/pet.sh`, `scripts/state.sh`, `hooks/hooks.json`** — hooks resolve
  `${CLAUDE_PLUGIN_ROOT}` to the **installed marketplace clone**, never this
  checkout. Editing them here changes nothing until the commit is pushed and
  the user runs `claude plugin marketplace update perchling` followed by
  `claude plugin update perchling@perchling` (the bare plugin name is rejected).

Symptom of confusing the two: a new hook feature is silently inert while
running the same script by hand works fine. To test hook-path changes without
publishing, pipe a fake payload straight into the dev script:

```bash
printf '{"session_id":"test","prompt":"hi"}' \
  | CLAUDE_CONFIG_DIR="$(mktemp -d)" bash scripts/state.sh running
```

`state.sh` resolves its home from `CLAUDE_CONFIG_DIR`, so without that override
this writes a `sessions/test` into the LIVE install — a tray row for a session
nobody typed in, which also holds the 30s idle-quit open for an hour.

A session only gains a plugin's hooks at session start, so a freshly installed
or updated plugin is invisible to sessions that were already open.

## Do not launch the overlay to see if it works

`perchling` with no arguments starts a real pet window on the user's screen,
and it will not exit while any Claude Code session is live — the 30s idle-quit
only fires when the sessions directory is empty. Several agents doing this in
parallel litters the desktop with pets that outlive the terminals that spawned
them. Unknown arguments print usage and exit 2, so a mistyped flag is safe, but
a bare invocation is not.

`pet.sh up`, `enable` and `wake` all end in the same launch path, and reach it
through the REBUILD gate — so a checkout's `wake` compiles WIP `pet.swift` into
the user's live binary and then opens a window from it. A scratch
`CLAUDE_CONFIG_DIR` is not a sandbox until a stub is already sitting in it.

The rest of the launch story — the mkdir mutex, the reclaim, the wedged lock —
is in [docs/invariants/shell.md](docs/invariants/shell.md). Two commandments
survive out here: never launch a bare `perchling` to see if it works, and
never write into a `.launch.lock`.

Verify without launching instead. The six techniques — `--validate`, a window
geometry probe, offscreen frame rendering, the session-harness cut, rasterised
pixel art, and unified-log ground truth for mood timing — are in
[docs/invariants/harnesses.md](docs/invariants/harnesses.md), beside the
three-clause stub rule they all depend on. The clause that matters most rides
here too: a harness stub must be a compiled executable that stays alive and is
**never a copy of the real binary** — the cheapest stub that satisfies the
first two clauses is the one that opens a pet window.

"Verified" still means: it compiles, the examples still validate, `--export`
still round-trips, malformed manifests are still rejected, and you have looked
at a rendered frame. A harness is one more kind of evidence for the code it
covers, not a replacement for any of those.

## Where the invariants live

**Before editing a layer, read its file** — every bullet in them was earned by
a shipped bug, and the one-liner quoted below is only the most lethal of each
file's rules, not a summary of it.

- **[manifest.md](docs/invariants/manifest.md)** — the format, the parser, the
  built-in's art. The rule: anything added to the manifest goes at the TOP
  LEVEL, never inside `moods` — one unknown key under `moods` makes the whole
  file unloadable on every older perchling, silently, while `sequences`
  deliberately ignores unknown names; that asymmetry IS the format's
  forward-compatibility story.
- **[pose.md](docs/invariants/pose.md)** — sequences, precedence, gaze, drag,
  Reduce Motion. The rule: every arm below the first in `pose()`'s precedence
  chain is reached by testing whether a frame was already produced, never by
  chaining another `else if` — a spent burst's clock stays armed and swallows
  everything below it, a regression that has shipped twice.
- **[chrome.md](docs/invariants/chrome.md)** — the bubble, the chip, vibrancy,
  `inkTop`. The rule: the chrome hangs off the ART at the resting bounce, and
  a frame with no ink has no top — scoring one blank frame as row 0 collapsed
  `inkTop` and pinned the chrome to the top of the canvas.
- **[sessions.md](docs/invariants/sessions.md)** — the fold, TTLs, owners, the
  registry, captions, the pet library. The rule: `clearPetLink` is two lines,
  and their ORDER plus the `try` on the first are all that stands between a
  menu click and deleting a pet with no other copy — weakening either reads in
  review like tidying.
- **[shell.md](docs/invariants/shell.md)** — `pet.sh`, `state.sh`,
  `hooks/hooks.json`, the launch lock. The rule: one event key the running CLI
  does not recognise is silently fatal — to EVERY hook in the plugin on a CLI
  old enough, and to that entry alone on 2.1.258 — and a `--settings` probe
  proves nothing either way, because that validator ignores unknown keys; the
  two failure modes are opposites.
- **[harnesses.md](docs/invariants/harnesses.md)** — how to verify anything
  here without opening a window, and the stub rules above.

## Commands

```bash
bash scripts/pet.sh build     # recompile the binary from this checkout
bash scripts/pet.sh status    # binary / process / state / session count
bash scripts/pet.sh stop      # drop refcounts and kill the pet
bash tools/make-moods-gif.sh   [OUT.gif]  # README hero; NO ARG OVERWRITES docs/moods.gif
bash tools/make-social-card.sh [OUT.png]  # social preview; NO ARG OVERWRITES docs/social-card.png
bash tools/run-session-harness.sh  # 180 assertions over the session/tray + pet library
bash tools/run-manifest-checks.sh  # manifest parser: steps, tap, eyes, inkTop, key asymmetry
bash tools/run-pose-harness.sh     # sequence precedence, the pinned pose, and mirror consent
bash tools/run-hooks-check.sh      # hooks.json declares no event this CLI rejects
bash tools/run-launch-race.sh      # cmd_up launches exactly one pet; 13 lines, 11 guarantees
bash tools/run-build-gate.sh       # what a FAILED build may do to a working install
bash tools/run-state-checks.sh     # what state.sh writes, and what it must refuse to
bash tools/run-prune-checks.sh     # cmd_up retires stale refcounts and keeps live ones
bash tools/run-library-refresh.sh  # a picked pet takes shipped updates only while provably untouched
bash tools/run-art-checks.sh       # no shipped pet has a hole the desktop shows through
bash tools/run-toggle-checks.sh    # disable / enable / wake, and what each may claim
bash tools/run-release-checks.sh   # manifests parse, version holds, LF, hero width, hook paths
bash tools/run-mutation-gate.sh    # every harness goes red against the defect it is named after
~/.claude/perchling/bin/perchling --validate examples/otter.json
~/.claude/perchling/bin/perchling --export > /tmp/draft.json
```

Ten of the `run-*` scripts are layer harnesses; `run-hooks-check.sh`,
`run-release-checks.sh` and `run-mutation-gate.sh` are not. Each script's own
header says what it covers, why it is a separate file, and where it cuts
`pet.swift` — read that before editing one. `--validate` and `--export` read the
INSTALLED binary and the installed `builtin.json`, never this checkout.

Every layer harness and the release gate takes `PERCHLING_*` overrides — each
script's header names its own — so it can be pointed at a mutant carrying
exactly the defect it names and shown to FAIL. That is the only reason to
believe any of them, and the escape test described beside them is what makes a
red mutant mean ONE line noticed rather than four cascading.

`tools/run-mutation-gate.sh` runs that argument as one command: forty-nine
mutants generated from HEAD — never a committed copy, which drifts silently —
each asserted to red the harness it is named after. A new harness assertion
needs a matching case there, and a new `tools/run-*.sh` is picked up by CI's
glob automatically — skip it by name if it must not run there.
`.github/workflows/harnesses.yml` runs the harnesses, the gate,
`run-release-checks.sh` and `run-hooks-check.sh` on every PR and push to main;
the hooks check also runs daily, because the CLI it validates against moves
without this repo moving.

CI compiles with a PINNED Xcode 16.4 / Swift 6.1.2, asserted rather than
inferred. A dev machine's Swift has never been evidence about CI's, and bumping
means changing the path AND the assertion, in BOTH jobs.

This repo IS the marketplace: the version line in `.claude-plugin/plugin.json`
is the publish, with no staging where a stray comma gets caught later. Run
`bash tools/run-release-checks.sh` by hand before pushing one.

## The built-in's art

**It has no generator, and only one thing checks it.** `examples/husky.json` is
449KB of row strings quantised from raster art, so changing the built-in means
replacing the whole file — there is no `build()` to re-run, and nothing that
will notice if the DRAWING comes out wrong. 1.7–1.12 emitted the manifest from
parametric geometry with a guard holding the two together; the generator only
ever drew the hippo, so it went when the hippo did. If it is ever generated
again, bind the guard to the shipped file and nothing else — a copy parked under
`examples/` puts the check one indirection from what ships.

`tools/run-art-checks.sh` is the one check that exists. It globs
`examples/*.json`, so a seventh pet is covered the moment it lands, and it
answers exactly one question — is any transparent pixel unreachable from the
border — because that one is decidable without knowing what the art should look
like. A featureless blob passes it. It is not a substitute for rendering a frame
and looking at it.

Adding a pet that is NOT the built-in is otherwise ungated: `README.md` states
the shipped count in prose and nothing holds it to the directory, and each pet
carries its own fractional `scale` tuned so the creature lands near 90pt.

The format `--export` round-trips, and the exact serialisation anything writing
a manifest must match, are in
[docs/invariants/manifest.md](docs/invariants/manifest.md).

Three artifacts go stale behind an art change, and they do not share a trigger.
The built-in's art moving or `draw()` changing stales `docs/moods.gif` AND
`docs/social-card.png`; `plugin.json`'s description stales the card alone.
Only one of the three fails loudly: `run-release-checks.sh` holds the README's
`width=` to the GIF's real header, so a hero regenerated at a new size with the
README left behind reds the gate instead of resampling the pixel art into mush
in every reader's browser. Nothing compares either image against a fresh render.
Both tools decode their own output before exiting 0, so a green run means the
file is right — but byte-reproducibility holds per MACHINE only (the GIF tool
ships a measured ±1-per-channel tolerance), which is why CI refuses to `cmp` the
committed file. The card tool promises nothing about the text beside the pet.
And the card has one step nothing here does: GitHub takes the social preview
only through Settings → General → Social preview, so a regenerated PNG is not
live until someone uploads it there. That omission is detectable after the fact
— the `og:image` GitHub serves IS the uploaded bytes — but never as a merge
gate.
