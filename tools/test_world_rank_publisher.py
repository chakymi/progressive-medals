import json
import tempfile
from pathlib import Path
import unittest

from world_rank_publisher import (OLD_UIDS, Store, capture, count_players,
                                  epoch, fall_migration_maps, filter_discovery_since, iso, run, validate_manifest)
from publish_fall_2026 import NADEO_ACCOUNT
from generate import publish


UID = "Z" * 27
RELEASE = "2026-10-15T19:00:00Z"
MAP = {"uid": UID, "name": "Track of the Day", "type": "totd", "releaseAt": RELEASE}


def supplier(url, *, players=6000, author=25500, error=False, ties=False):
    if error: raise OSError("offline")
    if "/api/map/" in url:
        return {"mapUid": UID, "name": MAP["name"], "mapType": "TrackMania\\TM_Race",
                "author": NADEO_ACCOUNT, "authorScore": author, "isPlayable": True}
    rank = int(url.split("offset=")[1]) + 1 if "offset=" in url else 1
    times = {1: 19000, 100: 19800, 200: 20000, 500: 21000, 1000: 22000, 2500: 23000, 5000: 24000}
    if ties: times[200] = times[1000] = 22000
    return {"lockedLeaderboard": False, "playercount": players,
            "tops": [{"position": rank, "time": times[rank], "score": times[rank],
                      "player": {"id": f"account-{rank}"}}] if rank <= players else []}


class FakeStore:
    def __init__(self, observed_status):
        self.status = observed_status
        self.calls = []
        self.published = False
        self.registered = False

    def rpc(self, name, **values):
        self.calls.append((name, values))
        if name == "register":
            self.registered = True
            self.kind = values["kind"]
        if name == "observe": return {"status": self.status}
        if name == "publish":
            if self.published: return False
            self.published = True
            return True
        return None

    def states(self, uids, kind="campaign"):
        if not self.registered or not uids or self.kind != kind: return []
        return [{"map_uid": UID, "status": "published" if self.published else "waiting_initial_delay",
                 "retry_at": None}]

    def pending(self, kind="campaign"):
        if self.registered and not self.published and self.kind == kind:
            return [{"map_uid": UID, "map_type": self.kind, "status": "waiting_initial_delay", "retry_at": None}]
        return []


class WorldRankTests(unittest.TestCase):
    def test_manifest_rejects_historical_uid_and_invalid_utc(self):
        with self.assertRaisesRegex(ValueError, "already published"):
            validate_manifest({"maps": [{**MAP, "uid": next(iter(OLD_UIDS))}]})
        with self.assertRaisesRegex(ValueError, "UTC"):
            validate_manifest({"maps": [{**MAP, "releaseAt": "2026-10-15T19:00:00+02:00"}]})

    def test_old_formula_cannot_generate_new_catalogues(self):
        with self.assertRaisesRegex(ValueError, "historical only"):
            publish({"version": 5, "maps": {}})

    def test_fall_migration_is_explicit_25_exact_uid_exception(self):
        maps = fall_migration_maps()
        self.assertEqual(len(maps), 25)
        self.assertEqual({m["uid"] for m in maps}, OLD_UIDS)
        self.assertTrue(all(m["type"] == "campaign" and
                            m["releaseAt"] == "2026-10-01T15:00:00Z" for m in maps))
        self.assertEqual(maps[20]["name"], "Egypt 2026")
        with self.assertRaisesRegex(ValueError, "already published Fall 2026 UID"):
            validate_manifest({"maps": maps})
        self.assertEqual(len(validate_manifest({"maps": maps}, allow_historical=True)), 25)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            validate_manifest({"maps": maps + [maps[0]]}, allow_historical=True)

    def test_supabase_state_reads_are_bounded_and_paginated(self):
        store = Store("https://example.supabase.co", "sb_secret_fake", open_request=lambda *_a, **_kw: None)
        store.request = lambda endpoint: calls.append(endpoint) or []
        calls = []
        self.assertEqual(store.states([str(n).zfill(27) for n in range(101)]), [])
        self.assertEqual(len(calls), 2)
        self.assertIn("limit=100", calls[0])
        self.assertTrue(calls[0].startswith("pm_revised_medals?"))
        self.assertEqual(store.states([UID], kind="totd"), [])
        self.assertTrue(calls[-1].startswith("pm_totd_medals?"))

    def test_store_keeps_campaign_v7_and_totd_v8_separate(self):
        store = Store("https://example.supabase.co", "sb_secret_fake", open_request=lambda *_a, **_kw: None)
        calls = []
        store.request = lambda endpoint, payload=None: calls.append((endpoint, payload)) or ([] if payload is None else None)
        store.states([UID], "campaign")
        store.states([UID], "totd")
        store.pending("campaign")
        store.pending("totd")
        store.rpc("observe", policy=7, uid=UID, players=2500)
        store.rpc("observe", policy=8, uid=UID, players=2500)
        self.assertTrue(calls[0][0].startswith("pm_revised_medals?"))
        self.assertTrue(calls[1][0].startswith("pm_totd_medals?"))
        self.assertTrue(calls[2][0].startswith("pm_revised_medals?"))
        self.assertTrue(calls[3][0].startswith("pm_totd_medals?"))
        self.assertEqual([calls[4][0], calls[5][0]], ["rpc/pm7_observe", "rpc/pm8_observe"])

    def test_discovery_requires_explicit_future_activation_boundary(self):
        maps = [{"releaseAt": "2026-09-30T17:00:00Z"},
                {"releaseAt": "2026-10-15T18:00:00Z"},
                {"releaseAt": "2026-10-15T18:00:01Z"}]
        with self.assertRaisesRegex(ValueError, "required"):
            filter_discovery_since(maps, "")
        self.assertEqual(filter_discovery_since(maps, "2026-10-15T18:00:00Z"), maps[1:])
        with self.assertRaisesRegex(ValueError, "UTC"):
            filter_discovery_since(maps, "2026-10-15T20:00:00+02:00")

    def test_exact_ranks_ignore_author_and_keep_ties(self):
        times, evidence, captured = capture(UID, lambda url: supplier(url, author=10000, ties=True),
                                             clock=lambda: epoch(RELEASE) + 4 * 3600, pause=lambda _: None)
        self.assertEqual([times[k] for k in ("platinum", "emerald", "diamond")], [23000, 22000, 22000])
        self.assertEqual([evidence[k]["position"] for k in ("platinum", "emerald", "diamond")], [2500, 1000, 200])
        self.assertEqual(captured, epoch(RELEASE) + 4 * 3600)

    def test_missing_2500th_blocks_new_publication(self):
        with self.assertRaises(ValueError):
            count_players(UID, lambda url: supplier(url, players=6000) if "offset" not in url else supplier(url, players=2499))

    def test_totd_requires_exact_2500th_and_not_5000th(self):
        self.assertEqual(count_players(UID, lambda url: supplier(url, players=2500), kind="totd"), 2500)
        self.assertEqual(count_players(UID, lambda url: supplier(url, players=2499), kind="totd"), 2499)
        with self.assertRaises(ValueError):
            count_players(UID, lambda url: supplier(url, players=2500) if "offset" not in url else supplier(url, players=2000),
                          kind="totd")
        goals, evidence, _ = capture(UID, lambda url: supplier(url, players=2500, author=18000),
                                      kind="totd", pause=lambda _: None)
        self.assertEqual([goals[k] for k in ("platinum", "emerald", "diamond")], [22000, 21000, 19800])
        self.assertEqual([evidence[k]["position"] for k in ("platinum", "emerald", "diamond")], [1000, 500, 100])

    def test_2499_players_never_enter_capture(self):
        self.assertEqual(count_players(UID, lambda url: supplier(url, players=2499)), 2499)
        store = FakeStore("waiting_for_players")
        run([MAP], store, fetch=lambda url: supplier(url, players=2499), pause=lambda _: None)
        self.assertEqual([name for name, _ in store.calls], ["register", "observe"])

    def test_popular_totd_and_campaign_call_publish_at_initial_deadline(self):
        for kind in ("totd", "campaign"):
            with self.subTest(kind=kind):
                store = FakeStore("ready_to_capture")
                run([{**MAP, "type": kind}], store, fetch=supplier, clock=lambda: epoch(RELEASE) + 8 * 86400,
                    pause=lambda _: None)
                self.assertEqual([name for name, _ in store.calls], ["register", "observe", "publish"])
                published = store.calls[-1][1]
                expected = [22000, 21000, 19800] if kind == "totd" else [23000, 22000, 20000]
                self.assertEqual([published[k] for k in ("platinum", "emerald", "diamond")], expected)
                self.assertEqual(published["captured"], iso(epoch(RELEASE) + 8 * 86400))
                run([{**MAP, "type": kind}], store, fetch=supplier, pause=lambda _: None)
                self.assertEqual(sum(name == "publish" for name, _ in store.calls), 1)

    def test_late_threshold_persists_without_premature_capture(self):
        for state in ("waiting_extra_hour", "waiting_initial_delay", "waiting_for_players"):
            with self.subTest(state=state):
                store = FakeStore(state)
                run([MAP], store, fetch=supplier, pause=lambda _: None)
                self.assertFalse(store.published)
        # The due timestamp is held in PostgreSQL, never inferred from local process uptime.

    def test_api_failure_marks_retry_without_partial_goals(self):
        store = FakeStore("ready_to_capture")
        def partial(url):
            if "offset=499" in url: raise OSError("supplier unavailable")
            return supplier(url)
        run([MAP], store, fetch=partial, pause=lambda _: None)
        self.assertEqual([name for name, _ in store.calls], ["register", "observe", "retry"])
        self.assertFalse(store.published)

    def test_duplicate_players_at_different_ranks_rejected(self):
        def duplicate(url):
            result = supplier(url)
            if "offset=199" in url: result["tops"][0]["player"]["id"] = "account-1000"
            return result
        with self.assertRaisesRegex(ValueError, "unique-player"):
            capture(UID, duplicate, pause=lambda _: None)

    def test_supabase_requires_server_key_and_fixed_https_origin(self):
        with self.assertRaises(ValueError): Store("https://evil.example", "sb_secret_fake")
        with self.assertRaises(ValueError): Store("https://example.supabase.co", "sb_publishable_fake")
        self.assertEqual(Store("https://example.supabase.co", "sb_secret_fake").base,
                         "https://example.supabase.co/rest/v1/")

    def test_sql_defines_immutable_atomic_publications_and_private_writes(self):
        sql = (Path(__file__).parent.parent / "supabase/migrations/202610150001_world_rank_medals.sql").read_text(encoding="utf-8")
        for statement in ("for update", "pm_complete_publication", "before update or delete",
                          "grant execute on function public.pm_public_catalog() to anon, authenticated, service_role",
                          "revoke all on public.map_medals from public, anon, authenticated",
                          "and diamond_ms <= emerald_ms and emerald_ms <= platinum_ms"):
            self.assertIn(statement, sql)


if __name__ == "__main__":
    unittest.main()
