import json
from pathlib import Path
import unittest

from generate import COUNT, DELAYS, goals, publish


BASE = Path(__file__).resolve().parent.parent


class GeneratorTests(unittest.TestCase):
    def test_tight_gap_and_constraints(self):
        self.assertEqual(COUNT, 3)
        self.assertEqual(goals(1003, 1000), [1002, 1001, 1000])
        for gap in range(3, 400):
            for power in range(1, 5):
                values = goals(10000 + gap, 10000, power)
                self.assertEqual(values, goals(10000 + gap, 10000, power))
                self.assertEqual(len(set(values)), 3)
                self.assertTrue(all(10000 <= x < 10000 + gap for x in values))
                self.assertTrue(all(a > b for a, b in zip(values, values[1:])))

    def test_reject_impossible_and_invalid(self):
        for author, wr in [(1002, 1000), (100, 100), (100, 101), (True, 1), (86_400_001, 1)]:
            with self.assertRaises(ValueError):
                goals(author, wr)
        with self.assertRaises(ValueError):
            goals(1000, 500, 0)

    def test_bundled_catalog_is_exact_published_output(self):
        source = json.loads((BASE / "tools/demo-source.json").read_text(encoding="utf-8"))
        published = json.loads((BASE / "plugin/catalog/catalog-v2.json").read_text(encoding="utf-8"))
        self.assertEqual(published, publish(source))
        self.assertEqual(published["schema"], 1)
        self.assertEqual(published["version"], 2)
        self.assertTrue(all(len(item["timesMs"]) == 3 for item in published["maps"].values()))
        self.assertTrue(set(published["maps"]).issubset(set(source["maps"])))

    def test_old_ten_medal_demo_is_preserved_as_version_one(self):
        source = json.loads((BASE / "tools/demo-source.json").read_text(encoding="utf-8"))
        source["version"] = 1
        old = json.loads((BASE / "plugin/catalog/catalog-v1.json").read_text(encoding="utf-8"))
        self.assertEqual(publish(source), old)

    def test_release_schedules_and_common_launch(self):
        anchor = 1_800_000_000
        for kind, delay in DELAYS.items():
            release = {"kind": kind, "anchorAtUtc": anchor,
                       "wrCapturedAtUtc": anchor + delay, "publishedAtUtc": anchor + delay}
            source = {"schema": 2, "version": 3, "maps": {
                "real-map-UID": {"name": "Carte", "authorMs": 1000, "referenceWrMs": 800, "release": release}
            }}
            if kind == "launchCampaign":
                source["launchAtUtc"] = anchor
            published = publish(source, now_utc=anchor + delay)
            self.assertEqual(published["maps"]["real-map-UID"]["release"]["availableAtUtc"], anchor + delay)
            self.assertEqual(published, publish(source, now_utc=anchor + delay))
            with self.assertRaises(ValueError):
                publish(source, now_utc=anchor + delay - 1)
            release["wrCapturedAtUtc"] -= 1
            with self.assertRaises(ValueError):
                publish(source, now_utc=anchor + delay)
            release["wrCapturedAtUtc"] += 1
            release["publishedAtUtc"] -= 1
            with self.assertRaises(ValueError):
                publish(source, now_utc=anchor + delay)
            if kind == "launchCampaign":
                release["publishedAtUtc"] += 1
                source["launchAtUtc"] += 1
                with self.assertRaises(ValueError):
                    publish(source, now_utc=anchor + delay)

    def test_no_unscheduled_real_goals_or_milliseconds_timestamps(self):
        entry = {"name": "Carte", "authorMs": 1000, "referenceWrMs": 800}
        with self.assertRaises(ValueError):
            publish({"version": 3, "maps": {"real-map-UID": entry}})
        with self.assertRaises(ValueError):
            publish({"schema": 2, "version": 3, "maps": {"real-map-UID": entry}})
        entry["release"] = {"kind": "totd", "anchorAtUtc": 1_800_000_000_000,
                            "wrCapturedAtUtc": 1_800_003_600, "publishedAtUtc": 1_800_003_600}
        with self.assertRaises(ValueError):
            publish({"schema": 2, "version": 3, "maps": {"real-map-UID": entry}}, now_utc=1_800_003_600)


if __name__ == "__main__":
    unittest.main()
