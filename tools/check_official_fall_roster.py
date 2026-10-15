"""Read-only confirmation of Fall 2026's *official* Nadeo opening time.

Does not import cards or read leaderboards. No credentials, UIDs or API bodies
are printed; a mismatch fails closed.
"""
import os
import time

from discover_official_maps import CAMPAIGNS, open_json, request_token
from world_rank_publisher import OLD_UIDS, iso


def official_start(response, *, now=time.time):
    campaigns = response.get("campaignList") if isinstance(response, dict) else None
    if not isinstance(campaigns, list) or len(campaigns) != 1:
        raise ValueError("official campaign response missing")
    campaign = campaigns[0]
    if not isinstance(campaign, dict) or campaign.get("name") != "Fall 2026" or not isinstance(campaign.get("playlist"), list):
        raise ValueError("unexpected active campaign")
    uids = [p.get("mapUid") if isinstance(p, dict) else None for p in campaign["playlist"]]
    if len(uids) != 25 or set(uids) != OLD_UIDS:
        raise ValueError("Fall 2026 official UIDs do not match frozen v4 roster")
    released = campaign.get("startTimestamp")
    if type(released) is not int or not 1609459200 <= released <= int(now()) - 604800:
        raise ValueError("Fall 2026 has not reached its official seven-day deadline")
    return released


def main():
    login = os.environ.get("PM_NADEO_SERVICE_LOGIN", "")
    password = os.environ.get("PM_NADEO_SERVICE_PASSWORD", "")
    token = request_token(login, password, "NadeoLiveServices")
    response = open_json(CAMPAIGNS, {"Authorization": "nadeo_v1 t=" + token})
    start = official_start(response)
    print("Official Fall 2026: 25 UIDs match; opened " + iso(start) +
          "; seven-day deadline " + iso(start + 604800) + ". No writes.")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("Official Fall 2026 check failed (" + type(exc).__name__ + "). No writes.")
        raise SystemExit(1)
