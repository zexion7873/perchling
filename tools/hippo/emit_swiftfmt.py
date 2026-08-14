#!/usr/bin/env python3
"""Emit the hippo manifest byte-formatted the way Swift's JSONSerialization
(.prettyPrinted + .sortedKeys) writes it, so --export can print the embedded
string verbatim and examples/perchling.json is that same text."""
import sys, os, json
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from hippo import PAL
import v6_deform as art          # v5_lighter plus the squash/stretch axis;
                                # art.build(m) with no deformation is proven
                                # byte-identical to v5_lighter by check_deform.

MOODS = ['done', 'error', 'idle', 'running', 'waiting']      # sorted, as Swift emits
grids = {m: art.build(m) for m in MOODS}
used = sorted({c for g in grids.values() for row in g for c in row if c})

def rows(m):
    return [''.join(c if c else '.' for c in row) for row in grids[m]]

# Keys sort alphabetically the way JSONSerialization(.sortedKeys) writes them:
# eyes, moods, name, palette, scale, sequences.
#
# The box is `waiting`'s WHOLE eye -- the amber, the ivory catchlight, and the
# 'o' almond ring around them: x26..69, y11..27. Blink is synthesised from
# `waiting`, so it is measured there.
#
# The amber interior alone (28,13,40,14) was tried first and rendered wrong.
# synthBlinkFrame repaints the whole box and nothing outside it, so a box that
# stops at the amber leaves 64 pixels of eye edge and ring behind: the closed
# face came out with two loose amber arcs floating over the ears. The ring has
# to go with the eye.
#
# The upper bound on growing it is transparency, not taste. The repaint is
# unconditional -- `out[y][x] = socketColor` for every cell in the box -- so a
# box overhanging the head outline paints a coral rectangle corner onto the
# desktop. (26,11,44,17) is the box that covers every eye pixel with zero
# transparent cells inside it. It costs 22 cells of the head's `l`/`s` shading
# flattened to coral for the two ticks a blink lasts.
#
# range 0 is load-bearing, not a default. The gaze shifts the box's contents and
# refills the vacated strip with `socket`, and this pet has ZERO coral margin
# beside its eyes at rows 21-22 -- searched exhaustively, every box within nine
# pixels of the amber bbox in every mood, and not one has a single-ink border.
# Declaring a range would smear the face. At range 0 the box feeds nothing but
# synthBlinkFrame, which repaints it whole and therefore needs no margin at all.
#
# `lid` is declared rather than left to auto-selection: the auto rule takes the
# brightest ink covering >=3% of the box, which here is `e`, so a blink would
# close the eye and leave it amber.
out = ['{',
       '  "eyes" : {',
       '    "box" : [',
       '      26,',
       '      11,',
       '      44,',
       '      17',
       '    ],',
       '    "lid" : "o",',
       '    "range" : 0,',
       '    "socket" : "b"',
       '  },',
       '  "moods" : {']
for i, m in enumerate(MOODS):
    out.append(f'    "{m}" : [')
    r = rows(m)
    for j, line in enumerate(r):
        out.append(f'      "{line}"' + (',' if j < len(r) - 1 else ''))
    out.append('    ]' + (',' if i < len(MOODS) - 1 else ''))
out.append('  },')
out.append('  "name" : "perchling",')
out.append('  "palette" : {')
for i, k in enumerate(used):
    out.append(f'    "{k}" : "#%02x%02x%02x"' % PAL[k] + (',' if i < len(used) - 1 else ''))
out.append('  },')
out.append('  "scale" : 1,')

# ---------------------------------------------------------------- sequences
# Deformations picked off sheet_deform.png / crop_deform.png. wd = sq/2
# throughout: a squash that does not widen reads as the window zooming rather
# than as the creature compressing.
#
# +3.0 is the last CLEAN squash. At +3.5 the chin drops from 6px to 5, and the
# chin is one of the two bands the hippo redesign calls load-bearing. The cheek
# holds at 3px across the whole range.
SQUASH  = (3.0, 1.5)
STRETCH = (-3.0, -1.5)      # done's stretch is what puts inkTop at 0
REBOUND = (-1.5, -0.75)
REST    = (0.0, 0.0)
SETTLE  = (1.5, 0.75)       # hover's landing: the mirror of REBOUND

# Every duration is a multiple of TICK_MS = 50, or the parser quantises it and
# --validate prints a number nobody wrote.
SEQ = [
    # `done` LOOPS, so it carries its own resting beat -- here the rebound,
    # because a celebration that pauses at true rest has stopped celebrating.
    # Up, land, smaller up, land.
    ('done', 'done', [STRETCH, SQUASH, REBOUND],
     [(0, 200), (1, 100), (2, 150), (1, 100)]),
    # `error` LOOPS. Its rest beat IS moods.error -- frame 0 is the undeformed
    # build, byte-identical to the static grid by check_deform's first guard --
    # for the same reason idle's is: Reduce Motion shows that grid, and a mood
    # with one frozen resting pose and a different animated one has two.
    #
    # It separates from idle's breath by DIRECTION rather than by amplitude:
    # idle stretches UP, error squashes DOWN. At 1x that is a silhouette that
    # rises against one that sinks, which does not depend on noticing how far
    # either moved.
    #
    # The motion carries WEIGHT, not identity -- the dark cross through each eye
    # already says "error" unambiguously. All this has to do is stop the
    # highest-but-one ranked mood in the attention fold reading as dead.
    ('error', 'error', [REST, SQUASH],
     [(0, 500), (1, 1000), (1, 700)]),
    # `hover` is a BURST and the exact inverse of `tap`: a poke COMPRESSES, a
    # surprise RECOILS. It deforms `idle` for the same reason tap does, there
    # being one hover for five moods.
    #
    # It inherits tap's accepted cost in full: a burst replaces the whole
    # sprite, so hovering an errored pet swaps its cross for this face. 250ms
    # rather than tap's 300 on purpose -- a reaction nobody asked for should get
    # out of the way faster than one they did.
    #
    # Frame 0 is byte-identical to tap's frame 1. `frames` is per-sequence and
    # the format has no cross-sequence reference, so that ~10KB is unavoidable
    # rather than an oversight.
    ('hover', 'idle', [STRETCH, SETTLE],
     [(0, 100), (1, 100), (0, 50)]),
    # `idle` LOOPS and its rest beat IS moods.idle: frame 0 is the undeformed
    # build, which check_deform's first guard proves byte-identical to the
    # static grid. Reduce Motion shows that grid, and a pet whose animated rest
    # sits a pixel off its frozen rest has two resting poses for one mood.
    # 77% of the cycle is spent on it -- idle has to stay the stillest thing on
    # screen or the attention fold it anchors stops meaning anything.
    # The rest is TWO steps of 1000 because a single step's ms is capped at
    # 1000 by the parser. `steps` replaying one frame is exactly what it is for.
    ('idle', 'idle', [REST, REBOUND],
     [(0, 1000), (0, 1000), (1, 600)]),
    # `tap` is a BURST: when it expires `seq` goes nil and the mood's own grid
    # returns, so it needs no rest frame of its own. It deforms `idle` because
    # there is one tap for every mood -- poking an errored pet swaps its cross
    # for this face for 300ms, which is the accepted cost of a drawn tap over
    # the procedural hop, and the neutral face is the right one to carry.
    ('tap', 'idle', [SQUASH, STRETCH],
     [(0, 100), (1, 150), (0, 50)]),
]

out.append('  "sequences" : {')
for i, (name, mood, frames, steps) in enumerate(SEQ):
    out.append(f'    "{name}" : {{')
    out.append('      "frames" : [')
    for j, (sq, wd) in enumerate(frames):
        grid = art.build(mood, sq, wd)
        rowstrs = [''.join(c if c else '.' for c in row) for row in grid]
        out.append('        [')
        for k, line in enumerate(rowstrs):
            out.append(f'          "{line}"' + (',' if k < len(rowstrs) - 1 else ''))
        out.append('        ]' + (',' if j < len(frames) - 1 else ''))
    out.append('      ],')
    out.append('      "steps" : [')
    for j, (f, ms) in enumerate(steps):
        out.append('        [')
        out.append(f'          {f},')
        out.append(f'          {ms}')
        out.append('        ]' + (',' if j < len(steps) - 1 else ''))
    out.append('      ]')
    out.append('    }' + (',' if i < len(SEQ) - 1 else ''))
out.append('  }')
out.append('}')
text = '\n'.join(out) + '\n'
out = os.path.join(HERE, 'perchling-hippo.json')
open(out, 'w').write(text)
print(f"{out}\n{len(text)} bytes, {len(used)} inks: {''.join(used)}")
