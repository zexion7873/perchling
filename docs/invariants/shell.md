# Launch, build, state.sh and hooks invariants

Moved verbatim from `AGENTS.md`, which now carries only each layer's most
lethal rule and a pointer here. Every bullet below was earned by a shipped bug
or a measured dead end — nothing in this file is style. New invariants for this
layer belong HERE, written the same way: what was measured, what it rules out,
and what the alternative lost to.

## The launch lock, and the lock inside the lock

**Agents are not the only way to get several pets, and blaming them was the
wrong diagnosis.** Three overlays were observed on the user's desktop at once
with no agent involved: three ordinary sessions hit `SessionStart` inside the
same few milliseconds and `cmd_up`'s check-and-launch had nothing atomic
between its halves. The window is a property of the machine and it MOVES:
callers staggered by **4–12 ms each launch their own pet** here, where the
figure was 4–16 when first measured, and past the top of it the first pet is
already visible and the rest correctly stand down. `launch_once` closes it with
a `mkdir` mutex — macOS ships no `flock(1)` — and the lock is held until the
child is VISIBLE to `running()`, not merely until `nohup` returns, because
releasing at spawn time only narrows the window rather than closing it. It is
reclaimed after a minute so a process killed mid-launch cannot wedge every
future session start.

**Reclaiming that lock is a second critical section, and 1.13.0 shipped it as a
plain check-then-act — the same defect one level in**, measured at four pets
from eight callers. The trap worth carrying out of `launch_once`'s own comment:
making the reclaim ATOMIC does not fix it, and was measured failing the same
way. `rmdir` is a genuinely exclusive claim, but the staleness verdict it acts
on comes from a `find`, and a fork+exec is long enough for somebody else to
reclaim and take the lock. Serialising reclaim is what works, and the freshness
re-test inside that lock is load-bearing rather than belt-and-braces: dropping
it alone still launches two.

The reclaim also has to survive a lock it cannot `rmdir`. That call refuses a
non-empty directory and nothing else clears the lock, so anything that ever
lands inside one wedges every future launch permanently — the exact failure the
reclaim exists to prevent. Nothing writes in there, so it takes an outside
cause, which is the kind of thing a lock has to survive rather than assume away.
A stale lock that will not `rmdir` is RENAMED aside: one syscall, works on a
non-empty directory, and leaves the debris where a human can look at it.
`rm -rf` on a path built from an environment variable is not something this
script should own.

## The invariants

- **Not every wait announces itself, and not every announcement reaches the
  plugin.** `waiting` has three triggers, and they cover different failures
  rather than duplicating each other. `PermissionRequest` fires whenever a tool
  call needs a permission decision; it takes no matcher because the point is
  that it does not depend on knowing which tools block. The `PreToolUse` matcher
  covers the affordances that block on a human WITHOUT entering the permission
  flow at all — asking a question, presenting a plan — which no permission event
  can see. The `Notification` event matches a regex over the notification type
  (`permission_prompt` also catches `worker_permission_prompt`).
  **In the Claude Code desktop app the third one never fires, and the reason is
  structural rather than a bug.** The app launches the CLI with
  `--permission-mode auto --permission-prompt-tool stdio`, so a decision leaves
  as a control-protocol `can_use_tool` request and the app draws its own dialog;
  Claude Code's own notification path is never reached. Measured with one prompt
  and a forced `permissions.ask` rule, varying only the host:

  | host / path | fires at the permission decision |
  |---|---|
  | interactive terminal CLI | `PermissionRequest`, then `Notification` |
  | `--permission-prompt-tool stdio` (what the desktop app runs) | `PermissionRequest` only |
  | headless `-p` | neither, even though the decision was genuinely required |

  So **headless is not a proxy for either host** — a probe run under `-p` that
  sees nothing has measured nothing. The user-facing macOS banner and the
  plugin-facing hook event are separate mechanisms too; seeing the banner says
  nothing about the hook, which is the easy way to get this backwards.
  `PreToolUse` still cannot cover the permission gap — it runs before the
  permission check, so it cannot tell a call that will prompt from one that will
  just run — and that is exactly why `PermissionRequest` is its own arm instead
  of a wider `PreToolUse` matcher. It does not fire when a rule or the
  classifier already allowed the call, so it cannot manufacture a false
  `waiting`, and a false one would self-heal anyway: nothing has to clear
  `waiting`, the next tool batch writes `running` on its own.
- **Adding an event name to `hooks/hooks.json` is a compatibility decision, and
  getting it wrong is silent and total.** An event key the running CLI does not
  recognise voids EVERY hook in the file, not just its own entry — so the pet
  never launches at all, no `SessionStart`, no error anywhere the user can see.
  Measured one variable at a time with throwaway plugins and a
  `UserPromptSubmit` canary: `UserPromptSubmit` alone fires, `PermissionRequest`
  + `UserPromptSubmit` fires, and adding one bogus key to either kills both.
  **A `--settings` file does the exact opposite and ignores unknown keys**, so a
  probe run with `claude --settings` proves nothing about this file; they are
  separate validators with opposite failure modes, and the permissive one is the
  easy one to reach for. The published docs describe the permissive behaviour
  for both, and are wrong about plugins. `bash tools/run-hooks-check.sh` is the
  gate; it has to copy `plugin.json` and `hooks/` to a scratch directory first,
  because `claude plugin validate` pointed at this repo finds
  `.claude-plugin/marketplace.json` and validates that instead, never reaching
  hooks.json. Before adding an event, establish how far back it is accepted by
  running an old CLI's own `plugin validate` — the tarballs are on npm and that
  subcommand needs no auth. `PermissionRequest` was cleared this way back to
  2.1.109, over a hundred releases; 2.0.x demands auth before validating and was
  not measured.
- **`pgrep -f "$BIN"` cannot answer "is the pet running", because the probes see
  each other.** `-f` matches any process whose whole argv CONTAINS the pattern,
  and a concurrent `pgrep -f "$BIN"` has that path in its own argv. Measured:
  eight simultaneous probes against a path **no process was running from** all
  eight reported a hit. So the same burst of session starts that can launch
  several pets can also launch NONE — every caller concludes one is already up —
  and `pet.sh status` will say `running` beside an empty screen. `running()`
  therefore uses `pgrep -x -f`, which requires the argv to EQUAL "$BIN": the
  overlay's does, since it is exec'd as `nohup "$BIN"`, and a probe's never can.
  The three `pkill` sites carry `-x` for the same reason — without it a teardown
  can match and kill somebody's in-flight `pgrep`. Two consequences for anyone
  writing a harness. A shebang-script stub is invisible to `-x -f`, because its
  argv is `/bin/bash <path>` — but do not read that as "so copy the real
  binary", which satisfies it and opens a pet window; the stub rule has a third
  clause and it is in [harnesses.md](harnesses.md), beside the stub rules.
  And `pgrep -x perchling` was rejected as the alternative precisely because it
  matches by process NAME and would see an unrelated install, which breaks the
  scratch-`CLAUDE_CONFIG_DIR` isolation every test here depends on.

  **`-x` is not enough on its own, because the pattern is a REGEX and `$BIN` is
  a path the user chose.** A config directory named `cfg+test (1)` makes `+` a
  quantifier and `(1)` a group, and the pattern then matches nothing: measured
  against a process genuinely running from such a path, `pgrep -x -f "$BIN"`
  reports NOT FOUND. Both halves break at once and neither says so — `running()`
  reports stopped beside a visible pet, so each session start adds another, and
  all three `pkill` sites match nothing, so `stop` and `disable` stop nothing.
  `BIN_RE` is escaped once beside `BIN` and is what all four uses match on.
  Matching literally with `ps -Awwo args= | grep -qxF` removes the class of bug
  instead of escaping it, and lost on cost: 33.9ms against pgrep's 20.7 per
  call, in a function polled up to 50 times per launch.

  The assertion for this must be the ALREADY-RUNNING shape, never a stampede.
  A stampede cannot see it: the lock serialises the callers, the holder spins
  out its full five seconds waiting for a pet `running()` will never admit to,
  and the rest stand down against a genuinely fresh lock — one launch, green,
  against the broken script. The damage lands between session starts, where no
  lock is left to mask it. The first version of that assertion scored 13/13
  against the mutant it existed to catch.
- **`state.sh` runs on every prompt and every tool batch.** Keep it cheap, never
  let it fail a hook, and do not add a `jq` dependency — the existing `sed`
  extraction style is deliberate. Hook payloads arrive as one blob on a pipe the
  harness holds open, so it reads with a single `dd bs=65536 count=1` rather
  than to EOF.

  **It honours `disabled` too, and that is what makes `disable` mean it.**
  `cmd_up` has always read the flag, so a disabled install launched no pet, but
  the hot path kept running a `dd`, five `sed`s and three writes on every
  prompt and every tool batch of every session for a user who had turned the
  pet off. The test is a shell builtin before the `mkdir`, so a disabled
  install also stops recreating the runtime home. Refcounts stop being
  re-stamped while it is set, which is the intended shape rather than a cost:
  `cmd_down` still removes them at `SessionEnd` so nothing leaks, a live
  session re-announces itself on its next hook after `enable`, and one too
  stale to do that is one the staleness window would have retired anyway.
- **Whether the machine can build is a different question from whether the pet
  can run, and four separate ways of conflating them are all silent.** Nothing
  here has a harness, and every one of these was found by measurement after
  looking correct.

  `command -v swiftc` is not a capability check. `/usr/bin/swiftc` is an xcrun
  stub macOS ships whether or not a toolchain is installed — 118KB, root-owned,
  78 hard links, one per `/usr/bin` dev tool — so it succeeds on exactly the
  machine the guard exists to reject. Hence `macos()` and `supported()` are
  two predicates: the probe costs ~117ms per exec, and `cmd_up` runs at every
  `SessionStart`, so gating the LAUNCH on it both wastes that on every session
  and refuses to start an already-built binary on a machine whose Xcode later
  vanished. `cmd_up` takes the cheap one; only the build path pays for the real
  one.

  The probe's output is held, not passed through. An unaccepted Xcode licence
  fails `swiftc --version` exactly like an absent toolchain, and only the
  compiler's own words tell them apart — but `--version` also writes an
  unterminated `swift-driver version: … ` banner to stderr when it SUCCEEDS,
  and `supported()`'s stderr is the build log, so passing it through fuses the
  banner onto the first diagnostic and into the status headline.

  **`$ROOT/build.log` belongs to the build, not to whoever called it.** A
  caller-side redirect cannot own it: it holds the file open, so a `rm` inside
  `cmd_build` would unlink the very inode the reason is still being written to
  and the log would vanish on failure. `cmd_build` therefore opens it, prints
  it either way — a successful build's WARNINGS are most of the value of
  running `pet.sh build` by hand, and capturing them to a file about to be
  removed eats them silently — and removes it only on success.

  That is not enough on its own, because `cmd_up` builds only when the binary
  is missing or stale, so on a healthy install no session start runs a build at
  all and nothing retracts a reason. A dev checkout's `pet.sh build` failing
  against its own `$SRC` while sharing one runtime home, or a transient
  breakage fixed in a way that never moves `$SRC`'s mtime, would otherwise
  leave `status` naming a build nobody can retract beside a binary it calls
  `(built)`. So `cmd_up` removes the log on the branch where it does NOT
  build: every other line of `status` reports current state, and this one must
  too.

  **Finding the reason in a swiftc log is subtraction, not a pattern.** The
  message comes first and its source excerpt after, so `tail -1` reports
  `951 |  }`. An unanchored match for `error:` finds the excerpt's own caret
  line, or one of the nine lines in `pet.swift` that contain that text — the
  `moodRank`/`moodTTL` tables and the mood-wording table. And a column anchor
  does not save it: swiftc right-aligns each excerpt's line number to the width
  of the WHOLE FILE, so in a four-digit source every quoted line from 1000 up
  starts at column 0 too, and eight of those nine sit up there. (The line count
  is deliberately not written down here — it moves with every change, and what
  the argument needs is only that the file is over a thousand lines.) What every excerpt line
  does carry is the ` | ` gutter, so the headline drops those and takes the
  first `error:` among what remains.

  **The gutter filter could not be shown load-bearing, and the fixture that
  tried is committed anyway.** `swiftc` emits NO warnings once it has an error,
  so a failed build's log is always one diagnostic followed by its own excerpt —
  and `grep -m1` therefore reaches the real message before any excerpt line,
  filter or no filter. Two constructions were tried, both siting a warning on
  the `moodTTL` row so its excerpt would precede the error; the compiler printed
  no warning either time. The filter stays because it costs nothing and another
  compiler mode may order things differently, but `run-build-gate.sh` labels the
  assertion covering it a negative control rather than pretending otherwise.
  What the fixture DOES pin is the `tail -1` mistake, which reds two
  assertions.

  A hand-written fake `swiftc` is why two of these shipped green: the fixture
  put its error on the last line, which the real compiler never does. Fake the
  interface, never the output format — capture that from one real run.

  **A failed build gets three things right, and each of them is a separate
  branch.** It must not corrupt the binary: `compile()` writes `swiftc`'s
  output to a `$$`-suffixed staging name in `bin/` and renames on zero exit,
  because a compile killed partway through the old in-place write left a
  truncated 0755 file with an mtime newer than `$SRC` — exactly what the
  rebuild gate reads as current, so nothing rebuilt it, `status` called it
  `(built)`, and the install was wedged with no path back. A `$$` name rather
  than a lock: concurrent session starts after a plugin update then build their
  own copies of the same source and the last rename wins, which is harmless,
  where a lock is a second wedgeable mutex bought to save CPU in a window that
  opens once per release. It must not empty the desktop: the `pkill` runs only
  on the branch where `cmd_build` SUCCEEDED, since a failure returns before
  `launch_once` is ever reached and nothing puts a pet back — and `rename()`
  over a running executable succeeds where a write returns `ETXTBSY`, so
  clearing the path first buys nothing anyway. And it must not repeat: a
  `$BUILDLOG` newer than `$SRC` means this exact source has already been tried,
  and without that test a source that compiles for the author and not on this
  machine burns a full `swiftc -O` inside the 30s hook timeout on every session
  start, forever, and still ends with no pet. That third test is why the
  log-retracting branch is now an explicit `elif` on "present AND current"
  rather than a bare `else`: the `else` of the widened condition also catches
  "needs a build, already failed", and deleting the reason there is deleting
  the only thing that stops the loop.

  `tools/run-build-gate.sh` pins the first, second and fourth of those, and
  takes `PERCHLING_PET_SH` so it can be shown to FAIL: against the pre-fix
  script it goes red on `pet-survives-failed-build` and `no-rebuild-loop`.
  Only those two discriminate — `binary-untouched`, `reason-recorded` and
  `no-staging-debris` pass against that mutant too, because `swiftc` writes no
  output at all on a parse error, and they are negative controls rather than
  coverage. Its mtimes are set with `touch -t`, never by writing the file: the
  first version let `cc`, `touch` and `swiftc` land inside the same second and
  `-nt` then answered differently run to run, which produced three verdicts
  from three runs and none of them about the code.
- **Only `cmd_up` launches the pet, and of the hook events only `SessionStart`
  reaches it.** Everything else — `UserPromptSubmit`, `PostToolBatch`, `Stop`,
  `StopFailure`, `PreToolUse`, `PermissionRequest`, `Notification` — runs
  `state.sh`, which writes the global state file and the session refcount and
  starts nothing. So a pet
  killed mid-session by `pet.sh stop`, by the menu's Quit, or by a crash does
  NOT come back on the next prompt: it comes back when a new session starts, or
  from `pet.sh up`, `pet.sh enable` or `pet.sh wake`, each of which calls
  `cmd_up` when nothing is running. This is easy to get backwards — and was, in
  advice given to the user — because the next prompt visibly does re-stamp
  `sessions/<sid>`, so the refcount returns without the process.
