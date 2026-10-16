"""Publisher for future maps plus the explicitly requested Fall 2026 migration.

Requires the isolated SQL migration, SUPABASE_URL and SUPABASE_SECRET_KEY in the
publisher's server environment. --manifest supplies independently verified
official UIDs and release times; no map is discovered from a player's machine.
The immutable historical v4 file is never rewritten, even when a v5 map wins.
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

from publish_fall_2026 import NADEO_ACCOUNT, fetch_json, load_roster


UID = re.compile(r"[A-Za-z0-9_]{20,40}\Z")
SOURCE = "trackmania.io/world-map-leaderboard"
RANKS_BY_TYPE = {
    "campaign": {"platinum": 2500, "emerald": 1000, "diamond": 200, "wr": 1},
    "totd": {"platinum": 1000, "emerald": 500, "diamond": 100, "wr": 1},
}
# The v5 evidence verifier must always describe the archived 5,000th-rank goals.
RANKS = {"platinum": 5000, "emerald": 1000, "diamond": 200, "wr": 1}
REQUIRED_PLAYERS = {"campaign": 2500, "totd": 2500}  # A TOTD still needs 2,500 players for stable sampling.
MAX_BODY = 524_288
OLD_UIDS = {m["uid"] for m in json.loads((Path(__file__).parent / "fall-2026-roster.json").read_text(encoding="utf-8"))["maps"]}
# Nadeo official campaign v2, verified against all 25 UIDs on 2026-10-15.
# Do not use the historical v4 exception's unrelated launchAtUtc.
FALL_OFFICIAL_OPEN = "2026-10-01T15:00:00Z"


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


def validate_manifest(data, *, allow_historical=False, max_maps=100):
    if type(data) is not dict or set(data) != {"maps"} or type(data["maps"]) is not list or len(data["maps"]) > max_maps:
        raise ValueError("manifest contains too many maps")
    seen = set()
    for m in data["maps"]:
        if type(m) is not dict or set(m) != {"uid", "name", "type", "releaseAt"}:
            raise ValueError("map fields mismatch")
        uid = m["uid"]
        if type(uid) is not str or not UID.fullmatch(uid) or uid in seen or (uid in OLD_UIDS and not allow_historical):
            raise ValueError("invalid, duplicate or already published Fall 2026 UID")
        seen.add(uid)
        if type(m["name"]) is not str or not 1 <= len(m["name"]) <= 160 or m["type"] not in ("campaign", "totd"):
            raise ValueError("map name/type invalid")
        when = epoch(m["releaseAt"])
        if not 1609459200 <= when <= int(time.time()) + 60:
            raise ValueError("release time not verified")
    return data["maps"]


def fall_migration_maps():
    """The ONLY permitted legacy UIDs; their published v4 stays archived."""
    roster = load_roster()
    legacy = json.loads((Path(__file__).parent.parent / "docs/catalogue.json").read_text(encoding="utf-8"))
    if type(legacy) is not dict or legacy.get("schema") != 2 or legacy.get("version") != 4 or type(legacy.get("maps")) is not dict:
        raise ValueError("frozen Fall 2026 v4 source unavailable")
    if epoch(FALL_OFFICIAL_OPEN) + 604800 > time.time():
        raise ValueError("Fall 2026 official J+7 is not over")
    maps = []
    for item in roster["maps"]:
        published = legacy["maps"].get(item["uid"])
        if (type(published) is not dict or published.get("authorMs") != item["authorMs"] or
                type(published.get("name")) is not str or not 1 <= len(published["name"]) <= 160):
            raise ValueError("frozen Fall 2026 UID/author/name mismatch")
        maps.append({"uid": item["uid"], "name": published["name"], "type": "campaign",
                     "releaseAt": FALL_OFFICIAL_OPEN})
    if {m["uid"] for m in maps} != OLD_UIDS or len(maps) != 25:
        raise ValueError("historical UID roster mismatch")
    return maps


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


def verify_rank(data, rank, seen, required_players=5000):
    if (type(data) is not dict or data.get("lockedLeaderboard") is not False or
            type(data.get("playercount")) is not int or data["playercount"] < required_players or
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


def capture(uid, fetch=fetch_json, clock=time.time, pause=time.sleep, *, kind="campaign"):
    """Four exact world positions selected by map type; no AT/WR formula."""
    ranks = RANKS_BY_TYPE[kind]
    seen = set()
    times = {}
    evidence = {}
    for label, rank in ranks.items():
        if times: pause(2.5)
        data = leaderboard(uid, rank, fetch)
        times[label] = verify_rank(data, rank, seen, REQUIRED_PLAYERS[kind])
        evidence[label] = {"position": rank, "playerCount": data["playercount"],
                           "observedAtUtc": iso(int(clock())),
                           "url": f"https://trackmania.io/api/leaderboard/map/{uid}?length=1&offset={rank - 1}"}
    if not times["wr"] <= times["diamond"] <= times["emerald"] <= times["platinum"]:
        raise ValueError("incoherent world records")
    return times, evidence, int(clock())


def count_players(uid, fetch=fetch_json, *, kind="campaign"):
    minimum = REQUIRED_PLAYERS[kind]
    data = fetch(f"https://trackmania.io/api/leaderboard/map/{uid}?length=1")
    if (type(data) is not dict or data.get("lockedLeaderboard") is not False or
            type(data.get("playercount")) is not int or data["playercount"] < 0):
        raise ValueError("player count unavailable")
    count = data["playercount"]
    if count >= minimum:
        verify_rank(leaderboard(uid, minimum, fetch), minimum, set(), minimum)
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
        if not (endpoint.startswith("rpc/pm7_") or endpoint.startswith("rpc/pm8_") or
                endpoint.startswith("rpc/pm_public_catalog") or
                endpoint.startswith("map_medals?") or endpoint.startswith("map_medal_publications?") or
                endpoint.startswith("pm_revised_medals?") or endpoint.startswith("pm_revised_medal_publications?") or
                endpoint.startswith("pm_totd_medals?") or endpoint.startswith("pm_totd_medal_publications?")):
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

    def rpc(self, name, *, policy, **params):
        if name not in ("register", "observe", "retry", "publish"):
            raise ValueError("unknown publisher operation")
        if policy not in (7, 8): raise ValueError("unsupported publisher policy")
        return self.request("rpc/pm" + str(policy) + "_" + name, params)

    def states(self, uids, kind="campaign"):
        if not uids: return []
        if len(uids) > 250 or any(not UID.fullmatch(uid) for uid in uids):
            raise ValueError("invalid manifest UID filter")
        rows = []
        table = "pm_totd_medals" if kind == "totd" else "pm_revised_medals"
        for offset in range(0, len(uids), 100):
            names = ",".join(uids[offset:offset + 100])
            page = self.request(table + "?select=map_uid,status,resume_status,eligible_at,capture_due_at,retry_at" +
                                "&map_uid=in.%28" + quote(names, safe=",") + "%29&limit=100")
            if type(page) is not list or len(page) > 100:
                raise ValueError("invalid Supabase map state page")
            rows.extend(page)
        return rows

    def pending(self, kind="campaign"):
        # Old low-traffic cards remain eligible even after their TOTD month
        # disappears from discovery. Rotate the oldest ten checks per cycle.
        current = quote(iso(int(time.time())), safe="")
        table = "pm_totd_medals" if kind == "totd" else "pm_revised_medals"
        return self.request(table + "?select=map_uid,map_type,status,retry_at,checked_at&status=neq.published" +
                            "&or=%28status.neq.retry_pending,retry_at.lte." + current + "%29" +
                            "&order=checked_at.asc.nullsfirst&limit=10")


def run(maps, store, *, fetch=fetch_json, clock=time.time, pause=time.sleep):
    for kind, policy in (("campaign", 7), ("totd", 8)):
        selected = [m for m in maps if m["type"] == kind]
        states = {m["map_uid"]: m for m in store.states([m["uid"] for m in selected], kind)}
        for m in selected:
            uid = m["uid"]
            if uid in states: continue
            try:
                verify_map(m, fetch)
                store.rpc("register", policy=policy, uid=uid, title=m["name"], kind=kind, released=m["releaseAt"])
            except Exception as exc:
                print(f"{uid}: registration deferred ({type(exc).__name__})")
                continue
            pause(2.5)
        for state in store.pending(kind):
            uid = state["map_uid"]
            if not UID.fullmatch(uid) or state["map_type"] != kind:
                raise ValueError("invalid map in persistent queue")
            try:
                players = count_players(uid, fetch, kind=kind)
                status = store.rpc("observe", policy=policy, uid=uid, players=players)["status"]
                print(f"{uid}: {status} ({players} players)")
                if status != "ready_to_capture": continue
                times, evidence, captured = capture(uid, fetch, clock, pause, kind=kind)
                if min(x["playerCount"] for x in evidence.values()) < REQUIRED_PLAYERS[kind]:
                    raise ValueError("player count dropped before capture")
                published = store.rpc("publish", policy=policy, uid=uid, platinum=times["platinum"],
                                      emerald=times["emerald"], diamond=times["diamond"], wr=times["wr"],
                                      captured=iso(captured), source=SOURCE, evidence=evidence)
                print(f"{uid}: {'published' if published else 'already published'} at {iso(captured)}")
            except Exception as exc:
                print(f"{uid}: retry pending ({type(exc).__name__})")
                store.rpc("retry", policy=policy, uid=uid, reason=type(exc).__name__)
            pause(2.5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--discover", action="store_true", help="discover official maps via server-only Nadeo service account")
    parser.add_argument("--migrate-fall-2026", action="store_true",
                        help="explicitly register the 25 verified historic UID using official J+7; preserve public v4 archive")
    args = parser.parse_args()
    maps = validate_manifest(json.loads(args.manifest.read_text(encoding="utf-8")))
    store = Store(os.environ.get("SUPABASE_URL", ""), os.environ.get("SUPABASE_SECRET_KEY", ""))
    if args.migrate_fall_2026:
        maps.extend(fall_migration_maps())
    if args.discover:
        from discover_official_maps import fetch_official
        start_utc = os.environ.get("PM_WORLD_RANK_START_UTC", "")
        if not start_utc:
            parser.error("PM_WORLD_RANK_START_UTC is required before automatic discovery; no historical backfill")
        filter_discovery_since([], start_utc)  # Fail before contacting Nadeo.
        found = filter_discovery_since(fetch_official(), start_utc)
        existing = set()
        for kind in ("campaign", "totd"):
            existing.update(row["map_uid"] for row in store.states([m["uid"] for m in found if m["type"] == kind], kind))
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
        validate_manifest({"maps": maps}, allow_historical=args.migrate_fall_2026, max_maps=250)
    run(maps, store)


if __name__ == "__main__":
    main()
