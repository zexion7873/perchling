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

**Agents are not the only way to get several pets, and blaming them was the
wrong diagnosis.** Three overlays were observed on the user's desktop at once
with no agent involved: three ordinary sessions hit `SessionStart` inside the
same few milliseconds and `cmd_up`'s check-and-launch had nothing atomic
between its halves. The window is a property of the machine and it MOVES:
callers staggered by **4–12 ms each launch their own pet** here, where the
figure was 4–16 when first measured, and past the top of it the first pet is
already visible and the rest correctly stand down. `launch_once` closes it with
a `mkdir` mutex — macOS ships no `flock(1)` — and the lock is held until the
child is VISIBLE to `running()`, not merely until `nohup` returns, because
releasing at spawn time only narrows the window rather than closing it. It is
reclaimed after a minute so a process killed mid-launch cannot wedge every
future session start.

**Reclaiming that lock is a second critical section, and 1.13.0 shipped it as a
plain check-then-act — the same defect one level in**, measured at four pets
from eight callers. The trap worth carrying out of `launch_once`'s own comment:
making the reclaim ATOMIC does not fix it, and was measured failing the same
way. `rmdir` is a genuinely exclusive claim, but the staleness verdict it acts
on comes from a `find`, and a fork+exec is long enough for somebody else to
reclaim and take the lock. Serialising reclaim is what works, and the freshness
re-test inside that lock is load-bearing rather than belt-and-braces: dropping
it alone still launches two.

The reclaim also has to survive a lock it cannot `rmdir`. That call refuses a
non-empty directory and nothing else clears the lock, so anything that ever
lands inside one wedges every future launch permanently — the exact failure the
reclaim exists to prevent. Nothing writes in there, so it takes an outside
cause, which is the kind of thing a lock has to survive rather than assume away.
A stale lock that will not `rmdir` is RENAMED aside: one syscall, works on a
non-empty directory, and leaves the debris where a human can look at it.
`rm -rf` on a path built from an environment variable is not something this
script should own.

Verify without launching:

- **Manifest correctness** — `perchling --validate <path>` runs the same parser
  the renderer uses; `perchling --export` prints the built-in pet as a manifest.
- **Window geometry** — compile a throwaway `CGWindowListCopyWindowInfo` probe
  and assert on the bounds reported for the already-running pet.
- **Rendered frames** — copy `pet.swift` to a scratch directory, cut everything
  from `let argv = CommandLine.arguments` onward, and append a harness that
  calls `cacheDisplay(in:to:)` on a `PetView` per tick into a filmstrip PNG.
  The cut has to keep `builtinPet`, or a `PetView` with no pet draws nothing —
  and `builtinPet` sits BELOW the runtime-home block, not above it, because it
  needs `root` to know which file to load. Cutting at `let argv` keeps it;
  cutting where the session harness cuts does not, and a harness that cuts
  there has to stub it the way that one does. (There is no `BUILTIN_MANIFEST`
  to keep. The built-in's art has been a file since 1.14.)
  This exercises the real `draw()`, so what you see is what ships.
  `tools/moods-gif.swift` is a worked example of the same cut. Give the view no
  window: `gaze()` returns neutral without one, whereas a view in a window aims
  its pupils at wherever the mouse happens to be, which is how a render stops
  being reproducible. Blit the cached `CGImage` with `interpolationQuality`
  `.none` — going through `NSImage.draw` blends every pixel with its neighbour
  and turns a handful of flat inks into a million.
- **Session/tray logic** — `Mood.parse`, `liveSessions`, `foldMoods`,
  `menuRows`, `sessionName`, `sessionLabels`, `sessionTitle`, `bubbleText`,
  `registryNames`, `cleanName`, `desktopTitles` and `TitleEntry` all sit above
  the runtime-home block, so a harness for them has to cut there instead of
  at `let argv`: cutting at `let argv` still runs
  that block at load time, which touches `~/.claude/perchling/` — the very
  directory this file forbids writing to. `bash tools/run-session-harness.sh`
  already does exactly this — it cuts `pet.swift` before `// Runtime home:`,
  stubs the four globals a still-included type reaches for (`examplesRoot`,
  then `builtinLoaded`, `builtinText` and `builtinPet`, which moved below the
  cut when the built-in's art became a file), appends
  `tools/session-harness.swift`, and
  compiles and runs the result — so reach for it rather than hand-rolling the
  cut again. The reasoning above is not a one-off justification for that
  script; it is why any future addition to this layer belongs above that line
  too. The shell side has the same trap: `pet.sh up` ends in `launch_once &`,
  so calling it directly starts a real overlay. Point
  `CLAUDE_CONFIG_DIR` at a scratch directory, then neutralise the launch path
  by dropping a stub at `<scratch>/perchling/bin/perchling` with a
  mtime newer than `pet.swift` — `cmd_up` then skips its rebuild check and
  launches the stub instead of opening a window. THREE things about that stub,
  and the third one exists because the first two, written on their own, walked
  a later agent straight into opening two real pets on the user's desktop:
  it must be a COMPILED executable, because a script's argv is
  `/bin/bash <path>` and `running()`'s `pgrep -x -f "$BIN"` rightly will not
  match that — so a script stub is invisible to the check under test; it
  must STAY ALIVE, because a stub that exits immediately is never visible to
  `running()` either, so every caller legitimately launches one and a harness
  measures nothing; and it must **NOT be a copy of the real binary**. That last
  one is not obvious, it is the CHEAPEST way to satisfy the other two, and it is
  wrong for the one reason this whole section exists: a copy of
  `~/.claude/perchling/bin/perchling` is a compiled executable that stays alive
  by opening a pet window. Copies were found in 55 scratch directories from a
  single fan-out, two of them running. `cp` the real binary here and you have
  written a harness whose passing condition is littering the desktop.
  `tools/run-launch-race.sh` compiles a five-line C stub for exactly this and is
  the worked example: the stub must be something you BUILT, whose entire
  behaviour you can read.
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

- **There is no drawing code, and as of 1.14 there is no embedded art either.**
  The built-in is a pet in `examples/`, named by `PERCHLING_BUILTIN` and
  defaulting to `husky`, parsed through the same
  `loadCustomPet` a user's `pet.json` goes through, and `--export` hands the
  loaded TEXT straight back — so the export is an exact round-trip rather than a
  re-serialisation, and there is exactly one copy of it in the repo. It used to
  be 449KB of string literal called `BUILTIN_MANIFEST`, which is most of why the
  binary was 917KB and is now 458.

  Selecting it by NAME rather than by path is what makes swapping the default
  creature one line, and the menu needs no help: `petChoices` hides whichever
  shipped pet matches `builtinPet.name`, so the new built-in leaves the list and
  the old one joins it. The copy is compared by CONTENT rather than mtime,
  because a swap points at a different file that may be older than the copy
  already in place and an mtime test would decline to update it.

  Three more things follow, and the second is the one that bites. `pet.sh`
  copies the file into the RUNTIME HOME, and the renderer reads it from there
  rather than from the plugin directory — so an overlay launched by hand, with no idea which plugin started
  it, still finds its art. `builtinPet` therefore sits BELOW the runtime-home
  block, because it needs `root` to know what to load, which means every harness
  cutting above that line has to stub it (`run-session-harness.sh` and
  `run-art-checks.sh` both do, next to the `examplesRoot` stub they already
  had). And `builtinText` is the file with its trailing newline dropped, so
  `print()` puts exactly one back and `--export > draft.json` is byte-identical
  to the file it came from.

  What is still embedded is `PLACEHOLDER_MANIFEST`, 1.8KB, and it renders only
  when that file is missing or will not parse. Both mean a broken install rather
  than a choice, so it is deliberately plain — do not improve it into something
  that looks chosen. Do not park a copy of the husky under `examples/` either: a
  copy can drift from the file the app renders, and nothing would see it. The whole
  programmatic engine that used to draw the robot — `Ink`, its palette,
  `buildBase`, `lathe`, `shade`, `cell`, `merge`, `rrect`, and the `eyeRects` /
  `startledRects` / `tearRects` / `sparkleRects` overlays — is gone as of 1.7.0.
  Do not go looking for it, and do not restore a piece of it to add a behaviour:
  anything the pet does that a manifest cannot declare has nowhere to live.
  Git history is the only record of what that engine drew — the manifest is at
  `examples/robot.json` in the 1.12 tree, and nowhere in the working one.
- **`custom` means "the user picked something"; `activePet` means "what is on
  screen".** They were the same question while the built-in was drawing code and
  are not now — `custom` is still nil when no `pet.json` resolves, because the
  Pets menu's checkmark means "this is what you are looking at" and the built-in
  row can only answer that while "no user pet" stays representable. Every draw
  path reads `activePet`; the menu reads `custom`. Collapsing the two puts two
  checkmarks in the menu, or none.

  **`pose()` was the site that got this wrong**, and the symptom was not the
  one you would predict. Its sequence-selection block read `custom`, while the
  clocks feeding it are armed off `activePet` — so a built-in declaring `tap`
  had `mouseUp` set `tapSeqStart` instead of `hopUntil`, gave up the procedural
  hop, and then produced no frame: clicking the pet did nothing at all. Pinned
  now by two assertions in `tools/run-pose-harness.sh`, which sed-patches `let
  builtinPet` to `var` in its scratch copy so a harness can give the BUILT-IN a
  sequence. `PetView` is `final`, so overriding `activePet` was not open
  either, and a rule that cannot be tested is a rule that silently rots.
- **The chrome has its own colours and must keep them.** `CHROME_PANEL`,
  `CHROME_EDGE`, `CHROME_TEXT` and `CHROME_INK` used to be borrowed from the
  pet's ink palette, which was fine while one enum described both. A pet is a
  manifest now: borrowing would mean a user's pet repainting the bubble and the
  chip. The hexes are unchanged from 1.6 on purpose — the panels look identical.
- **Six behaviours died with the engine in 1.7.0, and which of them a pet has is
  now a property of the pet rather than of the code.** The hover startle,
  error's tear, done's sparkle, idle's doze-and-peek, the cursor-following gaze
  and the blink were all gated on `custom == nil` and all drew through the
  deleted overlays. A manifest can express every one of them, so the question is
  only ever what the shipped pet declares.

  - **hover, done, idle and error** are sequences on the husky. `error`'s is a
    slump rather than a tear, and it separates from `idle`'s breath by DIRECTION
    rather than amplitude (idle stretches up, error squashes down), so telling
    them apart does not depend on noticing how far either moved. `hover`'s is
    the exact inverse of `tap`: a poke compresses, a surprise recoils. Why a
    deformation and not a drawn startle is under the hover bullet below.
  - **gaze and blink are gone, and a RULE removes them rather than an art
    budget.** A mood loop takes the eye box; `waiting` is the only mood that
    ever carried either; the husky animates `waiting`. So a pet that animates
    everything has neither whatever it declares — and the husky declares no
    `eyes` at all, which settles it twice.

  Earlier editions argued gaze and tear out on measured geometry: amber bboxes,
  a coral margin, a five-row runway under the eye. Every one of those numbers
  came off the hippo and none survived the 1.13.0 swap — the husky's 44-ink
  palette contains no amber, and its art leaves 13 free rows above and 5 below
  where the hippo left 3 and 0. **A rejection binds only the art it was measured
  against.** Re-measure before treating either as ruled out.
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
  the other. That is not only a click concern now: both are frosted, and two
  translucent panels crossing double the tint exactly where they meet.
- **The chrome hangs off the ART, not off the canvas.** `chromeLayout()` is a
  pure function of the pet's frame and `PetView.artTopInset` precisely so the
  offscreen harness composes the same rects the Controller does. The inset
  matters because `canvasSize()` reserves headroom for the bounce AND a
  manifest pads its own grid on top of that: measured to the window, the
  bubble floated 23 points clear of a pet whose ink starts at row 13. The chip
  hangs off the same line — beside the top of the head, with the bubble's
  right edge flush to the chip's so the three read as one right-aligned
  column — and its screen clamp has to run BEFORE the bubble's x is derived
  from it, or a pet shoved against the screen edge moves the chip and leaves
  the bubble behind, breaking the one alignment the layout exists for.
  `CustomPet.inkTop` is ONE number across every pose — the highest row any of
  them reaches — and deliberately not one per pose. Per-pose tucks in tighter
  and was built that way first; it also drags the bubble and the chip upward
  every time the pet celebrates, and chrome that jumps whenever the mood
  changes is worse than chrome sitting a few points high. The cost is real and
  worth knowing: on a pet whose `done` reaches row 0 while every other pose
  starts at row 13, the fixed line buys back only about six points over
  measuring to the canvas. It buys the whole 23 on a pet that never lifts.
  And the inset is measured at the RESTING bounce, never the live one, or the
  chrome breathes along with the pet.

  **The shipped pet now exercises this**, so the paragraph above is a live cost
  rather than a hypothetical. Its sequences reach higher than its mood grids do,
  and `--validate` prints exactly that: `inkTop: 12 (moods alone: 13 —
  sequences reach higher, chrome moves up 1 rows)`. The bubble and the chip
  therefore sit one point higher than the moods alone would put them, in every
  mood, permanently. (The figures were 0 and 3 while the built-in was the hippo;
  they are a property of whichever pet ships, so re-read them from `--validate`
  rather than from here.) That it cannot become per-mood movement is
  structural rather than lucky: `artTopInset` reads `activePet.inkTop`, which
  is one stored value on `CustomPet`.
- **The bubble and the chip ARE vibrancy views; their drawing is a subview.**
  A view's own `draw()` runs before every one of its subviews, so an
  `NSVisualEffectView` added *under* a painting view lands on top of the text
  and the panel comes out a featureless grey slab — which is what the
  offscreen render showed, and it is not a harness artifact. Apple's own
  guidance is the same: compose vibrancy with subviews, never override its
  drawing. Three things follow. Vibrancy has no notion of shape, so both
  carry a `maskImage`, and its geometry comes from the same `bodyPath()` the
  painter strokes — a one-pixel disagreement leaves a frosted edge beside a
  drawn one. (Both masks are constants now. They were rebuilt on every move
  while the bubble had a tail chasing the pet's midline; the tail is gone,
  along with the pet-to-bubble connector it drew.) `appearance` is pinned to
  `.darkAqua`: the chrome sits on the
  wallpaper, not inside an app window, so the system's light mode says
  nothing about what is behind it, and following it turns the panel white
  under cream text. And the frost goes away on tuck or collapse and on nothing
  else: `applyChrome()` reads `tucked` and `collapsed` and never the mood. It
  used to fold away with an idle mood, on the theory that an idle pet keeps
  the desktop clean; the cost was that the one control for the bubble vanished
  exactly when the bubble was quiet enough to be in the way, and `.idle` now
  carries its own status wording so the panel is never an empty slab.
- **`CHROME_TINT` is a tint over the frost, not the panel.** The frost
  supplies the darkening and the legibility; the tint only pulls
  `.hudWindow`'s neutral grey toward the pet's warm brown, which is why 0.38
  looks far too transparent in any offscreen render and is right on screen.
  `.behindWindow` blending draws NOTHING through `cacheDisplay` — there is no
  window behind it — so the harness can verify the mask, the tint and the
  hide/show, and cannot verify the blur. Judge that one on a desktop, as 0.38
  was: it looks far too transparent in every offscreen render and is right on
  screen, so a future reader who only has the harness should not "fix" it.
- **A manifest carries pixels, and the two things it can say about them are
  where the eyes are and which frames animate.** A mood is one grid unless
  `sequences` gives that mood a clock. The doze-and-peek cycle cut between two
  drawn eye SHAPES and no manifest can express that; synthesising the second
  shape was built and removed, and the cycle left with the drawing code. The two
  declarations do not compose: a mood loop suppresses the eye box, so a pet is
  choosing per mood between eyes that track and frames that move.
  The optional `eyes` block (`box`, `socket`, and optional `range`/`lid`)
  buys two things: gaze, by shifting the box's contents
  and refilling the vacated pixels with `socket`, and blink, from a frame
  synthesised once at load. Everything about that block exists because
  the eyes cannot be FOUND: on a soft-shaded sprite the brightest inks inside
  the eyes are the surrounding rim's own highlights, so every detector returns a
  second copy of that rim and shifting it smears the frame. Two consequences
  worth not rediscovering. The box's border has to sit on flat colour, because
  a shift rewrites the whole box and a border crossing a gradient leaves a
  seam — verify with a difference map against the unshifted frame, where a
  correct shift changes exactly `box` pixels and nothing outside it. And
  `blink` is not guaranteed by declaring a box: synthesis needs pixels inside
  it brighter than `socket`, and `--validate` says `blink UNAVAILABLE` rather
  than failing when there are none.
- **Hover is a sequence or it is nothing.** `mouseEntered` arms
  `hoverSeqStart` only when the active pet declares `sequences.hover`, and the
  burst expires by elapsing rather than on `mouseExited` — there is no
  `mouseExited` — so no pet ever holds a hover state. A single drawn `hover`
  grid was built and removed before this: the reaction Codex plays on hover is
  its five-frame `jumping` row, so a one-frame version is the wrong shape.
  Synthesising one by opening the declared eye box was also built and removed —
  it keeps the pose's own lids and merely widens them, which is a squint, not a
  start. **The built-in declares one now**, and it sidesteps both objections
  without answering either: a squash/stretch deformation is at least two frames
  by construction, so "a one-frame version is the wrong shape" never applies,
  and it never touches the eyes, so it cannot come out a squint.
- **A sequence is either a reaction or a resting state, and the difference is
  when it stops.** `hover`, `drag` and `tap` arrive and get out of the way; the
  five mood names loop for as long as the pet is in that mood and restart when
  it changes, because `done`'s frames are an arc and a celebration joined
  halfway through lands before it jumps. `moods` is still required and is still
  what Reduce Motion shows. Priority is drag > tap > hover > mood loop, and
  **every arm below the first is reached by testing whether a frame was already
  produced, never by chaining another `else`**: a burst's clock stays armed
  after the burst is spent — only a drag clears it — so an `else if` matches on
  a spent burst, produces nothing, and silently swallows everything below it.
  That regression is one line away at all times, it has now been made twice
  (once against the mood loop, once against hover by the first `tap` arm), and
  `tools/run-pose-harness.sh` pins it for both clocks. Before that harness
  existed this paragraph claimed an assertion that did not.
- **`tap` outranks `hover`, and the reverse is dead code rather than a
  preference.** The cursor must be on the pet to click it, so `hoverSeqStart` is
  always armed when a tap arrives; a `tap` ranked below it could never play on
  any pet declaring both. The procedural two-cell hop survives for pets that
  declare no `tap`, and `mouseUp` arms exactly one of the two.

  **No shipped pet is one of those, so `hopUntil` is live code that the repo's
  own art never reaches.** Verified by parsing all six: chinchilla, husky,
  otter, sea-lion, shark and whale each declare `done, drag, error, hover,
  idle, running, tap, waiting`. Both arming sites are therefore unreachable
  here — the `else` at the `mouseUp` site needs no `tap`, and the arrival hop
  needs `sequence(for: .done) == nil`. It stays because a third-party manifest
  may omit either, which is exactly the pet that has nothing else to move. Do
  not read a green harness run as evidence it works: nothing in `tools/`
  mentions `hopUntil`, and no fixture in the repo exercises either branch.
- **A sequence's timing is `steps`, it is required, and `frames` is an unordered
  pose pool.** Each entry is `[frameIndex, ms]`, and a pose may appear several
  times under different holds — which is the whole point, because a real
  animation row is four drawings replayed on an accented clock, not six
  drawings. A missing `steps` is REJECTED rather than defaulted: a tempo that
  quietly fell back to a house value is indistinguishable from one authored that
  way, and the manifest is read on disk by a process whose stderr nobody sees.
  The single `ms` this replaced is gone from the format; a leftover one warns.
  Making `ms` accept either an Int or an array was considered and is the
  catastrophic version — an older perchling does `guard let n = m as? Int` and
  throws, which rejects the whole file and greys the pet's row out with no
  visible error. Each step quantises to `TICK_MS` independently, and the OK line
  prints the whole declared-to-resolved timeline, one line per sequence, because
  six numbers do not fit the semicolon-joined form the single duration used.
- **`plays` repeats a one-shot; it does not lengthen a loop.** A double hop is
  the same timeline run twice — the index wraps, the deadline does not — because
  storing the arc twice costs ~11KB per duplicated grid AND puts byte-identical
  cells inside a sequence, which the pipeline has an assertion against precisely
  so an accidentally padded row cannot get in. Since `steps` exists there is a
  second reason: a repeated pose costs two numbers, so padding `frames` is never
  the way to hold a beat. It is the exact dual of `mirror`:
  both are declared, both are meaningless on kinds that cannot use them, and
  both make `--validate` warn rather than fail. And in both cases the OK line
  must not print what the warning just called ignored — a repeat count or a
  "mirrors when dragged left" beside its own contradiction is worse than
  silence. `totalTicks` is therefore ONE pass, and the caller multiplies.
- **A playing sequence owns the body, and the shear is the one thing it does
  not take.** While a sequence plays, `pose()` pins the bounce to its resting
  value and zeroes the twitch, the gaze and the blink: the frames carry their
  own motion, so a bounce added on top double-counts a jump's lift, and the eye
  box is declared against the MOOD frames — on a real pet `done` already lands
  37.5% of it on the shell, and a lifted frame is worse. A mood loop therefore
  TRADES that mood's gaze and blink away, permanently rather than for a burst,
  and `waiting` is the only mood that had either — so animating `waiting` is the
  one that costs something, and a pet that animates it never blinks again,
  `blinkFrame` and all. The one exception is the tap hop, which outranks a mood
  loop and nothing else: a resting state is not a reaction, and a poke that
  visibly does nothing reads as a dead window. The arrival hop is the other
  half of that rule and goes the other way — it is not armed at all when `done`
  has a sequence, because those frames already are the celebration. The lean
  stays,
  because it is applied inside `fill()`, which every blit including the
  sequence's already passes through, and because it is the only thing telling
  the viewer which way the pet is being dragged: a manifest ships ONE
  direction-agnostic `drag` sequence, and mirroring is what gives it a second
  facing. Sequence frames also count toward `inkTop`, so a lifted frame moves
  the chrome for every mood, permanently, not only while it plays.
- **A sequence is mirrored only if it says it may be.** `mirror: true` on
  `drag` makes the renderer draw the frames flipped while the drag heads left;
  the frames as drawn always face right. The flag exists because the reflection
  is free and the consent is not: Codex spends a whole atlas row on
  `running-left`, and every one of its columns is a byte-exact flip of
  `running-right` — measured, max channel delta 0 — so shipping both directions
  is six grids of pure redundancy. But a flip also reverses any asymmetric
  detail: a badge, a logo, lettering. The renderer cannot tell those from the
  gait, and before this flag a manifest had no way to say so, which is why
  render-time mirroring was rejected outright. Now the author says. Two
  consequences: `mirror` means something on `drag` and nowhere else — a burst
  and a resting state both have no direction of travel — so `--validate` warns
  rather than failing and deliberately does not print "mirrors when dragged
  left" on a kind it just called ignored, and the
  facing is latched off **accumulated signed travel**, never off a single
  `mouseDragged` delta and never off `lean`. Both alternatives were written and
  are wrong in opposite ways: a per-event threshold is a velocity gate, because
  mouse events arrive at 60Hz or better and four points inside one of them is
  240 points a second — a gentle drag never crosses it however far it goes —
  while `lean` decays to zero the moment the hand pauses and would spin the
  creature round mid-drag. An accumulator has neither failure: jitter cancels
  because a wobble contributes both signs, and turning around costs
  `FACING_TRAVEL` plus whatever residue the previous direction left, up to twice
  it, which reads as shedding momentum.
- **Anything added to the manifest goes at the TOP LEVEL, never inside
  `moods`.** The mood loop rejects any key that is not one of the five, so a
  new grid parked in `moods` makes the whole file unloadable on every older
  perchling — the pet falls back to the built-in and its row greys out in the
  Pets menu, with no error anywhere the user can see. Unknown top-level keys
  are ignored by every version. Found the hard way, in one afternoon, by a
  single misplaced key. Inside `sequences` the rule INVERTS: an unrecognised
  sequence name is ignored rather than rejected, so a later perchling adding an
  eighth sequence does not make its manifests unloadable here — `--validate`
  warns on stderr and the file still loads. That inversion is what let the five
  mood loops ship without a format break: a manifest declaring `sequences.idle`
  loads on 1.4.0 and simply does not animate. It is also the reason a mood's
  frames go in `sequences` under the mood's NAME and never as a second key
  inside `moods`, which would be the unloadable version of the same idea.
  `moods` rejects because a mistyped
  mood is a mood that silently never shows; `sequences` ignores because a
  mistyped sequence is a reaction that silently never plays, and only one of
  those can take the whole file down with it.
- **Gaze rides a different unit for each kind of pet.** The built-in measures
  it in bounce units, because its eye rects are in design cells; a manifest
  measures it in its own `eyes.range` pixels, because the box is the only
  thing that knows how much headroom the eyes have. `Pose.dx` moves the whole
  sprite, so the eye offset needs its own `eyeDX`/`eyeDY` — reusing `dx` drags
  the body along with the glance. `gazeVector()` returns a DIRECTION, one of
  sixteen sectors with a deadzone dead ahead; callers scale x and y by
  different amounts because an eye box is wider than it is tall. Sixteen
  survives the rounding even at a two-pixel radius — all sixteen sectors land
  on distinct integer offsets — so the resolution is not decorative.
- **The side margin is one bounce unit and the twitch already spends all of
  it.** `sidePad()` is what keeps a shifted sprite from being sliced, and the
  twitch moves a custom pet by a full unit, so nothing else may move the body
  sideways at the same time. That is why the drag lean zeroes `dx` rather than
  adding to it: the two share one budget. Widening the budget is a
  `canvasSize()` change, and it drags `docs/moods.gif`'s dimensions and the
  README's `width=` along with it — the hero is sized `(canvas + 8) * 6`.
- **The drag lean is a shear, not a pose, which is why every pet has it.** The
  top of the sprite lags the direction of travel and the bottom stays planted;
  `fill()` applies it so the base, eyes, tear, sparkle and custom blit all
  inherit it from one place, exactly as they inherit `xpad`. Two things it
  must not become: state read inside `pose()`, which has to stay pure because
  `draw()` and `repaintIfChanged()` both call it — the decay belongs in the
  tick loop next to `tick += 1`, where Reduce Motion already gates it; and a
  uniform offset, which reads as the window sliding rather than the creature
  resisting. Codex spends two whole atlas rows (`running-left`/`running-right`)
  on this reaction; a shear is what it costs when a manifest has no second
  pose to cut to, and at true size it reads as a sway, not a run.
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

  The whole property is two lines of `clearPetLink` — their ORDER, and the
  `try` on the first, which makes a failed rescue throw before the removal
  below it can run. Swapping them or weakening that `try` to `try?` deletes a
  pet with no other copy, is a one-line diff, and reads in review like tidying.
  `tools/run-session-harness.sh` now calls this layer rather than merely
  compiling it: an unwritable `pets/` makes `clearPetLink` throw and leaves
  `pet.json` intact, and both mutations were shown to fail that pair. The
  collision suffix is asserted beside it, because a second rescue overwriting
  the first is the same loss one step along.
- **A checkmark means "on screen", which is not "what the link points at".**
  A manifest that fails to load leaves `pet.json` pointing at it while the
  built-in is what renders, and a dotfiles `pet.json` can point outside `pets/`
  at a pet with no row in the menu at all. `PetView.custom` is the only honest
  answer — `pollPet` clears it on every fallback — so the menu asks that rather
  than deriving the tick from the list. Fixing one row's rule without the other
  produces two checkmarks.
- **Not every wait announces itself, and not every announcement reaches the
  plugin.** `waiting` has three triggers, and they cover different failures
  rather than duplicating each other. `PermissionRequest` fires whenever a tool
  call needs a permission decision; it takes no matcher because the point is
  that it does not depend on knowing which tools block. The `PreToolUse` matcher
  covers the affordances that block on a human WITHOUT entering the permission
  flow at all — asking a question, presenting a plan — which no permission event
  can see. The `Notification` event matches a regex over the notification type
  (`permission_prompt` also catches `worker_permission_prompt`).
  **In the Claude Code desktop app the third one never fires, and the reason is
  structural rather than a bug.** The app launches the CLI with
  `--permission-mode auto --permission-prompt-tool stdio`, so a decision leaves
  as a control-protocol `can_use_tool` request and the app draws its own dialog;
  Claude Code's own notification path is never reached. Measured with one prompt
  and a forced `permissions.ask` rule, varying only the host:

  | host / path | fires at the permission decision |
  |---|---|
  | interactive terminal CLI | `PermissionRequest`, then `Notification` |
  | `--permission-prompt-tool stdio` (what the desktop app runs) | `PermissionRequest` only |
  | headless `-p` | neither, even though the decision was genuinely required |

  So **headless is not a proxy for either host** — a probe run under `-p` that
  sees nothing has measured nothing. The user-facing macOS banner and the
  plugin-facing hook event are separate mechanisms too; seeing the banner says
  nothing about the hook, which is the easy way to get this backwards.
  `PreToolUse` still cannot cover the permission gap — it runs before the
  permission check, so it cannot tell a call that will prompt from one that will
  just run — and that is exactly why `PermissionRequest` is its own arm instead
  of a wider `PreToolUse` matcher. It does not fire when a rule or the
  classifier already allowed the call, so it cannot manufacture a false
  `waiting`, and a false one would self-heal anyway: nothing has to clear
  `waiting`, the next tool batch writes `running` on its own.
- **Adding an event name to `hooks/hooks.json` is a compatibility decision, and
  getting it wrong is silent and total.** An event key the running CLI does not
  recognise voids EVERY hook in the file, not just its own entry — so the pet
  never launches at all, no `SessionStart`, no error anywhere the user can see.
  Measured one variable at a time with throwaway plugins and a
  `UserPromptSubmit` canary: `UserPromptSubmit` alone fires, `PermissionRequest`
  + `UserPromptSubmit` fires, and adding one bogus key to either kills both.
  **A `--settings` file does the exact opposite and ignores unknown keys**, so a
  probe run with `claude --settings` proves nothing about this file; they are
  separate validators with opposite failure modes, and the permissive one is the
  easy one to reach for. The published docs describe the permissive behaviour
  for both, and are wrong about plugins. `bash tools/run-hooks-check.sh` is the
  gate; it has to copy `plugin.json` and `hooks/` to a scratch directory first,
  because `claude plugin validate` pointed at this repo finds
  `.claude-plugin/marketplace.json` and validates that instead, never reaching
  hooks.json. Before adding an event, establish how far back it is accepted by
  running an old CLI's own `plugin validate` — the tarballs are on npm and that
  subcommand needs no auth. `PermissionRequest` was cleared this way back to
  2.1.109, over a hundred releases; 2.0.x demands auth before validating and was
  not measured.
- **A row string is walked as utf8 BYTES, and the Character walk beside it is
  the fallback rather than dead code.** Iterating a `String` by `Character`
  segments grapheme clusters on every pixel, and a pet is tens of thousands of
  them: that walk alone was 140ms of a 220ms parse, against 3.7ms for the same
  walk over `row.utf8`. **Every aggregate in this bullet was measured against a
  twelve-file `examples/`; six ship today**, so treat the totals as upper
  bounds and the per-pet figures as the part that transfers. It matters
  because `petChoices()` parses EVERY manifest in `examples/` and `pets/`
  synchronously on the main thread before the Pets menu can be drawn — 220ms of
  right-click latency that no user could mistake for anything but a hang. The
  whole parse is now 44ms. Three things about the shape of that fix.
  The bytes are MATERIALISED with `Array(row.utf8)` rather than walked lazily,
  because the utf8 view charges per-element bookkeeping an array walk does not:
  84ms against 46ms across that same library. A separate `asciiPalette` flag was
  written first and deleted as dead weight — a row can only USE a non-ASCII
  palette key by carrying a byte over 127, which the byte walk already declines,
  so one condition covers both cases. And the fallback is not only about
  reaching the same verdict: a rejection has to name the CHARACTER the author
  wrote, not one byte of it, which only the Character walk can do.
  `tools/run-manifest-checks.sh` pins the pair with seven cases — a star, a CJK
  and an emoji palette key must LOAD, and a non-ASCII glyph under an ASCII
  palette must be rejected by its character — and every one of them was shown to
  go red when the fallback is removed. The change was also diffed against the
  pre-change binary over 13 hand-built edge cases plus every example in that
  twelve-file library, whole output and exit status, three runs each: identical.

  **Do not write that diff against fixtures that put the same defect in several
  moods.** `loadCustomPet` walks `moods` as a Swift Dictionary, whose iteration
  order is randomised per process, so whichever broken mood is visited first is
  the one named — the OLD binary alone reported four different moods across
  eight runs of one file. Put the defect in exactly one mood and the comparison
  is deterministic.
- **`pgrep -f "$BIN"` cannot answer "is the pet running", because the probes see
  each other.** `-f` matches any process whose whole argv CONTAINS the pattern,
  and a concurrent `pgrep -f "$BIN"` has that path in its own argv. Measured:
  eight simultaneous probes against a path **no process was running from** all
  eight reported a hit. So the same burst of session starts that can launch
  several pets can also launch NONE — every caller concludes one is already up —
  and `pet.sh status` will say `running` beside an empty screen. `running()`
  therefore uses `pgrep -x -f`, which requires the argv to EQUAL "$BIN": the
  overlay's does, since it is exec'd as `nohup "$BIN"`, and a probe's never can.
  The three `pkill` sites carry `-x` for the same reason — without it a teardown
  can match and kill somebody's in-flight `pgrep`. Two consequences for anyone
  writing a harness. A shebang-script stub is invisible to `-x -f`, because its
  argv is `/bin/bash <path>` — but do not read that as "so copy the real
  binary", which satisfies it and opens a pet window; the stub rule has a third
  clause and it is under "Do not launch the overlay to see if it works" above.
  And `pgrep -x perchling` was rejected as the alternative precisely because it
  matches by process NAME and would see an unrelated install, which breaks the
  scratch-`CLAUDE_CONFIG_DIR` isolation every test here depends on.

  **`-x` is not enough on its own, because the pattern is a REGEX and `$BIN` is
  a path the user chose.** A config directory named `cfg+test (1)` makes `+` a
  quantifier and `(1)` a group, and the pattern then matches nothing: measured
  against a process genuinely running from such a path, `pgrep -x -f "$BIN"`
  reports NOT FOUND. Both halves break at once and neither says so — `running()`
  reports stopped beside a visible pet, so each session start adds another, and
  all three `pkill` sites match nothing, so `stop` and `disable` stop nothing.
  `BIN_RE` is escaped once beside `BIN` and is what all four uses match on.
  Matching literally with `ps -Awwo args= | grep -qxF` removes the class of bug
  instead of escaping it, and lost on cost: 33.9ms against pgrep's 20.7 per
  call, in a function polled up to 50 times per launch.

  The assertion for this must be the ALREADY-RUNNING shape, never a stampede.
  A stampede cannot see it: the lock serialises the callers, the holder spins
  out its full five seconds waiting for a pet `running()` will never admit to,
  and the rest stand down against a genuinely fresh lock — one launch, green,
  against the broken script. The damage lands between session starts, where no
  lock is left to mask it. The first version of that assertion scored 13/13
  against the mutant it existed to catch.
- **`state.sh` runs on every prompt and every tool batch.** Keep it cheap, never
  let it fail a hook, and do not add a `jq` dependency — the existing `sed`
  extraction style is deliberate. Hook payloads arrive as one blob on a pipe the
  harness holds open, so it reads with a single `dd bs=65536 count=1` rather
  than to EOF.

  **It honours `disabled` too, and that is what makes `disable` mean it.**
  `cmd_up` has always read the flag, so a disabled install launched no pet, but
  the hot path kept running a `dd`, five `sed`s and three writes on every
  prompt and every tool batch of every session for a user who had turned the
  pet off. The test is a shell builtin before the `mkdir`, so a disabled
  install also stops recreating the runtime home. Refcounts stop being
  re-stamped while it is set, which is the intended shape rather than a cost:
  `cmd_down` still removes them at `SessionEnd` so nothing leaks, a live
  session re-announces itself on its next hook after `enable`, and one too
  stale to do that is one the staleness window would have retired anyway.
- **Whether the machine can build is a different question from whether the pet
  can run, and four separate ways of conflating them are all silent.** Nothing
  here has a harness, and every one of these was found by measurement after
  looking correct.

  `command -v swiftc` is not a capability check. `/usr/bin/swiftc` is an xcrun
  stub macOS ships whether or not a toolchain is installed — 118KB, root-owned,
  78 hard links, one per `/usr/bin` dev tool — so it succeeds on exactly the
  machine the guard exists to reject. Hence `macos()` and `supported()` are
  two predicates: the probe costs ~117ms per exec, and `cmd_up` runs at every
  `SessionStart`, so gating the LAUNCH on it both wastes that on every session
  and refuses to start an already-built binary on a machine whose Xcode later
  vanished. `cmd_up` takes the cheap one; only the build path pays for the real
  one.

  The probe's output is held, not passed through. An unaccepted Xcode licence
  fails `swiftc --version` exactly like an absent toolchain, and only the
  compiler's own words tell them apart — but `--version` also writes an
  unterminated `swift-driver version: … ` banner to stderr when it SUCCEEDS,
  and `supported()`'s stderr is the build log, so passing it through fuses the
  banner onto the first diagnostic and into the status headline.

  **`$ROOT/build.log` belongs to the build, not to whoever called it.** A
  caller-side redirect cannot own it: it holds the file open, so a `rm` inside
  `cmd_build` would unlink the very inode the reason is still being written to
  and the log would vanish on failure. `cmd_build` therefore opens it, prints
  it either way — a successful build's WARNINGS are most of the value of
  running `pet.sh build` by hand, and capturing them to a file about to be
  removed eats them silently — and removes it only on success.

  That is not enough on its own, because `cmd_up` builds only when the binary
  is missing or stale, so on a healthy install no session start runs a build at
  all and nothing retracts a reason. A dev checkout's `pet.sh build` failing
  against its own `$SRC` while sharing one runtime home, or a transient
  breakage fixed in a way that never moves `$SRC`'s mtime, would otherwise
  leave `status` naming a build nobody can retract beside a binary it calls
  `(built)`. So `cmd_up` removes the log on the branch where it does NOT
  build: every other line of `status` reports current state, and this one must
  too.

  **Finding the reason in a swiftc log is subtraction, not a pattern.** The
  message comes first and its source excerpt after, so `tail -1` reports
  `951 |  }`. An unanchored match for `error:` finds the excerpt's own caret
  line, or one of the nine lines in `pet.swift` that contain that text — the
  `moodRank`/`moodTTL` tables and the mood-wording table. And a column anchor
  does not save it: swiftc right-aligns each excerpt's line number to the width
  of the WHOLE FILE, so in a four-digit source every quoted line from 1000 up
  starts at column 0 too, and eight of those nine sit up there. (The line count
  is deliberately not written down here — it moves with every change, and what
  the argument needs is only that the file is over a thousand lines.) What every excerpt line
  does carry is the ` | ` gutter, so the headline drops those and takes the
  first `error:` among what remains.

  A hand-written fake `swiftc` is why two of these shipped green: the fixture
  put its error on the last line, which the real compiler never does. Fake the
  interface, never the output format — capture that from one real run.

  **A failed build gets three things right, and each of them is a separate
  branch.** It must not corrupt the binary: `compile()` writes `swiftc`'s
  output to a `$$`-suffixed staging name in `bin/` and renames on zero exit,
  because a compile killed partway through the old in-place write left a
  truncated 0755 file with an mtime newer than `$SRC` — exactly what the
  rebuild gate reads as current, so nothing rebuilt it, `status` called it
  `(built)`, and the install was wedged with no path back. A `$$` name rather
  than a lock: concurrent session starts after a plugin update then build their
  own copies of the same source and the last rename wins, which is harmless,
  where a lock is a second wedgeable mutex bought to save CPU in a window that
  opens once per release. It must not empty the desktop: the `pkill` runs only
  on the branch where `cmd_build` SUCCEEDED, since a failure returns before
  `launch_once` is ever reached and nothing puts a pet back — and `rename()`
  over a running executable succeeds where a write returns `ETXTBSY`, so
  clearing the path first buys nothing anyway. And it must not repeat: a
  `$BUILDLOG` newer than `$SRC` means this exact source has already been tried,
  and without that test a source that compiles for the author and not on this
  machine burns a full `swiftc -O` inside the 30s hook timeout on every session
  start, forever, and still ends with no pet. That third test is why the
  log-retracting branch is now an explicit `elif` on "present AND current"
  rather than a bare `else`: the `else` of the widened condition also catches
  "needs a build, already failed", and deleting the reason there is deleting
  the only thing that stops the loop.

  `tools/run-build-gate.sh` pins the first, second and fourth of those, and
  takes `PERCHLING_PET_SH` so it can be shown to FAIL: against the pre-fix
  script it goes red on `pet-survives-failed-build` and `no-rebuild-loop`.
  Only those two discriminate — `binary-untouched`, `reason-recorded` and
  `no-staging-debris` pass against that mutant too, because `swiftc` writes no
  output at all on a parse error, and they are negative controls rather than
  coverage. Its mtimes are set with `touch -t`, never by writing the file: the
  first version let `cc`, `touch` and `swiftc` land inside the same second and
  `-nt` then answered differently run to run, which produced three verdicts
  from three runs and none of them about the code.
- **Only `cmd_up` launches the pet, and of the hook events only `SessionStart`
  reaches it.** Everything else — `UserPromptSubmit`, `PostToolBatch`, `Stop`,
  `StopFailure`, `PreToolUse`, `PermissionRequest`, `Notification` — runs
  `state.sh`, which writes the global state file and the session refcount and
  starts nothing. So a pet
  killed mid-session by `pet.sh stop`, by the menu's Quit, or by a crash does
  NOT come back on the next prompt: it comes back when a new session starts, or
  from `pet.sh up`, `pet.sh enable` or `pet.sh wake`, each of which calls
  `cmd_up` when nothing is running. This is easy to get backwards — and was, in
  advice given to the user — because the next prompt visibly does re-stamp
  `sessions/<sid>`, so the refcount returns without the process.
- **Session files are mood, refcount, label, and caption.** Line one is the
  mood; an optional line two is that session's `cwd`, which the tray rows show
  and the fold ignores; an optional line three is the caption the bubble quotes.
  `Mood.parse` reads line one, so the one- and two-line forms stay valid
  forever — `pet.sh up` writes the one-line form whenever there is no payload
  behind the launch (`manual`, `enable`, `wake`). **`state.sh` carries line
  three forward when it has nothing new to say**: only a prompt and a `done`
  reply produce text, a tool batch produces none, and a session file is
  rewritten whole on every hook — so writing the empty value would blank the
  bubble halfway through a turn. The global `say` never had that problem
  because it is only written when non-empty, which is exactly why the session
  file has to re-read its own line 3 first. Writing a session file re-stamps
  liveness; never `touch` one, because that resurrects a stale mood with a
  full TTL. The `manual` entry is a bridge for launches with no session behind
  them, retired by the first real session or by the last `SessionEnd` — it is
  not a session, must not outlive them, and must not appear in the tray.
  Hook payloads do carry `cwd`: observed on seven event types so far —
  `UserPromptSubmit`, `Stop`, `SessionStart`, `SessionEnd`, `PreToolUse`,
  `PostToolUse` and `PostToolBatch` — each from a real headless CLI run, not
  read off the docs. In every one of those seven, `"cwd"` occurred exactly
  once, including on tool events carrying `tool_input`.
- **That survey covers `cwd`, and `session_id` is not the same question.** The
  extraction is greedy and takes the LAST match, so a payload whose
  `tool_input` carries a key of the same name wins over the top-level one. For
  `cwd` the cost is a wrong directory on one tray row until the next hook,
  which is why the extraction accepts it. For `session_id` the value becomes a
  FILENAME: `mv -f` in `state.sh` and `cmd_up`, `rm -f` in `cmd_down`. Measured
  end to end — a nested `"session_id":"../../../evil"` resolves three levels
  above the sessions directory and clobbers an arbitrary file whose third line
  the same payload chose, and `PostToolBatch` carries no matcher, so every tool
  batch is a delivery route. `state.sh` and `pet.sh` therefore both check the
  SHAPE (`case "$sid" in ''|*[!A-Za-z0-9_-]*)`), which costs no fork, and
  reject rather than sanitise: an empty sid degrades to no refcount for that
  hook, where a repaired one still names a file somebody else picked. The
  general form of the trap is worth more than the fix — a measurement of the
  harmless field read as a verdict on the dangerous one, in prose that looks
  exactly like the measured bullets around it.
- **`sessions/` is read for moods in exactly one place.** `liveSessions()`
  owns the owner-alive guard, the one-hour staleness cutoff, and the per-mood
  TTL decay, and both the attention fold and the tray rows consume its
  output — a second *mood* scan is how the face ends up showing idle while
  the menu says "thinking…". `pollSessions()` walks the same directory too,
  for the 30s-empty-grace liveness check, but never touches a mood — it is
  not the second reader this bullet forbids, and adding one that reads a mood
  would be.
- **The session registry is one of two foreign files perchling reads, and by
  itself it is not where a tray row's name comes from.**
  `<config>/sessions/<pid>.json` carries a session's id and the CLI's own name
  for it — usually derived from the cwd rather than typed by a human (measured
  on this machine: `perchling-de`, `nameSource: derived`) — one layer in the
  title → name → project directory → sid-prefix chain, not the top of it. It
  is undocumented, so
  `registryNames` treats every failure as a missing entry: a moved format, an
  older CLI and a background job that never had a name are indistinguishable
  from outside and all three are correctly answered by falling back. **A name's
  absence is normal, not a fault** — the CLI writes one only for interactive
  kinds, so every headless `-p` run and every background job has none. The
  registry directory is resolved from `CLAUDE_CONFIG_DIR` directly and never
  from `root`, because `PERCHLING_HOME` can point at a scratch directory with no
  registry in it. `nameSource` is deliberately not read: it would encode a guess
  about host naming policy, and `sessionLabels` guarantees two drawn rows never
  print the same string without knowing — except when two session ids share
  their first eight characters, where the guard against a doubled suffix
  (`abcdef01 · abcdef01`) knowingly leaves both unsuffixed instead. That
  guarantee is why the suffix is computed over the MENU rows and applied only
  on collision — and why it joins with a middle dot, since the em dash is
  already spent joining a label to its status. **There is a second foreign
  file, and perchling only ever reads it too:** the desktop app's own session
  records, at
  `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<uuid>.json`,
  joined to a `sessions/<sid>` file by their `cliSessionId`. The title in that
  record is what a tray row's name actually comes from when the session has
  one, and it outranks the registry name on purpose — every interactive
  session is given a `derived` registry name, so a name always answers, and a
  title ranked below it could never win; the two stores disagree about the
  same session by design, not by drift. A real record is ~279KB, almost all of
  it an MCP config block, and there is no index over the directory, so
  `desktopTitles` caches by modification time rather than reparsing on every
  poll — parsing every record on a 0.4s poll would put over a megabyte a
  second of JSON through the main thread. A bounded prefix read was rejected
  in its place: the JSON's key order is not guaranteed, so `title` might sit
  past whatever prefix was read, and the failure mode would be a title
  silently vanishing rather than falling back to the registry name.
  Enumeration asks for no resource keys and filters by filename first,
  because these records share a directory with hundreds of `deleted_`
  tombstones — asking for keys up front would turn one `readdir` into a
  `stat` per tombstone. `titleSource` is deliberately not read, for the same
  reason `nameSource` is not.

  **The enumeration is cached separately from the parse, and the two answer
  different questions.** Skipping every parse still walked the whole directory:
  351 tombstones against 3 real records, measured 2026-08-14, and growing on
  its own — 292 two days earlier. `TitleCache.dirs` memoises the records'
  directory listing against that directory's own mtime, which took a warm poll
  from 1167.4 µs to 80.8 µs.

  **Do not collapse the two into one gate.** A directory's mtime moves when an
  entry is added, removed or renamed and does NOT move when an existing file's
  contents are rewritten — measured on APFS, and true of
  `write(to:atomically:)` as well as an in-place write. A single dir-mtime gate
  therefore serves a renamed session's old title until some unrelated record is
  created or deleted. The listing cache may memoise WHICH files exist and never
  what is in them; the per-file stamp check stays. `tools/session-harness.swift`
  pins both halves, and each assertion was proven to fail alone under the
  mutation it exists for. The listing half needed `titleDirScans`, a counter
  nothing in the app reads — a pure performance change has no observable result,
  so without it deleting the cache leaves every assertion green.

  The listing cache needs no prune, unlike the parse cache: a removal moves the
  directory's mtime, so a stale listing is replaced on the next poll rather than
  answering forever.
- **A caption arrives still JSON-escaped, and BOTH captions are cleaned in one
  place.** `state.sh` captures the string body with a `sed`, so a two-line
  prompt reaches the file as the literal characters backslash and n.
  `cleanCaption` is the only unescaper and `liveSessions` and `pollSay` both
  call it. Putting it in `pollSay` alone was the shape of the bug worth
  remembering: `bubbleText` prefers `top.say` and only falls back to the global
  `say`, so the cleaned path was the one nobody normally sees and the escapes
  were on screen in every ordinary case. It is ONE PASS rather than a chain of
  `replacingOccurrences`, because a chain gets `\\n` wrong in either order — a
  user who typed a backslash before an n loses the backslash or gains a
  space — and an escape it does not recognise (`\uXXXX`, which that `sed`
  cannot decode anyway) passes through whole rather than half-eaten. Both
  mutations are pinned in `tools/run-session-harness.sh` and each was shown to
  fail alone.
- **The bubble quotes the session the face is reporting.** `menuRows()` already
  sorts most-attention-worthy first, so `sessionRows.first` IS that session, and
  `bubbleText()` takes its line three and its name. Before this the caption came
  from the global `say`, which every session overwrites unconditionally, so with
  several sessions open the face and the caption could describe different ones
  with nothing on screen saying so. The name is shown only when more than one
  session is live — with one there is nothing to tell it apart from, so it
  stays hidden whatever `sessionName` would have returned for it. The composed
  status line budgets the NAME by measured width, never a
  character count: the line holds about 34 monospace advances, the longest
  shipped status is "waiting for you…" at 16, and a CJK name spends two advances
  per character, so any character budget lets the status be the thing that gets
  cut. `bubbleText` takes the wording table as a parameter for the same reason
  `sessionTitle` does, and `BubbleView` has no `mood`: it is handed the status
  string, because deriving it a second time in the view would leave the rule
  under test and the rule on screen as two pieces of code that merely agree.
  The guarantee binds the live SESSIONS and stops there: the fold also takes
  the global `state` file, which has no row behind it and which `cmd_down`
  never clears, so a session ending on `waiting` can hold the face for up to
  that file's 300s leash while the caption reports the top live row. A harness
  that recomputes the face from `liveSessions` alone shares the blind spot and
  will assert the gap away — take the fold's own inputs, or assert against a
  literal. That fold is `foldMoods`, a free function: it was inside
  `Controller.pollMoods`, where `Controller.init`'s three NSWindows put the one
  rule deciding what the user sees out of reach of every harness. It takes the
  state file's mood and stamp as an EXPLICIT parameter for precisely the reason
  above, so a caller cannot accidentally derive it from the rows; `pollMoods` is
  now the IO around it, and the assertions live in `tools/session-harness.swift`
  beside a literal for the gap itself.
- **A refcount is owned.** `sessions/<sid>` is paired with `owners/<sid>`, the
  pid of the outermost process the session hangs off — Claude desktop, or the
  terminal that ran `claude`. A dead owner retires the session on the next
  poll, which is what makes a force-quit (where no `SessionEnd` ever fires)
  survivable. A missing owner file means unknown, never dead: it falls back to
  the one-hour staleness window.

  **Only `cmd_up` ever writes an owner file, and absence is a normal state with
  two different causes.** `cmd_up` writes the pair at `SessionStart` and
  deliberately writes NO owner when the process tree is unclimbable or resolves
  to itself — there, absence means "cannot be known". `state.sh` is the other
  writer of session files, on every prompt and every tool batch, and it never
  touches `owners/` by design: resolving an owner costs a whole-process-table
  `ps`, and that file is the hot path. So `pet.sh stop`, which wipes both
  directories, leaves a session whose very next hook restores the refcount
  alone — there, absence means "was known, then erased", and that session runs
  ownerless until it ends. Reproduced deterministically; the only cost is that
  a force-quit after a manual `stop` is retired by the one-hour window instead
  of immediately, and it self-heals.

  Do not "fix" that by having `state.sh` fill in the missing owner. The two
  causes of absence are indistinguishable on disk, so the unclimbable case
  would re-run `ps` on every hook forever and could write the very pid
  `cmd_up`'s `!= "$$"` guard exists to reject. Closing it properly means
  inventing a third state, which buys back a self-healing hour.

  **Removal is symmetric only when `SessionEnd` fires, and the owner machinery
  exists precisely because it sometimes does not.** `cmd_down` removes both
  halves whatever the owner situation was; a force-quit runs it never, and the
  owner-prune loop then removed `owners/<sid>` while `sessions/<sid>` stayed
  forever. Nothing in the renderer deletes one either — `liveSessions` and
  `pollSessions` compute the staleness predicate and use it only to HIDE. A
  session file four days old was found on a live install.

  `cmd_up` therefore retires session files past the renderer's own hour before
  the owner loop runs, which is what makes that loop's job right rather than
  inverted: the session goes first and its owner follows, so the pair stays
  matched without the loop knowing the cutoff. The window is not a choice —
  `liveSessions` requires the stamp to be inside the cutoff regardless of
  whether the owner is alive, so a session too stale to draw is too stale to
  keep, and one that is genuinely alive re-announces itself on its next hook.
  Pinned in `tools/run-prune-checks.sh`, including the half that matters more:
  a FRESH session must survive `cmd_up` untouched.
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
bash tools/run-session-harness.sh  # 107 assertions over the session/tray + pet library
bash tools/run-manifest-checks.sh  # manifest parser: steps, tap, four rejections
bash tools/run-pose-harness.sh     # sequence precedence over the real pose()
bash tools/run-hooks-check.sh      # hooks.json declares no event this CLI rejects
bash tools/run-launch-race.sh       # cmd_up launches exactly one pet, 13 assertions
bash tools/run-build-gate.sh        # what a FAILED build may do to a working install
bash tools/run-state-checks.sh      # what state.sh writes, and what it must refuse to
bash tools/run-prune-checks.sh      # cmd_up retires stale refcounts and keeps live ones
bash tools/run-art-checks.sh        # no shipped pet has a hole the desktop shows through
~/.claude/perchling/bin/perchling --validate examples/otter.json
~/.claude/perchling/bin/perchling --export > /tmp/draft.json
```

Eight layers have harnesses — the session/tray layer and the pet library
(`tools/run-session-harness.sh`), `state.sh` itself
(`tools/run-state-checks.sh`, shell only, since that script compiles nothing
and launches nothing), `cmd_up`'s housekeeping
(`tools/run-prune-checks.sh` — kept apart from the launch and build harnesses
because they are three unrelated properties of one function and one file would
make a failure ambiguous), the manifest parser
(`tools/run-manifest-checks.sh`, which compiles a throwaway binary rather than
rebuilding the installed one) and sequence precedence inside `pose()`
(`tools/run-pose-harness.sh`, which cuts at `let argv` rather than before the
runtime-home block, because `PetView` lives below that line) and `cmd_up`'s
launch path (`tools/run-launch-race.sh`, which is shell only and compiles a C
stub rather than touching `pet.swift`) and what a failed build may do to a
working install (`tools/run-build-gate.sh`, shell only for the same reason, and
using the same kind of C stub) and the shipped art (`tools/run-art-checks.sh`,
which cuts where the session harness cuts so it can reach `builtinPet`).

Six of them take an override — `PERCHLING_PET_SH`, `PERCHLING_PET_SWIFT` and
`PERCHLING_STATE_SH` — so each can be pointed at a mutant carrying exactly the
defect it is named after and shown to FAIL. That is the only reason to believe any of them, and the
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
back rather than naming a cause. And thirteen green lines are not thirteen
guarantees: `staggered-16ms` and `staggered-20ms` sit past the top of
the race window, so they pass against a broken script too and the file labels
them negative controls rather than coverage.

Nothing else here has a test suite. `tools/run-hooks-check.sh` is not a sixth
harness — it tests no Swift at all, it asks the installed CLI whether
`hooks/hooks.json` is loadable — but it belongs to the same release gate,
because the failure it catches takes the whole plugin down without printing
anything.
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
