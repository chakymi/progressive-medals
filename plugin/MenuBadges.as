// Fall 2026 campaign badge rendering extracted from the user's original
// ProgressiveMedals/MenuBadges.as and adapted to Lite's Google API architecture.
// This is an NVG overlay, NOT a modification of Trackmania's native UI.
// Deliberately limited to Fall 2026: later campaigns need dynamic playlist data.

namespace PML {
    class MenuTarget {
        uint[] times;
    }

    string[] menuUids;
    dictionary menuTargets; // Immutable 25-map published snapshot for this menu.
    dictionary menuPbs;     // Official records for current logged-in player only.
    nvg::Texture@[] menuTextures;
    string menuAccount = "";
    string menuStatus = "En attente du menu Fall 2026";
    uint64 menuLastAttempt = 0;
    bool menuLoading = false;
    const uint64 PB_MIN_REFRESH_MS = 1800000; // At most once every 30 minutes.

    void InitMenuBadges() {
        try {
            Json::Value@ root = Json::FromFile("catalog/fall-2026-goals.json");
            if (root is null || root.GetType() != Json::Type::Object ||
                    !root.HasKey("campaign") || string(root.Get("campaign")) != "Fall 2026" ||
                    !root.HasKey("maps")) throw("Fichier de catalogue Fall 2026 invalide");
            const Json::Value@ maps = root.Get("maps");
            if (maps is null || maps.GetType() != Json::Type::Array || maps.Length != 25)
                throw("La liste du menu doit comporter 25 cartes");
            dictionary seen;
            for (uint i = 0; i < maps.Length; i++) {
                const Json::Value@ row = maps[i];
                if (row is null || row.GetType() != Json::Type::Object || !row.HasKey("uid") ||
                        !row.HasKey("platinum_ms") || !row.HasKey("emerald_ms") ||
                        !row.HasKey("diamond_ms")) throw("Ligne de catalogue incomplète");
                string uid = string(row.Get("uid"));
                if (!IsValidUid(uid) || seen.Exists(uid)) throw("UID invalide ou dupliqué");
                uint p = 0; uint e = 0; uint d = 0;
                if (!ReadPositiveMs(row, "platinum_ms", p) ||
                        !ReadPositiveMs(row, "emerald_ms", e) ||
                        !ReadPositiveMs(row, "diamond_ms", d))
                    throw("Temps de médaille non numériques");
                uint[] values = {p, e, d};
                if (values[2] == 0 || values[0] > MAX_TIME_MS ||
                        values[0] < values[1] || values[1] < values[2])
                    throw("Temps publiés invalides");
                MenuTarget@ target = MenuTarget();
                target.times = values;
                menuTargets.Set(uid, @target);
                menuUids.InsertLast(uid);
                seen.Set(uid, true);
            }
            menuStatus = "25 cartes Fall 2026 chargées, PB en attente";
        } catch {
            menuUids.RemoveRange(0, menuUids.Length);
            menuTargets.DeleteAll();
            menuStatus = "Catalogue Fall 2026 indisponible";
            warn("Progressive Medals Lite Menu : " + getExceptionInfo());
        }
        const string[] icons = {"assets/platinum.png", "assets/emerald.png", "assets/diamond.png"};
        for (uint i = 0; i < icons.Length; i++) {
            nvg::Texture@ image;
            try { @image = nvg::LoadTexture(icons[i], int(nvg::TextureFlags::GenerateMipmaps)); }
            catch { warn("Progressive Medals Lite Menu : PNG manquant : " + icons[i]); }
            menuTextures.InsertLast(image);
        }
    }

    // Verified against the menu lookup and anchor logic of ProgressiveMedals 0.3.
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
                CGameManialinkLabel@ title = cast<CGameManialinkLabel@>(page.GetFirstChild("label-title"));
                if (title is null) continue;
                string caption = Text::StripFormatCodes(string(title.Value)).ToLower();
                if (!caption.Contains("2026") ||
                        (!caption.Contains("automne") && !caption.Contains("fall"))) continue;
                CGameManialinkControl@ zoneTab = page.GetFirstChild("frame-zone-selection");
                CGameManialinkControl@ clubTab = page.GetFirstChild("frame-pinned-club");
                if ((zoneTab !is null && zoneTab.Visible) ||
                        (clubTab !is null && clubTab.Visible)) continue;
                return page;
            }
        } catch { /* Menus can be rebuilt while navigating. */ }
        return null;
    }

    bool GetFallGridSpacing(CGameManialinkPage@ page, vec2 &out spacing) {
        if (page is null) return false;
        CGameManialinkFrame@ first = cast<CGameManialinkFrame@>(page.GetFirstChild("frame-map-0-0"));
        CGameManialinkFrame@ right = cast<CGameManialinkFrame@>(page.GetFirstChild("frame-map-1-0"));
        CGameManialinkFrame@ below = cast<CGameManialinkFrame@>(page.GetFirstChild("frame-map-0-1"));
        if (first is null || right is null || below is null) return false;
        vec3 p = first.AbsolutePosition;
        vec3 r = right.AbsolutePosition;
        vec3 b = below.AbsolutePosition;
        spacing = vec2(r.x - p.x, b.y - p.y);
        return spacing.x >= 8.0f && spacing.x <= 80.0f &&
               spacing.y <= -3.0f && spacing.y >= -45.0f;
    }

    bool IsMenuUid(const string &in uid) {
        for (uint i = 0; i < menuUids.Length; i++) if (menuUids[i] == uid) return true;
        return false;
    }

    // Uses the same grouped PB route as the original working plugin, only
    // when the map medal menu is open (one request for the 25 cards).
    // No Nadeo leaderboard requests are performed for medal target times.
    void FetchCampaignPbs() {
        if (menuLoading || menuUids.Length != 25) return;
        if (menuLastAttempt != 0 && Time::Now - menuLastAttempt < PB_MIN_REFRESH_MS) return;
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
        menuStatus = "Lecture groupée des PB de Fall 2026…";
        try {
            string account = NadeoServices::GetAccountID();
            if (account.Length == 0) throw("Compte Nadeo non disponible");

            // Same validated batch request as for TOTD (OfficialPbs.as).
            dictionary next;
            ReadOfficialPbs(menuUids, next);
            if (NadeoServices::GetAccountID() != account)
                throw("Le compte a changé pendant le chargement");
            // Do not overwrite verified local improvements with an older score.
            for (uint i = 0; i < menuUids.Length; i++) {
                uint previous = 0; uint fresh = 0;
                if (menuAccount == account && menuPbs.Get(menuUids[i], previous) &&
                        next.Get(menuUids[i], fresh) && previous < fresh)
                    next.Set(menuUids[i], previous);
            }
            if (!next.IsEmpty() || menuPbs.IsEmpty() || account != menuAccount)
                menuPbs = next;
            menuAccount = account;
            menuStatus = "PB chargés : " + menuPbs.GetSize() + "/25";
        } catch {
            menuStatus = "Impossible de récupérer les PB (nouvel essai différé)";
            warn("Progressive Medals Lite Menu : " + getExceptionInfo());
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
                menuStatus = "Compte changé : PB à relire";
            }
            if (PML_ShowMenuBadges && menuUids.Length == 25 &&
                    FindFallMenuPage() !is null && !menuLoading)
                FetchCampaignPbs();
            sleep(2500);
        }
    }

    void RememberMenuPb(const string &in uid, uint best) {
        if (best == 0 || best == uint(-1) || !IsMenuUid(uid) ||
                !NadeoServices::IsAuthenticated("NadeoLiveServices")) return;
        string account = NadeoServices::GetAccountID();
        if (account.Length == 0) return;
        if (menuAccount.Length > 0 && menuAccount != account) {
            menuPbs.DeleteAll();
        }
        menuAccount = account;
        uint previous = 0;
        if (!menuPbs.Get(uid, previous) || best < previous) menuPbs.Set(uid, best);
    }

    // Shared by campaign and TOTD. Index: 0 Platinum, 1 Emerald, 2 Diamond.
    int HighestBadge(const uint[] &in times, uint best) {
        if (best == 0 || best > MAX_TIME_MS || times.Length != 3) return -1;
        int highest = -1;
        for (uint i = 0; i < 3; i++) {
            if (best <= times[i]) highest = int(i);
        }
        return highest;
    }

    void RenderCampaignBadges() {
        if (menuUids.Length != 25 || menuTextures.Length != 3 || menuPbs.IsEmpty()) return;
        CGameManialinkPage@ page = FindFallMenuPage();
        if (page is null) return;
        float unit = Math::Min(float(Display::GetWidth()) / 320.0f,
                               float(Display::GetHeight()) / 180.0f);
        float scale = float(Display::GetHeight()) / 1080.0f;
        float size = float(PML_MenuBadgeSize) * scale;
        vec2 offset = vec2(float(PML_MenuOffsetX) * scale,
                           float(PML_MenuOffsetY) * scale);
        vec2 gridSpacing;
        bool hasGrid = GetFallGridSpacing(page, gridSpacing);
        nvg::Save();
        try {
            for (uint i = 0; i < menuUids.Length; i++) {
                uint pb = 0;
                if (!menuPbs.Get(menuUids[i], pb)) continue;
                MenuTarget@ goal;
                if (!menuTargets.Get(menuUids[i], @goal) || goal is null) continue;
                int level = HighestBadge(goal.times, pb);
                if (level < 0 || menuTextures[uint(level)] is null) continue;
                CGameManialinkFrame@ frame = cast<CGameManialinkFrame@>(
                    page.GetFirstChild("frame-map-" + (i / 5) + "-" + (i % 5)));
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
                float x = float(Display::GetWidth()) * 0.5f + pos.x * unit + offset.x;
                float y = float(Display::GetHeight()) * 0.5f - pos.y * unit + offset.y;
                if (x < 0 || y < 0 || x + size > Display::GetWidth() ||
                        y + size > Display::GetHeight()) continue;
                nvg::BeginPath();
                nvg::Rect(x, y, size, size);
                nvg::FillPaint(nvg::TexturePattern(vec2(x, y), vec2(size, size),
                              0.0f, menuTextures[uint(level)], 1.0f));
                nvg::Fill();
                nvg::ClosePath();
            }
        } catch {
            menuStatus = "Menu modifié : rendu des badges différé";
        }
        nvg::Restore();
    }
}
