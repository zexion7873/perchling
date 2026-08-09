# Working on perchling

A Claude Code plugin: one Swift file compiled to an accessory-app
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
  calls `cacheDisplay(in:to:)` on a `PetView` per tick into a filmstrip PNG.
  This exercises the real `draw()`, so what you see is what ships.
  `tools/moods-gif.swift` is a worked example of the same cut. Give the view no
  window: `gaze()` returns neutral without one, whereas a view in a window aims
  its pupils at wherever the mouse happens to be, which is how a render stops
  being reproducible. Blit the cached `CGImage` with `interpolationQuality`
  `.none` — going through `NSImage.draw` blends every pixel with its neighbour
  and turns nine flat inks into a million.
- **Session/tray logic** — `Mood.parse`, `liveSessions`, `menuRows`,
  `sessionName`, and `sessionTitle` all sit above the runtime-home block, so a
  harness for them should cut there instead of at `let argv`: cutting at `let
  argv` still runs that block at load time, which touches
  `~/.claude/perchling/` — the very directory this file forbids writing to.
  Cut before `// Runtime home:` and stub the one global a still-included type
  reaches for: `let examplesRoot: URL? = nil`. The shell side has the same
  trap: `pet.sh up` ends in `running || ... nohup "$BIN" ...`, so calling it
  directly starts a real overlay. Point `CLAUDE_CONFIG_DIR` at a scratch
  directory, then neutralise the launch path by dropping a no-op executable at
  `<scratch>/perchling/bin/perchling` with a mtime newer than `pet.swift` —
  `cmd_up` then skips its rebuild check and `nohup` launches the stub, which
  exits immediately instead of opening a window.
- **Pixel art** — rasterize a manifest to PNG yourself and look at it. Grid
  dimensions passing validation says nothing about whether the creature reads.
- **Mood changes** — poll `sessions/<sid>`, never `state`. `state.sh`
  overwrites the global file unconditionally, so it reads last-writer-wins and
  any second live session stomps it. The renderer reads it, but only as one
  more input folded by priority alongside every `sessions/*` entry — and with
  its own shorter TTL — so it is a fine puppet string and a bad measurement.
  For anything keyed to a prompt appearing on screen, get the ground truth
  from the macOS unified log rather than asking the user — query
  `NotificationCenter` for bundle `com.anthropic.claudefordesktop` and read the
  `NotificationRecord` request id, which timestamps when the banner appeared
  and when it cleared. Use `/usr/bin/log`; the bare name is a zsh builtin and
  silently does something else.

`screencapture` needs Screen Recording permission that a shell spawned by
Claude Code generally lacks, and the desktop-control tools cannot target
perchling because it has no `.app` bundle. Neither is a viable fallback.

## Invariants worth not rediscovering

- **Art lives in the original 32×33 design space.** `RES` multiplies every
  coordinate and `cell()` expands each source cell into a `RES × RES` block.
  Write new sprite coordinates in design space and pass them through `cell()`;
  hand-multiplying by `RES` at a call site is how the two spaces drift apart.
  The shell and torso are the one place expansion is not cell-blocky:
  `lathe()` slides each design row's span toward the next across its `RES`
  sub-rows, because a profile stepped 3px at a time scallops the silhouette
  while every other rounded edge in the art steps 1px. Its profile is still
  written in design cells.
- **A limb that leaves its resting place has to be overlaid, not unioned.**
  `buildBase()` builds the 1.1 body from two `lathe()` profiles joined by a
  waist — the head is the wider profile, the torso the narrower one below
  it — plus a pair of square `rrect` legs (rounding a 5x4 leg at this size
  costs its planted look, and the outline is most of the leg anyway).
  `buildBase()` still merges shell, torso, and legs into one mask and
  `shade()` derives every ink from neighbour tests over that mask, so an arm
  unioned into it at any height stops being an arm and becomes a lump on
  whatever it touches. Both of the built-in's arms are already built this
  way — each is its own mask, shaded on its own, and stamped over the base —
  which generalises what used to be a wave-only trick into how every arm
  works, resting or not, and is what gives each one an outline of its own
  instead of melting into the shell. Each arm is ONE uniform 4-cell pill,
  not a shoulder welded to a forearm: those overlapped, so the arm was widest
  in the middle and grew outward as it descended, which reads as a flexed
  deltoid. Four cells is the floor, not a preference — three is all outline
  once `shade()` takes its ring, and reaching past column 4 drops the
  arm-to-torso overlap to zero so the limb floats. The wave was the original reason for
  the rule and was retired in 1.0.1: its elbow was anchored at hip height,
  where the resting arm nub sits, so the raised arm spanned hip-to-glass with
  zero transition frames and read as a creature suddenly extending a limb,
  not waving one. The 1.1 rework gives the body real shoulders and proves the
  overlay rule at the resting arms, but the wave itself is still retired —
  nobody has rebuilt it on the new geometry, and its old operational details
  (which frames end on the dark glass, the elbow's overlap margin, the
  parameter that dropped the resting nub) do not carry forward regardless,
  since a new shoulder is new geometry from scratch.
- **The only way to draw a line INSIDE the pet is to stamp a separately
  shaded mass.** `buildBase()` merges shell, torso and legs into one mask, so
  `shade()` can only ever derive the OUTSIDE contour — which is why the head
  was a flat coral field with a rim, and why five rounds of reshaping its
  `lathe` profile could not give it a feature (a lathe is one centred span
  per row, so it can only produce a convex silhouette; every bump that would
  break that reads as ears, an antenna or a hood). The arms already dodged
  this; the brim over the visor is the same trick pointed at the head, and it
  is what makes the screen read as set into the shell rather than painted on
  it. Two limits worth not rediscovering: the head's contrast budget is spent
  at ONE band, because a second starts reading as stripes on a light desktop;
  and an overlay can never fix the SILHOUETTE, since `rrect` expands
  cell-blocky while the head expands through `lathe`'s sub-row slide, so an
  overlay cannot even follow the existing contour. Also fixed forever: the
  forehead cannot grow, because the casing's top is frozen at design row 4
  and the head cannot start above row 0, so every row a taller head buys
  lands below the visor as blank chin.
- **The glass carries eyes only, and `Ink.errorX` exists for exactly one
  thing: error's X.** 1.1 retired `.scanline` and `.blush` along with the
  corner glint and the terminal ticker — nothing stamps onto the glass now
  except `eyeRects`'/`startledRects`'/`tearRects`'/`sparkleRects`'
  `.eye`/`.glyph`/`.errorX`, so a face
  idea that used to live on one of those retired inks needs a home in one of
  the three survivors or it does not ship. `errorX` is not a reuse of
  `.shade` — error's cross needed its own hex once the palette split face
  inks apart, and it is the one face ink that is not amber.
  `tools/moods-gif.swift` keeps its own literal `inks` array mirroring the
  enum's cases, so any change to `Ink` — addition, removal, or reorder —
  has to be mirrored there too, or the GIF tool's ink-count assertion fails
  at regen time instead of at compile time; `.scanline`/`.blush` going away
  is exactly as much a mirror update as a new ink arriving.
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
  per mood. Cursor-following pupils, the doze-and-peek cycle, and any tick-driven animation are
  renderer-only and cannot be expressed in `pet.json`; anything new in that
  family widens the gap between the built-in pet and custom ones.
- **The active pet is a symlink, and its target is the only record of which
  pet is active.** There is no config file and must not be one: a "selected
  pet" setting would be a second source of truth that can disagree with the
  file actually being rendered. `pollPet` already resolved symlinks before the
  library existed, for dotfiles setups, which is why the renderer needed no
  change. Two things follow. A shipped pet is copied into `pets/` before it is
  linked, because the plugin path carries a version number and is replaced
  wholesale on update — a link into `examples/` dangles the moment the user
  runs `plugin update`. And `pet.json` arriving as a regular file is the
  pre-library state, not a corruption: it gets moved into `pets/`, never
  linked over, because it may be the only copy of a pet someone drew. That is
  not a launch-time concern that migration retires — the process outlives a
  whole session, and `pet.json` can go back to being a loose file at any point
  in it, so every path that removes `pet.json` rescues it first and refuses the
  removal outright when the rescue cannot finish. A rescue that fails quietly
  and then deletes is the same data loss with more steps.
- **A checkmark means "on screen", which is not "what the link points at".**
  A manifest that fails to load leaves `pet.json` pointing at it while the
  built-in is what renders, and a dotfiles `pet.json` can point outside `pets/`
  at a pet with no row in the menu at all. `PetView.custom` is the only honest
  answer — `pollPet` clears it on every fallback — so the menu asks that rather
  than deriving the tick from the list. Fixing one row's rule without the other
  produces two checkmarks.
- **Not every wait announces itself, and not every announcement reaches the
  plugin.** `waiting` has two triggers: the `Notification` event, whose matcher
  is a regex over the notification type (`permission_prompt` also catches
  `worker_permission_prompt`), and a `PreToolUse` matcher on the tools that
  block on a human — asking a question and presenting a plan. **In the Claude
  Code desktop app only the second one ever fires.** The app posts a macOS
  banner with a `permission-<uuid>` request id for every blocking prompt
  whatever the tool, and an `idle-<session>` one for the waiting-on-you nudge;
  across nine such banners the `Notification` hook wrote nothing, not even for
  a permission window held open 220 seconds. `waiting` tracked the `PreToolUse`
  tool list exactly. The terminal CLI does dispatch the event. The user-facing
  banner and the plugin-facing hook event are separate mechanisms — seeing the
  banner says nothing about the hook, which is the easy way to get this
  backwards. `PreToolUse` cannot cover the gap either: it runs before the
  permission check, so it cannot tell a call that will prompt from one that
  will just run. A new blocking affordance needs its own trigger; nothing
  generic covers it. Nothing has to clear it: the next tool batch writes
  `running` on its own.
- **`state.sh` runs on every prompt and every tool batch.** Keep it cheap, never
  let it fail a hook, and do not add a `jq` dependency — the existing `sed`
  extraction style is deliberate. Hook payloads arrive as one blob on a pipe the
  harness holds open, so it reads with a single `dd bs=65536 count=1` rather
  than to EOF.
- **Session files are mood, refcount, and label.** Line one is the mood; an
  optional line two is that session's `cwd`, which the tray rows show and the
  fold ignores. `Mood.parse` reads line one, so the one-line form stays valid
  forever — `pet.sh up` writes it whenever there is no payload behind the
  launch (`manual`, `enable`, `wake`). Writing a session file re-stamps
  liveness; never `touch` one, because that resurrects a stale mood with a
  full TTL. The `manual` entry is a bridge for launches with no session behind
  them, retired by the first real session or by the last `SessionEnd` — it is
  not a session, must not outlive them, and must not appear in the tray.
  Hook payloads do carry `cwd`: observed on seven event types so far —
  `UserPromptSubmit`, `Stop`, `SessionStart`, `SessionEnd`, `PreToolUse`,
  `PostToolUse` and `PostToolBatch` — each from a real headless CLI run, not
  read off the docs. In every one of those seven, `"cwd"` occurred exactly
  once, including on tool events carrying `tool_input`, so the greedy-`sed`
  hazard the extraction knowingly accepts has not actually bitten yet.
- **`sessions/` is read for moods in exactly one place.** `liveSessions()`
  owns the owner-alive guard, the one-hour staleness cutoff, and the per-mood
  TTL decay, and both the attention fold and the tray rows consume its
  output — a second *mood* scan is how the face ends up showing idle while
  the menu says "thinking…". `pollSessions()` walks the same directory too,
  for the 30s-empty-grace liveness check, but never touches a mood — it is
  not the second reader this bullet forbids, and adding one that reads a mood
  would be.
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
bash tools/make-moods-gif.sh  # regenerate the README hero from this checkout
~/.claude/perchling/bin/perchling --validate examples/sprout.json
~/.claude/perchling/bin/perchling --export > /tmp/draft.json
```

There is no test suite. "Verified" means: it compiles, the examples still
validate, `--export` still round-trips, malformed manifests are still rejected,
and you have looked at a rendered frame.

Changing the built-in's art leaves two generated artifacts behind, and both of
them lie quietly rather than failing: `examples/perchling.json` *is* `--export`
output, and `docs/moods.gif` is the README hero. Regenerate both in the same
change. The GIF tool encodes its own output and decodes it back pixel-for-pixel
before it will exit 0, so a green run really does mean the file is right — and
two runs of it are byte-identical, so a diff on `docs/moods.gif` means the art
moved.
