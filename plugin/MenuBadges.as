// Campaign badge overlay. Uses a fixed Fall 2026 snapshot; no global leaderboard polling.
namespace PML {
    class MenuTarget {
        uint[] times;
    }

    string[] menuUids;
    dictionary menuTargets;
    dictionary menuPbs;
    nvg::Texture@[] menuTextures;
    string menuAccount = "";
    string menuStatus = "En attente du menu Fall 2026";
    uint64 menuLastAttempt = 0;
    bool menuLoading = false;
    const uint64 PB_MIN_REFRESH_MS = 1800000;
    const uint64 PB_HTTP_TIMEOUT_MS = 12000;

    // Keep type and range checks here: the catalog and API are data, not code.
    bool ReadMenuMs(const Json::Value@ object, const string &in key, uint &out value) {
        value = 0;
        if (object is null || !object.HasKey(key)) return false;
        const Json::Value@ node = object.Get(key);
        if (node is null || node.GetType() != Json::Type::Number) return false;
        double n = double(node);
        if (n < 1 || n > double(MAX_TIME_MS) || n != double(uint(n))) return false;
        value = uint(n);
        return true;
    }

    void InitMenuBadges() {
        try {
            Json::Value@ root = Json::FromFile("catalog/fall-2026-goals.json");
            if (root is null || root.GetType() != Json::Type::Object ||
                    !root.HasKey("campaign") || string(root.Get("campaign")) != "Fall 2026" ||
                    !root.HasKey("maps"))
                throw("Catalogue Fall 2026 invalide");
            const Json::Value@ maps = root.Get("maps");
            if (maps is null || maps.GetType() != Json::Type::Array || maps.Length != 25)
                throw("Le menu Fall 2026 doit contenir 25 cartes");

            dictionary seen;
            for (uint i = 0; i < maps.Length; i++) {
                const Json::Value@ row = maps[i];
                if (row is null || row.GetType() != Json::Type::Object ||
                        !row.HasKey("uid") || !row.HasKey("platinum_ms") ||
                        !row.HasKey("emerald_ms") || !row.HasKey("diamond_ms"))
                    throw("Entrée de catalogue incomplète");

                string uid = string(row.Get("uid"));
                if (!IsValidUid(uid) || seen.Exists(uid))
                    throw("UID manquant ou dupliqué");
                uint p = 0;
                uint e = 0;
                uint d = 0;
                if (!ReadMenuMs(row, "platinum_ms", p) ||
                        !ReadMenuMs(row, "emerald_ms", e) ||
                        !ReadMenuMs(row, "diamond_ms", d) || p < e || e < d)
                    throw("Temps de médailles invalides");
                MenuTarget@ target = MenuTarget();
                uint[] times = {p, e, d};
                target.times = times;
                menuTargets.Set(uid, @target);
                menuUids.InsertLast(uid);
                seen.Set(uid, true);
            }
            menuStatus = "25 cartes Fall 2026 chargées";
        } catch {
            menuUids.RemoveRange(0, menuUids.Length);
            menuTargets.DeleteAll();
            menuStatus = "Catalogue Fall 2026 indisponible";
            warn("Progressive Medals: " + getExceptionInfo());
        }

        const string[] paths = {"assets/platinum.png", "assets/emerald.png", "assets/diamond.png"};
        for (uint i = 0; i < paths.Length; i++) {
            nvg::Texture@ texture;
            try {
                @texture = nvg::LoadTexture(paths[i], int(nvg::TextureFlags::GenerateMipmaps));
            } catch {
                warn("Progressive Medals: PNG manquant: " + paths[i]);
            }
            menuTextures.InsertLast(texture);
        }
    }

    // Trackmania UI control names may change between game releases.
    CGameManialinkPage@ FindFallMenuPage() {
        try {
            CTrackMania@ app = cast<CTrackMania@>(GetApp());
            if (app is null || app.Editor !is null || app.CurrentPlayground !is null ||
                    app.MenuManager is null || app.MenuManager.MenuCustom_CurrentManiaApp is null)
                return null;
            auto layers = app.MenuManager.MenuCustom_CurrentManiaApp.UILayers;
            for (uint i = 0; i < layers.Length && i < 100; i++) {
                CGameUILayer@ layer = layers[i];
                if (layer is null || !layer.IsVisible || layer.LocalPage is null) continue;
                CGameManialinkPage@ page = layer.LocalPage;
                if (page.GetFirstChild("frame-map-0-0") is null) continue;
                CGameManialinkLabel@ title =
                    cast<CGameManialinkLabel@>(page.GetFirstChild("label-title"));
                if (title is null) continue;
                string caption = Text::StripFormatCodes(string(title.Value)).ToLower();
                if (!caption.Contains("2026") ||
                        (!caption.Contains("automne") && !caption.Contains("fall")))
                    continue;
                CGameManialinkControl@ zone = page.GetFirstChild("frame-zone-selection");
                CGameManialinkControl@ club = page.GetFirstChild("frame-pinned-club");
                if ((zone !is null && zone.Visible) || (club !is null && club.Visible))
                    continue;
                return page;
            }
        } catch {
            // Menu pages are transient while navigating.
        }
        return null;
    }

    bool GetFallGridSpacing(CGameManialinkPage@ page, vec2 &out spacing) {
        if (page is null) return false;
        CGameManialinkFrame@ first =
            cast<CGameManialinkFrame@>(page.GetFirstChild("frame-map-0-0"));
        CGameManialinkFrame@ right =
            cast<CGameManialinkFrame@>(page.GetFirstChild("frame-map-1-0"));
        CGameManialinkFrame@ below =
            cast<CGameManialinkFrame@>(page.GetFirstChild("frame-map-0-1"));
        if (first is null || right is null || below is null) return false;
        vec3 p = first.AbsolutePosition;
        vec3 r = right.AbsolutePosition;
        vec3 b = below.AbsolutePosition;
        spacing = vec2(r.x - p.x, b.y - p.y);
        return spacing.x >= 8.0f && spacing.x <= 80.0f &&
               spacing.y <= -3.0f && spacing.y >= -45.0f;
    }

    bool IsMenuUid(const string &in uid) {
        for (uint i = 0; i < menuUids.Length; i++) {
            if (menuUids[i] == uid) return true;
        }
        return false;
    }

    // One grouped request, no more than once per 30 minutes while menu is open.
    void FetchCampaignPbs() {
        if (menuLoading || menuUids.Length != 25) return;
        if (menuLastAttempt != 0 && Time::Now - menuLastAttempt < PB_MIN_REFRESH_MS)
            return;
        if (!Permissions::ViewRecords()) {
            menuStatus = "Permission de consulter les records désactivée";
            return;
        }
        if (!NadeoServices::IsAuthenticated("NadeoLiveServices")) {
            menuStatus = "Authentification Nadeo en attente";
            return;
        }

        menuLoading = true;
        menuLastAttempt = Time::Now;
        menuStatus = "Lecture groupée des PB...";
        try {
            string account = NadeoServices::GetAccountID();
            if (account.Length == 0) throw("Compte Nadeo indisponible");

            string body = "{\"maps\":[";
            for (uint i = 0; i < menuUids.Length; i++) {
                if (i > 0) body += ",";
                body += "{\"mapUid\":\"" + menuUids[i] +
                        "\",\"groupUid\":\"Personal_Best\"}";
            }
            body += "]}";

            Net::HttpRequest@ request = NadeoServices::Post("NadeoLiveServices",
                NadeoServices::BaseURLLive() + "/api/token/leaderboard/group/map", body);
            request.Start();
            uint64 started = Time::Now;
            while (!request.Finished()) {
                if (Time::Now - started > PB_HTTP_TIMEOUT_MS ||
                        request.ProgressDownload() > 65536) {
                    request.Cancel();
                    throw("Lecture des PB expirée ou trop volumineuse");
                }
                sleep(100);
            }
            if (request.ResponseCode() != 200 || request.ProgressDownload() > 65536)
                throw("Réponse PB invalide : HTTP " + request.ResponseCode());
            string raw = request.String();
            if (raw.Length > 65536) throw("Réponse PB trop longue");
            Json::Value@ records = Json::Parse(raw);
            if (records is null || records.GetType() != Json::Type::Array ||
                    records.Length > 25)
                throw("Réponse PB inattendue");

            dictionary next;
            for (uint i = 0; i < records.Length; i++) {
                const Json::Value@ record = records[i];
                if (record is null || record.GetType() != Json::Type::Object ||
                        !record.HasKey("mapUid") || !record.HasKey("groupUid") ||
                        !record.HasKey("score"))
                    throw("Record incomplet");
                string uid = string(record.Get("mapUid"));
                string group = string(record.Get("groupUid"));
                uint score = 0;
                if (!ReadMenuMs(record, "score", score) || !IsMenuUid(uid) ||
                        group != "Personal_Best" || next.Exists(uid))
                    throw("Record hors campagne ou invalide");
                next.Set(uid, score);
            }
            if (NadeoServices::GetAccountID() != account)
                throw("Compte changé pendant la lecture");

            // Preserve a better known PB if Nadeo returns a partial or stale batch.
            if (menuAccount == account) {
                for (uint i = 0; i < menuUids.Length; i++) {
                    uint previous = 0;
                    uint fresh = 0;
                    if (!menuPbs.Get(menuUids[i], previous)) continue;
                    if (!next.Get(menuUids[i], fresh) || previous < fresh)
                        next.Set(menuUids[i], previous);
                }
            }
            if (records.Length > 0 || menuPbs.IsEmpty() || account != menuAccount)
                menuPbs = next;
            menuAccount = account;
            menuStatus = "PB chargés : " + menuPbs.GetSize() + "/25";
        } catch {
            menuStatus = "PB indisponibles (réessai différé)";
            warn("Progressive Medals: " + getExceptionInfo());
        }
        menuLoading = false;
    }

    void MenuPbWorker() {
        while (true) {
            if (menuAccount.Length > 0 &&
                    (!NadeoServices::IsAuthenticated("NadeoLiveServices") ||
                     NadeoServices::GetAccountID() != menuAccount)) {
                menuPbs.DeleteAll();
                menuAccount = "";
                menuLastAttempt = 0;
                menuStatus = "Compte changé : PB à recharger";
            }
            if (PML_ShowMenuBadges && menuUids.Length == 25 &&
                    FindFallMenuPage() !is null && !menuLoading)
                FetchCampaignPbs();
            sleep(2500);
        }
    }

    void RememberMenuPb(const string &in uid, uint best) {
        if (best == 0 || best == uint(-1) || !IsMenuUid(uid) ||
                !NadeoServices::IsAuthenticated("NadeoLiveServices"))
            return;
        string account = NadeoServices::GetAccountID();
        if (account.Length == 0) return;
        if (menuAccount.Length > 0 && menuAccount != account)
            menuPbs.DeleteAll();
        menuAccount = account;
        uint previous = 0;
        if (!menuPbs.Get(uid, previous) || best < previous)
            menuPbs.Set(uid, best);
    }

    int HighestMenuBadge(const MenuTarget@ target, uint best) {
        if (target is null || best == 0 || best > MAX_TIME_MS ||
                target.times.Length != 3)
            return -1;
        int highest = -1;
        for (uint i = 0; i < 3; i++) {
            if (best <= target.times[i]) highest = int(i);
        }
        return highest;
    }

    // Settings are 1080p-relative; retain the user-approved 58px / +3px defaults.
    vec2 GetMenuBadgeOffset(float scale) {
        return vec2(float(PML_MenuOffsetX) * scale,
                    float(PML_MenuOffsetY) * scale);
    }

    float GetMenuBadgeSize(float scale) {
        return float(PML_MenuBadgeSize) * scale;
    }

    void RenderCampaignBadges() {
        if (menuUids.Length != 25 || menuTextures.Length != 3 ||
                menuPbs.IsEmpty())
            return;
        CGameManialinkPage@ page = FindFallMenuPage();
        if (page is null) return;
        float unit = Math::Min(float(Display::GetWidth()) / 320.0f,
                               float(Display::GetHeight()) / 180.0f);
        float scale = float(Display::GetHeight()) / 1080.0f;
        float size = GetMenuBadgeSize(scale);
        vec2 offset = GetMenuBadgeOffset(scale);
        vec2 gridSpacing;
        bool hasGrid = GetFallGridSpacing(page, gridSpacing);

        nvg::Save();
        try {
            for (uint i = 0; i < menuUids.Length; i++) {
                uint pb = 0;
                if (!menuPbs.Get(menuUids[i], pb)) continue;
                MenuTarget@ goal;
                if (!menuTargets.Get(menuUids[i], @goal) || goal is null)
                    continue;
                int level = HighestMenuBadge(goal, pb);
                if (level < 0 || menuTextures[uint(level)] is null) continue;

                CGameManialinkFrame@ frame =
                    cast<CGameManialinkFrame@>(page.GetFirstChild(
                        "frame-map-" + (i / 5) + "-" + (i % 5)));
                if (frame is null || !frame.Visible) continue;
                CGameManialinkControl@ medal = frame.GetFirstChild("quad-medal");
                vec3 pos;
                if (medal !is null && medal.Visible) pos = medal.AbsolutePosition;
                else {
                    if (!hasGrid) continue;
                    pos = frame.AbsolutePosition;
                    pos.x += gridSpacing.x * 0.72f;
                    pos.y += gridSpacing.y * 0.35f;
                }

                float x = float(Display::GetWidth()) * 0.5f +
                          pos.x * unit + offset.x;
                float y = float(Display::GetHeight()) * 0.5f -
                          pos.y * unit + offset.y;
                if (x < 0 || y < 0 || x + size > Display::GetWidth() ||
                        y + size > Display::GetHeight())
                    continue;
                nvg::BeginPath();
                nvg::Rect(x, y, size, size);
                nvg::FillPaint(nvg::TexturePattern(vec2(x, y), vec2(size, size),
                    0.0f, menuTextures[uint(level)], 1.0f));
                nvg::Fill();
                nvg::ClosePath();
            }
        } catch {
            menuStatus = "Menu modifié : dessin différé";
        }
        nvg::Restore();
    }
}
