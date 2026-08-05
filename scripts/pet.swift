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

func spike(_ cx: Int, _ y0: Int, _ h: Int) -> [[Int]] {
    var t = blank()
    for i in 0..<h { box(&t, cx - i, y0 + i, cx + i, y0 + i) }
    return t
}

func leg(_ x0: Int) -> [[Int]] {
    var t = blank()
    let w = 4 * RES - 1
    box(&t, x0, 30 * RES, x0 + w, GH - 1)
    for i in 0..<RES {
        for j in 0..<RES {
            t[GH - 1 - i][x0 + j] = 0
            t[GH - 1 - i][x0 + w - j] = 0
        }
    }
    return t
}

// A rect written in the original 32x33 design space, expanded to cover the
// full RES x RES block each source cell now occupies.
func cell(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> (Int, Int, Int, Int) {
    (x0 * RES, y0 * RES, (x1 + 1) * RES - 1, (y1 + 1) * RES - 1)
}

enum Ink: UInt8 { case none, outline, shade, body, light, screen, eye, glyph }

let palette: [Ink: NSColor] = [
    .outline: NSColor(srgbRed: 0.478, green: 0.208, blue: 0.125, alpha: 1),
    .shade:   NSColor(srgbRed: 0.690, green: 0.329, blue: 0.216, alpha: 1),
    .body:    NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1),
    .light:   NSColor(srgbRed: 0.941, green: 0.639, blue: 0.510, alpha: 1),
    .screen:  NSColor(srgbRed: 0.165, green: 0.110, blue: 0.090, alpha: 1),
    .eye:     NSColor(srgbRed: 1.000, green: 0.851, blue: 0.678, alpha: 1),
    .glyph:   NSColor(srgbRed: 1.000, green: 0.957, blue: 0.914, alpha: 1),
]

func buildBase() -> [[Ink]] {
    var mass = blank()
    let R = RES
    let parts = [
        rrect(3 * R, 5 * R, 29 * R - 1, 18 * R - 1, 3 * R),
        spike(7 * R, 2 * R, 3 * R), spike(24 * R, 2 * R, 3 * R), spike(15 * R, 0, 5 * R),
        rrect(8 * R, 18 * R, 24 * R - 1, 30 * R - 1, 2 * R),
        rrect(2 * R, 21 * R, 10 * R - 1, 26 * R - 1, 1 * R),
        rrect(22 * R, 21 * R, 30 * R - 1, 26 * R - 1, 1 * R),
        leg(10 * R), leg(18 * R),
    ]
    for p in parts {
        for y in 0..<GH { for x in 0..<GW where p[y][x] == 1 { mass[y][x] = 1 } }
    }

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
    let sc = rrect(7 * RES, 8 * RES, 25 * RES - 1, 17 * RES - 1, 2 * RES)
    for y in 0..<GH { for x in 0..<GW where sc[y][x] == 1 { out[y][x] = .screen } }
    return out
}

enum Mood: String {
    case idle, running, waiting, done, error

    static func parse(_ s: String) -> Mood {
        Mood(rawValue: s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .idle
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

struct CustomPet {
    let name: String
    let width: Int
    let height: Int
    let scale: CGFloat
    let frames: [Mood: [[NSColor?]]]

    func frame(for mood: Mood) -> [[NSColor?]] { frames[mood] ?? frames[.idle]! }
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
    return CustomPet(name: (top["name"] as? String) ?? "custom",
                     width: dims.w, height: dims.h, scale: CGFloat(scale), frames: frames)
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

func eyeRects(_ mood: Mood, _ dx: Int, _ gy: Int, _ blinking: Bool) -> [(Ink, Int, Int, Int, Int)] {
    switch mood {
    case .waiting:
        return [r(.eye, 10, 10, 13, 12, dx, gy), r(.eye, 18, 10, 21, 12, dx, gy),
                r(.glyph, 10, 10, 10, 10, dx, gy), r(.glyph, 18, 10, 18, 10, dx, gy)]
    case .done:
        return [r(.eye, 11, 11, 12, 11), r(.eye, 10, 12, 13, 12),
                r(.eye, 19, 11, 20, 11), r(.eye, 18, 12, 21, 12)]
    case .error:
        return [r(.eye, 10, 11, 11, 11), r(.eye, 12, 12, 13, 12),
                r(.eye, 20, 11, 21, 11), r(.eye, 18, 12, 19, 12)]
    case .running:
        return [r(.eye, 10, 11, 13, 11, dx), r(.eye, 11, 12, 13, 12, dx),
                r(.eye, 18, 11, 21, 11, dx), r(.eye, 18, 12, 20, 12, dx)]
    case .idle:
        // Never freeze on the blink frame: with Reduce Motion the tick stays
        // put, and eyes-shut is a terrible static pose.
        if blinking {
            return [r(.eye, 10, 12, 13, 12), r(.eye, 18, 12, 21, 12)]
        }
        return [r(.eye, 10, 11, 13, 11, dx, gy), r(.eye, 11, 12, 13, 12, dx, gy),
                r(.eye, 18, 11, 21, 11, dx, gy), r(.eye, 18, 12, 20, 12, dx, gy)]
    }
}

// The prompt chevron plus `cursorCells` of underscore after it (0...5). A
// steady 5 is the plain cursor the pet has always drawn; growing it a cell at
// a time is what reads as typing.
func chromeRects(_ cursorCells: Int) -> [(Ink, Int, Int, Int, Int)] {
    var out = [r(.glyph, 11, 22, 12, 22), r(.glyph, 12, 23, 13, 23), r(.glyph, 13, 24, 14, 24),
               r(.glyph, 12, 25, 13, 25), r(.glyph, 11, 26, 12, 26)]
    let n = min(max(cursorCells, 0), 5)
    if n > 0 { out.append(r(.glyph, 16, 26, 15 + n, 26)) }
    return out
}

// Startle: both eyes blown wide, overriding whatever the mood was drawing.
func startledRects() -> [(Ink, Int, Int, Int, Int)] {
    [r(.eye, 9, 9, 13, 13), r(.eye, 18, 9, 22, 13),
     r(.screen, 11, 11, 12, 12), r(.screen, 19, 11, 20, 12)]
}

// A tear wells under the left eye and falls clear of the chin, then pauses.
// The fall resolves to one of five rows, or to nothing during the pause. Taking
// the row rather than the clock means two ticks that draw the same droplet are
// the same value, which is what lets a pose be compared instead of re-derived.
func tearRow(_ tick: Int) -> Int? {
    let phase = tick % 54
    guard phase >= 12 else { return nil }
    return 13 + min(4, (phase - 12) / 7)
}

func tearRects(_ y: Int) -> [(Ink, Int, Int, Int, Int)] { [r(.glyph, 11, y, 11, y + 1)] }

// Twinkles either side of the crown, alternating so something is always
// catching the light without both sides flashing in lockstep.
func sparkleRects(_ left: Bool) -> [(Ink, Int, Int, Int, Int)] {
    left
        ? [r(.glyph, 3, 2, 3, 2), r(.glyph, 2, 3, 4, 3), r(.glyph, 3, 4, 3, 4)]
        : [r(.glyph, 28, 2, 28, 2), r(.glyph, 27, 3, 29, 3), r(.glyph, 28, 4, 28, 4)]
}

// Snapshot the built-in pet as a manifest, so the default is a starting point
// for a custom pet instead of something you can only redraw from scratch.
// A manifest carries pixels, not behavior: the snapshot loses the
// cursor-following pupils, the idle blink and the blinking terminal cursor,
// and because it has no eye coordinates the sideways twitch that moves only
// these eyes becomes a whole-body shift.
func exportBuiltin() -> String {
    let key: [Ink: Character] = [.outline: "o", .shade: "s", .body: "b", .light: "l",
                                 .screen: "c", .eye: "e", .glyph: "g"]
    func hex(_ c: NSColor) -> String {
        String(format: "#%02x%02x%02x",
               Int((c.redComponent * 255).rounded()),
               Int((c.greenComponent * 255).rounded()),
               Int((c.blueComponent * 255).rounded()))
    }
    var moods: [String: [String]] = [:]
    for mood in [Mood.idle, .running, .waiting, .done, .error] {
        var grid = base
        for (ink, x0, y0, x1, y1) in eyeRects(mood, 0, 0, false) + chromeRects(5) {
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

    // Hovering the pet startles it. The tracking area is rebuilt on resize
    // because installing a custom pet changes the window's bounds.
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
        if motionOK { startledUntil = tick + 16 }
    }

    // Pupils drift toward the cursor (idle/waiting only) — the feature OpenAI
    // built for Codex pets and left Statsig-gated off.
    private func gaze() -> (Int, Int) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return (0, 0) }
        guard let w = window else { return (0, 0) }
        let m = NSEvent.mouseLocation
        let dx = m.x - w.frame.midX
        let dy = m.y - w.frame.midY
        let gx = dx < -30 ? -1 : (dx > 30 ? 1 : 0)
        // Screen coords are y-up, the grid is y-down: cursor above → pupils up.
        let gy = dy > 80 ? -1 : (dy < -40 ? 1 : 0)
        return (gx, gy)
    }

    // Every draw goes through here, so the side margin is applied once rather
    // than at each of the base / eyes / chrome / custom call sites.
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
        for (ink, x0, y0, x1, y1) in eyeRects(p.mood, p.dx, p.gazeY, p.blinking) {
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
        let blinking: Bool
        let cursorCells: Int
        let tearRow: Int?
        let sparkleLeft: Bool
    }

    func pose() -> Pose {
        let u = bounceUnit(custom?.scale ?? SCALE)
        var off = 2
        var dx = 0
        var gy = 0
        switch mood {
        case .running:
            off = 2 + (tick / 4) % 2
            dx = ((tick / 10) % 4 == 1) ? -1 : (((tick / 10) % 4 == 3) ? 1 : 0)
        case .waiting:
            dx = (tick % 30 < 2) ? 1 : 0
            if custom == nil { let g = gaze(); dx += g.0; gy = g.1 }
        case .done:
            off = 2 + (tick / 12) % 2
        case .error:
            off = 3
        case .idle:
            off = 2 + (tick / 9) % 2
            if custom == nil { let g = gaze(); dx = g.0; gy = g.1 }
        }
        // The hop outranks the mood's resting bob, and now fires on a tap in
        // any mood rather than only on the switch into done.
        if motionOK && tick < hopUntil { off = ((tick / 3) % 2 == 0) ? 2 : 0 }

        let st = startled
        // running types a line out a cell at a time; every other mood keeps the
        // plain cursor it has always had, blinking at its own rate.
        let cursor: Int
        switch mood {
        // A frozen clock must land on a good pose, and phase 0 of the typing
        // cycle is an empty prompt line — the one frame that reads as broken.
        case .running: cursor = motionOK ? min(5, (tick / 3) % 7) : 5
        case .waiting: cursor = (tick / 6) % 2 == 0 ? 5 : 0
        case .done, .error: cursor = 5
        case .idle: cursor = (tick / 11) % 2 == 0 ? 5 : 0
        }

        // A droplet frozen mid-fall reads as a rendering fault, so the tear is
        // the one extra that sits out Reduce Motion entirely.
        let tear = (mood == .error && motionOK && !st) ? tearRow(tick) : nil

        return Pose(mood: mood, off: off * u, dx: dx * u, gazeY: gy * u,
                    startled: st, blinking: tick % 84 < 3 && motionOK,
                    cursorCells: cursor, tearRow: tear,
                    sparkleLeft: (tick / 6) % 2 == 0)
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
            let grid = pet.frame(for: p.mood)
            for y in 0..<pet.height {
                for x in 0..<pet.width {
                    if let c = grid[y][x] { fill(c, x + p.dx, y, x + p.dx, y, p.off) }
                }
            }
            return
        }

        for y in 0..<GH {
            for x in 0..<GW {
                let ink = base[y][x]
                if ink != .none { put(ink, x, y, x, y, p.off) }
            }
        }
        if p.startled {
            for (ink, x0, y0, x1, y1) in startledRects() { put(ink, x0, y0, x1, y1, p.off) }
        } else {
            drawEyes(p)
        }

        for (ink, x0, y0, x1, y1) in chromeRects(p.cursorCells) { put(ink, x0, y0, x1, y1, p.off) }

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

    @objc private func tuckAction() { onTuck?() }
    @objc private func disableAction() { onDisable?() }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
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

    // Four words of UI, so the table is inline rather than a .lproj bundle a
    // single-file build cannot carry. Only languages whose wording I can vouch
    // for are listed — a wrong translation is worse than English.
    private static let status: [Mood: String] = {
        let en: [Mood: String] = [.running: "thinking…", .waiting: "waiting for you…",
                                  .done: "done!", .error: "oops — error"]
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

    private func statusText() -> String { BubbleView.status[mood] ?? "" }

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

    init(root: URL) {
        self.root = root
        stateURL = root.appendingPathComponent("state")
        sessionsURL = root.appendingPathComponent("sessions")
        ownersURL = root.appendingPathComponent("owners")
        sayURL = root.appendingPathComponent("say")
        petURL = root.appendingPathComponent("pet.json")
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
        var inputs: [(String, Mood, Date)] = []
        if let attrs = try? fm.attributesOfItem(atPath: stateURL.path),
           let stamp = attrs[.modificationDate] as? Date,
           let raw = try? String(contentsOf: stateURL, encoding: .utf8) {
            inputs.append(("state", Mood.parse(raw), stamp))
        }
        let cutoff = now.addingTimeInterval(-3600)
        let items = (try? fm.contentsOfDirectory(at: sessionsURL,
                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        for url in items {
            // A dead owner's last mood is not news: without this a killed app
            // leaves "waiting for you" on the pet's face for the rest of the
            // TTL, in front of whoever is still working elsewhere.
            guard ownerAlive(url.lastPathComponent),
                  let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  stamp > cutoff else { continue }
            let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            inputs.append((url.lastPathComponent, Mood.parse(raw), stamp))
        }
        var display = Mood.idle
        var current: [String: Mood] = [:]
        var entered: Set<Mood> = []
        for (key, m, stamp) in inputs {
            var ttl = moodTTL[m] ?? 0
            // The state file has no owner to clean it up on session end, so it
            // gets a short leash: enough for manual puppeteering, too short to
            // haunt the fold as a dead session's ghost.
            if key == "state" { ttl = min(ttl, 300) }
            let effective = now.timeIntervalSince(stamp) > ttl ? Mood.idle : m
            current[key] = effective
            if moodRank[effective]! > moodRank[display]! { display = effective }
            let prev = lastInputMoods[key] ?? .idle
            if effective != prev, effective == .waiting || effective == .done || effective == .error {
                entered.insert(effective)
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
                if next != view.mood {
                    view.mood = next
                    if next == .done && view.motionOK { view.hopUntil = view.tick + 12 }
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
            view.needsDisplay = true
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
            print("OK: \(pet.name) \(pet.width)x\(pet.height) @\(Int(pet.scale))x [\(moods)]")
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
