// Progressive Medals : objectifs publiés dans Google Sheets, PB lus via Nadeo.
// Les badges sont dessinés par-dessus les menus, sans les modifier.
// Conserver les fonctions de rendu testées avant toute refonte des menus.

[Setting name="Afficher Progressive Medals Lite" category="Affichage"]
bool PML_ShowWindow = true;

[Setting name="Badges dans le menu Fall 2026" category="Menu"]
bool PML_ShowMenuBadges = true;

[Setting name="Décalage X des badges menu (px 1080p)" category="Menu" min=-120 max=120]
int PML_MenuOffsetX = 3;

[Setting name="Décalage Y des badges menu (px 1080p)" category="Menu" min=-120 max=120]
int PML_MenuOffsetY = -28;

[Setting name="Taille des badges menu (px 1080p)" category="Menu" min=16 max=100]
int PML_MenuBadgeSize = 61;

[Setting name="Afficher les badges sur le calendrier TOTD" category="TOTD"]
bool PML_ShowTotdBadges = true;

[Setting name="Décalage horizontal TOTD (px 1080p)" category="TOTD" min=-120 max=120]
int PML_TotdOffsetX = -4;

[Setting name="Décalage vertical TOTD (px 1080p)" category="TOTD" min=-120 max=120]
int PML_TotdOffsetY = -28;

[Setting name="Taille des badges TOTD (px 1080p)" category="TOTD" min=16 max=100]
int PML_TotdBadgeSize = 56;

[Setting name="Récupération automatique des temps" category="Réseau"]
bool PML_AutoFetch = true;

namespace PML {
    const string[] KEYS = {"platinum", "emerald", "diamond"};
    const string[] NAMES = {"Platine", "Émeraude", "Diamant"};
    const string[] ICON_PATHS = {"assets/platinum.png", "assets/emerald.png", "assets/diamond.png"};
    const uint MAX_TIME_MS = 86400000;

    class Goals {
        uint[] times;
    }

    string currentUid = "";
    string currentTitle = "Aucune carte chargée";
    uint currentPb = 0;
    string status = "En attente d'une carte";
    dictionary publishedByUid; // Medals published in Google Sheets only.
    UI::Texture@[] icons;

    bool IsValidUid(const string &in uid) {
        if (uid.Length < 15 || uid.Length > 80) return false;
        for (uint i = 0; i < uid.Length; i++) {
            uint8 c = uid[i];
            if (!((c >= 48 && c <= 57) || (c >= 65 && c <= 90) ||
                    (c >= 97 && c <= 122) || c == 45 || c == 95)) return false;
        }
        return true;
    }

    string FormatTime(uint ms) {
        uint minutes = ms / 60000;
        uint seconds = (ms / 1000) % 60;
        uint millis = ms % 1000;
        return (minutes < 10 ? "0" : "") + minutes + ":" +
               (seconds < 10 ? "0" : "") + seconds + "." +
               (millis < 100 ? "0" : "") + (millis < 10 ? "0" : "") + millis;
    }

    void LoadIcons() {
        for (uint i = 0; i < ICON_PATHS.Length; i++) {
            UI::Texture@ icon;
            try { @icon = UI::LoadTexture(ICON_PATHS[i]); }
            catch { warn("Progressive Medals Lite: PNG indisponible : " + ICON_PATHS[i]); }
            icons.InsertLast(icon);
        }
    }

    // Reads the game's own local score manager; sends no record queries to Nadeo.
    void PollMapAndLocalPb() {
        CGameCtnApp@ app = GetApp();
        if (app is null || app.RootMap is null) {
            currentUid = "";
            currentTitle = "Aucune carte chargée";
            currentPb = 0;
            return;
        }

        string uid = app.RootMap.IdName;
        if (uid != currentUid) {
            currentUid = uid;
            currentPb = 0;
        }
        currentTitle = app.RootMap.MapName;

        try {
            CTrackManiaNetwork@ network = cast<CTrackManiaNetwork>(app.Network);
            if (network is null || network.ClientManiaAppPlayground is null) return;
            CGameUserManagerScript@ users = network.ClientManiaAppPlayground.UserMgr;
            CGameScoreAndLeaderBoardManagerScript@ scores = network.ClientManiaAppPlayground.ScoreMgr;
            if (users is null || scores is null || users.Users.Length == 0) return;
            uint best = uint(scores.Map_GetRecord_v2(users.Users[0].Id, uid,
                "PersonalBest", "", "TimeAttack", ""));
            if (best > 0 && best != uint(-1) && (currentPb == 0 || best < currentPb))
                currentPb = best;
            if (best > 0 && best != uint(-1)) {
                RememberMenuPb(uid, best);
                RememberTotdPb(uid, best);
            }
        } catch {
            // The score manager is not always exposed during loading or in menus.
        }
    }

    void RenderWindow() {
        UI::SetNextWindowSize(400, 330, UI::Cond::FirstUseEver);
        if (UI::Begin("Progressive Medals Lite", PML_ShowWindow)) {
            UI::TextWrapped(currentTitle);
            UI::Text("UID : " + (currentUid.Length == 0 ? "—" : currentUid));
            UI::Text("PB local : " + (currentPb == 0 ? "indisponible" : FormatTime(currentPb)));
            UI::TextWrapped("Réseau : " + status);
            if (sheetLastError.Length > 0) {
                UI::TextWrapped("Diagnostic Google Sheets : " + sheetLastError);
            }
            UI::TextWrapped("Menu Fall 2026 : " + menuStatus);
            UI::TextDisabled("Badges obtenus : " + menuPbs.GetSize() + "/25 PB reconnus");
            UI::TextWrapped("Calendrier TOTD : " + totdStatus);
            UI::Separator();
            Goals@ goals;
            // A validated Google Sheet snapshot serves the map HUD and menus.
            publishedByUid.Get(currentUid, @goals);
            if (goals is null) {
                UI::TextWrapped("Aucun objectif publié disponible pour cette carte.");
            } else {
                for (uint i = 0; i < KEYS.Length; i++) {
                    if (i < icons.Length && icons[i] !is null) {
                        UI::Image(icons[i], vec2(36, 36));
                        UI::SameLine();
                    }
                    string result = currentPb == 0 ? "PB inconnu" :
                        (currentPb <= goals.times[i] ? "OBTENUE" : "à obtenir");
                    UI::Text(NAMES[i] + " — " + FormatTime(goals.times[i]) + " — " + result);
                }
            }
            if (UI::Button("Actualiser les objectifs Google Sheets")) sheetForceRefresh = true;
            UI::TextDisabled("Objectifs : lecture directe du Google Sheet public (onglet Medals).");
            UI::TextDisabled("Les objectifs ne nécessitent aucune requête de classement Nadeo.");
        }
        UI::End();
    }
}

void Main() {
    PML::LoadIcons();
    PML::InitMenuBadges();
    PML::InitSheetCatalogue(); // Bundled Sheet snapshot, then any newer validated cache.
    NadeoServices::AddAudience("NadeoLiveServices");
    startnew(PML::SheetCatalogueWorker);
    startnew(PML::MenuPbWorker);
    startnew(PML::TotdPbWorker);
    while (true) {
        PML::PollMapAndLocalPb();
        sleep(500);
    }
}

void RenderMenu() {
    if (UI::MenuItem("Progressive Medals Lite", "", PML_ShowWindow))
        PML_ShowWindow = !PML_ShowWindow;
}

void RenderInterface() {
    if (PML_ShowWindow) PML::RenderWindow();
}

// NVG overlay drawn on top of the native menu grid. Never edits game controls.
void Render() {
    if (PML_ShowMenuBadges) PML::RenderCampaignBadges();
    if (PML_ShowTotdBadges) PML::RenderTotdBadges();
}
