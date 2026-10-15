"""Historical AT/WR publisher (versions 1-4 only; never use for new maps).

Usage: python tools/generate.py input.json output.json --power 2
Catalogue versions 1-3 keep their historical smoothstep formula. Version 4
uses 30/60/90 percent of the frozen Author-to-WR interval (no Champion).
Version 5+ uses the independent world-rank publisher, never this generator.
The generated JSON is reviewable before publication; never generated in the plugin.
"""
import argparse
from datetime import datetime, timezone
from fractions import Fraction
import json
from pathlib import Path

COUNT = 3
LEGACY_DEMO_COUNT = 10
MAX_MS = 86_400_000
EARLIEST_UTC = 1_609_459_200
LATEST_UTC = 4_102_444_800
DELAYS = {"campaign": 7 * 24 * 60 * 60, "totd": 60 * 60, "launchCampaign": 60 * 60}
DEMO_UIDS = {f"DEMO-PROGRESSIVE-{i:03d}" for i in range(1, 4)}


def timestamp(value, label: str) -> int:
    if type(value) is not int or not EARLIEST_UTC <= value <= LATEST_UTC:
        raise ValueError(f"{label} must be a UTC Unix timestamp in seconds (2021–2100)")
    return value


def release_for(uid: str, item: dict, schema: int, now_utc: int, launch_utc: int | None) -> dict | None:
    if schema == 1:
        if uid not in DEMO_UIDS or "release" in item:
            raise ValueError("schema 1 is reserved for the three fictitious maps")
        return None
    release = item.get("release")
    if type(release) is not dict:
        raise ValueError(f"missing release schedule for {uid}")
    kind = release.get("kind")
    if type(kind) is not str:
        raise ValueError(f"invalid release kind for {uid}")
    if kind == "demo" and uid in DEMO_UIDS and set(release) == {"kind"}:
        return {"kind": "demo"}
    if kind not in DELAYS or set(release) != {"kind", "anchorAtUtc", "wrCapturedAtUtc", "publishedAtUtc"}:
        raise ValueError(f"invalid release fields for {uid}")
    anchor = timestamp(release["anchorAtUtc"], "anchorAtUtc")
    captured = timestamp(release["wrCapturedAtUtc"], "wrCapturedAtUtc")
    published = timestamp(release["publishedAtUtc"], "publishedAtUtc")
    available = anchor + DELAYS[kind]
    if available > LATEST_UTC or captured < available or published < captured or published > now_utc:
        raise ValueError(f"early publication or invalid WR snapshot for {uid}")
    if kind == "launchCampaign" and (launch_utc is None or anchor != launch_utc):
        raise ValueError("launch campaign must use the shared launchAtUtc")
    return {"kind": kind, "anchorAtUtc": anchor, "availableAtUtc": available,
            "wrCapturedAtUtc": captured, "publishedAtUtc": published}


def goals(author_ms: int, wr_ms: int, power: int = 2, *, count: int = COUNT) -> list[int]:
    if type(author_ms) is not int or type(wr_ms) is not int or not (1 <= wr_ms < author_ms <= MAX_MS):
        raise ValueError("author/WR must be positive integer milliseconds, WR < author")
    if type(power) is not int or not 1 <= power <= 4:
        raise ValueError("power must be an integer between 1 and 4")
    if type(count) is not int or count not in (COUNT, LEGACY_DEMO_COUNT):
        raise ValueError("unsupported goal count")
    gap = author_ms - wr_ms
    if gap < count:
        raise ValueError(f"not enough distinct milliseconds for {count} goals")
    result = []
    for i in range(1, count + 1):
        x = Fraction(i, count + 1)
        curve = (3 * x * x - 2 * x * x * x) ** power
        offset = gap * curve
        rounded = (2 * offset.numerator + offset.denominator) // (2 * offset.denominator)
        ideal = author_ms - rounded
        # Preserve at least one millisecond for every remaining level.
        upper = (result[-1] - 1) if result else author_ms - 1
        lower = wr_ms + count - i
        result.append(max(lower, min(upper, ideal)))
    assert len(result) == count and all(wr_ms <= t < author_ms for t in result)
    assert all(a > b for a, b in zip(result, result[1:]))
    return result


def goals_linear(author_ms: int, wr_ms: int) -> list[int]:
    """Three reproducible targets at 30%, 60%, 90%; strict even in a 3ms gap."""
    if type(author_ms) is not int or type(wr_ms) is not int or not (1 <= wr_ms < author_ms <= MAX_MS):
        raise ValueError("author/WR must be positive integer milliseconds, WR < author")
    gap = author_ms - wr_ms
    if gap < COUNT:
        raise ValueError("not enough distinct milliseconds for three goals")
    result = []
    for i in range(1, COUNT + 1):
        offset = gap * Fraction(3 * i, 10)
        rounded = (2 * offset.numerator + offset.denominator) // (2 * offset.denominator)
        upper = result[-1] - 1 if result else author_ms - 1
        lower = wr_ms + COUNT - i
        result.append(max(lower, min(upper, author_ms - rounded)))
    assert len(result) == COUNT and all(wr_ms <= t < author_ms for t in result)
    assert all(a > b for a, b in zip(result, result[1:]))
    return result


def publish(source: dict, power: int = 2, now_utc: int | None = None) -> dict:
    if type(source) is not dict or type(source.get("version")) is not int or not 1 <= source["version"] <= 1_000_000:
        raise ValueError("positive integer version required")
    if source["version"] >= 5:
        raise ValueError("AT/WR goals are historical only; use exact world ranks for version 5+")
    if source["version"] >= 4 and power != 2:
        raise ValueError("--power applies only to historical smoothstep versions 1-3")
    schema = source.get("schema", 1)
    if type(schema) is not int or schema not in (1, 2):
        raise ValueError("supported schemas: 1 (demo only), 2 (scheduled)")
    if schema == 2 and source["version"] < 3:
        raise ValueError("schema 2 real maps require catalogue version 3 or later")
    if now_utc is None:
        now_utc = int(datetime.now(timezone.utc).timestamp())
    timestamp(now_utc, "now_utc")
    launch_utc = source.get("launchAtUtc")
    if launch_utc is not None:
        if schema != 2:
            raise ValueError("launchAtUtc requires schema 2")
        timestamp(launch_utc, "launchAtUtc")
    maps = source.get("maps")
    if type(maps) is not dict or len(maps) > 5000:
        raise ValueError("maps must be an object of at most 5000 UIDs")
    output = {}
    for uid, item in maps.items():
        if type(uid) is not str or not uid or len(uid) > 128 or "/" in uid or "\\" in uid:
            raise ValueError("invalid UID")
        if type(item) is not dict or type(item.get("name")) is not str or not 0 < len(item["name"]) <= 160:
            raise ValueError(f"invalid map name for {uid}")
        release = release_for(uid, item, schema, now_utc, launch_utc)
        author, wr = item.get("authorMs"), item.get("referenceWrMs")
        targets = (goals_linear(author, wr) if source["version"] >= 4
                   else goals(author, wr, power,
                       count=LEGACY_DEMO_COUNT if schema == 1 and source["version"] == 1 else COUNT))
        output[uid] = {"name": item["name"], "authorMs": author,
                       "referenceWrMs": wr, "timesMs": targets}
        if release is not None:
            output[uid]["release"] = release
    result = {"schema": schema, "version": source["version"], "maps": output}
    if launch_utc is not None:
        result["launchAtUtc"] = launch_utc
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--power", type=int, default=2)
    args = parser.parse_args()
    source = json.loads(args.input.read_text(encoding="utf-8"))
    result = publish(source, args.power)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
