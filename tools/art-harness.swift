// Every pixel of shipped art must either be drawn or be reachable from outside.
//
// The overlay paints no background, so a transparent pixel the border cannot
// reach is a hole the desktop shows through — and on a light wallpaper it is
// the most visible thing about the pet. 1.13.0 shipped 7,293 of them in the
// built-in husky and another 18,822 across the five examples, almost all of
// them inside the goggle lenses: the worst single region spanned the whole face
// at 192 px. They are quantisation residue rather than drawing mistakes, which
// is why nobody caught them by reading the manifest.
//
// This runs against every manifest path it is given — assets/builtin.json and
// examples/ — plus the placeholder compiled into the binary, which no path can
// reach. There is one copy of each of those, so there is nothing for a check to
// drift away from: the file the runner passes is the file that ships.

import Foundation

var pass = 0
var fail = 0

// Transparent cells with no 4-connected path to the edge of the canvas. The
// walk starts from the border rather than from a known-outside pixel because a
// pet may touch every edge — canvasSize() reserves the margins, the grid does
// not have to leave any.
func enclosed(_ grid: [[NSColor?]]) -> Int {
    let h = grid.count
    guard h > 0 else { return 0 }
    let w = grid[0].count
    var seen = [Bool](repeating: false, count: w * h)
    var stack: [Int] = []

    func push(_ x: Int, _ y: Int) {
        let i = y * w + x
        if !seen[i] && grid[y][x] == nil {
            seen[i] = true
            stack.append(i)
        }
    }
    for y in 0..<h { push(0, y); push(w - 1, y) }
    for x in 0..<w { push(x, 0); push(x, h - 1) }
    while let i = stack.popLast() {
        let x = i % w, y = i / w
        if x > 0 { push(x - 1, y) }
        if x < w - 1 { push(x + 1, y) }
        if y > 0 { push(x, y - 1) }
        if y < h - 1 { push(x, y + 1) }
    }
    var n = 0
    for y in 0..<h where grid[y].count == w {
        for x in 0..<w where grid[y][x] == nil && !seen[y * w + x] { n += 1 }
    }
    return n
}

// Every grid a manifest can put on screen, named the way --validate names them
// so a failure points at something an author can open and look at.
func allGrids(_ pet: CustomPet) -> [(String, [[NSColor?]])] {
    var out: [(String, [[NSColor?]])] = []
    for m in [Mood.done, .error, .idle, .running, .waiting] {
        if let g = pet.frames[m] { out.append(("moods.\(m.rawValue)", g)) }
    }
    for k in SeqKind.allCases {
        guard let s = pet.sequences[k] else { continue }
        for (i, f) in s.frames.enumerated() {
            out.append(("sequences.\(k.rawValue)[\(i)]", f))
        }
    }
    // Synthesised at load rather than authored, so it is the one grid no author
    // can inspect — and it is built by wiping pixels, which is how holes appear.
    if let b = pet.blinkFrame { out.append(("blinkFrame", b)) }
    return out
}

func check(_ label: String, _ pet: CustomPet) {
    var total = 0
    var worst = ""
    var worstN = 0
    for (name, grid) in allGrids(pet) {
        let n = enclosed(grid)
        total += n
        if n > worstN { worstN = n; worst = name }
    }
    if total == 0 {
        print(String(format: "  ok   %-24s no transparent pixel is enclosed", (label as NSString).utf8String!))
        pass += 1
    } else {
        print("  FAIL \(label): \(total) enclosed transparent px, worst grid \(worst) with \(worstN)")
        fail += 1
    }
}

print("shipped art:")
// `builtinPet` is declared below this harness's cut now — it needs the runtime
// home to know which file to load. What ships is checked as a file instead,
// passed in by the runner alongside examples/, and the embedded placeholder is
// checked here because no argument can reach it.
check("placeholder (embedded)", builtinFrom(nil).pet)

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    do {
        let pet = try loadCustomPet(Data(contentsOf: url))
        check(url.lastPathComponent, pet)
    } catch {
        print("  FAIL \(url.lastPathComponent): \(error)")
        fail += 1
    }
}

print("")
print("\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
