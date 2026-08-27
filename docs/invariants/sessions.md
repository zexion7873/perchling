# Session, tray and pet-library invariants

Moved verbatim from `AGENTS.md`, which now carries only each layer's most
lethal rule and a pointer here. Every bullet below was earned by a shipped bug
or a measured dead end — nothing in this file is style. New invariants for this
layer belong HERE, written the same way: what was measured, what it rules out,
and what the alternative lost to.

- **The active pet is a symlink, and its target is the only record of which
  pet is active.** There is no config file and must not be one: a "selected
  pet" setting would be a second source of truth that can disagree with the
  file actually being rendered. `pollPet` already resolved symlinks before the
  library existed, for dotfiles setups, which is why the renderer needed no
  change. Two things follow. A shipped pet is copied into `pets/` before it is
  linked, because the plugin path carries a version number and is replaced
  wholesale on update — a link into `examples/` dangles the moment the user
  runs `plugin update`. And `pet.json` arriving as a regular file is the
  pre-library state, not a corruption: it gets moved into `pets/`, never
  linked over, because it may be the only copy of a pet someone drew. That is
  not a launch-time concern that migration retires — the process outlives a
  whole session, and `pet.json` can go back to being a loose file at any point
  in it, so every path that removes `pet.json` rescues it first and refuses the
  removal outright when the rescue cannot finish. A rescue that fails quietly
  and then deletes is the same data loss with more steps.

  The whole property is two lines of `clearPetLink` — their ORDER, and the
  `try` on the first, which makes a failed rescue throw before the removal
  below it can run. Swapping them or weakening that `try` to `try?` deletes a
  pet with no other copy, is a one-line diff, and reads in review like tidying.
  `tools/run-session-harness.sh` now calls this layer rather than merely
  compiling it: an unwritable `pets/` makes `clearPetLink` throw and leaves
  `pet.json` intact, and both mutations were shown to fail that pair. The
  collision suffix is asserted beside it, because a second rescue overwriting
  the first is the same loss one step along.
- **A picked shipped pet refreshes only over proof, and the proof is a file.**
  `adoptShippedPet` copies the shipped manifest into `pets/` and records the
  same bytes again at `pets/.shipped/<name>.json`; `cmd_up` then refreshes a
  library copy to the currently shipped bytes only while the copy still
  matches its record, updating the record in the same pass. Without the loop,
  no art update can ever reach a picked pet — the menu hides the shipped row
  while the copy exists, so the pick-time snapshot is all the user can ever
  see (measured on a live install: four copies still carrying mid-development
  bytes after the 1.17.2 repairs shipped). A copy that differs from its
  record carries the user's edits — the library is theirs — and is never
  touched; a copy with NO record predates the mechanism and stays frozen,
  because without proof "stale shipped snapshot" and "hand-tuned pet" are
  indistinguishable on disk, and guessing wrong is the `clearPetLink` class
  of loss. The record is a whole copy rather than a hash so both writers stay
  a `cmp`: a hash is a Swift/shell contract on hasher and encoding, and those
  two drifting apart is invisible until it eats an edit. Order matters twice.
  `cmd_up` writes the COPY first and the record second — killed between the
  two, the next run finds copy == shipped and re-syncs the record; the
  reverse order leaves copy != record, which reads as a user edit and freezes
  that pet forever, the original bug reborn inside its own fix. And a copy
  that is already current is never rewritten in place: `pollPet` reloads on
  mtime, so a needless staged rename repaints the pet on every session start.
  An orphaned record (pet deleted by hand) is pruned; a retired shipped pet
  (source gone from `examples/`) keeps both files, because the copy may be
  the only one anywhere. `petChoices` scans `pets/` for `.json` files only,
  so `.shipped` never grows a menu row. Pinned in
  `tools/run-library-refresh.sh`, the adopt half in
  `tools/session-harness.swift`, and all four mutations — no refresh, no
  pristine guard, no heal arm, no record at adopt — were shown to fail.
- **A checkmark means "on screen", which is not "what the link points at".**
  A manifest that fails to load leaves `pet.json` pointing at it while the
  built-in is what renders, and a dotfiles `pet.json` can point outside `pets/`
  at a pet with no row in the menu at all. `PetView.custom` is the only honest
  answer — `pollPet` clears it on every fallback — so the menu asks that rather
  than deriving the tick from the list. Fixing one row's rule without the other
  produces two checkmarks.
- **Session files are mood, refcount, label, caption, and the waiting
  detail.** Line one is the
  mood; an optional line two is that session's `cwd`, which the tray rows show
  and the fold ignores; an optional line three is the caption the bubble
  quotes; an optional line four is the tool a `waiting` session is blocked on.
  `Mood.parse` reads line one, so every shorter form stays valid
  forever — `pet.sh up` writes the one-line form whenever there is no payload
  behind the launch (`manual`, `enable`, `wake`). **`state.sh` carries line
  three forward when it has nothing new to say**: only a prompt and a `done`
  reply produce text, a tool batch produces none, and a session file is
  rewritten whole on every hook — so writing the empty value would blank the
  bubble halfway through a turn. The global `say` never had that problem
  because it is only written when non-empty, which is exactly why the session
  file has to re-read its own line 3 first. Line four has the same carry rule
  with a mood gate on it: a `waiting` hook with no `tool_name` of its own
  keeps the last one — a terminal host answers one permission decision with
  `PermissionRequest` and then `Notification`, and the second write must not
  blank what the first just recorded — while any other mood retires it,
  because the wait is over. The extraction mirrors the sid's first-match
  prefix-strip, not the cosmetic last-match: measured 2026-08-27,
  `"tool_name"` is the CLI's own top-level key and serialises before
  `tool_input`, so first-match is what keeps a nested `tool_name` from
  naming the tool on screen. It is gated on `waiting` so the hot path never
  pays for it, and shape-checked to a real tool name's alphabet
  (`A-Za-z0-9_-`) — a hostile token degrades to no detail, never a repaired
  one. Writing a session file re-stamps
  liveness; never `touch` one, because that resurrects a stale mood with a
  full TTL. The `manual` entry is a bridge for launches with no session behind
  them, retired by the first real session or by the last `SessionEnd` — it is
  not a session, must not outlive them, and must not appear in the tray.
  Hook payloads do carry `cwd`: observed on seven event types so far —
  `UserPromptSubmit`, `Stop`, `SessionStart`, `SessionEnd`, `PreToolUse`,
  `PostToolUse` and `PostToolBatch` — each from a real headless CLI run, not
  read off the docs. In every one of those seven, `"cwd"` occurred exactly
  once, including on tool events carrying `tool_input`.
- **That survey covers `cwd`, and `session_id` is not the same question.** The
  cosmetic extractions are greedy and take the LAST match, so a payload whose
  `tool_input` carries a key of the same name wins over the top-level one. For
  `cwd` the cost is a wrong directory on one tray row until the next hook,
  which is why that extraction accepts it. For `session_id` the value becomes
  a FILENAME: `mv -f` in `state.sh` and `cmd_up`, `rm -f` in `cmd_down`.
  Measured end to end — a nested `"session_id":"../../../evil"` resolves three
  levels above the sessions directory and clobbers an arbitrary file whose
  third line the same payload chose, and `PostToolBatch` carries no matcher,
  so every tool batch is a delivery route. So the sid extraction differs from
  its cosmetic siblings twice over, in one direction each. It takes the FIRST
  match (a builtin prefix-strip, no fork): the CLI writes its own `session_id`
  as the payload's leading key and everything an embedded object carries
  serialises after it, where the last match handed a well-formed nested UUID
  the refcount — a ghost row holding the pet up for the staleness hour while
  the real session's "waiting" went stale mid-wait. And it checks the SHAPE
  (`case "$sid" in ''|*[!A-Za-z0-9_-]*)`), rejecting rather than sanitising:
  an empty sid degrades to no refcount for that hook, where a repaired one
  still names a file somebody else picked. Both rules live in `state.sh` and
  `pet.sh` as a mirrored pair; `run-state-checks.sh` pins routing and shape
  separately, and the mutation gate carries a mutant for each. The general
  form of the original trap is worth more than either fix — a measurement of
  the harmless field read as a verdict on the dangerous one, in prose that
  looks exactly like the measured bullets around it.
- **`sessions/` is read for moods in exactly one place.** `liveSessions()`
  owns the owner-alive guard, the one-hour staleness cutoff, and the per-mood
  TTL decay, and both the attention fold and the tray rows consume its
  output — a second *mood* scan is how the face ends up showing idle while
  the menu says "thinking…". `pollSessions()` walks the same directory too,
  for the 30s-empty-grace liveness check, but never touches a mood — it is
  not the second reader this bullet forbids, and adding one that reads a mood
  would be.
- **The session registry is one of two foreign files perchling reads, and by
  itself it is not where a tray row's name comes from.**
  `<config>/sessions/<pid>.json` carries a session's id and the CLI's own name
  for it — usually derived from the cwd rather than typed by a human (measured
  on this machine: `perchling-de`, `nameSource: derived`) — one layer in the
  title → name → project directory → sid-prefix chain, not the top of it. It
  is undocumented, so
  `registryNames` treats every failure as a missing entry: a moved format, an
  older CLI and a background job that never had a name are indistinguishable
  from outside and all three are correctly answered by falling back. **A name's
  absence is normal, not a fault** — the CLI writes one only for interactive
  kinds, so every headless `-p` run and every background job has none. The
  registry directory is resolved from `CLAUDE_CONFIG_DIR` directly and never
  from `root`, because `PERCHLING_HOME` can point at a scratch directory with no
  registry in it. `nameSource` is deliberately not read: it would encode a guess
  about host naming policy, and `sessionLabels` guarantees two drawn rows never
  print the same string without knowing — except when two session ids share
  their first eight characters, where the guard against a doubled suffix
  (`abcdef01 · abcdef01`) knowingly leaves both unsuffixed instead. That
  guarantee is why the suffix is computed over the MENU rows and applied only
  on collision — and why it joins with a middle dot, since the em dash is
  already spent joining a label to its status. **There is a second foreign
  file, and perchling only ever reads it too:** the desktop app's own session
  records, at
  `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<uuid>.json`,
  joined to a `sessions/<sid>` file by their `cliSessionId`. The title in that
  record is what a tray row's name actually comes from when the session has
  one, and it outranks the registry name on purpose — every interactive
  session is given a `derived` registry name, so a name always answers, and a
  title ranked below it could never win; the two stores disagree about the
  same session by design, not by drift. A real record is ~279KB, almost all of
  it an MCP config block, and there is no index over the directory, so
  `desktopTitles` caches by modification time rather than reparsing on every
  poll — parsing every record on a 0.4s poll would put over a megabyte a
  second of JSON through the main thread. A bounded prefix read was rejected
  in its place: the JSON's key order is not guaranteed, so `title` might sit
  past whatever prefix was read, and the failure mode would be a title
  silently vanishing rather than falling back to the registry name.
  Enumeration asks for no resource keys and filters by filename first,
  because these records share a directory with hundreds of `deleted_`
  tombstones — asking for keys up front would turn one `readdir` into a
  `stat` per tombstone. `titleSource` is deliberately not read, for the same
  reason `nameSource` is not.

  **The enumeration is cached separately from the parse, and the two answer
  different questions.** Skipping every parse still walked the whole directory:
  351 tombstones against 3 real records, measured 2026-08-14, and growing on
  its own — 292 two days earlier. `TitleCache.dirs` memoises the records'
  directory listing against that directory's own mtime, which took a warm poll
  from 1167.4 µs to 80.8 µs.

  **Do not collapse the two into one gate.** A directory's mtime moves when an
  entry is added, removed or renamed and does NOT move when an existing file's
  contents are rewritten — measured on APFS, and true of
  `write(to:atomically:)` as well as an in-place write. A single dir-mtime gate
  therefore serves a renamed session's old title until some unrelated record is
  created or deleted. The listing cache may memoise WHICH files exist and never
  what is in them; the per-file stamp check stays. `tools/session-harness.swift`
  pins both halves, and each assertion was proven to fail alone under the
  mutation it exists for. The listing half needed `titleDirScans`, a counter
  nothing in the app reads — a pure performance change has no observable result,
  so without it deleting the cache leaves every assertion green.

  The listing cache needs no prune, unlike the parse cache: a removal moves the
  directory's mtime, so a stale listing is replaced on the next poll rather than
  answering forever.
- **A caption arrives still JSON-escaped, and BOTH captions are cleaned in one
  place.** `state.sh` captures the string body with a `sed`, so a two-line
  prompt reaches the file as the literal characters backslash and n.
  `cleanCaption` is the only unescaper and `liveSessions` and `pollSay` both
  call it. Putting it in `pollSay` alone was the shape of the bug worth
  remembering: `bubbleText` prefers `top.say` and only falls back to the global
  `say`, so the cleaned path was the one nobody normally sees and the escapes
  were on screen in every ordinary case. It is ONE PASS rather than a chain of
  `replacingOccurrences`, because a chain gets `\\n` wrong in either order — a
  user who typed a backslash before an n loses the backslash or gains a
  space — and an escape it does not recognise (`\uXXXX`, which that `sed`
  cannot decode anyway) passes through whole rather than half-eaten. Both
  mutations are pinned in `tools/run-session-harness.sh` and each was shown to
  fail alone.
- **The bubble quotes the session the face is reporting.** `menuRows()` already
  sorts most-attention-worthy first, so `sessionRows.first` IS that session, and
  `bubbleText()` takes its line three and its name. Before this the caption came
  from the global `say`, which every session overwrites unconditionally, so with
  several sessions open the face and the caption could describe different ones
  with nothing on screen saying so. The name is shown only when more than one
  session is live — with one there is nothing to tell it apart from, so it
  stays hidden whatever `sessionName` would have returned for it. The composed
  status line budgets the NAME by measured width, never a
  character count: the line holds about 34 monospace advances, the longest
  shipped status is "waiting for you… · 59m" at 22, and a CJK name spends two
  advances per character, so any character budget lets the status be the thing
  that gets cut. The age suffix rides the STATUS half on purpose — the status is
  the half that never truncates, and an age the layout could cut would count
  minutes only while the desk was quiet. `waitAge` prints minutes and nothing
  larger, which is not a style choice: `liveSessions` hides a row an hour after
  its last write, so no age it can be handed ever reaches 60m — and a blocked
  session emits no hooks, so the file's mtime IS the moment it blocked. Under a
  minute the suffix stays off; the common quick approval should not flicker a
  counter. The tool the wait is blocked on splits by surface: `waitSuffix`
  is the tray's version and carries any tool uncut, because a menu row has no
  width budget; `bubbleStatus` admits the tool only while the whole status
  fits the 34-advance budget WITH the age's widest slot (`· 59m`) reserved —
  reserved whether or not an age is showing yet, so the tool cannot appear
  during the first minute and vanish when the counter arrives. "Bash" fits
  behind every shipped wording; "AskUserQuestion" and the `mcp__` names do
  not, and fall back to the bare status rather than truncating it. `bubbleText` takes the wording table as a parameter for the same reason
  `sessionTitle` does, and `BubbleView` has no `mood`: it is handed the status
  string, because deriving it a second time in the view would leave the rule
  under test and the rule on screen as two pieces of code that merely agree.
  The guarantee binds the live SESSIONS and stops there: the fold also takes
  the global `state` file, which has no row behind it and which `cmd_down`
  never clears, so a session ending on `waiting` can hold the face for up to
  that file's 300s leash while the caption reports the top live row. A harness
  that recomputes the face from `liveSessions` alone shares the blind spot and
  will assert the gap away — take the fold's own inputs, or assert against a
  literal. That fold is `foldMoods`, a free function: it was inside
  `Controller.pollMoods`, where `Controller.init`'s three NSWindows put the one
  rule deciding what the user sees out of reach of every harness. It takes the
  state file's mood and stamp as an EXPLICIT parameter for precisely the reason
  above, so a caller cannot accidentally derive it from the rows; `pollMoods` is
  now the IO around it, and the assertions live in `tools/session-harness.swift`
  beside a literal for the gap itself.
- **A refcount is owned.** `sessions/<sid>` is paired with `owners/<sid>`, the
  pid of the outermost process the session hangs off — Claude desktop, or the
  terminal that ran `claude`. A dead owner retires the session on the next
  poll, which is what makes a force-quit (where no `SessionEnd` ever fires)
  survivable. A missing owner file means unknown, never dead: it falls back to
  the one-hour staleness window.

  **Only `cmd_up` ever writes an owner file, and absence is a normal state with
  two different causes.** `cmd_up` writes the pair at `SessionStart` and
  deliberately writes NO owner when the process tree is unclimbable or resolves
  to itself — there, absence means "cannot be known". `state.sh` is the other
  writer of session files, on every prompt and every tool batch, and it never
  touches `owners/` by design: resolving an owner costs a whole-process-table
  `ps`, and that file is the hot path. So `pet.sh stop`, which wipes both
  directories, leaves a session whose very next hook restores the refcount
  alone — there, absence means "was known, then erased", and that session runs
  ownerless until it ends. Reproduced deterministically; the only cost is that
  a force-quit after a manual `stop` is retired by the one-hour window instead
  of immediately, and it self-heals.

  Do not "fix" that by having `state.sh` fill in the missing owner. The two
  causes of absence are indistinguishable on disk, so the unclimbable case
  would re-run `ps` on every hook forever and could write the very pid
  `cmd_up`'s `!= "$$"` guard exists to reject. Closing it properly means
  inventing a third state, which buys back a self-healing hour.

  **Removal is symmetric only when `SessionEnd` fires, and the owner machinery
  exists precisely because it sometimes does not.** `cmd_down` removes both
  halves whatever the owner situation was; a force-quit runs it never, and the
  owner-prune loop then removed `owners/<sid>` while `sessions/<sid>` stayed
  forever. Nothing in the renderer deletes one either — `liveSessions` and
  `pollSessions` compute the staleness predicate and use it only to HIDE. A
  session file four days old was found on a live install.

  `cmd_up` therefore retires session files past the renderer's own hour before
  the owner loop runs, which is what makes that loop's job right rather than
  inverted: the session goes first and its owner follows, so the pair stays
  matched without the loop knowing the cutoff. The window is not a choice —
  `liveSessions` requires the stamp to be inside the cutoff regardless of
  whether the owner is alive, so a session too stale to draw is too stale to
  keep, and one that is genuinely alive re-announces itself on its next hook.
  Pinned in `tools/run-prune-checks.sh`, including the half that matters more:
  a FRESH session must survive `cmd_up` untouched.
- **The 30s empty grace is for gaps, not for deaths.** It exists to ride out
  the pause between one session ending and the next starting — a resume, a
  `/clear`, a new window. Both ways of losing every session skip it: refcounts
  orphaned by an owner that died, and an empty directory whose last known
  owners are all gone. The ordinary quit takes the second path, not the first
  — `SessionEnd` really does fire on ⌘Q and removes the refcounts properly, so
  a pet that only handles orphans still sits there for the full 30 seconds
  after the app is gone.
- **Termination liveness is owner-first, mtime second.** `sessionLiveness`
  counts a session live while its owner provably runs, however stale its
  file: hooks stop arriving the moment the user walks into a meeting, only
  SessionStart brings a quit pet back, and deciding from mtime alone
  self-terminated the overlay beside a live session an hour in. The staleness
  window decides only for sessions with no owner file — absence still means
  "unknown, not dead" — and hiding (`liveSessions`) and pruning (`cmd_up`)
  keep their own hour for their own jobs; widening those was considered and
  rejected, because a session nobody can see should still stop being drawn
  and stop being stored. It is a free function for the reason `foldMoods`
  is: `Controller.init` opens windows, so a method is out of every harness's
  reach.
