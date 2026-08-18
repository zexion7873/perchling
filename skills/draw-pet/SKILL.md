---
name: draw-pet
description: Design and install a custom pixel pet for Perchling, the desktop pet. Use when the user wants to change the pet's appearance, draw a new pet, or turn it into a specific creature — "make my pet a cat", "draw me a dragon pet", "change the perchling", "換寵物", "畫一隻寵物".
---

# Draw a custom Perchling pet

Perchling renders whatever `~/.claude/perchling/pet.json` describes and
live-reloads within a second of the file changing — no rebuild, no restart, and
the manifest itself carries no image files. In this skill you are the pixel
artist: author palette-indexed text grids, install the file, and the creature on
screen transforms while the user watches. That is the method here rather than
the only method the format allows: the built-in husky and every pet under
`examples/` were quantised from raster renders, which is why the note on reading
them says to read them for format and never for art.

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
- **sequences** (optional) puts several frames on a clock:
  `"sequences": { "hover": { "frames": [ <grid>, <grid> ], "steps": [[0,150],[1,150]] } }`.
  Eight names are recognised. Three are reactions: `hover` plays when the cursor
  arrives and then stops — it does not hold while the cursor stays, and there is
  no exit reaction — `drag` loops for as long as the pet is held, and `tap`
  plays when the pet is clicked. A pet that ships `tap` frames replaces the
  two-cell hop every pet does by default; ship no `tap` and you keep the hop.
  `plays` (optional, 1–8, default 1) runs a `hover` or `tap` burst that many
  times off one copy of the frames, so a double hop costs a number rather than a
  second set of grids; it does nothing on `drag` or on a mood, which already run
  until the drag or the mood ends, and `--validate` says so.
  The other five are the moods, `idle` `running` `waiting` `done` `error`, and
  naming one makes that mood animate: the frames loop for as long as the pet is
  in that mood and start over when it arrives there. A mood you animate still
  needs its grid in `moods`; that grid is what shows under Reduce Motion, so
  make it the frame the pet should hold still in. A drag beats a tap, a tap
  beats a hover, and a hover beats a mood loop — a tap outranks a hover because
  the cursor is on the pet whenever you click it. Each frame is a grid exactly
  like a mood's: same canvas size, same palette. `frames` takes 2–16 — one frame
  is a pose, not a sequence.
  `steps` is **required** and it is the animation: 2–32 entries, each one a
  `[frame, ms]` pair meaning "draw this frame, hold it this long". `frame` is an
  index into `frames`, so the order you list `frames` in means nothing, and the
  same pose may appear several times with different holds — `[[0,280],[1,110],[2,110],[3,140],[0,140],[1,320]]`
  is six beats off four drawings, which is how a breathing loop gets an accent
  instead of a metronome. `ms` is 50–1000 per step and the renderer ticks every
  50ms, so each one rounds to a multiple of 50 — write 120 and you get 100, and
  `perchling --validate` prints the whole timeline it actually built. Never pad
  `frames` with a duplicate grid to hold a pose longer: a grid costs about 11KB
  and a repeated step costs two numbers. Ship any sequence without the others.
  None of them plays while macOS Reduce Motion is on.
  Do not draw a left and a right `drag`. Draw it facing RIGHT and add
  `"mirror": true` to that sequence if your pet may be reflected — the renderer
  then draws the frames flipped while the drag heads left, which buys a second
  facing for no extra pixels. Leave `mirror` off (the default) when something on
  the pet must not reverse: a badge, a logo, lettering. Either way the lean every
  pet gets for free is already showing which way it is being pulled. `mirror`
  does nothing anywhere but `drag` — a burst and a resting state have no
  direction of travel — and `--validate` says so rather than leaving you to
  wonder.
- A sequence frame that reaches higher than any mood raises the pet's ink line,
  and the speech bubble and chip hang off that line — permanently, in every
  mood, not just while the sequence plays. A big jump buys a reaction and costs
  a few points of headroom all the time. `--validate` says when a sequence
  moved it and by how much.
- The app animates position itself (bounce, hop, droop, twitch) and reserves
  the canvas margin those need — draw poses and expressions, not motion, and
  do not pad the grid with blank rows to make room. A playing sequence takes
  the body over: the bounce, the twitch, the gaze and the blink all stand down
  for its duration, because the frames carry their own motion. For a reaction
  that is a moment; for a mood loop it is the whole time the pet is in that
  mood, so animating a mood trades its gaze and its blink for the frames. Only
  `waiting` had both, which makes it the one mood where that is a real choice —
  animate it and the pet stops watching the cursor and never blinks again. A
  tap still hops a pet off a mood loop, and `done`'s automatic celebration hop
  stands down when `done` has frames of its own, so a jump is not lifted twice.
- There is no renderer-only behaviour left to inherit. The doze-and-peek cycle
  and the hover startle were drawing code on a built-in that no longer exists;
  the built-in is a manifest now and lives under exactly these rules. A pet with
  no hover sequence has no hover reaction at all. The shipped one declares
  one, so it does — but that is a fact about its manifest, not about the
  renderer, which is the whole point of this section.
  What the shipped pet *does* declare is worth copying from: all eight
  sequences, five frames apiece, including the `drag` row and its `mirror`
  flag. `perchling --export` prints it.

  **No shipped pet declares `eyes`, so this document is your only reference for
  that block.** Every pet that ships animates all five moods, and a mood loop
  suppresses the gaze and the blink, so the block would buy them nothing. If a
  user wants eyes that follow, you are writing the first one — read the `eyes`
  rules above carefully and lean on `--validate`, which prints the box it read
  and says `blink UNAVAILABLE` when nothing in the box is bright enough.

## Workflow

0. If the user wants to *modify* the default pet rather than replace it,
   start from a snapshot of it instead of a blank grid. Rebuild first — a
   binary older than this feature ignores the flag, and the redirect would
   truncate the target to zero bytes before the command hangs:
   ```
   bash "$CLAUDE_PLUGIN_ROOT/scripts/pet.sh" build
   ~/.claude/perchling/bin/perchling --export > /tmp/draft.json
   ```
   The snapshot is a faithful copy: the built-in is itself a manifest, so the
   export carries everything it has — all eight sequences at five frames each —
   and loses nothing.

   Two things about it shape what a remix can be. It is 449KB and about 4700
   lines, so do not read it whole; slice out the part you are changing. And it
   declares no `eyes`, because animating every mood gives up the gaze and the
   blink anyway — adding eyes to a remix means dropping at least one mood's
   sequence first, not just appending a block.
1. Settle the creature with the user: species, colors, vibe.
2. Draw the five grids. Design `idle` first, then copy it per mood and
   re-stamp the face:
   - `idle` — neutral open eyes
   - `running` — focused / determined
   - `waiting` — wide staring eyes (it wants the user's attention)
   - `done` — happy closed eyes, smile
   - `error` — X eyes, distress
   Pixel-art craft, and none of this is house taste — it is what the medium
   and the size will carry. A dark outline around the silhouette, because the
   pet sits on the user's wallpaper with a transparent background and a pale
   creature on a pale desktop is invisible. Lighter color toward the top-left,
   shade toward the bottom-right, so one light direction reads across every
   mood. And at this scale the face carries the art while fine detail does
   not — 92x96 at scale 1 is 92x96 points on screen, so a whisker is one pixel
   and reads as dirt.
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

## Worked examples

**Do not read a file under `examples/` whole.** The six that ship are 449–589 KB
and 4,500–6,000 lines each — one of them will not fit in your context, and the
one thing you would learn from the whole file is what a wall of row strings looks
like. Two sources, and which one you want depends on the question:

- **`perchling --export`** — the built-in pet, 92×96 at scale 1, declaring all
  eight sequences at five frames apiece. About 449KB, so pull the part you need
  rather than printing it all:

  ```bash
  ~/.claude/perchling/bin/perchling --export | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["name"], d["scale"], len(d["palette"]), "inks"); print({k:v["steps"] for k,v in d["sequences"].items()})'
  ```

- **`$CLAUDE_PLUGIN_ROOT/examples/*.json`** — `otter`, `chinchilla`, `whale`,
  `shark`, `sea-lion`. Five animals at scale 1, each declaring all eight
  sequences off five frames apiece. The husky is one of them and is also the
  built-in, which is why it has no row of its own — the built-in row already is
  it.

  **Read them for FORMAT, never for art.** They were quantised from raster
  renders: 44 inks each, and around half of their pixels share a colour with no
  neighbour at all. That is not something a character grid can be written to
  produce by hand, and aiming at it gets you noise rather than shading — the
  craft rules above are what this medium actually expresses. What these files
  are good for is the shape of a `steps` timeline, where `mirror` goes, and how
  a sequence block is assembled.

  Read them by that full path, not a bare relative one, since the skill runs
  with the user's project as the working directory — and read a SLICE:

  ```bash
  python3 -c 'import json;d=json.load(open("'"$CLAUDE_PLUGIN_ROOT"'/examples/otter.json"));print(json.dumps({k:d[k] for k in ("name","scale")}));print(len(d["palette"]),"inks");print({k:v["steps"] for k,v in d["sequences"].items()})'
  ```

  The three land animals stand upright and are sized off their height (92–110
  wide); the three sea animals are long and horizontal, so all three hit the 128
  ceiling on width and come out shorter instead — which is what a pet looks like
  when the canvas budget binds on the other axis.

For the shape of a whole manifest at a size you can actually hold, use the
`blob` under **Manifest format** at the top of this document. It is complete and
valid, and it is there for exactly this: nothing under `examples/` is small
enough to serve as one any more.

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
