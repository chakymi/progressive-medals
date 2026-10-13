"""Build one immutable Fall 2026 catalogue, never from per-player WR queries.

Use --check-roster before the agreed UTC opening. --publish refuses to fetch
leaderboards until 2026-10-13 22:03:09 UTC. Nothing is installed or uploaded.
"""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import tempfile
import time
from urllib.parse import urlsplit
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from generate import publish


HERE = Path(__file__).resolve().parent
ROSTER = HERE / "fall-2026-roster.json"
DEMOS = HERE / "demo-source.json"
NADEO_ACCOUNT = "aa02b90e-0652-4a1c-b705-4677e2983003"
UID_RE = re.compile(r"[a-zA-Z0-9_]{20,40}\Z")
MAX_RESPONSE = 131_072


def utc_now() -> int:
    return int(datetime.now(timezone.utc).timestamp())


def fetch_json(url: str, *, open_request=urlopen, pause=time.sleep) -> dict:
    parts = urlsplit(url)
    if parts.scheme != "https" or parts.hostname != "trackmania.io" or parts.username or parts.password:
        raise ValueError("only public Trackmania.io HTTPS endpoints are allowed")
    request = Request(url, headers={"User-Agent": "ProgressiveMedalsPublisher/0.1 (public-read-only)", "Accept": "application/json"})
    for attempt in range(3):
        try:
            with open_request(request, timeout=10) as response:
                if response.status != 200 or urlsplit(response.geturl()).hostname != "trackmania.io":
                    raise ValueError("map/leaderboard endpoint unavailable")
                body = response.read(MAX_RESPONSE + 1)
                if len(body) > MAX_RESPONSE:
                    raise ValueError("response too large")
            data = json.loads(body)
            if type(data) is not dict:
                raise ValueError("unexpected JSON response")
            return data
        except HTTPError as exc:
            if exc.code != 429 or attempt == 2:
                exc.close()
                raise ValueError(f"supplier HTTP {exc.code}; no catalogue published") from exc
            retry_after = (exc.headers or {}).get("Retry-After", "")
            seconds = int(retry_after) if retry_after.isdecimal() else 30 * (attempt + 1)
            delay = min(120, max(20, seconds))
            exc.close()
            print(f"Supplier rate limit (429): waiting {delay}s before a bounded retry", flush=True)
            pause(delay)
    raise ValueError("supplier unavailable")


def load_roster(path: Path = ROSTER) -> dict:
    roster = json.loads(path.read_text(encoding="utf-8"))
    if type(roster) is not dict or roster.get("campaign") != "Fall 2026":
        raise ValueError("wrong campaign")
    anchor = roster.get("launchAtUtc")
    available = roster.get("availableAtUtc")
    if type(anchor) is not int or anchor != 1_791_925_389 or type(available) is not int or available != anchor + 3600:
        raise ValueError("agreed launch UTC mismatch")
    maps = roster.get("maps")
    if type(maps) is not list or len(maps) != 25:
        raise ValueError("exactly 25 campaign maps required")
    seen = set()
    for number, item in enumerate(maps, 1):
        if type(item) is not dict or set(item) != {"number", "uid", "authorMs", "tmxId"}:
            raise ValueError("roster entry malformed")
        uid = item["uid"]
        if type(item["number"]) is not int or item["number"] != number or type(uid) is not str or not UID_RE.fullmatch(uid) or uid in seen:
            raise ValueError("number/UID sequence invalid")
        if type(item["authorMs"]) is not int or not 1 <= item["authorMs"] <= 86_400_000 or type(item["tmxId"]) is not int or item["tmxId"] < 1:
            raise ValueError("map data invalid")
        seen.add(uid)
    return roster


def collect(roster: dict, *, capture: bool, now=utc_now, fetch=fetch_json, pause=time.sleep) -> tuple[dict, list[dict]]:
    if capture and now() < roster["availableAtUtc"]:
        raise ValueError("too early: WR capture forbidden before common UTC release")
    source = {"schema": 2, "version": 3, "launchAtUtc": roster["launchAtUtc"], "maps": {}}
    demos = json.loads(DEMOS.read_text(encoding="utf-8"))
    for uid, example in demos["maps"].items():
        source["maps"][uid] = {**example, "release": {"kind": "demo"}}
    evidence = []
    for item in roster["maps"]:
        uid = item["uid"]
        info_url = f"https://trackmania.io/api/map/{uid}"
        info = fetch(info_url)
        if (info.get("mapUid") != uid or info.get("author") != NADEO_ACCOUNT or info.get("mapType") != "TrackMania\\TM_Race" or
                info.get("authorScore") != item["authorMs"] or info.get("isPlayable") is not True or
                type(info.get("name")) is not str or not 0 < len(info["name"]) <= 160):
            raise ValueError(f"map info mismatch for Fall 2026 - {item['number']:02d}")
        if capture:
            pause(2.5)  # Two calls per map, well below the supplier's observed rate limit.
            if now() < roster["availableAtUtc"]:
                raise ValueError("clock moved before allowed capture time")
            wr_url = f"https://trackmania.io/api/leaderboard/map/{uid}?length=1"
            leaderboard = fetch(wr_url)
            captured = now()
            tops = leaderboard.get("tops")
            if (leaderboard.get("lockedLeaderboard") is not False or type(tops) is not list or len(tops) != 1 or
                    type(tops[0]) is not dict or type(tops[0].get("position")) is not int or tops[0]["position"] != 1 or
                    type(tops[0].get("time")) is not int or type(tops[0].get("score")) is not int or tops[0]["score"] != tops[0]["time"] or
                    not 1 <= tops[0]["time"] <= 86_400_000):
                raise ValueError(f"missing verified WR for Fall 2026 - {item['number']:02d}")
            wr = tops[0]["time"]
            if item["authorMs"] - wr < 10:
                raise ValueError(f"WR too close to Author for Fall 2026 - {item['number']:02d}")
            source["maps"][uid] = {"name": info["name"], "authorMs": item["authorMs"], "referenceWrMs": wr,
                "release": {"kind": "launchCampaign", "anchorAtUtc": roster["launchAtUtc"],
                            "wrCapturedAtUtc": captured, "publishedAtUtc": 0}}
            evidence.append({"number": item["number"], "uid": uid, "wrMs": wr,
                             "wrCapturedAtUtc": captured, "source": wr_url})
        else:
            evidence.append({"number": item["number"], "uid": uid, "authorMs": item["authorMs"]})
        pause(2.5 if capture else 0.25)
    if capture:
        published = now()
        for item in roster["maps"]:
            source["maps"][item["uid"]]["release"]["publishedAtUtc"] = published
    return source, evidence


def write_new(path: Path, value: dict) -> None:
    if path.exists():
        raise FileExistsError(f"existing published catalogue not overwritten: {path}")
    contents = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    name = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=".progressive-", suffix=".tmp", delete=False) as tmp:
            name = tmp.name
            tmp.write(contents)
            tmp.flush()
            os.fsync(tmp.fileno())
        if path.exists():
            raise FileExistsError(f"existing published catalogue not overwritten: {path}")
        os.replace(name, path)
    finally:
        if name and os.path.exists(name):
            os.unlink(name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check-roster", action="store_true", help="check 25 UIDs/Author times, without reading WRs or writing")
    group.add_argument("--publish", action="store_true", help="capture 25 WRs after T0+1h; produce local catalogue + evidence")
    parser.add_argument("--output", type=Path, default=HERE.parent / "catalogue-fall-2026-v3.json")
    parser.add_argument("--wait", action="store_true", help="keep this process running until T0+1h, then publish once (requires --publish)")
    args = parser.parse_args()
    if args.wait and not args.publish:
        parser.error("--wait requires --publish")
    roster = load_roster()
    if args.publish and (args.output.exists() or args.output.with_suffix(".evidence.json").exists()):
        parser.error("output already exists; immutable version 3 must not be overwritten")
    if args.wait:
        while utc_now() < roster["availableAtUtc"]:
            time.sleep(min(30, roster["availableAtUtc"] - utc_now()))
    source, evidence = collect(roster, capture=args.publish)
    if args.check_roster:
        print("Roster OK: 25 Nadeo maps, UID and Author time cross-checked; no WR captured")
        return
    catalogue = publish(source, now_utc=utc_now())
    if catalogue["version"] != 3 or len(catalogue["maps"]) != 28 or any(len(m["timesMs"]) != 3 for m in catalogue["maps"].values()):
        raise ValueError("incomplete publication")
    # Catalogue and audit stay local; no upload, plugin edit or automatic deployment.
    write_new(args.output.with_suffix(".evidence.json"), {"campaign": "Fall 2026", "captures": evidence})
    write_new(args.output, catalogue)
    print(f"LOCAL catalogue ready: {args.output} (25 real maps + 3 demos)")


if __name__ == "__main__":
    main()
