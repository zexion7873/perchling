// Regenerates docs/moods.gif from the real draw(), appended to pet.swift's
// body by tools/make-moods-gif.sh. It is not part of the shipped binary: the
// overlay has no reason to carry an LZW encoder, and the alternative — a
// hidden --gif flag — puts dev tooling on a CLI whose dispatch is already
// load-bearing.
//
// GIF is an indexed format and the pet is ten flat colours, so the encode is
// lossless rather than merely acceptable. Every frame comes from PetView.draw()
// through cacheDisplay, which is what makes this a picture of the pet that
// ships instead of a second drawing of it.

let FRAMES = 54       // one full tear cycle; anything shorter cuts a droplet
                      // off mid-fall at the loop seam
let START = 30        // ticks 0-15 are inside idle's open-eyed peek, and a
                      // peeking idle reads identically to waiting — a bad first
                      // frame for a hero whose whole claim is that the moods
                      // differ. Every animation here is periodic, so starting
                      // late rotates the loop without breaking it.
let DELAY = 6         // hundredths; the overlay ticks at 1/20s
let CELL_PAD = 4      // per side, so five 104pt canvases land on 560

// Five cells in one row, one per mood. The sixth used to show the hover
// startle; the built-in is a manifest now and reacts to hover only when it
// declares the frames, which this one does not — so there is no sixth pose to
// photograph, rather than a sixth pose being left out.
let CELLS: [Mood] = [.idle, .running, .waiting, .done, .error]

// MARK: - GIF89a

struct BitWriter {
    private var bytes: [UInt8] = []
    private var acc = 0
    private var bits = 0

    mutating func write(_ code: Int, _ width: Int) {
        acc |= code << bits
        bits += width
        while bits >= 8 {
            bytes.append(UInt8(acc & 0xff))
            acc >>= 8
            bits -= 8
        }
    }

    mutating func flush() -> [UInt8] {
        if bits > 0 { bytes.append(UInt8(acc & 0xff)); acc = 0; bits = 0 }
        return bytes
    }
}

// The code-width grows the moment the next code stops fitting, which is the
// same moment the decoder's table does. Getting this one comparison wrong
// produces a file that opens fine in some decoders and shears in others, so
// the output is decoded back and compared rather than eyeballed.
func lzwEncode(_ pixels: [UInt8], minCodeSize: Int) -> [UInt8] {
    let clearCode = 1 << minCodeSize
    let endCode = clearCode + 1
    var codeSize = minCodeSize + 1
    var nextCode = endCode + 1
    var table: [Int: Int] = [:]
    var w = BitWriter()

    w.write(clearCode, codeSize)
    var prefix = -1
    for px in pixels {
        let ch = Int(px)
        if prefix < 0 { prefix = ch; continue }
        let key = prefix << 8 | ch
        if let found = table[key] {
            prefix = found
        } else {
            w.write(prefix, codeSize)
            if nextCode < 4096 {
                table[key] = nextCode
                nextCode += 1
                if nextCode > (1 << codeSize) && codeSize < 12 { codeSize += 1 }
            } else {
                w.write(clearCode, codeSize)
                table.removeAll(keepingCapacity: true)
                nextCode = endCode + 1
                codeSize = minCodeSize + 1
            }
            prefix = ch
        }
    }
    if prefix >= 0 { w.write(prefix, codeSize) }
    w.write(endCode, codeSize)
    return w.flush()
}

func subBlocks(_ data: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var i = 0
    while i < data.count {
        let n = min(255, data.count - i)
        out.append(UInt8(n))
        out.append(contentsOf: data[i..<(i + n)])
        i += n
    }
    out.append(0)
    return out
}

func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }

// Index 0 is transparent so the hero adapts to whatever background a README is
// rendered on; the inks follow it in Ink's own order. The table's bit depth is
// derived from what the render actually produced — a hardcoded size is exactly
// the kind of value that survives an ink-count change and ships a torn file.
func buildGIF(frames: [[UInt8]], width: Int, height: Int, table: [NSColor]) -> Data {
    var bits = 2
    while (1 << bits) < table.count + 1 { bits += 1 }
    var out: [UInt8] = Array("GIF89a".utf8)
    out += u16(width) + u16(height)
    out += [UInt8(0xF0 | (bits - 1)), 0x00, 0x00]   // GCT present, 2^bits entries
    out += [0, 0, 0]                                // index 0: transparent
    for c in table {
        out += [UInt8((c.redComponent * 255).rounded()),
                UInt8((c.greenComponent * 255).rounded()),
                UInt8((c.blueComponent * 255).rounded())]
    }
    out += Array(repeating: 0, count: ((1 << bits) - 1 - table.count) * 3)
    out += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]

    for f in frames {
        // Disposal 2 (restore to background) — without it a transparent pixel
        // keeps whatever the previous frame left there and the pet smears.
        out += [0x21, 0xF9, 0x04, 0x09] + u16(DELAY) + [0x00, 0x00]
        out += [0x2C] + u16(0) + u16(0) + u16(width) + u16(height) + [0x00]
        out += [UInt8(bits)]
        out += subBlocks(lzwEncode(f, minCodeSize: bits))
    }
    out += [0x3B]
    return Data(out)
}

// MARK: - frames from the real renderer

let outURL = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "docs/moods.gif")

_ = NSApplication.shared
NSApplication.shared.setActivationPolicy(.prohibited)

if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    FileHandle.standardError.write(
        "Reduce Motion is on: the tick freezes, so every cell renders one resting frame. Turn it off and re-run.\n"
        .data(using: .utf8)!)
    exit(1)
}

// The expected colour set is harvested from the pet's own frames rather than
// kept as a list in step by hand. That list was a mirror of an enum, and a
// mirror is a thing that goes stale silently: an ink the art stops using is now
// a manifest edit, and this finds out by looking.
let inks: [NSColor] = {
    var seen: [String: NSColor] = [:]
    for grid in builtinPet.frames.values {
        for row in grid {
            for c in row where c != nil {
                let k = String(format: "%02x%02x%02x",
                               Int((c!.redComponent * 255).rounded()),
                               Int((c!.greenComponent * 255).rounded()),
                               Int((c!.blueComponent * 255).rounded()))
                seen[k] = c!
            }
        }
    }
    return Array(seen.values)
}()

let canvas = canvasSize(builtinPet.width, builtinPet.height, builtinPet.scale)
let cw = Int(canvas.width), chh = Int(canvas.height)
let cellW = cw + 2 * CELL_PAD
let W = cellW * CELLS.count, H = chh

// No window on purpose. Pupils drift toward the cursor, and gaze() gives up and
// returns neutral when the view has no window — so a windowless view is the one
// arrangement that cannot bake whatever the mouse was doing into committed art.
// Attaching one and centring it on the pointer looks equivalent but is not: the
// pointer can move during the render.
let views = CELLS.map { mood -> PetView in
    let v = PetView(frame: NSRect(origin: .zero, size: canvas))
    v.mood = mood
    return v
}

// Render every frame first, then build the colour table from what actually
// landed in the pixels. Comparing against the manifest's colours instead loses to
// colour management — the same srgb value drawn through AppKit comes back
// shifted — and a table harvested from the render is lossless by construction.
// GIF carries no colour profile, so the context is pinned to sRGB and the
// bytes written are the bytes every viewer will show.
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
var rendered: [[UInt8]] = []          // RGBA, W*H*4 per frame

for step in 0..<FRAMES {
    let tick = START + step
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                              bytesPerRow: W * 4, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write("cannot create an sRGB context\n".data(using: .utf8)!)
        exit(1)
    }
    // Blit the cached CGImage straight in. Going through NSImage.draw lets the
    // context interpolate — the view is flipped and the context is not, and the
    // resulting half-pixel offset blends every pixel with its neighbour, which
    // turns a handful of flat inks into a million.
    ctx.interpolationQuality = .none
    ctx.setShouldAntialias(false)
    for (i, v) in views.enumerated() {
        v.tick = tick
        v.needsDisplay = true
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let cg = rep.cgImage else {
            FileHandle.standardError.write("frame \(tick): the view produced no image\n".data(using: .utf8)!)
            exit(1)
        }
        ctx.draw(cg, in: CGRect(x: CGFloat(i * cellW + CELL_PAD), y: 0,
                                width: canvas.width, height: canvas.height))
    }
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    rendered.append(Array(UnsafeBufferPointer(start: p, count: W * H * 4)))
}

// One entry per distinct opaque colour. More than the ink count means the
// renderer antialiased something, and an indexed format would then be
// quantising real art rather than storing it — worth failing over, not
// rounding away.
var indexOf: [UInt32: UInt8] = [:]
var observed: [UInt32] = []
for frame in rendered {
    for i in stride(from: 0, to: frame.count, by: 4) where frame[i + 3] >= 128 {
        let key = UInt32(frame[i]) << 16 | UInt32(frame[i + 1]) << 8 | UInt32(frame[i + 2])
        if indexOf[key] == nil, observed.count < inks.count {
            observed.append(key)
            indexOf[key] = UInt8(observed.count)
        } else if indexOf[key] == nil {
            observed.append(key)
        }
    }
}
guard observed.count == inks.count else {
    FileHandle.standardError.write(
        "expected \(inks.count) distinct colours, the render produced \(observed.count) — something is antialiasing\n"
        .data(using: .utf8)!)
    exit(1)
}
let table = observed.map {
    NSColor(srgbRed: CGFloat(($0 >> 16) & 0xff) / 255, green: CGFloat(($0 >> 8) & 0xff) / 255,
            blue: CGFloat($0 & 0xff) / 255, alpha: 1)
}

// Every ink must still be recognisable as the colour the manifest asked for; a
// silent profile shift would otherwise ship a differently-coloured pet.
var drift = 0
for key in observed {
    var best = Int.max
    for c in inks {
        let dr = Int((key >> 16) & 0xff) - Int((c.redComponent * 255).rounded())
        let dg = Int((key >> 8) & 0xff) - Int((c.greenComponent * 255).rounded())
        let db = Int(key & 0xff) - Int((c.blueComponent * 255).rounded())
        best = min(best, dr * dr + dg * dg + db * db)
    }
    drift = max(drift, best)
}

var gifFrames: [[UInt8]] = []
for frame in rendered {
    var indices = [UInt8](repeating: 0, count: W * H)
    for i in stride(from: 0, to: frame.count, by: 4) where frame[i + 3] >= 128 {
        let key = UInt32(frame[i]) << 16 | UInt32(frame[i + 1]) << 8 | UInt32(frame[i + 2])
        indices[i / 4] = indexOf[key]!
    }
    gifFrames.append(indices)
}

try! buildGIF(frames: gifFrames, width: W, height: H, table: table).write(to: outURL)

// Decode the file back through the system decoder and compare every pixel to
// what was encoded. A code-width off-by-one still produces a file, and it
// still opens somewhere — this is the only check that tells them apart.
func verify() -> String? {
    guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil) else {
        return "the written file is not readable as an image"
    }
    let n = CGImageSourceGetCount(src)
    guard n == FRAMES else { return "decoded \(n) frames, encoded \(FRAMES)" }
    for i in 0..<n {
        guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else {
            return "frame \(i) failed to decode"
        }
        guard cg.width == W, cg.height == H else {
            return "frame \(i) decoded \(cg.width)x\(cg.height), expected \(W)x\(H)"
        }
        // Redraw into the very context the encode side used rather than poking
        // at whatever layout the decoder handed back. A GIF frame can come back
        // alpha-first, and reading byte 3 as alpha then reports every dark ink
        // as transparent — a decode bug that looks exactly like an encode bug.
        guard let vctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                                   bytesPerRow: W * 4, space: srgb,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return "cannot create the comparison context"
        }
        vctx.interpolationQuality = .none
        vctx.setShouldAntialias(false)
        vctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        let px = vctx.data!.assumingMemoryBound(to: UInt8.self)
        for j in 0..<(W * H) {
            let o = j * 4
            let expected = gifFrames[i][j]
            let got: UInt8
            if px[o + 3] < 128 {
                got = 0
            } else {
                let key = UInt32(px[o]) << 16 | UInt32(px[o + 1]) << 8 | UInt32(px[o + 2])
                guard let idx = indexOf[key] else {
                    return "frame \(i) pixel (\(j % W),\(j / W)) decoded to a colour outside the palette"
                }
                got = idx
            }
            if got != expected {
                return "frame \(i) pixel (\(j % W),\(j / W)): decoded index \(got), encoded \(expected)"
            }
        }
    }
    return nil
}

var report = "wrote \(outURL.path) — \(W)x\(H), \(FRAMES) frames @ \(DELAY)0ms, "
report += "\((try! Data(contentsOf: outURL)).count / 1024)KB\n"
report += "palette: \(observed.count) colours, all of them stored verbatim\n"
report += drift == 0
    ? "profile: the rendered inks match the manifest's palette exactly\n"
    : "profile: rendered inks drift up to \(Int(Double(drift).squareRoot())) per channel from the manifest's palette\n"
if let failure = verify() {
    report += "ROUND-TRIP FAILED: \(failure)\n"
    FileHandle.standardError.write(report.data(using: .utf8)!)
    exit(1)
}
report += "round-trip: all \(FRAMES) frames decode back pixel-for-pixel\n"
FileHandle.standardError.write(report.data(using: .utf8)!)
