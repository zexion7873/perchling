import AppKit

let GW = 32, GH = 33
let SCALE: CGFloat = 4
let CANVAS_H = 36

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
    box(&t, x0, 30, x0 + 3, 32)
    t[32][x0] = 0; t[32][x0 + 3] = 0
    return t
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
    let parts = [
        rrect(3, 5, 28, 17, 3), spike(7, 2, 3), spike(24, 2, 3), spike(15, 0, 5),
        rrect(8, 18, 23, 29, 2), rrect(2, 21, 9, 25, 1), rrect(22, 21, 29, 25, 1),
        leg(10), leg(18),
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
            } else if !solid(y - 2, x) || !solid(y, x - 2) {
                out[y][x] = .light
            } else if !solid(y + 2, x) || !solid(y, x + 2) {
                out[y][x] = .shade
            } else {
                out[y][x] = .body
            }
        }
    }
    let sc = rrect(7, 8, 24, 16, 2)
    for y in 0..<GH { for x in 0..<GW where sc[y][x] == 1 { out[y][x] = .screen } }
    return out
}

enum Mood: String {
    case idle, running, waiting, done, error

    static func parse(_ s: String) -> Mood {
        Mood(rawValue: s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .idle
    }
}

let base = buildBase()

final class PetView: NSView {
    var mood: Mood = .idle
    var moodAge: TimeInterval = 0
    var tick: Int = 0
    var hopUntil: Int = -1

    override var isFlipped: Bool { true }

    private func put(_ ink: Ink, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ off: Int) {
        palette[ink]!.setFill()
        let r = NSRect(x: CGFloat(x0) * SCALE,
                       y: CGFloat(y0 + off) * SCALE,
                       width: CGFloat(x1 - x0 + 1) * SCALE,
                       height: CGFloat(y1 - y0 + 1) * SCALE)
        r.fill()
    }

    private func drawEyes(_ off: Int, _ dx: Int) {
        switch mood {
        case .waiting:
            put(.eye, 10 + dx, 10, 13 + dx, 12, off)
            put(.eye, 18 + dx, 10, 21 + dx, 12, off)
            put(.glyph, 10 + dx, 10, 10 + dx, 10, off)
            put(.glyph, 18 + dx, 10, 18 + dx, 10, off)
        case .done:
            put(.eye, 11, 11, 12, 11, off); put(.eye, 10, 12, 13, 12, off)
            put(.eye, 19, 11, 20, 11, off); put(.eye, 18, 12, 21, 12, off)
        case .error:
            put(.eye, 10, 11, 11, 11, off); put(.eye, 12, 12, 13, 12, off)
            put(.eye, 20, 11, 21, 11, off); put(.eye, 18, 12, 19, 12, off)
        case .running:
            put(.eye, 10 + dx, 11, 13 + dx, 11, off)
            put(.eye, 11 + dx, 12, 13 + dx, 12, off)
            put(.eye, 18 + dx, 11, 21 + dx, 11, off)
            put(.eye, 18 + dx, 12, 20 + dx, 12, off)
        case .idle:
            if tick % 84 < 3 {
                put(.eye, 10, 12, 13, 12, off)
                put(.eye, 18, 12, 21, 12, off)
            } else {
                put(.eye, 10, 11, 13, 11, off); put(.eye, 11, 12, 13, 12, off)
                put(.eye, 18, 11, 21, 11, off); put(.eye, 18, 12, 20, 12, off)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.shouldAntialias = false
        ctx.imageInterpolation = .none

        var off = 2
        var dx = 0
        switch mood {
        case .running:
            off = 2 + (tick / 4) % 2
            dx = ((tick / 10) % 4 == 1) ? -1 : (((tick / 10) % 4 == 3) ? 1 : 0)
        case .waiting:
            dx = (tick % 30 < 2) ? 1 : 0
        case .done:
            off = tick < hopUntil ? (2 - ((tick / 3) % 2) * 2) : 2 + (tick / 12) % 2
        case .error:
            off = 3
        case .idle:
            off = 2 + (tick / 9) % 2
        }

        for y in 0..<GH {
            for x in 0..<GW {
                let ink = base[y][x]
                if ink != .none { put(ink, x, y, x, y, off) }
            }
        }
        drawEyes(off, dx)

        put(.glyph, 11, 22, 12, 22, off); put(.glyph, 12, 23, 13, 23, off)
        put(.glyph, 13, 24, 14, 24, off); put(.glyph, 12, 25, 13, 25, off)
        put(.glyph, 11, 26, 12, 26, off)

        let cursorOn: Bool
        switch mood {
        case .running: cursorOn = (tick / 3) % 2 == 0
        case .waiting: cursorOn = (tick / 6) % 2 == 0
        case .done, .error: cursorOn = true
        case .idle: cursorOn = (tick / 11) % 2 == 0
        }
        if cursorOn { put(.glyph, 16, 26, 20, 26, off) }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit perchling", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

final class Controller: NSObject, NSWindowDelegate {
    let window: NSWindow
    let view: PetView
    let stateURL: URL
    let sessionsURL: URL
    var lastStamp: Date?
    var emptySince: Date?

    init(root: URL) {
        stateURL = root.appendingPathComponent("state")
        sessionsURL = root.appendingPathComponent("sessions")
        let size = NSSize(width: CGFloat(GW) * SCALE, height: CGFloat(CANVAS_H) * SCALE)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        view = PetView(frame: NSRect(origin: .zero, size: size))
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = true
        window.contentView = view
        window.delegate = self
        window.ignoresMouseEvents = false

        let d = UserDefaults.standard
        if d.object(forKey: "petX") != nil {
            window.setFrameOrigin(NSPoint(x: d.double(forKey: "petX"), y: d.double(forKey: "petY")))
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.maxX - size.width - 24, y: f.minY + 24))
        }
        window.orderFrontRegardless()
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(Double(window.frame.origin.x), forKey: "petX")
        UserDefaults.standard.set(Double(window.frame.origin.y), forKey: "petY")
    }

    func pollState() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: stateURL.path),
              let stamp = attrs[.modificationDate] as? Date else { return }
        if stamp == lastStamp { return }
        lastStamp = stamp
        let raw = (try? String(contentsOf: stateURL, encoding: .utf8)) ?? "idle"
        let next = Mood.parse(raw)
        if next != view.mood {
            view.mood = next
            if next == .done { view.hopUntil = view.tick + 12 }
        }
        view.moodAge = 0
    }

    func pollSessions() -> Bool {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        let items = (try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let live = items.filter { url in
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (d ?? .distantPast) > cutoff
        }
        return !live.isEmpty
    }

    func run() {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [self] _ in
            view.tick += 1
            view.moodAge += 1.0 / 20.0
            if view.tick % 8 == 0 { pollState() }
            if view.mood == .done && view.moodAge > 12 { view.mood = .idle }
            if view.tick % 100 == 0 {
                if pollSessions() {
                    emptySince = nil
                } else {
                    if emptySince == nil { emptySince = Date() }
                    if Date().timeIntervalSince(emptySince!) > 30 { NSApp.terminate(nil) }
                }
            }
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller(root: root)
controller.run()
app.run()
