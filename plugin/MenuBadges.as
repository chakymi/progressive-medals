namespace PM {
    string[] menuUids;
    dictionary menuPbs;
    nvg::Texture@[] menuTextures;
    string menuAccount = ""; // In-memory only. Never written to disk or logged.
    string menuStatus = "Campagne non chargée";
    uint64 menuLastAttempt = 0;
    bool menuLoading = false;
    bool menuNeedsRefresh = false;

    // A native TimeAttack PB already saved before School Mode is still valid.
    // Never use a simulated PB or a result shown only on the finish screen.
    void RememberOfficialPb(const string &in uid, uint best) {
        if (best == 0 || best == uint(-1) || menuUids.Length != 25) return;
        bool inCampaign = false;
        for (uint i = 0; i < menuUids.Length; i++) { if (menuUids[i] == uid) { inCampaign = true; break; } }
        if (!inCampaign) return;
        MapGoals@ goal = FindGoals(uid);
        if (!IsReleased(goal) || (goal.calculationVersion < 5 && best > goal.authorMs)) return;
        if (!NadeoServices::IsAuthenticated("NadeoLiveServices")) return;
        string account = NadeoServices::GetAccountID();
        if (account.Length == 0) return;
        if (menuAccount.Length > 0 && menuAccount != account) menuPbs.DeleteAll();
        menuAccount = account;
        uint previous = 0;
        if (!menuPbs.Get(uid, previous) || best < previous) {
            menuPbs.Set(uid, best);
            menuStatus = menuPbs.GetSize() + "/25 PB natifs déjà lus, autres cartes en attente";
            menuNeedsRefresh = true;
        }
    }

    void InitMenuBadges() {
        menuUids.RemoveRange(0, menuUids.Length);
        try {
            Json::Value@ root = Json::FromFile("catalog/fall-2026-order.json");
            if (root is null || root.GetType() != Json::Type::Object || !root.HasKey("campaign") ||
                    string(root.Get("campaign")) != "Fall 2026" || !root.HasKey("mapUids")) throw("ordre de campagne invalide");
            Json::Value@ list = root.Get("mapUids");
            if (list is null || list.GetType() != Json::Type::Array || list.Length != 25) throw("la campagne doit contenir 25 UID");
            dictionary seen;
            for (uint i = 0; i < 25; i++) {
                Json::Value@ value = list[i];
                if (value is null || value.GetType() != Json::Type::String) throw("UID non textuel");
                string uid = string(value);
                if (uid.Length < 20 || uid.Length > 40 || uid.Contains("/") || seen.Exists(uid)) throw("UID doublon ou invalide");
                seen.Set(uid, true);
                menuUids.InsertLast(uid);
            }
            menuStatus = "25 cartes Fall 2026 prêtes";
        } catch {
            menuUids.RemoveRange(0, menuUids.Length);
            menuStatus = "Ordre des cartes invalide";
            warn("Progressive Medals: ordre menu refusé : " + getExceptionInfo());
        }
        for (uint i = 0; i < COUNT; i++) {
            nvg::Texture@ image;
            // The supplied PNGs are much larger than a menu badge. Mipmaps
            // preserve their colors/detail instead of aliasing bright pixels.
            try { @image = nvg::LoadTexture(ICON_FILES[i], int(nvg::TextureFlags::GenerateMipmaps)); }
            catch { warn("Progressive Medals: texture menu indisponible : " + ICON_FILES[i]); }
            menuTextures.InsertLast(image);
        }
    }

    CGameManialinkPage@ FindFallMenuPage() {
        try {
            CTrackMania@ app = cast<CTrackMania@>(GetApp());
            if (app is null || app.Editor !is null || app.CurrentPlayground !is null || app.MenuManager is null ||
                    app.MenuManager.MenuCustom_CurrentManiaApp is null) return null;
            auto layers = app.MenuManager.MenuCustom_CurrentManiaApp.UILayers;
            for (uint i = 0; i < layers.Length; i++) {
                CGameUILayer@ layer = layers[i];
                if (layer is null || !layer.IsVisible || layer.LocalPage is null) continue;
                CGameManialinkPage@ page = layer.LocalPage;
                if (page.GetFirstChild("frame-map-0-0") is null) continue;
                CGameManialinkLabel@ label = cast<CGameManialinkLabel@>(page.GetFirstChild("label-title"));
                if (label is null) continue;
                string title = Text::StripFormatCodes(string(label.Value)).ToLower();
                if (!title.Contains("2026") || (!title.Contains("automne") && !title.Contains("fall"))) continue;
                // Nadeo reuses the same map frames for rankings by country/club.
                // Draw only while the medals tab is active, never over positions.
                CGameManialinkControl@ zoneTab = page.GetFirstChild("frame-zone-selection");
                CGameManialinkControl@ clubTab = page.GetFirstChild("frame-pinned-club");
                if ((zoneTab !is null && zoneTab.Visible) || (clubTab !is null && clubTab.Visible)) continue;
                return page;
            }
        } catch {
            // Menu pages are destroyed/rebuilt while navigating. Retry on the next frame.
        }
        return null;
    }

    // Measure the displayed grid. The native medal quad is not present in all
    // menu variants; frame spacing provides a bounded fallback anchor without
    // modifying any game controls or borrowing other plugins' coordinates.
    bool GetMenuGridSpacing(CGameManialinkPage@ page, vec2 &out spacing) {
        if (page is null) return false;
        CGameManialinkFrame@ first = cast<CGameManialinkFrame@>(page.GetFirstChild("frame-map-0-0"));
        CGameManialinkFrame@ right = cast<CGameManialinkFrame@>(page.GetFirstChild("frame-map-1-0"));
        CGameManialinkFrame@ below = cast<CGameManialinkFrame@>(page.GetFirstChild("frame-map-0-1"));
        if (first is null || right is null || below is null) return false;
        vec3 p = first.AbsolutePosition;
        vec3 r = right.AbsolutePosition;
        vec3 b = below.AbsolutePosition;
        spacing = vec2(r.x - p.x, b.y - p.y);
        return spacing.x >= 8.0f && spacing.x <= 80.0f && spacing.y <= -3.0f && spacing.y >= -45.0f;
    }

    bool DecodeMenuPbs(const Json::Value@ results, dictionary &out next) {
        if (results is null || results.GetType() != Json::Type::Array || results.Length > 25 || menuUids.Length != 25) return false;
        for (uint i = 0; i < results.Length; i++) {
            const Json::Value@ row = results[i];
            if (row is null || row.GetType() != Json::Type::Object || !row.HasKey("mapUid") || !row.HasKey("groupUid")) return false;
            const Json::Value@ mapUid = row.Get("mapUid");
            const Json::Value@ group = row.Get("groupUid");
            if (mapUid is null || mapUid.GetType() != Json::Type::String || group is null ||
                    group.GetType() != Json::Type::String || string(group) != "Personal_Best") return false;
            string uid = string(mapUid);
            bool inCampaign = false;
            for (uint j = 0; j < menuUids.Length; j++) { if (menuUids[j] == uid) { inCampaign = true; break; } }
            uint pb = 0;
            if (!inCampaign || next.Exists(uid) || !ReadInt(row, "score", pb)) return false;
            next.Set(uid, pb);
        }
        return true;
    }

    string CheckMenuLoader() {
        if (menuUids.Length != 25 || menuTextures.Length != COUNT) return "Menu : roster ou textures incomplets";
        try {
            string uid = menuUids[5];
            string one = "[{\"mapUid\":\"" + uid + "\",\"groupUid\":\"Personal_Best\",\"score\":26964}]";
            dictionary correct;
            if (!DecodeMenuPbs(Json::Parse(one), correct) || correct.GetSize() != 1) return "Menu : PB officiel de test refusé";
            dictionary duplicate;
            if (DecodeMenuPbs(Json::Parse("[" + one.SubStr(1, one.Length - 2) + "," + one.SubStr(1, one.Length - 2) + "]"), duplicate))
                return "Menu : PB doublon accepté";
            Json::Value@ rank = Json::Parse("{\"mapUid\":\"" + uid + "\",\"tops\":[{\"zoneId\":\"301e1b69-7e13-11e8-8060-e284abfd2bc4\",\"top\":[{\"score\":26894,\"position\":641}]}]}");
            if (ParseWorldPosition(rank, uid, 26894) != 641 || ParseWorldPosition(rank, uid, 26893) != -1)
                return "Positions : parseur de rang incohérent";
            CGameManialinkPage@ page = FindFallMenuPage();
            if (page is null) return "Menu OK : 25 UID, PB et rang validés ; ouvrir l'onglet Médailles Fall 2026 pour tester les badges";
            CGameManialinkFrame@ frame = cast<CGameManialinkFrame@>(page.GetFirstChild("frame-map-0-0"));
            if (frame is null) return "Menu détecté sans première case native";
            vec2 spacing;
            CGameManialinkControl@ medal = frame.GetFirstChild("quad-medal");
            if (medal !is null && medal.Visible)
                return "Menu OK : ancre de médaille native et " + menuPbs.GetSize() + " PB disponibles";
            if (!GetMenuGridSpacing(page, spacing))
                return "Menu détecté, mais cadres voisins introuvables ; " + menuPbs.GetSize() + " PB disponibles";
            return "Menu OK : ancre par cases (écart " + spacing.x + "/" + spacing.y + "), " +
                menuPbs.GetSize() + " PB disponibles";
        } catch { return "Menu : vérification interrompue : " + getExceptionInfo(); }
    }

    void RefreshMenuPbs() {
        if (menuLoading || menuUids.Length != 25) return;
        if (menuLastAttempt != 0 && Time::Now - menuLastAttempt < 300000) {
            menuStatus = "Attendre 5 minutes entre les demandes de PB officiels"; return;
        }
        if (!Permissions::ViewRecords()) {
            menuStatus = menuPbs.IsEmpty() ? "Classements fermés : aucun PB encore lu" :
                "Classements fermés : " + menuPbs.GetSize() + " PB natifs déjà lus restent affichables";
            return;
        }
        if (!NadeoServices::IsAuthenticated("NadeoLiveServices")) { menuStatus = "Authentification Nadeo en attente"; return; }
        menuLastAttempt = Time::Now;
        menuLoading = true;
        menuStatus = "Lecture des PB officiels (25 cartes)...";
        try {
            string account = NadeoServices::GetAccountID();
            if (account.Length == 0) throw("compte indisponible");
            string body = "{\"maps\":[";
            for (uint i = 0; i < menuUids.Length; i++) {
                if (i > 0) body += ",";
                body += "{\"mapUid\":\"" + menuUids[i] + "\",\"groupUid\":\"Personal_Best\"}";
            }
            body += "]}";
            Net::HttpRequest@ request = NadeoServices::Post("NadeoLiveServices",
                NadeoServices::BaseURLLive() + "/api/token/leaderboard/group/map", body);
            request.Start();
            uint64 started = Time::Now;
            while (!request.Finished()) {
                if (Time::Now - started > 12000 || request.ProgressDownload() > 65536) {
                    request.Cancel(); throw("lecture des PB expirée ou trop volumineuse");
                }
                sleep(100);
            }
            if (request.ResponseCode() != 200 || request.ProgressDownload() > 65536) throw("service PB indisponible");
            string response = request.String();
            if (response.Length > 65536) throw("réponse PB trop volumineuse");
            Json::Value@ results = Json::Parse(response);
            dictionary next;
            if (!DecodeMenuPbs(results, next)) throw("réponse PB invalide ou en doublon");
            if (NadeoServices::GetAccountID() != account) throw("compte changé pendant le chargement");
            if (results.Length == 0 && menuPbs.GetSize() > 0 && menuAccount == account) {
                menuStatus = "Réponse vide : anciens PB conservés sans rafraîchissement";
            } else {
                menuPbs = next;
                menuAccount = account;
                menuStatus = menuPbs.GetSize() + "/25 PB officiels disponibles";
                menuNeedsRefresh = false;
            }
        } catch {
            menuStatus = "PB de campagne indisponibles (nouvel essai différé)";
            warn("Progressive Medals: lecture groupée des PB impossible : " + getExceptionInfo());
        }
        menuLoading = false;
    }

    void MenuBadgeLoop() {
        while (true) {
            if (menuAccount.Length > 0 && (!NadeoServices::IsAuthenticated("NadeoLiveServices") ||
                    NadeoServices::GetAccountID() != menuAccount)) {
                menuPbs.DeleteAll(); menuAccount = ""; menuLastAttempt = 0;
                menuStatus = "Compte changé : PB à relire";
            }
            if (S_MenuBadges && catalogVersion >= 4 && FindFallMenuPage() !is null && !menuLoading &&
                    (menuLastAttempt == 0 || Time::Now - menuLastAttempt >= 1800000 ||
                     (menuNeedsRefresh && Time::Now - menuLastAttempt >= 300000))) RefreshMenuPbs();
            sleep(2000);
        }
    }

    void RenderCampaignBadges() {
        if (!S_MenuBadges || catalogVersion < 4 || menuPbs.IsEmpty() || menuUids.Length != 25 || menuTextures.Length != COUNT) return;
        CGameManialinkPage@ page = FindFallMenuPage();
        if (page is null) return;
        float unit = Math::Min(float(Display::GetWidth()) / 320.0f, float(Display::GetHeight()) / 180.0f);
        float resolutionScale = float(Display::GetHeight()) / 1080.0f;
        float size = float(S_MenuBadgeSize) * resolutionScale;
        vec2 gridSpacing;
        bool hasGrid = GetMenuGridSpacing(page, gridSpacing);
        nvg::Save();
        try {
            for (uint i = 0; i < menuUids.Length; i++) {
                uint pb = 0;
                if (!menuPbs.Get(menuUids[i], pb)) continue;
                MapGoals@ goals = FindGoals(menuUids[i]);
                if (!IsReleased(goals)) continue;
                int level = HighestLevel(goals, pb);
                if (level < 0 || menuTextures[uint(level)] is null) continue;
                string frameId = "frame-map-" + (i / 5) + "-" + (i % 5);
                CGameManialinkFrame@ frame = cast<CGameManialinkFrame@>(page.GetFirstChild(frameId));
                if (frame is null || !frame.Visible) continue;
                CGameManialinkControl@ nativeMedal = frame.GetFirstChild("quad-medal");
                vec3 pos;
                if (nativeMedal !is null && nativeMedal.Visible) {
                    pos = nativeMedal.AbsolutePosition;
                } else {
                    if (!hasGrid) continue;
                    pos = frame.AbsolutePosition;
                    pos.x += gridSpacing.x * 0.72f;
                    pos.y += gridSpacing.y * 0.35f;
                }
                float x = float(Display::GetWidth()) * 0.5f + pos.x * unit + float(S_MenuBadgeOffsetX) * resolutionScale;
                float y = float(Display::GetHeight()) * 0.5f - pos.y * unit + float(S_MenuBadgeOffsetY) * resolutionScale;
                if (x < 0 || y < 0 || x + size > Display::GetWidth() || y + size > Display::GetHeight()) continue;
                nvg::BeginPath();
                nvg::Rect(x, y, size, size);
                nvg::FillPaint(nvg::TexturePattern(vec2(x, y), vec2(size, size), 0.0f, menuTextures[uint(level)], 1.0f));
                nvg::Fill();
                nvg::ClosePath();
            }
        } catch {
            menuStatus = "Rendu du menu indisponible après changement d'écran";
        }
        nvg::Restore();
    }
}
