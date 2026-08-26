// Appended to a cut copy of pet.swift by tools/run-pose-harness.sh.
// Assertions over sequence precedence in pose(). No window is created: a view
// with no window gazes neutral, which is what makes these reproducible.
//
// Every assertion below was proven able to fail before it was trusted — a green
// run is not evidence, and this repo has shipped assertions that tested nothing.
// The mutations, applied to pose() one at a time, and what each one killed:
//
//   tap arm never runs .................. 2, 6
//   `plays` dropped from the expiry ..... 6
//   hover arm not gated on `seq == nil` .. 1, 2
//   drag arm never runs ................. 1
//   bursts never expire ................. 3, 4, 5, 7
//   tap falls back to another sequence ... 8
//   pose() reads `custom` instead of `activePet` ... 9, 10
//
// Assertion 5 also has the strongest proof of all: it failed against the first
// implementation of the tap arm, which was an `else if` and let a spent tap
// swallow every hover after it.

// pose() gates every sequence on motionOK. The runner script pins motionOK to
// true in the scratch copy — the same treatment as a forced locale — so these
// assertions run identically whatever the machine's Reduce Motion setting is.
// A SKIP guard lived here instead and was worse than useless: it keyed the
// harness's coverage to an accessibility setting, and on a machine with Reduce
// Motion on, its exit 2 read as "harness went red" to the mutation gate,
// which passed a mutant on the strength of a harness that had refused to run.

var passed = 0, failed = 0
func check(_ label: String, _ cond: Bool) {
    if cond { passed += 1; print("ok   \(label)") }
    else { failed += 1; print("FAIL \(label)") }
}

// A boolean says which assertion broke and nothing about why. These are
// numeric fields of a struct, so print the number.
func checkEq<T: Equatable>(_ label: String, _ got: T, _ want: T) {
    if got == want { passed += 1; print("ok   \(label)") }
    else { failed += 1; print("FAIL \(label)\n       got:  \(got)\n       want: \(want)") }
}

func grid(_ rows: [String], _ pal: [Character: NSColor]) -> [[NSColor?]] {
    rows.map { row in row.map { pal[$0] } }
}

let pal: [Character: NSColor] = ["#": .white, "o": .gray]
let a = grid(["........", "........", "..####..", "..####..",
              "..####..", "..####..", "........", "........"], pal)
let b = grid(["........", "........", "..oooo..", "..oooo..",
              "..oooo..", "..oooo..", "........", "........"], pal)
let c = grid(["..####..", "..####..", "..oooo..", "..oooo..",
              "........", "........", "........", "........"], pal)

// Every sequence here is two frames at one tick each, so a frame index is a
// direct read of which arm of the precedence chain won.
func seq(_ frames: [[[NSColor?]]], plays: Int = 1, mirror: Bool = false) -> PetSequence {
    PetSequence(frames: frames, schedule: [0, 1],
                steps: [(frame: 0, ms: 50, ticks: 1), (frame: 1, ms: 50, ticks: 1)],
                mirror: mirror, plays: plays)
}

func pet(_ sequences: [SeqKind: PetSequence]) -> CustomPet {
    CustomPet(name: "harness", width: 8, height: 8, scale: 1,
              frames: [.idle: a, .running: a, .waiting: a, .done: a, .error: a],
              eyes: nil, inkTop: 0, blinkFrame: nil,
              sequences: sequences, unknownSequenceKeys: [], legacyMsKeys: [])
}

let view = PetView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
view.custom = pet([.hover: seq([a, b]), .tap: seq([a, c]),
                   .drag: seq([b, c]), .idle: seq([b, a])])

// `Pose` is nested in PetView, so it is `PetView.Pose` from out here.
func poseAt(_ t: Int, drag: Int = -1, hover: Int = -1, tap: Int = -1,
            moodStart: Int = 0) -> PetView.Pose {
    view.tick = t
    view.dragSeqStart = drag
    view.hoverSeqStart = hover
    view.tapSeqStart = tap
    view.moodSeqStart = moodStart
    return view.pose()
}

// 1. Drag outranks everything: the cursor sitting on a pet you are already
//    holding is not new information.
check("drag beats tap and hover", poseAt(10, drag: 10, hover: 10, tap: 10).seq?.kind == .drag)

// 2. Tap outranks hover. This is the rule that makes tap reachable at all: the
//    cursor is on the pet whenever a tap arrives, so hover is always armed.
check("tap beats hover", poseAt(10, hover: 10, tap: 10).seq?.kind == .tap)

// 3. A spent tap does not block the mood loop — the `else if` regression
//    docs/invariants/pose.md warns about, now with two armed-forever clocks instead of one.
check("spent tap falls through to the mood loop", poseAt(100, tap: 10).seq?.kind == .idle)

// 4. The original form of the same rule.
check("spent hover falls through to the mood loop", poseAt(100, hover: 10).seq?.kind == .idle)

// 5. And a spent tap must not swallow a later hover either. This is the case an
//    `else if` chain gets wrong while still passing checks 3 and 4.
check("spent tap still lets hover play", poseAt(100, hover: 100, tap: 10).seq?.kind == .hover)

// 6. `plays` repeats a one-shot rather than lengthening it: a 2-tick sequence
//    with plays: 2 is alive at offset 3 and spent at 4.
view.custom = pet([.tap: seq([a, c], plays: 2), .idle: seq([b, a])])
check("plays repeats a one-shot", poseAt(13, tap: 10).seq?.kind == .tap)
check("plays does not lengthen it", poseAt(14, tap: 10).seq?.kind == .idle)

// 7. A pet that declared no tap sequence is untouched by any of this: the
//    procedural hop still owns the poke, and pose() must not invent a frame.
view.custom = pet([.idle: seq([b, a])])
check("no tap sequence means no tap frame", poseAt(10, tap: 10).seq?.kind == .idle)

// 9-10. The built-in is a manifest too, and every draw path must read
//    `activePet` rather than `custom`. A sequence declared by the built-in that
//    pose() cannot see is not merely inert: mouseUp arms `tapSeqStart` off
//    `activePet`, so declaring `tap` gives up the procedural hop for a frame
//    that never arrives, and clicking the pet does nothing at all.
builtinPet = pet([.tap: seq([a, c]), .idle: seq([b, a])])
view.custom = nil
check("built-in tap plays with no custom pet", poseAt(10, tap: 10).seq?.kind == .tap)
check("built-in mood loop plays with no custom pet", poseAt(10).seq?.kind == .idle)

print("---")
// --- what a playing sequence takes, and what it leaves alone -----------------
//
// The frames carry their own motion, so a bounce or a twitch added on top
// double-counts a jump's lift. Everything above asserts WHICH sequence won;
// these assert what winning costs, which is a different field of the same Pose
// and was never read.
//
// `running` is the mood that moves both at once — off = 2 + (tick/4)%2 and
// dx = -1 at tick 12 — so it is the only one that can tell a pinned pose from
// an unpinned one. The pair without a sequence is the control: without it,
// asserting 2 and 0 would pass against a pose() that never moved anything.
view.mood = .running
view.custom = pet([.running: seq([b, a])])
// `off` and `dx` leave pose() in POINTS, already multiplied by the bounce unit
// — the switch above works in units and the struct carries the product. Taken
// from bounceUnit rather than written as 8, so the numbers here cannot drift
// away from a change in what a bounce is worth.
let u = bounceUnit(view.activePet.scale)
let pinned = poseAt(12)
checkEq("a mood loop pins the bounce to its resting value", pinned.off, 2 * u)
checkEq("and zeroes the twitch", pinned.dx, 0)
check("the loop really is playing", pinned.seq?.kind == .running)

view.custom = pet([:])
let free = poseAt(12)
checkEq("control: the same mood unsequenced still bounces", free.off, 3 * u)
checkEq("control: and still twitches", free.dx, -u)

// The one exception on record: a tap hop outranks a mood loop, because a
// resting state is not a reaction and a poke that visibly does nothing reads
// as a dead window.
// Tick 15, not 12: the hop alternates 2 and 0 every three ticks, and at 12 it
// happens to sit at 2 — the same value the pinning produces. Asserted there,
// this would pass against a pose() that had no hop arm at all.
view.custom = pet([.running: seq([b, a])])
view.hopUntil = 100
checkEq("a tap hop still moves a pet whose mood is a loop", poseAt(15).off, 0)
view.hopUntil = -1
checkEq("control: without the hop that same tick is pinned", poseAt(15).off, 2 * u)

// --- mirror is consent, not a default ----------------------------------------
//
// The reflection is free and the consent is not: a flip reverses any asymmetric
// detail — a badge, lettering — and the renderer cannot tell those from a gait.
// So a pet that never declared `mirror` must not flip however it is dragged.
view.mood = .idle
view.dragFacingLeft = true
view.custom = pet([.drag: seq([b, c])])
check("a drag sequence without mirror never flips", poseAt(0, drag: 0).seq?.flipped == false)
view.custom = pet([.drag: seq([b, c], mirror: true)])
check("one that declares mirror flips on leftward travel", poseAt(0, drag: 0).seq?.flipped == true)
view.dragFacingLeft = false
check("and faces right when travel is not leftward", poseAt(0, drag: 0).seq?.flipped == false)

// --- the shear stands down for a mirrored drag --------------------------------
//
// A mirrored drag already expresses direction — the flip is the facing — so
// pose() zeroes the lean while one plays: stacked, the shear's per-row
// rounding slides a dark face plate out of the head outline, a block that
// swaps sides with the drag direction. A direction-blind drag keeps it, and
// so does a pet with no drag sequence: there the shear is the only signal.
// Both directions of the mutation were shown to fail — the carve-out removed
// reds the first check, the carve-out widened to every drag reds the second.
view.lean = 3
view.custom = pet([.drag: seq([b, c], mirror: true)])
checkEq("a mirrored drag stands the shear down", poseAt(0, drag: 0).lean, 0)
view.custom = pet([.drag: seq([b, c])])
checkEq("an unmirrored drag keeps the shear", poseAt(0, drag: 0).lean, 3)
view.custom = pet([:])
checkEq("no drag sequence keeps it too", poseAt(0, drag: 0).lean, 3)
view.lean = 0

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
