// Assertions for the session layer, appended to pet.swift's body by
// tools/run-session-harness.sh. Not part of the shipped binary: the overlay has
// no reason to carry fixtures, and there is no test framework here to put them
// in.
//
// Everything here is a free function over injected inputs, which is the only
// reason this is possible — the fold, the tray rows and the bubble take their
// wording table and their liveness probe as parameters precisely so a harness
// needs no process table, no pet window, and no machine set to English.

var failures = 0

func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
    if got == want {
        print("ok   \(label)")
    } else {
        failures += 1
        print("FAIL \(label)\n       got:  \(got)\n       want: \(want)")
    }
}

func tempDir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("perchling-harness-\(name)")
    try? FileManager.default.removeItem(at: d)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func writeFile(_ dir: URL, _ name: String, _ body: String) {
    try! body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

// A wording table of its own, never the global moodStatus: that one is chosen
// from Locale.preferredLanguages, so an assertion against it passes or fails by
// machine rather than by behaviour.
let words: [Mood: String] = [.idle: "idle", .running: "running",
                             .waiting: "waiting", .done: "done", .error: "error"]

func row(_ sid: String, _ mood: Mood, cwd: String? = nil,
         say: String? = nil, name: String? = nil) -> SessionRow {
    SessionRow(sid: sid, cwd: cwd, mood: mood, say: say, name: name)
}

// MARK: - sessionName

check("name falls back to the cwd basename",
      sessionName(row("abcdef0123456789", .idle, cwd: "/Users/x/Project/perchling")),
      "perchling")
check("name falls back to the sid prefix when no cwd arrived",
      sessionName(row("abcdef0123456789", .idle)),
      "abcdef01")

// MARK: - liveSessions

do {
    let dir = tempDir("live")
    writeFile(dir, "s1", "running\n/Users/x/Project/perchling\nhello")
    writeFile(dir, "s2", "idle")
    let rows = liveSessions(dir, now: Date(), alive: { _ in true }, names: ["s1": "named"])
        .sorted { $0.sid < $1.sid }
    check("liveSessions reads both files", rows.count, 2)
    check("liveSessions reads line 2", rows[0].cwd, "/Users/x/Project/perchling")
    check("liveSessions reads line 3", rows[0].say, "hello")
    check("the one-line form stays valid", rows[1].cwd, nil)
    check("a registry name reaches the row", rows[0].name, "named")
    check("a session absent from the registry has no name", rows[1].name, nil)
    check("a dead owner drops the row",
          liveSessions(dir, now: Date(), alive: { _ in false }, names: [:]).count, 0)
}

// MARK: - menuRows

do {
    let rows = menuRows([row("s1", .idle, cwd: "/p/alpha"),
                         row("manual", .running),
                         row("s2", .waiting, cwd: "/p/beta")])
    check("manual is not a session", rows.map(\.sid), ["s2", "s1"])
}

// MARK: - sessionTitle

check("a title joins the label to the status",
      sessionTitle("alpha", .running, words), "alpha — running")
check("a title with no wording is the bare label",
      sessionTitle("alpha", .running, [:]), "alpha")
check("a suffixed label reaches the tray intact",
      sessionTitle("perchling · s1", .waiting, words), "perchling · s1 — waiting")

// MARK: - bubbleText

do {
    let one = [row("s1", .running, cwd: "/p/alpha", say: "hi")]
    let two = menuRows([row("s1", .running, cwd: "/p/alpha", say: "hi"),
                        row("s2", .idle, cwd: "/p/alpha")])
    check("one session needs no name",
          bubbleText(one, .running, "", words, sessionLabels(one)).name, nil)
    check("two sessions name the top one with its resolved label",
          bubbleText(two, .running, "", words, sessionLabels(two)).name, "alpha · s1")
    check("the caption is the top session's own line",
          bubbleText(two, .running, "global", words, sessionLabels(two)).prompt, "hi")
    check("no rows falls back to the global say",
          bubbleText([], .done, "global", words, [:]).prompt, "global")
}

// MARK: - registryNames

func regFile(_ dir: URL, _ pid: Int, _ sid: String, _ name: String?, extra: String = "") {
    let nameKey = name.map { ",\"name\":\"\($0)\"" } ?? ""
    writeFile(dir, "\(pid).json",
              "{\"pid\":\(pid),\"sessionId\":\"\(sid)\",\"cwd\":\"/p/x\"\(nameKey)\(extra)}")
}

do {
    let dir = tempDir("registry")
    regFile(dir, 101, "s1", "my session")
    regFile(dir, 102, "s2", nil)                       // every non-interactive kind
    regFile(dir, 103, "s3", "")                        // empty is absent
    regFile(dir, 104, "s4", "line\\nbreak")            // control character
    regFile(dir, 105, "s5", String(repeating: "x", count: 200))
    writeFile(dir, "106.json", "{not json")
    writeFile(dir, "107.json", "{\"pid\":107,\"name\":\"orphan\"}")   // no sessionId
    writeFile(dir, "notes.txt", "ignored")

    let m = registryNames(dir, alive: { _ in true })
    check("a named session is read", m["s1"], "my session")
    check("a nameless session has no entry", m["s2"], nil)
    check("an empty name is absent", m["s3"], nil)
    check("control characters are stripped", m["s4"], "linebreak")
    check("a long name is capped", m["s5"]?.count, 64)
    // s1, s4 and s5 survive; s2, s3, the unparseable file, the one with no
    // sessionId and the .txt do not.
    check("bad JSON is skipped, not fatal", m.count, 3)
    check("a dead pid drops its entry",
          registryNames(dir, alive: { _ in false }).count, 0)
}

do {
    let dir = tempDir("registry-dup")
    regFile(dir, 201, "same", "older")
    Thread.sleep(forTimeInterval: 0.02)
    regFile(dir, 202, "same", "newer")
    check("two files for one session: the newer wins",
          registryNames(dir, alive: { _ in true })["same"], "newer")
}

do {
    let dir = tempDir("registry-nopid")
    writeFile(dir, "301.json", "{\"sessionId\":\"s9\",\"name\":\"unknown pid\"}")
    check("a missing pid is unknown, never dead",
          registryNames(dir, alive: { _ in false })["s9"], "unknown pid")
    // pid_t is Int32 on Darwin; a JSON integer wider than that must not trap
    // pid_t's failable-less initializer — it has to fall into the same
    // "unknown" bucket a missing pid does.
    regFile(dir, 99999999999999, "s10", "huge pid")
    check("an out-of-range pid is unknown, never dead",
          registryNames(dir, alive: { _ in false })["s10"], "huge pid")
}

check("a missing registry is an empty map, not a crash",
      registryNames(URL(fileURLWithPath: "/nonexistent/perchling-harness"),
                    alive: { _ in true }).count, 0)

// MARK: - the three-layer chain

check("a registry name wins over the project directory",
      sessionName(row("abcdef0123456789", .idle, cwd: "/Users/x/Project/perchling",
                      name: "the refactor")),
      "the refactor")
check("an empty registry name is not a name",
      sessionName(row("abcdef0123456789", .idle, cwd: "/Users/x/Project/perchling", name: "")),
      "perchling")
check("no name falls through to the project directory",
      sessionName(row("abcdef0123456789", .idle, cwd: "/Users/x/Project/perchling")),
      "perchling")
check("neither falls through to the sid prefix",
      sessionName(row("abcdef0123456789", .idle)),
      "abcdef01")

// MARK: - sessionLabels

do {
    let rows = menuRows([row("s1", .running, cwd: "/p/perchling"),
                         row("s2", .idle, cwd: "/p/perchling"),
                         row("s3", .idle, cwd: "/p/alpha")])
    let labels = sessionLabels(rows)
    check("a collision suffixes the first row", labels["s1"], "perchling · s1")
    check("a collision suffixes the second row", labels["s2"], "perchling · s2")
    check("a name that does not collide is untouched", labels["s3"], "alpha")
}

do {
    let labels = sessionLabels(menuRows([row("s1", .idle, cwd: "/p/perchling")]))
    check("a lone session wears no suffix", labels["s1"], "perchling")
}

do {
    // sessionLabels must be fed the MENU rows, never the raw liveSessions
    // output: `manual` is a bridge row that is never drawn, and letting it
    // into the collision count could suffix a real row for colliding with a
    // row nobody on screen ever sees. Unfiltered, "manual" and "s1" tie on
    // "perchling" and s1 would wear "perchling · s1"; menuRows drops manual
    // before sessionLabels ever counts it.
    let raw = [row("manual", .running, cwd: "/p/perchling"),
               row("s1", .running, cwd: "/p/perchling")]
    let labels = sessionLabels(menuRows(raw))
    check("manual cannot push a real row into a collision suffix", labels["s1"], "perchling")
}

do {
    // Two rows can only reach the sid layer with different ids, so this only
    // fires when two ids share their first eight characters — and the label must
    // not double into "abcdef01 · abcdef01".
    let labels = sessionLabels([row("abcdef0111", .idle), row("abcdef0122", .idle)])
    check("a sid-prefix label is never doubled", labels["abcdef0111"], "abcdef01")
}

do {
    // The suffix is a middle dot, never an em dash: sessionTitle joins the label
    // to the status with one, and a second makes the row stutter.
    let labels = sessionLabels(menuRows([row("s1", .idle, cwd: "/p/x"),
                                         row("s2", .idle, cwd: "/p/x")]))
    check("the separator is not an em dash", labels["s1"]!.contains("—"), false)
}

// MARK: - desktopTitles

func titleFile(_ dir: URL, _ leaf: String, _ cliSid: String?, _ title: String?,
               bulkKB: Int = 0) {
    let sidKey = cliSid.map { "\"cliSessionId\":\"\($0)\"," } ?? ""
    let titleKey = title.map { ",\"title\":\"\($0)\"" } ?? ""
    let bulk = bulkKB > 0
        ? ",\"remoteMcpServersConfig\":\"\(String(repeating: "x", count: bulkKB * 1024))\""
        : ""
    writeFile(dir, leaf,
              "{\"sessionId\":\"local_x\",\(sidKey)\"cwd\":\"/p/x\"\(titleKey)\(bulk)}")
}

do {
    // The records sit two account-scoped directories down; the level must be
    // globbed, never hardcoded.
    let root = tempDir("titles")
    let nested = root.appendingPathComponent("acct").appendingPathComponent("org")
    try! FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    titleFile(nested, "local_1.json", "s1", "my session")
    titleFile(nested, "local_2.json", "s2", nil)              // no title
    titleFile(nested, "local_3.json", "s3", "")               // empty title
    titleFile(nested, "local_4.json", nil, "orphan")          // no join key
    titleFile(nested, "local_5.json", "s5", "line\\nbreak")   // control character
    writeFile(nested, "local_6.json", "{not json")
    writeFile(nested, "deleted_7", "{\"cliSessionId\":\"s7\",\"title\":\"tombstone\"}")
    writeFile(nested, "notes.txt", "ignored")

    var cache: [String: TitleEntry] = [:]
    let m = desktopTitles(root, cache: &cache)
    check("a titled session is read", m["s1"], "my session")
    check("a record with no title has no entry", m["s2"], nil)
    check("an empty title is absent", m["s3"], nil)
    check("a record with no cliSessionId is skipped", m.values.contains("orphan"), false)
    check("control characters are stripped from a title", m["s5"], "linebreak")
    check("a deleted_ tombstone is not a record", m["s7"], nil)
    // Of the six local_*.json fixtures, only s1 and s5 clear both bars (a
    // parseable cliSessionId and a non-empty cleaned title) — s2 has no title
    // key, s3's title cleans to empty, s4 has no join key, s6 isn't valid
    // JSON. The five checks above already pin every other key to absent, so
    // 2 is the only count consistent with them.
    check("only local_*.json records are read", m.count, 2)

    // The cache exists because a real record is ~279KB. Same mtime must not
    // re-parse, and a changed file must not be served stale.
    check("the cache holds one entry per parsed record", cache.count, 2)
    let again = desktopTitles(root, cache: &cache)
    check("a second call is stable", again["s1"], "my session")

    titleFile(nested, "local_1.json", "s1", "renamed")
    check("a rewritten record is re-read", desktopTitles(root, cache: &cache)["s1"], "renamed")

    // local_2.json was never cached (it has no title), so deleting it could
    // never move cache.count regardless of whether pruning works — that
    // assertion couldn't fail. local_1.json IS cached at this point (the
    // rename above put it there under "renamed"), so deleting it is the one
    // fixture that actually exercises the prune path.
    try! FileManager.default.removeItem(at: nested.appendingPathComponent("local_1.json"))
    let afterPrune = desktopTitles(root, cache: &cache)
    check("the cache is pruned when a record goes away", cache.count, 1)
    // The count could look right while a stale entry still answers queries —
    // that's the failure the prune exists to prevent, so assert the map
    // directly, not just its size.
    check("a pruned record no longer answers", afterPrune["s1"], nil)
}

var missingCache: [String: TitleEntry] = [:]
check("a missing titles directory is an empty map",
      desktopTitles(URL(fileURLWithPath: "/nonexistent/perchling-titles"),
                    cache: &missingCache).count, 0)

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
