# Working on perchling

A Claude Code plugin: one Swift file compiled to an accessory-app
overlay, driven by hook scripts that write mood files. No package manager, no
test framework, no dependencies. `README.md` covers what it does for a user —
this file covers what will waste your time if you assume it.

## Changes reach the running system by two different paths

- **`scripts/pet.swift`** — `bash scripts/pet.sh build` recompiles
  `~/.claude/perchling/bin/perchling` from *this* checkout. Live on next
  launch. Fast loop.
- **the built-in's art** — `examples/$PERCHLING_BUILTIN.json`, copied into the
  runtime home by `cmd_up` from whichever `pet.sh` ran. So a dev checkout's
  `pet.sh up` installs the checkout's art exactly as it installs the checkout's
  binary, and neither reaches a hook-driven session until published.
- **`scripts/pet.sh`, `scripts/state.sh`, `hooks/hooks.json`** — hooks resolve
  `${CLAUDE_PLUGIN_ROOT}` to the **installed marketplace clone**, never this
  checkout. Editing them here changes nothing until the commit is pushed and
  the user runs `claude plugin marketplace update perchling` followed by
  `claude plugin update perchling@perchling` (the bare plugin name is rejected).

Symptom of confusing the two: a new hook feature is silently inert while
running the same script by hand works fine. To test hook-path changes without
publishing, pipe a fake payload straight into the dev script:

```bash
printf '{"session_id":"test","prompt":"hi"}' | bash scripts/state.sh running
```

A session only gains a plugin's hooks at session start, so a freshly installed
or updated plugin is invisible to sessions that were already open.

## Do not launch the overlay to see if it works

`perchling` with no arguments starts a real pet window on the user's screen,
and it will not exit while any Claude Code session is live — the 30s idle-quit
only fires when the sessions directory is empty. Several agents doing this in
parallel litters the desktop with pets that outlive the terminals that spawned
them. Unknown arguments print usage and exit 2, so a mistyped flag is safe, but
a bare invocation is not.

The rest of the launch story — the mkdir mutex, why the lock's reclaim is a
second critical section that must be SERIALISED rather than made atomic, and
why a wedged lock is renamed aside rather than removed — is in
[docs/invariants/shell.md](docs/invariants/shell.md). The two commandments
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

## Where the invariants live

878 lines of layer invariants used to sit here, flat, and the traps drowned
each other. They moved verbatim into `docs/invariants/`, one file per layer.
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
  does not recognise voids EVERY hook in the plugin, silently — and a
  `--settings` probe proves nothing, because that validator ignores unknown
  keys; the two failure modes are opposites.
- **[harnesses.md](docs/invariants/harnesses.md)** — how to verify anything
  here without opening a window, and the stub rules above.

## Commands

```bash
bash scripts/pet.sh build     # recompile the binary from this checkout
bash scripts/pet.sh status    # binary / process / state / session count
bash scripts/pet.sh stop      # drop refcounts and kill the pet
bash tools/make-moods-gif.sh  # regenerate the README hero from this checkout
bash tools/run-session-harness.sh  # 137 assertions over the session/tray + pet library
bash tools/run-manifest-checks.sh  # manifest parser: steps, tap, eyes, inkTop, key asymmetry
bash tools/run-pose-harness.sh     # sequence precedence, the pinned pose, and mirror consent
bash tools/run-hooks-check.sh      # hooks.json declares no event this CLI rejects
bash tools/run-launch-race.sh       # cmd_up launches exactly one pet, 13 assertions
bash tools/run-build-gate.sh        # what a FAILED build may do to a working install
bash tools/run-state-checks.sh      # what state.sh writes, and what it must refuse to
bash tools/run-prune-checks.sh      # cmd_up retires stale refcounts and keeps live ones
bash tools/run-library-refresh.sh   # a picked pet takes shipped updates only while provably untouched
bash tools/run-art-checks.sh        # no shipped pet has a hole the desktop shows through
bash tools/run-toggle-checks.sh     # disable / enable / wake, and what each may claim
bash tools/run-release-checks.sh    # the release manifests parse, and the version never goes backwards
bash tools/run-mutation-gate.sh     # every harness goes red against the defect it is named after
~/.claude/perchling/bin/perchling --validate examples/otter.json
~/.claude/perchling/bin/perchling --export > /tmp/draft.json
```

Ten layers have harnesses — the session/tray layer and the pet library
(`tools/run-session-harness.sh`), `state.sh` itself
(`tools/run-state-checks.sh`, shell only, since that script compiles nothing
and launches nothing), `cmd_up`'s housekeeping
(`tools/run-prune-checks.sh` — kept apart from the launch, build and
library-refresh harnesses because they are four unrelated properties of one
function and one file would make a failure ambiguous), the library refresh
inside the same `cmd_up` (`tools/run-library-refresh.sh`, shell only with
byte fixtures — the refresh compares files and never parses them), the manifest parser
(`tools/run-manifest-checks.sh`, which compiles a throwaway binary rather than
rebuilding the installed one) and sequence precedence inside `pose()`
(`tools/run-pose-harness.sh`, which cuts at `let argv` rather than before the
runtime-home block, because `PetView` lives below that line) and `cmd_up`'s
launch path (`tools/run-launch-race.sh`, which is shell only and compiles a C
stub rather than touching `pet.swift`) and what a failed build may do to a
working install (`tools/run-build-gate.sh`, shell only for the same reason, and
using the same kind of C stub) and the shipped art (`tools/run-art-checks.sh`,
which cuts where the session harness cuts so it can reach `builtinPet`) and the
three commands that take the pet off the screen and put it back
(`tools/run-toggle-checks.sh` — its own file rather than another section of an
existing one, for the reason the others are separate: it covers
`cmd_disable`/`cmd_enable`/`cmd_wake`, not `cmd_up`, so a failure has to name
the toggle).

Ten of them take an override — `PERCHLING_PET_SH`, `PERCHLING_PET_SWIFT` and
`PERCHLING_STATE_SH` — and so does the release gate below
(`PERCHLING_PLUGIN_JSON`, `PERCHLING_MARKETPLACE_JSON`), so each can be pointed
at a mutant carrying exactly the defect it is named after and shown to FAIL.
Four of the release gate's six lines are pinned that way and each of the four
was shown to ESCAPE against a copy with that one assertion removed, which is
the difference between proof and a cascade; its two `parses as JSON` lines are
deliberately unpinned, for the reason given beside them. That is the only reason to believe any of them, and the
launch one has now been wrong twice in a way its own green lines could not show. Its first
version asserted `pgrep -x -f` as its own literal text and passed against the
broken script it was written to catch. The replacement went the same way for a
subtler reason: it reconstructs `running()` by `sed`-ing one line out of the
script under test, which silently yields nothing callable for four of the five
ways to spell that function — every probe then exits 127, prints `miss`, and the
assertion reports "0 false hits" having tested nothing. It now asserts the
extracted name is callable before trusting the count — and, because that proved
insufficient the same afternoon, that all eight probes came back with a VERDICT.
`BIN_RE` was added to `pet.sh` hours later; the extracted `running()` referenced
it, the probe did not set it, every subshell died on `set -u`, and the
assertion counted zero hits among zero verdicts and reported ok. Both failures
were "the extracted function did not run", so the guard now counts what came
back rather than naming a cause. Counting verdicts still cannot see an
extracted `running()` that runs and never matches — a body refactored to
delegate to a helper the `sed` misses turns every probe into a clean 127
"miss", 8 verdicts, 0 hits, ok — so a POSITIVE control now runs first: the
extracted function must report a HIT against a stub genuinely live at `$BIN`
before its silence about anything else is believed. A third escape is measured rather than
suspected: removing `-x` from `running()`'s pgrep leaves all thirteen lines
GREEN whenever the eight concurrent probes fail to overlap — probe-self-match
detects that mutant by timing luck, not by construction. The mutation gate
therefore uses the UNESCAPED `BIN_RE` as its launch-race case, which the
`cfg+test (1)` scenario reds deterministically.

`tools/run-mutation-gate.sh` runs the whole argument above as one command: it
generates a mutant from HEAD for each of thirty-five defects a harness is named after —
never a committed copy, which drifts silently — asserts the anchor was actually
found and the file actually changed (a replacement matching nothing tests the
clean tree and passes forever), and requires the harness to go red.
`.github/workflows/harnesses.yml` runs the harnesses, the gate,
`run-release-checks.sh` and `run-hooks-check.sh` on every PR and push to main; the hooks check also runs on
a daily schedule, because the CLI it validates against moves without this repo
moving. The workflow is a thin caller — everything of substance is one of these
scripts and runs identically by hand. And thirteen green lines are not thirteen
guarantees: `staggered-16ms` and `staggered-20ms` sit past the top of
the race window, so they pass against a broken script too and the file labels
them negative controls rather than coverage.

Nothing else here has a test suite. Two scripts in `tools/` are not layer
harnesses and are not counted above: `run-hooks-check.sh` tests no Swift at all
— it asks the installed CLI whether `hooks/hooks.json` is loadable — and
`run-release-checks.sh` parses `.claude-plugin/plugin.json` and
`marketplace.json`, which nothing in CI had ever read. Thirty-four releases
shipped that one version line unchecked, and this repo IS the marketplace, so
the version landing on main IS the publish: there is no staging where a stray
comma could be caught later. Both belong to the same release gate, because both
catch failures that take the whole plugin down without printing anything.

The release one runs in its own ubuntu job rather than the macOS harness loop,
and is skipped by that loop the way `run-hooks-check.sh` and
`run-mutation-gate.sh` are. It needs no toolchain, and a manifest check that
dies alongside `swiftc` is a manifest check that never runs. Its checkout, and
the mutation gate's, both set `fetch-depth: 2`, because the version comparison
reads HEAD's parents.

It reads ALL of them, not `HEAD~1`. `HEAD~1` is only the FIRST parent, and the
hole that leaves was measured rather than argued: a feature branch that merged
main, resolved the version line keep-ours and was fast-forwarded onto main
takes main from 1.16.0 back to 1.15.1, and a `HEAD~1` baseline reports
`1.15.1 -> 1.15.1` and prints six green lines over the exact regression it
exists to catch. Walking every parent reds it, covers `pull_request` (the merge
commit's parents include the base tip) and still works at depth 2. It does NOT
see a regression buried mid-push — a two-commit push whose first commit
regresses and whose second leaves the line alone compares HEAD against its own
parent and passes; closing that needs the published baseline, which CI does not
have. The comparison is NON-DECREASING rather than strictly increasing: most
commits do not touch that line. A baseline it cannot resolve is an ERROR that
exits 1 WITHOUT printing a FAIL line, because `run-mutation-gate.sh` scores a
catch by counting red assertions, and infra death that spells itself FAIL is
exactly how a broken toolchain once reported "10 mutants caught".
"Verified" still means: it compiles, the examples still validate, `--export`
still round-trips, malformed manifests are still rejected, and you have looked
at a rendered frame. The harness is one more kind of evidence for the code it
covers, not a replacement for any of those.

**The built-in's art has no generator, and only one thing checks it.**
`examples/husky.json` is 449KB of row strings quantised from raster art, so
changing the built-in means replacing the whole file — there is no `build()` to
re-run, and nothing that will notice if the DRAWING comes out wrong. That is a real regression against 1.7–1.12, where the manifest was
emitted from parametric geometry and a guard held the two together; the
generator only ever drew the hippo, so it went when the hippo did. If the
built-in is ever generated again, bind the guard to this string and nothing
else — a copy parked under `examples/` puts the check one indirection from what
ships, and a drift between them is invisible to it.

`tools/run-art-checks.sh` is the one check that does exist: it is handed
every manifest in `examples/` as a path, the built-in among them — the files
that actually ship, with nothing in between to drift — plus the embedded
placeholder, which no path can reach. It answers exactly one question — is any
transparent pixel unreachable from the border — because that one is decidable
without knowing what the art is supposed to look like. It is not a substitute
for rendering a frame and looking at it, and it cannot be: a pet drawn as a
featureless blob passes.

`--export` hands back the TEXT of `examples/$PERCHLING_BUILTIN.json` as loaded,
not a re-serialisation of it, so whatever formatting is in that file is what a
user's `--export > draft.json` gets. Match what is there:
`JSONSerialization(.prettyPrinted, .sortedKeys)`, which Python reproduces as
`json.dumps(d, indent=2, sort_keys=True, separators=(',', ' : '))`.

Two things a change to the built-in's art still leaves behind, and both lie
quietly rather than failing: `docs/moods.gif` is the README hero, and the
README's `width=` must equal the GIF's real pixel width or the browser resamples
the pixel art into mush. Regenerate both in the same change. The GIF tool encodes its own output and decodes it back pixel-for-pixel
before it will exit 0, so a green run really does mean the file is right — and
two runs of it are byte-identical, so a diff on `docs/moods.gif` means the art
moved.
