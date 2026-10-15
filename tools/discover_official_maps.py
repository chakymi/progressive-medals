"""Discover Nadeo official campaigns/TOTDs from Live Services on a SERVER ONLY.

Requires a separate Trackmania service account. Documentation describes these
endpoints; real authenticated responses still need verification before rollout.
"""
import base64
import json
import os
import time
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener

from world_rank_publisher import OLD_UIDS, UID, iso


AUTH = "https://prod.trackmania.core.nadeo.online/v2/authentication/token/basic"
CAMPAIGNS = "https://live-services.trackmania.nadeo.live/api/campaign/official?offset=0&length=1"
TOTDS = "https://live-services.trackmania.nadeo.live/api/token/campaign/month?offset=0&length=2"
STAGES = {AUTH: "authentification", CAMPAIGNS: "campagnes", TOTDS: "TOTD"}
MAX_OFFICIAL_BYTES = 524_288


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


def open_json(url, headers, payload=None, *, open_request=None):
    if url not in (AUTH, CAMPAIGNS, TOTDS):
        raise ValueError("unapproved Nadeo service endpoint")
    req = Request(url, data=json.dumps(payload).encode() if payload is not None else None,
                  headers={**headers, "Accept": "application/json"}, method="POST" if payload is not None else "GET")
    try:
        opener = open_request or build_opener(NoRedirect).open
        with opener(req, timeout=12) as response:
            if response.status != 200 or response.geturl() != url:
                raise ValueError("Nadeo réponse inattendue (" + STAGES[url] + ")")
            body = response.read(MAX_OFFICIAL_BYTES + 1)
            if len(body) > MAX_OFFICIAL_BYTES:
                raise ValueError("Nadeo réponse trop volumineuse (" + STAGES[url] + ")")
            try:
                result = json.loads(body)
            except (ValueError, UnicodeDecodeError):
                raise ValueError("Nadeo JSON invalide (" + STAGES[url] + ")") from None
            if not isinstance(result, dict):
                raise ValueError("Nadeo JSON invalide (" + STAGES[url] + ")")
            return result
    except HTTPError as exc:
        status = exc.code
        exc.close()
        raise ValueError(f"Nadeo HTTP {status} ({STAGES[url]})") from None


def discover(campaigns, months, *, clock=time.time):
    """Use Nadeo startTimestamp, never a map upload time or player's install date."""
    if not isinstance(campaigns, dict) or not isinstance(campaigns.get("campaignList"), list):
        raise ValueError("campaign list missing")
    if not isinstance(months, dict) or not isinstance(months.get("monthList"), list):
        raise ValueError("month list missing")
    now = int(clock())
    result = {}
    campaign_list = campaigns["campaignList"]
    month_list = months["monthList"]
    if len(campaign_list) > 1 or len(month_list) > 2:
        raise ValueError("unbounded official lists")
    for campaign in campaign_list:
        if (not isinstance(campaign, dict) or not isinstance(campaign.get("playlist"), list) or
                type(campaign.get("startTimestamp")) is not int or
                not 0 < len(campaign["playlist"]) <= 25):
            raise ValueError("invalid official campaign")
        released = campaign["startTimestamp"]
        if not 1609459200 <= released <= now: continue
        for item in campaign["playlist"]:
            uid = item.get("mapUid") if isinstance(item, dict) else None
            if not isinstance(uid, str) or not UID.fullmatch(uid): raise ValueError("invalid official campaign UID")
            if uid not in OLD_UIDS:
                if uid in result: raise ValueError("duplicate official UID")
                result[uid] = {"uid": uid, "type": "campaign", "releaseAt": iso(released)}
    for month in month_list:
        if not isinstance(month, dict) or not isinstance(month.get("days"), list) or len(month["days"]) > 31:
            raise ValueError("invalid official TOTD month")
        for item in month["days"]:
            if not isinstance(item, dict): raise ValueError("invalid official TOTD")
            uid, released = item.get("mapUid"), item.get("startTimestamp")
            if uid is None or uid == "": continue  # Unannounced day: no UID, no goals.
            if type(released) is not int: raise ValueError("invalid official TOTD time type")
            if not 1609459200 <= released <= now: continue
            if not isinstance(uid, str) or not UID.fullmatch(uid):
                raise ValueError("invalid official TOTD UID")
            if uid not in OLD_UIDS:
                if uid in result: raise ValueError("duplicate campaign/TOTD UID")
                result[uid] = {"uid": uid, "type": "totd", "releaseAt": iso(released)}
    if len(result) > 100: raise ValueError("too many discovered maps")
    return list(result.values())


def request_token(login, password, audience, *, open_request=None):
    if audience not in ("NadeoServices", "NadeoLiveServices"):
        raise ValueError("unsupported Nadeo audience")
    if not login or not password or "\n" in login or "\n" in password:
        raise ValueError("dedicated Nadeo service account is not configured")
    basic = base64.b64encode(f"{login}:{password}".encode()).decode()
    token = open_json(AUTH, {"Authorization": "Basic " + basic,
                             "Content-Type": "application/json", "User-Agent": "ProgressiveMedalsPublisher/0.5"},
                      {"audience": audience}, open_request=open_request).get("accessToken")
    if not isinstance(token, str) or not token or len(token) > 8192:
        raise ValueError("Nadeo jeton absent (authentification)")
    return token


def fetch_official(*, open_request=None):
    login = os.environ.get("PM_NADEO_SERVICE_LOGIN", "")
    password = os.environ.get("PM_NADEO_SERVICE_PASSWORD", "")
    token = request_token(login, password, "NadeoLiveServices", open_request=open_request)
    headers = {"Authorization": "nadeo_v1 t=" + token, "User-Agent": "ProgressiveMedalsPublisher/0.5"}
    campaigns = open_json(CAMPAIGNS, headers, open_request=open_request)
    months = open_json(TOTDS, headers, open_request=open_request)
    try:
        return discover(campaigns, months)
    except ValueError as exc:
        # All keys are static diagnostics from our validator, never provider text.
        codes = {
            "campaign list missing": "campagnes-liste-absente",
            "month list missing": "totd-liste-absente",
            "unbounded official lists": "nombre-de-listes",
            "invalid official campaign": "campagne-format",
            "invalid official campaign UID": "campagne-uid",
            "duplicate official UID": "campagne-doublon",
            "invalid official TOTD month": "totd-mois-format",
            "invalid official TOTD": "totd-jour-format",
            "invalid official TOTD UID/time": "totd-uid-horaire",
            "invalid official TOTD time type": "totd-horaire-type",
            "invalid official TOTD UID": "totd-uid-format",
            "duplicate campaign/TOTD UID": "carte-deux-types",
            "too many discovered maps": "trop-de-cartes",
        }
        raise ValueError("Nadeo listes officielles incompatibles (validation:" +
                         codes.get(str(exc), "autre") + ")") from None
