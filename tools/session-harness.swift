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
         say: String? = nil, name: String? = nil, title: String? = nil,
         stamp: Date = Date(), tool: String? = nil) -> SessionRow {
    SessionRow(sid: sid, cwd: cwd, mood: mood, say: say, name: name, title: title,
               stamp: stamp, tool: tool)
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
    writeFile(dir, "s3", "waiting\n/p/x\n\nBash")
    let rows = liveSessions(dir, now: Date(), alive: { _ in true }, names: ["s1": "named"],
                            titles: ["s1": "titled"])
        .sorted { $0.sid < $1.sid }
    check("liveSessions reads every file", rows.count, 3)
    check("liveSessions reads line 2", rows[0].cwd, "/Users/x/Project/perchling")
    check("liveSessions reads line 3", rows[0].say, "hello")
    check("the one-line form stays valid", rows[1].cwd, nil)
    check("a registry name reaches the row", rows[0].name, "named")
    check("a session absent from the registry has no name", rows[1].name, nil)
    check("a desktop title reaches the row", rows[0].title, "titled")
    check("a session with no desktop record has no title", rows[1].title, nil)
    check("liveSessions reads line 4", rows[2].tool, "Bash")
    check("an empty caption above a tool still maps to nil", rows[2].say, nil)
    check("the three-line form has no tool", rows[0].tool, nil)
    check("a dead owner drops the row",
          liveSessions(dir, now: Date(), alive: { _ in false }, names: [:], titles: [:]).count, 0)
    // The stamp IS the file's mtime, pinned by setting one and reading it back
    // through the row — the age suffix upstream is only as honest as this.
    let blocked = Date(timeIntervalSinceReferenceDate:
                       (Date().timeIntervalSinceReferenceDate - 720).rounded())
    try! FileManager.default.setAttributes([.modificationDate: blocked],
                                           ofItemAtPath: dir.appendingPathComponent("s1").path)
    let stamped = liveSessions(dir, now: Date(), alive: { _ in true }, names: [:], titles: [:])
        .first { $0.sid == "s1" }
    check("the row carries the file's own mtime", stamped?.stamp, blocked)
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
    let t0 = Date()
    check("one session needs no name",
          bubbleText(one, .running, "", words, sessionLabels(one), now: t0).name, nil)
    check("two sessions name the top one with its resolved label",
          bubbleText(two, .running, "", words, sessionLabels(two), now: t0).name, "alpha · s1")
    check("the caption is the top session's own line",
          bubbleText(two, .running, "global", words, sessionLabels(two), now: t0).prompt, "hi")
    check("no rows falls back to the global say",
          bubbleText([], .done, "global", words, [:], now: t0).prompt, "global")
}

// MARK: - waitAge

do {
    let t0 = Date()
    let blocked = t0.addingTimeInterval(-720)
    check("a waiting session's age is whole minutes",
          waitAge(.waiting, stamp: blocked, now: t0), "12m")
    check("under a minute there is no age",
          waitAge(.waiting, stamp: t0.addingTimeInterval(-59), now: t0), nil)
    check("exactly a minute is the first age shown",
          waitAge(.waiting, stamp: t0.addingTimeInterval(-60), now: t0), "1m")
    check("only waiting has an age, however stale the row",
          waitAge(.running, stamp: blocked, now: t0), nil)
    check("a title carries the detail behind a middle dot",
          sessionTitle("alpha", .waiting, words, detail: "12m"), "alpha — waiting · 12m")
    check("a title with no detail is unchanged",
          sessionTitle("alpha", .waiting, words), "alpha — waiting")
    let stale = [row("s1", .waiting, say: "hi", stamp: blocked)]
    check("the bubble status of an ignored wait carries the age",
          bubbleText(stale, .waiting, "", words, sessionLabels(stale), now: t0).status,
          "waiting · 12m")
    let fresh = [row("s1", .waiting, say: "hi", stamp: t0)]
    check("a fresh wait shows the bare status",
          bubbleText(fresh, .waiting, "", words, sessionLabels(fresh), now: t0).status,
          "waiting")
    check("a puppeteered waiting with no row behind it has no age",
          bubbleText([], .waiting, "", words, [:], now: t0).status, "waiting")
}

// MARK: - waitSuffix and the bubble's status budget

do {
    let t0 = Date()
    let blocked = t0.addingTimeInterval(-720)
    check("the tray suffix is tool then age",
          waitSuffix(row("s", .waiting, stamp: blocked, tool: "Bash"), now: t0), "Bash · 12m")
    check("a fresh wait's suffix is the tool alone",
          waitSuffix(row("s", .waiting, stamp: t0, tool: "Bash"), now: t0), "Bash")
    check("an mcp tool rides the tray uncut",
          waitSuffix(row("s", .waiting, stamp: blocked, tool: "mcp__github__get_me"), now: t0),
          "mcp__github__get_me · 12m")
    check("no tool and no age is no suffix",
          waitSuffix(row("s", .waiting, stamp: t0), now: t0), nil)
    check("a session that is not waiting has none",
          waitSuffix(row("s", .running, stamp: blocked, tool: "Bash"), now: t0), nil)

    check("advances count ASCII as one and CJK as two", advances("ab你好"), 6)
    // The real longest base: "waiting for you…" — 15 ASCII glyphs and the
    // two-advance ellipsis. Bash fits behind it with the widest age reserved;
    // AskUserQuestion busts the budget and falls back to the bare status.
    let base = "waiting for you…"
    check("a short tool rides the bubble status",
          bubbleStatus(base, row("s", .waiting, stamp: blocked, tool: "Bash"), now: t0),
          "waiting for you… · Bash · 12m")
    check("a tool that busts the budget stays off the bubble",
          bubbleStatus(base, row("s", .waiting, stamp: blocked, tool: "AskUserQuestion"), now: t0),
          "waiting for you… · 12m")
    // The reserve is the widest age, not the current one: the tool must not
    // appear during the first minute and vanish when the counter arrives.
    check("the budget reserves the age slot before one shows",
          bubbleStatus(base, row("s", .waiting, stamp: t0, tool: "WebSearches"), now: t0),
          base)
    check("a non-waiting status is untouched",
          bubbleStatus("running", row("s", .running, stamp: blocked, tool: "Bash"), now: t0),
          "running")
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
    // Directory enumeration is a name-hash order on this filesystem, not
    // creation order: probed by writing 201.json 202.json acct1 acct2
    // zzz.json aaa.json and getting back zzz.json acct1 201.json aaa.json
    // 202.json acct2. One arrangement of which pid gets the later mtime can
    // therefore pass by coincidence of enumeration order alone, with no
    // tie-break in play — so both permutations run, and one of them
    // necessarily lands the older file last whatever order this filesystem
    // hands back.
    let d1 = tempDir("registry-dup-a")
    regFile(d1, 201, "same", "older"); Thread.sleep(forTimeInterval: 0.02); regFile(d1, 202, "same", "newer")
    check("dup A: the newer wins", registryNames(d1, alive: { _ in true })["same"], "newer")
    let d2 = tempDir("registry-dup-b")
    regFile(d2, 202, "same", "older"); Thread.sleep(forTimeInterval: 0.02); regFile(d2, 201, "same", "newer")
    check("dup B: the newer wins", registryNames(d2, alive: { _ in true })["same"], "newer")
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
    // Documents the real directory shape but proves nothing on its own: no
    // .json extension, so pathExtension == "json" already excludes it before
    // hasPrefix("local_") is ever asked — removing that prefix filter leaves
    // this fixture, and the harness, green.
    writeFile(nested, "deleted_7", "{\"cliSessionId\":\"s7\",\"title\":\"tombstone\"}")
    // The fixture that actually exercises hasPrefix("local_"): a sibling
    // .json that isn't a session record. scheduled-tasks.json really sits in
    // this directory (87 bytes) — pathExtension alone would let it through.
    writeFile(nested, "scheduled-tasks.json", "{\"cliSessionId\":\"s9\",\"title\":\"not a session\"}")
    writeFile(nested, "notes.txt", "ignored")

    // A second account directory, with its own org level and its own record.
    // With only one directory at each level under `nested`, an implementation
    // that took kids(dir).first / kids(acct).first instead of looping every
    // entry would still satisfy every assertion above — this is the one
    // fixture that actually exercises "globbed, never hardcoded".
    let nested2 = root.appendingPathComponent("acct2").appendingPathComponent("org2")
    try! FileManager.default.createDirectory(at: nested2, withIntermediateDirectories: true)
    titleFile(nested2, "local_8.json", "s8", "second acct")

    var cache = TitleCache()
    let m = desktopTitles(root, cache: &cache)
    check("a titled session is read", m["s1"], "my session")
    check("a record with no title has no entry", m["s2"], nil)
    check("an empty title is absent", m["s3"], nil)
    check("a record with no cliSessionId is skipped", m.values.contains("orphan"), false)
    check("control characters are stripped from a title", m["s5"], "linebreak")
    check("a deleted_ tombstone is not a record", m["s7"], nil)
    check("a sibling .json that is not a record is skipped", m["s9"], nil)
    check("a second account directory is found, not just the first", m["s8"], "second acct")
    // Of the seven local_*.json fixtures (six under acct/org, one under
    // acct2/org2), only s1, s5 and s8 clear both bars (a parseable
    // cliSessionId and a non-empty cleaned title) — s2 has no title key, s3's
    // title cleans to empty, s4 has no join key, s6 isn't valid JSON. The
    // checks above already pin every other key to absent, so 3 is the only
    // count consistent with them.
    check("only local_*.json records are read", m.count, 3)

    // The cache exists because a real record is ~279KB. Same mtime must not
    // re-parse, and a changed file must not be served stale — and a record
    // with no usable title must not either: the desktop app writes a
    // session's record before it has a title, so a title-less record is the
    // normal state of every new session for a while, not a rare failure.
    // Every examined local_*.json file gets exactly one cache entry whether
    // it yielded a title or not: 7 files in, 7 entries out (3 hits, 4
    // misses) — a count of 3 here would mean misses are silently dropped
    // and re-parsed on every poll forever, the exact bug this cache exists
    // to prevent.
    check("the cache holds one entry per examined record, hit or miss", cache.files.count, 7)
    let again = desktopTitles(root, cache: &cache)
    check("a second call is stable", again["s1"], "my session")

    // The listing cache is a pure performance change: no assertion over the
    // RESULT can tell whether it is working, which is why `titleDirScans`
    // exists. Two calls with nothing touched must enumerate the records'
    // directory once, not twice. Proven able to fail by deleting the memo in
    // `records()`, which takes this from 2 to 4.
    //
    // 5 scans on the first call: `root`, its two account directories, and both
    // org directories. The second call re-walks only the three levels above the
    // records, because both org listings are memoised — hence 3, not 5.
    titleDirScans = 0
    _ = desktopTitles(root, cache: &cache)
    let firstScans = titleDirScans
    _ = desktopTitles(root, cache: &cache)
    check("an unchanged records directory is not re-enumerated",
          titleDirScans - firstScans, 3)

    titleFile(nested, "local_1.json", "s1", "renamed")
    // A rewrite leaves the directory's mtime alone — measured on APFS, and true
    // of `write(to:atomically:)` as well — so this is exactly the assertion a
    // listing cache that also memoised CONTENTS would fail.
    check("a rewritten record is re-read", desktopTitles(root, cache: &cache)["s1"], "renamed")

    // local_1.json IS cached at this point (the rename above put it there
    // under "renamed"), so deleting it is the fixture that exercises the
    // prune path — unlike local_2.json, which was never cached before the
    // negative-caching fix and would have let a broken prune pass by
    // coincidence.
    try! FileManager.default.removeItem(at: nested.appendingPathComponent("local_1.json"))
    let afterPrune = desktopTitles(root, cache: &cache)
    check("the cache is pruned when a record goes away", cache.files.count, 6)
    // The count could look right while a stale entry still answers queries —
    // that's the failure the prune exists to prevent, so assert the map
    // directly, not just its size.
    check("a pruned record no longer answers", afterPrune["s1"], nil)
}

do {
    // A directory that cannot be READ is not a directory with no records, and
    // the listing cache must not conflate them. It used to: `[]` was stored
    // against the current mtime, and because rewriting a file does not move a
    // directory's mtime, that entry answered "no records" until one was created
    // or deleted — so a single unreadable poll dropped every desktop title for
    // the rest of the process's life.
    //
    // Proven able to fail: against the version that cached the failure, the
    // recovery check below comes back nil.
    let root = tempDir("titles-unreadable")
    let org = root.appendingPathComponent("acct").appendingPathComponent("org")
    try! FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
    titleFile(org, "local_1.json", "s1", "my session")

    try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: org.path)
    var cache = TitleCache()
    let blind = desktopTitles(root, cache: &cache)["s1"]
    // Running as root ignores the mode bits, which would leave the rest of this
    // block asserting nothing. Say so rather than reporting a colour.
    if blind != nil {
        print("SKIP unreadable-directory checks — mode bits did not bite (root?)")
    } else {
        check("an unreadable records directory yields no title", blind, nil)
        check("...and is not cached as an empty listing", cache.dirs.isEmpty, true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: org.path)
        check("...so the next poll recovers once it is readable again",
              desktopTitles(root, cache: &cache)["s1"], "my session")
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: org.path)
}

do {
    // Two records under different account directories claiming the same
    // cliSessionId — the desktop analogue of registry-dup above. Which of
    // acct1/acct2 contentsOfDirectory enumerates first is a name-hash order
    // on this filesystem, not creation order (probed under registry-dup
    // above), so a single arrangement of which account holds the older
    // record can pass by coincidence of that order alone. Both permutations
    // run, the same fix as registry-dup, so one of them necessarily
    // enumerates the older record last whatever order this filesystem hands
    // back. The sleep clears the mtime resolution hazard: two files written
    // in the same instant can carry the same stamp.
    let d1 = tempDir("titles-dup-a")
    let a1 = d1.appendingPathComponent("acct1").appendingPathComponent("org")
    let b1 = d1.appendingPathComponent("acct2").appendingPathComponent("org")
    try! FileManager.default.createDirectory(at: a1, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: b1, withIntermediateDirectories: true)
    titleFile(a1, "local_older.json", "dup", "older")
    Thread.sleep(forTimeInterval: 0.02)
    titleFile(b1, "local_newer.json", "dup", "newer")
    var cacheA = TitleCache()
    check("titles dup A: the newer wins", desktopTitles(d1, cache: &cacheA)["dup"], "newer")

    let d2 = tempDir("titles-dup-b")
    let a2 = d2.appendingPathComponent("acct1").appendingPathComponent("org")
    let b2 = d2.appendingPathComponent("acct2").appendingPathComponent("org")
    try! FileManager.default.createDirectory(at: a2, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: b2, withIntermediateDirectories: true)
    titleFile(b2, "local_older.json", "dup", "older")
    Thread.sleep(forTimeInterval: 0.02)
    titleFile(a2, "local_newer.json", "dup", "newer")
    var cacheB = TitleCache()
    check("titles dup B: the newer wins", desktopTitles(d2, cache: &cacheB)["dup"], "newer")
}

var missingCache = TitleCache()
check("a missing titles directory is an empty map",
      desktopTitles(URL(fileURLWithPath: "/nonexistent/perchling-titles"),
                    cache: &missingCache).count, 0)

// MARK: - the four-layer chain

check("a desktop title outranks a registry name",
      sessionName(row("abcdef0123456789", .idle, cwd: "/p/perchling",
                      name: "perchling-de", title: "the refactor")),
      "the refactor")
check("an empty title falls through to the registry name",
      sessionName(row("abcdef0123456789", .idle, cwd: "/p/perchling",
                      name: "perchling-de", title: "")),
      "perchling-de")
check("no title falls through to the registry name",
      sessionName(row("abcdef0123456789", .idle, cwd: "/p/perchling",
                      name: "perchling-de")),
      "perchling-de")

// MARK: - a caption cut mid-codepoint

// state.sh truncates the caption to 300 BYTES, so a CJK prompt straddles the
// cut roughly two times in three. A strict decoder answers nil for the WHOLE
// file on one dangling continuation byte, and `Mood.parse("")` is `.idle` — so
// the pet would report an actively working session as idle, with no label and
// no caption, and keep doing it: state.sh reads line 3 back and republishes
// the same bad bytes on every tool batch. The bytes are written as Data
// because the fixture is by definition not expressible as a Swift String,
// which is also why writeFile cannot build it.
do {
    let dir = tempDir("truncated-utf8")
    var bytes = Array("running\n/Users/x/Project/perchling\nhello ".utf8)
    bytes.append(contentsOf: [0xE4, 0xB8])   // lead byte + one of two continuations
    try! Data(bytes).write(to: dir.appendingPathComponent("s1"))
    writeFile(dir, "s2", "waiting\n/Users/x/Project/perchling\nfine")
    let rows = liveSessions(dir, now: Date(), alive: { _ in true }, names: [:], titles: [:])
    let s1 = rows.first { $0.sid == "s1" }
    check("a caption cut mid-codepoint keeps its mood", s1?.mood, .running)
    check("a caption cut mid-codepoint keeps its cwd", s1?.cwd, "/Users/x/Project/perchling")
    check("a caption cut mid-codepoint still reaches the bubble",
          s1?.say?.hasPrefix("hello") ?? false, true)
    check("a clean session beside it is unaffected",
          rows.first { $0.sid == "s2" }?.mood, .waiting)
}

// MARK: - cleanCaption

check("an escaped newline becomes a space", cleanCaption(#"two\nlines"#), "two lines")
check("an escaped tab becomes a space", cleanCaption(#"a\tb"#), "a b")
check("an escaped quote becomes a quote", cleanCaption(#"he said \"go\""#), #"he said "go""#)
// The case a chain of replacements cannot get right in either order: the user
// typed a backslash and then an n, so the backslash survives and the n is an n.
check("an escaped backslash does not eat the character after it",
      cleanCaption(#"C:\\nope"#), #"C:\nope"#)
check("an escape this sed cannot decode is passed through whole",
      cleanCaption(#"\u4e2d"#), #"\u4e2d"#)
check("a bare backslash at the end survives", cleanCaption(#"trailing \"#), #"trailing \"#)

// The bug this existed to fix: the SESSION caption is what the bubble shows,
// and it was the one that never got cleaned.
do {
    let dir = tempDir("caption-escapes")
    writeFile(dir, "s1", #"running"# + "\n/Users/x/p\n" + #"fix the \"bug\"\nthen ship"#)
    let rows = liveSessions(dir, now: Date(), alive: { _ in true }, names: [:], titles: [:])
    check("a session caption reaches the bubble unescaped",
          rows.first?.say, #"fix the "bug" then ship"#)
}

// MARK: - the pet library, and the one path that can delete a user's only copy

// `clearPetLink` is two lines, and the whole safety property is their ORDER
// plus the `try` on the first: a rescue that cannot finish must throw, so the
// removal below it never runs. Swapping them, or weakening that `try` to
// `try?`, deletes a hand-drawn pet that has no other copy and passes every
// other check in this repo. Both mutations fail `a rescue that cannot finish
// refuses the removal` below, which is the only reason these lines are worth
// anything.
//
// Everything here is a pure function of a scratch directory, and this harness
// already compiles all of it — the cut is at the runtime-home block and the
// library sits well above it. It was simply never called.

// The smallest manifest the parser accepts: 8x8 is the minimum canvas, and one
// mood is enough. Named, because the name is what becomes the library slug.
// Delimited `##"…"##`, not `#"…"#`: a hex colour is `"#FFFFFF"`, and that `"#`
// closes the shorter form mid-manifest.
func petJSON(_ name: String) -> String {
    let flat = ##"["........","........","..oooo..","..oooo..","..oooo..","..oooo..","........","........"]"##
    return ##"{ "name": "\##(name)", "palette": { "o": "#FFFFFF" }, "moods": { "idle": \##(flat) } }"##
}

func isSymlink(_ url: URL) -> Bool {
    let a = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (a?[.type] as? FileAttributeType) == .typeSymbolicLink
}

do {
    let root = tempDir("library-migrate")
    let pet = root.appendingPathComponent("pet.json")
    writeFile(root, "pet.json", petJSON("Hand Drawn"))
    try! migrateLoosePet(root: root)
    check("a loose pet.json is rescued into pets/ under its own name",
          FileManager.default.fileExists(atPath:
              petsDir(root).appendingPathComponent("hand-drawn.json").path), true)
    check("and pet.json becomes a link to it", isSymlink(pet), true)
    check("the rescued file still holds the original manifest",
          (try? String(contentsOf: petsDir(root).appendingPathComponent("hand-drawn.json"),
                       encoding: .utf8))?.contains("Hand Drawn"), true)
}

do {
    // A second loose pet of the same name must not overwrite the first. This is
    // the same "their only copy" property one step along: the collision suffix
    // is what stops the rescue from destroying what an earlier rescue saved.
    let root = tempDir("library-collide")
    writeFile(root, "pet.json", petJSON("Twin"))
    try! migrateLoosePet(root: root)
    try? FileManager.default.removeItem(at: root.appendingPathComponent("pet.json"))
    writeFile(root, "pet.json", petJSON("Twin"))
    try! migrateLoosePet(root: root)
    check("a name already in the library gets a suffix rather than a clobber",
          FileManager.default.fileExists(atPath:
              petsDir(root).appendingPathComponent("twin-2.json").path), true)
}

do {
    // A pet.json that is already a link is not loose, and re-migrating one
    // would move the library entry it points at out from under itself.
    let root = tempDir("library-symlink")
    try! FileManager.default.createDirectory(at: petsDir(root), withIntermediateDirectories: true)
    writeFile(petsDir(root), "kept.json", petJSON("Kept"))
    try! FileManager.default.createSymbolicLink(
        atPath: root.appendingPathComponent("pet.json").path,
        withDestinationPath: "pets/kept.json")
    try! migrateLoosePet(root: root)
    check("an existing link is left alone",
          FileManager.default.fileExists(atPath:
              petsDir(root).appendingPathComponent("kept.json").path), true)
    check("and no second copy is invented",
          (try? FileManager.default.contentsOfDirectory(atPath: petsDir(root).path))?.count, 1)
}

do {
    // The whole point. `clearPetLink` runs from the Pets menu, arbitrarily long
    // after launch, and pet.json can be a loose regular file again by then.
    let root = tempDir("library-clear")
    writeFile(root, "pet.json", petJSON("Only Copy"))
    try! clearPetLink(root: root)
    check("clearing a loose pet.json saves it before removing it",
          (try? String(contentsOf: petsDir(root).appendingPathComponent("only-copy.json"),
                       encoding: .utf8))?.contains("Only Copy"), true)
    check("and pet.json itself is gone afterwards",
          FileManager.default.fileExists(atPath: root.appendingPathComponent("pet.json").path),
          false)
}

do {
    // A rescue that CANNOT finish must abandon the removal rather than delete
    // what it failed to save. An unwritable pets/ is the reachable version of
    // that: a directory the user's own umask or a restore left read-only.
    let root = tempDir("library-refuse")
    let pet = root.appendingPathComponent("pet.json")
    writeFile(root, "pet.json", petJSON("Precious"))
    try! FileManager.default.createDirectory(at: petsDir(root), withIntermediateDirectories: true)
    try! FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: petsDir(root).path)
    var threw = false
    do { try clearPetLink(root: root) } catch { threw = true }
    check("a rescue that cannot finish throws", threw, true)
    check("a rescue that cannot finish refuses the removal",
          (try? String(contentsOf: pet, encoding: .utf8))?.contains("Precious"), true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: petsDir(root).path)
}

do {
    // Adopting a shipped pet records its pick-time bytes in pets/.shipped/ —
    // the proof cmd_up's refresh needs before it may replace the copy with
    // newer shipped art. No record means no refresh ever: a pick that skips
    // the record re-ships the frozen-at-pick-time bug for that pet.
    let root = tempDir("library-adopt")
    let ship = tempDir("library-adopt-examples")
    writeFile(ship, "whale.json", petJSON("Whale"))
    let dest = try! adoptShippedPet(ship.appendingPathComponent("whale.json"), root: root)
    check("adopting copies the pet into pets/",
          (try? String(contentsOf: dest, encoding: .utf8))?.contains("Whale"), true)
    let snap = petsDir(root).appendingPathComponent(".shipped/whale.json")
    check("and records the pick-time bytes beside it",
          (try? String(contentsOf: snap, encoding: .utf8)) ==
              (try? String(contentsOf: dest, encoding: .utf8)), true)
    check("the record directory never becomes a menu row",
          petChoices(root: root, examples: ship).allSatisfy { !$0.name.hasPrefix(".") }, true)
}

do {
    // A pets/ file already wearing the name is the user's, and adopt leaves it
    // alone — so it must not manufacture provenance for bytes it did not
    // write: a record here would let the refresh later replace a file the
    // user made.
    let root = tempDir("library-adopt-taken")
    let ship = tempDir("library-adopt-taken-examples")
    writeFile(ship, "otter.json", petJSON("Shipped Otter"))
    try! FileManager.default.createDirectory(at: petsDir(root), withIntermediateDirectories: true)
    writeFile(petsDir(root), "otter.json", petJSON("My Otter"))
    _ = try! adoptShippedPet(ship.appendingPathComponent("otter.json"), root: root)
    check("an existing library file is not clobbered by adopt",
          (try? String(contentsOf: petsDir(root).appendingPathComponent("otter.json"),
                       encoding: .utf8))?.contains("My Otter"), true)
    check("and no provenance is invented for it",
          FileManager.default.fileExists(atPath:
              petsDir(root).appendingPathComponent(".shipped/otter.json").path), false)
}

// MARK: - liveSessions: the TTL decay and the one-hour cutoff
//
// Both were unreachable while every fixture was read milliseconds after being
// written: `now` and the file's mtime were the same instant, so each comparison
// had exactly one value and could not disagree with anything. `liveSessions`
// takes `now`, so pushing it FORWARD ages the fixture precisely — and sidesteps
// setting mtimes by hand, where sub-second landings answer differently per run.
func agedRows(_ dir: URL, _ age: TimeInterval) -> [SessionRow] {
    liveSessions(dir, now: Date().addingTimeInterval(age), alive: { _ in true },
                 names: [:], titles: [:])
}

do {
    let dir = tempDir("ttl-running")
    writeFile(dir, "s1", "running\n")
    check("running inside its 900s TTL keeps its mood", agedRows(dir, 800).first?.mood, Mood.running)
    check("running past its 900s TTL reads idle", agedRows(dir, 1000).first?.mood, Mood.idle)
}

do {
    let dir = tempDir("ttl-done")
    writeFile(dir, "s1", "done\n")
    check("done inside its 60s TTL keeps its mood", agedRows(dir, 30).first?.mood, Mood.done)
    check("done past its 60s TTL reads idle", agedRows(dir, 100).first?.mood, Mood.idle)
}

do {
    // waiting's TTL and the cutoff are both 3600, so the row is RETIRED before
    // its mood can decay: no age exists at which a waiting row reads idle. The
    // decay and the cutoff are not two chances to retire the same row.
    let dir = tempDir("ttl-waiting")
    writeFile(dir, "s1", "waiting\n")
    check("waiting just inside the cutoff still reads waiting", agedRows(dir, 3500).first?.mood, Mood.waiting)
    check("past the cutoff the row is gone, not decayed", agedRows(dir, 3700).count, 0)
}

// MARK: - foldMoods

let t0 = Date()

do {
    check("nothing at all is idle",
          foldMoods(state: nil, live: [], now: t0, last: [:]).display, Mood.idle)
    check("the highest rank wins",
          foldMoods(state: nil, live: [row("a", .running), row("b", .error)],
                    now: t0, last: [:]).display, Mood.error)
    check("waiting outranks error",
          foldMoods(state: nil, live: [row("a", .error), row("b", .waiting)],
                    now: t0, last: [:]).display, Mood.waiting)
}

do {
    // The state file's leash is min(that mood's TTL, 300), so it binds from
    // BOTH sides: waiting's own 3600 is clamped down to 300, and done's 60 is
    // left alone rather than raised to it.
    func face(_ m: Mood, _ age: TimeInterval) -> Mood {
        foldMoods(state: (m, t0.addingTimeInterval(-age)), live: [], now: t0, last: [:]).display
    }
    check("a fresh state file drives the face", face(.waiting, 10), Mood.waiting)
    check("the state file's leash is 300s, not waiting's own 3600", face(.waiting, 400), Mood.idle)
    check("a mood whose own TTL is shorter keeps the shorter one", face(.done, 100), Mood.idle)
    check("and is not retired early by the 300s leash", face(.done, 30), Mood.done)
}

do {
    // The blind spot docs/invariants/sessions.md warns about, asserted against a literal rather
    // than recomputed from the rows: the state file has no row behind it and
    // nothing clears it at SessionEnd, so it can hold the face while the rows —
    // and therefore the bubble's caption — report a different session entirely.
    let live = [row("s1", .running)]
    let f = foldMoods(state: (.waiting, t0), live: live, now: t0, last: [:])
    check("the state file outranks a live session it has no row for", f.display, Mood.waiting)
    check("while the top row is still that live session", menuRows(live).first?.sid, "s1")
}

do {
    check("a first-arrival waiting is an event",
          foldMoods(state: nil, live: [row("s1", .waiting)], now: t0, last: [:]).entered,
          Set([Mood.waiting]))
    check("the same mood a second time is not",
          foldMoods(state: nil, live: [row("s1", .waiting)], now: t0,
                    last: ["s1": .waiting]).entered, Set<Mood>())
    check("running is never an event",
          foldMoods(state: nil, live: [row("s1", .running)], now: t0, last: [:]).entered,
          Set<Mood>())
    check("nor is idle, however it was reached",
          foldMoods(state: nil, live: [row("s1", .idle)], now: t0,
                    last: ["s1": .waiting]).entered, Set<Mood>())
    check("every input lands in current, the state file included",
          Set(foldMoods(state: (.idle, t0), live: [row("s1", .done)], now: t0,
                        last: [:]).current.keys), Set(["state", "s1"]))
}

// MARK: - awayNudge
//
// The arrival reminder is silenced while the user is looking, and a permission
// prompt appears while they are necessarily looking — so the chime was
// structurally mute for its main case. This is the other transition: looking
// stopped while the face still shows a debt.

func nudge(_ d: Mood, _ was: Bool, _ now: Bool, _ n: Mood?) -> (fire: Bool, nudged: Mood?) {
    awayNudge(display: d, wasLooking: was, looking: now, nudged: n)
}

do {
    check("walking away from waiting fires", nudge(.waiting, true, false, nil).fire, true)
    check("and marks the episode", nudge(.waiting, true, false, nil).nudged, Mood.waiting)
    check("walking away from error fires", nudge(.error, true, false, nil).fire, true)
    check("done is news, not a debt", nudge(.done, true, false, nil).fire, false)
    check("running is not a debt either", nudge(.running, true, false, nil).fire, false)
    check("still looking never fires", nudge(.waiting, true, true, nil).fire, false)
    check("already away is not a transition", nudge(.waiting, false, false, nil).fire, false)
    check("one banner per episode", nudge(.waiting, true, false, .waiting).fire, false)
    check("a paid-off debt resets the episode", nudge(.idle, false, false, .waiting).nudged, nil)
    check("a new debt after reset fires again", nudge(.waiting, true, false, nil).fire, true)
    check("the debt changing mid-episode is a new episode",
          nudge(.error, true, false, .waiting).fire, true)
    check("looking keeps the episode armed, not cleared",
          nudge(.waiting, true, true, .waiting).nudged, Mood.waiting)
}

// MARK: - sessionLiveness
//
// Whether the overlay may quit. The rule that shipped wrong: liveness came
// from file mtime alone, so an idle-but-open session — a long meeting — went
// "stale" beside a provably running owner and the pet quit 30 seconds later,
// with only the next SessionStart able to bring it back.

do {
    let stale = t0.addingTimeInterval(-7200)
    let never: (pid_t) -> Bool = { _ in false }
    let always: (pid_t) -> Bool = { _ in true }

    let meeting = sessionLiveness([(owner: 42, stamp: stale)], lastOwners: [], now: t0, alive: always)
    check("a stale file with a live owner is live", meeting.live, true)
    check("and nothing about it is retired", meeting.retired, false)
    check("a dead owner retires in one poll",
          sessionLiveness([(owner: 42, stamp: stale)], lastOwners: [], now: t0, alive: never).retired, true)
    let unknown = sessionLiveness([(owner: nil, stamp: stale)], lastOwners: [], now: t0, alive: always)
    check("an ownerless stale session is not live", unknown.live, false)
    check("but not declared dead on missing evidence", unknown.retired, false)
    check("an ownerless fresh session is live",
          sessionLiveness([(owner: nil, stamp: t0)], lastOwners: [], now: t0, alive: never).live, true)
    check("an emptied directory with dead remembered owners retires",
          sessionLiveness([], lastOwners: [42], now: t0, alive: never).retired, true)
    let gap = sessionLiveness([], lastOwners: [42], now: t0, alive: always)
    check("with a live remembered owner it waits out the grace", gap.retired, false)
    check("remembered owners survive an owner-less poll",
          sessionLiveness([(owner: nil, stamp: t0)], lastOwners: [42], now: t0, alive: always).owners,
          Set<pid_t>([42]))
}

// MARK: - strandedOrigin
//
// A restored origin can name a display that no longer exists. Only a frame
// touching NO screen comes home: partial overlap is the user's own parking.

do {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = NSRect(x: 100, y: 100, width: 84, height: 99)
    let parked = NSRect(x: 1400, y: 100, width: 84, height: 99)
    let stranded = NSRect(x: 2000, y: 100, width: 84, height: 99)
    check("a visible frame is left alone",
          strandedOrigin(frame: visible, screens: [screen], home: screen), nil)
    check("partial overlap is a choice, not a stranding",
          strandedOrigin(frame: parked, screens: [screen], home: screen), nil)
    check("a stranded frame comes home",
          strandedOrigin(frame: stranded, screens: [screen], home: screen),
          NSPoint(x: 1356, y: 100))
    check("no home screen leaves it untouched",
          strandedOrigin(frame: stranded, screens: [], home: nil), nil)
}

// MARK: - flick & skid
//
// The physics of release momentum, every number of it — the window IO around
// these two functions is too thin to hide a defect that these do not already
// catch. Velocities go through arithmetic the harness cannot spell exactly
// (0.9 and 0.05 have no binary representation), so speed assertions use a
// tolerance; clamped POSITIONS are assigned, not computed, and stay exact.

func near(_ got: CGFloat?, _ want: CGFloat) -> Bool {
    got.map { abs($0 - want) < 0.001 } ?? false
}

do {
    check("a gentle release does not skid",
          flickVelocity(300, 0, sinceLastDrag: 0.01) == nil, true)
    check("a flick does",
          flickVelocity(800, 0, sinceLastDrag: 0.01) != nil, true)
    check("a pause before release parks the pet",
          flickVelocity(800, 0, sinceLastDrag: 0.5) == nil, true)
    // 800 pt/s across 50 ms ticks is 40 pt/tick — under the cap, so the
    // conversion is the only thing between input and output.
    check("velocity converts to points per tick",
          near(flickVelocity(800, 0, sinceLastDrag: 0.01)?.dx, 40), true)
    // 4000 pt/s would be 200 pt/tick; the cap holds the launch to SKID_MAX.
    check("the cap bounds the launch speed",
          near(flickVelocity(4000, 0, sinceLastDrag: 0.01)?.dx, SKID_MAX), true)

    let bounds = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: 84, height: 99)
    let step = skidStep(NSPoint(x: 100, y: 100), CGVector(dx: 40, dy: 0),
                        size: size, bounds: bounds)
    check("a step advances by the velocity", step.origin.x, 100 + 40)
    check("and bleeds speed", near(step.v.dx, 36), true)
    let wall = skidStep(NSPoint(x: 1400, y: 100), CGVector(dx: 40, dy: 20),
                        size: size, bounds: bounds)
    check("the screen edge stops that axis", wall.origin.x, bounds.maxX - size.width)
    check("and zeroes its speed", wall.v.dx, 0)
    check("while the other axis keeps sliding", near(wall.v.dy, 18), true)
    let crawl = skidStep(NSPoint(x: 100, y: 100), CGVector(dx: 1, dy: 0),
                         size: size, bounds: bounds)
    check("a crawl snaps to rest", crawl.v.dx, 0)
}

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
