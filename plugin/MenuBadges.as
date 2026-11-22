// Fall 2026 uses a fixed playlist order. All target times come from Google Sheets.
// This overlay draws over native menu tiles without changing game controls.
namespace PML {
    string[] menuUids;
    dictionary fallIndexByUid; // UID -> playlist index (0 to 24).
    PlayerPbs@ campaignPbs = PlayerPbs();
    string menuStatus = "En attente du menu Fall 2026";

    void InitMenuBadges() {
        try {
            Json::Value@ root = Json::FromFile("catalog/fall-2026-goals.json");
            if (root is null || root.GetType() != Json::Type::Object ||
                    !root.HasKey("campaign") || string(root.Get("campaign")) != "Fall 2026" ||
                    !root.HasKey("maps")) throw("Invalid Fall 2026 roster");
            const Json::Value@ maps = root.Get("maps");
            if (maps is null || maps.GetType() != Json::Type::Array ||
                    maps.Length != FALL_MAP_COUNT) throw("Unexpected Fall 2026 map count");
            for (uint i = 0; i < maps.Length; i++) {
                const Json::Value@ row = maps[i];
                if (row is null || row.GetType() != Json::Type::Object ||
                        !row.HasKey("uid")) throw("Missing campaign UID");
                string uid = string(row.Get("uid"));
                if (!IsValidUid(uid) || fallIndexByUid.Exists(uid))
                    throw("Invalid or repeated campaign UID");
                fallIndexByUid.Set(uid, i);
                menuUids.InsertLast(uid);
            }
            menuStatus = "" + FALL_MAP_COUNT + " cartes Fall 2026 chargées, PB en attente";
        } catch {
            menuUids.RemoveRange(0, menuUids.Length);
            fallIndexByUid.DeleteAll();
            menuStatus = "Catalogue Fall 2026 indisponible";
            warn(LOG_PREFIX + "campaign roster: " + getExceptionInfo());
        }
    }

    int FindFall2026IndexByUid(const string &in uid) {
        uint index = 0;
        return fallIndexByUid.Get(uid, index) ? int(index) : -1;
    }

    // One grouped Nadeo request, only while the Fall 2026 grid is open.
    void FetchCampaignPbs() {
        if (campaignPbs.loading || menuUids.Length != FALL_MAP_COUNT) return;
        if (campaignPbs.lastAttempt != 0 &&
                Time::Now - campaignPbs.lastAttempt < PB_REFRESH_MS) return;
        if (!Permissions::ViewRecords() || AuthenticatedAccount().Length == 0) {
            menuStatus = "En attente des autorisations PB Nadeo";
            return;
        }

        campaignPbs.loading = true;
        campaignPbs.lastAttempt = Time::Now;
        menuStatus = "Lecture groupée des PB de Fall 2026…";
        try {
            string account = AuthenticatedAccount();
            dictionary received;
            ReadOfficialPbs(menuUids, received);
            if (AuthenticatedAccount() != account) throw("Nadeo account changed");
            MergeOfficialPbs(campaignPbs, menuUids, received);
            menuStatus = "PB chargés : " + campaignPbs.times.GetSize() + "/" + FALL_MAP_COUNT;
        } catch {
            menuStatus = "Impossible de récupérer les PB (nouvel essai différé)";
            warn(LOG_PREFIX + "campaign PB: " + getExceptionInfo());
        }
        campaignPbs.loading = false;
    }

    void MenuPbWorker() {
        while (true) {
            if (SynchronizeAccount(campaignPbs))
                menuStatus = "Compte changé : PB à relire";
            if (PML_ShowMenuBadges && menuUids.Length == FALL_MAP_COUNT &&
                    FindBadgeMenuPage(false) !is null && !campaignPbs.loading)
                FetchCampaignPbs();
            sleep(2500);
        }
    }

    void RenderCampaignBadges() {
        if (menuUids.Length != FALL_MAP_COUNT || badgeTextures.Length != MEDAL_COUNT ||
                campaignPbs.times.IsEmpty()) return;
        CGameManialinkPage@ page = FindBadgeMenuPage(false);
        if (page is null) return;
        BadgeLayout@ layout = MakeBadgeLayout(page, 0, 0, PML_MenuBadgeSize,
                                              PML_MenuOffsetX, PML_MenuOffsetY);
        nvg::Save();
        try {
            for (uint i = 0; i < menuUids.Length; i++) {
                uint best = 0;
                if (!campaignPbs.times.Get(menuUids[i], best)) continue;
                Goals@ goal;
                if (!publishedByUid.Get(menuUids[i], @goal) || goal is null) continue;
                int level = HighestBadge(goal.times, best);
                if (level < 0) continue;
                // Keep the verified Fall 2026 row/column mapping unchanged.
                CGameManialinkFrame@ frame = cast<CGameManialinkFrame@>(
                    page.GetFirstChild("frame-map-" + (i / FALL_GRID_SIDE) + "-" +
                                       (i % FALL_GRID_SIDE)));
                DrawBadge(frame, level, layout);
            }
        } catch {
            menuStatus = "Menu modifié : rendu des badges différé";
        }
        nvg::Restore();
    }
}
