# Privacy

Perchling runs entirely on your Mac. It makes no network requests, opens no
ports, has no analytics, and sends nothing anywhere.

## What it reads

- **Hook payloads** that Claude Code hands its hook scripts on stdin. Perchling
  keeps the session id, the project directory, the tool a waiting session is
  blocked on, and a short snippet (below) of the prompt you typed or of
  Claude's final reply. Nothing else from the payload is kept.
- **The Claude Code CLI's session registry** at
  `${CLAUDE_CONFIG_DIR:-~/.claude}/sessions/*.json`, for the session id, the
  process id and the session's name, which label the rows in the pet's menu.
- **Your pet manifests**, the pixel art the pet draws.

It does not read conversation transcripts, conversation history or summaries,
or the Claude desktop app's own session records.

## What it stores

Everything lives under `${CLAUDE_CONFIG_DIR:-~/.claude}/perchling/`:

| File | Contents |
|---|---|
| `sessions/<session id>` | The session's mood, project directory, a snippet of at most 300 bytes of the latest prompt or reply (the speech bubble's text), the tool a waiting session is blocked on, and how many prompts you have sent. Readable only by your user account. |
| `owners/<session id>` | The process id of the app or terminal the session runs in. |
| `state` | The most recent mood word. |
| `bin/`, `pets/`, `pet.json`, `builtin.json` | The compiled pet, your pet library and the active pet. |
| `.sess.<number>` | A session file mid-write, renamed into `sessions/` a moment later. |

The pet window's position and the menu's preferences (mute, chrome theme,
collapsed bubble) are kept in macOS user defaults under the `perchling`
domain.

## How long

A session file, snippet included, is deleted when its session ends. If Claude
Code quits without ending the session — a force-quit or a crash — the file is
deleted at the next session start once it is more than an hour old. The
same goes for a `.sess.<number>` temp left behind when a hook is killed
mid-write. `pet.sh stop` deletes every session file at once.

Releases up to and including 1.21.4 also kept the latest snippet in
`perchling/say` and never deleted it. The first session start after updating
removes that file.

## Removing everything

Uninstall the plugin, then delete `~/.claude/perchling` — the
[README](README.md#-uninstall) explains what to check first, because your own
pets live there — and run `defaults delete perchling`.

## Questions

Open an issue at <https://github.com/zexion7873/perchling/issues>, or report
a vulnerability privately as described in [SECURITY.md](SECURITY.md).
