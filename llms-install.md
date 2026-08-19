# Perchling — install guide for AI agents

Perchling is a Claude Code plugin: a tiny native macOS desktop pet that
perches on the screen and reacts to Claude Code hook events. Follow these
steps to install it on the user's machine.

## 1. Preflight

Perchling is macOS-only and compiles itself from source on first launch.

```bash
[ "$(uname)" = Darwin ] || echo "NOT macOS"
swiftc --version
```

Run the compiler, don't just locate it: `/usr/bin/swiftc` is a stub that ships
with macOS, so `command -v swiftc` succeeds on the very machine this step
exists to reject. Read its output rather than only its exit status — a
toolchain that is absent and one whose licence has not been accepted both fail
here, and only the message tells them apart.

- Not macOS → stop and tell the user perchling is macOS-only. Do not install.
- `xcrun: error: unable to find utility` → have the user run
  `xcode-select --install`, then retry.
- A licence complaint → have the user run `sudo xcodebuild -license`. Do not
  run it for them; it needs their admin password.

## 2. Install

The `/plugin` commands in the README are REPL slash commands and won't work
from a shell — use the CLI:

```bash
claude plugin marketplace add zexion7873/perchling
claude plugin install perchling@perchling
```

If these fail on a machine where Claude Code has never been run interactively,
have the user launch `claude` once first, then retry.

## 3. Verify

```bash
claude plugin list | grep -i perchling
```

Nothing to configure: the pet builds itself (a few seconds, on first launch and
again after every plugin update) and appears when the user's next Claude Code
session starts. After that first
session, the build succeeded if
`"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/perchling/bin/perchling"` exists.

- Missing there → run `pet.sh status` (resolve the script as in Control,
  below). `sessions: 0` means no hook has run yet. A `build: failed` line
  names the reason and points at the full compiler output.
- No `build:` line and still no binary → nothing has tried to build yet. Run
  `pet.sh build` directly; it is the only path that reports on its own stdout.

## 4. Launch it now (recommended)

Hooks only register at session start, so after a mid-session install the pet
would first appear at the user's *next* session. Don't make them wait — launch
it immediately:

```bash
bash "$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins" -type f -path '*perchling*/scripts/pet.sh' 2>/dev/null | head -1)" up manual
```

This builds (first run) and starts the pet right away; it perches at the
bottom-right of the screen. The `manual` liveness stamp expires after ~1 hour,
after which real Claude Code sessions keep the pet alive via their own hooks.

## Control & uninstall

The control script lives inside the installed plugin and its path carries a
version number, so resolve it once:

```bash
pet=$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins" -type f -path '*perchling*/scripts/pet.sh' 2>/dev/null | head -1)
```

Then, in that same shell, run the one the user asked for — not the whole
block; `enable` and `wake` start a real pet.

```bash
bash "$pet" status   # binary / process / state / session count
bash "$pet" stop     # remove refcounts and kill the pet
bash "$pet" build    # force rebuild
bash "$pet" disable  # keep it off across sessions
bash "$pet" enable   # bring it back
bash "$pet" wake     # un-tuck a tucked pet
```

Uninstall: `claude plugin uninstall perchling@perchling`. That leaves the
runtime home behind — binary, state, and the user's pet library:

```bash
home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/perchling"
ls -l "$home/pets" "$home/pet.json"
```

Copies of the shipped examples are replaceable; anything else is a pet the
user drew, and the draw-pet skill *moves* one in rather than copying it, so
it may be the only copy. `pet.json` counts too — it can be a regular file
rather than a symlink. Ask, then remove `"$home"`.
