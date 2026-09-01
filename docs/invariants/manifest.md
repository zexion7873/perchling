# Manifest format and parser invariants

Moved verbatim from `AGENTS.md`, which now carries only each layer's most
lethal rule and a pointer here. Every bullet below was earned by a shipped bug
or a measured dead end — nothing in this file is style. New invariants for this
layer belong HERE, written the same way: what was measured, what it rules out,
and what the alternative lost to.

- **There is no drawing code, and as of 1.14 there is no embedded art either.**
  The built-in is a pet in `examples/`, named by `PERCHLING_BUILTIN` and
  defaulting to `husky`, parsed through the same
  `loadCustomPet` a user's `pet.json` goes through, and `--export` hands the
  loaded TEXT straight back — so the export is an exact round-trip rather than a
  re-serialisation, and there is exactly one copy of it in the repo. It used to
  be 449KB of string literal called `BUILTIN_MANIFEST`, which is most of why
  taking it out of the binary took that binary from 917KB to 458 at the time.
  Do not read 458 as the current size — it is the measurement that sized the
  change, and the binary grows with every feature since.

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

  **This block had no coverage at all until 2026-08-19, and it killed the
  process two ways.** No shipped pet declares `eyes`, so nothing here had ever
  run — in the app or in a test. `box` is two untrusted `Int`s that were ADDED
  before being range-checked, so an origin near `Int.max` trapped on overflow;
  it is compared by subtraction now. And the lid search force-unwrapped the
  palette for a transparent cell, which has no entry — that one needed TWO
  distinct non-socket inks inside the box, because a single key never makes
  `max(by:)` call its comparator, so a box over nothing but transparency
  survived and a realistic one did not. Both took down `--validate` itself,
  which is the only tool an author has for finding out what is wrong with a
  manifest: it died on the mistake it exists to diagnose. Pinned by eight
  fixtures in `tools/run-manifest-checks.sh`, and the happy paths were measured
  working before either fix — the feature was never broken, only unguarded.
  One of the eight is labelled a negative control: `0 + Int.max` does not
  overflow, so the extent case passes against the pre-fix parser too.
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
- **CR and LF cannot be palette keys, and the guard sits at the palette.**
  They are the one pair where the parser's two width measures disagree: the
  byte fast path counts CR LF as two cells, while every grapheme walk — the
  row-length fallback, `synthBlinkFrame` — counts the pair as ONE `Character`.
  A manifest declaring both as keys, with a CR LF pair inside a declared eye
  box, passed the byte width check and then trapped in `synthBlinkFrame`: an
  uncatchable index abort (exit 133), not a `PetError`, so `petChoices.scan`
  could not contain it and the file merely SITTING in the pet library aborted
  the app on every right-click. No other ASCII bytes coalesce into one
  grapheme and non-ASCII keys already fall off the byte path whole, so
  rejecting these two keys closes the divergence exactly.
  `run-manifest-checks.sh` carries the trap fixture itself, and the mutation
  gate points that harness at a parser without the guard — where the fixture
  aborts instead of erroring.
