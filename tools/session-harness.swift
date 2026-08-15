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
         say: String? = nil, name: String? = nil, title: String? = nil) -> SessionRow {
    SessionRow(sid: sid, cwd: cwd, mood: mood, say: say, name: name, title: title)
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
    let rows = liveSessions(dir, now: Date(), alive: { _ in true }, names: ["s1": "named"],
                            titles: ["s1": "titled"])
        .sorted { $0.sid < $1.sid }
    check("liveSessions reads both files", rows.count, 2)
    check("liveSessions reads line 2", rows[0].cwd, "/Users/x/Project/perchling")
    check("liveSessions reads line 3", rows[0].say, "hello")
    check("the one-line form stays valid", rows[1].cwd, nil)
    check("a registry name reaches the row", rows[0].name, "named")
    check("a session absent from the registry has no name", rows[1].name, nil)
    check("a desktop title reaches the row", rows[0].title, "titled")
    check("a session with no desktop record has no title", rows[1].title, nil)
    check("a dead owner drops the row",
          liveSessions(dir, now: Date(), alive: { _ in false }, names: [:], titles: [:]).count, 0)
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

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
