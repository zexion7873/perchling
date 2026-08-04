# Perchling — install guide for AI agents

Perchling is a Claude Code plugin: a tiny native macOS desktop pet that
perches on the screen and reacts to Claude Code hook events. Follow these
steps to install it on the user's machine.

## 1. Preflight

Perchling is macOS-only and compiles itself from source on first launch.

```bash
[ "$(uname)" = Darwin ] && command -v swiftc >/dev/null && echo ok
```

- Not macOS → stop and tell the user perchling is macOS-only. Do not install.
- macOS without `swiftc` → have the user run `xcode-select --install`, then retry.

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

Nothing to configure: the pet builds itself (~2 seconds, one-time) and
appears when the user's next Claude Code session starts. After that first
session, the build succeeded if `~/.claude/perchling/bin/perchling` exists.

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

From the installed plugin directory:

```bash
scripts/pet.sh status   # binary / process / state / session count
scripts/pet.sh stop     # remove refcounts and kill the pet
scripts/pet.sh build    # force rebuild
scripts/pet.sh disable  # keep it off across sessions
scripts/pet.sh enable   # bring it back
scripts/pet.sh wake     # un-tuck a tucked pet
```

Uninstall: `claude plugin uninstall perchling@perchling`, then
`rm -rf ~/.claude/perchling` to remove the binary and state.
