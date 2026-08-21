# Bubble, chip and chrome invariants

Moved verbatim from `AGENTS.md`, which now carries only each layer's most
lethal rule and a pointer here. Every bullet below was earned by a shipped bug
or a measured dead end — nothing in this file is style. New invariants for this
layer belong HERE, written the same way: what was measured, what it rules out,
and what the alternative lost to.

- **The chrome's colours are the user's, never the pet's.** They used to be
  borrowed from the pet's ink palette, which was fine while one enum described
  both. A pet is a manifest now: borrowing would mean a user's pet repainting
  the bubble and the chip. The colours live in `CHROME_THEMES`, a fixed table
  the user picks from in the right-click menu, persisted per machine via
  `UserDefaults` exactly as mute and the chip's collapse are — and never in a
  manifest. A per-pet manifest key was the runner-up and lost three ways: it
  would be the first manifest attribute to reach the chrome layer at all, it
  buys nothing while one pet window exists at a time, and an author's hex
  lands at `CHROME_TINT` alpha over frost, where it neither looks like itself
  nor guarantees the text stays readable. The table is curated for the same
  reason free hexes were refused: a new row is an on-screen eyeball, not four
  plausible numbers — the harness cannot render the blur (see the last bullet).
  Amber is the default and its hexes are unchanged from 1.6, so an untouched
  install looks identical to every version before themes existed. The saved
  theme is restored in `Controller.init` before any chrome draws; the menu
  handler that changes it repaints both faces itself, because `Panel.draw`
  repaints only on its own three inputs and deliberately does not watch the
  theme — those are the only two writers `CHROME_THEME` may ever have.
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
  under light text — every theme's ink assumes a dark panel, which is also why
  the table stays curated. And the frost goes away on tuck or collapse and on nothing
  else: `applyChrome()` reads `tucked` and `collapsed` and never the mood. It
  used to fold away with an idle mood, on the theory that an idle pet keeps
  the desktop clean; the cost was that the one control for the bubble vanished
  exactly when the bubble was quiet enough to be in the way, and `.idle` now
  carries its own status wording so the panel is never an empty slab.
- **`CHROME_TINT` is a tint over the frost, not the panel.** The frost
  supplies the darkening and the legibility; the tint only pulls
  `.hudWindow`'s neutral grey toward the active theme's panel colour, which is
  why 0.38 looks far too transparent in any offscreen render and is right on
  screen. The 0.38 is shared across every theme — the eyeball that set it was
  made against Amber, so a NEW theme row is judged on a desktop under the same
  constant, never by giving the row its own tint. Two corollaries, both
  measured by a four-reviewer pass over the shipped rows: the tint passes only
  ~0.38 of a panel's DECLARED chroma, so a lean that should render cool or
  warm must be overdeclared ~2.6x — Abyss's first panel (0.09, 0.11, 0.16)
  rendered within 5/255 per channel of Graphite's, a named theme reduced to
  trim. And an edge with no hue channel has only luminance to hold the
  silhouette: Graphite's first edge (0.32) measured 1.17:1 against its own
  effective panel, so on a wallpaper near the frost value both boundaries
  died at once. The third lesson came from the white band of the real-desktop
  verification card, and it ends in an ACCEPTED cost, not a fix: a light
  wallpaper brightens the frost until a single mid-value edge goes soft on
  every theme at once, and the edge stays single-tone anyway. Every escape
  was tried on a real desktop and lost. Darkening the three edges re-breaks
  Graphite's dark-band restraint, the exact trade the edge lift had just
  settled. A dark understroke contour — flat near-black, then edge x 0.35,
  then x 0.5 — always read as the same black frame, because at a point of
  visible width the eye keeps only luminance and no dark hue survives; the
  outermost line defines the shape, so the whole family collapsed into
  "black". A pale halo (edge lightened 65% toward white) fixed the white band
  by isolation but turned every dark band that had already passed into a
  sticker glow. Do not reopen this with another ratio — the knob was explored
  end to end; a soft edge on white beat every ring that guaranteed one. What
  finally bought the white band back was WEIGHT, a knob none of the rings
  touched: the edge thickened to its geometric ceiling (bubble 4pt, chip
  3.5pt — the stroke rides the path and the path sits 2pt in from the window
  edge, so 4pt lands flush; thicker means moving the path and both masks).
  Width is hue's friend where darkness was its enemy: at 4pt each theme's
  edge reads its own colour on white, the exact thing no dark ring achieved.
  `.behindWindow` blending draws NOTHING through `cacheDisplay` — there is no
  window behind it — so the harness can verify the mask, the tint and the
  hide/show, and cannot verify the blur. Judge that one on a desktop, as 0.38
  was: it looks far too transparent in every offscreen render and is right on
  screen, so a future reader who only has the harness should not "fix" it.
