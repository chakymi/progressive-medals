// Médailles TOTD dans le calendrier de Trackmania.
// Même approche que le menu de campagne :
//   1. Google Sheets fournit les objectifs (SheetCatalogue.as).
//   2. Nadeo fournit uniquement les records personnels (PB).
//   3. Render() lit les quelques cases visibles et dessine une image NVG.
// Aucun contrôle du jeu n'est modifié. Aucun pointeur vers le menu n'est conservé.
namespace PML {
    const uint64 TOTD_PB_REFRESH_MS = 1800000; // 30 minutes.
    const uint64 TOTD_PB_RETRY_MS = 15000;

    const string[] TOTD_MONTH_FR = {"janvier", "février", "mars", "avril", "mai", "juin",
        "juillet", "août", "septembre", "octobre", "novembre", "décembre"};
    const string[] TOTD_MONTH_EN = {"january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december"};

    // Le catalogue est rempli par SheetCatalogue.as, depuis l'onglet Medals.
    class TotdGoal {
        string uid;
        int year;
        int month;
        int day;
        uint[] times; // Platine, Émeraude, Diamant (millisecondes).
    }

    dictionary totdByUid;  // UID -> TotdGoal@.
    dictionary totdByDate; // AAAAMMJJ -> TotdGoal@.
    uint totdCatalogueVersion = 0;

    dictionary totdPbs; // UID -> meilleur temps du joueur connecté.
    string totdAccount = "";
    string totdStatus = "Calendrier TOTD en attente";
    uint64 totdLastPbAttempt = 0;
    int totdLastMonth = 0;
    uint totdLastPbVersion = 0;
    bool totdPbLoading = false;

    // Ces deux entiers sont les seules données communiquées par le rendu au
    // travailleur réseau. Ce dernier ne lit jamais les contrôles Trackmania.
    int totdVisibleYear = 0;
    int totdVisibleMonth = 0;

    string TotdDateKey(int year, int month, int day) {
        return "" + (year * 10000 + month * 100 + day);
    }

    // 0 = lundi, ... 6 = dimanche. Sert à placer le 1er jour dans la grille.
    int FirstTotdWeekday(int year, int month) {
        if (year < 2021 || year > 2100 || month < 1 || month > 12) return -1;
        const int[] offsets = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};
        int y = month < 3 ? year - 1 : year;
        int sunday = (y + y / 4 - y / 100 + y / 400 + offsets[month - 1] + 1) % 7;
        return (sunday + 6) % 7;
    }

    // Cherche uniquement la page du calendrier. Même vérification de menus
    // que FindFallMenuPage() dans MenuBadges.as. Aucun ControlsCache.
    CGameManialinkPage@ FindTotdPage() {
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
                if (page.GetFirstChild("button-previous-month") is null ||
                        page.GetFirstChild("frame-map-rankings") is null) continue;
                CGameManialinkControl@ zone = page.GetFirstChild("frame-zone-selection");
                CGameManialinkControl@ club = page.GetFirstChild("frame-pinned-club");
                if ((zone !is null && zone.Visible) || (club !is null && club.Visible))
                    continue;
                return page;
            }
        } catch { /* Le menu peut être fermé pendant la navigation. */ }
        return null;
    }

    // Le nombre de cases masquées dans la première ligne donne le jour de
    // semaine du premier jour du mois. On ne lit que sept boutons.
    int FirstVisibleColumn(CGameManialinkPage@ page) {
        if (page is null) return -1;
        int first = -1;
        for (int col = 0; col < 7; col++) {
            CGameManialinkControl@ button = page.GetFirstChild("button-map-" + col + "-0");
            bool visible = button !is null && button.Visible;
            if (visible && first == -1) first = col;
            if (!visible && first != -1) return -1; // Ligne incohérente.
        }
        return first;
    }

    // Si le calendrier expose un titre simple, on peut y lire le mois.
    // Sinon, pour les données actuelles, octobre et novembre 2026 ont un
    // premier jour différent. En cas d'ambiguïté : ne rien afficher.
    bool MonthFromTitle(CGameManialinkPage@ page, int weekday, int &out year, int &out month) {
        CGameManialinkLabel@ label = cast<CGameManialinkLabel@>(page.GetFirstChild("label-title"));
        if (label is null) return false;
        string title = Text::StripFormatCodes(string(label.Value)).ToLower();
        for (int y = 2021; y <= 2100; y++) {
            if (!title.Contains("" + y)) continue;
            for (int m = 1; m <= 12; m++) {
                if (FirstTotdWeekday(y, m) != weekday) continue;
                if (title.Contains(TOTD_MONTH_FR[m - 1]) || title.Contains(TOTD_MONTH_EN[m - 1])) {
                    year = y;
                    month = m;
                    return true;
                }
            }
        }
        return false;
    }

    // Associe le mois visible au catalogue. On évite surtout de poser des
    // badges sur le mauvais mois si plusieurs mois ont la même disposition.
    bool ResolveTotdMonth(CGameManialinkPage@ page, int &out year, int &out month,
                          int &out weekday) {
        weekday = FirstVisibleColumn(page);
        if (weekday < 0) return false;
        if (MonthFromTitle(page, weekday, year, month)) return true;

        string[]@ keys = totdByUid.GetKeys();
        for (uint i = 0; i < keys.Length; i++) {
            TotdGoal@ goal;
            if (!totdByUid.Get(keys[i], @goal) || goal is null ||
                    FirstTotdWeekday(goal.year, goal.month) != weekday) continue;
            if (year != 0 && (year != goal.year || month != goal.month)) return false;
            year = goal.year;
            month = goal.month;
        }
        return year != 0;
    }

    // PB par mois : même route Nadeo groupée que les 25 cartes de campagne.
    // Cette fonction ne lit pas le menu, uniquement les UID déjà publiés.
    void FetchTotdPbs(int year, int month) {
        if (year < 2021 || year > 2100 || month < 1 || month > 12 || totdPbLoading) return;
        int monthKey = year * 100 + month;
        uint64 elapsed = totdLastPbAttempt == 0 ? TOTD_PB_REFRESH_MS :
            Time::Now - totdLastPbAttempt;
        if (totdLastPbAttempt != 0 && elapsed < TOTD_PB_RETRY_MS) return;
        if (totdLastMonth == monthKey && totdLastPbVersion == totdCatalogueVersion &&
                totdLastPbAttempt != 0 && elapsed < TOTD_PB_REFRESH_MS) return;
        if (!Permissions::ViewRecords() || !NadeoServices::IsAuthenticated("NadeoLiveServices")) {
            totdStatus = "En attente des autorisations PB Nadeo";
            return;
        }

        string[] uids;
        for (int day = 1; day <= 31; day++) {
            TotdGoal@ goal;
            if (totdByDate.Get(TotdDateKey(year, month, day), @goal) && goal !is null)
                uids.InsertLast(goal.uid);
        }
        if (uids.Length == 0) {
            totdStatus = "Aucune TOTD publiée pour ce mois";
            return;
        }

        totdPbLoading = true;
        totdLastPbAttempt = Time::Now;
        totdLastMonth = monthKey;
        totdLastPbVersion = totdCatalogueVersion;
        totdStatus = "Récupération des PB TOTD...";
        try {
            string account = NadeoServices::GetAccountID();
            if (account.Length == 0) throw("Compte Nadeo indisponible");
            dictionary received;
            ReadOfficialPbs(uids, received); // OfficialPbs.as, 1 requête groupée.
            if (NadeoServices::GetAccountID() != account) throw("Compte Nadeo modifié");

            if (totdAccount.Length != 0 && totdAccount != account) totdPbs.DeleteAll();
            totdAccount = account;
            for (uint i = 0; i < uids.Length; i++) {
                uint best = 0;
                if (!received.Get(uids[i], best)) continue;
                uint old = 0;
                if (!totdPbs.Get(uids[i], old) || best < old)
                    totdPbs.Set(uids[i], best);
            }
            totdStatus = "PB TOTD chargés : " + received.GetSize() + "/" + uids.Length;
        } catch {
            totdStatus = "PB TOTD indisponibles, prochain essai différé";
            warn("Progressive Medals TOTD : " + getExceptionInfo());
        }
        totdPbLoading = false;
    }

    void TotdPbWorker() {
        while (true) {
            if (totdAccount.Length != 0 &&
                    (!NadeoServices::IsAuthenticated("NadeoLiveServices") ||
                     NadeoServices::GetAccountID() != totdAccount)) {
                totdPbs.DeleteAll();
                totdAccount = "";
                totdLastPbAttempt = 0;
            }
            if (PML_ShowTotdBadges && totdCatalogueVersion > 0 && !totdPbLoading &&
                    totdVisibleYear != 0 && totdVisibleMonth != 0)
                FetchTotdPbs(totdVisibleYear, totdVisibleMonth);
            sleep(2500);
        }
    }

    // Prend en compte immédiatement un PB local obtenu en jouant une TOTD.
    void RememberTotdPb(const string &in uid, uint best) {
        if (best == 0 || best > MAX_TIME_MS || !totdByUid.Exists(uid) ||
                !NadeoServices::IsAuthenticated("NadeoLiveServices")) return;
        string account = NadeoServices::GetAccountID();
        if (account.Length == 0) return;
        if (totdAccount.Length != 0 && totdAccount != account) totdPbs.DeleteAll();
        totdAccount = account;
        uint old = 0;
        if (!totdPbs.Get(uid, old) || best < old) totdPbs.Set(uid, best);
    }

    // Même positionnement de secours que la campagne lorsqu'une case
    // n'a pas encore de médaille native visible.
    bool GetTotdGridSpacing(CGameManialinkPage@ page, int weekday, vec2 &out spacing) {
        if (page is null) return false;
        int col = weekday < 6 ? weekday : 0;
        int row = weekday < 6 ? 0 : 1;
        CGameManialinkFrame@ first = cast<CGameManialinkFrame@>(
            page.GetFirstChild("frame-map-" + col + "-" + row));
        CGameManialinkFrame@ right = cast<CGameManialinkFrame@>(
            page.GetFirstChild("frame-map-" + (col + 1) + "-" + row));
        CGameManialinkFrame@ below = cast<CGameManialinkFrame@>(
            page.GetFirstChild("frame-map-" + col + "-" + (row + 1)));
        if (first is null || right is null || below is null) return false;
        vec3 p = first.AbsolutePosition;
        vec3 r = right.AbsolutePosition;
        vec3 b = below.AbsolutePosition;
        spacing = vec2(r.x - p.x, b.y - p.y);
        return spacing.x >= 8.0f && spacing.x <= 80.0f &&
               spacing.y <= -3.0f && spacing.y >= -45.0f;
    }

    // Aucune boucle dans ControlsCache, aucun cache de pointeurs/manialinks.
    void RenderTotdBadges() {
        if (menuTextures.Length != 3 || totdByDate.IsEmpty()) return;
        CGameManialinkPage@ page = FindTotdPage();
        if (page is null) {
            totdVisibleYear = 0;
            totdVisibleMonth = 0;
            return;
        }

        int year = 0; int month = 0; int weekday = -1;
        if (!ResolveTotdMonth(page, year, month, weekday)) {
            totdVisibleYear = 0;
            totdVisibleMonth = 0;
            totdStatus = "Mois non identifié : aucun badge affiché";
            return;
        }
        totdVisibleYear = year;
        totdVisibleMonth = month;
        if (totdPbs.IsEmpty()) return;

        float unit = Math::Min(float(Display::GetWidth()) / 320.0f,
                               float(Display::GetHeight()) / 180.0f);
        float scale = float(Display::GetHeight()) / 1080.0f;
        float size = float(PML_TotdBadgeSize) * scale;
        vec2 offset = vec2(float(PML_TotdOffsetX) * scale,
                           float(PML_TotdOffsetY) * scale);
        vec2 gridSpacing;
        bool hasGrid = GetTotdGridSpacing(page, weekday, gridSpacing);

        nvg::Save();
        try {
            for (int day = 1; day <= 31; day++) {
                TotdGoal@ goal;
                if (!totdByDate.Get(TotdDateKey(year, month, day), @goal) || goal is null)
                    continue;
                uint pb = 0;
                if (!totdPbs.Get(goal.uid, pb)) continue;

                // La campagne et les TOTD partagent le même calcul.
                int level = HighestBadge(goal.times, pb);
                if (level < 0 || menuTextures[uint(level)] is null) continue;

                int index = weekday + day - 1;
                if (index < 0 || index >= 42) continue;
                int col = index % 7;
                int row = index / 7;
                CGameManialinkFrame@ frame = cast<CGameManialinkFrame@>(
                    page.GetFirstChild("frame-map-" + col + "-" + row));
                if (frame is null || !frame.Visible) continue;
                CGameManialinkControl@ button = page.GetFirstChild(
                    "button-map-" + col + "-" + row);
                if (button is null || !button.Visible) continue;
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
            totdStatus = "Calendrier en cours de modification, rendu différé";
        }
        nvg::Restore();
    }
}
