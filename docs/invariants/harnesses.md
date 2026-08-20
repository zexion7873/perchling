# Verifying without launching, and the stub rules every harness depends on

Moved verbatim from `AGENTS.md`. The three-clause stub rule in here is a SAFETY
rule, not a style note: two of its clauses written alone walked an agent into
opening real pets on the user's desktop, and copies of the real binary were
once found in 55 scratch directories from a single fan-out.

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
