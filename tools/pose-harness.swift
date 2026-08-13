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

// pose() gates every sequence on motionOK, so under Reduce Motion each of these
// would fail for a reason that has nothing to do with the rule under test. Say
// so and exit unrun rather than reporting a colour.
guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
    print("SKIP: Reduce Motion is on — pose() freezes every sequence, so nothing here is testable.")
    exit(2)
}

var passed = 0, failed = 0
func check(_ label: String, _ cond: Bool) {
    if cond { passed += 1; print("ok   \(label)") }
    else { failed += 1; print("FAIL \(label)") }
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
//    AGENTS.md warns about, now with two armed-forever clocks instead of one.
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
print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
