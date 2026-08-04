# Working on perchling

A Claude Code plugin: one Swift file compiled to a ~200KB accessory-app
overlay, driven by hook scripts that write mood files. No package manager, no
test framework, no dependencies. `README.md` covers what it does for a user —
this file covers what will waste your time if you assume it.

## Changes reach the running system by two different paths

- **`scripts/pet.swift`** — `bash scripts/pet.sh build` recompiles
  `~/.claude/perchling/bin/perchling` from *this* checkout. Live on next
  launch. Fast loop.
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

Verify without launching:

- **Manifest correctness** — `perchling --validate <path>` runs the same parser
  the renderer uses; `perchling --export` prints the built-in pet as a manifest.
- **Window geometry** — compile a throwaway `CGWindowListCopyWindowInfo` probe
  and assert on the bounds reported for the already-running pet.
- **Rendered frames** — copy `pet.swift` to a scratch directory, cut everything
  from `let argv = CommandLine.arguments` onward, and append a harness that
  puts a `PetView` in an offscreen `NSWindow` and calls
  `cacheDisplay(in:to:)` per tick into a filmstrip PNG. This exercises the real
  `draw()`, so what you see is what ships.
- **Pixel art** — rasterize a manifest to PNG yourself and look at it. Grid
  dimensions passing validation says nothing about whether the creature reads.

`screencapture` needs Screen Recording permission that a shell spawned by
Claude Code generally lacks, and the desktop-control tools cannot target
perchling because it has no `.app` bundle. Neither is a viable fallback.

## Invariants worth not rediscovering

- **Art lives in the original 32×33 design space.** `RES` multiplies every
  coordinate and `cell()` expands each source cell into a `RES × RES` block.
  Write new sprite coordinates in design space and pass them through `cell()`;
  hand-multiplying by `RES` at a call site is how the two spaces drift apart.
- **`canvasSize()` is the only place window dimensions are decided.** It
  reserves `3 × bounceUnit` cells below the art for the bounce and
  `bounceUnit` on each side for the twitch. A hardcoded margin here previously
  clipped the pet's feet, made an exported manifest a different size from the
  pet it copied, and sliced the leading column off wide custom pets — three
  bugs, one assumption.
- **Motion is measured in points, not cells.** `bounceUnit(scale)` keeps travel
  at roughly four points whatever a pet's cell size is.
- **Reduce Motion freezes `tick`, not the poll clock.** Anything shaped like
  `deadline = tick + n` must be armed only when motion is allowed, or `tick`
  never reaches it and the state sticks forever. Liveness and mood changes must
  keep working while frozen.
- **Only the chip takes clicks.** `ignoresMouseEvents` is per-window, so a
  button hung off the bubble would cost the whole 260-point rect the
  click-through that lets it sit over other windows. Anything tappable that
  belongs to the bubble needs its own window, the way the chip does — and the
  chip is placed to clear the bubble's rect entirely, so neither draws over
  the other.
- **A manifest carries pixels, not behavior.** Custom pets get one static frame
  per mood. Cursor-following pupils, blinking, and any tick-driven animation are
  renderer-only and cannot be expressed in `pet.json`; anything new in that
  family widens the gap between the built-in pet and custom ones.
- **`state.sh` runs on every prompt and every tool batch.** Keep it cheap, never
  let it fail a hook, and do not add a `jq` dependency — the existing `sed`
  extraction style is deliberate. Hook payloads arrive as one blob on a pipe the
  harness holds open, so it reads with a single `dd bs=65536 count=1` rather
  than to EOF.
- **Session files are both mood and refcount.** Writing one re-stamps liveness;
  never `touch` one, because that resurrects a stale mood with a full TTL. The
  `manual` entry is a bridge for launches with no session behind them, retired
  by the first real session or by the last `SessionEnd` — it is not a session
  and must not outlive them.
- **A refcount is owned.** `sessions/<sid>` is paired with `owners/<sid>`, the
  pid of the outermost process the session hangs off — Claude desktop, or the
  terminal that ran `claude`. A dead owner retires the session on the next
  poll, which is what makes a force-quit (where no `SessionEnd` ever fires)
  survivable. A missing owner file means unknown, never dead: it falls back to
  the one-hour staleness window. Whatever writes a session file owes it an
  owner file, and owes both a removal.
- **The 30s empty grace is for gaps, not for deaths.** It exists to ride out
  the pause between one session ending and the next starting — a resume, a
  `/clear`, a new window. Both ways of losing every session skip it: refcounts
  orphaned by an owner that died, and an empty directory whose last known
  owners are all gone. The ordinary quit takes the second path, not the first
  — `SessionEnd` really does fire on ⌘Q and removes the refcounts properly, so
  a pet that only handles orphans still sits there for the full 30 seconds
  after the app is gone.

## Commands

```bash
bash scripts/pet.sh build     # recompile the binary from this checkout
bash scripts/pet.sh status    # binary / process / state / session count
bash scripts/pet.sh stop      # drop refcounts and kill the pet
~/.claude/perchling/bin/perchling --validate examples/sprout.json
~/.claude/perchling/bin/perchling --export > /tmp/draft.json
```

There is no test suite. "Verified" means: it compiles, the examples still
validate, `--export` still round-trips, malformed manifests are still rejected,
and you have looked at a rendered frame.
