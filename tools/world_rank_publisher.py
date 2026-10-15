"""Publisher for FUTURE maps only. Never imports or rewrites the frozen Fall 2026 v4.

Requires the isolated SQL migration, SUPABASE_URL and SUPABASE_SECRET_KEY in the
publisher's server environment. --manifest supplies independently verified
official UIDs and release times; no map is discovered from a player's machine.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import time
from urllib.error import HTTPError
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener, urlopen

from publish_fall_2026 import NADEO_ACCOUNT, fetch_json


UID = re.compile(r"[A-Za-z0-9_]{20,40}\Z")
SOURCE = "trackmania.io/world-map-leaderboard"
RANKS = {"platinum": 5000, "emerald": 1000, "diamond": 200, "wr": 1}
MAX_BODY = 524_288
OLD_UIDS = {m["uid"] for m in json.loads((Path(__file__).parent / "fall-2026-roster.json").read_text(encoding="utf-8"))["maps"]}


def epoch(value):
    if type(value) is not str or not value.endswith("Z"):
        raise ValueError("releaseAt must be explicit UTC ISO-8601")
    try:
        date = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("invalid UTC releaseAt") from exc
    return int(date.timestamp())


def iso(value):
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace("+00:00", "Z")


def validate_manifest(data):
    if type(data) is not dict or set(data) != {"maps"} or type(data["maps"]) is not list or len(data["maps"]) > 100:
        raise ValueError("manifest must contain <=100 verified maps")
    seen = set()
    for m in data["maps"]:
        if type(m) is not dict or set(m) != {"uid", "name", "type", "releaseAt"}:
            raise ValueError("map fields mismatch")
        uid = m["uid"]
        if type(uid) is not str or not UID.fullmatch(uid) or uid in seen or uid in OLD_UIDS:
            raise ValueError("invalid, duplicate or already published Fall 2026 UID")
        seen.add(uid)
        if type(m["name"]) is not str or not 1 <= len(m["name"]) <= 160 or m["type"] not in ("campaign", "totd"):
            raise ValueError("map name/type invalid")
        when = epoch(m["releaseAt"])
        if not 1609459200 <= when <= int(time.time()) + 60:
            raise ValueError("release time not verified")
    return data["maps"]


def filter_discovery_since(maps, start_utc):
    """Activation boundary: historical TOTDs are never backfilled implicitly."""
    if not start_utc:
        raise ValueError("PM_WORLD_RANK_START_UTC required before automatic discovery")
    start = epoch(start_utc)
    if not 1609459200 <= start <= 4102444800:
        raise ValueError("invalid UTC activation date")
    return [item for item in maps if epoch(item["releaseAt"]) >= start]


def verify_map(m, fetch=fetch_json):
    info = fetch(f"https://trackmania.io/api/map/{m['uid']}")
    if (info.get("mapUid") != m["uid"] or info.get("name") != m["name"] or
            info.get("mapType") != "TrackMania\\TM_Race" or info.get("isPlayable") is not True or
            (m["type"] == "campaign" and info.get("author") != NADEO_ACCOUNT)):
        raise ValueError("map UID/name/type mismatch")
    # The public map timestamp is the upload time, NOT necessarily the official
    # release. The manifest's releaseAt must be confirmed against an official schedule.
    return info


def verify_rank(data, rank, seen):
    if (type(data) is not dict or data.get("lockedLeaderboard") is not False or
            type(data.get("playercount")) is not int or data["playercount"] < 5000 or
            data["playercount"] < rank or type(data.get("tops")) is not list or len(data["tops"]) != 1):
        raise ValueError("world leaderboard incomplete")
    top = data["tops"][0]
    if (type(top) is not dict or type(top.get("position")) is not int or top["position"] != rank or
            type(top.get("score")) is not int or type(top.get("time")) is not int or
            top["score"] != top["time"] or not 1 <= top["time"] <= 86400000 or
            type(top.get("player")) is not dict or type(top["player"].get("id")) is not str or
            top["player"]["id"] in seen):
        raise ValueError("rank/unique-player/time mismatch")
    seen.add(top["player"]["id"])
    return top["time"]


def leaderboard(uid, rank, fetch=fetch_json):
    return fetch(f"https://trackmania.io/api/leaderboard/map/{uid}?length=1&offset={rank - 1}")


def capture(uid, fetch=fetch_json, clock=time.time, pause=time.sleep):
    """Independent 1st/200th/1000th/5000th world records; no AT/WR formula."""
    seen = set()
    times = {}
    evidence = {}
    for label, rank in RANKS.items():
        if times: pause(2.5)
        data = leaderboard(uid, rank, fetch)
        times[label] = verify_rank(data, rank, seen)
        evidence[label] = {"position": rank, "playerCount": data["playercount"],
                           "observedAtUtc": iso(int(clock())),
                           "url": f"https://trackmania.io/api/leaderboard/map/{uid}?length=1&offset={rank - 1}"}
    if not times["wr"] <= times["diamond"] <= times["emerald"] <= times["platinum"]:
        raise ValueError("incoherent world records")
    return times, evidence, int(clock())


def count_players(uid, fetch=fetch_json):
    data = fetch(f"https://trackmania.io/api/leaderboard/map/{uid}?length=1")
    if (type(data) is not dict or data.get("lockedLeaderboard") is not False or
            type(data.get("playercount")) is not int or data["playercount"] < 0):
        raise ValueError("player count unavailable")
    count = data["playercount"]
    if count >= 5000:
        verify_rank(leaderboard(uid, 5000, fetch), 5000, set())
    return count


class Store:
    def __init__(self, url, key, *, open_request=None):
        parts = urlsplit(url)
        if (parts.scheme != "https" or not re.fullmatch(r"[a-z0-9-]+\.supabase\.co", parts.hostname or "") or
                parts.path not in ("", "/") or parts.username or parts.password or parts.query or parts.fragment):
            raise ValueError("only a Supabase HTTPS project URL is allowed")
        if not (key.startswith("sb_secret_") or key.startswith("eyJ")):
            raise ValueError("server-only Supabase secret missing or invalid")
        self.base = url.rstrip("/") + "/rest/v1/"
        self.key = key
        class NoRedirect(HTTPRedirectHandler):
            def redirect_request(self, request, fp, code, message, headers, new_url):
                return None  # Never forward a server key, including on 30x.
        self.open_request = open_request or build_opener(NoRedirect).open

    def request(self, endpoint, payload=None):
        if not (endpoint.startswith("rpc/pm_") or endpoint.startswith("map_medals?") or
                endpoint.startswith("map_medal_publications?")):
            raise ValueError("unapproved Supabase operation")
        body = json.dumps(payload).encode() if payload is not None else None
        headers = {"apikey": self.key, "Accept": "application/json", "Content-Type": "application/json"}
        if self.key.startswith("eyJ"):
            headers["Authorization"] = "Bearer " + self.key
        req = Request(self.base + endpoint, data=body, headers=headers, method="POST" if body is not None else "GET")
        try:
            with self.open_request(req, timeout=12) as result:
                content = result.read(MAX_BODY + 1)
                if result.status not in (200, 201, 204) or len(content) > MAX_BODY:
                    raise ValueError("Supabase response invalid")
                return json.loads(content) if content else None
        except HTTPError as exc:
            code = exc.code
            exc.close()
            raise ValueError(f"Supabase HTTP {code}; no public goals changed") from exc

    def rpc(self, name, **params):
        if name not in ("register", "observe", "retry", "publish"):
            raise ValueError("unknown publisher operation")
        return self.request("rpc/pm_" + name, params)

    def states(self, uids):
        if not uids: return []
        if len(uids) > 100 or any(not UID.fullmatch(uid) for uid in uids):
            raise ValueError("invalid manifest UID filter")
        names = ",".join(uids)
        return self.request("map_medals?select=map_uid,status,resume_status,eligible_at,capture_due_at,retry_at" +
                            "&map_uid=in.%28" + quote(names, safe=",") + "%29&limit=100")

    def pending(self):
        # Old low-traffic cards remain eligible even after their TOTD month
        # disappears from discovery. Rotate the oldest ten checks per cycle.
        current = quote(iso(int(time.time())), safe="")
        return self.request("map_medals?select=map_uid,status,retry_at,checked_at&status=neq.published" +
                            "&or=%28status.neq.retry_pending,retry_at.lte." + current + "%29" +
                            "&order=checked_at.asc.nullsfirst&limit=10")


def run(maps, store, *, fetch=fetch_json, clock=time.time, pause=time.sleep):
    states = {m["map_uid"]: m for m in store.states([m["uid"] for m in maps])}
    for m in maps:
        uid = m["uid"]
        state = states.get(uid)
        if state is not None: continue
        try:
            verify_map(m, fetch)
            store.rpc("register", uid=uid, title=m["name"], kind=m["type"], released=m["releaseAt"])
        except Exception as exc:
            print(f"{uid}: registration deferred ({type(exc).__name__})")
            continue
        pause(2.5)
    for state in store.pending():
        uid = state["map_uid"]
        if not UID.fullmatch(uid): raise ValueError("invalid UID in persistent queue")
        try:
            players = count_players(uid, fetch)
            status = store.rpc("observe", uid=uid, players=players)["status"]
            print(f"{uid}: {status} ({players} players)")
            if status != "ready_to_capture": continue
            times, evidence, captured = capture(uid, fetch, clock, pause)
            if min(x["playerCount"] for x in evidence.values()) < 5000:
                raise ValueError("player count dropped before capture")
            published = store.rpc("publish", uid=uid, platinum=times["platinum"], emerald=times["emerald"],
                                  diamond=times["diamond"], wr=times["wr"], captured=iso(captured),
                                  source=SOURCE, evidence=evidence)
            print(f"{uid}: {'published' if published else 'already published'} at {iso(captured)}")
        except Exception as exc:
            # Never log response bodies, account identifiers or server credentials.
            print(f"{uid}: retry pending ({type(exc).__name__})")
            store.rpc("retry", uid=uid, reason=type(exc).__name__)
        pause(2.5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--discover", action="store_true", help="discover official maps via server-only Nadeo service account")
    args = parser.parse_args()
    maps = validate_manifest(json.loads(args.manifest.read_text(encoding="utf-8")))
    store = Store(os.environ.get("SUPABASE_URL", ""), os.environ.get("SUPABASE_SECRET_KEY", ""))
    if args.discover:
        from discover_official_maps import fetch_official
        start_utc = os.environ.get("PM_WORLD_RANK_START_UTC", "")
        if not start_utc:
            parser.error("PM_WORLD_RANK_START_UTC is required before automatic discovery; no historical backfill")
        filter_discovery_since([], start_utc)  # Fail before contacting Nadeo.
        found = filter_discovery_since(fetch_official(), start_utc)
        existing = {row["map_uid"] for row in store.states([m["uid"] for m in found])}
        used = {m["uid"] for m in maps}
        for m in found:
            if m["uid"] in used: continue
            if m["uid"] in existing:
                # Name is only used by pm_register; existing persistent rows do
                # not need a new map lookup or a second name check.
                m["name"] = "(existing)"
            else:
                info = fetch_json(f"https://trackmania.io/api/map/{m['uid']}")
                m["name"] = info.get("name", "")
            maps.append(m)
            used.add(m["uid"])
        validate_manifest({"maps": maps})
    run(maps, store)


if __name__ == "__main__":
    main()
