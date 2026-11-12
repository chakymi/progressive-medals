#!/usr/bin/env python3
"""Check the packaged Progressive Medals sources without running Trackmania.

This is a data/packaging check, not an AngelScript compilation or in-game test.
"""
import json
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugin"
RANKS = ("platinum", "emerald", "diamond")
UID_PATTERN = re.compile(r"[A-Za-z0-9_-]{15,80}\Z")


def validate_times(row):
    times = [row[f"{rank}_ms"] for rank in RANKS]
    assert all(type(value) is int for value in times), row
    assert 0 < times[2] <= times[1] <= times[0] <= 86_400_000, row


def validate():
    campaign = json.loads((PLUGIN / "catalog/fall-2026-goals.json").read_text("utf-8"))
    catalogue = json.loads((PLUGIN / "catalog/sheet-medals-bootstrap.json").read_text("utf-8"))
    assert campaign["campaign"] == "Fall 2026"
    assert catalogue["schema"] == 1
    assert len(campaign["maps"]) == 25

    published = {}
    for row in catalogue["maps"]:
        uid = row["map_uid"]
        assert UID_PATTERN.fullmatch(uid), uid
        assert uid not in published, f"Duplicate published UID: {uid}"
        assert row["status"] == "PUBLISHED"
        assert row["map_type"] in ("campaign", "totd")
        validate_times(row)
        published[uid] = row

    assert any(row["map_type"] == "totd" for row in published.values())
    campaign_uids = set()
    for row in campaign["maps"]:
        uid = row["uid"]
        assert UID_PATTERN.fullmatch(uid), uid
        assert uid not in campaign_uids, f"Duplicate Fall UID: {uid}"
        campaign_uids.add(uid)
        validate_times(row)
        match = published[uid]
        assert match["map_type"] == "campaign"
        assert all(row[f"{rank}_ms"] == match[f"{rank}_ms"] for rank in RANKS), uid

    for rank in RANKS:
        raw = (PLUGIN / "assets" / f"{rank}.png").read_bytes()
        assert raw.startswith(b"\x89PNG\r\n\x1a\n"), rank
        width, height = struct.unpack(">II", raw[16:24])
        assert width >= 128 and height >= 128, rank

    sources = {}
    for name in ("Main", "MenuBadges", "TotdBadges", "SheetCatalogue", "OfficialPbs"):
        sources[name] = (PLUGIN / f"{name}.as").read_text("utf-8")
    assert "int PML_MenuBadgeSize = 61;" in sources["Main"]
    assert "int PML_TotdBadgeSize = 56;" in sources["Main"]
    assert "NadeoServices" in (PLUGIN / "info.toml").read_text("utf-8")
    assert 'version = "0.7.2"' in (PLUGIN / "info.toml").read_text("utf-8")
    assert "supabase.co" not in "\n".join(sources.values()).lower()

    print(f"PASS: {len(campaign_uids)} Fall maps, "
          f"{sum(row['map_type'] == 'totd' for row in published.values())} TOTDs, "
          "5 AngelScript sources and 3 PNG icons")
    print("NOT TESTED: Openplanet compilation and Trackmania runtime")


if __name__ == "__main__":
    try:
        validate()
    except (AssertionError, KeyError, OSError, ValueError) as exc:
        print("FAIL:", exc, file=sys.stderr)
        sys.exit(1)
