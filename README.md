# Perchling

A tiny pixel creature that perches on the corner of your screen and reacts to
what Claude Code is doing — so you can look away from the terminal and still
know when it needs you.

No Electron. No WebSocket server. No log scraping. A single ~200KB native
Swift binary, driven directly by Claude Code hook events, installed as a
plugin in one command.

## Install

### For AI agents

Paste this to your agent:

```text
Fetch and follow https://raw.githubusercontent.com/zexion7873/perchling/main/llms-install.md
```

([llms-install.md](llms-install.md) in-repo.)

### For humans

From inside a Claude Code session:

```
/plugin marketplace add zexion7873/perchling
/plugin install perchling@perchling
```

The pet appears on your next session. It builds itself from source on first
launch (~2 seconds, one-time).

**Requirements**: macOS + Xcode Command Line Tools (`xcode-select --install`).
On other platforms the plugin stays silently inactive.

## What it does

| State | Trigger | Perchling |
|---|---|---|
| running | you submit a prompt / tools execute | bounces quickly, glances left and right |
| waiting | permission prompt, agent needs input | stops and stares at you, twitching |
| done | turn or agent completed | hops happily, then settles |
| error | API failure ended the turn | droops |
| idle | nothing happening | breathes slowly, blinks |

While it works, a pixel speech bubble above its head shows a snippet of your
latest prompt plus what it's doing (thinking… / waiting for you… / done!).
The bubble vanishes when things go idle, and it never steals clicks — it's a
click-through overlay.

Its eyes follow your cursor. With several sessions running, it shows the most
attention-worthy state across all of them (waiting > error > done > running) —
one session's chatter can't drown out another one that needs you — and stale
moods expire on their own, so a killed session can't leave it bouncing
forever. It honors the system Reduce Motion setting.

Click the pet to jump back to Claude — the Claude desktop app if it's
running, otherwise the app that was frontmost when the pet launched. When
you're in another app, waiting / done / error each post a macOS notification
with a chirp; when you're already looking at Claude it stays quiet. macOS
attributes these notifications to "Script Editor" — allow them when the
first one asks, or they're silently dropped.

Drag it anywhere — the position sticks. Right-click for Tuck away (hides
until something needs you — or `scripts/pet.sh wake`), Disable (stays off
until `scripts/pet.sh enable`), or Quit. It exits by itself ~30s after your
last Claude Code session ends, and comes back with the next one.

## Custom pets

Don't like the default creature? Ask Claude to draw you a new one:

```
draw me a cat pet
```

The bundled `draw-pet` skill has Claude design a `pet.json` — a small
manifest of palette colors plus one pixel grid per mood — validate it, and
install it to `~/.claude/perchling/pet.json`. The pet transforms live within
a second: no rebuild, no restart, no image files. Delete the file to get the
default creature back.

Pets are shareable — a pet is one JSON file. Two worked examples ship in
[examples/](examples/): a leafy slime and the built-in pet itself; the format
is documented in [skills/draw-pet/SKILL.md](skills/draw-pet/SKILL.md).

Pixel size is up to the pet: a small grid at `"scale": 4` gives the chunky
retro look, while a grid twice as wide at `"scale": 2` covers about the same
corner of the screen with four times the detail.

To remix the default creature instead of drawing from scratch, snapshot it:

```bash
~/.claude/perchling/bin/perchling --export > mypet.json
```

A manifest carries pixels, not behavior, so the snapshot drops the default's
cursor-following pupils, idle blink, and blinking terminal cursor, and its
sideways twitch moves the whole body rather than just the eyes. (If that
command hangs and writes an empty file, the binary predates the feature — run
`scripts/pet.sh build` first.)

## How it works

Hooks write each session's mood into `~/.claude/perchling/sessions/<id>`
(plus the last event to `~/.claude/perchling/state` for manual control); the
app polls at 20fps and folds live sessions by attention priority with
per-mood expiry. The same files are the liveness refcount: re-stamped on
every prompt, removed on session end. No IPC, no daemon framework, no
network.

## Manual controls

```bash
# from the plugin directory
scripts/pet.sh status   # binary / process / state / session count
scripts/pet.sh stop     # remove all refcounts and kill the pet
scripts/pet.sh build    # force rebuild
scripts/pet.sh disable  # keep it off across sessions
scripts/pet.sh enable   # bring it back
scripts/pet.sh wake     # un-tuck a tucked pet
echo -n waiting > ~/.claude/perchling/state   # puppeteer it yourself
```

## Uninstall

```
/plugin uninstall perchling@perchling
```

Then `rm -rf ~/.claude/perchling` to remove the binary and state.

## Disclaimer

Unofficial community project. Not affiliated with, endorsed by, or sponsored
by Anthropic or OpenAI. All pixel art is original.

## License

MIT
