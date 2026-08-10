---
name: draw-pet
description: Design and install a custom pixel pet for Perchling, the desktop pet. Use when the user wants to change the pet's appearance, draw a new pet, or turn it into a specific creature — "make my pet a cat", "draw me a dragon pet", "change the perchling", "換寵物", "畫一隻寵物".
---

# Draw a custom Perchling pet

Perchling renders whatever `~/.claude/perchling/pet.json` describes and
live-reloads within a second of the file changing — no rebuild, no restart,
no image files. You are the pixel artist: author palette-indexed text grids,
install the file, and the creature on screen transforms while the user
watches.

## Manifest format

```json
{
  "name": "blob",
  "scale": 4,
  "palette": { "b": "#6fc276", "s": "#4e9757", "k": "#26402e" },
  "moods": {
    "idle": [
      "..bbbbbb..",
      ".bbbbbbbb.",
      "bbbbbbbbbb",
      "bbkbbbbkbb",
      "bbbbbbbbbb",
      "bbbbkkbbbb",
      ".bbbbbbbb.",
      "..ssssss.."
    ]
  }
}
```

(Only `idle` is shown, and it is a complete valid grid — 10×8, inside the
8–128 range. A real manifest repeats the same-size array for `running`,
`waiting`, `done`, and `error`.)

Rules the loader enforces:

- **palette** keys are one character each — any character except `0` and `.`
  (both mean transparent). Values are `#RRGGBB` or `#RGB`.
- **moods**: `idle` is required; `running`, `waiting`, `done`, `error` are
  optional and fall back to idle — but ship all five; mood switches are the
  whole point of the pet.
- Every row in a mood must be the same length, and every mood the same size:
  8–128 in both dimensions.
- **scale** (optional, integer 1–4, default 4) is screen points per pixel.
  The art occupies width×scale by height×scale points — keep that roughly
  80–130 points wide so the pet stays a corner creature, not a billboard.
  (The window is a little larger: the app adds its own margin for the
  animation. Size the art, not the window.) Within that budget, scale is the
  sharpness dial: 24×24 at scale 4 is chunky retro, 96×96 at scale 1 is the
  same footprint with sixteen times the detail. The built-in pet sits at
  scale 1 for exactly this reason.
- **eyes** (optional) makes the eyes follow the cursor while the pet waits and
  blink on their own: `"eyes": { "box": [x, y, width, height], "socket": "k" }`.
  `box` frames the eyes, `socket` is the palette key of the flat color behind
  them — the renderer shifts everything in the box and refills what the shift
  vacates with `socket`, so the box's whole border must sit on that one color
  or the shift leaves a seam. Leave the eyes a couple of pixels of clearance
  inside the box; whatever crosses the edge gets clipped. `range` (optional,
  0–8, default 2) is the travel in pixels, and `lid` (optional palette key)
  overrides the blink color, which is otherwise the brightest color occupying
  at least 3% of the box. `perchling --validate` prints the box it read and
  says `blink UNAVAILABLE` if nothing in the box is bright enough to close.
- **sequences** (optional) gives the pet the two reactions that need several
  frames on a clock:
  `"sequences": { "hover": { "ms": 150, "frames": [ <grid>, <grid> ] } }`.
  `hover` plays once when the cursor arrives and then stops — it does not hold
  while the cursor stays, and there is no exit reaction. `drag` loops for as
  long as the pet is held. Each frame is a grid exactly like a mood's: same
  canvas size, same palette. `frames` takes 2–16 — one frame is a pose, not a
  sequence. `ms` (optional, 50–1000, default 150) is per frame; the renderer
  ticks every 50ms, so the number rounds to a multiple of 50 — write 120 and
  you get 100, and `perchling --validate` prints what you actually got. Ship
  either one without the other. Neither plays while macOS Reduce Motion is on.
  Do not draw a left and a right `drag`: the lean every pet already gets is
  what shows which way it is being pulled.
- A sequence frame that reaches higher than any mood raises the pet's ink line,
  and the speech bubble and chip hang off that line — permanently, in every
  mood, not just while the sequence plays. A big jump buys a reaction and costs
  a few points of headroom all the time. `--validate` says when a sequence
  moved it and by how much.
- The app animates position itself (bounce, hop, droop, twitch) and reserves
  the canvas margin those need — draw poses and expressions, not motion, and
  do not pad the grid with blank rows to make room. A playing sequence takes
  the body over: the bounce, the twitch, the gaze and the blink all stand down
  for its duration, because the frames carry their own motion.
- The doze-and-peek cycle stays renderer-only: it cuts between two drawn eye
  shapes, and a manifest has one frame per mood to cut between. The hover
  startle was the same shape, which is what `sequences.hover` exists to fix —
  but only for pets that ship the frames. A pet with no hover sequence has no
  hover reaction at all.

## Workflow

0. If the user wants to *modify* the default pet rather than replace it,
   start from a snapshot of it instead of a blank grid. Rebuild first — a
   binary older than this feature ignores the flag, and the redirect would
   truncate the target to zero bytes before the command hangs:
   ```
   bash "$CLAUDE_PLUGIN_ROOT/scripts/pet.sh" build
   ~/.claude/perchling/bin/perchling --export > /tmp/draft.json
   ```
   Tell the user what the snapshot does not carry before they commit to
   editing it: the export is pixels, so the default's doze-and-peek cycle and
   typing animation are gone, and the sideways twitch that moves only the
   default's eyes becomes a whole-body shift. Declaring `eyes` on the copy
   wins back the gaze and the blink — the export's own eye
   box is `[22, 15, 52, 27]` with `socket` `"c"` — two pixels wider than the
   eyes on every side, which is the clearance the gaze needs.
1. Settle the creature with the user: species, colors, vibe. An outline
   color, 2–3 body colors, and 1–2 face colors is the sweet spot.
2. Draw the five grids. Design `idle` first, then copy it per mood and
   re-stamp the face:
   - `idle` — neutral open eyes
   - `running` — focused / determined
   - `waiting` — wide staring eyes (it wants the user's attention)
   - `done` — happy closed eyes, smile
   - `error` — X eyes, distress
   Pixel-art craft: dark outline around the silhouette, lighter color toward
   the top-left, shade toward the bottom-right; at this scale faces carry the
   art, fine detail doesn't.
3. Validate the draft **before** installing:
   ```
   ~/.claude/perchling/bin/perchling --validate /path/to/draft.json
   ```
   Errors name the exact mood/row/character; an unknown flag prints usage and
   exits 2. If the command instead hangs with no output and a second pet
   appears on screen, the installed binary predates this feature and is
   ignoring the flag: interrupt it, run
   `bash "$CLAUDE_PLUGIN_ROOT/scripts/pet.sh" build`, and retry.
4. Install atomically — the app watches mtime, and a partial write would
   flash the fallback pet. `<slug>` is the manifest's `name` lowercased, with
   letters and digits of any script kept and everything else turned into a
   dash — the same rule the app uses when it adopts a pet, so a pet named
   貓咪 becomes `貓咪.json`:
   ```bash
   mkdir -p ~/.claude/perchling/pets
   # A pet.json from before the library is a real file, not a link into pets/,
   # and `ln -sf` would delete it. Perchling rescues one when it launches, but
   # it may not have launched since the update — or at all.
   if [ -f ~/.claude/perchling/pet.json ] && [ ! -L ~/.claude/perchling/pet.json ]; then
     mv ~/.claude/perchling/pet.json ~/.claude/perchling/pets/previous-$(date +%s).json
   fi
   mv /path/to/draft.json ~/.claude/perchling/pets/<slug>.json
   ln -sf pets/<slug>.json ~/.claude/perchling/pet.json
   ```
   (If a security guard in your environment blocks `mv` into the home
   directory, plain `cp` is fine — the app re-reads on the next mtime
   change, so a torn read self-heals within half a second.) Drawing a second
   pet adds to the library instead of replacing the first.
5. The pet transforms within a second. Tell the user to look at their screen,
   then iterate on feedback — recolor, resize, fix the face — by editing a
   draft and re-installing it the same way.

Three worked examples ship with this plugin, under `$CLAUDE_PLUGIN_ROOT/examples/`
— read them by that path, not a bare relative one, since the skill runs with
the user's project as the working directory:

- `sprout.json` — a leafy slime, 48×40 at scale 2, shaded and blushing. Shows
  how the pieces fit together at the fine-detail end.
- `perchling.json` — the built-in pet, exported: 96×99 at scale 1.
- `classic.json` — the first mascot, retired when the built-in became the
  terminal robot; same footprint as the export it was frozen from.

## Revert

The built-in perchling returns, live, the moment `pet.json` is gone. Retire it
rather than delete it, for the same reason the install step does: a pre-library
`pet.json` is the pet itself, not a link to one.

```bash
if [ -f ~/.claude/perchling/pet.json ] && [ ! -L ~/.claude/perchling/pet.json ]; then
  mkdir -p ~/.claude/perchling/pets
  mv ~/.claude/perchling/pet.json ~/.claude/perchling/pets/previous-$(date +%s).json
else
  rm -f ~/.claude/perchling/pet.json
fi
```
