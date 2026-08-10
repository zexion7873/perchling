import AppKit

// The built-in pet is drawn from primitives, not a fixed bitmap, so its
// resolution is a knob: RES multiplies every grid coordinate while the
// silhouette stays put. RES 3 at 1 point per cell renders the same creature
// at 96x99 points with nine times the detail of the original 32x33 at 4.
let RES = 3
let GW = 32 * RES, GH = 33 * RES
let SCALE: CGFloat = 1

// Bounce and twitch are physical: roughly four points of travel regardless of
// how big a pet's cells are. Expressed in cells so the sprite grid stays the
// only coordinate system, and the canvas reserves three of those below the
// art for the motion to happen in.
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
// Shading band thickness. A proportional band (2 * RES) would just reproduce
// the old chunky ramp; a third of that is what buys the finer gradient.
let BAND = RES

func blank() -> [[Int]] { Array(repeating: Array(repeating: 0, count: GW), count: GH) }

func box(_ g: inout [[Int]], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
    for y in y0...y1 where y >= 0 && y < GH {
        for x in x0...x1 where x >= 0 && x < GW { g[y][x] = 1 }
    }
}

func rrect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ r: Int) -> [[Int]] {
    var t = blank()
    box(&t, x0, y0, x1, y1)
    for i in 0..<r {
        for j in 0..<(r - i) {
            t[y0 + i][x0 + j] = 0; t[y0 + i][x1 - j] = 0
            t[y1 - i][x0 + j] = 0; t[y1 - i][x1 - j] = 0
        }
    }
    return t
}

// One column span per design row, drawn at expanded resolution: each span
// slides linearly toward the next across its RES sub-rows. A pure design-space
// profile would step 3px at a time and scallop the silhouette; this keeps the
// 1px grain every other rounded edge in the art already has. A lathe profile
// rather than unioned rrects because a continuous bulge has no 45-degree
// corner an rrect cut could produce.
func lathe(_ profile: [(x0: Int, x1: Int)], from y0: Int = 0) -> [[Int]] {
    var t = blank()
    let top = y0 * RES
    for y in top..<min(GH, top + profile.count * RES) {
        let d = (y - top) / RES, f = (y - top) % RES
        let cur = profile[d]
        let nxt = d + 1 < profile.count ? profile[d + 1] : cur
        let x0 = cur.x0 * (RES - f) + nxt.x0 * f
        let x1 = (cur.x1 + 1) * (RES - f) + (nxt.x1 + 1) * f - 1
        for x in x0...x1 where x >= 0 && x < GW { t[y][x] = 1 }
    }
    return t
}

// A rect written in the original 32x33 design space, expanded to cover the
// full RES x RES block each source cell now occupies.
func cell(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> (Int, Int, Int, Int) {
    (x0 * RES, y0 * RES, (x1 + 1) * RES - 1, (y1 + 1) * RES - 1)
}

// .screen is the glass the amber eyes draw on, .casing the darker ring around
// it. .eye is the amber phosphor — sleepy arcs and open eyes are all the same
// ink, keeping the face reading as one lit tube, except catchlights' and
// sparkles' ivory `.glyph` and `.errorX`, the one non-amber face ink (error's
// X).
enum Ink: UInt8 { case none, outline, shade, body, light, casing, screen, eye, glyph, errorX }

let palette: [Ink: NSColor] = [
    .outline:  NSColor(srgbRed: 0.455, green: 0.216, blue: 0.145, alpha: 1),
    .shade:    NSColor(srgbRed: 0.745, green: 0.349, blue: 0.216, alpha: 1),
    .body:     NSColor(srgbRed: 0.855, green: 0.467, blue: 0.337, alpha: 1),
    .light:    NSColor(srgbRed: 0.918, green: 0.635, blue: 0.525, alpha: 1),
    .casing:   NSColor(srgbRed: 0.329, green: 0.216, blue: 0.165, alpha: 1),
    .screen:   NSColor(srgbRed: 0.227, green: 0.157, blue: 0.125, alpha: 1),
    .eye:      NSColor(srgbRed: 1.000, green: 0.757, blue: 0.412, alpha: 1),
    .glyph:    NSColor(srgbRed: 1.000, green: 0.957, blue: 0.914, alpha: 1),
    .errorX:   NSColor(srgbRed: 0.969, green: 0.561, blue: 0.561, alpha: 1),
]

func merge(_ parts: [[[Int]]]) -> [[Int]] {
    var mass = blank()
    for p in parts {
        for y in 0..<GH { for x in 0..<GW where p[y][x] == 1 { mass[y][x] = 1 } }
    }
    return mass
}

// Outline wherever the mass ends, a light band down the top and left edges and
// a shade band down the bottom and right. Every ink is derived from the mass
// rather than painted, which is what lets a limb built separately from the body
// come out shaded like the rest of it.
func shade(_ mass: [[Int]]) -> [[Ink]] {
    func solid(_ y: Int, _ x: Int) -> Bool {
        y >= 0 && y < GH && x >= 0 && x < GW && mass[y][x] == 1
    }

    var out = Array(repeating: Array(repeating: Ink.none, count: GW), count: GH)
    for y in 0..<GH {
        for x in 0..<GW where mass[y][x] == 1 {
            if !solid(y - 1, x) || !solid(y + 1, x) || !solid(y, x - 1) || !solid(y, x + 1) {
                out[y][x] = .outline
            } else if !solid(y - BAND, x) || !solid(y, x - BAND) {
                out[y][x] = .light
            } else if !solid(y + BAND, x) || !solid(y, x + BAND) {
                out[y][x] = .shade
            } else {
                out[y][x] = .body
            }
        }
    }
    return out
}

func buildBase() -> [[Ink]] {
    // Head, then a lathed torso rather than a rect: the waist at rows 18-19
    // is what separates the head from the body, and a curve derived the same
    // way the head's is will not read as a bolted-on box.
    let shell = lathe([(10, 21), (7, 24), (5, 26), (4, 27), (3, 28),
                       (2, 29), (2, 29), (2, 29), (2, 29), (2, 29),
                       (2, 29), (2, 29), (2, 29), (2, 29), (2, 29),
                       (3, 28), (4, 27), (6, 25)])
    let torso = lathe([(10, 21), (8, 23),
                       (7, 24), (7, 24), (7, 24), (7, 24),
                       (7, 24), (7, 24), (7, 24), (7, 24),
                       (8, 23)], from: 18)
    // Legs are square on purpose — rounding 5x4 pebbles costs them their
    // planted look, and at this size the outline is most of the leg.
    let legs = [(9, 29, 13, 32), (18, 29, 22, 32)].map { l -> [[Int]] in
        let c = cell(l.0, l.1, l.2, l.3)
        return rrect(c.0, c.1, c.2, c.3, 0)
    }

    var out = shade(merge([shell, torso] + legs))

    // An arm unioned into the body has no seam along the straight join, and
    // shade() derives none — the 1.0 answer was a painted crease, which is
    // one pixel wide at shipping size and lets the arm melt into the torso on
    // a light desktop. Each arm is its own mask, shaded on its own and
    // stamped over the base, which gives it a real outline for free.
    //
    // One uniform pill, not a shoulder welded to a forearm: those overlapped
    // at rows 22-23, so the arm was widest in the middle and grew outward as
    // it descended, which reads as a flexed deltoid. Four cells is the floor —
    // three is all outline, and reaching past column 4 breaks the weld.
    for mirrored in [false, true] {
        let pills = [(4, 19, 7, 26)].map { p -> [[Int]] in
            let (x0, x1) = mirrored ? (31 - p.2, 31 - p.0) : (p.0, p.2)
            let c = cell(x0, p.1, x1, p.3)
            return rrect(c.0, c.1, c.2, c.3, RES)
        }
        let arm = shade(merge(pills))
        for y in 0..<GH { for x in 0..<GW where arm[y][x] != .none { out[y][x] = arm[y][x] } }
    }

    // The brim, and the only way this head could have got one. Everything
    // above is merged into a single mask before shade() runs, so shade() can
    // only ever derive the OUTSIDE contour — five rounds of reshaping the head
    // profile failed on exactly that, because a lathe is convex and a merged
    // mass has no interior edges. This borrows the arm's trick instead: its
    // own mask, its own shade(), stamped over the base, so it lands with an
    // outline and a light band of its own and the visor reads as set into the
    // shell rather than painted on it. One band and no more: a second one
    // starts reading as stripes on a light desktop.
    let brimCell = cell(5, 2, 26, 4)
    let brim = shade(rrect(brimCell.0, brimCell.1, brimCell.2, brimCell.3, RES))
    for y in 0..<GH { for x in 0..<GW where brim[y][x] != .none { out[y][x] = brim[y][x] } }

    // Screen: casing ring, then glass. Stamped after shade() so the face is a
    // window into the shell, not a shaded lump on it. Nothing else goes on the
    // glass — 1.1 retired the scanlines and the corner glint, so the eyes are
    // the whole face.
    for (rect, ink) in [((5, 4, 26, 14), Ink.casing), ((6, 5, 25, 13), .screen)] {
        let c = cell(rect.0, rect.1, rect.2, rect.3)
        let m = rrect(c.0, c.1, c.2, c.3, 2 * RES)
        for y in 0..<GH { for x in 0..<GW where m[y][x] == 1 { out[y][x] = ink } }
    }

    // Chest badge: the Claude spark, cream with an amber heart.
    for (ink, x0, y0, x1, y1) in [(Ink.glyph, 16, 22, 16, 22), (.glyph, 15, 23, 15, 23),
                                  (.glyph, 17, 23, 17, 23), (.glyph, 16, 24, 16, 24),
                                  (.eye, 16, 23, 16, 23)] {
        let c = cell(x0, y0, x1, y1)
        for y in c.1...c.3 { for x in c.0...c.2 { out[y][x] = ink } }
    }
    return out
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
// which is why gaze and blink were built-in-only: the renderer knows where the
// built-in's eyes are because they are rects in `eyeRects`, and knows nothing
// about a manifest's. Finding them by colour does not work — on a soft-shaded
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

struct CustomPet {
    let name: String
    let width: Int
    let height: Int
    let scale: CGFloat
    let frames: [Mood: [[NSColor?]]]
    let eyes: EyeBox?
    let blinkFrame: [[NSColor?]]?

    func frame(for mood: Mood) -> [[NSColor?]] { frames[mood] ?? frames[.idle]! }
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

func loadCustomPet(_ url: URL) throws -> CustomPet {
    guard let data = try? Data(contentsOf: url) else { throw PetError("cannot read \(url.path)") }
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
        var grid: [[NSColor?]] = []
        for (y, row) in rows.enumerated() {
            guard row.count == w else { throw PetError("\(key) row \(y): length \(row.count) != \(w)") }
            var line: [NSColor?] = []
            for ch in row {
                if ch == "0" || ch == "." { line.append(nil) }
                else if let c = pal[ch] { line.append(c) }
                else { throw PetError("\(key) row \(y): \"\(ch)\" is not in the palette") }
            }
            grid.append(line)
        }
        frames[mood] = grid
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
    return CustomPet(name: (top["name"] as? String) ?? "custom",
                     width: dims.w, height: dims.h, scale: CGFloat(scale), frames: frames,
                     eyes: eyes, blinkFrame: blinkFrame)
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

let base = buildBase()

// The rects the built-in pet stamps over `base`. Kept as data rather than
// draw calls so --export emits exactly the art the app renders.
// Coordinates stay in the original 32x33 design space; cell() expands them and
// the dx/gy offsets arrive already in final cells.
func r(_ ink: Ink, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int,
       _ ox: Int = 0, _ oy: Int = 0) -> (Ink, Int, Int, Int, Int) {
    let c = cell(x0, y0, x1, y1)
    return (ink, c.0 + ox, c.1 + oy, c.2 + ox, c.3 + oy)
}

// The mood is legible or it is not, and the eyes are where it has to happen:
// the glass is 22x11 design cells (x5..26, y4..14) and everything else on the
// face is fixed, so a mood that only moves a small smudge inside it reads as
// the same picture five times. The five are chosen to differ in OUTLINE, not
// in area: idle's thick drowsy bowls, running's raised half-lid slits,
// waiting's wide-with-catchlight, done's lifted arch with a
// corner sparkle, error's heavy X. Gaze and the twitch shift these by one
// cell, which the zone's margin inside the glass absorbs.
//
// idle's resting face is the sleepy arc — the pet dozes. `peeking` swaps in
// open eyes for a beat so the cursor-following gaze survives the redesign;
// with Reduce Motion the tick freezes, peeking stays false, and the static
// pose is the arcs, which is exactly the frame that should be permanent.
func eyeRects(_ mood: Mood, _ dx: Int, _ gy: Int, _ peeking: Bool,
              _ blinking: Bool = false) -> [(Ink, Int, Int, Int, Int)] {
    switch mood {
    case .waiting:
        // Blink slit, 2 ticks on its own clock: liveness for the one mood
        // that could otherwise hold an unblinking stare for a full hour.
        if blinking {
            return [r(.eye, 8, 9, 14, 9, dx, gy), r(.eye, 17, 9, 23, 9, dx, gy)]
        }
        // The widest of the five: a 7x7 octagon filling the glass, with one
        // catchlight per eye in the SAME upper-left corner — one light source,
        // so this pair is deliberately not mirrored.
        return [r(.eye, 10, 6, 12, 6, dx, gy), r(.eye, 9, 7, 13, 7, dx, gy),
                r(.eye, 8, 8, 14, 10, dx, gy), r(.eye, 9, 11, 13, 11, dx, gy),
                r(.eye, 10, 12, 12, 12, dx, gy),
                r(.eye, 19, 6, 21, 6, dx, gy), r(.eye, 18, 7, 22, 7, dx, gy),
                r(.eye, 17, 8, 23, 10, dx, gy), r(.eye, 18, 11, 22, 11, dx, gy),
                r(.eye, 19, 12, 21, 12, dx, gy),
                r(.glyph, 9, 8, 10, 9, dx, gy), r(.glyph, 18, 8, 19, 9, dx, gy)]
    case .done:
        // A thin lifted arch with the tips thrown up, and a sparkle two clear
        // rows below it — closer and the pair reads as a mouse cursor.
        return [r(.eye, 9, 6, 12, 6), r(.eye, 8, 7, 9, 7), r(.eye, 12, 7, 13, 7),
                r(.eye, 8, 8, 8, 8), r(.eye, 13, 8, 13, 8),
                r(.eye, 19, 6, 22, 6), r(.eye, 18, 7, 19, 7), r(.eye, 22, 7, 23, 7),
                r(.eye, 18, 8, 18, 8), r(.eye, 23, 8, 23, 8),
                r(.glyph, 23, 10, 23, 10), r(.glyph, 22, 11, 24, 11),
                r(.glyph, 23, 12, 23, 12)]
    case .error:
        // A waisted X two cells thick — the waist is what stops it reading as
        // a block. The one deliberate exception to amber phosphor.
        return [r(.errorX, 8, 7, 9, 7), r(.errorX, 12, 7, 13, 7),
                r(.errorX, 9, 8, 12, 8), r(.errorX, 10, 9, 11, 9),
                r(.errorX, 9, 10, 12, 10),
                r(.errorX, 8, 11, 9, 11), r(.errorX, 12, 11, 13, 11),
                r(.errorX, 18, 7, 19, 7), r(.errorX, 22, 7, 23, 7),
                r(.errorX, 19, 8, 22, 8), r(.errorX, 20, 9, 21, 9),
                r(.errorX, 19, 10, 22, 10),
                r(.errorX, 18, 11, 19, 11), r(.errorX, 22, 11, 23, 11)]
    case .running:
        // A flat half-lid slab, raised. With the ticker gone this shape is the
        // ONLY thing separating running from idle, so it sits as high in the
        // glass as idle's bowl sits low.
        return [r(.eye, 8, 7, 13, 7, dx), r(.eye, 9, 8, 12, 8, dx),
                r(.eye, 18, 7, 23, 7, dx), r(.eye, 19, 8, 22, 8, dx)]
    case .idle:
        if peeking {
            // Awake for a beat: rounded amber eyes with a catchlight, gaze on.
            return [r(.eye, 10, 7, 12, 7, dx, gy), r(.eye, 9, 8, 13, 10, dx, gy),
                    r(.eye, 10, 11, 12, 11, dx, gy),
                    r(.eye, 19, 7, 21, 7, dx, gy), r(.eye, 18, 8, 22, 10, dx, gy),
                    r(.eye, 19, 11, 21, 11, dx, gy),
                    r(.glyph, 10, 8, 10, 8, dx, gy), r(.glyph, 19, 8, 19, 8, dx, gy)]
        }
        // The resting face: thick drowsy bowls sunk to the glass floor.
        return [r(.eye, 8, 10, 9, 10), r(.eye, 12, 10, 13, 10),
                r(.eye, 8, 11, 13, 11), r(.eye, 9, 12, 12, 12),
                r(.eye, 18, 10, 19, 10), r(.eye, 22, 10, 23, 10),
                r(.eye, 18, 11, 23, 11), r(.eye, 19, 12, 22, 12)]
    }
}

// Startle: both eyes blown wide, overriding whatever the mood was drawing.
// "Wide" is relative to the moods, so this is re-measured whenever they move:
// its widest row ties waiting's seven-wide octagon, but stands five rows tall
// where waiting's band is three — height, not width, is what out-sizes it.
// The pupil shrinks rather than grows because a pinprick in a large eye is
// what reads as startled. Carries no gaze offset, so it may use the glass to
// its edges.
func startledRects() -> [(Ink, Int, Int, Int, Int)] {
    [r(.eye, 8, 6, 12, 6), r(.eye, 7, 7, 13, 11), r(.eye, 8, 12, 12, 12),
     r(.eye, 19, 6, 23, 6), r(.eye, 18, 7, 24, 11), r(.eye, 19, 12, 23, 12),
     r(.screen, 9, 8, 11, 10), r(.screen, 20, 8, 22, 10)]
}

// A tear wells under the left eye, slides down the glass and off the casing
// onto the chin, then pauses. The fall resolves to one of six rows, or to
// nothing during the pause. Taking the row rather than the clock means two
// ticks that draw the same droplet are the same value, which is what lets a
// pose be compared instead of re-derived.
func tearRow(_ tick: Int) -> Int? {
    let phase = tick % 54
    guard phase >= 12 else { return nil }
    return 12 + min(5, (phase - 12) / 6)
}

func tearRects(_ y: Int) -> [(Ink, Int, Int, Int, Int)] { [r(.glyph, 8, y, 8, y + 1)] }

// Twinkles in the glass's upper corners, alternating so something is always
// catching the light without both sides flashing in lockstep. They sit ON the
// sprite rather than in the air beside it: a near-white glyph over transparent
// pixels is invisible against a light desktop, and `done` is the one mood the
// product exists to deliver — its signal cannot be background-dependent.
func sparkleRects(_ left: Bool) -> [(Ink, Int, Int, Int, Int)] {
    left
        ? [r(.glyph, 5, 7, 5, 7), r(.glyph, 4, 8, 6, 8), r(.glyph, 5, 9, 5, 9)]
        : [r(.glyph, 26, 7, 26, 7), r(.glyph, 25, 8, 27, 8), r(.glyph, 26, 9, 26, 9)]
}

// Snapshot the built-in pet as a manifest, so the default is a starting point
// for a custom pet instead of something you can only redraw from scratch.
// A manifest carries pixels, not behavior: the snapshot loses the
// cursor-following pupils and the doze-and-peek cycle, and because it has no
// eye coordinates the sideways twitch that moves only these eyes becomes a
// whole-body shift.
func exportBuiltin() -> String {
    let key: [Ink: Character] = [.outline: "o", .shade: "s", .body: "b", .light: "l",
                                 .casing: "k", .screen: "c",
                                 .eye: "e", .glyph: "g", .errorX: "x"]
    func hex(_ c: NSColor) -> String {
        String(format: "#%02x%02x%02x",
               Int((c.redComponent * 255).rounded()),
               Int((c.greenComponent * 255).rounded()),
               Int((c.blueComponent * 255).rounded()))
    }
    var moods: [String: [String]] = [:]
    for mood in [Mood.idle, .running, .waiting, .done, .error] {
        var grid = base
        for (ink, x0, y0, x1, y1) in eyeRects(mood, 0, 0, false) {
            for y in y0...y1 where y >= 0 && y < GH {
                for x in x0...x1 where x >= 0 && x < GW { grid[y][x] = ink }
            }
        }
        moods[mood.rawValue] = grid.map { String($0.map { $0 == .none ? "." : key[$0]! }) }
    }
    var pal: [String: String] = [:]
    for (ink, ch) in key { pal[String(ch)] = hex(palette[ink]!) }
    let doc: [String: Any] = ["name": "perchling", "scale": Int(SCALE),
                              "palette": pal, "moods": moods]
    let data = try! JSONSerialization.data(withJSONObject: doc,
                                           options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

final class PetView: NSView {
    var mood: Mood = .idle
    var tick: Int = 0
    var hopUntil: Int = -1
    var custom: CustomPet?
    var scale: CGFloat = SCALE
    var xpad = sidePad(SCALE)
    var startledUntil = -1
    override var isFlipped: Bool { true }

    var motionOK: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    // Reduce Motion freezes `tick`, so a deadline can never be reached once it
    // is on. Guarding only where the deadline is armed covers Reduce Motion
    // being on already, but not being switched on mid-flight — that leaves
    // `tick` parked below the deadline forever and the pose stuck for the life
    // of the process. Both ends have to check.
    var startled: Bool { custom == nil && motionOK && tick < startledUntil }

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
        // Same two conditions `startled` reads, so the deadline is never armed
        // for a pose that cannot be drawn. `custom` can change under a running
        // process, which is the reason to check it here as well as there: a
        // pet swapped mid-hover would otherwise inherit a deadline armed for
        // the creature before it.
        if custom == nil && motionOK { startledUntil = tick + 16 }
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

    // Every draw goes through here, so the side margin is applied once rather
    // than at each of the base / eyes / tear / sparkle / custom call sites.
    private func fill(_ color: NSColor, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ off: Int) {
        color.setFill()
        let r = NSRect(x: CGFloat(x0 + xpad) * scale,
                       y: CGFloat(y0 + off) * scale,
                       width: CGFloat(x1 - x0 + 1) * scale,
                       height: CGFloat(y1 - y0 + 1) * scale)
        r.fill()
    }

    private func put(_ ink: Ink, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ off: Int) {
        fill(palette[ink]!, x0, y0, x1, y1, off)
    }

    private func drawEyes(_ p: Pose) {
        for (ink, x0, y0, x1, y1) in eyeRects(p.mood, p.dx, p.gazeY, p.peeking, p.blinking) {
            put(ink, x0, y0, x1, y1, p.off)
        }
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
        let gazeY: Int
        let startled: Bool
        let peeking: Bool
        let blinking: Bool
        // Custom pets only. `dx` moves the whole sprite, so the eye shift needs
        // its own pair or a glance would drag the body with it.
        let eyeDX: Int
        let eyeDY: Int
        let tearRow: Int?
        let sparkleLeft: Bool
        let spriteGen: Int
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
        let u = bounceUnit(custom?.scale ?? SCALE)
        // The doze cycle: eyes open for a beat every few seconds, and only then
        // does the gaze apply — closed lids following the cursor read as a
        // glitch, not a glance. Under Reduce Motion the tick freezes, peek
        // stays false, and the permanent frame is the resting arcs.
        let peek = mood == .idle && custom == nil && motionOK && (nearCursor() || tick % 132 < 16)
        var off = 2
        var dx = 0
        // Gaze rides half the bounce unit, not the whole thing: the glass
        // gives waiting's eyes 6px of sideways headroom and 3px vertical, and
        // the twitch below already spends up to 4 of those 6 sideways on its
        // own — a full-unit gaze stacked on top of a full-unit twitch pushes
        // the widest eye past the casing, and a full-unit vertical gaze alone
        // already exceeds the 3px it has to work with. Idle's peek gaze skips
        // the halving: its eyes are narrower and centered, with about 9px of
        // sideways and 6px of vertical margin inside the glass and no twitch
        // stacked on top, so the full unit fits.
        var gazeDX = 0
        var gazeGY = 0
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
            if custom == nil {
                let g = gazeVector()
                gazeDX = Int((g.0 * CGFloat(u) / 2).rounded())
                gazeGY = Int((g.1 * CGFloat(u) / 2).rounded())
            } else if let e = custom?.eyes {
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
            if peek {
                let g = gazeVector()
                gazeDX = Int((g.0 * CGFloat(u)).rounded())
                gazeGY = Int((g.1 * CGFloat(u)).rounded())
            }
            // The doze cycle cuts between two eye shapes, and a manifest has
            // only one idle frame to cut between — so proximity moves the eyes
            // it already has instead. The pet still notices you approaching;
            // it just cannot open eyes it has no art for.
            else if let e = custom?.eyes, motionOK, nearCursor() {
                let g = gazeVector()
                eyeDX = Int((g.0 * CGFloat(e.range)).rounded())
                eyeDY = Int((g.1 * CGFloat(e.range)).rounded())
            }
        }
        // The hop outranks the mood's resting bob, and now fires on a tap in
        // any mood rather than only on the switch into done.
        if motionOK && tick < hopUntil { off = ((tick / 3) % 2 == 0) ? 2 : 0 }

        let st = startled

        // A droplet frozen mid-fall reads as a rendering fault, so the tear is
        // the one extra that sits out Reduce Motion entirely.
        let tear = (mood == .error && motionOK && !st) ? tearRow(tick) : nil

        let blink = mood == .waiting && motionOK && tick % 80 < 2
            && (custom == nil || custom?.blinkFrame != nil)
        // Three clocks, three periods — twinkle /6, waiting beat %60, waiting
        // blink %80 — deliberately share none, so overlapping animations read
        // as three mechanisms, not one.

        return Pose(mood: mood, off: off * u, dx: dx * u + gazeDX, gazeY: gazeGY,
                    startled: st, peeking: peek, blinking: blink,
                    eyeDX: eyeDX, eyeDY: eyeDY,
                    tearRow: tear,
                    sparkleLeft: (tick / 6) % 2 == 0,
                    spriteGen: spriteGen)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.shouldAntialias = false
        ctx.imageInterpolation = .none

        let p = pose()

        // Custom pets swap the whole sprite per mood; bounce (off) and twitch
        // (dx) still apply, but eye/gaze/glyph overlays are built-in-only —
        // the manifest knows nothing about eye coordinates.
        if let pet = custom {
            let grid = (p.blinking ? pet.blinkFrame : nil) ?? pet.frame(for: p.mood)
            let shifting = p.eyeDX != 0 || p.eyeDY != 0
            // Startle outranks the glance rather than composing with it, the
            // same way `startledRects` replaces the built-in's eyes outright:
            // a creature whose eyes have just snapped open is not also
            // tracking the cursor with them.

            for y in 0..<pet.height {
                for x in 0..<pet.width {
                    var c = grid[y][x]
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
            return
        }

        let grid = base
        for y in 0..<GH {
            for x in 0..<GW {
                let ink = grid[y][x]
                if ink != .none { put(ink, x, y, x, y, p.off) }
            }
        }
        if p.startled {
            for (ink, x0, y0, x1, y1) in startledRects() { put(ink, x0, y0, x1, y1, p.off) }
        } else {
            drawEyes(p)
        }

        if let y = p.tearRow {
            for (ink, x0, y0, x1, y1) in tearRects(y) { put(ink, x0, y0, x1, y1, p.off) }
        }
        if p.mood == .done {
            for (ink, x0, y0, x1, y1) in sparkleRects(p.sparkleLeft) { put(ink, x0, y0, x1, y1, p.off) }
        }
    }

    // Manual drag: window-background dragging would swallow the mouseUp we
    // need to tell a click ("jump back to Claude") from a drag ("move me").
    var onTap: (() -> Void)?
    private var pressAt: NSPoint?
    private var winAt: NSPoint?
    private var dragged = false

    // Deliver the activating click too — an accessory app is inactive at
    // nearly every interaction, and without this AppKit eats the first
    // mouseDown as an activation click (two-click taps, dead cold drags).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressAt = NSEvent.mouseLocation
        winAt = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p0 = pressAt, let w0 = winAt, let w = window else { return }
        let p = NSEvent.mouseLocation
        if abs(p.x - p0.x) + abs(p.y - p0.y) > 2 { dragged = true }
        w.setFrameOrigin(NSPoint(x: w0.x + (p.x - p0.x), y: w0.y + (p.y - p0.y)))
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged {
            // Hop first so the poke registers even though focus is about to
            // leave for the home app.
            if motionOK { hopUntil = tick + 12 }
            onTap?()
        }
        pressAt = nil
        winAt = nil
    }

    var onTuck: (() -> Void)?
    var onDisable: (() -> Void)?

    // Named petList, not petChoices: the free function that computes it is
    // already called petChoices, and a property shadowing it inside the
    // Controller closure that assigns this is a needless fight.
    var petList: (() -> [PetChoice])?
    var onPickPet: ((PetChoice?) -> Void)?   // nil picks the built-in
    var sessionList: (() -> [SessionRow])?

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
        for r in sessions {
            let item = NSMenuItem(title: sessionTitle(r, moodStatus),
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
// `sessionTitle` joins the project name to the status with one, and a second
// makes the row stutter. The bubble draws the status alone, so the collision
// is invisible from here.
let moodStatus: [Mood: String] = {
    let en: [Mood: String] = [.running: "thinking…", .waiting: "waiting for you…",
                              .done: "done!", .error: "oops, error"]
    let tables: [String: [Mood: String]] = [
        "zh-Hant": [.running: "思考中…", .waiting: "等你回應…", .done: "完成！", .error: "出錯了"],
        "zh-Hans": [.running: "思考中…", .waiting: "等你回应…", .done: "完成！", .error: "出错了"],
        "ja": [.running: "考え中…", .waiting: "入力待ち…", .done: "完了！", .error: "エラー"],
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
}

// The one place sessions/ is read for moods. The attention fold and the menu
// both take their sessions from here, so the face and the list cannot disagree
// about who is live or what they are doing. `alive` is injected because a
// harness has no pids to point at.
func liveSessions(_ dir: URL, now: Date, alive: (String) -> Bool) -> [SessionRow] {
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
        let ttl = moodTTL[mood] ?? 0
        out.append(SessionRow(sid: sid,
                              cwd: cwd.isEmpty ? nil : cwd,
                              mood: now.timeIntervalSince(stamp) > ttl ? .idle : mood))
    }
    return out
}

// The project directory is a session's identity. One whose cwd never arrived
// gets its raw id instead — deliberately unfriendly, because that is a real
// state (a file written before the label existed) and a made-up name would
// hide it.
func sessionName(_ r: SessionRow) -> String {
    // isDirectory:true is a lie the path is never asked to prove — it skips a
    // filesystem stat that would otherwise run on every poll-loop comparator
    // call and block the main-thread Timer if cwd sits on an unresponsive mount.
    r.cwd.map { URL(fileURLWithPath: $0, isDirectory: true).lastPathComponent } ?? String(r.sid.prefix(8))
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

// `status` is passed rather than read off the global so the wording under test
// is not whatever language the machine happens to be set to.
func sessionTitle(_ r: SessionRow, _ status: [Mood: String]) -> String {
    let name = sessionName(r)
    guard let s = status[r.mood], !s.isEmpty else { return name }
    return "\(name) — \(s)"
}

let BUB_W: CGFloat = 260, BUB_H: CGFloat = 72, BUB_BODY: CGFloat = 52
let CHIP: CGFloat = 26

// One control with two jobs: the count of what happened while you were not
// looking, and the handle that folds the bubble away. It gets its own window
// because `ignoresMouseEvents` is per-window — hanging a button off the bubble
// would cost the whole 260-point rect the click-through that is the point of
// a bubble you can leave on screen.
final class ChipView: NSView {
    var count = 0
    var collapsed = false
    var onTap: (() -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onTap?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        let disc = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: CHIP - 4, height: CHIP - 4))
        (count > 0 ? palette[.body]! : palette[.glyph]!).setFill()
        disc.fill()
        palette[.outline]!.setStroke()
        disc.lineWidth = 2.5
        disc.stroke()
        if count > 0 {
            // Two glyphs is the whole budget at this size; past nine the exact
            // number stops being the point anyway.
            let s = count > 9 ? "9+" : "\(count)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: count > 9 ? 10 : 12, weight: .bold),
                // Dark on the warm disc: at 26 points, cream on body colour
                // turns to mush and the count is the one thing to read.
                .foregroundColor: palette[.outline]!,
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
            palette[.screen]!.setStroke()
            p.lineWidth = 2.5
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        }
    }
}

final class BubbleView: NSView {
    // draw() is a pure function of these three and nothing else — no tick, no
    // clock, no cursor, and a palette that never varies — so repainting on a
    // real change is both necessary and sufficient. The poll loop used to mark
    // the bubble dirty twenty times a second for content that changes a few
    // times a turn, and text is the expensive thing on this canvas.
    var mood: Mood = .idle { didSet { if mood != oldValue { needsDisplay = true } } }
    var prompt: String = "" { didSet { if prompt != oldValue { needsDisplay = true } } }
    var tailCenter: CGFloat = BUB_W - 64 { didSet { if tailCenter != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    private func statusText() -> String { moodStatus[mood] ?? "" }

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
        guard mood != .idle else { return }

        let bg = palette[.glyph]!, line = palette[.outline]!, textColor = palette[.screen]!

        // Tail steps first so the body sits on top of them. tailCenter tracks
        // the pet's midline — a fixed inset from the bubble's right edge only
        // aims at the head for one particular pet width.
        let c = min(max(tailCenter, 26), BUB_W - 26)
        let steps = [NSRect(x: c - 11, y: BUB_BODY - 2, width: 22, height: 12),
                     NSRect(x: c - 5, y: BUB_BODY + 8, width: 12, height: 9)]
        for s in steps { line.setFill(); s.insetBy(dx: -3, dy: 0).fill() }
        for s in steps { bg.setFill(); s.fill() }

        let body = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: BUB_W - 4, height: BUB_BODY - 2),
                                xRadius: 7, yRadius: 7)
        bg.setFill(); body.fill()
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
            (truncate(statusText(), statusAttrs, maxW) as NSString)
                .draw(at: NSPoint(x: 16, y: 19), withAttributes: statusAttrs)
        } else {
            (truncate(prompt, promptAttrs, maxW) as NSString)
                .draw(at: NSPoint(x: 16, y: 9), withAttributes: promptAttrs)
            (truncate(statusText(), statusAttrs, maxW) as NSString)
                .draw(at: NSPoint(x: 16, y: 28), withAttributes: statusAttrs)
        }
    }
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
    let sayURL: URL
    let petURL: URL
    var lastSayStamp: Date?
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

    init(root: URL) {
        self.root = root
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
        let size = canvasSize(GW, GH, SCALE)
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
        view.scale = pet?.scale ?? SCALE
        let s = pet?.scale ?? SCALE
        view.xpad = sidePad(s)
        view.spriteGen += 1
        let size = canvasSize(pet?.width ?? GW, pet?.height ?? GH, s)
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
        let pf = window.frame
        var x = pf.maxX - BUB_W
        if let s = window.screen ?? NSScreen.main { x = max(x, s.visibleFrame.minX + 4) }
        bubbleView.tailCenter = pf.midX - x
        bubble.setFrameOrigin(NSPoint(x: x, y: pf.maxY + 2))
        // Perched on the pet's top-right corner, mostly outside the art and
        // entirely below the bubble — the two never draw over each other.
        var cx = pf.maxX - 10, cy = pf.maxY - CHIP
        if let s = window.screen ?? NSScreen.main {
            cx = min(cx, s.visibleFrame.maxX - CHIP)
            cy = min(cy, s.visibleFrame.maxY - CHIP)
        }
        chip.setFrameOrigin(NSPoint(x: cx, y: cy))
    }

    // The chip earns its place only when it has something to say or something
    // to fold: a count you have not seen, or a bubble that is actually drawn.
    // An idle pet keeps the desktop clean.
    func applyChrome() {
        let wanted = !tucked && (unread > 0 || view.mood != .idle)
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
        bubbleView.prompt = s.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let live = liveSessions(sessionsURL, now: now, alive: ownerAlive)
        sessionRows = menuRows(live)
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
        Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [self] _ in
            clock += 1
            // Reduce Motion freezes the animation clock (static pose), never
            // the polling clock — liveness and mood changes must keep working.
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { view.tick += 1 }
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
                if (becameDone || entered.contains(.done)) && next == .done && view.motionOK {
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
                if let s = lastSayStamp, Date().timeIntervalSince(s) > 3600,
                   !bubbleView.prompt.isEmpty { bubbleView.prompt = "" }
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
            bubbleView.mood = view.mood
            view.repaintIfChanged()
        }
    }
}

// Runtime home: PERCHLING_HOME (set by pet.sh) > $CLAUDE_CONFIG_DIR/perchling > ~/.claude/perchling.
let env = ProcessInfo.processInfo.environment
let root: URL
if let p = env["PERCHLING_HOME"] {
    root = URL(fileURLWithPath: p)
} else {
    let cfg = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    root = cfg.appendingPathComponent("perchling")
}
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
            print("OK: \(pet.name) \(pet.width)x\(pet.height) @\(Int(pet.scale))x [\(moods)] — \(eyes)")
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
let controller = Controller(root: root)
controller.run()
app.run()
