import tempfile
from pathlib import Path
import unittest
from urllib.error import HTTPError

from generate import publish
from publish_fall_2026 import NADEO_ACCOUNT, collect, fetch_json, load_roster, write_new


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.roster = load_roster()
        self.ready = self.roster["availableAtUtc"]
        self.uids = {m["uid"]: m for m in self.roster["maps"]}

    def fetch(self, url):
        uid = url.split("/map/")[-1].split("?")[0]
        item = self.uids[uid]
        if "/leaderboard/" in url:
            return {"lockedLeaderboard": False, "tops": [{"position": 1, "time": item["authorMs"] - 100, "score": item["authorMs"] - 100}]}
        return {"mapUid": uid, "author": NADEO_ACCOUNT, "authorScore": item["authorMs"],
                "name": f"Fall 2026 - {item['number']:02d}", "isPlayable": True, "mapType": "TrackMania\\TM_Race"}

    def test_25_maps_and_no_premature_fetch(self):
        self.assertEqual(len(self.uids), 25)
        self.assertEqual(self.roster["availableAtUtc"], self.roster["launchAtUtc"] + 3600)
        def fail_fetch(_):
            self.fail("no network call is allowed before the snapshot deadline")
        with self.assertRaisesRegex(ValueError, "too early"):
            collect(self.roster, capture=True, now=lambda: self.ready - 1, fetch=fail_fetch)

    def test_automated_batch_is_atomic_and_deterministic(self):
        source, evidence = collect(self.roster, capture=True, now=lambda: self.ready,
                                   fetch=self.fetch, pause=lambda _: None)
        self.assertEqual(len(evidence), 25)
        self.assertEqual(len(source["maps"]), 28)
        self.assertTrue(all(x["wrCapturedAtUtc"] >= self.ready for x in evidence))
        self.assertEqual(publish(source, now_utc=self.ready), publish(source, now_utc=self.ready))
        catalogue = publish(source, now_utc=self.ready)
        self.assertEqual(catalogue["version"], 3)
        self.assertEqual(len(catalogue["maps"]), 28)
        self.assertTrue(all(len(m["timesMs"]) == 3 for m in catalogue["maps"].values()))

    def test_bad_author_or_missing_wr_aborts_entire_batch(self):
        def wrong_author(url):
            info = self.fetch(url)
            if url.endswith(self.roster["maps"][12]["uid"]):
                info["authorScore"] += 1
            return info
        with self.assertRaisesRegex(ValueError, "map info mismatch"):
            collect(self.roster, capture=True, now=lambda: self.ready, fetch=wrong_author, pause=lambda _: None)
        def missing_wr(url):
            info = self.fetch(url)
            if "/leaderboard/" in url and self.roster["maps"][24]["uid"] in url:
                info["tops"] = []
            return info
        with self.assertRaisesRegex(ValueError, "missing verified WR"):
            collect(self.roster, capture=True, now=lambda: self.ready, fetch=missing_wr, pause=lambda _: None)

    def test_existing_catalogue_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalogue.json"
            write_new(path, {"version": 2})
            with self.assertRaises(FileExistsError):
                write_new(path, {"version": 3})
            self.assertIn('"version": 2', path.read_text(encoding="utf-8"))

    def test_rate_limit_retry_is_bounded_and_respects_retry_after(self):
        url = "https://trackmania.io/api/map/RnjnOu0fwna8i3hjnRT1Wnuxqz2"
        attempts = []
        delays = []
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *_): return False
            def geturl(self): return url
            def read(self, limit): return b'{"mapUid":"valid"}'
        def limited(request, timeout):
            attempts.append(request.full_url)
            if len(attempts) == 1:
                raise HTTPError(url, 429, "limit", {"Retry-After": "45"}, None)
            return Response()
        self.assertEqual(fetch_json(url, open_request=limited, pause=delays.append), {"mapUid": "valid"})
        self.assertEqual(len(attempts), 2)
        self.assertEqual(delays, [45])

    def test_persistent_limit_does_not_generate_catalogue(self):
        url = "https://trackmania.io/api/map/RnjnOu0fwna8i3hjnRT1Wnuxqz2"
        calls = []
        def limited(request, timeout):
            calls.append(request.full_url)
            raise HTTPError(url, 429, "limit", {"Retry-After": "1"}, None)
        with self.assertRaisesRegex(ValueError, "429"):
            fetch_json(url, open_request=limited, pause=lambda _: None)
        self.assertEqual(len(calls), 3)


if __name__ == "__main__":
    unittest.main()
