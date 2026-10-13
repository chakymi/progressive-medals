"""Validate the artist's exact PNG sources and paths loaded by Openplanet."""

from pathlib import Path
import struct
import unittest


ASSETS = Path(__file__).resolve().parent.parent / "plugin" / "assets"


class MedalArtworkTests(unittest.TestCase):
    def test_three_readable_matching_png_medals(self):
        dimensions = set()
        for filename in ("platinum.png", "emerald.png", "diamond.png"):
            path = ASSETS / filename
            self.assertTrue(path.is_file(), filename)
            self.assertLess(path.stat().st_size, 8_000_000, filename)
            with path.open("rb") as image:
                content = image.read()
            header = content[:33]
            self.assertEqual(header[:8], b"\x89PNG\r\n\x1a\n", filename)
            self.assertEqual(header[12:16], b"IHDR", filename)
            width, height, depth, colour, *_ = struct.unpack(">IIBBBBB", header[16:29])
            self.assertTrue(32 <= width == height <= 2048, filename)
            self.assertEqual(depth, 8, filename)
            self.assertEqual(colour, 6, filename)  # RGBA, transparent outside medal
            offset = 8
            while offset < len(content):
                self.assertGreaterEqual(len(content) - offset, 12, filename)
                size = struct.unpack_from(">I", content, offset)[0]
                kind = content[offset + 4:offset + 8]
                self.assertNotIn(kind, (b"tEXt", b"iTXt", b"zTXt", b"eXIf"), filename)
                offset += size + 12
                self.assertLessEqual(offset, len(content), filename)
                if kind == b"IEND":
                    break
            self.assertEqual(offset, len(content), filename)
            dimensions.add((width, height))
        self.assertEqual(len(dimensions), 1)


if __name__ == "__main__":
    unittest.main()
