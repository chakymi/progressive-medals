import unittest
import json
from unittest import mock
from urllib.error import HTTPError

from discover_official_maps import AUTH, CAMPAIGNS, TOTDS, MAX_OFFICIAL_BYTES, discover, fetch_official, open_json
from world_rank_publisher import OLD_UIDS, epoch


RELEASE = 1791990000
CAMPAIGN_UID = "C" * 27
TOTD_UID = "T" * 27


class DiscoveryTests(unittest.TestCase):
    def test_official_start_timestamps_not_map_upload_or_local_time(self):
        campaigns = {"campaignList": [{"startTimestamp": RELEASE, "playlist":
            [{"mapUid": CAMPAIGN_UID}, {"mapUid": next(iter(OLD_UIDS))}]}]}
        months = {"monthList": [{"days": [
            {"mapUid": TOTD_UID, "startTimestamp": RELEASE + 100},
            {"mapUid": "F" * 27, "startTimestamp": RELEASE + 200000},
        ]}]}
        maps = discover(campaigns, months, clock=lambda: RELEASE + 101)
        self.assertEqual({m["uid"]: (m["type"], epoch(m["releaseAt"])) for m in maps},
                         {CAMPAIGN_UID: ("campaign", RELEASE), TOTD_UID: ("totd", RELEASE + 100)})

    def test_duplicated_uid_between_lists_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            discover({"campaignList": [{"startTimestamp": RELEASE, "playlist": [{"mapUid": CAMPAIGN_UID}]}]},
                     {"monthList": [{"days": [{"mapUid": CAMPAIGN_UID, "startTimestamp": RELEASE}]}]},
                     clock=lambda: RELEASE + 1)

    def test_invalid_official_shapes_rejected(self):
        with self.assertRaisesRegex(ValueError, "campaign list missing"):
            discover({}, {"monthList": []})
        with self.assertRaisesRegex(ValueError, "UID"):
            discover({"campaignList": []}, {"monthList": [{"days": [{"mapUid": "../bad", "startTimestamp": RELEASE}]}]},
                     clock=lambda: RELEASE + 1)

    def test_unannounced_or_future_totd_is_not_registered(self):
        months = {"monthList": [{"days": [
            {"mapUid": "", "startTimestamp": RELEASE + 86400},
            {"mapUid": None, "startTimestamp": None},
            {"mapUid": "not-yet-valid", "startTimestamp": RELEASE + 86400},
            {"mapUid": TOTD_UID, "startTimestamp": RELEASE},
        ]}]}
        self.assertEqual([m["uid"] for m in discover({"campaignList": []}, months, clock=lambda: RELEASE + 1)], [TOTD_UID])
        with self.assertRaisesRegex(ValueError, "invalid official TOTD time type"):
            discover({"campaignList": []}, {"monthList": [{"days": [
                {"mapUid": TOTD_UID, "startTimestamp": "unknown"}]}]}, clock=lambda: RELEASE + 1)

    def test_http_error_identifies_stage_without_body_or_credentials(self):
        def denied(request, timeout):
            raise HTTPError(request.full_url, 401, "sensitive response", {}, None)
        for url, stage in ((AUTH, "authentification"), (CAMPAIGNS, "campagnes"), (TOTDS, "TOTD")):
            with self.subTest(stage=stage), self.assertRaisesRegex(ValueError, f"Nadeo HTTP 401 \\({stage}\\)") as result:
                open_json(url, {"Authorization": "private-secret"}, open_request=denied)
            self.assertNotIn("private-secret", str(result.exception))
            self.assertNotIn("sensitive response", str(result.exception))

    def test_service_auth_uses_server_login_and_live_audience(self):
        requests = []
        class Response:
            status = 200
            def __init__(self, url, body): self.url, self.body = url, body
            def __enter__(self): return self
            def __exit__(self, *_): return False
            def geturl(self): return self.url
            def read(self, limit): return json.dumps(self.body).encode()
        def opener(request, timeout):
            requests.append(request)
            if request.full_url == AUTH:
                self.assertEqual(request.get_method(), "POST")
                self.assertEqual(json.loads(request.data), {"audience": "NadeoLiveServices"})
                self.assertEqual(request.get_header("Authorization"), "Basic cG10ZXN0OnRlc3Q=")
                return Response(AUTH, {"accessToken": "test-token"})
            self.assertEqual(request.get_header("Authorization"), "nadeo_v1 t=test-token")
            if request.full_url == CAMPAIGNS: return Response(CAMPAIGNS, {"campaignList": []})
            return Response(TOTDS, {"monthList": []})
        with mock.patch.dict("os.environ", {"PM_NADEO_SERVICE_LOGIN": "pmtest",
                                            "PM_NADEO_SERVICE_PASSWORD": "test"}):
            self.assertEqual(fetch_official(open_request=opener), [])
        self.assertEqual([r.full_url for r in requests], [AUTH, CAMPAIGNS, TOTDS])

    def test_oversize_response_reports_stage_without_body(self):
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *_): return False
            def geturl(self): return TOTDS
            def read(self, limit): return b'x' * (MAX_OFFICIAL_BYTES + 1)
        with self.assertRaisesRegex(ValueError, "Nadeo réponse trop volumineuse \\(TOTD\\)"):
            open_json(TOTDS, {}, open_request=lambda *_args, **_kwargs: Response())


if __name__ == "__main__": unittest.main()
