#!/usr/bin/env python3
"""Parametric hippo generator + manifest rasterizer for perchling previews."""
import json, zlib, struct, math, sys

W, H = 96, 100

PAL = {
    'o': (116, 55, 37),    # outline
    's': (190, 89, 55),    # shade
    'b': (218, 119, 86),   # body (Claude coral)
    'l': (234, 162, 134),  # light
    'k': (84, 55, 42),     # casing  -> muzzle dark
    'c': (58, 40, 32),     # screen  -> nostril / mouth dark
    'e': (255, 193, 105),  # eye amber
    'g': (255, 244, 233),  # glyph ivory
    'x': (247, 143, 143),  # errorX
}

BAND = 3

def blank():
    return [[0] * W for _ in range(H)]

def ellipse(cx, cy, rx, ry, n=2.0):
    m = blank()
    for y in range(H):
        for x in range(W):
            dx = (x + 0.5 - cx) / rx
            dy = (y + 0.5 - cy) / ry
            if abs(dx) ** n + abs(dy) ** n <= 1.0:
                m[y][x] = 1
    return m

def rrect(x0, y0, x1, y1, r):
    m = blank()
    for y in range(max(0, y0), min(H, y1 + 1)):
        for x in range(max(0, x0), min(W, x1 + 1)):
            cx = min(max(x, x0 + r), x1 - r)
            cy = min(max(y, y0 + r), y1 - r)
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r + r:
                m[y][x] = 1
    return m

def merge(*parts):
    m = blank()
    for p in parts:
        for y in range(H):
            for x in range(W):
                if p[y][x]:
                    m[y][x] = 1
    return m

def shade(mass):
    def solid(y, x):
        return 0 <= y < H and 0 <= x < W and mass[y][x] == 1
    out = [[None] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if not mass[y][x]:
                continue
            if not (solid(y-1, x) and solid(y+1, x) and solid(y, x-1) and solid(y, x+1)):
                out[y][x] = 'o'
            elif not solid(y - BAND, x) or not solid(y, x - BAND):
                out[y][x] = 'l'
            elif not solid(y + BAND, x) or not solid(y, x + BAND):
                out[y][x] = 's'
            else:
                out[y][x] = 'b'
    return out

def stamp(dst, src):
    for y in range(H):
        for x in range(W):
            if src[y][x] is not None:
                dst[y][x] = src[y][x]

def flat(dst, mask, ink):
    for y in range(H):
        for x in range(W):
            if mask[y][x]:
                dst[y][x] = ink

# ---------- PNG ----------
def png(path, rows, scale=1):
    h = len(rows) * scale
    w = len(rows[0]) * scale
    raw = bytearray()
    for row in rows:
        line = bytearray()
        for px in row:
            r, g, b, a = px
            line += bytes((r, g, b, a)) * scale
        for _ in range(scale):
            raw += b'\x00' + line
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
    out = b'\x89PNG\r\n\x1a\n'
    out += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
    out += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    out += chunk(b'IEND', b'')
    open(path, 'wb').write(out)

def to_rgba(grid, bg=(24, 24, 27)):
    rows = []
    for y in range(len(grid)):
        row = []
        for x in range(len(grid[0])):
            ch = grid[y][x]
            if ch is None or ch in ('.', '0'):
                row.append((bg[0], bg[1], bg[2], 255))
            else:
                r, g, b = PAL[ch]
                row.append((r, g, b, 255))
        rows.append(row)
    return rows
