# Contributing

**Read [AGENTS.md](AGENTS.md) before you write anything.** It is short on
purpose and every line in it was earned by a shipped bug. The four traps below
are the ones that waste a whole day if you meet them by surprise; AGENTS.md and
`docs/invariants/` have the rest.

## Four things that will cost you a day

**Never run `perchling` with no arguments.** It starts a real pet window on
your desktop, and it will not exit while any Claude Code session is live — the
30-second idle quit only fires when the sessions directory is empty. Unknown
arguments print usage and exit 2, so a mistyped flag is safe; a bare invocation
is not. `bash scripts/pet.sh wake` and `pet.sh enable` are equally live: they
end in `cmd_up`, which will compile your checkout and launch it. Verify with
`--validate`, an offscreen render, or a harness — never by launching. The six
techniques are in [docs/invariants/harnesses.md](docs/invariants/harnesses.md).

**Hooks do not run your checkout.** `hooks/hooks.json` resolves
`${CLAUDE_PLUGIN_ROOT}` to the *installed marketplace clone*, so editing
`scripts/pet.sh`, `scripts/state.sh` or `hooks/hooks.json` here changes nothing
until the commit is published and the user updates. The symptom is a new hook
feature that is silently inert while running the same script by hand works
fine. To test a hook-path change without publishing, pipe a payload straight
into the dev script:

```bash
printf '{"session_id":"test","prompt":"hi"}' | bash scripts/state.sh running
```

**A green assertion is not evidence.** This repo has shipped assertions that
tested nothing at least four times, twice in one afternoon. Any change to
`pose()`, the launch path, the build gate, `state.sh` or the manifest parser
has to be shown to FAIL against a mutant carrying exactly the defect it names.
Every harness takes a `PERCHLING_*` override for this, and
`tools/run-mutation-gate.sh` runs the whole argument as one command.

**A release is one line.** `.claude-plugin/plugin.json`'s version is the only
thing that reaches an install. There are no tags, and this repo *is* the
marketplace, so the version landing on `main` is the publish.

## Working on it

```bash
bash scripts/pet.sh build      # recompile the binary from this checkout
bash scripts/pet.sh status     # binary / process / state / session count
bash scripts/pet.sh stop       # drop refcounts and kill the pet
bash tools/run-mutation-gate.sh  # every harness goes red against its own defect
```

The ten layer harnesses are listed in AGENTS.md and all run by hand exactly as
they run in CI — `.github/workflows/harnesses.yml` is a thin caller. Run them
before you open a PR; the mutation gate is the slow one and the one that
matters.

"Verified" means: it compiles, the examples still validate, `--export` still
round-trips byte-identically, malformed manifests are still rejected, and **you
have looked at a rendered frame.** A harness is one more kind of evidence, not
a replacement for any of those.

## Pull requests

Conventional Commits (`feat:` / `fix:` / `refactor:` / `docs:` / `chore:` /
`test:` / `perf:`), in English, saying WHY rather than WHAT. One logical change
per commit. Do not bump the version in your PR — releases are cut separately.

If your change alters behaviour, interfaces, or project state, the docs it makes
stale are part of the diff: README, AGENTS.md, the file under
`docs/invariants/` for the layer you touched, and `skills/draw-pet/SKILL.md` if
you changed the manifest format.

## Drawing a pet

You do not need to touch Swift. A pet is a single JSON manifest, and
`skills/draw-pet/SKILL.md` is the authoring reference and ships to whoever asks
Claude to draw one; README's "Eyes that follow" covers the `eyes` block from the
user's side. `perchling --validate` with no arguments prints the built-in's
shape without writing anything to disk; start there rather than from
`--export`, which is 460KB.
