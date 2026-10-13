import json
from copy import deepcopy
from pathlib import Path
import unittest

from generate import goals_linear, publish
from publish_fall_2026 import load_roster
from rebalance_v4 import rebalance


ROOT = Path(__file__).resolve().parent.parent


class RebalanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.roster = load_roster()
        archive = ROOT / "docs/catalogue-v3.json"
        cls.old = json.loads((archive if archive.exists() else ROOT / "docs/catalogue.json").read_text(encoding="utf-8"))
        cls.evidence = json.loads((ROOT / "docs/catalogue.evidence.json").read_text(encoding="utf-8"))
        cls.next_publication = 1_791_940_000

    def test_linear_goals_are_strict_and_deterministic(self):
        self.assertEqual(goals_linear(29175, 26641), [28415, 27655, 26894])
        self.assertEqual(goals_linear(1003, 1000), [1002, 1001, 1000])
        for gap in range(3, 400):
            values = goals_linear(10000 + gap, 10000)
            self.assertEqual(values, goals_linear(10000 + gap, 10000))
            self.assertTrue(10000 <= values[2] < values[1] < values[0] < 10000 + gap)
        for author, wr in ((1002, 1000), (1000, 1000), (True, 1)):
            with self.assertRaises(ValueError):
                goals_linear(author, wr)
        with self.assertRaisesRegex(ValueError, "historical smoothstep"):
            publish({"schema": 1, "version": 4, "maps": {}}, power=1)

    def test_all_25_wr_and_evidence_remain_frozen(self):
        old = deepcopy(self.old)
        new = rebalance(old, self.evidence, self.roster, self.next_publication)
        self.assertEqual(self.old, old)
        self.assertEqual(new["version"], 4)
        self.assertEqual(new["policy"]["percent"], [30, 60, 90])
        self.assertEqual(len(new["maps"]), 28)
        for uid, source in old["maps"].items():
            item = new["maps"][uid]
            self.assertEqual(item["authorMs"], source["authorMs"])
            self.assertEqual(item["referenceWrMs"], source["referenceWrMs"])
            self.assertEqual(item["timesMs"], goals_linear(source["authorMs"], source["referenceWrMs"]))
            if not uid.startswith("DEMO-"):
                self.assertEqual(item["release"]["wrCapturedAtUtc"], source["release"]["wrCapturedAtUtc"])
                self.assertEqual(item["release"]["availableAtUtc"], source["release"]["availableAtUtc"])
                self.assertEqual(item["release"]["publishedAtUtc"], self.next_publication)

    def test_reject_tampering_and_missing_evidence(self):
        bad = deepcopy(self.old)
        bad["maps"][self.roster["maps"][0]["uid"]]["referenceWrMs"] -= 1
        with self.assertRaises(ValueError):
            rebalance(bad, self.evidence, self.roster, self.next_publication)
        missing = deepcopy(self.evidence)
        missing["captures"].pop()
        with self.assertRaises(ValueError):
            rebalance(self.old, missing, self.roster, self.next_publication)

    def test_published_version_matches_the_reviewed_rule_if_present(self):
        current = json.loads((ROOT / "docs/catalogue.json").read_text(encoding="utf-8"))
        if current["version"] == 4:
            published_at = current["maps"][self.roster["maps"][0]["uid"]]["release"]["publishedAtUtc"]
            self.assertEqual(current, rebalance(self.old, self.evidence, self.roster, published_at))
        else:
            self.assertEqual(current["version"], 3)


if __name__ == "__main__":
    unittest.main()
