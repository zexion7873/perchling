// Renders .claude-plugin/icon.png — the plugin directory's listing icon — from
// the real draw(), appended to pet.swift's body by tools/make-icon.sh. Same
// cut and same reason as social-card.swift: an icon drawn from anything but
// PetView.draw() is a second drawing of the pet, and second drawings drift.
//
// The pet is rendered at an integer scale, never resampled, so every sprite
// cell is a square of whole pixels. The scale is the largest that fits the
// ink inside the margin, so a pet with a different silhouette still fills it.

let SIZE = 1024
let MARGIN_FRAC = 0.12
// The squircle-ish corner macOS app icons use, so the tile reads as an icon
// rather than a screenshot crop.
let CORNER_FRAC: CGFloat = 0.2237
// Same pose the social card shows, for the same reason: see social-card.swift.
let TICK = 5
let BG = NSColor(srgbRed: 0x1c / 255, green: 0x23 / 255, blue: 0x33 / 255, alpha: 1)

let outURL = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : ".claude-plugin/icon.png")

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

_ = NSApplication.shared
NSApplication.shared.setActivationPolicy(.prohibited)
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

// A 1x rep sized in pixels, for the reason social-card.swift gives: the
// windowless caching rep takes the screen's backing scale.
func render(_ scale: CGFloat) -> CGImage {
    let b = builtinPet
    let pet = CustomPet(name: b.name, width: b.width, height: b.height, scale: scale,
                        frames: b.frames, eyes: b.eyes, inkTop: b.inkTop, blinkFrame: b.blinkFrame,
                        sequences: b.sequences, unknownSequenceKeys: b.unknownSequenceKeys,
                        legacyMsKeys: b.legacyMsKeys)
    let canvas = canvasSize(pet.width, pet.height, scale)
    let view = PetView(frame: NSRect(origin: .zero, size: canvas))
    view.custom = pet
    view.scale = scale
    view.xpad = sidePad(scale)
    view.mood = .idle
    view.tick = TICK
    view.needsDisplay = true
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width),
                                     pixelsHigh: Int(canvas.height), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        die("cannot allocate the pet's bitmap")
    }
    rep.size = canvas
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let img = rep.cgImage, img.width == Int(canvas.width), img.height == Int(canvas.height) else {
        die("the render is not 1x for a \(Int(canvas.width))x\(Int(canvas.height)) canvas")
    }
    return img
}

// Rows are bitmap rows, top-down, as in social-card.swift.
func ink(_ px: [UInt8], _ w: Int, _ h: Int) -> (l: Int, r: Int, t: Int, b: Int) {
    var l = w, r = -1, t = h, bt = -1
    for y in 0..<h {
        for x in 0..<w where px[(y * w + x) * 4 + 3] >= 128 {
            l = min(l, x); r = max(r, x); t = min(t, y); bt = max(bt, y)
        }
    }
    guard r >= 0 else { die("the pet rendered no opaque pixel") }
    return (l, r, t, bt)
}

let one = render(1)
let ink1 = ink(rgba(one), one.width, one.height)
let avail = Double(SIZE) * (1 - 2 * MARGIN_FRAC)
let fit = min(avail / Double(ink1.r - ink1.l + 1), avail / Double(ink1.b - ink1.t + 1))
guard fit >= 1 else { die("the pet's ink does not fit \(SIZE)px at scale 1") }
let SCALE = CGFloat(Int(fit))

let petImage = render(SCALE)
let PW = petImage.width, PH = petImage.height
let petPx = rgba(petImage)
let k = ink(petPx, PW, PH)
let inkW = k.r - k.l + 1, inkH = k.b - k.t + 1

guard let ctx = CGContext(data: nil, width: SIZE, height: SIZE, bitsPerComponent: 8,
                          bytesPerRow: SIZE * 4, space: srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    die("cannot create the icon context")
}
let corner = CGFloat(SIZE) * CORNER_FRAC
ctx.setFillColor(BG.cgColor)
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: SIZE, height: SIZE),
                   cornerWidth: corner, cornerHeight: corner, transform: nil))
ctx.fillPath()

// Ink centred on the tile. (petX, petY) is the render's top-left, top-down.
let petX = (SIZE - inkW) / 2 - k.l
let petY = (SIZE - inkH) / 2 - k.t
ctx.saveGState()
ctx.interpolationQuality = .none
ctx.setShouldAntialias(false)
ctx.draw(petImage, in: CGRect(x: petX, y: SIZE - petY - PH, width: PW, height: PH))
ctx.restoreGState()

guard let icon = ctx.makeImage() else { die("the icon context produced no image") }
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else {
    die("cannot open \(outURL.path) for writing")
}
CGImageDestinationAddImage(dest, icon, nil)
guard CGImageDestinationFinalize(dest) else { die("PNG encode failed") }

// MARK: - Verify

guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
      let back = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    die("the written file does not decode as an image")
}
guard back.width == SIZE, back.height == SIZE else {
    die("decoded \(back.width)x\(back.height), expected \(SIZE)x\(SIZE)")
}
// Every pet pixel inside the ink box must decode back exactly where draw() put
// it: opaque pixels with their colour, clear ones as the tile. The corners are
// outside the ink box by construction (the margin is wider than the corner's
// reach into the square), so the tile colour is the only background there is.
let iconPx = rgba(back)
let bg = (UInt8((BG.redComponent * 255).rounded()), UInt8((BG.greenComponent * 255).rounded()),
          UInt8((BG.blueComponent * 255).rounded()))
var partial = 0, mismatched = 0
for y in k.t...k.b {
    for x in k.l...k.r {
        let s = (y * PW + x) * 4
        let a = petPx[s + 3]
        if a != 0 && a != 255 { partial += 1; continue }
        let d = ((petY + y) * SIZE + petX + x) * 4
        let want = a == 255 ? (petPx[s], petPx[s + 1], petPx[s + 2]) : bg
        if abs(Int(iconPx[d]) - Int(want.0)) > 1 || abs(Int(iconPx[d + 1]) - Int(want.1)) > 1
            || abs(Int(iconPx[d + 2]) - Int(want.2)) > 1 || iconPx[d + 3] != 255 {
            mismatched += 1
        }
    }
}
guard partial == 0 else { die("\(partial) pet pixels are semi-transparent; draw() antialiased something") }
guard mismatched == 0 else { die("\(mismatched) pet pixels on the icon differ from the render; something interpolated") }

let bytes = (try! Data(contentsOf: outURL)).count
var report = "wrote \(outURL.path) — \(SIZE)x\(SIZE), \(bytes / 1024)KB\n"
report += "pet: \(builtinPet.name) @\(Int(SCALE))x, ink \(inkW)x\(inkH) centred\n"
report += "round-trip: every pet pixel decodes back where draw() put it\n"
FileHandle.standardError.write(report.data(using: .utf8)!)
