"""Read-only verification of 25 Fall 2026 v5 goals against Supabase rows/audit.

Reads a private Supabase key only from memory; never prints credentials or raw
response bodies. --require-complete fails unless all 25 frozen goals are present.
"""
import argparse
from collections import Counter
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
from urllib.parse import quote
from urllib.request import Request, urlopen

from check_world_service_access import private_config
from world_rank_publisher import FALL_OFFICIAL_OPEN, OLD_UIDS, RANKS, SOURCE, Store, epoch


BASE = "https://mfopepdzllvyefwnxvqh.supabase.co"
PUBLISHABLE = "sb_publishable_bX6Orw7rrrBGZrgjehzWgA_jq4R2nhN"


def utc(value):
    if not isinstance(value, str): raise ValueError("invalid UTC timestamp")
    date = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if date.tzinfo is None: raise ValueError("UTC timezone required")
    return date.astimezone(timezone.utc)


def public_catalog(*, open_request=urlopen):
    req = Request(BASE + "/rest/v1/rpc/pm_public_catalog", headers={"apikey": PUBLISHABLE, "Accept": "application/json"})
    with open_request(req, timeout=12) as response:
        if response.status != 200 or response.geturl() != req.full_url:
            raise ValueError("public RPC unavailable")
        body = response.read(524289)
        if len(body) > 524288: raise ValueError("public RPC response too large")
        return json.loads(body)


def verify(store, public):
    if type(public) is not dict or public.get("schema") != 3 or type(public.get("maps")) is not dict:
        raise ValueError("unexpected public world catalogue")
    archive = json.loads((Path(__file__).parent.parent / "docs/catalogue.json").read_text(encoding="utf-8"))
    if archive.get("schema") != 2 or archive.get("version") != 4 or type(archive.get("maps")) is not dict:
        raise ValueError("historical v4 archive unavailable")
    uids = ",".join(sorted(OLD_UIDS))
    rows = store.request("map_medals?select=*&map_uid=in.%28" + quote(uids, safe=",") + "%29&limit=25")
    if type(rows) is not list or len(rows) != 25 or {r["map_uid"] for r in rows} != OLD_UIDS:
        raise ValueError("Fall 2026 registration incomplete or wrong UIDs")
    audit = store.request("map_medal_publications?select=*&map_uid=in.%28" + quote(uids, safe=",") + "%29&limit=25")
    if type(audit) is not list: raise ValueError("publication history unavailable")
    history = {r["map_uid"]: r for r in audit}
    counts = Counter()
    due = []
    for row in rows:
        uid = row["map_uid"]
        entry = public["maps"].get(uid)
        old = archive["maps"].get(uid)
        if (type(entry) is not dict or type(old) is not dict or entry.get("mapType") != "campaign" or
                entry.get("name") != old.get("name") or row["map_name"] != old.get("name") or row["map_type"] != "campaign" or
                utc(row["release_at"]) != utc(FALL_OFFICIAL_OPEN) or
                utc(row["eligible_at"]) != utc(FALL_OFFICIAL_OPEN) + timedelta(days=7)):
            raise ValueError("Fall 2026 official map metadata mismatch")
        status = row["status"]
        counts[status] += 1
        if row["capture_due_at"]:
            due.append(utc(row["capture_due_at"]))
        if status != "published":
            if entry.get("timesMs") is not None or uid in history:
                raise ValueError("partial unpublished goals or evidence")
            continue
        if uid not in history or entry.get("status") != "published" or row["data_source"] != SOURCE:
            raise ValueError("missing public goals or audit evidence")
        targets = [row["platinum_ms"], row["emerald_ms"], row["diamond_ms"]]
        wr = row["reference_wr_ms"]
        if (type(wr) is not int or any(type(value) is not int for value in targets) or
                not 1 <= wr <= targets[2] <= targets[1] <= targets[0] <= 86400000 or
                entry.get("timesMs") != targets or entry.get("referenceWrMs") != wr):
            raise ValueError("world times inconsistent between private/public records")
        threshold = utc(row["threshold_detected_at"])
        capture_due = utc(row["capture_due_at"])
        captured = utc(row["captured_at"])
        published = utc(row["published_at"])
        if capture_due != threshold + timedelta(hours=1) or not capture_due <= captured <= published:
            raise ValueError("premature or backdated world capture")
        evidence = row["capture_evidence"]
        if type(evidence) is not dict or set(evidence) != set(RANKS):
            raise ValueError("missing rank capture evidence")
        for medal, rank in RANKS.items():
            item = evidence[medal]
            if (type(item) is not dict or item.get("position") != rank or
                    type(item.get("playerCount")) is not int or item["playerCount"] < 5000 or
                    item.get("url") != f"https://trackmania.io/api/leaderboard/map/{uid}?length=1&offset={rank - 1}" or
                    not capture_due - timedelta(seconds=1) <= utc(item.get("observedAtUtc")) <= captured):
                raise ValueError("rank evidence/time mismatch")
        snapshot = history[uid]["snapshot"]
        if (snapshot.get("platinumMs") != targets[0] or snapshot.get("emeraldMs") != targets[1] or
                snapshot.get("diamondMs") != targets[2] or snapshot.get("wrMs") != wr or snapshot.get("evidence") != evidence):
            raise ValueError("append-only publication history mismatch")
    return counts, sorted(due)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-env", type=Path, required=True)
    parser.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()
    values = private_config(args.private_env)
    store = Store(values.get("SUPABASE_URL", ""), values.get("SUPABASE_SECRET_KEY") or values.get("SUPABASE_SERVICE_ROLE_KEY", ""))
    if store.base != BASE + "/rest/v1/": raise ValueError("wrong Supabase project")
    counts, due = verify(store, public_catalog())
    print("Fall 2026 v5: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())) + "; no writes.")
    if due:
        print("First/last UTC capture due: " + due[0].isoformat() + " / " + due[-1].isoformat())
    if args.require_complete and counts.get("published", 0) != 25:
        raise ValueError("not all 25 Fall 2026 goals have been published")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("Fall verification incomplete (" + type(exc).__name__ + "); no secret or raw data printed.")
        raise SystemExit(1)
