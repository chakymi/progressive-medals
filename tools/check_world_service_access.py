"""Read-only check of server access to the isolated medals tables.

The optional --private-env is read only in memory. Only SUPABASE_URL and one
server key are used; no secret or account data is printed or stored.
"""
import argparse
import os
from pathlib import Path

from world_rank_publisher import Store


def private_config(path):
    config = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key in ("SUPABASE_URL", "SUPABASE_SECRET_KEY", "SUPABASE_SERVICE_ROLE_KEY"):
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                value = value[1:-1]
            config[key] = value
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-env", type=Path)
    args = parser.parse_args()
    values = private_config(args.private_env) if args.private_env else {}
    base = os.environ.get("SUPABASE_URL") or values.get("SUPABASE_URL", "")
    key = (os.environ.get("SUPABASE_SECRET_KEY") or os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or
           values.get("SUPABASE_SECRET_KEY") or values.get("SUPABASE_SERVICE_ROLE_KEY", ""))
    store = Store(base, key)
    rows = store.request("map_medals?select=map_uid,status&limit=1")
    catalog = store.request("rpc/pm_public_catalog")
    if not isinstance(rows, list) or not isinstance(catalog, dict) or catalog.get("schema") != 3:
        raise ValueError("publisher read contract unavailable")
    print("Supabase publisher read-only OK; public catalogue v" + str(catalog["version"]) +
          ", " + str(len(catalog["maps"])) + " map(s). No writes performed.")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        # Never expose an HTTP error body, environment value or traceback.
        print("Publisher read-only check failed (" + type(exc).__name__ + ").")
        raise SystemExit(1)
