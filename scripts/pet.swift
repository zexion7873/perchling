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
    var tick: Int = 0
    var hopUntil: Int = -1
    private var gazeY = 0

    override var isFlipped: Bool { true }

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
            put(.eye, 10 + dx, 10 + gazeY, 13 + dx, 12 + gazeY, off)
            put(.eye, 18 + dx, 10 + gazeY, 21 + dx, 12 + gazeY, off)
            put(.glyph, 10 + dx, 10 + gazeY, 10 + dx, 10 + gazeY, off)
            put(.glyph, 18 + dx, 10 + gazeY, 18 + dx, 10 + gazeY, off)
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
            // Never freeze on the blink frame: with Reduce Motion the tick
            // stays put, and eyes-shut is a terrible static pose.
            if tick % 84 < 3 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                put(.eye, 10, 12, 13, 12, off)
                put(.eye, 18, 12, 21, 12, off)
            } else {
                put(.eye, 10 + dx, 11 + gazeY, 13 + dx, 11 + gazeY, off)
                put(.eye, 11 + dx, 12 + gazeY, 13 + dx, 12 + gazeY, off)
                put(.eye, 18 + dx, 11 + gazeY, 21 + dx, 11 + gazeY, off)
                put(.eye, 18 + dx, 12 + gazeY, 20 + dx, 12 + gazeY, off)
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
            let g = gaze()
            dx = ((tick % 30 < 2) ? 1 : 0) + g.0
            gazeY = g.1
        case .done:
            off = tick < hopUntil ? (2 - ((tick / 3) % 2) * 2) : 2 + (tick / 12) % 2
        case .error:
            off = 3
        case .idle:
            off = 2 + (tick / 9) % 2
            let g = gaze()
            dx = g.0
            gazeY = g.1
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
        if !dragged { onTap?() }
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
let moodTTL: [Mood: TimeInterval] = [.running: 900, .done: 12, .error: 3600, .waiting: 3600]

let BUB_W: CGFloat = 260, BUB_H: CGFloat = 72, BUB_BODY: CGFloat = 52

final class BubbleView: NSView {
    var mood: Mood = .idle
    var prompt: String = ""

    override var isFlipped: Bool { true }

    private func statusText() -> String {
        switch mood {
        case .running: return "thinking…"
        case .waiting: return "waiting for you…"
        case .done:    return "done!"
        case .error:   return "oops — error"
        case .idle:    return ""
        }
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
        guard mood != .idle else { return }

        let bg = palette[.glyph]!, line = palette[.outline]!, textColor = palette[.screen]!

        // Tail steps first so the body sits on top of them; pet is right-aligned
        // under the bubble, so the tail points at its head.
        let steps = [NSRect(x: 190, y: BUB_BODY - 2, width: 22, height: 12),
                     NSRect(x: 196, y: BUB_BODY + 8, width: 12, height: 9)]
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
    let root: URL
    let stateURL: URL
    let sessionsURL: URL
    let sayURL: URL
    var lastSayStamp: Date?
    var emptySince: Date?
    var homeApp: NSRunningApplication?
    var firstFold = true
    var tucked = false
    var lastInputMoods: [String: Mood] = [:]

    init(root: URL) {
        self.root = root
        stateURL = root.appendingPathComponent("state")
        sessionsURL = root.appendingPathComponent("sessions")
        sayURL = root.appendingPathComponent("say")
        let bubSize = NSSize(width: BUB_W, height: BUB_H)
        bubble = NSWindow(contentRect: NSRect(origin: .zero, size: bubSize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        bubbleView = BubbleView(frame: NSRect(origin: .zero, size: bubSize))
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

        // "Home" is where a tap sends the user: Claude desktop when present,
        // else whatever was frontmost at launch (terminal-CLI users).
        homeApp = Controller.resolveHomeApp()
        view.onTap = { [weak self] in self?.focusHome() }
        view.onTuck = { [weak self] in self?.setTucked(true) }
        view.onDisable = { [weak self] in self?.disableAndQuit() }
    }

    func setTucked(_ t: Bool) {
        tucked = t
        if t {
            window.removeChildWindow(bubble)
            bubble.orderOut(nil)
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
            window.addChildWindow(bubble, ordered: .above)
            repositionBubble()
        }
    }

    func disableAndQuit() {
        FileManager.default.createFile(atPath: root.appendingPathComponent("disabled").path, contents: nil)
        NSApp.terminate(nil)
    }

    func repositionBubble() {
        let pf = window.frame
        var x = pf.maxX - BUB_W
        if let s = window.screen ?? NSScreen.main { x = max(x, s.visibleFrame.minX + 4) }
        bubble.setFrameOrigin(NSPoint(x: x, y: pf.maxY + 2))
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
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier == homeApp?.bundleIdentifier
           || front.bundleIdentifier == claudeBundleID { return }
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
        s = s.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\t", with: " ")
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
            guard let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
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
                    if next == .done { view.hopUntil = view.tick + 12 }
                }
                // Reminders and tuck-wake follow per-input events, not the
                // (possibly masked) display transition.
                if !firstFold, let alert = entered.max(by: { moodRank[$0]! < moodRank[$1]! }) {
                    maybeRemind(alert)
                    if tucked && (alert == .waiting || alert == .error) { setTucked(false) }
                }
                firstFold = false
                pollSay()
                // A prompt snippet from hours ago is noise, not context.
                if let s = lastSayStamp, Date().timeIntervalSince(s) > 3600,
                   !bubbleView.prompt.isEmpty { bubbleView.prompt = "" }
            }
            bubbleView.mood = view.mood
            bubbleView.needsDisplay = true
            if clock % 100 == 0 {
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
