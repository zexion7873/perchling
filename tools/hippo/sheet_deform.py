#!/usr/bin/env python3
"""Contact sheet for the squash/stretch axis: one row per mood, one column per
deformation, rendered at 3x on dark and at 1x on both grounds.

The 1x block is the one that decides anything. Everything this pet has learned
about mood legibility was learned there -- an amber slit and an amber arc are
the same 2px smudge at shipping size, and a boundary one design cell thick is
sub-pixel. A deformation that only reads at 3x has not been seen.
"""
import sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from hippo import PAL, png
import v6_deform

W, H = 96, 100
MOODS = ['idle', 'running', 'waiting', 'done', 'error']
# (sq, wd): sq is rows of vertical compression, wd columns of spread per side.
# Paired so volume is roughly conserved -- a squash that does not widen reads
# as the window zooming rather than as the creature compressing.
STEPS = [(-3.0, -1.0), (-1.5, -0.5), (0.0, 0.0), (2.0, 1.0), (4.0, 2.0)]

DARK, LIGHT, BG = (24, 24, 27), (245, 240, 232), (40, 40, 44)
IVORY = (255, 244, 233)
S, GAP, BLOCKGAP, GUTTER, MARGIN = 3, 8, 26, 18, 12
LABEL_W = 74

BLOCK3_W = len(STEPS) * (W * S) + (len(STEPS) - 1) * GAP
BLOCK1_W = len(STEPS) * W + (len(STEPS) - 1) * GAP
SHEET_W = MARGIN + LABEL_W + BLOCK3_W + BLOCKGAP + BLOCK1_W + BLOCKGAP + BLOCK1_W + MARGIN
ROW_H = H * S
SHEET_H = MARGIN + len(MOODS) * (ROW_H + GUTTER) + MARGIN


def blit(canvas, grid, ox, oy, scale, bg):
    for y, row in enumerate(grid):
        for x, ch in enumerate(row):
            px = (bg if ch is None else PAL[ch]) + (255,)
            for sy in range(scale):
                line = canvas[oy + y * scale + sy]
                for sx in range(scale):
                    line[ox + x * scale + sx] = px


def box(canvas, x0, y0, w, h, col):
    px = col + (255,)
    for y in range(y0, y0 + h):
        if 0 <= y < len(canvas):
            line = canvas[y]
            for x in range(x0, x0 + w):
                if 0 <= x < len(line):
                    line[x] = px


def main():
    canvas = [[BG + (255,)] * SHEET_W for _ in range(SHEET_H)]
    for r, mood in enumerate(MOODS):
        oy = MARGIN + r * (ROW_H + GUTTER)
        box(canvas, MARGIN, oy + ROW_H // 2 - 4, 9, 9, IVORY)
        x = MARGIN + LABEL_W
        for sq, wd in STEPS:
            blit(canvas, v6_deform.build(mood, sq, wd), x, oy, S, DARK)
            x += W * S + GAP
        x = x - GAP + BLOCKGAP
        for sq, wd in STEPS:
            blit(canvas, v6_deform.build(mood, sq, wd), x, oy, 1, DARK)
            x += W + GAP
        x = x - GAP + BLOCKGAP
        for sq, wd in STEPS:
            blit(canvas, v6_deform.build(mood, sq, wd), x, oy, 1, LIGHT)
            x += W + GAP
        print(f"  {mood:8} " + "  ".join(f"sq{sq:+.1f}/wd{wd:+.1f}" for sq, wd in STEPS))

    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'sheet_deform.png')
    png(out, canvas)
    print(f"\n{out}  {SHEET_W}x{SHEET_H}")
    print("rows: " + ", ".join(MOODS))
    print("columns, left to right: " + ", ".join(f"sq{s:+.1f}" for s, _ in STEPS))
    print("blocks: 3x on dark | 1x on dark | 1x on light")


if __name__ == '__main__':
    main()
