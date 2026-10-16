"""Check the immutable 26-map v5 archive and its v7 replacement, read-only.

The private backup stays outside the repo. Never print REST bodies, credentials,
or archived user data. --require-complete requires all 26 new publications.
"""
import argparse
from collections import Counter
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
from urllib.parse import quote

from check_world_service_access import private_config
from verify_fall_migration import BASE, public_catalog
from world_rank_publisher import RANKS_BY_TYPE, SOURCE, Store


def stamp(value):
    if type(value) is not str: raise ValueError("invalid timestamp")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None: raise ValueError("missing UTC timezone")
    return result.astimezone(timezone.utc)


def archived(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    digest = data.pop("sha256", None)
    if type(digest) is not str or hashlib.sha256(json.dumps(data, sort_keys=True, ensure_ascii=False).encode()).hexdigest() != digest:
        raise ValueError("private archive hash mismatch")
    old = data.get("map_medals")
    journal = data.get("map_medal_publications")
    if (type(old) is not list or type(journal) is not list or len(old) != 26 or len(journal) != 26 or
            len({row["map_uid"] for row in old}) != 26 or
            {row["map_uid"] for row in old} != {row["map_uid"] for row in journal}):
        raise ValueError("private historical 26-map archive incomplete")
    return {row["map_uid"]: row for row in old}, {row["map_uid"]: row for row in journal}


def read_rows(store, table, uids):
    names = quote(",".join(sorted(uids)), safe=",")
    result = store.request(table + "?select=*&map_uid=in.%28" + names + "%29&limit=26")
    if type(result) is not list or len(result) > 26:
        raise ValueError("private revision query incomplete")
    return {row["map_uid"]: row for row in result}


def verify(store, public, old, old_journal):
    if type(public) is not dict or public.get("schema") != 3 or type(public.get("maps")) is not dict:
        raise ValueError("public world catalogue unavailable")
    uids = set(old)
    current_old = read_rows(store, "map_medals", uids)
    current_journal = read_rows(store, "map_medal_publications", uids)
    if current_old != old or current_journal != old_journal:
        raise ValueError("an archived v5 medal or its proof has changed")
    revised = read_rows(store, "pm_revised_medals", uids)
    proofs = read_rows(store, "pm_revised_medal_publications", uids)
    if not set(proofs) <= set(revised): raise ValueError("orphan new evidence")
    counts = Counter()
    counts["registered"] = len(revised)
    due_dates = []
    for uid, historical in old.items():
        entry = public["maps"].get(uid)
        row = revised.get(uid)
        if row is not None and row.get("capture_due_at"):
            due_dates.append(stamp(row["capture_due_at"]))
        if type(entry) is not dict: raise ValueError("published UID missing from public catalogue")
        if row is None or row["status"] != "published":
            counts["waiting"] += 1
            if row is not None: counts[row["status"]] += 1
            if (uid in proofs or entry.get("calculationVersion") != 5 or
                    entry.get("timesMs") != [historical[k] for k in ("platinum_ms", "emerald_ms", "diamond_ms")]):
                raise ValueError("historical medals not preserved while recapturing")
            continue
        counts["published"] += 1
        kind = historical["map_type"]
        ranks = RANKS_BY_TYPE[kind]
        goals = [row[k] for k in ("platinum_ms", "emerald_ms", "diamond_ms")]
        wr = row["reference_wr_ms"]
        if (row["calculation_version"] != 7 or row["map_type"] != kind or
                row["map_name"] != historical["map_name"] or row["release_at"] != historical["release_at"] or
                row["eligible_at"] != historical["eligible_at"] or row["data_source"] != SOURCE or
                type(wr) is not int or any(type(value) is not int for value in goals) or
                not 1 <= wr <= goals[2] <= goals[1] <= goals[0] <= 86400000 or row["player_count"] < 2500 or
                entry.get("calculationVersion") != 7 or entry.get("timesMs") != goals or
                entry.get("referenceWrMs") != wr or entry.get("status") != "published"):
            raise ValueError("v7 goals inconsistent with published record")
        detected = stamp(row["threshold_detected_at"])
        due = stamp(row["capture_due_at"])
        captured = stamp(row["captured_at"])
        published = stamp(row["published_at"])
        if (not stamp(row["eligible_at"]) < detected or due != detected + timedelta(hours=1) or
                not due <= captured <= published):
            raise ValueError("v7 world capture premature or backdated")
        evidence = row["capture_evidence"]
        if type(evidence) is not dict or set(evidence) != set(ranks):
            raise ValueError("v7 rank evidence missing")
        for medal, position in ranks.items():
            item = evidence[medal]
            if (type(item) is not dict or item.get("position") != position or
                    type(item.get("playerCount")) is not int or item["playerCount"] < 2500 or
                    item.get("url") != f"https://trackmania.io/api/leaderboard/map/{uid}?length=1&offset={position - 1}" or
                    not due - timedelta(seconds=1) <= stamp(item.get("observedAtUtc")) <= captured):
                raise ValueError("v7 supplier rank evidence inconsistent")
        audit = proofs.get(uid)
        if type(audit) is not dict or type(audit.get("snapshot")) is not dict:
            raise ValueError("v7 append-only audit missing")
        saved = audit["snapshot"]
        if (saved.get("platinumMs") != goals[0] or saved.get("emeraldMs") != goals[1] or
                saved.get("diamondMs") != goals[2] or saved.get("wrMs") != wr or saved.get("evidence") != evidence):
            raise ValueError("v7 append-only audit mismatch")
    if counts["waiting"] + counts["published"] != 26:
        raise ValueError("v7 archive size changed")
    return counts, sorted(due_dates)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-env", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()
    old, journal = archived(args.archive)
    values = private_config(args.private_env)
    key = os.environ.get("SUPABASE_SECRET_KEY") or values.get("SUPABASE_SECRET_KEY") or values.get("SUPABASE_SERVICE_ROLE_KEY", "")
    store = Store(values.get("SUPABASE_URL", ""), key)
    if store.base != BASE + "/rest/v1/": raise ValueError("wrong Supabase project")
    counts, due_dates = verify(store, public_catalog(), old, journal)
    print(f"v7 verification: {counts['published']}/26 revised, {counts['registered']} registered, "
          f"{counts['waiting']} still on frozen v5 ({counts['waiting_extra_hour']} in extra hour). No writes.")
    if due_dates:
        print("First/last UTC v7 capture due: " + due_dates[0].isoformat() + " / " + due_dates[-1].isoformat())
    if args.require_complete and counts["published"] != 26:
        raise ValueError("revision v7 not complete")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("Revision verification incomplete (" + type(exc).__name__ + "); no credentials or raw rows printed.")
        raise SystemExit(1)
