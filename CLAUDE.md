@AGENTS.md

## Rules a cloud session cannot see

A cloud session reads this repo and nothing from `~/.claude`. Only what no
check enforces belongs here; the user's global rules are the source and win
where the two disagree.

- Label every PR you open, mirroring the commit prefix: `fix:` → `bug`,
  `docs:` → `documentation`, `feat:` → `enhancement`, any other prefix → the
  label of that name, or the nearest one the repo already has.
- One logical change per commit. A subject that lists its fixes with commas
  is several commits.
- Off macOS (`uname` is not `Darwin`) nothing here builds, runs or renders, so
  CI on the PR is the only build evidence. Say in the PR body what you could
  not run, and when the change alters what a user sees or what a hook does,
  that a run on a Mac is still owed before merge. Never call it verified.
