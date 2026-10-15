from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

from build_plugin import FILES, PLUGIN, package


class PluginPackageTests(unittest.TestCase):
    def test_unsigned_package_contains_exact_sources_and_art(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "ProgressiveMedals.op"
            package(target)
            with ZipFile(target) as archive:
                self.assertEqual(set(archive.namelist()), set(FILES))
                self.assertIsNone(archive.testzip())
                self.assertIn(b'version = "0.3.0"', archive.read("info.toml"))
                for relative in FILES:
                    self.assertEqual(archive.read(relative), (PLUGIN / relative).read_bytes(), relative)
            self.assertLess(target.stat().st_size, 25_000_000)


if __name__ == "__main__":
    unittest.main()
