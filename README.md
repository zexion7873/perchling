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
| waiting | permission prompt, idle prompt, agent needs input | stops and stares at you, twitching |
| done | turn or agent completed | hops happily, then settles |
| error | API failure ended the turn | droops |
| idle | nothing happening | breathes slowly, blinks |

While it works, a pixel speech bubble above its head shows a snippet of your
latest prompt plus what it's doing (thinking… / waiting for you… / done!).
The bubble vanishes when things go idle, and it never steals clicks — it's a
click-through overlay.

Click the pet to jump back to Claude — the Claude desktop app if it's
running, otherwise the app that was frontmost when the pet launched. When
you're in another app, waiting / done / error each post a macOS notification
with a chirp; when you're already looking at Claude it stays quiet. macOS
attributes these notifications to "Script Editor" — allow them when the
first one asks, or they're silently dropped.

Drag it anywhere — the position sticks. Right-click to quit. It exits by
itself ~30s after your last Claude Code session ends, and comes back with the
next one.

## How it works

Hooks write a single word to `~/.claude/perchling/state`; the app polls the
file's mtime at 20fps and animates accordingly. Session liveness is a
refcount: each session touches a file in `~/.claude/perchling/sessions/`,
re-stamped on every prompt, removed on session end. No IPC, no daemon
framework, no network.

## Manual controls

```bash
# from the plugin directory
scripts/pet.sh status   # binary / process / state / session count
scripts/pet.sh stop     # remove all refcounts and kill the pet
scripts/pet.sh build    # force rebuild
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
