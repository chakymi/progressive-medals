import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent


class MenuRosterTests(unittest.TestCase):
    def test_menu_order_matches_verified_publication(self):
        source = json.loads((ROOT / "tools/fall-2026-roster.json").read_text(encoding="utf-8"))
        menu = json.loads((ROOT / "plugin/catalog/fall-2026-order.json").read_text(encoding="utf-8"))
        published = json.loads((ROOT / "docs/catalogue.json").read_text(encoding="utf-8"))
        self.assertEqual(menu["campaign"], "Fall 2026")
        self.assertEqual(menu["mapUids"], [item["uid"] for item in source["maps"]])
        self.assertEqual(len(set(menu["mapUids"])), 25)
        for number, uid in enumerate(menu["mapUids"], 1):
            self.assertEqual(source["maps"][number - 1]["number"], number)
            self.assertEqual(published["maps"][uid]["authorMs"], source["maps"][number - 1]["authorMs"])


if __name__ == "__main__":
    unittest.main()
