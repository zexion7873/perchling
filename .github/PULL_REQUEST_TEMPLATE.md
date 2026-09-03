## What and why

<!-- What changed, and what it fixes or adds. WHY rather than WHAT — the diff
     already says what. If it fixes an issue, link it. -->

## How you know it works

<!-- Delete the lines that do not apply. -->

- [ ] `bash tools/run-mutation-gate.sh` passes — the slow one, and the one that matters.
- [ ] I added or changed a guard, and **showed it go red against a mutant carrying
      the exact defect it names**. Which case, and what it printed:
- [ ] I looked at a rendered frame. (Only art or drawing changes. Grid dimensions
      passing validation say nothing about whether the creature reads.)
- [ ] `docs/moods.gif` and `docs/social-card.png` regenerated, and the README's
      `width=` still matches the GIF's real pixel width. (Only if the built-in's
      art moved, or plugin.json's description changed — the card renders it. The
      card is not live until re-uploaded at Settings → General → Social preview.)

> [!IMPORTANT]
> **Do not bump `.claude-plugin/plugin.json`.** That one line *is* the publish —
> this repository is the marketplace people install from — and releases are cut
> separately.

## Docs this makes stale

<!-- Which docs does this change invalidate? "None" is a fine answer — say it
     out loud rather than leaving this blank. CONTRIBUTING.md lists the four
     that usually go stale, and keeps that list so this template does not have
     to hold a second copy of it. -->
