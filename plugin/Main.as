// Progressive Medals: custom medal targets and local menu badges for TM2020.
// The backend publishes target times; this plugin only displays them.

[Setting name="Afficher Progressive Medals Lite" category="Affichage"]
bool PML_ShowWindow = true;

[Setting name="Badges dans le menu Fall 2026" category="Menu"]
bool PML_ShowMenuBadges = true;

[Setting name="Décalage X des badges menu (px 1080p)" category="Menu" min=-120 max=120]
int PML_MenuOffsetX = 3;

[Setting name="Décalage Y des badges menu (px 1080p)" category="Menu" min=-120 max=120]
int PML_MenuOffsetY = -28;

[Setting name="Taille des badges menu (px 1080p)" category="Menu" min=16 max=100]
int PML_MenuBadgeSize = 58;

[Setting name="Récupération automatique des temps" category="Réseau"]
bool PML_AutoFetch = true;

namespace PML {
    const string API_BASE = "https://script.google.com/macros/s/AKfycbwxQH-Tlga1v2Bbg1iesNDuCThGVPG12IgnDDsGKqSf1tKYQXofs3IKAjFmwPSJ1H_f/exec";
    const string[] KEYS = {"platinum", "emerald", "diamond"};
    const string[] NAMES = {"Platine", "Émeraude", "Diamant"};
    const string[] ICON_PATHS = {"assets/platinum.png", "assets/emerald.png", "assets/diamond.png"};
    const uint MAX_TIME_MS = 86400000;
    const uint64 RETRY_INTERVAL_MS = 600000; // Retry missing/unavailable maps after 10 min.
    const uint64 HTTP_TIMEOUT_MS = 12000;

    class Goals {
        uint[] times;
    }

    string currentUid = "";
    string currentTitle = "Aucune carte chargée";
    uint currentPb = 0;
    string status = "En attente d'une carte";
    string lastAttemptUid = "";
    uint64 lastAttemptAt = 0;
    bool fetching = false;
    bool forceRefresh = false;
    dictionary publishedByUid; // In-memory cache, populated only with complete triplets.
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

    // A valid API response is a positive integer in milliseconds, or -1.
    // Reject HTML, JSON errors, decimal seconds and unexpectedly long responses.
    bool ParseApiTime(const string &in raw, uint &out value, bool &out unpublished) {
        value = 0;
        unpublished = false;
        if (raw.Length == 0 || raw.Length > 32) return false;
        string cleaned = "";
        for (uint i = 0; i < raw.Length; i++) {
            uint8 c = raw[i];
            if (c == 32 || c == 9 || c == 10 || c == 13) continue;
            cleaned += raw.SubStr(i, 1);
        }
        if (cleaned == "-1") { unpublished = true; return true; }
        if (cleaned.Length == 0 || cleaned.Length > 8) return false;
        uint parsed = 0;
        for (uint i = 0; i < cleaned.Length; i++) {
            uint8 c = cleaned[i];
            if (c < 48 || c > 57) return false;
            parsed = parsed * 10 + (c - 48);
        }
        if (parsed == 0 || parsed > MAX_TIME_MS) return false;
        value = parsed;
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
            status = "Carte détectée";
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
            if (best > 0 && best != uint(-1)) {
                currentPb = best;
                RememberMenuPb(uid, best);
            }
        } catch {
            // The score manager is not always exposed during loading or in menus.
        }
    }

    // One request per medal, performed only when a map needs fetching.
    // This function runs in a coroutine; it never runs inside Render().
    bool FetchOne(const string &in uid, const string &in medal, uint &out timeMs, bool &out unpublished) {
        timeMs = 0;
        unpublished = false;
        if (!IsValidUid(uid)) return false;
        string url = API_BASE + "?uid=" + uid + "&medal=" + medal;
        Net::HttpRequest@ request = Net::HttpGet(url);
        uint64 started = Time::Now;
        while (!request.Finished()) {
            if (Time::Now - started > HTTP_TIMEOUT_MS || request.ProgressDownload() > 1024) {
                request.Cancel();
                return false;
            }
            sleep(100);
        }
        if (request.ResponseCode() != 200 || request.ProgressDownload() > 1024) return false;
        return ParseApiTime(request.String(), timeMs, unpublished);
    }

    void FetchCurrentMap() {
        string uid = currentUid;
        if (!IsValidUid(uid) || fetching) return;
        fetching = true;
        lastAttemptUid = uid;
        lastAttemptAt = Time::Now;
        status = "Chargement des trois objectifs…";
        uint[] results;
        bool unpublished = false;
        bool success = true;
        try {
            for (uint i = 0; i < KEYS.Length; i++) {
                if (currentUid != uid) { success = false; break; }
                uint value = 0;
                bool missing = false;
                if (!FetchOne(uid, KEYS[i], value, missing)) { success = false; break; }
                if (missing) { unpublished = true; success = false; break; }
                results.InsertLast(value);
            }
        } catch {
            success = false;
            warn("Progressive Medals Lite: erreur réseau : " + getExceptionInfo());
        }
        if (currentUid == uid) {
            if (success && results.Length == 3 && results[0] >= results[1] && results[1] >= results[2]) {
                Goals@ g = Goals();
                g.times = results;
                publishedByUid.Set(uid, @g);
                status = "Objectifs publiés et mis en cache";
            } else {
                status = unpublished ? "Médailles pas encore publiées" :
                         "API indisponible ou réponse invalide (nouvel essai différé)";
            }
        }
        fetching = false;
    }

    void NetworkWorker() {
        while (true) {
            if (PML_AutoFetch && IsValidUid(currentUid) && !fetching) {
                Goals@ known;
                bool cached = publishedByUid.Get(currentUid, @known) && known !is null;
                bool due = lastAttemptUid != currentUid ||
                           (lastAttemptAt != 0 && Time::Now - lastAttemptAt >= RETRY_INTERVAL_MS);
                if (forceRefresh || (!cached && due)) {
                    forceRefresh = false;
                    FetchCurrentMap();
                }
            }
            sleep(1000);
        }
    }

    void RenderWindow() {
        UI::SetNextWindowSize(400, 330, UI::Cond::FirstUseEver);
        if (UI::Begin("Progressive Medals Lite", PML_ShowWindow)) {
            UI::TextWrapped(currentTitle);
            UI::Text("UID : " + (currentUid.Length == 0 ? "—" : currentUid));
            UI::Text("PB local : " + (currentPb == 0 ? "indisponible" : FormatTime(currentPb)));
            UI::TextDisabled("Réseau : " + status);
            UI::TextWrapped("Menu Fall 2026 : " + menuStatus);
            UI::TextDisabled("Badges obtenus : " + menuPbs.GetSize() + "/25 PB reconnus");
            UI::Separator();
            Goals@ goals;
            if (!publishedByUid.Get(currentUid, @goals) || goals is null) {
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
            if (UI::Button("Réessayer sur cette carte")) forceRefresh = true;
            UI::TextDisabled("Source : API publique Google Apps Script. Aucune requête de classement Nadeo.");
        }
        UI::End();
    }
}

void Main() {
    PML::LoadIcons();
    PML::InitMenuBadges();
    NadeoServices::AddAudience("NadeoLiveServices");
    startnew(PML::NetworkWorker);
    startnew(PML::MenuPbWorker);
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
}
