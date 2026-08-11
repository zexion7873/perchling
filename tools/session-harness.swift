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

func row(_ sid: String, _ mood: Mood, cwd: String? = nil, say: String? = nil) -> SessionRow {
    SessionRow(sid: sid, cwd: cwd, mood: mood, say: say)
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
    let rows = liveSessions(dir, now: Date(), alive: { _ in true })
        .sorted { $0.sid < $1.sid }
    check("liveSessions reads both files", rows.count, 2)
    check("liveSessions reads line 2", rows[0].cwd, "/Users/x/Project/perchling")
    check("liveSessions reads line 3", rows[0].say, "hello")
    check("the one-line form stays valid", rows[1].cwd, nil)
    check("a dead owner drops the row",
          liveSessions(dir, now: Date(), alive: { _ in false }).count, 0)
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

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
