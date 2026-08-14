import AppKit

// Bounce and twitch are physical: roughly four points of travel regardless of
// how big a pet's cells are. Expressed in cells so the sprite grid stays the
// only coordinate system, and the canvas reserves three of those below the
// art for the motion to happen in.
// The chrome's own colours. These were borrowed from the pet's ink palette
// while the built-in was drawn from that enum; the pet is a manifest now and
// declares a palette of its own, so the two have no reason to move together —
// and a user's pet swapping in must not repaint the bubble. Hexes unchanged
// from what shipped, so the panels look identical to 1.6.
let CHROME_PANEL = NSColor(srgbRed: 0.227, green: 0.157, blue: 0.125, alpha: 1)
let CHROME_EDGE = NSColor(srgbRed: 0.455, green: 0.216, blue: 0.145, alpha: 1)
let CHROME_TEXT = NSColor(srgbRed: 1.000, green: 0.757, blue: 0.412, alpha: 1)
let CHROME_INK = NSColor(srgbRed: 1.000, green: 0.957, blue: 0.914, alpha: 1)

// The tick loop's period. Sequence timings quantise to this, so the parser and
// the timer cannot be allowed to drift apart.
let TICK_MS = 50

// Points of sustained sideways travel before a mirrored sequence changes which
// way it faces. Small because it is a DISTANCE, not a speed: jitter cancels
// itself out of the accumulator, so this only has to exceed the wobble of a
// hand trying to hold still. Turning around costs this much plus whatever
// residue the previous direction left behind, so up to twice it — which reads
// as the creature having to shed its momentum, and is the whole reason the
// accumulator is not cleared on every event.
let FACING_TRAVEL: CGFloat = 4

func bounceUnit(_ scale: CGFloat) -> Int { max(1, Int((4.0 / scale).rounded())) }
func headroom(_ scale: CGFloat) -> Int { 3 * bounceUnit(scale) }
// The twitch moves a custom pet's whole sprite sideways, so the canvas needs
// a margin on both sides or the leading column falls outside the view and the
// pet reads as sliced rather than shifted.
func sidePad(_ scale: CGFloat) -> Int { bounceUnit(scale) }
func canvasSize(_ w: Int, _ h: Int, _ scale: CGFloat) -> NSSize {
    NSSize(width: CGFloat(w + 2 * sidePad(scale)) * scale,
           height: CGFloat(h + headroom(scale)) * scale)
}
enum Mood: String {
    case idle, running, waiting, done, error

    // The session file's first line is the mood; an optional second line is
    // that session's cwd, which the tray shows and the fold ignores. Reading
    // line one keeps every file written before the label existed valid.
    static func parse(_ s: String) -> Mood {
        // .first, not [0] — split on an empty file returns an empty array, and
        // an empty session file is what a failed write leaves behind.
        let head = s.split(separator: "\n").first ?? ""
        return Mood(rawValue: head.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .idle
    }
}

// A custom pet replaces the whole sprite: one pixel grid per mood, colors
// from a per-manifest palette. "0" or "." is transparent; anything else must
// be a palette key. All moods share one canvas size; missing moods fall back
// to idle. Authored by hand or by the bundled draw-pet skill — no imagegen,
// no network; sharing a pet is sharing one JSON file.
struct PetError: Error, CustomStringConvertible {
    let description: String
    init(_ m: String) { description = m }
}

// A manifest's eyes are baked into its pixels, indistinguishable from the body,
// so a pet gets gaze and blink only by declaring where they are. Finding them
// by colour does not work — on a soft-shaded
// sprite the brightest inks inside the screen include the screen's own rim
// highlights, so the "eyes" come out as a second copy of the bezel and shifting
// them smears the frame. The author has to say. `socket` is the flat colour the
// vacated pixels take, so the box has to sit inside a flat field.
struct EyeBox {
    let x0: Int, y0: Int, x1: Int, y1: Int
    let socket: NSColor
    let range: Int

    func contains(_ x: Int, _ y: Int) -> Bool { x >= x0 && x <= x1 && y >= y0 && y <= y1 }
}

// A sequence is several frames on a clock — the one thing a manifest could not
// say, because a mood is a single grid. `steps` is compiled at load into a
// tick-indexed `schedule` because the tick loop quantises every duration to
// `TICK_MS`: an author who writes 120 gets 100, and `--validate` says so rather
// than leaving them to discover it by counting frames.
//
// hover, drag and tap are reactions, which arrive and expire. The five mood
// names are resting states, which loop until the mood changes — a mood is one
// grid, and this is how a manifest puts a clock on it. Their rawValues are
// `Mood`'s own, so a mood reaches its sequence by name instead of through a
// table that can fall out of step with the enum beside it.
//
// `tap` is named for what the user did, not for what the pet does. Of the
// others, two name an action of the user's and five name a state of the pet's,
// and none names a motion — `jump` would write "a poke makes it jump" into the
// format, where an author might want a nod.
enum SeqKind: String, CaseIterable {
    case hover, drag, tap
    case idle, running, waiting, done, error

    // nil for the three reactions, which is how a caller tells a state that
    // runs forever from a reaction that gets out of the way again.
    var mood: Mood? { Mood(rawValue: rawValue) }
}

struct PetSequence {
    let frames: [[[NSColor?]]]
    // Tick offset -> frame index, compiled once from `steps`. A uniform loop and
    // a timeline that replays poses under different holds are the same object
    // here, so `pose()` has one expression and no branch. A frame index occupies
    // as many entries as its step holds ticks.
    let schedule: [Int]
    // Declared beside resolved, for --validate only. An author who writes 110
    // and silently receives 100 has no other way to find out, and a timeline has
    // six of those numbers where the old single duration had one.
    let steps: [(frame: Int, ms: Int, ticks: Int)]
    // Consent to being flipped, which the format could not express before and
    // is the only reason mirroring is safe at all. A rightward run and its
    // leftward twin are the same pixels reflected — Codex spends a whole atlas
    // row on the copy, measured byte-identical to a flip of the other — so the
    // frames are worth reusing, but a flip also reverses any asymmetric detail:
    // a badge, a logo, lettering. The renderer cannot tell those apart from the
    // gait, so the author says.
    let mirror: Bool
    // How many times a ONE-SHOT runs before it gets out of the way. A double
    // hop is the timeline twice, not a doubled timeline — a repeat costs a
    // number where duplicated grids cost about 11KB each, and duplicates in
    // `frames` would also be indistinguishable from a row accidentally padded
    // with copies, which is a hazard the pipeline has an assertion against.
    // Meaningless on anything that already loops forever, where `--validate`
    // says so.
    let plays: Int
    // ONE pass through the timeline. `plays` multiplies it only where it
    // applies, which the caller knows and this does not.
    var totalTicks: Int { schedule.count }
}

// A tuple will not synthesise Equatable, and Pose's equality IS the repaint
// contract — without the frame index in there, repaintIfChanged() reads two
// consecutive sequence frames as the same pose and the animation never paints.
struct SeqRef: Equatable { let kind: SeqKind; let index: Int; let flipped: Bool }

struct CustomPet {
    let name: String
    let width: Int
    let height: Int
    let scale: CGFloat
    let frames: [Mood: [[NSColor?]]]
    let eyes: EyeBox?
    // The highest row any pose reaches. The chrome hangs off this rather than
    // off the canvas edge: `canvasSize` reserves headroom for the bounce and a
    // manifest pads its own grid on top of that, so a bubble pinned to the
    // window floats 23 points clear of a pet whose art starts at row 13. One
    // number across every pose, not one per pose — following each pose tucks
    // in tighter, but then the celebration drags the bubble and the chip up
    // with it every time the pet finishes something, and chrome that jumps
    // whenever the mood changes is worse than chrome that sits a few points
    // high. This is the position no pose reaches.
    let inkTop: Int
    // Synthesised once at load: the waiting frame with the eye box wiped to
    // `socket` and one lid bar per eye. Blinking then costs the draw path a
    // frame swap rather than per-tick pixel work, and a manifest that ships a
    // real blink frame later can replace this without the drawing changing.
    let blinkFrame: [[NSColor?]]?
    let sequences: [SeqKind: PetSequence]
    // Only --validate reads this. A name it did not recognise is worth saying
    // out loud once, or a typo is indistinguishable from a sequence that simply
    // never plays.
    let unknownSequenceKeys: [String]
    // Only --validate reads this too. A sequence still carrying `ms` is asking
    // for a tempo the format no longer has, and silence would look like it
    // worked.
    let legacyMsKeys: [String]

    func frame(for mood: Mood) -> [[NSColor?]] { frames[mood] ?? frames[.idle]! }

    // A mood animates only if it declared frames for itself. There is no
    // fallback to idle's sequence the way `frame(for:)` falls back to idle's
    // grid: a missing mood still has to be drawn as something, where a missing
    // sequence just means that state does not move.
    func sequence(for mood: Mood) -> PetSequence? {
        SeqKind(rawValue: mood.rawValue).flatMap { sequences[$0] }
    }

    func sequenceGrid(_ ref: SeqRef?) -> [[NSColor?]]? {
        guard let r = ref, let s = sequences[r.kind], r.index < s.frames.count else { return nil }
        return s.frames[r.index]
    }
}

func srgbLuma(_ c: NSColor) -> CGFloat {
    guard let s = c.usingColorSpace(.sRGB) else { return 0 }
    return 0.2126 * s.redComponent + 0.7152 * s.greenComponent + 0.0722 * s.blueComponent
}

func parseHex(_ s: String) -> NSColor? {
    guard s.hasPrefix("#") else { return nil }
    var h = String(s.dropFirst())
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    // The digit check is not redundant: UInt32(_:radix:) accepts a leading
    // "+", so "#+12345" would otherwise pass the length guard and silently
    // parse as #012345.
    guard h.count == 6, h.allSatisfy(\.isHexDigit), let v = UInt32(h, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

// The lid spans the lit runs, not the whole box: a box wide enough to gaze in
// is wider than the eyes, and a bar across all of it reads as a letterbox
// rather than a shut eye.
func synthBlinkFrame(_ rows: [[Character]], _ pal: [Character: NSColor],
                     _ e: EyeBox, _ socketCh: Character, _ lidCh: Character?) -> [[NSColor?]]? {
    guard let socketColor = pal[socketCh] else { return nil }
    let socketLuma = srgbLuma(socketColor)
    var counts: [Character: Int] = [:]
    for y in e.y0...e.y1 {
        for x in e.x0...e.x1 where rows[y][x] != socketCh { counts[rows[y][x], default: 0] += 1 }
    }
    let area = (e.x1 - e.x0 + 1) * (e.y1 - e.y0 + 1)
    // The 3% floor is what stops a single specular pixel winning: the very
    // brightest ink inside a screen is usually one cell of catchlight, and a
    // lid drawn in it comes out white instead of the eye's own colour.
    let auto = counts.filter { $0.value * 100 >= area * 3 }
        .max(by: { srgbLuma(pal[$0.key]!) < srgbLuma(pal[$1.key]!) })?.key
    guard let lid = lidCh ?? auto, let lidColor = pal[lid] else { return nil }

    func lit(_ x: Int, _ y: Int) -> Bool {
        guard let c = pal[rows[y][x]] else { return false }
        return srgbLuma(c) > socketLuma + 0.16
    }
    var cols: [Int] = []
    for x in e.x0...e.x1 {
        for y in e.y0...e.y1 where lit(x, y) { cols.append(x); break }
    }
    var lines: [Int] = []
    for y in e.y0...e.y1 {
        for x in e.x0...e.x1 where lit(x, y) { lines.append(y); break }
    }
    guard let first = cols.first, let top = lines.first, let bottom = lines.last else { return nil }
    var runs: [(Int, Int)] = []
    var start = first, prev = first
    for x in cols.dropFirst() {
        if x > prev + 2 { runs.append((start, prev)); start = x }
        prev = x
    }
    runs.append((start, prev))

    var out: [[NSColor?]] = rows.map { $0.map { ch in ch == "0" || ch == "." ? nil : pal[ch] } }
    for y in e.y0...e.y1 {
        for x in e.x0...e.x1 { out[y][x] = socketColor }
    }
    let mid = (top + bottom) / 2
    for (a, b) in runs {
        for y in mid...min(mid + 1, e.y1) {
            for x in a...b { out[y][x] = lidColor }
        }
    }
    return out
}

func parseGrid(_ rows: [String], _ pal: [Character: NSColor], _ w: Int,
               _ label: String) throws -> [[NSColor?]] {
    var grid: [[NSColor?]] = []
    for (y, row) in rows.enumerated() {
        guard row.count == w else { throw PetError("\(label) row \(y): length \(row.count) != \(w)") }
        var line: [NSColor?] = []
        for ch in row {
            if ch == "0" || ch == "." { line.append(nil) }
            else if let c = pal[ch] { line.append(c) }
            else { throw PetError("\(label) row \(y): \"\(ch)\" is not in the palette") }
        }
        grid.append(line)
    }
    return grid
}

func loadCustomPet(_ url: URL) throws -> CustomPet {
    guard let data = try? Data(contentsOf: url) else { throw PetError("cannot read \(url.path)") }
    return try loadCustomPet(data)
}

// Split from the URL form so the built-in pet can go through the same parser a
// user's pet.json does. Every rule enforced below therefore holds for the
// shipped pet too — a built-in that took a private path could drift from the
// format it is meant to be the reference example of.
func loadCustomPet(_ data: Data) throws -> CustomPet {
    let top: [String: Any]
    do {
        guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PetError("top level must be a JSON object")
        }
        top = d
    } catch let e as PetError {
        throw e
    } catch {
        throw PetError("bad JSON: \((error as NSError).userInfo[NSDebugDescriptionErrorKey] ?? error.localizedDescription)")
    }
    guard let palRaw = top["palette"] as? [String: String] else {
        throw PetError("\"palette\" must map single-character keys to \"#RRGGBB\" colors")
    }
    var pal: [Character: NSColor] = [:]
    for (k, v) in palRaw {
        guard k.count == 1, let ch = k.first, ch != "0", ch != "." else {
            throw PetError("palette key \"\(k)\" must be one character other than \"0\"/\".\" (those mean transparent)")
        }
        guard let c = parseHex(v) else { throw PetError("palette \"\(k)\": \"\(v)\" is not #RGB/#RRGGBB") }
        pal[ch] = c
    }
    guard let moodsRaw = top["moods"] as? [String: [String]], !moodsRaw.isEmpty else {
        throw PetError("\"moods\" must map mood names to arrays of row strings")
    }
    var frames: [Mood: [[NSColor?]]] = [:]
    var dims = (w: 0, h: 0)
    for (key, rows) in moodsRaw {
        guard let mood = Mood(rawValue: key) else {
            throw PetError("unknown mood \"\(key)\" (idle, running, waiting, done, error)")
        }
        let w = rows.first?.count ?? 0
        guard (8...128).contains(w), (8...128).contains(rows.count) else {
            throw PetError("\(key): size \(w)x\(rows.count) out of range 8...128")
        }
        if dims == (0, 0) { dims = (w, rows.count) }
        guard dims == (w, rows.count) else {
            throw PetError("\(key): size \(w)x\(rows.count) differs from \(dims.w)x\(dims.h) — all moods share one canvas")
        }
        frames[mood] = try parseGrid(rows, pal, w, key)
    }
    guard frames[.idle] != nil else { throw PetError("moods.idle is required") }
    // Finer-grained pets: a big grid at scale 2 beats a small grid at 4 —
    // same footprint on screen, four times the detail.
    var scale = 4
    if let s = top["scale"] {
        guard let n = s as? Int, (1...4).contains(n) else {
            throw PetError("\"scale\" must be an integer 1...4 (screen points per pixel)")
        }
        scale = n
    }
    var eyes: EyeBox?
    var blinkFrame: [[NSColor?]]?
    if let raw = top["eyes"] {
        guard let spec = raw as? [String: Any] else {
            throw PetError("\"eyes\" must be an object with \"box\" and \"socket\"")
        }
        guard let b = spec["box"] as? [Int], b.count == 4 else {
            throw PetError("eyes.box must be [x, y, width, height] in pixels")
        }
        guard b[2] > 0, b[3] > 0, b[0] >= 0, b[1] >= 0,
              b[0] + b[2] <= dims.w, b[1] + b[3] <= dims.h else {
            throw PetError("eyes.box \(b[0]),\(b[1]) \(b[2])x\(b[3]) does not fit the \(dims.w)x\(dims.h) canvas")
        }
        guard let sk = spec["socket"] as? String, sk.count == 1,
              let socketCh = sk.first, let socket = pal[socketCh] else {
            throw PetError("eyes.socket must be a palette key — the flat color behind the eyes")
        }
        var range = 2
        if let r = spec["range"] {
            guard let n = r as? Int, (0...8).contains(n) else {
                throw PetError("eyes.range must be an integer 0...8 (pixels of travel)")
            }
            range = n
        }
        var lidCh: Character?
        if let l = spec["lid"] {
            guard let s = l as? String, s.count == 1, let ch = s.first, pal[ch] != nil else {
                throw PetError("eyes.lid must be a palette key")
            }
            lidCh = ch
        }
        let box = EyeBox(x0: b[0], y0: b[1], x1: b[0] + b[2] - 1, y1: b[1] + b[3] - 1,
                         socket: socket, range: range)
        eyes = box
        // Blink is waiting's, so it is waiting's frame that gets a lid. A pet
        // with no waiting frame falls back to idle the same way drawing does.
        let src = (moodsRaw["waiting"] ?? moodsRaw["idle"]!).map(Array.init)
        blinkFrame = synthBlinkFrame(src, pal, box, socketCh, lidCh)
    }
    // Unknown keys are IGNORED here, which is deliberately the opposite of
    // `moods`. `moods` rejects them, and that is what makes a misplaced grid
    // silently fatal on an older perchling — the file fails to load, the pet
    // falls back to the built-in, and its row greys out in the Pets menu with
    // no error the user can see. A future perchling adding a sequence must not
    // do that to this one, so an unrecognised name is reported by --validate
    // and otherwise skipped.
    var sequences: [SeqKind: PetSequence] = [:]
    var unknownSequenceKeys: [String] = []
    var legacyMsKeys: [String] = []
    if let raw = top["sequences"] {
        guard let seqs = raw as? [String: Any] else {
            throw PetError("\"sequences\" must be an object mapping a sequence name — hover, drag, or a mood — to frame lists")
        }
        for (name, body) in seqs.sorted(by: { $0.key < $1.key }) {
            guard let kind = SeqKind(rawValue: name) else {
                unknownSequenceKeys.append(name)
                continue
            }
            guard let obj = body as? [String: Any] else {
                throw PetError("sequences.\(name) must be an object with \"frames\"")
            }
            guard let rawFrames = obj["frames"] as? [[String]] else {
                throw PetError("sequences.\(name).frames must be an array of frames, each an array of row strings")
            }
            // One frame is a pose, not a sequence — that version was built and
            // rejected. The ceiling is boundary validation: a frame costs about
            // 11KB in a 96x112 pet.
            guard (2...16).contains(rawFrames.count) else {
                throw PetError("sequences.\(name).frames has \(rawFrames.count) frames — must be 2...16")
            }
            // Required. There is no default tempo: a sequence whose timing
            // quietly fell back to a house value would be indistinguishable
            // from one authored that way, and the manifest is read on disk by a
            // process whose stderr the user never sees.
            guard let rawSteps = obj["steps"] as? [[Int]] else {
                throw PetError("sequences.\(name).steps is required — an array of [frameIndex, ms] pairs")
            }
            guard (2...32).contains(rawSteps.count) else {
                throw PetError("sequences.\(name).steps has \(rawSteps.count) entries — must be 2...32")
            }
            var steps: [(frame: Int, ms: Int, ticks: Int)] = []
            var schedule: [Int] = []
            for (i, pair) in rawSteps.enumerated() {
                guard pair.count == 2 else {
                    throw PetError("sequences.\(name).steps[\(i)] must be a two-element array [frameIndex, ms]")
                }
                let f = pair[0], stepMs = pair[1]
                guard (0..<rawFrames.count).contains(f) else {
                    throw PetError("sequences.\(name).steps[\(i)] frame \(f) is out of range — frames has \(rawFrames.count)")
                }
                guard (50...1000).contains(stepMs) else {
                    throw PetError("sequences.\(name).steps[\(i)].ms is \(stepMs) — must be 50...1000 (milliseconds)")
                }
                let ticks = max(1, Int((Double(stepMs) / Double(TICK_MS)).rounded()))
                steps.append((frame: f, ms: stepMs, ticks: ticks))
                schedule.append(contentsOf: Array(repeating: f, count: ticks))
            }
            // A leftover key from before timelines. Loud once, not fatal: the
            // timing it asks for is already fully described by `steps`.
            if obj["ms"] != nil { legacyMsKeys.append(name) }
            var mirror = false
            if let mr = obj["mirror"] {
                guard let b = mr as? Bool else {
                    throw PetError("sequences.\(name).mirror must be true or false")
                }
                mirror = b
            }
            var plays = 1
            if let p = obj["plays"] {
                guard let n = p as? Int, (1...8).contains(n) else {
                    throw PetError("sequences.\(name).plays must be an integer 1...8 (how many times a one-shot runs)")
                }
                plays = n
            }
            var grids: [[[NSColor?]]] = []
            for (i, rows) in rawFrames.enumerated() {
                let fw = rows.first?.count ?? 0
                guard (fw, rows.count) == (dims.w, dims.h) else {
                    throw PetError("sequences.\(name) frame \(i): size \(fw)x\(rows.count) differs from \(dims.w)x\(dims.h) — sequences share the moods' canvas")
                }
                grids.append(try parseGrid(rows, pal, dims.w, "sequences.\(name) frame \(i)"))
            }
            sequences[kind] = PetSequence(
                frames: grids, schedule: schedule, steps: steps,
                mirror: mirror, plays: plays)
        }
    }
    // Sequence frames count: a jump lifts the body above every mood, and the
    // chrome hangs off this one number. Leaving them out would sit the bubble
    // where a hovering pet's head goes through it — precisely when the user is
    // looking, since hover is the cursor being on the pet.
    let inkTop = (Array(frames.values) + sequences.values.flatMap { $0.frames })
        .map { $0.firstIndex { $0.contains { $0 != nil } } ?? 0 }
        .min() ?? 0
    return CustomPet(name: (top["name"] as? String) ?? "custom",
                     width: dims.w, height: dims.h, scale: CGFloat(scale), frames: frames,
                     eyes: eyes, inkTop: inkTop, blinkFrame: blinkFrame,
                     sequences: sequences, unknownSequenceKeys: unknownSequenceKeys,
                     legacyMsKeys: legacyMsKeys)
}

func petsDir(_ root: URL) -> URL { root.appendingPathComponent("pets") }

// A manifest's `name` becomes its filename, so it has to survive being one.
// CharacterSet.alphanumerics is Unicode-wide, not ASCII-only: letters and
// digits in any script pass through as-is, just lowercased — "café" and
// "貓咪" are left intact rather than stripped to nothing. Everything else,
// including "/", collapses to a dash, so the result can never come out empty
// or smuggle in a path separator.
func petSlug(_ name: String) -> String {
    let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    var out = ""
    for u in name.lowercased().unicodeScalars {
        out.append(ok.contains(u) ? Character(u) : "-")
    }
    while out.hasPrefix("-") { out.removeFirst() }
    while out.hasSuffix("-") { out.removeLast() }
    return out.isEmpty ? "pet" : out
}

// Every install predating the library has a REGULAR FILE at pet.json — that is
// what draw-pet wrote. Linking over it would destroy a pet the user may have no
// other copy of, so it becomes the library's first entry instead. A symlink is
// already correct; a missing file means the built-in, which is also correct.
// Both are left alone.
//
// Returning normally is a promise that pet.json is no longer a loose regular
// file, so a caller about to remove it can. Every way the rescue can fall short
// throws instead — including the rollback below, which deliberately puts the
// loose file back.
func migrateLoosePet(root: URL) throws {
    let fm = FileManager.default
    let pet = root.appendingPathComponent("pet.json")
    // attributesOfItem does not traverse symlinks, so this reports the link
    // itself rather than what it points at — which is the distinction the
    // whole guard rests on.
    guard let attrs = try? fm.attributesOfItem(atPath: pet.path) else { return }
    guard (attrs[.type] as? FileAttributeType) != .typeSymbolicLink else { return }

    let dir = petsDir(root)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)

    let slug = petSlug((try? loadCustomPet(pet))?.name ?? "current")
    var dest = dir.appendingPathComponent("\(slug).json")
    var n = 2
    while fm.fileExists(atPath: dest.path) {
        dest = dir.appendingPathComponent("\(slug)-\(n).json")
        n += 1
    }
    try fm.moveItem(at: pet, to: dest)
    // A relative link keeps working if the whole perchling directory moves.
    do {
        try fm.createSymbolicLink(atPath: pet.path,
                                  withDestinationPath: "pets/\(dest.lastPathComponent)")
    } catch {
        // The migrated file is safely in pets/, but pet.json no longer exists —
        // and this guard's own doctrine reads a missing pet.json as "no loose
        // pet, nothing to do," so without this it would never retry. Move it
        // back so the next launch finds the original loose file again and
        // attempts the whole migration over.
        try? fm.moveItem(at: dest, to: pet)
        throw error
    }
}

// One row of the Pets menu, resolved before anything is drawn: whether the
// manifest parses is decided here, not when the user clicks.
struct PetChoice {
    let name: String        // basename without .json, and what the menu shows
    let url: URL            // the file this row acts on
    let shipped: Bool       // still only in examples/, not yet copied into pets/
    let active: Bool        // pet.json currently resolves to this file
    let problem: String?    // why the manifest was rejected; nil when it loads
}

// User pets first, then shipped ones. Two rules are load-bearing:
// `perchling.json` never appears — it IS the built-in, which already has its
// own row — and a shipped pet whose name is already in pets/ is dropped,
// because the pets/ copy is the file a pick would link to.
func petChoices(root: URL, examples: URL?) -> [PetChoice] {
    let fm = FileManager.default
    let pet = root.appendingPathComponent("pet.json")
    // fileExists traverses the link, so a dangling one reports false and
    // nothing shows as active — which is exactly what a dangling link means.
    let activePath = fm.fileExists(atPath: pet.path)
        ? pet.resolvingSymlinksInPath().standardizedFileURL.path : nil

    func scan(_ dir: URL, shipped: Bool) -> [PetChoice] {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.map { url -> PetChoice in
            var problem: String?
            do { _ = try loadCustomPet(url) }
            catch let e as PetError { problem = e.description }
            catch { problem = error.localizedDescription }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            return PetChoice(name: url.deletingPathExtension().lastPathComponent,
                             url: url, shipped: shipped,
                             active: !shipped && resolved == activePath,
                             problem: problem)
        }.sorted { $0.name < $1.name }
    }

    let mine = scan(petsDir(root), shipped: false)
    let taken = Set(mine.map(\.name))
    let ship = (examples.map { scan($0, shipped: true) } ?? [])
        .filter { $0.name != "perchling" && !taken.contains($0.name) }
    return mine + ship
}

// Which menu row wears the checkmark — `nil` asks about the built-in row, the
// same convention `onPickPet` uses. The tick means "this is the creature on
// screen", which is not what the link names: a manifest that fails to load is
// still `active` while the built-in is what renders, and a dotfiles pet.json
// pointing outside pets/ renders a custom pet that has no row at all. Only the
// renderer knows which of those happened, so it is asked, via the `custom` that
// pollPet clears on every fallback.
func petIsOnScreen(_ choice: PetChoice?, showingCustom: Bool) -> Bool {
    guard let c = choice else { return !showingCustom }
    return showingCustom && c.active && c.problem == nil
}

// A shipped pet is copied into the library before it is linked. The plugin
// path carries a version number (.../perchling/<version>/examples/), so it is
// replaced wholesale by the next update — a link into it would dangle.
func adoptShippedPet(_ src: URL, root: URL) throws -> URL {
    let fm = FileManager.default
    let dir = petsDir(root)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent(src.lastPathComponent)
    if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: src, to: dest) }
    return dest
}

// The one place pet.json is removed. Its callers run from the menu, arbitrarily
// long after launch migrated, and pet.json can have gone back to being a loose
// regular file since: a migration that rolled itself back, a pets/ that only
// became writable later, or a user following the old copy-it-into-place
// instructions mid-session. That file may be their only copy of a pet, so it is
// rescued into the library first and the removal abandoned if the rescue can't
// finish — deleting what could not be saved is the whole bug.
func clearPetLink(root: URL) throws {
    try migrateLoosePet(root: root)
    try? FileManager.default.removeItem(at: root.appendingPathComponent("pet.json"))
}

// Validate before linking. A manifest that does not parse would leave pollPet
// with nil and the built-in on screen, which reads as the menu having done
// nothing at all.
func activatePet(_ target: URL, root: URL) throws {
    _ = try loadCustomPet(target)
    try clearPetLink(root: root)
    try FileManager.default.createSymbolicLink(
        atPath: root.appendingPathComponent("pet.json").path,
        withDestinationPath: "pets/\(target.lastPathComponent)")
}

// The built-in is the absence of a pet.json — the same thing the README has
// always told people to do by hand.
func useBuiltIn(root: URL) throws {
    try clearPetLink(root: root)
}

// The built-in is a manifest, so exporting it is handing the text back rather
// than reconstructing it from pixels. That is what makes `--export` an exact
// round-trip now: an author who edits the result and points `pet.json` at it
// starts from the shipped bytes, not from a re-serialisation of them.
func exportBuiltin() -> String { BUILTIN_MANIFEST }

final class PetView: NSView {
    // A mood loop restarts when the mood does, rather than free-running off
    // `tick`: `done`'s frames are an arc with a takeoff and a landing, and a
    // celebration joined halfway through is a pet that lands before it jumps.
    // In the setter and not in `pose()`, which has to stay pure — `draw()` and
    // `repaintIfChanged()` both call it.
    var mood: Mood = .idle { didSet { if mood != oldValue { moodSeqStart = tick } } }
    var moodSeqStart = 0
    var tick: Int = 0
    var hopUntil: Int = -1
    var custom: CustomPet?
    // What is actually drawn. `custom` answers "did the user pick something",
    // which the Pets menu needs; this answers "what is on screen", which the
    // draw path needs. Keeping them separate is what stopped the built-in row
    // losing its checkmark when the built-in became a manifest like any other.
    var activePet: CustomPet { custom ?? builtinPet }
    var scale: CGFloat = builtinPet.scale
    var xpad = sidePad(builtinPet.scale)
    var startledUntil = -1
    // `-1` is disarmed, matching hopUntil and startledUntil. Armed off
    // `activePet`, so the built-in's own sequences arm these too.
    // Hover is one-shot and expires by elapsing; drag loops until mouseUp; tap
    // is one-shot like hover and outranks it, because the cursor is on the pet
    // whenever a tap arrives and a tap ranked lower could never play.
    var hoverSeqStart = -1
    var dragSeqStart = -1
    var tapSeqStart = -1
    // Which way the drag is heading, latched. Only consulted for a sequence
    // that declared `mirror`. Deliberately NOT derived from `lean`: that decays
    // to zero the moment the hand stops moving, so a pause mid-drag would spin
    // the creature back to facing right.
    var dragFacingLeft = false
    // Signed distance travelled since the facing last changed. The facing has
    // to follow DISTANCE, not speed: `mouseDragged` fires per mouse event, so a
    // per-event threshold is really a velocity gate — at 60Hz, four points in
    // one event is 240 points a second, and a gentle drag never crosses it no
    // matter how far it goes. Accumulating fixes that and still cancels jitter,
    // because a wobble contributes both signs.
    private var facingTravel: CGFloat = 0

    func updateFacing(_ dx: CGFloat) {
        facingTravel += dx
        if facingTravel >= FACING_TRAVEL { dragFacingLeft = false; facingTravel = 0 }
        else if facingTravel <= -FACING_TRAVEL { dragFacingLeft = true; facingTravel = 0 }
    }
    // Drag inertia, in sprite pixels of top-row offset. A lean is a transform
    // of whatever pixels are already there, which is why it is the one drag
    // reaction a manifest can have without shipping a pose for it — the Codex
    // pets spend two atlas rows on running-left/running-right to get this.
    var lean: CGFloat = 0
    // Set once per draw so `fill` can shear without every call site — the base,
    // the eyes, the tear, the sparkle and the custom blit — passing it along.
    private var drawLean = 0

    override var isFlipped: Bool { true }

    var motionOK: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    // Reduce Motion freezes `tick`, so a deadline can never be reached once it
    // is on. Guarding only where the deadline is armed covers Reduce Motion
    // being on already, but not being switched on mid-flight — that leaves
    // `tick` parked below the deadline forever and the pose stuck for the life
    // of the process. Both ends have to check.

    // Hovering the BUILT-IN pet startles it. The startle swaps the eye shape,
    // and a manifest has one frame per mood with no second frame to cut to, so
    // a custom pet cannot have the reaction at all. The tracking area is still
    // built for it — it is rebuilt on resize anyway, because installing a
    // custom pet changes the window's bounds.
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        // A pet reacts to hover only if it shipped the frames for one. The
        // built-in used to swap in a drawn startle pose instead; that pose was
        // drawing code, and it left with the rest of it.
        if motionOK, activePet.sequences[.hover] != nil { hoverSeqStart = tick }
    }

    // Pupils drift toward the cursor (waiting, and idle's open-eyed peeks) —
    // the feature OpenAI built for Codex pets and left Statsig-gated off.
    //
    // Sixteen sectors, which is the resolution their own atlas devotes two
    // whole rows to. The three-value version this replaced could not tell a
    // cursor above from one above-and-left, so half the screen produced the
    // same two poses. The vector is a direction only — callers scale it, and
    // they scale x and y differently because the glass is wider than it is
    // tall and the eyes have about twice the sideways headroom.
    private func gazeVector() -> (CGFloat, CGFloat) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return (0, 0) }
        guard let w = window else { return (0, 0) }
        let m = NSEvent.mouseLocation
        let dx = m.x - w.frame.midX, dy = m.y - w.frame.midY
        // Dead ahead is not a direction. Without this the eyes chase the
        // sub-pixel jitter of a resting cursor and read as a nervous tic.
        guard hypot(dx, dy) > 40 else { return (0, 0) }
        let step = CGFloat.pi / 8
        let a = (atan2(dy, dx) / step).rounded() * step
        // Screen coords are y-up, the grid is y-down: cursor above → pupils up.
        return (cos(a), -sin(a))
    }

    // Proximity peek: approach wakes the pet before hover startles it.
    // Without a window (offscreen harness) there is no position, so no peek
    // — the same neutrality gaze() already promises.
    private func nearCursor() -> Bool {
        guard let w = window else { return false }
        let m = NSEvent.mouseLocation
        return hypot(m.x - w.frame.midX, m.y - w.frame.midY) < 150
    }

    // The top of the sprite lags the direction of travel and the feet stay
    // planted, because the feet are what it is being dragged BY — a uniform
    // offset would read as the window sliding rather than the creature
    // resisting. Rects spanning several rows take their top row's shear; the
    // tallest of them is three rows, so the error never reaches a pixel.
    private func leanShift(_ y: Int) -> Int {
        guard drawLean != 0 else { return 0 }
        let h = CGFloat(activePet.height)
        return Int((CGFloat(drawLean) * (1 - CGFloat(y) / h)).rounded())
    }

    // Every blit goes through here, so the side margin and the drag shear are
    // applied in one place rather than at each call site.
    private func fill(_ color: NSColor, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ off: Int) {
        color.setFill()
        let r = NSRect(x: CGFloat(x0 + xpad + leanShift(y0)) * scale,
                       y: CGFloat(y0 + off) * scale,
                       width: CGFloat(x1 - x0 + 1) * scale,
                       height: CGFloat(y1 - y0 + 1) * scale)
        r.fill()
    }

    // Everything draw() turns into pixels, resolved in one place. Every clock-
    // driven value is reduced to the state it actually lands on, so two ticks
    // that paint the same picture produce the same Pose. Anything that later
    // wants to know whether a repaint is needed reads this rather than
    // re-deriving the inputs, which is how the two would drift apart.
    struct Pose: Equatable {
        let mood: Mood
        let off: Int
        let dx: Int
        let blinking: Bool
        // Custom pets only. `dx` moves the whole sprite, so the eye shift needs
        // its own pair or a glance would drag the body with it.
        let eyeDX: Int
        let eyeDY: Int
        // Quantised here so the repaint decision sees the shear settle.
        let lean: Int
        let spriteGen: Int
        let seq: SeqRef?
    }

    // Which creature, as opposed to how it is posed. Swapping pet.json changes
    // `custom`, `scale` and `xpad` without moving a single other pose field,
    // and under Reduce Motion in idle every other field is invariant for the
    // life of the process — so a repaint decision watching the rest alone would
    // draw the previous creature forever. All three are assigned in exactly one
    // place, which is why one counter there is enough rather than merely likely.
    var spriteGen = 0

    private var lastPose: Pose?

    // The repaint decision reads the value the paint reads. Nothing here
    // re-derives an input, so the two cannot come to different conclusions
    // about what the next frame would contain.
    func repaintIfChanged() {
        let p = pose()
        guard p != lastPose else { return }
        lastPose = p
        needsDisplay = true
    }

    func pose() -> Pose {
        let u = bounceUnit(activePet.scale)
        var off = 2
        var dx = 0
        // A manifest declares one eye box, so its gaze is measured in that
        // box's own pixels rather than in bounce units: the box is the only
        // thing that knows how much headroom the eyes actually have.
        var eyeDX = 0
        var eyeDY = 0
        switch mood {
        case .running:
            off = 2 + (tick / 4) % 2
            dx = ((tick / 10) % 4 == 1) ? -1 : (((tick / 10) % 4 == 3) ? 1 : 0)
        case .waiting:
            dx = (tick % 30 < 2) ? 1 : 0
            if let e = activePet.eyes {
                let g = gazeVector()
                eyeDX = Int((g.0 * CGFloat(e.range)).rounded())
                eyeDY = Int((g.1 * CGFloat(e.range)).rounded())
            }
            // Attention beat: the fold ranks waiting above everything, so it
            // cannot be the stillest thing on screen — two hops every ~3s.
            if motionOK && tick % 60 < 12 { off = ((tick / 3) % 2 == 0) ? 2 : 0 }
        case .done:
            off = 2 + (tick / 9) % 2
        case .error:
            off = 3
        case .idle:
            // Breath, not bounce: the resting state stops spending the
            // attention budget the alert moods need to rise above.
            off = (tick % 64 < 56) ? 2 : 3
            // Straight into the gaze pair rather than through `dx`, which is
            // measured in whole cells and would collapse sixteen sectors back
            // to the three the old three-value gaze had.
            // Proximity moves the eyes the pet already has. It notices you
            // approaching; it cannot open eyes it has no art for.
            if let e = activePet.eyes, motionOK, nearCursor() {
                let g = gazeVector()
                eyeDX = Int((g.0 * CGFloat(e.range)).rounded())
                eyeDY = Int((g.1 * CGFloat(e.range)).rounded())
            }
        }
        // The hop outranks the mood's resting bob, and now fires on a tap in
        // any mood rather than only on the switch into done.
        if motionOK && tick < hopUntil { off = ((tick / 3) % 2 == 0) ? 2 : 0 }

        // Drag outranks hover: the cursor sitting on a pet you are already
        // holding is not new information. Both are gated on motionOK because
        // `tick` freezes under Reduce Motion, so an index derived from
        // `tick - start` would stick on one frame forever.
        var seq: SeqRef?
        if motionOK {
            // `activePet`, never `custom`: the built-in is a manifest like any
            // other and declares its own sequences. `custom` answers "did the
            // user pick something", which is a question only the Pets menu asks.
            let pet = activePet
            if dragSeqStart >= 0, let s = pet.sequences[.drag] {
                // Frames as drawn face RIGHT; the flip is what leftward travel
                // looks like. A pet that did not declare `mirror` never flips,
                // whichever way it is dragged.
                seq = SeqRef(kind: .drag,
                             index: s.schedule[(tick - dragSeqStart) % s.schedule.count],
                             flipped: s.mirror && dragFacingLeft)
            }
            // Above hover, and that ordering is not a preference: the cursor
            // must be on the pet to click it, so hover is always armed when a
            // tap arrives, and a tap ranked below it would be dead code.
            //
            // Reached by testing `seq`, never by chaining an `else if` onto the
            // arm above. A burst's clock stays armed after the burst is spent —
            // only a drag clears it — so an `else if` here matches on a spent
            // tap, produces nothing, and silently swallows every hover from the
            // first tap onward. That is the same regression the mood loop has
            // always been written around, one level up.
            if seq == nil, tapSeqStart >= 0, let s = pet.sequences[.tap] {
                let i = tick - tapSeqStart
                if i < s.schedule.count * s.plays {
                    seq = SeqRef(kind: .tap, index: s.schedule[i % s.schedule.count], flipped: false)
                }
            }
            if seq == nil, hoverSeqStart >= 0, let s = pet.sequences[.hover] {
                // In TICKS, not frames — the schedule is the clock now.
                let i = tick - hoverSeqStart
                // A burst has no direction of travel, so it never flips. It
                // may run more than once: the index wraps, the deadline does
                // not, which is what makes a double hop the same timeline
                // rather than a longer one.
                if i < s.schedule.count * s.plays {
                    seq = SeqRef(kind: .hover, index: s.schedule[i % s.schedule.count], flipped: false)
                }
            }
            // The mood loop is the floor: it plays whenever no reaction is,
            // which includes after a hover burst has elapsed. Reached by
            // testing `seq` rather than by chaining another `else`, because
            // `hoverSeqStart` stays armed once set — it is cleared only by a
            // drag — so an `else if` on it would swallow every mood loop from
            // the first hover onward. It never flips: a resting state has no
            // direction of travel, which is also why `mirror` only warns here.
            if seq == nil, let k = SeqKind(rawValue: mood.rawValue), let s = pet.sequences[k] {
                seq = SeqRef(kind: k,
                             index: s.schedule[(tick - moodSeqStart) % s.schedule.count],
                             flipped: false)
            }
        }
        // The frames own their own motion. The bounce would double-count a
        // jump's lift, the twitch shares the one-bounce-unit side budget with
        // the shear, and the eye box is declared against the mood frames — on a
        // real pet `done` already lands 37.5% of it on the shell, and a lifted
        // frame is worse. The shear is NOT reset: it is applied inside fill(),
        // which the custom blit already goes through, and it is what tells the
        // viewer which way the pet is being dragged.
        if seq != nil {
            off = 2
            dx = 0
            eyeDX = 0
            eyeDY = 0
            // A poke still lands, though. A mood loop is a resting state, not
            // a reaction: a tap that visibly does nothing reads as a dead
            // window, and the loop is the one thing on this list a tap is
            // allowed to outrank. Hover and drag are reactions themselves and
            // already outrank the loop, so their frames keep their own motion
            // untouched. The arrival hop does NOT come back this way — it is
            // armed only when `done` has no sequence of its own, which is what
            // stops a lift being stacked on a lift.
            if seq?.kind.mood != nil, motionOK, tick < hopUntil {
                off = ((tick / 3) % 2 == 0) ? 2 : 0
            }
        }

        // The side margin is one bounce unit and the twitch already spends all
        // of it, so the two cannot both run — and a nervous tic while the pet
        // is being held in a fist is not a thing worth reserving canvas for.
        let ln = motionOK ? Int(lean.rounded()) : 0
        if ln != 0 { dx = 0 }

        let blink = mood == .waiting && motionOK && tick % 80 < 2
            && activePet.blinkFrame != nil && seq == nil
        // Three clocks, three periods — twinkle /6, waiting beat %60, waiting
        // blink %80 — deliberately share none, so overlapping animations read
        // as three mechanisms, not one.

        return Pose(mood: mood, off: off * u, dx: dx * u, blinking: blink,
                    eyeDX: eyeDX, eyeDY: eyeDY, lean: ln,
                    spriteGen: spriteGen, seq: seq)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.shouldAntialias = false
        ctx.imageInterpolation = .none

        let p = pose()
        drawLean = p.lean

        // One sprite per mood, swapped whole. Bounce (off) and twitch (dx) still
        // apply on top; everything else the frame says is final, because a
        // manifest carries pixels and the renderer has no second opinion about
        // them.
        let pet = activePet
        // Sequence outranks both: it replaces the whole sprite for its
        // duration, which is why the gaze and the blink already bowed out
        // in pose(). Pixels do not composite, so a pet hovered mid-task
        // shows the reaction rather than its mood — the same trade Codex
        // makes (`respondToHover && isHovered ? 'jumping' : state`).
        let grid = pet.sequenceGrid(p.seq)
            ?? (p.blinking ? pet.blinkFrame : nil)
            ?? pet.frame(for: p.mood)
        let shifting = p.eyeDX != 0 || p.eyeDY != 0
        let flip = p.seq?.flipped == true
        for y in 0..<pet.height {
            for x in 0..<pet.width {
                var c = grid[y][flip ? pet.width - 1 - x : x]
                // Sampled backwards, so every destination pixel is written
                // exactly once. Scattering forwards instead leaves a gap
                // wherever the shift steps past a source pixel, which is
                // the difference between a glance and a torn eye.
                if shifting, let e = pet.eyes, e.contains(x, y) {
                    let sx = x - p.eyeDX, sy = y - p.eyeDY
                    c = e.contains(sx, sy) ? grid[sy][sx] : e.socket
                }
                if let c = c { fill(c, x + p.dx, y, x + p.dx, y, p.off) }
            }
        }
    }

    // Manual drag: window-background dragging would swallow the mouseUp we
    // need to tell a click ("jump back to Claude") from a drag ("move me").
    var onTap: (() -> Void)?
    private var pressAt: NSPoint?
    private var winAt: NSPoint?
    private var lastDrag: NSPoint?
    private var dragged = false

    // Deliver the activating click too — an accessory app is inactive at
    // nearly every interaction, and without this AppKit eats the first
    // mouseDown as an activation click (two-click taps, dead cold drags).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressAt = NSEvent.mouseLocation
        winAt = window?.frame.origin
        lastDrag = nil
        dragged = false
        dragSeqStart = -1
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p0 = pressAt, let w0 = winAt, let w = window else { return }
        let p = NSEvent.mouseLocation
        if abs(p.x - p0.x) + abs(p.y - p0.y) > 2 { dragged = true }
        if dragSeqStart < 0, motionOK, activePet.sequences[.drag] != nil {
            dragSeqStart = tick
            hoverSeqStart = -1
            tapSeqStart = -1
        }
        // Velocity, not displacement: a slow drag across the whole screen must
        // not accumulate into a permanent tilt. The blend is what keeps a
        // single jerky event from snapping the pet to full lean and back.
        if motionOK, let last = lastDrag {
            let cap = CGFloat(sidePad(scale))
            lean = max(-cap, min(cap, lean * 0.5 - (p.x - last.x) * 0.5))
            updateFacing(p.x - last.x)
        }
        lastDrag = p
        w.setFrameOrigin(NSPoint(x: w0.x + (p.x - p0.x), y: w0.y + (p.y - p0.y)))
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged {
            // React first so the poke registers even though focus is about to
            // leave for the home app. A pet that drew its own reaction plays
            // that; every other pet — the built-in included — keeps the
            // procedural two-cell hop, so nothing that works today changes.
            if motionOK {
                if activePet.sequences[.tap] != nil { tapSeqStart = tick } else { hopUntil = tick + 12 }
            }
            onTap?()
        }
        pressAt = nil
        winAt = nil
        lastDrag = nil
        dragSeqStart = -1
    }

    // Where the art starts, in points below the window's top edge — the same
    // for every pose, so the chrome never moves when the mood does. Measured
    // at the RESTING bounce rather than the live one, or it would breathe
    // along with the pet.
    var artTopInset: CGFloat {
        CGFloat(activePet.inkTop + 2 * bounceUnit(scale)) * scale
    }

    // Called from the tick loop rather than from pose(), which has to stay pure
    // — draw() and repaintIfChanged() both call it, and a decay in there would
    // run twice a frame or not at all depending on which of them ran first.
    func decayLean() {
        guard lean != 0 else { return }
        lean *= 0.8
        if abs(lean) < 0.5 { lean = 0 }
    }

    var onTuck: (() -> Void)?
    var onDisable: (() -> Void)?

    // Named petList, not petChoices: the free function that computes it is
    // already called petChoices, and a property shadowing it inside the
    // Controller closure that assigns this is a needless fight.
    var petList: (() -> [PetChoice])?
    var onPickPet: ((PetChoice?) -> Void)?   // nil picks the built-in
    var sessionList: (() -> [SessionRow])?
    var labelList: (() -> [String: String])?

    @objc private func tuckAction() { onTuck?() }
    @objc private func disableAction() { onDisable?() }
    @objc private func pickBuiltInAction() { onPickPet?(nil) }
    @objc private func pickPetAction(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? PetChoice else { return }
        onPickPet?(choice)
    }
    // A row cannot jump to its session — individual terminal tabs are not
    // addressable from an accessory app — so it does what tapping the pet
    // does, and does not pretend otherwise.
    @objc private func focusSessionAction() { onTap?() }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        // The fold's other half. The face can only ever show the maximum, so
        // this is the only place that says which session it belongs to.
        let sessions = sessionList?() ?? []
        let labels = labelList?() ?? [:]
        for r in sessions {
            // `labels` is `sessionLabels(sessions)` from this same poll, which
            // fills in every sid it is handed — the `?? sessionName(r)` cannot
            // fire. Kept anyway: it is a correct-value fallback (the
            // unsuffixed name), not a guard, and the alternative is a
            // force-unwrap in a process that runs all day.
            let item = NSMenuItem(title: sessionTitle(labels[r.sid] ?? sessionName(r),
                                                      r.mood, moodStatus),
                                  action: #selector(focusSessionAction), keyEquivalent: "")
            item.target = self
            // Two projects can share a basename; the full path is the only
            // thing that tells them apart, and there is no room for it inline.
            item.toolTip = r.cwd
            menu.addItem(item)
        }
        if !sessions.isEmpty { menu.addItem(.separator()) }

        let choices = petList?() ?? []
        let showingCustom = custom != nil
        let pets = NSMenu()
        // Without this, AppKit's automatic validation re-enables the rows we
        // deliberately disabled for unparseable manifests.
        pets.autoenablesItems = false
        let builtIn = NSMenuItem(title: "Built-in perchling",
                                 action: #selector(pickBuiltInAction), keyEquivalent: "")
        builtIn.target = self
        builtIn.state = petIsOnScreen(nil, showingCustom: showingCustom) ? .on : .off
        pets.addItem(builtIn)
        for group in [choices.filter { !$0.shipped }, choices.filter { $0.shipped }]
        where !group.isEmpty {
            pets.addItem(.separator())
            for c in group {
                let item = NSMenuItem(title: c.shipped ? "\(c.name)  (shipped)" : c.name,
                                      action: #selector(pickPetAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = c
                item.state = petIsOnScreen(c, showingCustom: showingCustom) ? .on : .off
                item.isEnabled = c.problem == nil
                item.toolTip = c.problem
                pets.addItem(item)
            }
        }
        let petsItem = NSMenuItem(title: "Pets", action: nil, keyEquivalent: "")
        petsItem.submenu = pets
        menu.addItem(petsItem)
        menu.addItem(.separator())

        let tuck = NSMenuItem(title: "Tuck away (wakes when needed)", action: #selector(tuckAction), keyEquivalent: "")
        tuck.target = self
        menu.addItem(tuck)
        let disable = NSMenuItem(title: "Disable (pet.sh enable to undo)", action: #selector(disableAction), keyEquivalent: "")
        disable.target = self
        menu.addItem(disable)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit perchling", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

let claudeBundleID = "com.anthropic.claudefordesktop"

// Attention-priority fold across sessions: one session's "running" must not
// stomp another's "waiting". Per-mood TTLs expire stale news (a SIGKILL'd
// session can't leave the pet bouncing forever).
let moodRank: [Mood: Int] = [.idle: 0, .running: 1, .done: 2, .error: 3, .waiting: 4]
// `done` outlives the moment it announces because the bubble carries the reply
// and stops drawing the instant the mood decays — a window you can look away
// from is the whole point. It stays short enough that a finished session does
// not sit on top of the attention fold, which it outranks, for minutes.
let moodTTL: [Mood: TimeInterval] = [.running: 900, .done: 60, .error: 3600, .waiting: 3600]

// Four words of UI, so the table is inline rather than a .lproj bundle a
// single-file build cannot carry. Only languages whose wording I can vouch
// for are listed — a wrong translation is worse than English. Shared by the
// speech bubble and the tray rows so the two never word the same mood
// differently — which is also why no entry may contain an em dash:
// `sessionTitle` joins a label to the status with one, and a second
// makes the row stutter. `statusLine` joins them the same way once a name is
// shown, so the ban binds the bubble too.
let moodStatus: [Mood: String] = {
    // Idle earns a line now that the bubble stays up through it. Without one
    // the panel is a blank slab whenever nothing is happening, which is most
    // of the time. It says spacing out rather than dozing because the idle
    // face has open eyes: a manifest has one frame per mood, so there is no
    // eyes-closed art to cut to, and "dozing" under two open eyes reads as a
    // caption that lost its picture.
    let en: [Mood: String] = [.idle: "unbothered…", .running: "thinking…",
                              .waiting: "waiting for you…",
                              .done: "done!", .error: "oops, error"]
    let tables: [String: [Mood: String]] = [
        "zh-Hant": [.idle: "懶得動…", .running: "思考中…", .waiting: "等你回應…", .done: "完成！", .error: "出錯了"],
        "zh-Hans": [.idle: "懒得动…", .running: "思考中…", .waiting: "等你回应…", .done: "完成！", .error: "出错了"],
        "ja": [.idle: "やる気なし…", .running: "考え中…", .waiting: "入力待ち…", .done: "完了！", .error: "エラー"],
    ]
    // Region-only Chinese tags carry no script subtag, so map them by hand
    // rather than letting a bare "zh" prefix decide the script.
    func key(_ lang: String) -> String? {
        if lang.hasPrefix("ja") { return "ja" }
        guard lang.hasPrefix("zh") else { return nil }
        if ["zh-Hant", "zh-TW", "zh-HK", "zh-MO"].contains(where: lang.hasPrefix) { return "zh-Hant" }
        return "zh-Hans"
    }
    // Only the primary language decides. Scanning the whole list would let
    // a Chinese entry further down override an English-first system —
    // "I don't have your language" means fall back, not keep hunting.
    guard let first = Locale.preferredLanguages.first,
          let k = key(first), let t = tables[k] else { return en }
    return t
}()

// One live session as the tray shows it.
struct SessionRow {
    let sid: String
    let cwd: String?    // line 2 of the session file; nil on the one-line form
    let mood: Mood      // effective: already decayed to idle past its own TTL
    let say: String?    // line 3: this session's caption; nil on the shorter forms
    let name: String?   // the host CLI's own name for it; nil when it has none
    let title: String?  // the desktop app's title for it; nil when it has none
}

// The one place sessions/ is read for moods. The attention fold and the menu
// both take their sessions from here, so the face and the list cannot disagree
// about who is live or what they are doing. `alive` is injected because a
// harness has no pids to point at.
func liveSessions(_ dir: URL, now: Date, alive: (String) -> Bool,
                  names: [String: String], titles: [String: String]) -> [SessionRow] {
    let fm = FileManager.default
    let cutoff = now.addingTimeInterval(-3600)
    let items = (try? fm.contentsOfDirectory(at: dir,
                                             includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles])) ?? []
    var out: [SessionRow] = []
    for url in items {
        let sid = url.lastPathComponent
        // A dead owner's last mood is not news: without this a killed app
        // leaves "waiting for you" on the pet's face for the rest of the TTL,
        // in front of whoever is still working elsewhere.
        guard alive(sid),
              let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              stamp > cutoff else { continue }
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let mood = Mood.parse(raw)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let cwd = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let say = lines.count > 2 ? lines[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let ttl = moodTTL[mood] ?? 0
        out.append(SessionRow(sid: sid,
                              cwd: cwd.isEmpty ? nil : cwd,
                              mood: now.timeIntervalSince(stamp) > ttl ? .idle : mood,
                              say: say.isEmpty ? nil : say,
                              name: names[sid],
                              title: titles[sid]))
    }
    return out
}

// The registry is written by another program, so this is a trust boundary. A
// newline would split an NSMenuItem title in two. The cap is not a layout
// concern — statusLine truncates by measured width and the menu truncates its
// own titles — it is there so a pathological string is not moved every 0.4s.
func cleanName(_ s: String) -> String {
    let stripped = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    return String(stripped.trimmingCharacters(in: .whitespaces).prefix(64))
}

// The host CLI's own session registry: one JSON file per live session, keyed by
// pid, carrying the session id it belongs to and the name the app shows for it.
// Undocumented and not ours, so every failure here is a missing entry rather
// than an error — an older CLI, a format that moved, and a background job that
// legitimately has no name are the same thing from the outside, and all three
// are correctly answered by falling back to the project directory.
//
// `nameSource` is deliberately not read. It distinguishes a name derived from
// the cwd from one a rename set, but which of those a session carries depends
// on host policy that cannot be pinned down from a minified bundle — and being
// wrong about it would be silent. `sessionLabels` guarantees distinguishable
// rows without knowing.
//
// `alive` is injected for the same reason `liveSessions` injects it: a harness
// has no pids to point at.
func registryNames(_ dir: URL, alive: (pid_t) -> Bool) -> [String: String] {
    let fm = FileManager.default
    let items = (try? fm.contentsOfDirectory(at: dir,
                                             includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles])) ?? []
    var out: [String: String] = [:]
    var stamps: [String: Date] = [:]
    for url in items where url.pathExtension == "json" {
        // Parenthesised for readability, not semantics.
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sid = obj["sessionId"] as? String,
              let raw = obj["name"] as? String else { continue }
        let name = cleanName(raw)
        if name.isEmpty { continue }
        // A missing pid is unknown, never dead — the same rule ownerAlive
        // follows for a session with no owner file. Dead pids are dropped here,
        // so everything that survives is live and mtime alone breaks a tie.
        // `pid_t.init(_: Int)` traps on an out-of-range value instead of
        // failing, so an oversized `pid` — a wider field from a future host
        // version — has to go through the failable initializer or it takes
        // the whole overlay down on data this function already treats as a
        // trust boundary. Out of range is unknown, exactly like absent.
        if let pidNum = obj["pid"] as? Int, let pid = Int32(exactly: pidNum), !alive(pid_t(pid)) { continue }
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        if let prev = stamps[sid], prev > stamp { continue }
        stamps[sid] = stamp
        out[sid] = name
    }
    return out
}

// One parsed desktop record. Cached because a real one is ~279KB — almost all
// of it an MCP config block — and re-parsing every record on a 0.4s poll would
// put over a megabyte a second of JSON through the main thread.
struct TitleEntry {
    let stamp: Date
    // nil when the record parsed but carried no usable title. A session whose
    // title has not been written yet is a normal state — the desktop app
    // writes a session's record when it starts and fills in the title later,
    // once auto-titling has something to summarise — so a title-less record
    // is not a rare edge case, it is every new session for as long as it
    // takes the app to name it. Not caching that answer means re-parsing the
    // full 279KB on every poll, unchanged, until the title lands: exactly the
    // cost this cache exists to eliminate.
    let hit: (sid: String, title: String)?
}

// Both halves of what survives across polls. The parse cache keys on a record's
// path; the listing cache keys on the directory that holds them, because the
// enumeration is its own cost and a separate question from the parse. Measured
// on this machine 2026-08-14: 3 real records against 351 `deleted_` tombstones,
// so a poll that skipped every parse still walked 355 directory entries.
struct TitleCache {
    var files: [String: TitleEntry] = [:]
    var dirs: [String: DirListing] = [:]
}

// The `local_*.json` paths a directory held, and the directory mtime they were
// read at. A directory's mtime moves when an entry is added, removed or
// renamed and does NOT move when an existing file's contents are rewritten —
// measured on APFS, and true of an atomic `write(to:atomically:)` as well as an
// in-place one. So this may memoise WHICH files exist and must never memoise
// what is in them: the per-file stamp check below is what catches a rename,
// and `tools/run-session-harness.sh`'s "a rewritten record is re-read" is what
// catches anyone who forgets that.
struct DirListing {
    let stamp: Date
    let urls: [URL]
}

// Incremented once per directory actually enumerated. Nothing in the app reads
// it; `tools/session-harness.swift` does, because the listing cache is a pure
// performance change and no assertion over the RESULT can tell whether it is
// working. Without this, deleting the cache leaves every test green.
var titleDirScans = 0

// The desktop app's own session records, which carry the title the user sees in
// the sidebar. A second foreign file, and a second one perchling only reads:
// the CLI registry beside it names the same session differently — `derived`
// there, user- or LLM-written here — and this one is what the human is looking
// at, so it wins.
//
// The join key is the record's `cliSessionId`, which holds the CLI session id
// that names perchling's own sessions/<sid> file.
//
// `titleSource` is deliberately not read, for the same reason `nameSource` is
// not: `user` and `auto` titles are both what the sidebar shows.
//
// Records sit two account-scoped directories below `dir`, so that level is
// globbed rather than hardcoded. Enumeration asks for NO resource keys and
// filters by name first: the records share a directory with hundreds of
// `deleted_` tombstones, and asking for keys up front turns one readdir into a
// stat per tombstone.
func desktopTitles(_ dir: URL, cache: inout TitleCache) -> [String: String] {
    let fm = FileManager.default
    func kids(_ u: URL) -> [URL] {
        titleDirScans += 1
        return (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil,
                                            options: [.skipsHiddenFiles])) ?? []
    }
    // The records' own directory is the only one worth memoising: `dir` and the
    // account level below it hold one entry each, while this one holds hundreds
    // of tombstones. Asking its mtime is one stat against that whole walk.
    func records(_ org: URL) -> [URL] {
        let stamp = (try? org.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        if let listed = cache.dirs[org.path], listed.stamp == stamp { return listed.urls }
        let urls = kids(org).filter { $0.lastPathComponent.hasPrefix("local_")
                                      && $0.pathExtension == "json" }
        cache.dirs[org.path] = DirListing(stamp: stamp, urls: urls)
        return urls
    }
    var out: [String: String] = [:]
    // Two records can claim the same cliSessionId — a stale directory left
    // behind by an account switch, say — and without a tie-break the winner
    // would be whichever one contentsOfDirectory happened to enumerate last.
    // mtime alone breaks the tie, the same rule registryNames follows for a
    // duplicate sessionId.
    var stamps: [String: Date] = [:]
    var seen: Set<String> = []
    for acct in kids(dir) {
        for org in kids(acct) {
            for url in records(org) {
                let key = url.path
                let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                seen.insert(key)
                if let entry = cache.files[key], entry.stamp == stamp {
                    if let hit = entry.hit {
                        if let prev = stamps[hit.sid], prev > stamp { continue }
                        stamps[hit.sid] = stamp
                        out[hit.sid] = hit.title
                    }
                    continue
                }
                guard let data = try? Data(contentsOf: url),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let sid = obj["cliSessionId"] as? String,
                      let raw = obj["title"] as? String else {
                    cache.files[key] = TitleEntry(stamp: stamp, hit: nil)
                    continue
                }
                let title = cleanName(raw)
                guard !title.isEmpty else {
                    cache.files[key] = TitleEntry(stamp: stamp, hit: nil)
                    continue
                }
                cache.files[key] = TitleEntry(stamp: stamp, hit: (sid: sid, title: title))
                if let prev = stamps[sid], prev > stamp { continue }
                stamps[sid] = stamp
                out[sid] = title
            }
        }
    }
    // A record the app deleted must not keep answering from memory. The listing
    // cache needs no prune: a removal moves the directory's mtime, so its entry
    // is replaced on the very next poll rather than going stale.
    cache.files = cache.files.filter { seen.contains($0.key) }
    return out
}

// A session's identity, most specific first: the title the desktop app shows
// for it, then the name the CLI keeps for it, then the project directory, then
// its raw id — deliberately unfriendly, because a session with none of the
// three is a real state and a made-up name would hide it.
//
// The title outranks the name rather than backstopping it because every
// interactive session is given a `derived` registry name, so a name always
// answers and a title placed below it could never be reached.
func sessionName(_ r: SessionRow) -> String {
    if let t = r.title, !t.isEmpty { return t }
    if let n = r.name, !n.isEmpty { return n }
    // isDirectory:true is a lie the path is never asked to prove — it skips a
    // filesystem stat that would otherwise run on every poll-loop comparator
    // call and block the main-thread Timer if cwd sits on an unresponsive mount.
    return r.cwd.map { URL(fileURLWithPath: $0, isDirectory: true).lastPathComponent }
        ?? String(r.sid.prefix(8))
}

// What the human sees, which is not what the fold sees: `manual` is a bridge
// for launches with no session behind them, so it holds a refcount but is not
// a session and must not be listed as one. Most attention-worthy first, so the
// row that wants you is the row under the cursor.
func menuRows(_ rows: [SessionRow]) -> [SessionRow] {
    rows.filter { $0.sid != "manual" }.sorted {
        let (a, b) = (moodRank[$0.mood]!, moodRank[$1.mood]!)
        if a != b { return a > b }
        let (na, nb) = (sessionName($0), sessionName($1))
        if na != nb { return na < nb }
        return $0.sid < $1.sid
    }
}

// What the tray and the bubble actually print. It takes the whole set rather
// than one row because the suffix exists for exactly one purpose: telling two
// identical names apart. Which rows collide is not knowable from any single one.
//
// Fed the MENU rows, after `manual` is gone — a bridge row that is never drawn
// must not be able to push a real row into wearing a suffix.
//
// The separator is a middle dot and must stay one. `sessionTitle` and
// `statusLine` both join a label to a status with an em dash, and a second one
// makes the line stutter — the same rule that bans em dashes from the mood
// wording table.
func sessionLabels(_ rows: [SessionRow]) -> [String: String] {
    var counts: [String: Int] = [:]
    for r in rows { counts[sessionName(r), default: 0] += 1 }
    var out: [String: String] = [:]
    for r in rows {
        let name = sessionName(r), short = String(r.sid.prefix(8))
        // A label that already IS the id prefix would double into "abc · abc".
        out[r.sid] = counts[name]! > 1 && name != short ? "\(name) · \(short)" : name
    }
    return out
}

// `status` is passed rather than read off the global so the wording under test
// is not whatever language the machine happens to be set to. The label is passed
// for the same reason and one more: resolving it needs the whole row set, which
// a single row cannot see.
func sessionTitle(_ label: String, _ mood: Mood, _ status: [Mood: String]) -> String {
    guard let s = status[mood], !s.isEmpty else { return label }
    return "\(label) — \(s)"
}

// What the bubble says, and whose it is. A free function taking the wording
// table for the same reason `sessionTitle` does: the real table is chosen from
// `Locale.preferredLanguages`, so anything asserting against the global passes
// or fails by machine rather than by behaviour.
//
// `rows` is the menu's already-sorted list, so its head is the session the face
// is reporting — the fold and the caption cannot pick different sessions, which
// is the whole point. The name appears only when there is something to
// disambiguate; with one session there is nothing to tell it apart from, so it
// stays hidden whatever `sessionName` would have returned for it.
//
// `labels` is `sessionLabels(rows)` from that same poll, not recomputed in
// here: the label table and the row list are assigned together in one
// `pollMoods` pass so the tray can never be naming a session the face has
// already moved past.
//
// `display` is passed rather than taken from the head because it can come from
// the `state` puppet file, which has no row behind it.
//
// Composition of the name and the status is NOT done here. It needs measured
// widths to decide what to truncate, and fonts belong to the view.
func bubbleText(_ rows: [SessionRow], _ display: Mood, _ globalSay: String,
                _ wording: [Mood: String],
                _ labels: [String: String]) -> (name: String?, status: String, prompt: String) {
    guard let top = rows.first else {
        return (nil, wording[display] ?? "", globalSay)
    }
    // `labels` and `rows` both come from the same `pollMoods` pass (see the
    // comment above), so `labels[top.sid]` cannot be missing — the `??` is a
    // correct-value fallback, not a guard against a case that can happen.
    return (rows.count > 1 ? labels[top.sid] ?? sessionName(top) : nil,
            wording[top.mood] ?? "",
            top.say ?? globalSay)
}

let BUB_W: CGFloat = 260, BUB_H: CGFloat = 54, BUB_BODY: CGFloat = 52

// The bubble and the chip are the only surfaces that sit over the user's
// desktop rather than over the pet, so they are the only place the flat palette
// is used with alpha. A translucent dark panel stops the chrome competing with
// the creature for attention on a busy wallpaper, where a cream slab read as a
// second, larger pet. Both windows are already non-opaque with a clear
// background, so this needs nothing from the window layer.
//
// This is a TINT over the blur, not the panel itself, which is why it is so
// much lighter than the 0.78 a blur-less version needed: the frost supplies the
// darkening and the legibility, and this only pulls the neutral grey toward the
// pet's warm brown. Raise it and the blur stops being visible at all.
let CHROME_TINT: CGFloat = 0.38
let CHIP: CGFloat = 26

// One control with two jobs: the count of what happened while you were not
// looking, and the handle that folds the bubble away. It gets its own window
// because `ignoresMouseEvents` is per-window — hanging a button off the bubble
// would cost the whole 260-point rect the click-through that is the point of
// a bubble you can leave on screen.
final class ChipView: NSVisualEffectView {
    // The frost is the CONTAINER and the drawing is a subview. A view's own
    // draw() runs before all of its subviews, so vibrancy added underneath the
    // painter lands on top of the chevron and the button turns into a grey
    // disc — which is exactly what the offscreen render showed. Apple's
    // guidance points the same way: compose NSVisualEffectView with subviews
    // rather than override its drawing.
    private final class Face: NSView {
        var count = 0
        var collapsed = false

        override var isFlipped: Bool { true }
        // Clicks belong to the container, which is what carries onTap.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.clear.setFill()
            dirtyRect.fill()
            let disc = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: CHIP - 4, height: CHIP - 4))
            // A tint over the frost, in one transparency layer so the disc does
            // not double up with anything drawn after it. Unread is carried by
            // the numeral's color rather than by flooding the disc: a coral
            // disc beside a dark bubble read as a detached second creature.
            let gc = NSGraphicsContext.current!.cgContext
            gc.setAlpha(CHROME_TINT)
            gc.beginTransparencyLayer(auxiliaryInfo: nil)
            CHROME_PANEL.setFill()
            disc.fill()
            gc.endTransparencyLayer()
            gc.setAlpha(1)
            CHROME_EDGE.setStroke()
            disc.lineWidth = 2.5
            disc.stroke()
            if count > 0 {
                // Two glyphs is the whole budget at this size; past nine the
                // exact number stops being the point anyway.
                let s = count > 9 ? "9+" : "\(count)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: count > 9 ? 10 : 12, weight: .bold),
                    // Amber on the dark disc — the pet's own attention ink, and
                    // the only thing on this 26-point surface that has to carry.
                    .foregroundColor: CHROME_TEXT,
                ]
                let sz = (s as NSString).size(withAttributes: attrs)
                (s as NSString).draw(at: NSPoint(x: (CHIP - sz.width) / 2, y: (CHIP - sz.height) / 2), withAttributes: attrs)
            } else {
                // The chevron points where the bubble is going, not where it is.
                let mid = CHIP / 2, w: CGFloat = 4.5, h: CGFloat = 2.5
                let apex = collapsed ? mid - h : mid + h, base = collapsed ? mid + h : mid - h
                let p = NSBezierPath()
                p.move(to: NSPoint(x: mid - w, y: base))
                p.line(to: NSPoint(x: mid, y: apex))
                p.line(to: NSPoint(x: mid + w, y: base))
                CHROME_INK.setStroke()
                p.lineWidth = 2.5
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                p.stroke()
            }
        }
    }

    private let face = Face()
    var count = 0 { didSet { if count != oldValue { face.count = count; face.needsDisplay = true } } }
    var collapsed = false { didSet { if collapsed != oldValue { face.collapsed = collapsed; face.needsDisplay = true } } }
    var onTap: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        // Pinned dark rather than following the system: this sits on the user's
        // wallpaper, not inside an app window, so "light mode" says nothing
        // about what is behind it. Following it turns the disc white and the
        // cream chevron disappears.
        appearance = NSAppearance(named: .darkAqua)
        // A disc, matching the drawn stroke — a square of frost behind a round
        // button is the same bug the bubble's tail mask exists to avoid.
        maskImage = NSImage(size: NSSize(width: CHIP, height: CHIP), flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: CHIP - 4, height: CHIP - 4)).fill()
            return true
        }
        face.frame = bounds
        face.autoresizingMask = [.width, .height]
        addSubview(face)
    }

    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onTap?() }
}

final class BubbleView: NSVisualEffectView {
    // Same shape as ChipView and for the same reason: the frost is the
    // container, the drawing is a subview. A view draws before its subviews, so
    // vibrancy added under the painter covers the text.
    private final class Panel: NSView {
        // draw() is a pure function of these three and nothing else — no tick,
        // no clock, no cursor, and a palette that never varies — so repainting
        // on a real change is both necessary and sufficient. The poll loop used
        // to mark the bubble dirty twenty times a second for content that
        // changes a few times a turn, and text is the expensive thing here.
        // The status arrives already chosen. Deriving it here from a mood and the
        // global wording table would mean the rule under test and the rule on
        // screen are two pieces of code that merely agree today.
        var status: String = "" { didSet { if status != oldValue { needsDisplay = true } } }
        var name: String? = nil { didSet { if name != oldValue { needsDisplay = true } } }
        var prompt: String = "" { didSet { if prompt != oldValue { needsDisplay = true } } }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // The status is the part that must never vanish, so the NAME gets
        // whatever room is left after it and the separator — not the other way
        // round, and not a character budget. A character count is not a width:
        // the line holds about 34 monospace advances, the longest shipped status
        // is "waiting for you…" at 16, and a name in CJK spends two advances per
        // character.
        private func statusLine(_ attrs: [NSAttributedString.Key: Any], _ maxW: CGFloat) -> String {
            guard let n = name, !n.isEmpty else { return status }
            let sep = " — "
            let tail = ("\(sep)\(status)" as NSString).size(withAttributes: attrs).width
            return "\(truncate(n, attrs, max(0, maxW - tail)))\(sep)\(status)"
        }

        private func truncate(_ s: String, _ attrs: [NSAttributedString.Key: Any], _ maxW: CGFloat) -> String {
            var t = s
            if (t as NSString).size(withAttributes: attrs).width <= maxW { return t }
            while !t.isEmpty && ("\(t)…" as NSString).size(withAttributes: attrs).width > maxW {
                t = String(t.dropLast())
            }
            return "\(t)…"
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.clear.setFill()
            dirtyRect.fill()
            let bg = CHROME_PANEL, line = CHROME_EDGE, textColor = CHROME_INK

            let body = BubbleView.bodyPath()
            // The blur underneath already darkens; this is a tint on top of it,
            // which is why it is far lighter than the alpha a blur-less panel
            // needed. It exists at all because `.hudWindow` is a neutral grey
            // and the pet is warm — untinted, the chrome reads as borrowed
            // system UI parked beside the creature rather than as part of it.
            //
            // One transparency layer, composited once. Filling each piece at
            // alpha instead stacks the tail's overlap with the body into a
            // darker seam — an artifact that does not exist while the fills are
            // opaque. Text stays outside it: a translucent glyph is unreadable
            // at 11pt.
            let gc = NSGraphicsContext.current!.cgContext
            gc.setAlpha(CHROME_TINT)
            gc.beginTransparencyLayer(auxiliaryInfo: nil)
            bg.setFill(); body.fill()
            gc.endTransparencyLayer()
            gc.setAlpha(1)
            // The outline is opaque and outside the layer: it is the edge that
            // makes this a pixel bubble rather than a system panel, and at 3pt
            // a translucent one just muddies into the blur.
            line.setStroke(); body.lineWidth = 3; body.stroke()

            let promptAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: textColor,
            ]
            let statusAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: textColor.withAlphaComponent(0.72),
            ]
            let maxW = BUB_W - 32
            if prompt.isEmpty {
                (truncate(statusLine(statusAttrs, maxW), statusAttrs, maxW) as NSString)
                    .draw(at: NSPoint(x: 16, y: 19), withAttributes: statusAttrs)
            } else {
                (truncate(prompt, promptAttrs, maxW) as NSString)
                    .draw(at: NSPoint(x: 16, y: 9), withAttributes: promptAttrs)
                (truncate(statusLine(statusAttrs, maxW), statusAttrs, maxW) as NSString)
                    .draw(at: NSPoint(x: 16, y: 28), withAttributes: statusAttrs)
            }
        }
    }

    private let panel = Panel()

    var status: String = "" { didSet { panel.status = status } }
    var name: String? = nil { didSet { panel.name = name } }
    var prompt: String = "" { didSet { panel.prompt = prompt } }
    static func bodyPath() -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: BUB_W - 4, height: BUB_BODY - 2),
                     xRadius: 7, yRadius: 7)
    }

    // Vibrancy has no notion of a shape: unmasked, the whole rect frosts over,
    // rounded corners included, and the bubble becomes a slab. Fixed now that
    // the tail is gone — the mask used to be rebuilt every time the tail
    // chased the pet's midline. Drawn flipped to match the panel, because
    // NSImage's origin is bottom-left and every coordinate here is top-down.
    private static let mask = NSImage(size: NSSize(width: BUB_W, height: BUB_H), flipped: true) { _ in
        NSColor.black.setFill()
        BubbleView.bodyPath().fill()
        return true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        // Pinned dark rather than following the system: the chrome sits on the
        // user's wallpaper, not inside an app window, so "light mode" is not a
        // statement about what is behind it. Letting it follow turns the panel
        // white on a light desktop and the cream text vanishes.
        appearance = NSAppearance(named: .darkAqua)
        maskImage = BubbleView.mask
        panel.frame = bounds
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)
    }

    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }
}

// Where the three pieces sit. A pure function of the pet's frame and where its
// art actually starts, so the offscreen harness composes the same rects the
// Controller does rather than a second guess at them.
//
// Bubble and chip share one horizontal band above the pet and never overlap:
// they are separate windows, and two frosted panels crossing would double the
// tint exactly where they meet. That is also why the chip no longer perches on
// the pet's shoulder — with the bubble brought down to meet the art there is
// no shoulder left to perch on.
struct ChromeLayout {
    let bubble: NSPoint
    let chip: NSPoint
}

let CHROME_GAP: CGFloat = 4

func chromeLayout(pet: NSRect, artTop: CGFloat, screen: NSRect?) -> ChromeLayout {
    // Everything hangs off where the ink starts, not off the canvas edge.
    let head = pet.maxY - artTop
    // Beside the top of the head, biting 10 points into the window so most of
    // it clears the art — the same corner perch it has always had, now aimed
    // at the head rather than at the canvas corner above it.
    var cx = pet.maxX - 10
    var cy = head - CHIP
    if let s = screen {
        cx = min(cx, s.maxX - CHIP)
        cy = max(cy, s.minY + CHROME_GAP)
    }
    // Right edges flush with the chip's, so the two stack on one axis instead
    // of the bubble ending 16 points short of the thing under it. Derived from
    // the CLAMPED chip, or a pet shoved against the screen edge moves the chip
    // and leaves the bubble behind — the one case where the alignment this
    // exists for is the first thing to break.
    var x = cx + CHIP - BUB_W
    let y = head + CHROME_GAP
    if let s = screen { x = max(x, s.minX + CHROME_GAP) }
    return ChromeLayout(bubble: NSPoint(x: x, y: y), chip: NSPoint(x: cx, y: cy))
}

final class Controller: NSObject, NSWindowDelegate {
    let window: NSWindow
    let view: PetView
    let bubble: NSWindow
    let bubbleView: BubbleView
    let chip: NSWindow
    let chipView: ChipView
    let root: URL
    let stateURL: URL
    let sessionsURL: URL
    let ownersURL: URL
    // The host CLI's session registry. Not under `root`: it belongs to the CLI,
    // and PERCHLING_HOME may point at a directory that has no registry in it.
    let registryURL: URL
    // The desktop app's session records. Resolved from the user's home rather
    // than from `root`, for the same reason the registry is.
    let titlesURL: URL
    // Survives across polls on purpose: see TitleEntry.
    var titleCache = TitleCache()
    let sayURL: URL
    let petURL: URL
    var lastSayStamp: Date?
    // The global say is only a fallback now, for a new binary running against an
    // installed state.sh that does not write line 3 yet.
    var globalSay = ""
    var lastPetStamp: Date?
    var emptySince: Date?
    var homeApp: NSRunningApplication?
    var firstFold = true
    var tucked = false
    var lastOwners: Set<pid_t> = []
    var unread = 0
    var collapsed = UserDefaults.standard.bool(forKey: "bubbleCollapsed")
    var lastChip: (Bool, Int, Bool)?
    var lastInputMoods: [String: Mood] = [:]
    // Refreshed by pollMoods every 0.4s; the menu renders whatever the last
    // poll left here. NSMenu tracking runs its own run-loop mode, so an open
    // menu shows the snapshot it opened with — the same as the Pets submenu.
    var sessionRows: [SessionRow] = []
    // Resolved with sessionRows, in the same poll: a label taken from one poll
    // and a row from the next can disagree about which session is which.
    var sessionLabelsBySid: [String: String] = [:]

    init(root: URL, registry: URL, titles: URL) {
        self.root = root
        registryURL = registry
        titlesURL = titles
        stateURL = root.appendingPathComponent("state")
        sessionsURL = root.appendingPathComponent("sessions")
        ownersURL = root.appendingPathComponent("owners")
        sayURL = root.appendingPathComponent("say")
        petURL = root.appendingPathComponent("pet.json")
        // Before anything can link over it. A no-op on every install that has
        // already been through it once. A rescue that cannot finish is not
        // fatal here — the loose file is still where it was, and the menu
        // refuses to remove one it could not rescue — so launch carries on.
        try? migrateLoosePet(root: root)
        let bubSize = NSSize(width: BUB_W, height: BUB_H)
        bubble = NSWindow(contentRect: NSRect(origin: .zero, size: bubSize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        bubbleView = BubbleView(frame: NSRect(origin: .zero, size: bubSize))
        let chipSize = NSSize(width: CHIP, height: CHIP)
        chip = NSWindow(contentRect: NSRect(origin: .zero, size: chipSize),
                        styleMask: [.borderless], backing: .buffered, defer: false)
        chipView = ChipView(frame: NSRect(origin: .zero, size: chipSize))
        let size = canvasSize(builtinPet.width, builtinPet.height, builtinPet.scale)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        view = PetView(frame: NSRect(origin: .zero, size: size))
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = view
        window.delegate = self
        window.ignoresMouseEvents = false

        let d = UserDefaults.standard
        if d.object(forKey: "petX") != nil {
            window.setFrameOrigin(NSPoint(x: d.double(forKey: "petX"), y: d.double(forKey: "petY")))
        }

        // Speech bubble rides along as a click-through child window — growing
        // the pet window instead would leave an invisible click-eating strip.
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.hasShadow = false
        bubble.level = .floating
        bubble.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        bubble.ignoresMouseEvents = true
        bubble.contentView = bubbleView
        window.addChildWindow(bubble, ordered: .above)
        repositionBubble()

        // The chip is the one piece of chrome that has to take a click, so it
        // is the one window that does not ignore mouse events.
        chip.isOpaque = false
        chip.backgroundColor = .clear
        chip.hasShadow = false
        chip.level = .floating
        chip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        chip.contentView = chipView
        window.addChildWindow(chip, ordered: .above)

        // "Home" is where a tap sends the user: Claude desktop when present,
        // else whatever was frontmost at launch (terminal-CLI users).
        homeApp = Controller.resolveHomeApp()
        view.onTap = { [weak self] in self?.focusHome() }
        chipView.onTap = { [weak self] in self?.toggleBubble() }
        view.onTuck = { [weak self] in self?.setTucked(true) }
        view.onDisable = { [weak self] in self?.disableAndQuit() }
        view.petList = { [unowned self] in
            petChoices(root: self.root, examples: examplesRoot)
        }
        view.sessionList = { [unowned self] in self.sessionRows }
        view.labelList = { [unowned self] in self.sessionLabelsBySid }
        view.onPickPet = { [unowned self] choice in
            do {
                if let c = choice {
                    let target = c.shipped ? try adoptShippedPet(c.url, root: self.root) : c.url
                    try activatePet(target, root: self.root)
                } else {
                    try useBuiltIn(root: self.root)
                }
            } catch {
                NSSound.beep()
                return
            }
            // pollPet skips when the stamp is unchanged, and two pets can share
            // an mtime. distantPast differs from both a real date and the nil a
            // removed pet.json produces, so either outcome repaints.
            self.lastPetStamp = Date.distantPast
            self.pollPet()
        }

        // Load the pet before the first placement: the corner gap has to be
        // measured against the window the custom pet ends up needing, not the
        // built-in size the window was constructed with.
        pollPet()
        if d.object(forKey: "petX") == nil, let screen = NSScreen.main {
            let f = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.maxX - window.frame.width - 24, y: f.minY + 24))
            repositionBubble()
        }
        window.orderFrontRegardless()
        applyChrome()
    }

    // pet.json IS the active pet: present and valid → custom sprite; broken
    // or missing → built-in perchling. Falling back on a bad parse (instead
    // of keeping the last good pet) makes authoring mistakes visible the
    // moment the file lands, which is what the live edit loop needs.
    func pollPet() {
        // Stat the resolved path: a dotfiles setup symlinks pet.json, and
        // neither attributesOfItem nor URL resource values follow a trailing
        // symlink — they report the link's own mtime, which never changes
        // when the target is edited.
        let resolved = petURL.resolvingSymlinksInPath()
        let stamp = (try? FileManager.default.attributesOfItem(atPath: resolved.path))?[.modificationDate] as? Date
        guard stamp != lastPetStamp else { return }
        lastPetStamp = stamp
        let pet = stamp == nil ? nil : (try? loadCustomPet(resolved))
        view.custom = pet
        // `custom` stays nil-when-absent even though something is always drawn:
        // the Pets menu's checkmark means "this is what you are looking at", and
        // the built-in row can only answer that while "no user pet" is still
        // representable. Geometry asks `activePet`, which resolves the fallback.
        let shown = pet ?? builtinPet
        view.scale = shown.scale
        let s = shown.scale
        view.xpad = sidePad(s)
        view.spriteGen += 1
        let size = canvasSize(shown.width, shown.height, s)
        if window.frame.size != size {
            // setContentSize pins the bottom-left corner, so a wider pet grows
            // off the right edge — where this thing lives by default.
            window.setContentSize(size)
            if let screen = window.screen ?? NSScreen.main {
                let vf = screen.visibleFrame, f = window.frame
                let x = min(max(f.minX, vf.minX), vf.maxX - f.width)
                let y = min(max(f.minY, vf.minY), vf.maxY - f.height)
                if x != f.minX || y != f.minY { window.setFrameOrigin(NSPoint(x: x, y: y)) }
            }
            repositionBubble()
        }
    }

    func setTucked(_ t: Bool) {
        tucked = t
        if t {
            window.removeChildWindow(bubble)
            bubble.orderOut(nil)
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
        applyChrome()
    }

    func disableAndQuit() {
        FileManager.default.createFile(atPath: root.appendingPathComponent("disabled").path, contents: nil)
        NSApp.terminate(nil)
    }

    func repositionBubble() {
        let l = chromeLayout(pet: window.frame, artTop: view.artTopInset,
                             screen: (window.screen ?? NSScreen.main)?.visibleFrame)
        bubble.setFrameOrigin(l.bubble)
        chip.setFrameOrigin(l.chip)
    }

    // Bubble and chip stay up through idle. They used to fold away with the
    // mood, on the theory that an idle pet keeps the desktop clean; the cost
    // was that the one control for the bubble vanished exactly when the bubble
    // was quiet enough to be in the way. Tuck is the control for "gone".
    func applyChrome() {
        let wanted = !tucked
        let state = (wanted, unread, collapsed)
        guard lastChip == nil || lastChip! != state else { return }
        lastChip = state
        chipView.count = unread
        chipView.collapsed = collapsed
        chipView.needsDisplay = true
        if wanted { chip.orderFrontRegardless() } else { chip.orderOut(nil) }
        if tucked || collapsed {
            bubble.orderOut(nil)
        } else {
            window.addChildWindow(bubble, ordered: .above)
            repositionBubble()
        }
    }

    func toggleBubble() {
        collapsed.toggle()
        UserDefaults.standard.set(collapsed, forKey: "bubbleCollapsed")
        // Opening it is the act of reading it.
        if !collapsed { unread = 0 }
        applyChrome()
    }

    // "Not looking" is the same judgement the away-notification makes, and the
    // unread count has to agree with it or the two tell different stories.
    var userIsLooking: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.bundleIdentifier == homeApp?.bundleIdentifier || front.bundleIdentifier == claudeBundleID
    }

    static func resolveHomeApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first
            ?? NSWorkspace.shared.frontmostApplication
    }

    func focusHome() {
        if homeApp == nil || homeApp?.isTerminated == true {
            // Never re-resolve from frontmost-at-tap — that's whatever the user
            // is in right now, or perchling itself, and it would be cached
            // forever. Claude first, else a relaunched instance of the old home.
            let oldID = homeApp?.bundleIdentifier
            homeApp = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first
                ?? oldID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        }
        guard let target = homeApp else { return }
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: target)
            target.activate()
        } else {
            target.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func maybeRemind(_ mood: Mood) {
        let messages: [Mood: String] = [
            .waiting: "Claude Code needs your input",
            .done: "Claude Code finished",
            .error: "Claude Code hit an error",
        ]
        guard let msg = messages[mood] else { return }
        // Quiet when the user is already looking at the home app — or at
        // Claude desktop, even one opened after we resolved home.
        guard !userIsLooking else { return }
        // Same event, two ways of surviving your absence: one notification you
        // may miss, one count that waits on the pet until you come back.
        unread += 1
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(msg)\" with title \"Perchling\" sound name \"Glass\""]
        p.terminationHandler = { _ in }   // keeps p alive until exit so the child is reaped
        try? p.run()
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(Double(window.frame.origin.x), forKey: "petX")
        UserDefaults.standard.set(Double(window.frame.origin.y), forKey: "petY")
        repositionBubble()
    }

    func pollSay() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: sayURL.path),
              let stamp = attrs[.modificationDate] as? Date, stamp != lastSayStamp else { return }
        lastSayStamp = stamp
        let data = (try? Data(contentsOf: sayURL)) ?? Data()
        var s = String(decoding: data, as: UTF8.self)
        // The snippet is lifted verbatim out of JSON, so it still carries the
        // escapes: newlines become spaces, and a quoted phrase should read as
        // a quoted phrase rather than a backslash storm.
        s = s.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\t", with: " ")
        s = s.replacingOccurrences(of: "\\\"", with: "\"")
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        globalSay = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Inputs: every live session file (mood as content) plus the plain state
    // file (manual override / single-session fast path). Each input decays to
    // idle past its mood's TTL; the highest-priority survivor is DISPLAYED.
    // Reminders instead key off each input's own transitions — a fold maximum
    // can't represent per-session events, and one session resting at waiting
    // must not swallow another session's "finished" notification.
    func pollMoods() -> (display: Mood, entered: Set<Mood>) {
        let fm = FileManager.default
        let now = Date()
        var inputs: [(String, Mood)] = []
        if let attrs = try? fm.attributesOfItem(atPath: stateURL.path),
           let stamp = attrs[.modificationDate] as? Date,
           let raw = try? String(contentsOf: stateURL, encoding: .utf8) {
            let m = Mood.parse(raw)
            // The state file has no owner to clean it up on session end, so it
            // gets a short leash: enough for manual puppeteering, too short to
            // haunt the fold as a dead session's ghost.
            let ttl = min(moodTTL[m] ?? 0, 300)
            inputs.append(("state", now.timeIntervalSince(stamp) > ttl ? .idle : m))
        }
        // One read, two consumers. `manual` stays in the fold — it is the
        // refcount that holds an idle pet up — and is dropped from the rows.
        let live = liveSessions(sessionsURL, now: now, alive: ownerAlive,
                                names: registryNames(registryURL, alive: alive),
                                titles: desktopTitles(titlesURL, cache: &titleCache))
        sessionRows = menuRows(live)
        sessionLabelsBySid = sessionLabels(sessionRows)
        inputs.append(contentsOf: live.map { ($0.sid, $0.mood) })

        var display = Mood.idle
        var current: [String: Mood] = [:]
        var entered: Set<Mood> = []
        for (key, m) in inputs {
            current[key] = m
            if moodRank[m]! > moodRank[display]! { display = m }
            let prev = lastInputMoods[key] ?? .idle
            if m != prev, m == .waiting || m == .done || m == .error {
                entered.insert(m)
            }
        }
        lastInputMoods = current
        return (display, entered)
    }

    // A session's owner is the outermost process it hangs off: the desktop app
    // for a session started there, the terminal for one started from a shell.
    // Killing that process fires no SessionEnd, so the refcount would stand
    // until it went stale an hour later; asking whether the owner still exists
    // retires it in a single poll. A session with no owner file — one that
    // predates the mechanism, or a process tree pet.sh could not walk — falls
    // back to staleness rather than being declared dead on missing evidence.
    func ownerPid(_ sid: String) -> pid_t? {
        guard let raw = try? String(contentsOf: ownersURL.appendingPathComponent(sid), encoding: .utf8) else { return nil }
        return pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    // A session with no owner file is unknown, never dead.
    func ownerAlive(_ sid: String) -> Bool { ownerPid(sid).map(alive) ?? true }

    // `retired` is the difference between having nothing to report and having
    // nobody left to report it — refcounts orphaned by an owner that died, or
    // an empty directory that the last owners emptied on their way out.
    func pollSessions() -> (live: Bool, retired: Bool) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        let items = (try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var live = false, retired = false
        var owners: Set<pid_t> = []
        for url in items {
            if let pid = ownerPid(url.lastPathComponent) {
                guard alive(pid) else { retired = true; continue }
                owners.insert(pid)
            }
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (d ?? .distantPast) > cutoff { live = true }
        }
        if !owners.isEmpty { lastOwners = owners }
        // A clean quit takes its refcounts with it, so the directory empties
        // exactly the way a session restart empties it. What tells them apart
        // is whether anyone who could start the next session is still running.
        if !live, !lastOwners.isEmpty, !lastOwners.contains(where: alive) { retired = true }
        return (live, retired)
    }

    func run() {
        var clock = 0
        Timer.scheduledTimer(withTimeInterval: Double(TICK_MS) / 1000.0, repeats: true) { [self] _ in
            clock += 1
            // Reduce Motion freezes the animation clock (static pose), never
            // the polling clock — liveness and mood changes must keep working.
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                view.tick += 1
                view.decayLean()
            }
            if clock % 8 == 0 {
                // Manual un-tuck: a tucked pet has no window to right-click,
                // so `pet.sh wake` drops a flag file for us to find.
                let wakeURL = root.appendingPathComponent("wake")
                if FileManager.default.fileExists(atPath: wakeURL.path) {
                    try? FileManager.default.removeItem(at: wakeURL)
                    if tucked { setTucked(false) }
                }
                let (next, entered) = pollMoods()
                let becameDone = next != view.mood && next == .done
                if next != view.mood { view.mood = next }
                // A burst on every arrival, not only the display transition:
                // a second session finishing while done is already on screen
                // must not be swallowed, so this follows `entered` the same
                // way the reminder path below does.
                // Not armed for a pet whose `done` is a sequence: those frames
                // are already the celebration, and a hop under them stacks a
                // lift on a lift. A tap still hops it — that one is a reply to
                // the user, where this one is the pet cheering by itself.
                if (becameDone || entered.contains(.done)) && next == .done && view.motionOK
                    && view.activePet.sequence(for: .done) == nil {
                    view.hopUntil = view.tick + 12
                }
                // Reminders and tuck-wake follow per-input events, not the
                // (possibly masked) display transition.
                if !firstFold, let alert = entered.max(by: { moodRank[$0]! < moodRank[$1]! }) {
                    maybeRemind(alert)
                    if tucked && (alert == .waiting || alert == .error) { setTucked(false) }
                }
                firstFold = false
                // Coming back to Claude is reading the news, whether or not
                // the bubble was ever opened.
                if unread > 0 && userIsLooking { unread = 0 }
                applyChrome()
                pollPet()
                pollSay()
                // A prompt snippet from hours ago is noise, not context.
                if let s = lastSayStamp, Date().timeIntervalSince(s) > 3600 { globalSay = "" }
                // One place decides all three, after both inputs have been
                // refreshed: a caption taken from one poll and a name from the
                // next would name the wrong session for a tick.
                let t = bubbleText(sessionRows, view.mood, globalSay, moodStatus,
                                   sessionLabelsBySid)
                bubbleView.name = t.name
                bubbleView.status = t.status
                bubbleView.prompt = t.prompt
                // The grace period rides out the gap between one session
                // ending and the next starting — a resume, a /clear, a new
                // window. Nothing can arrive to fill that gap once every owner
                // is gone, so waiting on it is waiting for nothing.
                let sessions = pollSessions()
                if sessions.live {
                    emptySince = nil
                } else if sessions.retired {
                    NSApp.terminate(nil)
                } else {
                    if emptySince == nil { emptySince = Date() }
                    if Date().timeIntervalSince(emptySince!) > 30 { NSApp.terminate(nil) }
                }
            }
            view.repaintIfChanged()
        }
    }
}

// The built-in pet, carried as a manifest rather than as drawing code. It goes
// through the same loader a user's pet.json does, so every rule that parser
// enforces holds for the shipped pet too, and `--export` can hand the text back
// verbatim instead of reconstructing it from pixels.
//
// The consequence to know before reading `PetView`: `custom` is now never nil.
// There is no second art path left, so the behaviours that used to key off
// `custom == nil` — the hover startle, error's tear, done's sparkle, idle's
// doze-and-peek, cursor gaze and the blink — are gone rather than dormant.
// They come back as declared `sequences`, not as branches.
let BUILTIN_MANIFEST = #"""
{
  "eyes" : {
    "box" : [
      26,
      11,
      44,
      17
    ],
    "lid" : "o",
    "range" : 0,
    "socket" : "b"
  },
  "moods" : {
    "done" : [
      "................................................................................................",
      "................................................................................................",
      "................................................................................................",
      ".........................ooooo....................................ooooo.........................",
      ".......................oollllloo.......oooooooooooooooooo.......oollllloo.......................",
      "......................olllllllllo..oooolllllllllllllllllloooo..olllllllllo......................",
      "......................ollbbbbbllooollllllllllllllllllllllllllooollbbbbbllo......................",
      "......................ollbbbbbsoollllllbbbbbbbbbbbbbbbbbblllllloolbbbbbsso......................",
      ".....................ollbbbbboollllbbbbbbbbbbbbbbbbbbbbbbbbbblllloobbbbbsso.....................",
      "......................ollbbbollllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllllobbbsso......................",
      ".............o........ollbbolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllobbsso........o.............",
      ".............o........ollsollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllossso........o.............",
      "............ogo........oolollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslosoo........ogo............",
      "..........oogggoo........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo........oogggoo..........",
      "............ogo..........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..........ogo............",
      ".............o..........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo..........o.............",
      ".............o..........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..........o.............",
      "........................ollbbbbbbboooobbbbbbbbbbbbbbbbbbbbboooobbbbbbsso........................",
      ".......................ollbbbbbgggeeeeooobbbbbbbbbbbbbbbgggeeeeooobbbbsso.......................",
      ".......................ollbbboggggeeeeeeeoobbbbbbbbbbboggggeeeeeeeoobbsso.......................",
      ".......................ollbboeggggeeeeeeeeeobbbbbbbbboeggggeeeeeeeeeobsso.......................",
      ".......................ollboeeeeeeeeeeeeeeeeobbbbbbboeeeeeeeeeeeeeeeeosso.......................",
      ".......................ollboeeeeeeeeeeeeeeeeobbbbbbboeeeeeeeeeeeeeeeeosso.......................",
      ".......................ollboeeeeeeooooeeeeeeobbbbbbboeeeeeeooooeeeeeeosso.......................",
      ".......................ollboeeeooobbbboooeeeobbbbbbboeeeooobbbboooeeeosso.......................",
      ".......................ollboeoobbbbbbbbbbooeobbbbbbboeoobbbbbbbbbbooeosso.......................",
      "......................ollbboobbbbbbbbbbbbbboobbbbbbboobbbbbbbbbbbbbboobsso......................",
      ".....................ollbbbobbbbbbbbbbbbbbbbobbbbbbbobbbbbbbbbbbbbbbbobbslo.....................",
      "....................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo....................",
      "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...................",
      "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo..................",
      ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.................",
      ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.................",
      "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo................",
      "................ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooooobbbbbsso................",
      "................ollbbbboosssssssssssssssssssssssssssssssssssssssssssssssoobbbsso................",
      "...............ollbbbbosssssssocccossssssssssssssssssssssssssocccossssssssobbbsso...............",
      "...............ollbbbosssssssocccccossssssssssssssssssssssssocccccossssssssobbsso...............",
      "...............ollbbosssssssocccccccossssssssssssssssssssssocccccccossssssssobsso...............",
      "...............ollbbosssssssocccccccossssssssssssssssssssssocccccccossssssssobsso...............",
      "...............ollbossssssssocccccccossssssssssssssssssssssocccccccosssssssssosso...............",
      "...............ollbosssssssssocccccossssssssssssssssssssssssocccccossssssssssosso...............",
      "...............ollbossssssssssooooossssssssssssssssssssssssssooooosssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssssobsso...............",
      "................ollccccccccssssssssssssssssssssssssssssssssssssssssssscccccccsso................",
      "................ollccccccccccssssssssssssssssssssssssssssssssssssssscccccccccsso................",
      "................ollbccccccccccccssssssssssssssssssssssssssssssssscccccccccccbsso................",
      ".................ollsssssssccccccccsssssssssssssssssssssssssssccccccccsssssssso.................",
      ".................ollbsssssssscccccccccccssssssssssssssssscccccccccccsssssssbsso.................",
      "..................ollbsssssssssscccccccccccccccccccccccccccccccccsssssssssbsso..................",
      "...................ollbsssssssssssscccccccccccccccccccccccccccsssssssssssbsso...................",
      "....................ollbsssssssssssssssscccccccccccccccccsssssssssssssssbsso....................",
      ".....................ollsbssssssssssssssssssssssssssssssssssssssssssssbssso.....................",
      "......................ollssbssssssssssssssssssssssssssssssssssssssssbsssso......................",
      ".......................oolsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssoo.......................",
      ".........................oolsssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssssoo.........................",
      "...........................oolssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssoo...........................",
      ".............................oooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbboooo.............................",
      "....................ooooooo......ollbbbbbbbbbbbbbbbbbbbbbbbbsso.......ooooooo...................",
      "..................oollllllloo...ollbbbbbbbbbbbbbbbbbbbbbbbbbbsso....oollllllloo.................",
      "................oolllllllllllooolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoooollllllllllloo...............",
      "................olllbbbbbbblllollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllolllbbbbbbblllo...............",
      "...............ollbbbbbbbbbbbllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblollbbbbbbbbbbbllo..............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "..............ollbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbslo.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "................ollsbbbbbbbsssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsbbbbbbbssso...............",
      "................oolssssssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolssssssssssoo...............",
      "..................oolssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolssssssoo.................",
      "....................ooooooolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssooooooo...................",
      ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........................",
      ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........................",
      "..........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..........................",
      "...........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...........................",
      "............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso............................",
      ".............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbooooobbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollsssssssssssso.....ollsssssssssssso.............................",
      "..............................ollsssssssssssso.....ollsssssssssssso.............................",
      "..............................oooooooooooooooo.....oooooooooooooooo............................."
    ],
    "error" : [
      "................................................................................................",
      "................................................................................................",
      "................................................................................................",
      "................................................................................................",
      ".......................................oooooooooooooooooo.......................................",
      "...................................oooolllllllllllllllllloooo...................................",
      ".................................oolllllllllllllllllllllllllloo.................................",
      "...............................oollllllbbbbbbbbbbbbbbbbbblllllloo...............................",
      ".............................oollllbbbbbbbbbbbbbbbbbbbbbbbbbblllloo.............................",
      "............................ollllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllllo............................",
      "...........................olllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo...........................",
      "..........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo..........................",
      "..........................ollbbbooooooobbbbbbbbbbbbbbbbbbooooooobbbslo..........................",
      ".......................ooollbbooeeeeeeeoobbbbbbbbbbbbbbooeeeeeeeoobbslooo.......................",
      ".....................oollollbocceeeeeeeccobbbbbbbbbbbbocceeeeeeeccobssolloo.....................",
      ".....................ollollbogggceeeeeccccobbbbbbbbbbogggceeeeeccccobslollo.....................",
      "....................ollbolloegggcceeeccccceobbbbbbbboegggcceeeccccceossobllo....................",
      ".....................ollolloegggccceccccceeobbbbbbbboegggccceccccceeossosso.....................",
      ".....................ooolloeeeeccccccccceeeeobbbbbboeeeeccccccccceeeeossooo.....................",
      ".......................olloeeeeeccccccceeeeeobbbbbboeeeeeccccccceeeeeosso.......................",
      ".......................olloeeeeeeccccceeeeeeobbbbbboeeeeeeccccceeeeeeosso.......................",
      ".......................olloeeeeeccccccceeeeeobbbbbboeeeeeccccccceeeeeosso.......................",
      ".......................olloeeeeccccccccceeeeobbbbbboeeeeccccccccceeeeosso.......................",
      ".......................ollboeeccccceccccceeobbbbbbbboeeccccceccccceeobsso.......................",
      ".......................ollboeccccceeeccccceobbbbbbbboeccccceeeccccceobsso.......................",
      ".......................ollbbocccceeeeeccccobbbbbbbbbbocccceeeeeccccobbsso.......................",
      "......................ollbbbbocceeeeeeeccobbbbbbbbbbbbocceeeeeeeccobbbbsso......................",
      ".....................ollbbbbbbooeeeeeeeoobbbbbbbbbbbbbbooeeeeeeeoobbbbbbslo.....................",
      "....................ollbbbbbbbbbooooooobbbbbbbbbbbbbbbbbbooooooobbbbbbbbbllo....................",
      "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...................",
      "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo..................",
      ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.................",
      ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.................",
      "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo................",
      "................ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooooobbbbbsso................",
      "................ollbbbboosssssssssssssssssssssssssssssssssssssssssssssssoobbbsso................",
      "...............ollbbbbosssssssocccossssssssssssssssssssssssssocccossssssssobbbsso...............",
      "...............ollbbbosssssssocccccossssssssssssssssssssssssocccccossssssssobbsso...............",
      "...............ollbbosssssssocccccccossssssssssssssssssssssocccccccossssssssobsso...............",
      "...............ollbbosssssssocccccccossssssssssssssssssssssocccccccossssssssobsso...............",
      "...............ollbossssssssocccccccossssssssssssssssssssssocccccccosssssssssosso...............",
      "...............ollbosssssssssocccccossssssssssssssssssssssssocccccossssssssssosso...............",
      "...............ollbossssssssssooooossssssssssssssssssssssssssooooosssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssssobsso...............",
      "................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
      "................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
      "................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssobsso................",
      ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
      ".................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssobsso.................",
      "..................ollbosssssssssssssssssscccccccccccccccsssssssssssssssssobsso..................",
      "...................ollbosssssssssssscccccccccccccccccccccccccsssssssssssobsso...................",
      "....................ollboossssssscccccccccccccccccccccccccccccccssssssoobsso....................",
      ".....................ollsboosscccccccccccssssssssssssssscccccccccccsoobssso.....................",
      "......................ollssbccccccccssssssssssssssssssssssssscccccccbsssso......................",
      ".......................oolsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssoo.......................",
      ".........................oolsssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssssoo.........................",
      "...........................oolssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssoo...........................",
      ".............................oooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbboooo.............................",
      ".................................ollbbbbbbbbbbbbbbbbbbbbbbbbsso.................................",
      "................................ollbbbbbbbbbbbbbbbbbbbbbbbbbbsso................................",
      "..............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo..............................",
      ".............................olllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo.............................",
      "............................olllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo............................",
      "...........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...........................",
      "..........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo..........................",
      "....................ooooooolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllooooooo...................",
      "..................oollllllloobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboollllllloo.................",
      "................oollllllllllloobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboollllllllllloo...............",
      "................olllbbbbbbblllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbolllbbbbbbblllo...............",
      "...............ollbbbbbbbbbbbllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbllo..............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "..............ollbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbslo.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "................ollsbbbbbbbsssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsbbbbbbbssso...............",
      "................oolssssssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoolssssssssssoo...............",
      "..................oolssssssooollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.oolssssssoo.................",
      "....................ooooooo...ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...ooooooo...................",
      "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbooooobbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollsssssssssssso.....ollsssssssssssso.............................",
      "..............................ollsssssssssssso.....ollsssssssssssso.............................",
      "..............................oooooooooooooooo.....oooooooooooooooo............................."
    ],
    "idle" : [
      "................................................................................................",
      "................................................................................................",
      "................................................................................................",
      "................................................................................................",
      ".......................................oooooooooooooooooo.......................................",
      "...................................oooolllllllllllllllllloooo...................................",
      ".................................oolllllllllllllllllllllllllloo.................................",
      "...........................o...oollllllbbbbbbbbbbbbbbbbbblllllloo...o...........................",
      "........................ooolooollllbbbbbbbbbbbbbbbbbbbbbbbbbbllllooolooo........................",
      ".......................ollllollllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllllollllo.......................",
      "......................ollllolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllollllo......................",
      "......................ollbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllobslo......................",
      ".....................ollbbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslobbslo.....................",
      "......................ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslosso......................",
      "......................ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssosso......................",
      ".......................oollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsloo.......................",
      "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
      "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
      ".......................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.......................",
      ".......................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.......................",
      ".......................ollooooooooooooooooooobbbbbbooooooooooooooooooosso.......................",
      ".......................olloeeeeggggeeeeeeeeeobbbbbboeeeeggggeeeeeeeeeosso.......................",
      ".......................olloeeeeggggeeeeeeeeeobbbbbboeeeeggggeeeeeeeeeosso.......................",
      ".......................ollboeeeggggeeeeeeeeobbbbbbbboeeeggggeeeeeeeeobsso.......................",
      ".......................ollboeeeeeeeeeeeeeeeobbbbbbbboeeeeeeeeeeeeeeeobsso.......................",
      ".......................ollboeeeeeeeeeeeeeeeobbbbbbbboeeeeeeeeeeeeeeeobsso.......................",
      "......................ollbbboeeeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeeeobbbsso......................",
      ".....................ollbbbbbooeeeeeeeeeoobbbbbbbbbbbbooeeeeeeeeeoobbbbbslo.....................",
      "....................ollbbbbbbbbooooeoooobbbbbbbbbbbbbbbbooooeoooobbbbbbbbllo....................",
      "...................ollbbbbbbbbbbbbbobbbbbbbbbbbbbbbbbbbbbbbbobbbbbbbbbbbbbllo...................",
      "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo..................",
      ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.................",
      ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.................",
      "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo................",
      "................ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooooobbbbbsso................",
      "................ollbbbboosssssssssssssssssssssssssssssssssssssssssssssssoobbbsso................",
      "...............ollbbbbosssssssocccossssssssssssssssssssssssssocccossssssssobbbsso...............",
      "...............ollbbbosssssssocccccossssssssssssssssssssssssocccccossssssssobbsso...............",
      "...............ollbbosssssssocccccccossssssssssssssssssssssocccccccossssssssobsso...............",
      "...............ollbbosssssssocccccccossssssssssssssssssssssocccccccossssssssobsso...............",
      "...............ollbossssssssocccccccossssssssssssssssssssssocccccccosssssssssosso...............",
      "...............ollbosssssssssocccccossssssssssssssssssssssssocccccossssssssssosso...............",
      "...............ollbossssssssssooooossssssssssssssssssssssssssooooosssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssssobsso...............",
      "................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
      "................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
      "................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssobsso................",
      ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
      ".................ollbcccccccccccsssssssssssssssssssssssssssssssssccccccccccbsso.................",
      "..................ollbccccccccccccccccccccccccccccccccccccccccccccccccccccbsso..................",
      "...................ollbccccccccccccccccccccccccccccccccccccccccccccccccccbsso...................",
      "....................ollbsssssssscccccccccccccccccccccccccccccccccsssssssbsso....................",
      ".....................ollsbssssssssssssssssssssssssssssssssssssssssssssbssso.....................",
      "......................ollssbssssssssssssssssssssssssssssssssssssssssbsssso......................",
      ".......................oolsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssoo.......................",
      ".........................oolsssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssssoo.........................",
      "...........................oolssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssoo...........................",
      ".............................oooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbboooo.............................",
      ".................................ollbbbbbbbbbbbbbbbbbbbbbbbbsso.................................",
      "................................ollbbbbbbbbbbbbbbbbbbbbbbbbbbsso................................",
      "..............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo..............................",
      ".............................olllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo.............................",
      "....................ooooooo.olllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo..ooooooo...................",
      "..................oollllllloolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblloollllllloo.................",
      "................oollllllllllloobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboollllllllllloo...............",
      "................olllbbbbbbblllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbolllbbbbbbblllo...............",
      "...............ollbbbbbbbbbbbllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbllo..............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "..............ollbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbslo.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "................ollsbbbbbbbsssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsbbbbbbbssso...............",
      "................oolssssssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolssssssssssoo...............",
      "..................oolssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoolssssssoo.................",
      "....................oooooooollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.ooooooo...................",
      "............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso............................",
      ".............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbooooobbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollsssssssssssso.....ollsssssssssssso.............................",
      "..............................ollsssssssssssso.....ollsssssssssssso.............................",
      "..............................oooooooooooooooo.....oooooooooooooooo............................."
    ],
    "running" : [
      "................................................................................................",
      "................................................................................................",
      "................................................................................................",
      ".........................ooooo....................................ooooo.........................",
      "........................olllllo........oooooooooooooooooo........olllllo........................",
      ".......................olllllllo...oooolllllllllllllllllloooo...olllllllo.......................",
      ".......................ollbbbslo.oolllllllllllllllllllllllllloo.ollbbbslo.......................",
      ".......................ollbbbssoollllllbbbbbbbbbbbbbbbbbblllllloollbbbsso.......................",
      "......................ollbbbboollllbbbbbbbbbbbbbbbbbbbbbbbbbblllloobbbbsso......................",
      ".......................ollbbollllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllllobbsso.......................",
      ".......................ollbolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllobsso.......................",
      ".......................ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllosso.......................",
      "........................olollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsloso........................",
      ".........................ollbbboobbbbbbbbbbbbbbbbbbbbbbbbbbbbbboobbbslo.........................",
      ".........................ollbboeeooobbbbbbbbbbbbbbbbbbbbbbbboooeeobbsso.........................",
      "........................ollbboeeeeeeoobbbbbbbbbbbbbbbbbbbbooeeeeeeobbslo........................",
      "........................ollbboeeeeeeeeooobbbbbbbbbbbbbboooeeeeeeeeobbsso........................",
      "........................ollboeeeeeeeeeeeeoobbbbbbbbbbooeeeeeeeeeeeeobsso........................",
      ".......................ollbboeeeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeeeobbsso.......................",
      ".......................ollbboeeegggeeeeeeeobbbbbbbbbboeeegggeeeeeeeobbsso.......................",
      ".......................ollbboeeegggeeeeeeeobbbbbbbbbboeeegggeeeeeeeobbsso.......................",
      ".......................ollbboeeegggeeeeeeeobbbbbbbbbboeeegggeeeeeeeobbsso.......................",
      ".......................ollbboeeeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeeeobbsso.......................",
      ".......................ollbboeeeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeeeobbsso.......................",
      ".......................ollbbboeeeeeeeeeeeobbbbbbbbbbbboeeeeeeeeeeeobbbsso.......................",
      ".......................ollbbboeeeeeeeeeeeobbbbbbbbbbbboeeeeeeeeeeeobbbsso.......................",
      "......................ollbbbbboeeeeeeeeeobbbbbbbbbbbbbboeeeeeeeeeobbbbbsso......................",
      ".....................ollbbbbbbboeeeeeeeobbbbbbbbbbbbbbbboeeeeeeeobbbbbbbslo.....................",
      "....................ollbbbbbbbbbooooooobbbbbbbbbbbbbbbbbbooooooobbbbbbbbbllo....................",
      "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...................",
      "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo..................",
      ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.................",
      ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.................",
      "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo................",
      "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso................",
      "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso................",
      "...............ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...............",
      "...............ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...............",
      "...............ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...............",
      "...............ollbbbbbbbbooooooooooooooooooooooooooooooooooooooooooooobbbbbbbsso...............",
      "...............ollbbbbbboosssssssssssssssssssssssssssssssssssssssssssssoobbbbbsso...............",
      "...............ollbbbbbossssssocccossssssssssssssssssssssssssocccosssssssobbbbsso...............",
      "...............ollbbbbbosssssocccccossssssssssssssssssssssssocccccossssssobbbbsso...............",
      "...............ollbbbbosssssocccccccossssssssssssssssssssssocccccccossssssobbbsso...............",
      "...............ollbbbbosssssocccccccossssssssssssssssssssssocccccccossssssobbbsso...............",
      "...............ollbbbbosssssocccccccossssssssssssssssssssssocccccccossssssobbbsso...............",
      "...............ollbbbbossssssocccccossssssssssssssssssssssssocccccosssssssobbbsso...............",
      "...............ollbbbbosssssssooooossssssssssssssssssssssssssooooossssssssobbbsso...............",
      "................ollbbbosssssssssssssssssssssssssssssssssssssssssssssssssssobbsso................",
      "................ollbbbosssssssssssssssssssssssssssssssssssssssssssssssssssobbsso................",
      "................ollbbbosssssssssssssssssssssssssssssssssssssssssssssssssssobbsso................",
      ".................ollbbosssssssssssssssssssssssssssssssssssssssssssssssssssobsso.................",
      ".................ollbbosssssssssssssssssssssssssssssssssssssssssssssssssssobsso.................",
      "..................ollbccccccccccccccccccccccccccccccccccccccccccccccccccccbsso..................",
      "...................ollbccccccccccccccccccccccccccccccccccccccccccccccccccbsso...................",
      "....................ollbccccccccccccccccccccccccccccccccccccccccccccccccbsso....................",
      ".....................ollsbssssssssssssssssssssssssssssssssssssssssssssbssso.....................",
      "......................ollssbssssssssssssssssssssssssssssssssssssssssbsssso......................",
      ".......................oolsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssoo.......................",
      ".........................oolsssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssssoo.........................",
      "...........................oolssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssoo...........................",
      ".............................oooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbboooo.............................",
      "....................ooooooo......ollbbbbbbbbbbbbbbbbbbbbbbbbsso.......ooooooo...................",
      "..................oollllllloo...ollbbbbbbbbbbbbbbbbbbbbbbbbbbsso....oollllllloo.................",
      "................oolllllllllllooolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoooollllllllllloo...............",
      "................olllbbbbbbblllollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllolllbbbbbbblllo...............",
      "...............ollbbbbbbbbbbbllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblollbbbbbbbbbbbllo..............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "..............ollbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbslo.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "................ollsbbbbbbbsssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsbbbbbbbssso...............",
      "................oolssssssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolssssssssssoo...............",
      "..................oolssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolssssssoo.................",
      "....................ooooooolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssooooooo...................",
      ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........................",
      ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........................",
      "..........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..........................",
      "...........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...........................",
      "............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso............................",
      ".............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbooooobbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollsssssssssssso.....ollsssssssssssso.............................",
      "..............................ollsssssssssssso.....ollsssssssssssso.............................",
      "..............................oooooooooooooooo.....oooooooooooooooo............................."
    ],
    "waiting" : [
      "................................................................................................",
      "................................................................................................",
      "................................................................................................",
      ".........................ooooo..................................................................",
      "........................olllllo........oooooooooooooooooo.......................................",
      ".......................olllllllo...oooolllllllllllllllllloooo...................................",
      ".......................ollbbbslo.oolllllllllllllllllllllllllloo.................................",
      ".......................ollbbbssoollllllbbbbbbbbbbbbbbbbbblllllloo...............................",
      "......................ollbbbboollllbbbbbbbbbbbbbbbbbbbbbbbbbblllloo.............................",
      ".......................ollbbollllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllllo............................",
      ".......................ollbolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo...........................",
      ".......................ollollbbbbbbobbbbbbbbbbbbbbbbbbbbbbbbobbbbbbllo..........................",
      "........................olollbbooooeoooobbbbbbbbbbbbbbbbooooeoooobbslooooo......................",
      ".........................ollbooeeeeeeeeeoobbbbbbbbbbbbooeeeeeeeeeoobslollloo....................",
      ".........................olloeeeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeeeossollllo....................",
      "........................olloeeeegggeeeeeeeeobbbbbbbboeeeegggeeeeeeeeoslobbllo...................",
      "........................olloeeeegggeeeeeeeeobbbbbbbboeeeegggeeeeeeeeossossso....................",
      "........................olloeeeegggeeeeeeeeobbbbbbbboeeeegggeeeeeeeeossossoo....................",
      ".......................olloeeeeeeeeeeeeeeeeeobbbbbboeeeeeeeeeeeeeeeeeossoo......................",
      ".......................olloeeeeeeeeeeeeeeeeeobbbbbboeeeeeeeeeeeeeeeeeosso.......................",
      ".......................olloeeeeeeeeeeeeeeeeeobbbbbboeeeeeeeeeeeeeeeeeosso.......................",
      ".......................olloeeeeeeeeeeeeeeeeeobbbbbboeeeeeeeeeeeeeeeeeosso.......................",
      ".......................ollboeeeeeeeeeeeeeeeobbbbbbbboeeeeeeeeeeeeeeeobsso.......................",
      ".......................ollboeeeeeeeeeeeeeeeobbbbbbbboeeeeeeeeeeeeeeeobsso.......................",
      ".......................ollbboeeeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeeeobbsso.......................",
      ".......................ollbboeeeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeeeobbsso.......................",
      "......................ollbbbbooeeeeeeeeeoobbbbbbbbbbbbooeeeeeeeeeoobbbbsso......................",
      ".....................ollbbbbbbbooooooooobbbbbbbbbbbbbbbbooooooooobbbbbbbslo.....................",
      "....................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo....................",
      "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...................",
      "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo..................",
      ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.................",
      ".................ollbbbbbooooooooooooooooooooooooooooooooooooooooooooooobbbbslo.................",
      "................ollbbbboosssssssssssssssssssssssssssssssssssssssssssssssoobbbslo................",
      "................ollbbbosssssssssssssssssssssssssssssssssssssssssssssssssssobbsso................",
      "................ollbbossssssssocccossssssssssssssssssssssssssocccosssssssssobsso................",
      "...............ollbbossssssssocccccossssssssssssssssssssssssocccccosssssssssobsso...............",
      "...............ollbbosssssssocccccccossssssssssssssssssssssocccccccossssssssobsso...............",
      "...............ollbossssssssocccccccossssssssssssssssssssssocccccccosssssssssosso...............",
      "...............ollbossssssssocccccccossssssssssssssssssssssocccccccosssssssssosso...............",
      "...............ollbosssssssssocccccossssssssssssssssssssssssocccccossssssssssosso...............",
      "...............ollbossssssssssooooossssssssssssssssssssssssssooooosssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
      "...............ollbosssssssssssssssssssssssssscccccssssssssssssssssssssssssssosso...............",
      "...............ollbbccccccccccccsssssssssssscccccccccssssssssssssccccccccccccbsso...............",
      "...............ollbbcccccccccccccccccccccccccccccccccccccccccccccccccccccccccbsso...............",
      "...............ollbbbcccccccccccccccccccccccccccccccccccccccccccccccccccccccbbsso...............",
      "................ollbbbsssssssssscccccccccccccccccccccccccccccccccssssssssssbbsso................",
      "................ollbbbbssssssssssssssssssssscccccccccsssssssssssssssssssssbbbsso................",
      "................ollbbbbbbsssssssssssssssssssssssssssssssssssssssssssssssbbbbbsso................",
      ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.................",
      ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.................",
      "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..................",
      "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...................",
      "....................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso....................",
      ".....................ollsbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssso.....................",
      "......................ollssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssso......................",
      ".......................oolsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssoo.......................",
      ".........................oolsssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssssoo.........................",
      "...........................oolssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssoo...........................",
      ".............................oooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbboooo.............................",
      ".................................ollbbbbbbbbbbbbbbbbbbbbbbbbsso.................................",
      "....................ooooooo.....ollbbbbbbbbbbbbbbbbbbbbbbbbbbsso................................",
      "..................oollllllloo.oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo..............................",
      "................oollllllllllloollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo.............................",
      "................olllbbbbbbblllolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo............................",
      "...............ollbbbbbbbbbbbllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...........................",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblloooooooo...................",
      "..............ollbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboollllllloo.................",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboollllllllllloo...............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbolllbbbbbbblllo...............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbllo..............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbslo.............",
      "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "................ollsbbbbbbbsssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "................oolssssssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "..................oolssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
      "....................ooooooolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
      "..........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsbbbbbbbssso...............",
      "...........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolssssssssssoo...............",
      "............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssooolssssssoo.................",
      ".............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...ooooooo...................",
      "..............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbbbbooooobbbbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
      "..............................ollsssssssssssso.....ollsssssssssssso.............................",
      "..............................ollsssssssssssso.....ollsssssssssssso.............................",
      "..............................oooooooooooooooo.....oooooooooooooooo............................."
    ]
  },
  "name" : "perchling",
  "palette" : {
    "b" : "#da7756",
    "c" : "#3a2820",
    "e" : "#ffc169",
    "g" : "#fff4e9",
    "l" : "#eaa286",
    "o" : "#743725",
    "s" : "#be5937"
  },
  "scale" : 1,
  "sequences" : {
    "done" : {
      "frames" : [
        [
          "..........................ooooo..................................ooooo..........................",
          "........................oolllllo........oooooooooooooooo........ollllloo........................",
          "........................olllllllo...oooolllllllllllllllloooo...olllllllo........................",
          ".......................ollbbbbbllooollllllllllllllllllllllllooollbbbbbllo.......................",
          ".......................ollbbbbbsolllllllbbbbbbbbbbbbbbbblllllllolbbbbbsso.......................",
          ".......................ollbbbboollllbbbbbbbbbbbbbbbbbbbbbbbblllloobbbbsso.......................",
          ".......................ollbbbolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllobbbsso.......................",
          "...............o.......ollbbolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllobbsso.......o...............",
          "...............o.......ollssollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslosssso.......o...............",
          "..............ogo.......ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslosso.......ogo..............",
          "............oogggoo......oollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsloo......oogggoo............",
          "..............ogo.........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.........ogo..............",
          "...............o.........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.........o...............",
          "...............o.........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........o...............",
          ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........................",
          ".........................ollbbbbboooooooobbbbbbbbbbbbbbboooooooobbbbsso.........................",
          "........................ollbbbbggggeeeeeeoobbbbbbbbbbbggggeeeeeeoobbbsso........................",
          "........................ollbbboggggeeeeeeeeobbbbbbbbboggggeeeeeeeeobbsso........................",
          "........................ollbboeggggeeeeeeeeeobbbbbbboeggggeeeeeeeeeobsso........................",
          "........................ollbboeeeeeeeeeeeeeeobbbbbbboeeeeeeeeeeeeeeobsso........................",
          "........................ollbboeeeeeeeeeeeeeeobbbbbbboeeeeeeeeeeeeeeobsso........................",
          "........................ollbboeeeooooooooeeeobbbbbbboeeeooooooooeeeobsso........................",
          "........................ollbboeoobbbbbbbbooeobbbbbbboeoobbbbbbbbooeobsso........................",
          "........................ollbboobbbbbbbbbbbboobbbbbbboobbbbbbbbbbbboobsso........................",
          ".......................ollbbbobbbbbbbbbbbbbbobbbbbbbobbbbbbbbbbbbbbobbsso.......................",
          "......................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo......................",
          ".....................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.....................",
          "....................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo....................",
          "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...................",
          "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo...................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo..................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..................",
          ".................ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooobbbbbslo.................",
          ".................ollbbbboosssssssssssssssssssssssssssssssssssssssssssssoobbbsso.................",
          ".................ollbbbosssssssoocoossssssssssssssssssssssssoocoossssssssobbsso.................",
          ".................ollbbosssssssocccccossssssssssssssssssssssocccccossssssssobsso.................",
          ".................ollbosssssssocccccccossssssssssssssssssssocccccccossssssssosso.................",
          ".................ollbosssssssocccccccossssssssssssssssssssocccccccossssssssosso.................",
          "................ollbossssssssocccccccossssssssssssssssssssocccccccossssssssobsso................",
          "................ollbosssssssssocccccossssssssssssssssssssssocccccossssssssssosso................",
          "................ollbosssssssssooooooossssssssssssssssssssssooooooossssssssssosso................",
          "................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssobsso................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollbcccccccsssssssssssssssssssssssssssssssssssssssssccccccbsso.................",
          "..................ollcccccccccsssssssssssssssssssssssssssssssssssssccccccccsso..................",
          "..................ollbcccccccccccsssssssssssssssssssssssssssssssccccccccccbsso..................",
          "...................ollssssssccccccccsssssssssssssssssssssssssccccccccssssssso...................",
          "...................ollbssssssscccccccccccssssssssssssssscccccccccccssssssbsso...................",
          "....................ollsssssssssscccccccccccccccccccccccccccccccssssssssssso....................",
          "....................ollbsssssssssssscccccccccccccccccccccccccsssssssssssbsso....................",
          ".....................ollsbssssssssssssssscccccccccccccccssssssssssssssbssso.....................",
          "......................ollsbssssssssssssssssssssssssssssssssssssssssssbssso......................",
          ".......................oolssbssssssssssssssssssssssssssssssssssssssbsssoo.......................",
          ".........................ollsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssso.........................",
          "..........................oolsssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssssoo..........................",
          "............................ooossbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssooo............................",
          "...............................ooobbbbbbbbbbbbbbbbbbbbbbbbbbbbooo...............................",
          ".....................oooooooo.....ollbbbbbbbbbbbbbbbbbbbbbbsso......oooooooo....................",
          "...................oolllllllloo..ollbbbbbbbbbbbbbbbbbbbbbbbbsso...oolllllllloo..................",
          "..................olllllllllllloolbbbbbbbbbbbbbbbbbbbbbbbbbbbbsooollllllllllllo.................",
          ".................olllbbbbbbbblllolbbbbbbbbbbbbbbbbbbbbbbbbbbbbllolllbbbbbbbblllo................",
          ".................ollbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbblollbbbbbbbbbbslo................",
          "................ollbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbslo...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          ".................ollbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbsso................",
          ".................ollsbbbbbbbbsssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsbbbbbbbbssso................",
          "..................ollssssssssssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsssssssssso.................",
          "...................oolsssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolsssssssoo..................",
          ".....................oooooooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoooooooo....................",
          "..........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..........................",
          "...........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...........................",
          "...........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...........................",
          "............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbbbbsssssbbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbbbbsssssbbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbbbbooooobbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollssssssssssso.....ollssssssssssso..............................",
          "...............................ollssssssssssso.....ollssssssssssso..............................",
          "...............................ooooooooooooooo.....ooooooooooooooo.............................."
        ],
        [
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "........................ooooo......................................ooooo........................",
          "......................oollllloo........oooooooooooooooooo........oollllloo......................",
          ".....................olllllllllo..ooooollllllllllllllllllooooo..olllllllllo.....................",
          ".....................ollbbbbbllooollllllllllllllllllllllllllllooollbbbbbllo.....................",
          "....................ollbbbbbbboolllllllbbbbbbbbbbbbbbbbbbllllllloobbbbbbbslo....................",
          "....................ollbbbbboollllbbbbbbbbbbbbbbbbbbbbbbbbbbbblllloobbbbbsso....................",
          "....................ollbbbbollllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllllobbbbsso....................",
          "...........o.........ollsbolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllobssso.........o...........",
          "...........o..........ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllosso..........o...........",
          "..........ogo..........ooollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslooo..........ogo..........",
          "........oogggoo.........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.........oogggoo........",
          "..........ogo..........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo..........ogo..........",
          "...........o...........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo...........o...........",
          "...........o...........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...........o...........",
          "......................ollbbbbbboooooooobbbbbbbbbbbbbbbbbbboooooooobbbbbsso......................",
          "......................ollbbbbggggeeeeeeoobbbbbbbbbbbbbbbggggeeeeeeoobbbsso......................",
          "......................ollbbooggggeeeeeeeeoobbbbbbbbbbbooggggeeeeeeeeoobsso......................",
          "......................ollboeeggggeeeeeeeeeeobbbbbbbbboeeggggeeeeeeeeeeosso......................",
          "......................ollboeeeeeeeeeeeeeeeeobbbbbbbbboeeeeeeeeeeeeeeeeosso......................",
          "......................ollboeeeeeeeeeeeeeeeeobbbbbbbbboeeeeeeeeeeeeeeeeosso......................",
          "......................ollboeeeeooooooooeeeeobbbbbbbbboeeeeooooooooeeeeosso......................",
          "......................ollboeeoobbbbbbbbooeeobbbbbbbbboeeoobbbbbbbbooeeosso......................",
          ".....................ollbbooobbbbbbbbbbbbooobbbbbbbbbooobbbbbbbbbbbbooobsso.....................",
          "....................ollbbbobbbbbbbbbbbbbbbbobbbbbbbbbobbbbbbbbbbbbbbbbobbslo....................",
          "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo..................",
          ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.................",
          "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo................",
          "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo................",
          "...............ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo...............",
          "...............ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooooooobbbbbsso...............",
          "..............ollbbbbboosssssssssssssssssssssssssssssssssssssssssssssssssoobbbbslo..............",
          "..............ollbbbbossssssoocccoossssssssssssssssssssssssssoocccoosssssssobbbsso..............",
          "..............ollbbbossssssocccccccossssssssssssssssssssssssocccccccosssssssobbsso..............",
          "..............ollbbosssssssocccccccossssssssssssssssssssssssocccccccossssssssobsso..............",
          "..............ollbbosssssssocccccccossssssssssssssssssssssssocccccccossssssssobsso..............",
          "..............ollbossssssssocccccccossssssssssssssssssssssssocccccccosssssssssosso..............",
          "..............ollbosssssssssoocccoossssssssssssssssssssssssssoocccoossssssssssosso..............",
          "..............ollbossssssssssooooossssssssssssssssssssssssssssooooosssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbcccccccsssssssssssssssssssssssssssssssssssssssssssssssccccccbsso..............",
          "...............ollccccccccccssssssssssssssssssssssssssssssssssssssssscccccccccsso...............",
          "...............ollbccccccccccccssssssssssssssssssssssssssssssssssscccccccccccbsso...............",
          "................ollsssssscccccccccssssssssssssssssssssssssssssscccccccccssssssso................",
          "................ollbssssssssccccccccccccsssssssssssssssssccccccccccccsssssssbsso................",
          ".................ollbsssssssssscccccccccccccccccccccccccccccccccccsssssssssbsso.................",
          "..................ollsbssssssssssscccccccccccccccccccccccccccccssssssssssbssso..................",
          "...................ollsbsssssssssssssssscccccccccccccccccsssssssssssssssbssso...................",
          "....................oolsssbssssssssssssssssssssssssssssssssssssssssssbssssoo....................",
          "......................ollsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssso......................",
          ".......................ooosssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssssooo.......................",
          "..........................oolsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssoo..........................",
          "............................ooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbooo............................",
          ".................oooooooooo....ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.....oooooooooo................",
          "................ollllllllllo....ollbbbbbbbbbbbbbbbbbbbbbbbbbbsso.....ollllllllllo...............",
          "..............oolllllllllllloooolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo.oolllllllllllloo.............",
          "..............ollbbbbbbbbbbllolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbloollbbbbbbbbbbllo.............",
          ".............ollbbbbbbbbbbbbllolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllollbbbbbbbbbbbbllo............",
          "............ollbbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbslo...........",
          "............ollbbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbslo...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          ".............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso............",
          "..............ollbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbsso.............",
          "..............oolsssssssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolsssssssssssoo.............",
          "................ollssssssssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsssssssso...............",
          ".................oooooooooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboooooooooo................",
          "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
          "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
          ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........................",
          ".........................ollsbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........................",
          "..........................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo..........................",
          "............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbbbbsssssbbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbbbbsssssbbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbbbbooooobbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollssssssssssssso.....ollssssssssssssso............................",
          ".............................ollssssssssssssso.....ollssssssssssssso............................",
          ".............................ooooooooooooooooo.....ooooooooooooooooo............................"
        ],
        [
          "................................................................................................",
          "...........................oo......................................oo...........................",
          ".........................oolloo..................................oolloo.........................",
          ".......................oollllllo.....oooooooooooooooooooooo.....olllllloo.......................",
          ".......................olllbblllo.ooollllllllllllllllllllllooo.olllbblllo.......................",
          "......................ollbbbbbbloolllllllllllllllllllllllllllloolbbbbbbllo......................",
          "......................ollbbbbbbolllllbbbbbbbbbbbbbbbbbbbbbblllllobbbbbbsso......................",
          "......................ollbbbboolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbllloobbbbsso......................",
          "......................ollbbbolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllobbbsso......................",
          "..............o........ollsolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllossso........o..............",
          "..............o........ollsollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslossso........o..............",
          ".............ogo........ooollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslooo........ogo.............",
          "...........oogggoo.......ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.......oogggoo...........",
          ".............ogo.........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.........ogo.............",
          "..............o..........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..........o..............",
          "..............o.........ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........o..............",
          "........................ollbbbbbboooooobbbbbbbbbbbbbbbbbbboooooobbbbbsso........................",
          "........................ollbbbggggeeeeeooobbbbbbbbbbbbbggggeeeeeooobbsso........................",
          "........................ollbboggggeeeeeeeeobbbbbbbbbbboggggeeeeeeeeobsso........................",
          "........................ollboeggggeeeeeeeeeobbbbbbbbboeggggeeeeeeeeeosso........................",
          "........................ollboeeeeeeeeeeeeeeobbbbbbbbboeeeeeeeeeeeeeeosso........................",
          "........................olloeeeeeeeeeeeeeeeeobbbbbbboeeeeeeeeeeeeeeeeoso........................",
          "........................olloeeeeeooooooeeeeeobbbbbbboeeeeeooooooeeeeeoso........................",
          "........................olloeeooobbbbbboooeeobbbbbbboeeooobbbbbboooeeoso........................",
          "........................olloeobbbbbbbbbbbboeobbbbbbboeobbbbbbbbbbbboeoso........................",
          "......................oolbboobbbbbbbbbbbbbboobbbbbbboobbbbbbbbbbbbbboobsoo......................",
          ".....................ollbbbobbbbbbbbbbbbbbbbobbbbbbbobbbbbbbbbbbbbbbbobbllo.....................",
          "....................olllbbbobbbbbbbbbbbbbbbbobbbbbbbobbbbbbbbbbbbbbbbobblllo....................",
          "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...................",
          "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo...................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo..................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..................",
          ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.................",
          ".................ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooobbbbbsso.................",
          "................ollbbbbboosssssssssssssssssssssssssssssssssssssssssssssoobbbbslo................",
          "................ollbbbbossssssoocoossssssssssssssssssssssssssoocoosssssssobbbsso................",
          "................ollbbbossssssocccccossssssssssssssssssssssssocccccosssssssobbsso................",
          "................ollbbossssssocccccccossssssssssssssssssssssocccccccosssssssobsso................",
          "................ollbbossssssocccccccossssssssssssssssssssssocccccccosssssssobsso................",
          "................ollbosssssssocccccccossssssssssssssssssssssocccccccossssssssosso................",
          "................ollbossssssssocccccossssssssssssssssssssssssocccccosssssssssosso................",
          "................ollbosssssssssooooossssssssssssssssssssssssssooooossssssssssosso................",
          "................ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbcccccccsssssssssssssssssssssssssssssssssssssssssssccccccbsso................",
          ".................ollccccccccccssssssssssssssssssssssssssssssssssssscccccccccsso.................",
          ".................ollccccccccccccssssssssssssssssssssssssssssssssscccccccccccsso.................",
          ".................ollbsssssscccccccccssssssssssssssssssssssssscccccccccsssssbsso.................",
          "..................ollbsssssssscccccccccccssssssssssssssscccccccccccsssssssbsso..................",
          "...................ollsssssssssscccccccccccccccccccccccccccccccccssssssssssso...................",
          "...................ollbssssssssssssscccccccccccccccccccccccccssssssssssssbsso...................",
          "....................ollbssssssssssssssssscccccccccccccccssssssssssssssssbsso....................",
          ".....................ollsbssssssssssssssssssssssssssssssssssssssssssssbssso.....................",
          "......................ollssbssssssssssssssssssssssssssssssssssssssssbsssso......................",
          ".......................oolsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssoo.......................",
          ".........................oolssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssssoo.........................",
          "...........................oolssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssssoo...........................",
          ".............................ooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbooo.............................",
          ".....................oooooo.....oolbbbbbbbbbbbbbbbbbbbbbbbbbbsoo......oooooo....................",
          "...................oolllllloo.....ollbbbbbbbbbbbbbbbbbbbbbbsso......oolllllloo..................",
          ".................oolllllllllloo.oolbbbbbbbbbbbbbbbbbbbbbbbbbbsoo..oolllllllllloo................",
          ".................olllbbbbbbllloolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsooolllbbbbbblllo................",
          "................ollbbbbbbbbbbllollbbbbbbbbbbbbbbbbbbbbbbbbbbbblllollbbbbbbbbbbllo...............",
          "................ollbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblollbbbbbbbbbbsso...............",
          "...............ollbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbslo..............",
          "...............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso..............",
          "...............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso..............",
          "...............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso..............",
          "...............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso..............",
          "...............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso..............",
          "...............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso..............",
          "................ollbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbsso...............",
          ".................ollsbbbbbbsssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsbbbbbbssso................",
          ".................oolsssssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolsssssssssoo................",
          "...................oolsssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolsssssoo..................",
          ".....................oooooolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssoooooo....................",
          ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........................",
          "..........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..........................",
          "..........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..........................",
          "...........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...........................",
          "...........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...........................",
          "............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso............................",
          "..............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbooooobbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollsssssssssssso.....ollsssssssssssso.............................",
          "..............................ollsssssssssssso.....ollsssssssssssso.............................",
          "..............................oooooooooooooooo.....oooooooooooooooo............................."
        ]
      ],
      "steps" : [
        [
          0,
          200
        ],
        [
          1,
          100
        ],
        [
          2,
          150
        ],
        [
          1,
          100
        ]
      ]
    },
    "error" : {
      "frames" : [
        [
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          ".......................................oooooooooooooooooo.......................................",
          "...................................oooolllllllllllllllllloooo...................................",
          ".................................oolllllllllllllllllllllllllloo.................................",
          "...............................oollllllbbbbbbbbbbbbbbbbbblllllloo...............................",
          ".............................oollllbbbbbbbbbbbbbbbbbbbbbbbbbblllloo.............................",
          "............................ollllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllllo............................",
          "...........................olllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo...........................",
          "..........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo..........................",
          "..........................ollbbbooooooobbbbbbbbbbbbbbbbbbooooooobbbslo..........................",
          ".......................ooollbbooeeeeeeeoobbbbbbbbbbbbbbooeeeeeeeoobbslooo.......................",
          ".....................oollollbocceeeeeeeccobbbbbbbbbbbbocceeeeeeeccobssolloo.....................",
          ".....................ollollbogggceeeeeccccobbbbbbbbbbogggceeeeeccccobslollo.....................",
          "....................ollbolloegggcceeeccccceobbbbbbbboegggcceeeccccceossobllo....................",
          ".....................ollolloegggccceccccceeobbbbbbbboegggccceccccceeossosso.....................",
          ".....................ooolloeeeeccccccccceeeeobbbbbboeeeeccccccccceeeeossooo.....................",
          ".......................olloeeeeeccccccceeeeeobbbbbboeeeeeccccccceeeeeosso.......................",
          ".......................olloeeeeeeccccceeeeeeobbbbbboeeeeeeccccceeeeeeosso.......................",
          ".......................olloeeeeeccccccceeeeeobbbbbboeeeeeccccccceeeeeosso.......................",
          ".......................olloeeeeccccccccceeeeobbbbbboeeeeccccccccceeeeosso.......................",
          ".......................ollboeeccccceccccceeobbbbbbbboeeccccceccccceeobsso.......................",
          ".......................ollboeccccceeeccccceobbbbbbbboeccccceeeccccceobsso.......................",
          ".......................ollbbocccceeeeeccccobbbbbbbbbbocccceeeeeccccobbsso.......................",
          "......................ollbbbbocceeeeeeeccobbbbbbbbbbbbocceeeeeeeccobbbbsso......................",
          ".....................ollbbbbbbooeeeeeeeoobbbbbbbbbbbbbbooeeeeeeeoobbbbbbslo.....................",
          "....................ollbbbbbbbbbooooooobbbbbbbbbbbbbbbbbbooooooobbbbbbbbbllo....................",
          "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo..................",
          ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.................",
          ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.................",
          "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo................",
          "................ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooooobbbbbsso................",
          "................ollbbbboosssssssssssssssssssssssssssssssssssssssssssssssoobbbsso................",
          "...............ollbbbbosssssssocccossssssssssssssssssssssssssocccossssssssobbbsso...............",
          "...............ollbbbosssssssocccccossssssssssssssssssssssssocccccossssssssobbsso...............",
          "...............ollbbosssssssocccccccossssssssssssssssssssssocccccccossssssssobsso...............",
          "...............ollbbosssssssocccccccossssssssssssssssssssssocccccccossssssssobsso...............",
          "...............ollbossssssssocccccccossssssssssssssssssssssocccccccosssssssssosso...............",
          "...............ollbosssssssssocccccossssssssssssssssssssssssocccccossssssssssosso...............",
          "...............ollbossssssssssooooossssssssssssssssssssssssssooooosssssssssssosso...............",
          "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
          "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
          "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
          "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
          "...............ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssssobsso...............",
          "................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssobsso................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssobsso.................",
          "..................ollbosssssssssssssssssscccccccccccccccsssssssssssssssssobsso..................",
          "...................ollbosssssssssssscccccccccccccccccccccccccsssssssssssobsso...................",
          "....................ollboossssssscccccccccccccccccccccccccccccccssssssoobsso....................",
          ".....................ollsboosscccccccccccssssssssssssssscccccccccccsoobssso.....................",
          "......................ollssbccccccccssssssssssssssssssssssssscccccccbsssso......................",
          ".......................oolsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssoo.......................",
          ".........................oolsssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssssoo.........................",
          "...........................oolssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssoo...........................",
          ".............................oooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbboooo.............................",
          ".................................ollbbbbbbbbbbbbbbbbbbbbbbbbsso.................................",
          "................................ollbbbbbbbbbbbbbbbbbbbbbbbbbbsso................................",
          "..............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo..............................",
          ".............................olllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo.............................",
          "............................olllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo............................",
          "...........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...........................",
          "..........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo..........................",
          "....................ooooooolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllooooooo...................",
          "..................oollllllloobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboollllllloo.................",
          "................oollllllllllloobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboollllllllllloo...............",
          "................olllbbbbbbblllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbolllbbbbbbblllo...............",
          "...............ollbbbbbbbbbbbllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbllo..............",
          "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
          "..............ollbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbslo.............",
          "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
          "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
          "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
          "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
          "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
          "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
          "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
          "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
          "................ollsbbbbbbbsssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsbbbbbbbssso...............",
          "................oolssssssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoolssssssssssoo...............",
          "..................oolssssssooollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.oolssssssoo.................",
          "....................ooooooo...ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...ooooooo...................",
          "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbooooobbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollsssssssssssso.....ollsssssssssssso.............................",
          "..............................ollsssssssssssso.....ollsssssssssssso.............................",
          "..............................oooooooooooooooo.....oooooooooooooooo............................."
        ],
        [
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          ".......................................oooooooooooooooooo.......................................",
          "..................................ooooollllllllllllllllllooooo..................................",
          "................................oolllllllllllllllllllllllllllloo................................",
          "..............................oolllllllbbbbbbbbbbbbbbbbbbllllllloo..............................",
          "............................oollllbbbbbbbbbbbbbbbbbbbbbbbbbbbblllloo............................",
          "...........................ollllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllllo...........................",
          "..........................olllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo..........................",
          ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.........................",
          "........................oollbbooooooooobbbbbbbbbbbbbbbbbbooooooooobbsloo........................",
          ".....................oooollbooeeeeeeeeeoobbbbbbbbbbbbbbooeeeeeeeeeoobsloooo.....................",
          "....................ollollbogggeeeeeeecccobbbbbbbbbbbbogggeeeeeeecccobslollo....................",
          "...................olllolloegggceeeeecccceobbbbbbbbbboegggceeeeecccceoslolllo...................",
          "...................ollsolloegggcceeecccceeobbbbbbbbbboegggcceeecccceeossosslo...................",
          "....................ololloeeeeccccecccceeeeobbbbbbbboeeeeccccecccceeeeossoso....................",
          ".....................oolloeeeeeccccccceeeeeobbbbbbbboeeeeeccccccceeeeeossoo.....................",
          "......................olloeeeeeeccccceeeeeeobbbbbbbboeeeeeeccccceeeeeeosso......................",
          "......................olloeeeeeeccccceeeeeeobbbbbbbboeeeeeeccccceeeeeeosso......................",
          "......................olloeeeeeccccccceeeeeobbbbbbbboeeeeeccccccceeeeeosso......................",
          "......................olloeeeeccccecccceeeeobbbbbbbboeeeeccccecccceeeeosso......................",
          "......................ollboeecccceeecccceeobbbbbbbbbboeecccceeecccceeobsso......................",
          "......................ollboecccceeeeecccceobbbbbbbbbboecccceeeeecccceobsso......................",
          ".....................ollbbboccceeeeeeecccobbbbbbbbbbbboccceeeeeeecccobbbsso.....................",
          "....................ollbbbbbooeeeeeeeeeoobbbbbbbbbbbbbbooeeeeeeeeeoobbbbbslo....................",
          "...................ollbbbbbbbbooooooooobbbbbbbbbbbbbbbbbbooooooooobbbbbbbbllo...................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo..................",
          ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.................",
          "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo................",
          "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo................",
          "...............ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo...............",
          "...............ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooooooobbbbbsso...............",
          "..............ollbbbbboosssssssssssssssssssssssssssssssssssssssssssssssssoobbbbslo..............",
          "..............ollbbbbossssssoocccoossssssssssssssssssssssssssoocccoosssssssobbbsso..............",
          "..............ollbbbossssssocccccccossssssssssssssssssssssssocccccccosssssssobbsso..............",
          "..............ollbbosssssssocccccccossssssssssssssssssssssssocccccccossssssssobsso..............",
          "..............ollbbosssssssocccccccossssssssssssssssssssssssocccccccossssssssobsso..............",
          "..............ollbossssssssocccccccossssssssssssssssssssssssocccccccosssssssssosso..............",
          "..............ollbosssssssssoocccoossssssssssssssssssssssssssoocccoossssssssssosso..............",
          "..............ollbossssssssssooooossssssssssssssssssssssssssssooooosssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssssssobsso..............",
          "...............ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
          "...............ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssssobsso...............",
          "................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssobsso................",
          ".................ollboosssssssssssssssssscccccccccccccccsssssssssssssssssoobsso.................",
          "..................ollsbosssssssssssscccccccccccccccccccccccccsssssssssssobssso..................",
          "...................ollsbooossssscccccccccccccccccccccccccccccccccssssooobssso...................",
          "....................oolsssbooccccccccccccsssssssssssssssccccccccccccobssssoo....................",
          "......................ollsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssso......................",
          ".......................ooosssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssssooo.......................",
          "..........................oolsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssoo..........................",
          "............................ooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbooo............................",
          "...............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...............................",
          "................................ollbbbbbbbbbbbbbbbbbbbbbbbbbbsso................................",
          "..............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo..............................",
          "............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbloo............................",
          "...........................ollllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllllo...........................",
          "..........................olllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo..........................",
          ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.........................",
          ".................oooooooooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbloooooooooo................",
          "................ollllllllllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollllllllllo...............",
          "..............oolllllllllllloobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolllllllllllloo.............",
          "..............ollbbbbbbbbbbllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbllo.............",
          ".............ollbbbbbbbbbbbbllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbllo............",
          "............ollbbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbslo...........",
          "............ollbbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbslo...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          ".............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso............",
          "..............ollbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbsso.............",
          "..............oolsssssssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolsssssssssssoo.............",
          "................ollssssssssoollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.ollsssssssso...............",
          ".................oooooooooo..ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..oooooooooo................",
          ".............................ollbbbbbbbbbbbbbbsssssbbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbbbbsssssbbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbbbbooooobbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollssssssssssssso.....ollssssssssssssso............................",
          ".............................ollssssssssssssso.....ollssssssssssssso............................",
          ".............................ooooooooooooooooo.....ooooooooooooooooo............................"
        ]
      ],
      "steps" : [
        [
          0,
          500
        ],
        [
          1,
          1000
        ],
        [
          1,
          700
        ]
      ]
    },
    "hover" : {
      "frames" : [
        [
          "................................................................................................",
          "........................................oooooooooooooooo........................................",
          "....................................oooolllllllllllllllloooo....................................",
          ".................................ooollllllllllllllllllllllllooo.................................",
          "................................olllllllbbbbbbbbbbbbbbbblllllllo................................",
          ".........................ooooooollllbbbbbbbbbbbbbbbbbbbbbbbbllllooooooo.........................",
          "........................ollllolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllollllo........................",
          ".......................ollllolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllollllo.......................",
          ".......................ollbbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslobbslo.......................",
          ".......................ollbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslobsso.......................",
          ".......................ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslosso.......................",
          ".......................ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslosso.......................",
          "........................oollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsloo........................",
          "........................oollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssoo........................",
          ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........................",
          ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........................",
          "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
          "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
          "........................ollbooooooooooooooooobbbbbbooooooooooooooooobsso........................",
          "........................ollboeeeggggeeeeeeeeobbbbbboeeeggggeeeeeeeeobsso........................",
          "........................ollboeeeggggeeeeeeeeobbbbbboeeeggggeeeeeeeeobsso........................",
          "........................ollboeeeggggeeeeeeeeobbbbbboeeeggggeeeeeeeeobsso........................",
          "........................ollboeeeeeeeeeeeeeeeobbbbbboeeeeeeeeeeeeeeeobsso........................",
          "........................ollbboeeeeeeeeeeeeeobbbbbbbboeeeeeeeeeeeeeobbsso........................",
          ".......................ollbbbboeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeobbbbsso.......................",
          "......................ollbbbbbboeeeeeeeeeobbbbbbbbbbbboeeeeeeeeeobbbbbbslo......................",
          ".....................ollbbbbbbbbooooooooobbbbbbbbbbbbbbooooooooobbbbbbbbllo.....................",
          "....................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo....................",
          "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...................",
          "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo...................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo..................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..................",
          ".................ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooobbbbbslo.................",
          ".................ollbbbboosssssssssssssssssssssssssssssssssssssssssssssoobbbsso.................",
          ".................ollbbbosssssssoocoossssssssssssssssssssssssoocoossssssssobbsso.................",
          ".................ollbbosssssssocccccossssssssssssssssssssssocccccossssssssobsso.................",
          ".................ollbosssssssocccccccossssssssssssssssssssocccccccossssssssosso.................",
          ".................ollbosssssssocccccccossssssssssssssssssssocccccccossssssssosso.................",
          "................ollbossssssssocccccccossssssssssssssssssssocccccccossssssssobsso................",
          "................ollbosssssssssocccccossssssssssssssssssssssocccccossssssssssosso................",
          "................ollbosssssssssooooooossssssssssssssssssssssooooooossssssssssosso................",
          "................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssobsso................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssobsso.................",
          "..................ollossssssssssssssssssssssssssssssssssssssssssssssssssssosso..................",
          "..................ollbossssssssssssssssssssssssssssssssssssssssssssssssssobsso..................",
          "...................ollossssssssssssssssssssssssssssssssssssssssssssssssssosso...................",
          "...................ollbccccccccccssssssssssssssssssssssssssssssscccccccccbsso...................",
          "....................ollccccccccccccccccccccccccccccccccccccccccccccccccccsso....................",
          "....................ollbccccccccccccccccccccccccccccccccccccccccccccccccbsso....................",
          ".....................ollsbssssssscccccccccccccccccccccccccccccccssssssbssso.....................",
          "......................ollsbssssssssssssssssssssssssssssssssssssssssssbssso......................",
          ".......................oolssbssssssssssssssssssssssssssssssssssssssbsssoo.......................",
          ".........................ollsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssso.........................",
          "..........................oolsssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssssoo..........................",
          "............................ooossbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssooo............................",
          "...............................ooobbbbbbbbbbbbbbbbbbbbbbbbbbbbooo...............................",
          "..................................ollbbbbbbbbbbbbbbbbbbbbbbsso..................................",
          ".................................ollbbbbbbbbbbbbbbbbbbbbbbbbsso.................................",
          "...............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo...............................",
          "..............................olllbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo..............................",
          ".....................ooooooooolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo.oooooooo....................",
          "...................oolllllllloobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbloolllllllloo..................",
          "..................ollllllllllllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollllllllllllo.................",
          ".................olllbbbbbbbblllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbolllbbbbbbbblllo................",
          ".................ollbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbslo................",
          "................ollbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbslo...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          ".................ollbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbsso................",
          ".................ollsbbbbbbbbsssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsbbbbbbbbssso................",
          "..................ollssssssssssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsssssssssso.................",
          "...................oolsssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolsssssssoo..................",
          ".....................oooooooollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssooooooooo....................",
          ".............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbbbbsssssbbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbbbbsssssbbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbbbbooooobbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollssssssssssso.....ollssssssssssso..............................",
          "...............................ollssssssssssso.....ollssssssssssso..............................",
          "...............................ooooooooooooooo.....ooooooooooooooo.............................."
        ],
        [
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          ".....................................oooooooooooooooooooooo.....................................",
          ".................................oooolllllllllllllllllllllloooo.................................",
          "...............................oolllllllllllllllllllllllllllllloo...............................",
          "........................ooooooollllllbbbbbbbbbbbbbbbbbbbbbbllllllooooooo........................",
          ".......................olllloolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllloollllo.......................",
          "......................ollllolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllollllo......................",
          ".....................ollbbolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllobbllo.....................",
          ".....................ollbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllobslo.....................",
          ".....................ollbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslobsso.....................",
          ".....................ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslosso.....................",
          "......................olollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssoso......................",
          ".......................oollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssoo.......................",
          ".......................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.......................",
          ".......................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.......................",
          ".......................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.......................",
          ".......................ollooooooooooooooooooobbbbbbooooooooooooooooooosso.......................",
          ".......................olloeeeeggggeeeeeeeeeobbbbbboeeeeggggeeeeeeeeeosso.......................",
          "......................ollboeeeeggggeeeeeeeeeobbbbbboeeeeggggeeeeeeeeeobsso......................",
          "......................ollboeeeeggggeeeeeeeeeobbbbbboeeeeggggeeeeeeeeeobsso......................",
          "......................ollbboeeeeeeeeeeeeeeeobbbbbbbboeeeeeeeeeeeeeeeobbsso......................",
          "......................ollbboeeeeeeeeeeeeeeeobbbbbbbboeeeeeeeeeeeeeeeobbsso......................",
          "......................ollbbboeeeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeeeobbbsso......................",
          "....................oolbbbbbboeeeeeeeeeeeobbbbbbbbbbbboeeeeeeeeeeeobbbbbbsoo....................",
          "...................ollbbbbbbbbooooeeeoooobbbbbbbbbbbbbbooooeeeoooobbbbbbbbllo...................",
          "..................olllbbbbbbbbbbbbooobbbbbbbbbbbbbbbbbbbbbbooobbbbbbbbbbbblllo..................",
          ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.................",
          ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.................",
          "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo................",
          "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso................",
          "...............ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooooooobbbbbslo...............",
          "...............ollbbbboosssssssssssssssssssssssssssssssssssssssssssssssssoobbbsso...............",
          "...............ollbbbossssssssocccossssssssssssssssssssssssssocccosssssssssobbsso...............",
          "...............ollbbosssssssoocccccoossssssssssssssssssssssoocccccoossssssssobsso...............",
          "..............ollbbossssssssocccccccossssssssssssssssssssssocccccccosssssssssobsso..............",
          "..............ollbbossssssssocccccccossssssssssssssssssssssocccccccosssssssssobsso..............",
          "..............ollbosssssssssocccccccossssssssssssssssssssssocccccccossssssssssosso..............",
          "..............ollbossssssssssoocccoossssssssssssssssssssssssoocccoosssssssssssosso..............",
          "..............ollbosssssssssssooooossssssssssssssssssssssssssooooossssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssssssobsso..............",
          "...............ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
          "...............ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
          "...............ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
          "...............ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssssobsso...............",
          "................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssobsso................",
          ".................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssobsso.................",
          "..................ollbcccccccccsssssssssssssssssssssssssssssssssssccccccccbsso..................",
          "..................ollsbccccccccccccccccccccccccccccccccccccccccccccccccccbssso..................",
          "...................oolsbccccccccccccccccccccccccccccccccccccccccccccccccbssoo...................",
          ".....................ollsbssssscccccccccccccccccccccccccccccccccccssssbssso.....................",
          "......................ollssbssssssssssssssssssssssssssssssssssssssssbsssso......................",
          ".......................oolssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssssoo.......................",
          ".........................oolssssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssssssoo.........................",
          "...........................ooosbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsooo...........................",
          "..............................oooobbbbbbbbbbbbbbbbbbbbbbbbbbbboooo..............................",
          "..................................ollbbbbbbbbbbbbbbbbbbbbbbsso..................................",
          "...............................ooobbbbbbbbbbbbbbbbbbbbbbbbbbbbooo...............................",
          ".............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo.............................",
          "............................olllllbbbbbbbbbbbbbbbbbbbbbbbbbbbblllllo............................",
          "...................ooooooooolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo.oooooooo..................",
          ".................oolllllllloobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbloolllllllloo................",
          "...............oolllllllllllloobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolllllllllllloo..............",
          "...............olllbbbbbbbblllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbolllbbbbbbbblllo..............",
          "..............ollbbbbbbbbbbbbllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbllo.............",
          "..............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso.............",
          ".............ollbbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbslo............",
          ".............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso............",
          ".............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso............",
          ".............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso............",
          ".............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso............",
          ".............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso............",
          ".............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso............",
          "..............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso.............",
          "..............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso.............",
          "...............ollsbbbbbbbbsssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsbbbbbbbbssso..............",
          "...............oolsssssssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolsssssssssssoo..............",
          ".................oolsssssssoosbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoolsssssssoo................",
          "...................ooooooooollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.oooooooo..................",
          "............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso............................",
          "..............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbooooobbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollsssssssssssso.....ollsssssssssssso.............................",
          "..............................ollsssssssssssso.....ollsssssssssssso.............................",
          "..............................oooooooooooooooo.....oooooooooooooooo............................."
        ]
      ],
      "steps" : [
        [
          0,
          100
        ],
        [
          1,
          100
        ],
        [
          0,
          50
        ]
      ]
    },
    "idle" : {
      "frames" : [
        [
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          ".......................................oooooooooooooooooo.......................................",
          "...................................oooolllllllllllllllllloooo...................................",
          ".................................oolllllllllllllllllllllllllloo.................................",
          "...........................o...oollllllbbbbbbbbbbbbbbbbbblllllloo...o...........................",
          "........................ooolooollllbbbbbbbbbbbbbbbbbbbbbbbbbbllllooolooo........................",
          ".......................ollllollllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllllollllo.......................",
          "......................ollllolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllollllo......................",
          "......................ollbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllobslo......................",
          ".....................ollbbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslobbslo.....................",
          "......................ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslosso......................",
          "......................ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssosso......................",
          ".......................oollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsloo.......................",
          "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
          "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
          ".......................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.......................",
          ".......................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.......................",
          ".......................ollooooooooooooooooooobbbbbbooooooooooooooooooosso.......................",
          ".......................olloeeeeggggeeeeeeeeeobbbbbboeeeeggggeeeeeeeeeosso.......................",
          ".......................olloeeeeggggeeeeeeeeeobbbbbboeeeeggggeeeeeeeeeosso.......................",
          ".......................ollboeeeggggeeeeeeeeobbbbbbbboeeeggggeeeeeeeeobsso.......................",
          ".......................ollboeeeeeeeeeeeeeeeobbbbbbbboeeeeeeeeeeeeeeeobsso.......................",
          ".......................ollboeeeeeeeeeeeeeeeobbbbbbbboeeeeeeeeeeeeeeeobsso.......................",
          "......................ollbbboeeeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeeeobbbsso......................",
          ".....................ollbbbbbooeeeeeeeeeoobbbbbbbbbbbbooeeeeeeeeeoobbbbbslo.....................",
          "....................ollbbbbbbbbooooeoooobbbbbbbbbbbbbbbbooooeoooobbbbbbbbllo....................",
          "...................ollbbbbbbbbbbbbbobbbbbbbbbbbbbbbbbbbbbbbbobbbbbbbbbbbbbllo...................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo..................",
          ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.................",
          ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.................",
          "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo................",
          "................ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooooobbbbbsso................",
          "................ollbbbboosssssssssssssssssssssssssssssssssssssssssssssssoobbbsso................",
          "...............ollbbbbosssssssocccossssssssssssssssssssssssssocccossssssssobbbsso...............",
          "...............ollbbbosssssssocccccossssssssssssssssssssssssocccccossssssssobbsso...............",
          "...............ollbbosssssssocccccccossssssssssssssssssssssocccccccossssssssobsso...............",
          "...............ollbbosssssssocccccccossssssssssssssssssssssocccccccossssssssobsso...............",
          "...............ollbossssssssocccccccossssssssssssssssssssssocccccccosssssssssosso...............",
          "...............ollbosssssssssocccccossssssssssssssssssssssssocccccossssssssssosso...............",
          "...............ollbossssssssssooooossssssssssssssssssssssssssooooosssssssssssosso...............",
          "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
          "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
          "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
          "...............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
          "...............ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssssobsso...............",
          "................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssobsso................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollbcccccccccccsssssssssssssssssssssssssssssssssccccccccccbsso.................",
          "..................ollbccccccccccccccccccccccccccccccccccccccccccccccccccccbsso..................",
          "...................ollbccccccccccccccccccccccccccccccccccccccccccccccccccbsso...................",
          "....................ollbsssssssscccccccccccccccccccccccccccccccccsssssssbsso....................",
          ".....................ollsbssssssssssssssssssssssssssssssssssssssssssssbssso.....................",
          "......................ollssbssssssssssssssssssssssssssssssssssssssssbsssso......................",
          ".......................oolsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssoo.......................",
          ".........................oolsssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssssoo.........................",
          "...........................oolssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssoo...........................",
          ".............................oooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbboooo.............................",
          ".................................ollbbbbbbbbbbbbbbbbbbbbbbbbsso.................................",
          "................................ollbbbbbbbbbbbbbbbbbbbbbbbbbbsso................................",
          "..............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo..............................",
          ".............................olllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo.............................",
          "....................ooooooo.olllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo..ooooooo...................",
          "..................oollllllloolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblloollllllloo.................",
          "................oollllllllllloobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboollllllllllloo...............",
          "................olllbbbbbbblllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbolllbbbbbbblllo...............",
          "...............ollbbbbbbbbbbbllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbllo..............",
          "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
          "..............ollbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbslo.............",
          "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
          "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
          "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
          "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
          "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
          "..............ollbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbsso.............",
          "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
          "...............ollbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbsso..............",
          "................ollsbbbbbbbsssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsbbbbbbbssso...............",
          "................oolssssssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolssssssssssoo...............",
          "..................oolssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoolssssssoo.................",
          "....................oooooooollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.ooooooo...................",
          "............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbooooobbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollsssssssssssso.....ollsssssssssssso.............................",
          "..............................ollsssssssssssso.....ollsssssssssssso.............................",
          "..............................oooooooooooooooo.....oooooooooooooooo............................."
        ],
        [
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          ".....................................oooooooooooooooooooooo.....................................",
          "..................................ooollllllllllllllllllllllooo..................................",
          "................................oolllllllllllllllllllllllllllloo................................",
          "..........................oooo.olllllbbbbbbbbbbbbbbbbbbbbbblllllo.oooo..........................",
          "........................oollloolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbllloollloo........................",
          ".......................ollllolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllollllo.......................",
          "......................olllbolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllloblllo......................",
          "......................ollbbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslobbslo......................",
          "......................ollbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslobsso......................",
          "......................ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslosso......................",
          ".......................olollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsloso.......................",
          "........................oollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssoo........................",
          "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
          "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
          "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
          "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
          "........................ollooooooooooooooooobbbbbbbbooooooooooooooooosso........................",
          "........................olloeeeggggeeeeeeeeobbbbbbbboeeeggggeeeeeeeeosso........................",
          "........................olloeeeggggeeeeeeeeobbbbbbbboeeeggggeeeeeeeeosso........................",
          "........................olloeeeggggeeeeeeeeobbbbbbbboeeeggggeeeeeeeeosso........................",
          "........................olloeeeeeeeeeeeeeeeobbbbbbbboeeeeeeeeeeeeeeeosso........................",
          "........................ollboeeeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeeeobsso........................",
          "......................oolbbboeeeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeeeobbbsoo......................",
          ".....................ollbbbbbooeeeeeeeeeoobbbbbbbbbbbbooeeeeeeeeeoobbbbbllo.....................",
          "....................olllbbbbbbbooooooooobbbbbbbbbbbbbbbbooooooooobbbbbbblllo....................",
          "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...................",
          "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo...................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo..................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..................",
          ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo.................",
          ".................ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooobbbbbsso.................",
          "................ollbbbbboosssssssssssssssssssssssssssssssssssssssssssssoobbbbslo................",
          "................ollbbbbossssssoocoossssssssssssssssssssssssssoocoosssssssobbbsso................",
          "................ollbbbossssssocccccossssssssssssssssssssssssocccccosssssssobbsso................",
          "................ollbbossssssocccccccossssssssssssssssssssssocccccccosssssssobsso................",
          "................ollbbossssssocccccccossssssssssssssssssssssocccccccosssssssobsso................",
          "................ollbosssssssocccccccossssssssssssssssssssssocccccccossssssssosso................",
          "................ollbossssssssocccccossssssssssssssssssssssssocccccosssssssssosso................",
          "................ollbosssssssssooooossssssssssssssssssssssssssooooossssssssssosso................",
          "................ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssobsso................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssobsso.................",
          "..................ollbccccccccccssssssssssssssssssssssssssssssssscccccccccbsso..................",
          "...................ollccccccccccccccccccccccccccccccccccccccccccccccccccccsso...................",
          "...................ollbccccccccccccccccccccccccccccccccccccccccccccccccccbsso...................",
          "....................ollbsssssssscccccccccccccccccccccccccccccccccsssssssbsso....................",
          ".....................ollsbssssssssssssssssssssssssssssssssssssssssssssbssso.....................",
          "......................ollssbssssssssssssssssssssssssssssssssssssssssbsssso......................",
          ".......................oolsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssoo.......................",
          ".........................oolssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssssoo.........................",
          "...........................oolssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssssoo...........................",
          ".............................ooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbooo.............................",
          "................................oolbbbbbbbbbbbbbbbbbbbbbbbbbbsoo................................",
          "..................................ollbbbbbbbbbbbbbbbbbbbbbbsso..................................",
          "................................oolbbbbbbbbbbbbbbbbbbbbbbbbbbsoo................................",
          "..............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo..............................",
          ".....................oooooo..ollllbbbbbbbbbbbbbbbbbbbbbbbbbbbbllllo...oooooo....................",
          "...................oolllllloolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllooolllllloo..................",
          ".................oolllllllllloobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolllllllllloo................",
          ".................olllbbbbbblllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbolllbbbbbblllo................",
          "................ollbbbbbbbbbbllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbllo...............",
          "................ollbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbsso...............",
          "...............ollbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbslo..............",
          "...............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso..............",
          "...............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso..............",
          "...............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso..............",
          "...............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso..............",
          "...............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso..............",
          "...............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso..............",
          "................ollbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbsso...............",
          ".................ollsbbbbbbsssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsbbbbbbssso................",
          ".................oolsssssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolsssssssssoo................",
          "...................oolsssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoolsssssoo..................",
          ".....................ooooooollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.oooooo....................",
          "...........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...........................",
          "............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso............................",
          "..............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbsssssbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbooooobbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbsso.....ollbbbbbbbbbbsso.............................",
          "..............................ollsssssssssssso.....ollsssssssssssso.............................",
          "..............................ollsssssssssssso.....ollsssssssssssso.............................",
          "..............................oooooooooooooooo.....oooooooooooooooo............................."
        ]
      ],
      "steps" : [
        [
          0,
          1000
        ],
        [
          0,
          1000
        ],
        [
          1,
          600
        ]
      ]
    },
    "tap" : {
      "frames" : [
        [
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          "................................................................................................",
          ".......................................oooooooooooooooooo.......................................",
          "..................................ooooollllllllllllllllllooooo..................................",
          "................................oolllllllllllllllllllllllllllloo................................",
          ".........................ooo..oolllllllbbbbbbbbbbbbbbbbbbllllllloo..ooo.........................",
          ".......................oollloollllbbbbbbbbbbbbbbbbbbbbbbbbbbbblllloollloo.......................",
          ".....................oollllollllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllllolllloo.....................",
          ".....................olllbolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllloblllo.....................",
          "....................ollbbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllobbllo....................",
          "....................ollbbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslobbsso....................",
          ".....................ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslosso.....................",
          ".....................olollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsloso.....................",
          "......................oollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsloo......................",
          ".......................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.......................",
          "......................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso......................",
          "......................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso......................",
          "......................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso......................",
          "......................olloooooggggoooooooooobbbbbbbboooooggggoooooooooosso......................",
          "......................olloeeeeggggeeeeeeeeeobbbbbbbboeeeeggggeeeeeeeeeosso......................",
          "......................olloeeeeggggeeeeeeeeeobbbbbbbboeeeeggggeeeeeeeeeosso......................",
          "......................olloeeeeeeeeeeeeeeeeeobbbbbbbboeeeeeeeeeeeeeeeeeosso......................",
          "......................ollboeeeeeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeeeeeobsso......................",
          ".....................ollbboeeeeeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeeeeeobbsso.....................",
          "....................ollbbbbooeeeeeeeeeeeoobbbbbbbbbbbbooeeeeeeeeeeeoobbbbslo....................",
          "...................ollbbbbbbboooeeeeeooobbbbbbbbbbbbbbbboooeeeeeooobbbbbbbllo...................",
          "..................ollbbbbbbbbbbbooooobbbbbbbbbbbbbbbbbbbbbbooooobbbbbbbbbbbllo..................",
          ".................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo.................",
          "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo................",
          "................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo................",
          "...............ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo...............",
          "...............ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooooooobbbbbsso...............",
          "..............ollbbbbboosssssssssssssssssssssssssssssssssssssssssssssssssoobbbbslo..............",
          "..............ollbbbbossssssoocccoossssssssssssssssssssssssssoocccoosssssssobbbsso..............",
          "..............ollbbbossssssocccccccossssssssssssssssssssssssocccccccosssssssobbsso..............",
          "..............ollbbosssssssocccccccossssssssssssssssssssssssocccccccossssssssobsso..............",
          "..............ollbbosssssssocccccccossssssssssssssssssssssssocccccccossssssssobsso..............",
          "..............ollbossssssssocccccccossssssssssssssssssssssssocccccccosssssssssosso..............",
          "..............ollbosssssssssoocccoossssssssssssssssssssssssssoocccoossssssssssosso..............",
          "..............ollbossssssssssooooossssssssssssssssssssssssssssooooosssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbosssssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso..............",
          "..............ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssssssobsso..............",
          "...............ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssssosso...............",
          "...............ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssssobsso...............",
          "................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssssosso................",
          "................ollbcccccccccccsssssssssssssssssssssssssssssssssssccccccccccbsso................",
          ".................ollbccccccccccccccccccccccccccccccccccccccccccccccccccccccbsso.................",
          "..................ollsbccccccccccccccccccccccccccccccccccccccccccccccccccbssso..................",
          "...................ollsbssssssscccccccccccccccccccccccccccccccccccssssssbssso...................",
          "....................oolsssbssssssssssssssssssssssssssssssssssssssssssbssssoo....................",
          "......................ollsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssso......................",
          ".......................ooosssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsssssooo.......................",
          "..........................oolsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssoo..........................",
          "............................ooobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbooo............................",
          "...............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso...............................",
          "................................ollbbbbbbbbbbbbbbbbbbbbbbbbbbsso................................",
          "..............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo..............................",
          "............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbloo............................",
          ".................ooooooooooollllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllllo.oooooooooo................",
          "................ollllllllllollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllollllllllllo...............",
          "..............oolllllllllllloobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolllllllllllloo.............",
          "..............ollbbbbbbbbbbllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbllo.............",
          ".............ollbbbbbbbbbbbbllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbllo............",
          "............ollbbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbslo...........",
          "............ollbbbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbslo...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          "............ollbbbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbbbsso...........",
          ".............ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso............",
          "..............ollbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbsso.............",
          "..............oolsssssssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolsssssssssssoo.............",
          "................ollssssssssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsollsssssssso...............",
          ".................oooooooooolsbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssoooooooooo................",
          "..........................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo..........................",
          "............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbbbbsssssbbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbbbbsssssbbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbbbbooooobbbbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollbbbbbbbbbbbsso.....ollbbbbbbbbbbbsso............................",
          ".............................ollssssssssssssso.....ollssssssssssssso............................",
          ".............................ollssssssssssssso.....ollssssssssssssso............................",
          ".............................ooooooooooooooooo.....ooooooooooooooooo............................"
        ],
        [
          "................................................................................................",
          "........................................oooooooooooooooo........................................",
          "....................................oooolllllllllllllllloooo....................................",
          ".................................ooollllllllllllllllllllllllooo.................................",
          "................................olllllllbbbbbbbbbbbbbbbblllllllo................................",
          ".........................ooooooollllbbbbbbbbbbbbbbbbbbbbbbbbllllooooooo.........................",
          "........................ollllolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllollllo........................",
          ".......................ollllolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllollllo.......................",
          ".......................ollbbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslobbslo.......................",
          ".......................ollbollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslobsso.......................",
          ".......................ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslosso.......................",
          ".......................ollollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslosso.......................",
          "........................oollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsloo........................",
          "........................oollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssoo........................",
          ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........................",
          ".........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.........................",
          "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
          "........................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso........................",
          "........................ollbooooooooooooooooobbbbbbooooooooooooooooobsso........................",
          "........................ollboeeeggggeeeeeeeeobbbbbboeeeggggeeeeeeeeobsso........................",
          "........................ollboeeeggggeeeeeeeeobbbbbboeeeggggeeeeeeeeobsso........................",
          "........................ollboeeeggggeeeeeeeeobbbbbboeeeggggeeeeeeeeobsso........................",
          "........................ollboeeeeeeeeeeeeeeeobbbbbboeeeeeeeeeeeeeeeobsso........................",
          "........................ollbboeeeeeeeeeeeeeobbbbbbbboeeeeeeeeeeeeeobbsso........................",
          ".......................ollbbbboeeeeeeeeeeeobbbbbbbbbboeeeeeeeeeeeobbbbsso.......................",
          "......................ollbbbbbboeeeeeeeeeobbbbbbbbbbbboeeeeeeeeeobbbbbbslo......................",
          ".....................ollbbbbbbbbooooooooobbbbbbbbbbbbbbooooooooobbbbbbbbllo.....................",
          "....................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo....................",
          "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbllo...................",
          "...................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo...................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbslo..................",
          "..................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..................",
          ".................ollbbbbbbooooooooooooooooooooooooooooooooooooooooooooobbbbbslo.................",
          ".................ollbbbboosssssssssssssssssssssssssssssssssssssssssssssoobbbsso.................",
          ".................ollbbbosssssssoocoossssssssssssssssssssssssoocoossssssssobbsso.................",
          ".................ollbbosssssssocccccossssssssssssssssssssssocccccossssssssobsso.................",
          ".................ollbosssssssocccccccossssssssssssssssssssocccccccossssssssosso.................",
          ".................ollbosssssssocccccccossssssssssssssssssssocccccccossssssssosso.................",
          "................ollbossssssssocccccccossssssssssssssssssssocccccccossssssssobsso................",
          "................ollbosssssssssocccccossssssssssssssssssssssocccccossssssssssosso................",
          "................ollbosssssssssooooooossssssssssssssssssssssooooooossssssssssosso................",
          "................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssssobsso................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollossssssssssssssssssssssssssssssssssssssssssssssssssssssosso.................",
          ".................ollbossssssssssssssssssssssssssssssssssssssssssssssssssssobsso.................",
          "..................ollossssssssssssssssssssssssssssssssssssssssssssssssssssosso..................",
          "..................ollbossssssssssssssssssssssssssssssssssssssssssssssssssobsso..................",
          "...................ollossssssssssssssssssssssssssssssssssssssssssssssssssosso...................",
          "...................ollbccccccccccssssssssssssssssssssssssssssssscccccccccbsso...................",
          "....................ollccccccccccccccccccccccccccccccccccccccccccccccccccsso....................",
          "....................ollbccccccccccccccccccccccccccccccccccccccccccccccccbsso....................",
          ".....................ollsbssssssscccccccccccccccccccccccccccccccssssssbssso.....................",
          "......................ollsbssssssssssssssssssssssssssssssssssssssssssbssso......................",
          ".......................oolssbssssssssssssssssssssssssssssssssssssssbsssoo.......................",
          ".........................ollsssbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssso.........................",
          "..........................oolsssssbbbbbbbbbbbbbbbbbbbbbbbbbbbbssssssoo..........................",
          "............................ooossbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssooo............................",
          "...............................ooobbbbbbbbbbbbbbbbbbbbbbbbbbbbooo...............................",
          "..................................ollbbbbbbbbbbbbbbbbbbbbbbsso..................................",
          ".................................ollbbbbbbbbbbbbbbbbbbbbbbbbsso.................................",
          "...............................oolbbbbbbbbbbbbbbbbbbbbbbbbbbbbsoo...............................",
          "..............................olllbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo..............................",
          ".....................ooooooooolllbbbbbbbbbbbbbbbbbbbbbbbbbbbbbblllo.oooooooo....................",
          "...................oolllllllloobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbloolllllllloo..................",
          "..................ollllllllllllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollllllllllllo.................",
          ".................olllbbbbbbbblllobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbolllbbbbbbbblllo................",
          ".................ollbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbslo................",
          "................ollbbbbbbbbbbbbslobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbslo...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          "................ollbbbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbbbsso...............",
          ".................ollbbbbbbbbbbssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollbbbbbbbbbbsso................",
          ".................ollsbbbbbbbbsssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsbbbbbbbbssso................",
          "..................ollssssssssssobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbollsssssssssso.................",
          "...................oolsssssssoobbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbboolsssssssoo..................",
          ".....................oooooooollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbssooooooooo....................",
          ".............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso.............................",
          "..............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbbbbbbbbbbbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbbbbsssssbbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbbbbsssssbbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbbbbooooobbbbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollbbbbbbbbbsso.....ollbbbbbbbbbsso..............................",
          "...............................ollssssssssssso.....ollssssssssssso..............................",
          "...............................ollssssssssssso.....ollssssssssssso..............................",
          "...............................ooooooooooooooo.....ooooooooooooooo.............................."
        ]
      ],
      "steps" : [
        [
          0,
          100
        ],
        [
          1,
          150
        ],
        [
          0,
          50
        ]
      ]
    }
  }
}
"""#

// try! is deliberate: this parses a compile-time constant, so a throw here is a
// broken build, not a runtime condition to survive. Failing loudly beats
// limping on with a pet nobody drew.
let builtinPet = try! loadCustomPet(Data(BUILTIN_MANIFEST.utf8))


// Runtime home: PERCHLING_HOME (set by pet.sh) > $CLAUDE_CONFIG_DIR/perchling > ~/.claude/perchling.
let env = ProcessInfo.processInfo.environment
// The host CLI's config directory, resolved on its own rather than derived from
// `root`: the session registry inside it belongs to the CLI, and PERCHLING_HOME
// may point anywhere — a harness scratch directory included.
let configDir = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
let root = env["PERCHLING_HOME"].map { URL(fileURLWithPath: $0) }
    ?? configDir.appendingPathComponent("perchling")
let registryURL = configDir.appendingPathComponent("sessions")
// The desktop app's session records, which carry the title the user sees in the
// sidebar. Not under the CLI's config directory — it is a different program's
// state — so this is the one path taken from the home directory directly.
let titlesURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
try? FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"),
                                         withIntermediateDirectories: true)

// Where the shipped pets live: PERCHLING_EXAMPLES, set by pet.sh to the
// examples/ of whichever copy launched us — a checkout when run from a
// checkout, the installed version otherwise, exactly as SRC already behaves.
// Unset means no shipped group; the overlay must stay launchable by hand.
let examplesRoot: URL? = env["PERCHLING_EXAMPLES"].map { URL(fileURLWithPath: $0) }

// CLI validation for the authoring loop: same parser as the runtime, so an
// "OK" here means the overlay will actually render the manifest. Anything
// unrecognized must NOT fall through to the overlay — a mistyped flag that
// silently launches a second pet and blocks forever is indistinguishable
// from a hung command, and the pet outlives the terminal that spawned it.
let argv = CommandLine.arguments
if argv.count >= 2 {
    switch argv[1] {
    case "--export":
        print(exportBuiltin())
        exit(0)
    case "--validate":
        let target = argv.count >= 3 ? URL(fileURLWithPath: argv[2]) : root.appendingPathComponent("pet.json")
        do {
            let pet = try loadCustomPet(target)
            let moods = pet.frames.keys.map { $0.rawValue }.sorted().joined(separator: ", ")
            // The eye box is reported because a manifest can declare one and
            // still get no blink — synthesis needs lit pixels inside the box,
            // and silently having none is the failure worth naming here.
            var eyes = "no eyes declared"
            if let e = pet.eyes {
                eyes = "eyes \(e.x1 - e.x0 + 1)x\(e.y1 - e.y0 + 1) at \(e.x0),\(e.y0) range \(e.range)"
                eyes += pet.blinkFrame == nil ? ", blink UNAVAILABLE (no lit pixels in box)" : ", blink ok"

            }
            let seqLines = SeqKind.allCases.compactMap { k -> String? in
                guard let s = pet.sequences[k] else { return nil }
                let declared = s.steps.map { String($0.ms) }.joined(separator: "/")
                let resolved = s.steps.map { String($0.ticks * TICK_MS) }.joined(separator: "/")
                // Saying the rounding out loud is the point. Only when there is
                // rounding to say: an arrow between two identical strings is
                // noise on every well-chosen timeline.
                let rounded = s.steps.contains { $0.ticks * TICK_MS != $0.ms }
                let timing = rounded ? "\(declared)ms -> \(resolved)ms" : "\(declared)ms"
                // Only where it does something, exactly as `mirror` below:
                // printing a repeat count on a kind the warning calls ignored
                // is one line contradicting the next.
                let plays = (k.mood == nil && k != .drag) ? s.plays : 1
                let secs = String(format: "%.2fs", Double(s.totalTicks * plays * TICK_MS) / 1000)
                // A reaction is over when its timeline runs out; a mood plays
                // for as long as the pet is in that mood, so the number worth
                // printing is its cycle, not its lifetime.
                let shape = (k == .drag || k.mood != nil) ? "loop" : "total"
                let runs = plays > 1 ? " x\(plays)" : ""
                let name = k.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
                return "  \(name) \(s.frames.count) frames, \(s.steps.count) steps\(runs)  "
                    + "\(timing)  (\(s.totalTicks) ticks, \(secs) \(shape))"
                    // Only where it does something. Saying it on a kind the
                    // warning below calls ignored is one line contradicting
                    // the next.
                    + (s.mirror && k == .drag ? ", mirrors when dragged left" : "")
            }
            print("OK: \(pet.name) \(pet.width)x\(pet.height) @\(Int(pet.scale))x [\(moods)] — \(eyes)")
            // One line per sequence: a timeline is six numbers where a single
            // duration was one, and the locomotion row on a real pet is eight.
            if seqLines.isEmpty { print("  no sequences") } else { print(seqLines.joined(separator: "\n")) }
            // In grid rows, not points: the on-screen distance is rows * scale,
            // so the same manifest at scale 2 moves the chrome twice as far.
            let moodTop = pet.frames.values
                .map { $0.firstIndex { $0.contains { $0 != nil } } ?? 0 }
                .min() ?? 0
            if moodTop != pet.inkTop {
                print("inkTop: \(pet.inkTop) (moods alone: \(moodTop) — sequences reach higher, chrome moves up \(moodTop - pet.inkTop) rows)")
            }
            // Silently ignoring it would be indistinguishable from a mirror that
            // simply never triggers, which is an afternoon nobody should spend.
            for k in SeqKind.allCases where k != .drag && pet.sequences[k]?.mirror == true {
                let why = k.mood == nil ? "a one-shot burst" : "a resting state"
                FileHandle.standardError.write(Data("warning: sequences.\(k.rawValue).mirror is ignored — \(why) has no direction of travel\n".utf8))
            }
            // The mirror image of the rule above: `plays` counts runs of
            // something that ends, and only the bursts end on their own. Same
            // test as `shape` above, so the two lines cannot disagree about
            // which kinds run forever.
            for k in SeqKind.allCases where (k == .drag || k.mood != nil) && (pet.sequences[k]?.plays ?? 1) > 1 {
                let why = k == .drag ? "a drag loops until you let go" : "a mood loops until the mood changes"
                FileHandle.standardError.write(Data("warning: sequences.\(k.rawValue).plays is ignored — \(why)\n".utf8))
            }
            // Not an error: the timeline is already complete without it. But a
            // key that silently does nothing is the afternoon this repo keeps
            // paying for.
            for name in pet.legacyMsKeys {
                FileHandle.standardError.write(Data("warning: sequences.\(name).ms is ignored — timing comes from steps\n".utf8))
            }
            // Listed off the enum rather than spelled out, so the message
            // cannot name a set of sequences the parser no longer agrees with.
            let known = SeqKind.allCases.map { $0.rawValue }.joined(separator: ", ")
            for k in pet.unknownSequenceKeys {
                FileHandle.standardError.write(Data("warning: sequences.\(k) is not a recognised sequence (\(known)) — ignored\n".utf8))
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("invalid pet manifest: \(error)\n".utf8))
            exit(1)
        }
    default:
        FileHandle.standardError.write(Data("""
            perchling — desktop pet overlay for Claude Code
            usage: perchling                     run the overlay
                   perchling --validate [path]   check a pet manifest (default: <home>/pet.json)
                   perchling --export            print the built-in pet as a manifest
            unknown argument: \(argv[1])

            """.utf8))
        exit(2)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller(root: root, registry: registryURL, titles: titlesURL)
controller.run()
app.run()
