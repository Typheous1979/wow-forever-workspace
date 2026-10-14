import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import make_icon  # noqa: E402


class IconTests(unittest.TestCase):
    def test_tga_layout(self):
        rows = make_icon.render(32)
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "Icon.tga")
            make_icon.write_tga(path, rows)
            data = open(path, "rb").read()
        idlen, cmap, kind = data[0], data[1], data[2]
        w, h, bpp, desc = struct.unpack("<HHBB", data[12:18])
        self.assertEqual((idlen, cmap, kind), (0, 0, 2))     # uncompressed true-colour
        self.assertEqual((w, h, bpp, desc), (32, 32, 32, 8))  # 32-bit, 8 alpha bits, bottom-left
        self.assertEqual(len(data), 18 + 32 * 32 * 4)

    def test_shape(self):
        rows = make_icon.render(64)
        self.assertEqual(rows[0][0][3], 0, "corners are transparent")
        self.assertEqual(rows[32][32][3], 255, "the disc is opaque")
        gold = [px for row in rows for px in row if px[0] > 200 and px[1] > 140 and px[2] < 120]
        self.assertGreater(len(gold), 300, "the notes are drawn in gold")

    def test_size_is_power_of_two(self):
        for size in (32, 64):
            rows = make_icon.render(size)
            self.assertEqual((len(rows), len(rows[0])), (size, size))


if __name__ == "__main__":
    unittest.main()
