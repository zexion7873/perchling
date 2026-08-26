# Pose, sequence and motion invariants

Moved verbatim from `AGENTS.md`, which now carries only each layer's most
lethal rule and a pointer here. Every bullet below was earned by a shipped bug
or a measured dead end — nothing in this file is style. New invariants for this
layer belong HERE, written the same way: what was measured, what it rules out,
and what the alternative lost to.

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
- **Motion is measured in points, not cells.** `bounceUnit(scale)` keeps travel
  at roughly four points whatever a pet's cell size is.
- **Reduce Motion freezes `tick`, not the poll clock.** Anything shaped like
  `deadline = tick + n` must be armed only when motion is allowed, or `tick`
  never reaches it and the state sticks forever. Liveness and mood changes must
  keep working while frozen.
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
  stays for every sequence EXCEPT a MIRRORED drag: it is applied inside
  `fill()`, which every blit including the sequence's already passes through,
  and for direction-blind frames it is the only thing telling the viewer
  which way the pet is being dragged — a manifest ships ONE `drag` sequence,
  and mirroring is what gives it a second facing. A drag that declares
  `mirror` already expresses direction through that flip, so there `pose()`
  zeroes the lean instead of stacking it: stacked, the shear's per-row
  rounding lands a step mid-sprite and slides a dark face plate sideways out
  of the head outline — a block that swaps sides with the drag direction,
  measured on the 96x112 robots, whose glass/chin junction sits exactly on
  the 1.5-cell rounding boundary. Every shipped pet mirrors its drag, so
  before the carve-out the stacked shear was what every drag showed. Pinned
  in `tools/run-pose-harness.sh` with the unmirrored and no-sequence controls
  beside it, and both directions of the mutation were shown to fail.
  Sequence frames also count toward `inkTop`, so a lifted frame moves
  the chrome for every mood, permanently, not only while it plays.
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
- **The drag lean is a shear, not a pose, which is why every pet without a
  mirrored drag has it.** The
  top of the sprite lags the direction of travel and the bottom stays planted;
  `fill()` applies it so the base, eyes, tear, sparkle and custom blit all
  inherit it from one place, exactly as they inherit `xpad`. Two things it
  must not become: state read inside `pose()`, which has to stay pure because
  `draw()` and `repaintIfChanged()` both call it — the decay belongs in the
  tick loop next to `tick += 1`, where Reduce Motion already gates it; and a
  uniform offset, which reads as the window sliding rather than the creature
  resisting. Codex spends two whole atlas rows (`running-left`/`running-right`)
  on this reaction; a shear is what it costs when a manifest has no second
  pose to cut to, and at true size it reads as a sway, not a run. A manifest
  that DID ship the second pose — a mirrored drag — has paid that cost
  already, which is the carve-out above.
