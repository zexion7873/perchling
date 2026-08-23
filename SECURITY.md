# Security Policy

## Reporting a Vulnerability

**Do not open a public issue.** This repository *is* the marketplace people
install from, so a working exploit in a public issue is a working exploit
against every install that has already pulled.

Use [GitHub's private vulnerability reporting](https://github.com/zexion7873/perchling/security/advisories/new).

This is a one-person project. You will get a first response within a few days,
not within hours, and the fix ships as a version bump in
`.claude-plugin/plugin.json` — nothing else reaches an install.

## Supported versions

The latest published version only. There are no maintenance branches and no
tags: whatever `.claude-plugin/plugin.json` says on `main` is what
`claude plugin update` hands out, and older versions are never patched.

## What this plugin actually does on your machine

Worth knowing before you decide whether something is in scope. Installing it
puts three things on your disk:

- **Hook scripts** (`scripts/state.sh`, `scripts/pet.sh`) that Claude Code runs
  on session and tool-use events, with the hook payload on stdin.
- **A Swift binary** compiled on your machine from `scripts/pet.swift` and run
  as an accessory app. It draws an overlay window and reads a menu.
- **A runtime home** at `${CLAUDE_CONFIG_DIR:-~/.claude}/perchling` holding the
  binary, the session refcounts, and the active pet manifest.

It makes no network requests, opens no ports, and reads nothing outside that
runtime home and the paths the hook payload names.

### In scope

- Anything in a hook script that lets payload content escape its quoting — the
  session id becomes a filename, and a traversal in it was a real bug once.
- Anything that writes outside the runtime home, or that follows a link out of
  it.
- A pet manifest that can do more than render badly. Manifests are a shareable
  single-file format: one crashing the parser is a bug, one reaching the
  filesystem or the shell is a vulnerability.
- Anything in the release path that could serve modified content to an install.

### Out of scope

- The pet window sitting above other windows, or refusing to quit while a
  Claude Code session is live. Both are deliberate; `pet.sh stop` ends it.
- A malformed manifest that only makes `--validate` exit nonzero. That is the
  tool working.
- Anything requiring an attacker who can already write to your
  `~/.claude` directory. At that point the pet is not the problem.
