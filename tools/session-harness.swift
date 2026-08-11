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

check("a title joins the name to the status",
      sessionTitle(row("s1", .running, cwd: "/p/alpha"), words),
      "alpha — running")

// MARK: - bubbleText

do {
    let one = [row("s1", .running, cwd: "/p/alpha", say: "hi")]
    let two = [row("s1", .running, cwd: "/p/alpha", say: "hi"),
               row("s2", .idle, cwd: "/p/beta")]
    check("one session needs no name", bubbleText(one, .running, "", words).name, nil)
    check("two sessions name the top one", bubbleText(two, .running, "", words).name, "alpha")
    check("the caption is the top session's own line",
          bubbleText(two, .running, "global", words).prompt, "hi")
    check("no rows falls back to the global say",
          bubbleText([], .done, "global", words).prompt, "global")
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

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
