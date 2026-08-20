# Bubble, chip and chrome invariants

Moved verbatim from `AGENTS.md`, which now carries only each layer's most
lethal rule and a pointer here. Every bullet below was earned by a shipped bug
or a measured dead end — nothing in this file is style. New invariants for this
layer belong HERE, written the same way: what was measured, what it rules out,
and what the alternative lost to.

- **The chrome has its own colours and must keep them.** `CHROME_PANEL`,
  `CHROME_EDGE`, `CHROME_TEXT` and `CHROME_INK` used to be borrowed from the
  pet's ink palette, which was fine while one enum described both. A pet is a
  manifest now: borrowing would mean a user's pet repainting the bubble and the
  chip. The hexes are unchanged from 1.6 on purpose — the panels look identical.
- **`canvasSize()` is the only place window dimensions are decided.** It
  reserves `3 × bounceUnit` cells below the art for the bounce and
  `bounceUnit` on each side for the twitch. A hardcoded margin here previously
  clipped the pet's feet, made an exported manifest a different size from the
  pet it copied, and sliced the leading column off wide custom pets — three
  bugs, one assumption.
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

  **A frame with no ink at all has no top, and scoring it as row 0 broke both
  halves of this.** `inkTopOf` is now the single implementation — it was
  computed twice, once for the pet and once for `--validate`'s explanation of
  it, so the two could disagree. One blank frame anywhere in the moods or the
  sequences collapsed `inkTop` to 0, which put the chrome at the very top of
  the canvas, and then made `--validate` announce that the sequences reached
  higher and the chrome had moved up N rows — a sentence about a frame that is
  empty. It returns an Optional rather than defaulting inside, because the two
  callers want different things from "nothing has ink": the pet needs a number,
  the explanation needs to stay silent. Both halves are pinned in
  `run-manifest-checks.sh`, including the half that matters second — a sequence
  that GENUINELY starts higher must still be reported, or the fix would have
  silenced a true warning too.

  **The chrome is repositioned on every pet change, not only when the window
  resizes.** `pollPet` used to call `repositionBubble()` inside its
  `frame.size != size` branch, so two pets sharing a canvas size but starting
  their ink on different rows swapped cleanly and left the bubble and the chip
  where the previous pet had put them. There is no harness for that one:
  `pollPet` is a `Controller` method and `Controller.init` builds three
  NSWindows, the same wall `foldMoods` was extracted through. It is the next
  candidate for the same treatment.
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
