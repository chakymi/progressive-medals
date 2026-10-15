"""One-shot private, immutable backup of published rows and append-only evidence.

Run on a trusted server with SUPABASE_URL/SUPABASE_SECRET_KEY in its environment.
Output must be outside docs/, plugin/ and the Git checkout.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
from check_world_service_access import private_config
from world_rank_publisher import Store, iso
from publish_fall_2026 import write_new
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--private-env", type=Path, help="optional existing private .env; never copied or logged")
    args = parser.parse_args()
    destination = args.output.resolve()
    root = Path(__file__).resolve().parent.parent
    if destination == root or root in destination.parents or not destination.parent.is_dir():
        parser.error("backup must be written to an existing PRIVATE directory outside this repository")
    values = private_config(args.private_env) if args.private_env else {}
    url = os.environ.get("SUPABASE_URL") or values.get("SUPABASE_URL", "")
    key = (os.environ.get("SUPABASE_SECRET_KEY") or os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or
           values.get("SUPABASE_SECRET_KEY") or values.get("SUPABASE_SERVICE_ROLE_KEY", ""))
    store = Store(url, key)
    def pages(endpoint):
        result = []
        for offset in range(0, 100000, 100):
            batch = store.request(f"{endpoint}&limit=100&offset={offset}&order=map_uid.asc")
            if not isinstance(batch, list): raise ValueError("backup source returned invalid rows")
            result.extend(batch)
            if len(batch) < 100: return result
        raise ValueError("backup exceeds supported range")
    rows = pages("map_medals?select=*&status=eq.published")
    evidence = pages("map_medal_publications?select=*")
    if not isinstance(rows, list) or not isinstance(evidence, list) or len(rows) != len(evidence):
        raise ValueError("backup incomplete: rows and evidence do not match")
    uids = {row["map_uid"] for row in rows}
    if len(uids) != len(rows) or uids != {row["map_uid"] for row in evidence}:
        raise ValueError("backup incomplete: UID mismatch")
    snapshot = {"capturedAtUtc": iso(int(time.time())), "map_medals": rows,
                "map_medal_publications": evidence}
    digest = hashlib.sha256(json.dumps(snapshot, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    snapshot["sha256"] = digest
    write_new(destination, snapshot)  # Never overwrite an existing snapshot.
    print(f"Private snapshot stored: {len(rows)} published maps, sha256={digest}")


if __name__ == "__main__":
    main()
