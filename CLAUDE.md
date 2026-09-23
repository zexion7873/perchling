@AGENTS.md

## Rules for cloud sessions

A cloud session sees this repo and nothing from `~/.claude`. The rules below
are a deliberate subset of `~/.claude/CLAUDE.md`, which is their source and
wins wherever the two disagree.

- Work on a branch and land it through a PR. The task authorises pushing its
  own branch and opening the PR; merging, anything touching `main`, and any
  force push need the user's explicit yes in the thread. Merge with
  `gh pr merge <n> --merge` (squash and rebase are disabled); delete branches
  with `git branch -d`, never `-D`.
- Commits: Conventional Commits in English, WHY not WHAT, one logical change
  each. Stage by explicit filename after reading `git status` and `git diff`,
  never `git add -A` / `git add .`.
- Never `--no-verify`, never force push, never `--amend` a pushed commit — fix
  forward. `.claude/settings.json` denies most of these by command text, so
  rewording a command until it slips past a rule is the violation, not a
  workaround.
- Label every PR you open: `fix:` → `bug`, `docs:` → `documentation`,
  `feat:` → `enhancement`, `chore:` → `chore`.
- Nothing is done while it holds a TODO stub, a skipped or stubbed test, or an
  unimplemented branch; report it as a blocker instead.
- Off macOS (`uname` is not `Darwin`) nothing here builds, runs, or renders:
  CI on the PR is the only build evidence, and a user-facing change still
  needs a run on a Mac before merge. Say which of those you could not do;
  never call it verified.
- Touch only what the task needs; report unrelated problems instead of fixing
  them.
- A comment names what breaks if the code changes, in one or two lines — no
  diary, no restating the code, no design essay.
