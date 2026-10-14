"""Draw MusicForever's icon: a gold beamed eighth-note pair on a dark-blue disc.

  python tools/wowf/cli.py make-icon [--out PATH] [--preview PNG] [--size 64]

Original art, drawn with plain geometry (anti-aliased by supersampling), written
as an uncompressed 32-bit RGBA TGA with bottom-left origin: the format WoW reads
from addon folders (BlizzThreatPlates-Forever ships the same kind of file).
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
    p.add_argument("--out", help="TGA path (default MusicForever/Media/Icon.tga)")
    p.add_argument("--preview", help="also write a PNG preview here")
    p.add_argument("--size", type=int, default=64, choices=[32, 64, 128, 256])
    a = p.parse_args(argv)
    out = a.out or os.path.join(config.load()["_root"], "MusicForever", "Media", "Icon.tga")
    rows = render(a.size)
    write_tga(out, rows)
    print(f"wrote {out} ({a.size}x{a.size})")
    if a.preview:
        write_png(a.preview, rows)
        print(f"wrote {a.preview}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
