#!/usr/bin/env python3
"""v6_deform -- v5_lighter plus one axis: a squash/stretch deformation.

Copied from v5_lighter.py. One change, nothing else.

The deformation is applied to the PARAMETERS, never to a finished grid. Every
mask is therefore BUILT at the deformed coordinates and shade() re-derives its
outline, light and shade bands from the new silhouette. Resampling the shaded
output instead lands those bands on notches -- the same trap recorded as "never
resample a measured curve into a lathe profile", one engine later.

Parameters, not call sites: all of this module's geometry already flows from
five tables plus a handful of literals, so deforming the tables reaches every
primitive at once. The literals are hoisted to constants below for exactly that
reason. check_deform.py guards the seam: it requires every ink to move on both
axes, which is what a table this transform forgot cannot do.

`sq` is rows of vertical compression, negative stretches; `wd` is columns of
horizontal spread per side. The vertical anchor is the FLOOR, because every
mood's ink already reaches row 99 and a creature that squashes keeps its feet
where they are. The horizontal anchor is CX.

What follows is v5_lighter's own docstring, unchanged.

v3_tilt -- the muzzle MASS carries running/waiting; error's X becomes dark ink.

Copied from v2_bigger.py. Two changes, nothing else.

CHANGE 1 -- running vs waiting through the muzzle's own outline.
    On the baseline these two are one round amber lens at two radii, and at 1x
    that is the same 2px smudge twice. So the separation moves off the eye
    entirely and onto the one feature big enough to survive a downsample: the
    whole dark muzzle BLOCK translates. running tucks it low and squares its
    corners; waiting lifts it and rounds them. Everything welded to the block
    -- nostrils, mouth groove, lower lip, the agape dot -- is now expressed as
    an offset FROM the block rather than as an absolute row, so the block moves
    as one rigid mass and the lip band keeps its thickness in every mood.

    How the five stay out of each other's way, which is the actual work here:
    the muzzle is not one channel, it is two independent ones, and each half of
    the mood set gets a different one.

      * AROUSAL rides the block's POSITION -- a rigid translation of a ~50x20
        dark mass. Only running (low) and waiting (high) ever leave the neutral
        row; idle, done and error all sit at exactly the baseline's rows.
      * VALENCE rides the mouth's CURVE INSIDE the block -- `lift`, which bends
        the groove and therefore fattens or thins the light 's' lower lip at
        the corners. Only done (+) and error (-) ever leave flat; running and
        waiting stay at the baseline's neutral lift.

    A translation of the mass and a curvature within it are measured by
    different receptors and neither overwrites the other, so the five occupy
    five distinct cells of one 3x3 grid and no pair shares one:

        block:      LOW        MID          HIGH
        curve up               done
        curve flat  running    idle         waiting
        curve down             error

CHANGE 2 -- error's cross is dark ink over amber.
    Was: swap the lens to 'x' pink [166] and cut 1px 'o' strokes. Pink on coral
    [140] is a 26-step and it dissolves on a cream desktop. Now: error keeps a
    full amber lens like every other mood and the cross is stamped in 'c' [44]
    on top -- a 159-step against the amber [203] underneath it, which is the
    largest step available anywhere on this sprite. 'x' is left unreached; see
    the ink report at the bottom of a run.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hippo import *

CX = 48

P = dict(
    # head = cranium U jaw, merged into ONE mask so shade() sees one contour
    skull=(CX, 25, 25, 21, 2.6),      # narrow above the eyes
    jowl=(CX, 42, 33, 22, 2.4),       # flares out at the snout line
    body=(CX, 76, 24, 15, 2.4),
    legs=[(30, 86, 45, 99), (51, 86, 66, 99)],

    inset=3,                          # coral rim left between muzzle and outline

    nostril_x=32,
    mouth_half=23,
    mouth_th=3,
)

# ------------------------------------------------------- CHANGE 1: the block
# The muzzle rrect, per mood: (x0, y0, x1, y1, r). The baseline's single value
# was (19, 34, 77, 57, 9) and that is exactly what idle, done and error still
# use -- the neutral row. Only running and waiting move, and they move in
# opposite directions so the pair that used to collapse now differs by the
# largest low-frequency quantity on the face.
#
# The bottom edge is the load-bearing one: it is what sets the coral chin.
# running keeps the baseline's y1=57 (chin unchanged, NOT thinner) and buys its
# "tucked" read by dropping the TOP edge instead, which is free -- the rows it
# gives up were blank muzzle. waiting raises BOTH edges, which is why its chin
# is the fattest on the sheet rather than the thinnest.
MUZZLE = {
    'idle':    (19, 34, 77, 57, 9),
    # top 40 was measured and rejected: it separates a hair harder but the
    # block stops reading as a snout and becomes a dark stripe worn across the
    # face. 39 already buys a 11-vs-5 forehead gap against waiting.
    'running': (22, 39, 74, 57, 6),   # tucked: top drops 5, sides pull in 3, corners squared
    'waiting': (19, 32, 77, 50, 9),   # lifted: whole block up, corners rounded
    'done':    (19, 34, 77, 57, 9),
    'error':   (19, 34, 77, 57, 9),
}

# everything inside the block is an OFFSET from the block, so it translates with it
MOUTH_UP = 4        # mouth groove starts this many rows above the block's bottom
NOST_DY = 5         # nostril centre this many rows below the block's top
AGAPE_DY = 1.5      # waiting's parted-lips dot, relative to the groove

# ------------------------------------------------------- CHANGE 2: the cross
CROSS_T = 2.2       # half-width of the diagonal band in the |dx +- dy| metric;
                    # ~3px of 'c' per stroke, drawn only over 'e', never over
                    # the lens's own 'o' ring and never onto coral.
                    #
                    # Swept 1.4 / 1.8 / 2.2 / 2.6 / 3.0 and looked at all five
                    # at 1x on both cards. The knob is coarser than it looks:
                    # 1.4 and 1.8 quantize to the SAME grid (284 amber px), and
                    # so do 2.2 and 2.6 (212), so there are really three
                    # settings here, not five. 1.4/1.8 leave a cross thin
                    # enough to wash out when you are not staring; 3.0 (148
                    # amber) eats the lens down to four slivers and the eye
                    # reads as a dark socket -- which is the treatment settled
                    # decision #2 spent six renders rejecting. 2.2 keeps four
                    # bright amber quadrants under a cross that survives a blur.

# ---------------------------------------------------------------- the eyes
# Untouched from v2_bigger except 'xx'. The head spans x 23..72 at the eye line
# so a lens centred at (35, 20) leaves 2-3 coral columns to the rim, a 7-column
# coral bridge between the eyes, and coral rows above the snout.
EYE = dict(
    cx=35,          # left eye centre; the right one is mirrored about CX
    cy=20,
    n=2.2,          # superellipse exponent of the lens
)

EYES = {
    # heavy lid: a wide lens with its top 40% lopped off by a straight cut.
    'sleepy': dict(rx=9.2, ry=8.0, dy=1.0, lid=0.44, glint=(-4, 0, -1, 2)),
    # focus: the full lens with a GENTLY tilted top edge. The removed pixels
    # revert to CORAL, never to shadow: this is a narrowing, not a brow ridge.
    'focus':  dict(rx=7.6, ry=8.6, dy=0.0, knit=(0.34, 6.0), glint=(-3, -1, -1, 1)),
    # expectant: the full lens, plus the ivory catchlight.
    'wide':   dict(rx=9.2, ry=8.4, dy=-0.6, glint=(-3, -4, -1, -2)),
    # closed happy arc, thick enough that shade() leaves amber inside the ring.
    'happy':  dict(rx=8.8, ry=5.4, dy=-2.6, arcth=7, glint=(-5, 1, -2, 3)),
    # CHANGED: a full amber lens -- grown to the ceiling so the four amber
    # quadrants the cross leaves behind are still bright -- crossed in dark 'c'.
    'xx':     dict(rx=9.2, ry=8.6, dy=0.0, cross=True, glint=(-6, -5, -4, -3)),
}

# the muzzle is FLAT dark: 'c' is spent only on the nostrils and the mouth,
# so those two stay the highest-contrast marks inside the dark mass.
MUZ = {'o': 'o', 'l': 's', 'b': 's', 's': 's'}

# per mood: mouth lift (+ = corners up), ear centres, limb top row
MOODS = {
    'idle':    dict(lift=1,  ears=(27, 12, 6, 5.0), limb=66, eyes='sleepy'),
    'running': dict(lift=0,  ears=(27, 8, 5, 5.5),  limb=62, eyes='focus'),
    'waiting': dict(lift=1,  ears=(27, 8, 5, 5.5),  limb=63, eyes='wide',
                    ears_r=(69, 15, 7, 4.0), limb_r=68, agape=True, nost_dy=6),
    'done':    dict(lift=5,  ears=(27, 8, 6, 5.5),  limb=62, eyes='happy'),
    # lift -4 -> -6: error gave up the 'x' colour swap, so the one channel it
    # can still spend is the lower lip's shape. A deeper droop thickens the
    # dark 'k' at the mouth corners, which is an AREA change and survives 1x.
    'error':   dict(lift=-6, ears=(27, 16, 7, 4.0), limb=69, eyes='xx'),
}


# ---------------------------------------------------------------- literals
# Hoisted out of build() and draw_nostrils so the deformation can reach them.
# Anything the transform cannot see is a feature that stays behind while the
# body moves, which is precisely what check_deform.py's second guard hunts.
LIMB_X = [(14, 32), (64, 82)]     # the two forelimb pills, x bounds
LIMB_H = 18                       # ... and their height below `limb`
LIMB_R = 8                        # ... and their corner radius
SPARK_AT = [(13, 13), (82, 13)]   # done's two sparkles, clear of the head
NOST_RIM = (4.5, 3.7)             # nostril rim radii
NOST_HOLE = (3.4, 2.8)            # ... and the dark hole inside it
AGAPE_R = (5.4, 3.2)              # waiting's parted-lips dot

# The sparkle ARMS are deliberately not deformed. They are 3px and 1px, and
# tr(3) at the largest squash this pet can take is 2.87 -- it rounds straight
# back to 3. A transform whose every output equals its input is noise.

# ------------------------------------------------------------- deformation
FLOOR = 99          # every mood's ink reaches this row; the squash anchors here
REST_TOP = 4        # idle's ink top at rest, so SPAN is the resting height
SPAN = FLOOR - REST_TOP
HALF_W = 34         # the pet spans x14..x82 about CX = 48, measured

# Captured once, at import, before anything deforms them. Every _apply() starts
# from these rather than from the current tables, so deformations never compose.
_BASE = dict(P=P, MUZZLE=MUZZLE, EYE=EYE, EYES=EYES, MOODS=MOODS,
             MOUTH_UP=MOUTH_UP, NOST_DY=NOST_DY, AGAPE_DY=AGAPE_DY,
             LIMB_X=LIMB_X, LIMB_H=LIMB_H, LIMB_R=LIMB_R, SPARK_AT=SPARK_AT,
             NOST_RIM=NOST_RIM, NOST_HOLE=NOST_HOLE, AGAPE_R=AGAPE_R)


def _vs(sq):  return (SPAN - sq) / SPAN
def _hs(wd):  return 1.0 + wd / HALF_W

def _ty(y, sq):   return FLOOR - (FLOOR - y) * _vs(sq)
def _tr(r, sq):   return r * _vs(sq)
def _tx(x, wd):   return CX + (x - CX) * _hs(wd)
def _txr(r, wd):  return r * _hs(wd)
def _iy(y, sq):   return int(round(_ty(y, sq)))
def _ix(x, wd):   return int(round(_tx(x, wd)))


def _apply(sq, wd):
    """Rewrite every parameter table at the deformed coordinates."""
    global P, MUZZLE, EYE, EYES, MOODS, MOUTH_UP, NOST_DY, AGAPE_DY
    global LIMB_X, LIMB_H, LIMB_R, SPARK_AT, NOST_RIM, NOST_HOLE, AGAPE_R
    b = _BASE

    P = dict(b['P'])
    for k in ('skull', 'jowl', 'body'):
        cx, cy, rx, ry, n = b['P'][k]
        P[k] = (_tx(cx, wd), _ty(cy, sq), _txr(rx, wd), _tr(ry, sq), n)
    P['legs'] = [(_ix(x0, wd), _iy(y0, sq), _ix(x1, wd), _iy(y1, sq))
                 for x0, y0, x1, y1 in b['P']['legs']]
    P['nostril_x'] = _ix(b['P']['nostril_x'], wd)
    P['mouth_half'] = _txr(b['P']['mouth_half'], wd)
    P['mouth_th'] = max(1, int(round(_tr(b['P']['mouth_th'], sq))))
    # `inset` is an EROSION radius, isotropic and integer, and it is the coral
    # rim that keeps the muzzle inside the head outline. Scaling it by 4% only
    # rounds back to itself; scaling it enough to matter would eat the cheeks.

    # A rounded rect's corner has to stay a corner under an anisotropic scale,
    # so its radius takes the SMALLER of the two -- the larger one bulges past
    # the shorter side and the rrect degenerates into a lozenge.
    MUZZLE = {k: (_ix(x0, wd), _iy(y0, sq), _ix(x1, wd), _iy(y1, sq),
                  min(_txr(r, wd), _tr(r, sq)))
              for k, (x0, y0, x1, y1, r) in b['MUZZLE'].items()}
    LIMB_R = min(_txr(b['LIMB_R'], wd), _tr(b['LIMB_R'], sq))

    EYE = dict(b['EYE'], cx=_ix(b['EYE']['cx'], wd), cy=_ty(b['EYE']['cy'], sq))

    EYES = {}
    for k, spec in b['EYES'].items():
        d = dict(spec)
        d['rx'] = _txr(spec['rx'], wd)
        d['ry'] = _tr(spec['ry'], sq)
        d['dy'] = _tr(spec['dy'], sq)
        if 'knit' in spec:
            # A slope is rise over run, so it takes the RATIO of the two scales.
            d['knit'] = (spec['knit'][0] * _vs(sq) / _hs(wd),
                         _tr(spec['knit'][1], sq))
        if 'arcth' in spec:
            d['arcth'] = max(1, int(round(_tr(spec['arcth'], sq))))
        if 'glint' in spec:
            x0, y0, x1, y1 = spec['glint']
            d['glint'] = (int(round(_txr(x0, wd))), int(round(_tr(y0, sq))),
                          int(round(_txr(x1, wd))), int(round(_tr(y1, sq))))
        EYES[k] = d

    MOODS = {}
    for k, spec in b['MOODS'].items():
        d = dict(spec)
        for key in ('ears', 'ears_r'):
            if spec.get(key):
                ecx, ecy, erx, ery = spec[key]
                d[key] = (_tx(ecx, wd), _ty(ecy, sq),
                          _txr(erx, wd), _tr(ery, sq))
        d['limb'] = _iy(spec['limb'], sq)
        if spec.get('limb_r'):
            d['limb_r'] = _iy(spec['limb_r'], sq)
        if 'nost_dy' in spec:
            d['nost_dy'] = _tr(spec['nost_dy'], sq)
        # `lift` is the mouth's curve depth in rows -- a vertical quantity.
        d['lift'] = spec['lift'] * _vs(sq)
        MOODS[k] = d

    MOUTH_UP = _tr(b['MOUTH_UP'], sq)
    NOST_DY = _tr(b['NOST_DY'], sq)
    AGAPE_DY = _tr(b['AGAPE_DY'], sq)
    LIMB_X = [(_ix(x0, wd), _ix(x1, wd)) for x0, x1 in b['LIMB_X']]
    LIMB_H = max(1, int(round(_tr(b['LIMB_H'], sq))))
    SPARK_AT = [(_ix(sx, wd), _iy(sy, sq)) for sx, sy in b['SPARK_AT']]
    NOST_RIM = (_txr(b['NOST_RIM'][0], wd), _tr(b['NOST_RIM'][1], sq))
    NOST_HOLE = (_txr(b['NOST_HOLE'][0], wd), _tr(b['NOST_HOLE'][1], sq))
    AGAPE_R = (_txr(b['AGAPE_R'][0], wd), _tr(b['AGAPE_R'][1], sq))


# ---------- geometry helpers ----------
def disc(cx, cy, r, n=2.0):
    return ellipse(cx + .5, cy + .5, r, r, n)


def erode(mask, r):
    offs = [(dy, dx) for dy in range(-r, r + 1) for dx in range(-r, r + 1)
            if dy * dy + dx * dx <= r * r + r]
    out = blank()
    for y in range(H):
        for x in range(W):
            if not mask[y][x]:
                continue
            for dy, dx in offs:
                yy, xx = y + dy, x + dx
                if not (0 <= yy < H and 0 <= xx < W and mask[yy][xx]):
                    break
            else:
                out[y][x] = 1
    return out


def isect(a, b):
    return [[1 if a[y][x] and b[y][x] else 0 for x in range(W)] for y in range(H)]


def arc_mask(cx, cy, rx, ry, th):
    m = blank()
    for x in range(int(round(cx - rx)), int(round(cx + rx)) + 1):
        t = (x - cx) / rx
        if abs(t) > 1:
            continue
        y0 = cy - ry * (1 - t * t) ** 0.5
        for k in range(th):
            yy = int(round(y0)) + k
            if 0 <= yy < H and 0 <= x < W:
                m[yy][x] = 1
    return m


def head_mask():
    return merge(ellipse(*P['skull']), ellipse(*P['jowl']))


def muzzle_mask(spec):
    x0, y0, x1, y1, r = spec
    return isect(rrect(x0, y0, x1, y1, r), erode(head_mask(), P['inset']))


# ---------- face parts ----------
def mouth_row(x, lift, mouth_y):
    t = min(1.0, abs(x - CX) / float(P['mouth_half']))
    return mouth_y - int(round(lift * (t ** 2.2)))


def draw_mouth(g, muz, lift, mouth_y):
    """'c' groove across the whole snout; everything under it is the lower lip."""
    th = P['mouth_th']
    for y in range(H):
        for x in range(W):
            if not muz[y][x]:
                continue
            e = mouth_row(x, lift, mouth_y)
            if e <= y < e + th:
                g[y][x] = 'c'
            elif y >= e + th:
                g[y][x] = 's'


def draw_nostrils(g, muz, ny):
    nx = P['nostril_x']
    for cx in (nx, W - 1 - nx):
        rim = ellipse(cx + .5, ny + .5, NOST_RIM[0], NOST_RIM[1], 2.2)
        hole = ellipse(cx + .5, ny + .2, NOST_HOLE[0], NOST_HOLE[1], 2.2)
        for y in range(H):
            for x in range(W):
                if muz[y][x] and rim[y][x]:
                    g[y][x] = 'o'
        for y in range(H):
            for x in range(W):
                if muz[y][x] and hole[y][x]:
                    g[y][x] = 'c'


# ---------- the eye ----------
def ink_mask(g, mask, fill):
    """Stamp a mask as `fill` wearing the 1px 'o' ring shade() derives from it."""
    sh = shade(mask)
    for y in range(H):
        for x in range(W):
            v = sh[y][x]
            if v is not None:
                g[y][x] = 'o' if v == 'o' else fill


def cut_rows_above(mask, y):
    for yy in range(0, min(H, y)):
        for x in range(W):
            mask[yy][x] = 0
    return mask


def cut_wedge(mask, cx, cy, side, slope, base):
    """Tilt the lens's top edge inward -- drawn as ABSENCE of amber, so the
    pixels revert to coral rather than to shadow."""
    for y in range(H):
        for x in range(W):
            if mask[y][x] and (y - (cy - base)) < -slope * (side * (x - cx)):
                mask[y][x] = 0
    return mask


def draw_cross(g, mask, cx, ecy, t):
    """CHANGE 2: dark 'c' over amber. Only pixels that came out 'e' are eaten,
    so the lens keeps the same 1px 'o' ring every other mood's eye has and the
    cross never reaches coral."""
    fcx, fcy = cx + .5, ecy + .5
    for y in range(H):
        for x in range(W):
            if not mask[y][x] or g[y][x] != 'e':
                continue
            dx, dy = x + .5 - fcx, y + .5 - fcy
            if abs(dx - dy) <= t or abs(dx + dy) <= t:
                g[y][x] = 'c'


def put_glint(g, s, m, cx, ecy):
    """Ivory catchlight, clipped to the eye it sits in.

    Ivory is 108 luminance steps from the coral body, against amber's 62 and the
    muzzle's 77-94: it is the ONLY ink on the sprite that out-contrasts the
    snout, which is why the muzzle held first fixation while the eyes only had
    amber to answer with. Measured, not guessed -- the two ivory tusks that
    shipped in an early draft pulled the eye to the bottom of the face by this
    exact mechanism, which is why they were cut. Pointed at the eyes it is the
    fix rather than the defect.

    Offsets are per mood because the mark has to land on lit amber: idle's lid
    eats everything above its cut line and done has no lens at all, only the
    upper limb of an arc."""
    box = s.get('glint')
    if not box:
        return
    gy = int(round(ecy))
    x0, y0, x1, y1 = box
    flat(g, isect(rrect(cx + x0, gy + y0, cx + x1, gy + y1, 1), m), 'g')


def draw_eye(g, cx, cy, kind, side):
    s = EYES[kind]
    ecy = cy + s['dy']
    if 'arcth' in s:
        m = arc_mask(cx + .5, ecy + s['ry'], s['rx'], s['ry'], s['arcth'])
        ink_mask(g, m, 'e')
        put_glint(g, s, m, cx, ecy)
        return
    m = ellipse(cx + .5, ecy + .5, s['rx'], s['ry'], EYE['n'])
    if 'lid' in s:
        top = ecy - s['ry']
        cut_rows_above(m, int(round(top + 2 * s['ry'] * s['lid'])))
    if 'knit' in s:
        cut_wedge(m, cx, ecy, side, s['knit'][0], s['knit'][1])
    ink_mask(g, m, 'e')
    if s.get('cross'):
        draw_cross(g, m, cx, ecy, CROSS_T)
    put_glint(g, s, m, cx, ecy)


# ---------- build ----------
def build(mood, sq=0.0, wd=0.0):
    """`sq` rows of vertical compression (negative stretches), `wd` columns of
    horizontal spread per side. The tables are restored on the way out, so a
    caller can never leave the module deformed for the next one."""
    _apply(float(sq), float(wd))
    try:
        return _build(mood)
    finally:
        _apply(0.0, 0.0)


def _build(mood):
    m = MOODS[mood]
    head = head_mask()
    body = ellipse(*P['body'])
    legs = [rrect(*l, 0) for l in P['legs']]
    core = merge(head, body, *legs)

    base = shade(core)
    for spec in (m['ears'], m.get('ears_r') or (W - 1 - m['ears'][0],) + m['ears'][1:]):
        ecx, ecy, erx, ery = spec
        stamp(base, shade(ellipse(ecx + .5, ecy + .5, erx, ery, 2.0)))
    stamp(base, shade(core))                   # ears sit BEHIND the head

    spec = MUZZLE[mood]
    muz = muzzle_mask(spec)
    mouth_y = spec[3] - MOUTH_UP               # the groove rides the block
    nost_y = spec[1] + m.get('nost_dy', NOST_DY)
    stamp(base, [[MUZ[v] if v else None for v in row] for row in shade(muz)])
    draw_mouth(base, muz, m['lift'], mouth_y)
    if m.get('agape'):                         # waiting: lips parted
        # clipped to the muzzle ERODED by one, not to the muzzle: the lifted
        # block puts the groove closer to its own bottom edge, and a 'c' dot
        # allowed to reach that edge eats the muzzle's 'o' outline and hangs
        # off the chin like a drip.
        flat(base, isect(erode(muz, 1),
                         ellipse(CX + .5, mouth_y + AGAPE_DY,
                                 AGAPE_R[0], AGAPE_R[1], 2.4)), 'c')
    draw_nostrils(base, muz, nost_y)

    for i, (x0, x1) in enumerate(LIMB_X):
        top = m['limb_r'] if (i == 1 and m.get('limb_r')) else m['limb']
        stamp(base, shade(rrect(x0, top, x1, top + LIMB_H, LIMB_R)))

    ex, ey = EYE['cx'], EYE['cy']
    draw_eye(base, ex, ey, m['eyes'], -1)
    draw_eye(base, W - 1 - ex, ey, m['eyes'], +1)
    if mood == 'done':                         # two sparkles clear of the head
        for sx, sy in SPARK_AT:
            star = merge(rrect(sx, sy - 3, sx, sy + 3, 0),
                         rrect(sx - 3, sy, sx + 3, sy, 0),
                         rrect(sx - 1, sy - 1, sx + 1, sy + 1, 0))
            stamp(base, [[('o' if v == 'o' else 'g') if v else None for v in row]
                         for row in shade(star)])
    return base


# ---------- preview ----------
DARK, LIGHT = (24, 24, 27), (245, 240, 232)
ALL = ['idle', 'running', 'waiting', 'done', 'error']


def blit(canvas, grid, ox, oy, scale, bg):
    for y, row in enumerate(grid):
        for x, ch in enumerate(row):
            col = bg if ch is None else PAL[ch]
            for sy in range(scale):
                for sx in range(scale):
                    canvas[oy + y * scale + sy][ox + x * scale + sx] = col + (255,)


# ---------- measurement ----------
def last_row(mask, x):
    for y in range(H - 1, -1, -1):
        if mask[y][x]:
            return y
    return None


def chin_px(mood):
    """Coral rows at the centre column between the muzzle mask's bottom edge and
    the head outline's bottom edge. This is the band settled decision #1 calls
    load-bearing, measured rather than eyeballed."""
    head = head_mask()
    muz = muzzle_mask(MUZZLE[mood])
    return last_row(head, CX) - last_row(muz, CX)


def cheek_px(mood):
    """Narrowest coral strip left of the muzzle, over every row the muzzle
    occupies. The other settled half of decision #1."""
    head = head_mask()
    muz = muzzle_mask(MUZZLE[mood])
    worst = 99
    for y in range(H):
        xs = [x for x in range(W) if muz[y][x]]
        if not xs:
            continue
        hs = [x for x in range(W) if head[y][x]]
        worst = min(worst, xs[0] - hs[0], hs[-1] - xs[-1])
    return worst


def gap_px(mood):
    """Coral rows between the lowest eye pixel and the muzzle's top edge."""
    g = build(mood)
    muz = muzzle_mask(MUZZLE[mood])
    eye_bottom = max((y for y in range(H) for x in range(W)
                      if g[y][x] in ('e', 'g')), default=0)
    muz_top = min(y for y in range(H) for x in range(W) if muz[y][x])
    return muz_top - eye_bottom - 1


def count(g, inks):
    return sum(1 for r in g for c in r if c in inks)


if __name__ == '__main__':
    grids = {m: build(m) for m in ALL}
    PAD, S = 6, 3
    cw = PAD + len(ALL) * (W * S + PAD)
    chh = PAD + (H * S + PAD) * 2 + (H + PAD) * 2 + PAD
    canvas = [[(40, 40, 44, 255)] * cw for _ in range(chh)]
    # the 1x rows are butted together rather than spread under the 3x columns:
    # the whole point of them is comparing neighbours, and 200px of grey between
    # two sprites is 200px of forgetting what the last one looked like.
    onex_ox = PAD + (cw - PAD - len(ALL) * (W + PAD)) // 2
    for i, m in enumerate(ALL):
        ox = PAD + i * (W * S + PAD)
        blit(canvas, grids[m], ox, PAD, S, DARK)
        blit(canvas, grids[m], ox, PAD + H * S + PAD, S, LIGHT)
        ox1 = onex_ox + i * (W + PAD)
        blit(canvas, grids[m], ox1, PAD + 2 * (H * S + PAD), 1, DARK)
        blit(canvas, grids[m], ox1, PAD + 2 * (H * S + PAD) + H + PAD, 1, LIGHT)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'v5_lighter.png')
    png(out, canvas, 1)

    inks = sorted({c for g in grids.values() for r in g for c in r if c})
    print('inks reached : %s   (%d of 9)' % (''.join(inks), len(inks)))
    for k in 'oslbkcegx':
        if k not in inks:
            print('  UNREACHED  : %r' % k)
    print()
    print('%-8s %5s %5s %5s | %6s %6s %6s %6s'
          % ('mood', 'chin', 'cheek', 'gap', 'amber', 'dark', 'crossC', 'muzTop'))
    for m in ALL:
        g = grids[m]
        print('%-8s %5d %5d %5d | %6d %6d %6d %6d'
              % (m, chin_px(m), cheek_px(m), gap_px(m),
                 count(g, ('e',)), count(g, ('k',)),
                 count(g, ('c',)), MUZZLE[m][1]))
