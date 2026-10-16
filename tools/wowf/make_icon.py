"""Draw the workspace addons' icons from plain geometry.

  python tools/wowf/cli.py make-icon [--design note|coin] [--out PATH] [--preview PNG] [--size 64]

Designs (each defaults to its addon's Media/Icon.tga):
  note  MusicForever: a gold beamed eighth-note pair on a dark-blue disc (the default)
  coin  BuffettForever: a stack of gold coins and a rising chart arrow on an emerald disc

Original art, drawn with plain geometry (anti-aliased by supersampling), written
as an uncompressed 32-bit RGBA TGA with bottom-left origin: the format WoW reads
from addon folders (BlizzThreatPlates-Forever ships the same kind of file).
A new design: add a render_<name>(size) that returns rows like render(), and an
entry in DESIGNS. Keep the family look: disc, gold rim, 60% drop shadow.
"""
import argparse
import math
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config  # noqa: E402

SS = 4  # supersamples per axis

# Geometry in a 64-unit design space (x right, y down).
DISC_R, RIM_IN = 30.0, 28.2
HEADS = [(22.0, 45.0), (43.0, 41.0)]   # note-head centres
HEAD_A, HEAD_B, HEAD_ROT = 6.6, 4.7, math.radians(-22)
STEM_W = 3.0
BEAM = [(25.6, 15.5), (48.6, 11.5), (48.6, 18.5), (25.6, 22.5)]   # top-left, top-right, bottom-right, bottom-left
SHADOW = (1.3, 1.5)

BG_IN, BG_OUT = (46, 84, 160), (10, 20, 52)
RIM = (214, 168, 64)
GOLD_TOP, GOLD_BOTTOM = (255, 224, 110), (214, 146, 36)


def _in_ellipse(x, y, cx, cy):
    dx, dy = x - cx, y - cy
    c, s = math.cos(HEAD_ROT), math.sin(HEAD_ROT)
    u, v = dx * c + dy * s, -dx * s + dy * c
    return (u / HEAD_A) ** 2 + (v / HEAD_B) ** 2 <= 1.0


def _in_poly(x, y, pts):
    sign = 0
    for i in range(len(pts)):
        (x1, y1), (x2, y2) = pts[i], pts[(i + 1) % len(pts)]
        cross = (x2 - x1) * (y - y1) - (y2 - y1) * (x - x1)
        if cross != 0:
            if sign == 0:
                sign = 1 if cross > 0 else -1
            elif (cross > 0) != (sign > 0):
                return False
    return True


def _stem(cx, cy):
    # right edge of the head up to the beam
    x1 = cx + HEAD_A * math.cos(HEAD_ROT) - STEM_W + 0.4
    return x1, x1 + STEM_W, cy


def _beam_top(x):
    (x1, y1), (x2, y2) = BEAM[0], BEAM[1]
    return y1 + (y2 - y1) * (x - x1) / (x2 - x1)


def in_notes(x, y):
    for cx, cy in HEADS:
        if _in_ellipse(x, y, cx, cy):
            return True
        x1, x2, bottom = _stem(cx, cy)
        if x1 <= x <= x2 and _beam_top(x) + 1.0 <= y <= bottom:   # stems end inside the beam
            return True
    return _in_poly(x, y, BEAM)


def _mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def _over(dst, src, alpha):
    """Composite colour src with coverage alpha over dst (r, g, b, a), all floats 0..1 alpha."""
    r, g, b, a = dst
    out_a = alpha + a * (1 - alpha)
    if out_a <= 0:
        return (0.0, 0.0, 0.0, 0.0)
    f = lambda s, d: (s * alpha + d * a * (1 - alpha)) / out_a  # noqa: E731
    return (f(src[0], r), f(src[1], g), f(src[2], b), out_a)


def render(size=64):
    """Return rows (top to bottom) of (r, g, b, a) byte tuples."""
    scale = 64.0 / size
    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            disc = rim = shadow = notes = 0
            for sy in range(SS):
                for sx in range(SS):
                    x = (px + (sx + 0.5) / SS) * scale
                    y = (py + (sy + 0.5) / SS) * scale
                    d = math.hypot(x - 32, y - 32)
                    if d <= DISC_R:
                        disc += 1
                        if d >= RIM_IN:
                            rim += 1
                        if in_notes(x, y):
                            notes += 1
                        elif in_notes(x - SHADOW[0], y - SHADOW[1]):
                            shadow += 1
            n = SS * SS
            cx, cy = (px + 0.5) * scale, (py + 0.5) * scale
            t = min(1.0, math.hypot(cx - 26, cy - 24) / 36.0)   # light from the upper left
            pixel = (0.0, 0.0, 0.0, 0.0)
            pixel = _over(pixel, _mix(BG_IN, BG_OUT, t), disc / n)
            pixel = _over(pixel, RIM, rim / n)
            pixel = _over(pixel, (0, 0, 0), 0.6 * shadow / n)
            gold = _mix(GOLD_TOP, GOLD_BOTTOM, min(1.0, max(0.0, (cy - 10) / 44.0)))
            pixel = _over(pixel, gold, notes / n)
            r, g, b, a = pixel
            row.append((round(r), round(g), round(b), round(a * 255)))
        rows.append(row)
    return rows


# ---------------------------------------------------------------- coin design (BuffettForever)

COIN_BG_IN, COIN_BG_OUT = (34, 128, 84), (5, 38, 24)
COIN_A, COIN_B, COIN_T = 12.0, 4.5, 3.5                   # face radii and edge thickness
COINS = [(25.0, 44.0), (25.0, 39.4), (25.0, 34.8)]       # face centres, bottom coin first
COIN_FACE_TOP, COIN_FACE_BOTTOM = (255, 232, 128), (236, 172, 52)
COIN_FACE_RING = (206, 144, 34)
COIN_SIDE_LIGHT, COIN_SIDE_DARK = (226, 160, 44), (150, 96, 20)
COIN_SEAM = (112, 70, 14)
ARROW = [(31.0, 31.5), (38.0, 24.5), (42.5, 28.0), (49.5, 19.5)]   # rising polyline
ARROW_W = 4.4
ARROW_TIP_LEN, ARROW_HALF_W = 7.5, 6.0
ARROW_TOP, ARROW_BOTTOM = (255, 250, 214), (255, 214, 92)


def _in_ellipse_r(x, y, cx, cy, a, b, rot=0.0):
    """Value of ((u/a)^2 + (v/b)^2) for the ellipse rotated by rot; <= 1 means inside."""
    dx, dy = x - cx, y - cy
    c, s = math.cos(rot), math.sin(rot)
    u, v = dx * c + dy * s, -dx * s + dy * c
    return (u / a) ** 2 + (v / b) ** 2


def _near_segment(x, y, p, q, r):
    (x1, y1), (x2, y2) = p, q
    dx, dy = x2 - x1, y2 - y1
    t = max(0.0, min(1.0, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)))
    return math.hypot(x - (x1 + t * dx), y - (y1 + t * dy)) <= r


def _arrow_head():
    (x2, y2), (x3, y3) = ARROW[-2], ARROW[-1]
    d = math.hypot(x3 - x2, y3 - y2)
    ux, uy = (x3 - x2) / d, (y3 - y2) / d
    px, py = -uy, ux
    tip = (x3 + ux * ARROW_TIP_LEN * 0.6, y3 + uy * ARROW_TIP_LEN * 0.6)
    bx, by = x3 - ux * ARROW_TIP_LEN * 0.4, y3 - uy * ARROW_TIP_LEN * 0.4
    return [tip, (bx + px * ARROW_HALF_W, by + py * ARROW_HALF_W), (bx - px * ARROW_HALF_W, by - py * ARROW_HALF_W)]


ARROW_HEAD = _arrow_head()


def _in_arrow(x, y):
    if _in_poly(x, y, ARROW_HEAD):
        return True
    return any(_near_segment(x, y, ARROW[i], ARROW[i + 1], ARROW_W / 2) for i in range(len(ARROW) - 1))


def _coin_colour(x, y, cx, cy):
    face = _in_ellipse_r(x, y, cx, cy, COIN_A, COIN_B)
    if face <= 1.0:
        if face >= 0.6:
            return COIN_FACE_RING
        return _mix(COIN_FACE_TOP, COIN_FACE_BOTTOM, min(1.0, max(0.0, (y - (cy - COIN_B)) / (2 * COIN_B))))
    bottom = _in_ellipse_r(x, y, cx, cy + COIN_T, COIN_A, COIN_B)
    in_band = cy <= y <= cy + COIN_T and abs(x - cx) <= COIN_A
    if in_band or (y >= cy + COIN_T and bottom <= 1.0):
        if y >= cy + COIN_T and bottom >= 0.72:
            return COIN_SEAM
        u = (x - cx) / COIN_A
        return _mix(COIN_SIDE_DARK, COIN_SIDE_LIGHT, 1.0 - u * u)
    return None


def coin_foreground(x, y):
    """Colour of the coin-and-arrow art at (x, y), or None for background."""
    if _in_arrow(x, y):
        return _mix(ARROW_TOP, ARROW_BOTTOM, min(1.0, max(0.0, (y - 14) / 22.0)))
    for cx, cy in reversed(COINS):          # the top coin hides the ones below it
        colour = _coin_colour(x, y, cx, cy)
        if colour:
            return colour
    return None


def render_coin(size=64):
    """BuffettForever's icon. Returns rows (top to bottom) of (r, g, b, a) byte tuples."""
    scale = 64.0 / size
    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            disc = rim = shadow = fg_n = 0
            fg = [0.0, 0.0, 0.0]
            for sy in range(SS):
                for sx in range(SS):
                    x = (px + (sx + 0.5) / SS) * scale
                    y = (py + (sy + 0.5) / SS) * scale
                    d = math.hypot(x - 32, y - 32)
                    if d <= DISC_R:
                        disc += 1
                        if d >= RIM_IN:
                            rim += 1
                            continue
                        colour = coin_foreground(x, y)
                        if colour:
                            fg_n += 1
                            fg[0] += colour[0]; fg[1] += colour[1]; fg[2] += colour[2]
                        elif coin_foreground(x - SHADOW[0], y - SHADOW[1]):
                            shadow += 1
            n = SS * SS
            cx, cy = (px + 0.5) * scale, (py + 0.5) * scale
            t = min(1.0, math.hypot(cx - 26, cy - 24) / 36.0)   # light from the upper left
            pixel = (0.0, 0.0, 0.0, 0.0)
            pixel = _over(pixel, _mix(COIN_BG_IN, COIN_BG_OUT, t), disc / n)
            pixel = _over(pixel, RIM, rim / n)
            pixel = _over(pixel, (0, 0, 0), 0.6 * shadow / n)
            if fg_n:
                pixel = _over(pixel, (fg[0] / fg_n, fg[1] / fg_n, fg[2] / fg_n), fg_n / n)
            r, g, b, a = pixel
            row.append((round(r), round(g), round(b), round(a * 255)))
        rows.append(row)
    return rows


# design -> (renderer, addon folder whose Media/Icon.tga it draws)
DESIGNS = {
    "note": (render, "MusicForever"),
    "coin": (render_coin, "BuffettForever"),
}


def write_tga(path, rows):
    h, w = len(rows), len(rows[0])
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8)
    body = bytearray()
    for row in reversed(rows):            # bottom-left origin
        for r, g, b, a in row:
            body += bytes((b, g, r, a))   # BGRA
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb") as f:
        f.write(header + bytes(body))


def write_png(path, rows):
    h, w = len(rows), len(rows[0])
    raw = b"".join(b"\0" + bytes(c for px in row for c in px) for row in rows)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def main(argv):
    p = argparse.ArgumentParser(prog="wowf make-icon")
    p.add_argument("--design", default="note", choices=sorted(DESIGNS), help="which icon to draw (default note)")
    p.add_argument("--out", help="TGA path (default <design's addon>/Media/Icon.tga; always pass it with --size 512)")
    p.add_argument("--preview", help="also write a PNG preview here")
    p.add_argument("--size", type=int, default=64, choices=[32, 64, 128, 256, 512])
    a = p.parse_args(argv)
    renderer, addon = DESIGNS[a.design]
    out = a.out or os.path.join(config.load()["_root"], addon, "Media", "Icon.tga")
    rows = renderer(a.size)
    write_tga(out, rows)
    print(f"wrote {out} ({a.size}x{a.size})")
    if a.preview:
        write_png(a.preview, rows)
        print(f"wrote {a.preview}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
