import unittest

from check_official_fall_roster import official_start
from world_rank_publisher import OLD_UIDS


class OfficialFallCheckTests(unittest.TestCase):
    def test_official_start_matches_exact_historical_25_uid_set(self):
        released = 1790809200
        response = {"campaignList": [{"name": "Fall 2026", "startTimestamp": released,
                                      "playlist": [{"mapUid": uid} for uid in sorted(OLD_UIDS)]}]}
        self.assertEqual(official_start(response, now=lambda: released + 604801), released)
        response["campaignList"][0]["playlist"][0]["mapUid"] = "X" * 27
        with self.assertRaisesRegex(ValueError, "UIDs do not match"):
            official_start(response, now=lambda: released + 604801)

    def test_seven_day_deadline_is_not_backdated(self):
        released = 1790809200
        response = {"campaignList": [{"name": "Fall 2026", "startTimestamp": released,
                                      "playlist": [{"mapUid": uid} for uid in sorted(OLD_UIDS)]}]}
        with self.assertRaisesRegex(ValueError, "seven-day"):
            official_start(response, now=lambda: released + 604799)


if __name__ == "__main__": unittest.main()
