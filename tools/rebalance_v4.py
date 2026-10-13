"""Publish a 30/60/90% catalogue without consulting any new world records.

The v3 catalogue and its evidence are the sole inputs. Preserve v3 as a
separate public file before replacing the current catalogue atomically.
"""

import argparse
from copy import deepcopy
import json
import os
from pathlib import Path
import tempfile

from generate import COUNT, goals, goals_linear, timestamp
from publish_fall_2026 import DEMOS, ROSTER, load_roster, utc_now, write_new


ROOT = Path(__file__).resolve().parent.parent
CURRENT = ROOT / "docs/catalogue.json"
ARCHIVE = ROOT / "docs/catalogue-v3.json"
EVIDENCE = ROOT / "docs/catalogue.evidence.json"


def rebalance(old: dict, evidence: dict, roster: dict, published_at: int) -> dict:
    timestamp(published_at, "publishedAtUtc")
    if type(old) is not dict or old.get("schema") != 2 or old.get("version") != 3 or old.get("launchAtUtc") != roster["launchAtUtc"]:
        raise ValueError("input must be the original schema-2 Fall 2026 catalogue v3")
    if type(evidence) is not dict or evidence.get("campaign") != "Fall 2026" or type(evidence.get("captures")) is not list or len(evidence["captures"]) != 25:
        raise ValueError("complete v3 snapshot evidence required")
    maps = old.get("maps")
    demo = json.loads(DEMOS.read_text(encoding="utf-8"))["maps"]
    expected = {item["uid"] for item in roster["maps"]} | set(demo)
    if type(maps) is not dict or set(maps) != expected or len(maps) != 28:
        raise ValueError("v3 map roster mismatch")
    captures = evidence["captures"]
    if any(type(x) is not dict or x.get("uid") not in expected for x in captures):
        raise ValueError("invalid snapshot evidence")
    by_uid = {x["uid"]: x for x in captures}
    if len(by_uid) != 25 or set(by_uid) != expected - set(demo):
        raise ValueError("snapshot UID mismatch or duplicates")
    updated = deepcopy(old)
    updated["version"] = 4
    updated["policy"] = {"distribution": "linear", "percent": [30, 60, 90], "wrSnapshot": "v3"}
    for item in roster["maps"]:
        uid = item["uid"]
        entry = maps[uid]
        if type(entry) is not dict:
            raise ValueError(f"invalid entry for map {item['number']:02d}")
        proof = by_uid[uid]
        release = entry.get("release")
        author, wr = entry.get("authorMs"), entry.get("referenceWrMs")
        if (type(author) is not int or author != item["authorMs"] or type(wr) is not int or
                type(release) is not dict or release.get("kind") != "launchCampaign" or
                release.get("anchorAtUtc") != roster["launchAtUtc"] or
                release.get("availableAtUtc") != roster["availableAtUtc"] or
                type(release.get("wrCapturedAtUtc")) is not int or release["wrCapturedAtUtc"] < roster["availableAtUtc"] or
                type(release.get("publishedAtUtc")) is not int or not release["wrCapturedAtUtc"] <= release["publishedAtUtc"] <= published_at or
                type(entry.get("timesMs")) is not list or entry["timesMs"] != goals(author, wr) or
                proof.get("number") != item["number"] or proof.get("wrMs") != wr or
                proof.get("wrCapturedAtUtc") != release["wrCapturedAtUtc"] or
                proof.get("source") != f"https://trackmania.io/api/leaderboard/map/{uid}?length=1"):
            raise ValueError(f"WR/evidence/author mismatch for map {item['number']:02d}")
        updated["maps"][uid]["timesMs"] = goals_linear(author, wr)
        updated["maps"][uid]["release"]["publishedAtUtc"] = published_at
    for uid, source in demo.items():
        entry = maps[uid]
        if (type(entry) is not dict or entry.get("name") != source["name"] or
                entry.get("authorMs") != source["authorMs"] or entry.get("referenceWrMs") != source["referenceWrMs"] or
                entry.get("release") != {"kind": "demo"} or entry.get("timesMs") != goals(source["authorMs"], source["referenceWrMs"])):
            raise ValueError("historical demo mismatch")
        updated["maps"][uid]["timesMs"] = goals_linear(source["authorMs"], source["referenceWrMs"])
    return updated


def replace_current(path: Path, value: dict) -> None:
    content = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    temporary = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=".catalogue-v4-", suffix=".tmp", delete=False) as out:
            temporary = out.name
            out.write(content)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish", action="store_true", help="archive v3 and replace docs/catalogue.json (local files only)")
    args = parser.parse_args()
    old_bytes = CURRENT.read_bytes()
    old = json.loads(old_bytes)
    evidence = json.loads(EVIDENCE.read_text(encoding="utf-8"))
    roster = load_roster(ROSTER)
    proposed = rebalance(old, evidence, roster, utc_now())
    uid = roster["maps"][5]["uid"]
    print(f"Validated 28 maps, 25 frozen WR; Fall 2026 - 06: {old['maps'][uid]['timesMs']} -> {proposed['maps'][uid]['timesMs']}")
    if not args.publish:
        print("Dry run only: no file changed, no HTTP request")
        return
    if ARCHIVE.exists():
        if ARCHIVE.read_bytes() != old_bytes:
            raise ValueError("existing v3 archive differs from current v3; refusing publication")
    else:
        write_new(ARCHIVE, old)
        if ARCHIVE.read_bytes() != old_bytes:
            raise ValueError("v3 archive is not byte-identical; refusing publication")
    replace_current(CURRENT, proposed)
    print("LOCAL v4 ready in docs/catalogue.json; commit/deploy only after review")


if __name__ == "__main__":
    main()
