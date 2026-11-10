#!/usr/bin/env python3
"""Offline consistency checks; this is not an AngelScript compiler."""
import json
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def validate():
    data = json.loads((ROOT / "plugin/catalog/fall-2026-goals.json").read_text("utf-8"))
    assert data["campaign"] == "Fall 2026"
    maps = data["maps"]
    assert len(maps) == 25
    seen = set()
    for idx, row in enumerate(maps, 1):
        uid = row["uid"]
        assert re.fullmatch(r"[A-Za-z0-9_-]{15,80}", uid), idx
        assert uid not in seen, idx
        seen.add(uid)
        p, e, d = [row[k + "_ms"] for k in ("platinum", "emerald", "diamond")]
        assert all(type(x) is int for x in (p, e, d)), idx
        assert 0 < d <= e <= p <= 86_400_000, idx
    def goals(row):
        return tuple(row[k + "_ms"] for k in ("platinum", "emerald", "diamond"))
    assert goals(maps[0]) == (20143, 20098, 20058)
    assert goals(maps[1]) == (21564, 21510, 21425)

    for name in ("platinum", "emerald", "diamond"):
        raw = (ROOT / "plugin/assets" / (name + ".png")).read_bytes()
        assert raw.startswith(b"\x89PNG\r\n\x1a\n")
        w, h, depth, color = struct.unpack(">IIBB", raw[16:26])
        assert w >= 128 and h >= 128 and depth == 8 and color == 6, name

    main = (ROOT / "plugin/Main.as").read_text("utf-8")
    menu = (ROOT / "plugin/MenuBadges.as").read_text("utf-8")
    manifest = (ROOT / "plugin/info.toml").read_text("utf-8")
    assert "int PML_MenuBadgeSize = 58;" in main
    assert "int PML_MenuOffsetX = 3;" in main
    assert "void Render()" in main and "RenderCampaignBadges()" in main
    assert "if (menuAccount == account)" in menu
    assert 'dependencies = [ "NadeoServices" ]' in manifest
    assert 'version = "0.2.1"' in manifest
    assert "&test=1" not in main and "&test=1" not in menu
    print("PASS: Fall 2026 roster, goals, exceptions, PNG files and source configuration")
    print("NOT TESTED: AngelScript compilation and in-game runtime")

if __name__ == "__main__":
    try:
        validate()
    except (AssertionError, OSError, KeyError, ValueError) as exc:
        print("FAIL:", exc, file=sys.stderr)
        sys.exit(1)
