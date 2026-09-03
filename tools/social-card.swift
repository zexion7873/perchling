// Renders docs/social-card.png — the 1280x640 image GitHub shows when a link
// to the repo is pasted anywhere — from the real draw(), appended to
// pet.swift's body by tools/make-social-card.sh. Same cut as moods-gif.swift,
// same reason: a card drawn from anything but PetView.draw() is a second
// drawing of the pet, and second drawings drift.
//
// The pet is rendered at an integer scale rather than upscaled from the 1.15
// it ships at. A fractional scale snaps each sprite cell to 1 or 2 points, so
// a nearest-neighbour blow-up of that render carries the 1/2 alternation up
// with it; asking draw() for scale 6 gives every cell exactly six pixels.

let CARD_W = 1280, CARD_H = 640          // GitHub's recommended 2:1
let PET_SCALE: CGFloat = 6
let MARGIN = 96
// The pet sits further in than the text does. LINE, iMessage and their kind
// do not show a 2:1 card; they crop its centre square (x 320..960 here) into
// a thumbnail, and at a 96px margin that square ends between the goggles.
// 196 puts the whole head — ears included, which reached column 1057 on a
// 96px margin — inside it, at the cost of 100px of text column. The report
// line says which ink columns the square holds; check it if the art moves.
let PET_MARGIN = 196
// idle's timeline holds frame 0 for its first second (steps[0] is [0, 1000])
// and the base bob rests at off 2 while tick % 64 < 56. 5 sits inside both,
// so this is the pose the pet spends most of its idle time in.
let TICK = 5

let BG      = NSColor(srgbRed: 0x1c / 255, green: 0x23 / 255, blue: 0x33 / 255, alpha: 1)
let TITLE   = NSColor(srgbRed: 0xf0 / 255, green: 0xf3 / 255, blue: 0xf6 / 255, alpha: 1)
let BODY    = NSColor(srgbRed: 0xae / 255, green: 0xb7 / 255, blue: 0xc2 / 255, alpha: 1)
let ACCENT  = NSColor(srgbRed: 0x37 / 255, green: 0xb3 / 255, blue: 0xe6 / 255, alpha: 1)  // the goggles

let outURL = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "docs/social-card.png")
// The tagline is the plugin's description, read from .claude-plugin/plugin.json
// — the copy the release gate holds byte-equal to marketplace.json's. GitHub's
// own About field is a third copy that nothing checks.
let pluginJSON = URL(fileURLWithPath: CommandLine.arguments.count > 2
                     ? CommandLine.arguments[2] : ".claude-plugin/plugin.json")

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

_ = NSApplication.shared
NSApplication.shared.setActivationPolicy(.prohibited)

guard let manifest = try? Data(contentsOf: pluginJSON),
      let obj = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
      let description = obj["description"] as? String, !description.isEmpty else {
    die("cannot read a description out of \(pluginJSON.path)")
}
// "A tiny native desktop pet … reacts to Claude Code — running, waiting, done,
// error. Swift binary, zero dependencies, no Electron." The dash splits the
// pitch from the mood list, the full stop splits the pitch from the footnote.
// A description shaped differently still renders — as one paragraph.
var pitch = description, moods = "", footnote = ""
if let dash = description.range(of: " — ") {
    pitch = String(description[..<dash.lowerBound])
    let rest = String(description[dash.upperBound...])
    if let stop = rest.range(of: ". ") {
        moods = String(rest[..<stop.lowerBound])
        footnote = String(rest[stop.upperBound...])
    } else {
        moods = rest
    }
}

// MARK: - Pet, rendered by the shipped draw() at the card's scale

let b = builtinPet
let pet = CustomPet(name: b.name, width: b.width, height: b.height, scale: PET_SCALE,
                    frames: b.frames, eyes: b.eyes, inkTop: b.inkTop, blinkFrame: b.blinkFrame,
                    sequences: b.sequences, unknownSequenceKeys: b.unknownSequenceKeys,
                    legacyMsKeys: b.legacyMsKeys)
let canvas = canvasSize(pet.width, pet.height, PET_SCALE)
// No window, on purpose: gaze() returns neutral without one, and a windowed
// view aims the pupils at wherever the mouse is, which is how a render stops
// being reproducible.
let view = PetView(frame: NSRect(origin: .zero, size: canvas))
view.custom = pet
view.scale = PET_SCALE
view.xpad = sidePad(PET_SCALE)
view.mood = .idle
view.tick = TICK
view.needsDisplay = true
// A rep of our own rather than bitmapImageRepForCachingDisplay: with no window
// that one takes the main screen's backing scale, which on a retina Mac is 2x,
// and a 2x render carries twelve device pixels per cell into a card whose
// pixels are the pixels. Sizing the rep in pixels to the canvas in points pins
// the render at 1x, so a cell is PET_SCALE pixels and nothing else.
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width),
                                 pixelsHigh: Int(canvas.height), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    die("cannot allocate the pet's bitmap")
}
rep.size = canvas
view.cacheDisplay(in: view.bounds, to: rep)
guard let petImage = rep.cgImage else { die("the view produced no image") }
let PW = petImage.width, PH = petImage.height
guard PW == Int(canvas.width), PH == Int(canvas.height) else {
    die("rendered \(PW)x\(PH) for a \(Int(canvas.width))x\(Int(canvas.height)) canvas; the rep is not 1x")
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func rgba(_ img: CGImage) -> [UInt8] {
    guard let c = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                            bytesPerRow: img.width * 4, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        die("cannot create an sRGB context")
    }
    c.interpolationQuality = .none
    c.setShouldAntialias(false)
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = c.data!.assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: p, count: img.width * img.height * 4))
}
let petPx = rgba(petImage)

// Where the ink actually landed, so the layout follows the drawing rather than
// the canvas — the canvas carries headroom and side padding the art never
// fills. Rows are bitmap rows, top-down: row 0 of a CGBitmapContext's buffer
// is the top of the image, however bottom-up the drawing coordinates are.
// Everything below stays in that space, and converts to CG's y only inside
// the two draw calls that need it.
var inkL = PW, inkR = -1, inkT = PH, inkB = -1
for y in 0..<PH {
    for x in 0..<PW where petPx[(y * PW + x) * 4 + 3] >= 128 {
        inkL = min(inkL, x); inkR = max(inkR, x)
        inkT = min(inkT, y); inkB = max(inkB, y)
    }
}
guard inkR >= 0 else { die("the pet rendered no opaque pixel") }
let inkW = inkR - inkL + 1, inkH = inkB - inkT + 1

// Every ink must still be recognisable as the colour the manifest asked for.
// Same measurement as the GIF tool, same bound: the render puts each ink
// through NSColor and CGImage, and that round trip costs up to 1 per channel.
// Further than that is colour management repainting the pet.
var drift = 0
var seen = Set<UInt32>()
for i in stride(from: 0, to: petPx.count, by: 4) where petPx[i + 3] >= 128 {
    let key = UInt32(petPx[i]) << 16 | UInt32(petPx[i + 1]) << 8 | UInt32(petPx[i + 2])
    guard seen.insert(key).inserted else { continue }
    var best = Int.max
    // The render is a sequence frame, so the palette it is held to has to
    // include the sequences' inks — a colour only a sequence uses would
    // otherwise read as drift.
    for grid in Array(b.frames.values) + b.sequences.values.flatMap({ $0.frames }) {
        for row in grid {
            for c in row {
                guard let c = c else { continue }
                let dr = Int(petPx[i]) - Int((c.redComponent * 255).rounded())
                let dg = Int(petPx[i + 1]) - Int((c.greenComponent * 255).rounded())
                let db = Int(petPx[i + 2]) - Int((c.blueComponent * 255).rounded())
                best = min(best, dr * dr + dg * dg + db * db)
            }
        }
    }
    drift = max(drift, best)
}
let perChannel = Int(Double(drift).squareRoot())
guard perChannel <= 1 else {
    die("PROFILE DRIFT: rendered inks drift up to \(perChannel) per channel from the manifest's palette")
}

// MARK: - Card

guard let ctx = CGContext(data: nil, width: CARD_W, height: CARD_H, bitsPerComponent: 8,
                          bytesPerRow: CARD_W * 4, space: srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    die("cannot create the card context")
}
ctx.setFillColor(BG.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: CARD_W, height: CARD_H))

// Pet: ink right-aligned to the margin and vertically centred. (petX, petY)
// is the render's top-left corner on the card, top-down.
let petX = CARD_W - PET_MARGIN - inkR - 1
let petY = (CARD_H - inkH) / 2 - inkT
ctx.saveGState()
ctx.interpolationQuality = .none
ctx.setShouldAntialias(false)
ctx.draw(petImage, in: CGRect(x: petX, y: CARD_H - petY - PH, width: PW, height: PH))
ctx.restoreGState()

// The perch: a bar under the feet, the width of the ink plus one margin each
// side, in the goggles' blue. It is the one thing on the card that is not the
// pet or a word, and it is there because the name is a claim about sitting on
// an edge.
let perchH = 6, perchPad = 24
let perchX = petX + inkL - perchPad, perchW = inkW + 2 * perchPad
let perchTop = petY + inkB + 1 + 4
// The round-trip below compares only pixels that landed on the card, so a pet
// taller than the card would clip top and bottom and still report clean.
// Width is bounded by the text column's guard; height has to be bounded here.
guard petY + inkT >= 0, perchTop + perchH <= CARD_H else {
    die("ink is \(inkH)px tall on a \(CARD_H)px card; the pet does not fit")
}
ctx.setFillColor(ACCENT.cgColor)
ctx.fill(CGRect(x: perchX, y: CARD_H - perchTop - perchH, width: perchW, height: perchH))

// Text. The column ends where the perch begins, less a gutter.
let textLeft = MARGIN
let textRight = perchX - 56
let textW = textRight - textLeft
guard textW >= 400 else {
    die("the pet leaves \(textW)px for text (render \(PW)x\(PH), ink \(inkW)x\(inkH)); the layout has broken")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
ctx.setShouldAntialias(true)
ctx.setShouldSmoothFonts(true)

func font(_ size: CGFloat, _ weight: NSFont.Weight, rounded: Bool = false) -> NSFont {
    let f = NSFont.systemFont(ofSize: size, weight: weight)
    guard rounded, let d = f.fontDescriptor.withDesign(.rounded) else { return f }
    return NSFont(descriptor: d, size: size) ?? f
}
func paragraph(_ text: String, _ f: NSFont, _ color: NSColor, lineSpacing: CGFloat = 0) -> NSAttributedString {
    let ps = NSMutableParagraphStyle()
    ps.lineSpacing = lineSpacing
    ps.lineBreakMode = .byWordWrapping
    return NSAttributedString(string: text, attributes: [
        .font: f, .foregroundColor: color, .paragraphStyle: ps,
    ])
}
func height(_ s: NSAttributedString, width: Int) -> Int {
    Int(ceil(s.boundingRect(with: NSSize(width: width, height: 10_000),
                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height))
}

// The title never wraps. At 112pt it is ~480px wide, and a pet whose ink is
// wider than the built-in's narrows the column below that (otter's does) —
// a title broken across two lines is the one failure the card cannot
// survive. Step the size down until one line fits; size() measures unwrapped.
var titleSize: CGFloat = 112
var title = paragraph("perchling", font(titleSize, .bold, rounded: true), TITLE)
while Int(ceil(title.size().width)) > textW, titleSize > 64 {
    titleSize -= 4
    title = paragraph("perchling", font(titleSize, .bold, rounded: true), TITLE)
}
let pitchText = paragraph(pitch, font(28, .regular), BODY, lineSpacing: 6)
let moodsText = paragraph(moods, font(30, .semibold), ACCENT)
let footText = paragraph(footnote, font(24, .regular), BODY.withAlphaComponent(0.7))

let blocks: [(NSAttributedString, Int)] = [
    (title, 0), (pitchText, 28), (moodsText, 18), (footText, 22),
].filter { $0.0.length > 0 }
let total = blocks.reduce(0) { $0 + $1.1 + height($1.0, width: textW) }
guard total <= CARD_H - 2 * MARGIN else { die("text stack is \(total)px tall; the description no longer fits") }

// Centre the text's INK, the way the pet is centred on its ink. A line box
// carries air above the cap height and a descender's worth below the
// baseline, and at 112pt the air on top is a dozen pixels the eye reads as
// the whole column sitting low. Taken from the fonts rather than pinned as a
// number, so a change of face or size moves it.
func fontOf(_ s: NSAttributedString) -> NSFont { s.attribute(.font, at: 0, effectiveRange: nil) as! NSFont }
let airAbove = Int((fontOf(blocks.first!.0).ascender - fontOf(blocks.first!.0).capHeight).rounded())
let airBelow = Int((-fontOf(blocks.last!.0).descender).rounded())

// Stack top-down from the centred block, in a bottom-up context.
var cursorTop = (CARD_H + total + airAbove - airBelow) / 2
for (s, gap) in blocks {
    cursorTop -= gap
    let h = height(s, width: textW)
    s.draw(with: NSRect(x: textLeft, y: cursorTop - h, width: textW, height: h),
           options: [.usesLineFragmentOrigin, .usesFontLeading])
    cursorTop -= h
}
NSGraphicsContext.restoreGraphicsState()

guard let card = ctx.makeImage() else { die("the card context produced no image") }
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else {
    die("cannot open \(outURL.path) for writing")
}
CGImageDestinationAddImage(dest, card, nil)
guard CGImageDestinationFinalize(dest) else { die("PNG encode failed") }

// MARK: - Verify

// GitHub rejects anything over 1 MB, and does so in a web form, after the
// upload — the one step of this pipeline that cannot be scripted.
let bytes = (try! Data(contentsOf: outURL)).count
guard bytes < 1_000_000 else { die("\(bytes) bytes; GitHub's limit is 1 MB") }

guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
      let back = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    die("the written file does not decode as an image")
}
guard back.width == CARD_W, back.height == CARD_H else {
    die("decoded \(back.width)x\(back.height), expected \(CARD_W)x\(CARD_H)")
}
// The pet on the card must be the pet draw() produced, pixel for pixel: every
// opaque pixel of the render lands at its offset with its colour, and every
// clear pixel inside the ink's bounding box shows the background. Text
// antialiasing is allowed to exist — that is what text does — but it is not
// allowed to have touched the pet, and neither is any interpolation on the
// blit. The canvas around the ink is not the pet: it is headroom and side
// padding, and a pet whose art starts far from its canvas edge (otter's does)
// legitimately shares that padding with the text column.
let cardPx = rgba(back)
let bgR = UInt8((BG.redComponent * 255).rounded()), bgG = UInt8((BG.greenComponent * 255).rounded()),
    bgB = UInt8((BG.blueComponent * 255).rounded())
var partial = 0, mismatched = 0
for y in 0..<PH {
    for x in 0..<PW {
        let s = (y * PW + x) * 4
        let a = petPx[s + 3]
        if a != 0 && a != 255 { partial += 1; continue }
        let cx = petX + x, cy = petY + y
        guard cx >= 0, cy >= 0, cx < CARD_W, cy < CARD_H else { continue }
        let d = (cy * CARD_W + cx) * 4
        if a == 0 && (x < inkL || x > inkR || y < inkT || y > inkB) { continue }
        let want: (UInt8, UInt8, UInt8) = a == 255 ? (petPx[s], petPx[s + 1], petPx[s + 2]) : (bgR, bgG, bgB)
        if abs(Int(cardPx[d]) - Int(want.0)) > 1 || abs(Int(cardPx[d + 1]) - Int(want.1)) > 1
            || abs(Int(cardPx[d + 2]) - Int(want.2)) > 1 {
            mismatched += 1
        }
    }
}
guard partial == 0 else { die("\(partial) pet pixels are semi-transparent; draw() antialiased something") }
guard mismatched == 0 else { die("\(mismatched) pet pixels on the card differ from the render; something interpolated") }

var report = "wrote \(outURL.path) — \(CARD_W)x\(CARD_H), \(bytes / 1024)KB\n"
report += "pet: \(b.name) @\(Int(PET_SCALE))x, ink \(inkW)x\(inkH) at (\(petX + inkL), \(petY + inkT)) top-left\n"
report += "text: \(textW)px column, \(total)px stack, title \(Int(titleSize))pt\n"
report += "centre square (\(CARD_W / 4)..\(CARD_W * 3 / 4)) holds ink columns \(petX + inkL)..\(min(petX + inkR, CARD_W * 3 / 4)) of \(petX + inkL)..\(petX + inkR)\n"
report += "palette: \(seen.count) inks, " + (perChannel == 0
    ? "matching the manifest exactly\n" : "within the 1-per-channel bound\n")
report += "round-trip: every pet pixel decodes back where draw() put it\n"
FileHandle.standardError.write(report.data(using: .utf8)!)
