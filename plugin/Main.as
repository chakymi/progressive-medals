[Setting name="Afficher la fenêtre" category="Affichage"]
bool S_ShowWindow = true;

[Setting name="Afficher Warrior (si installé)" category="Affichage"]
bool S_ShowWarrior = true;

[Setting name="Catalogue public HTTPS (facultatif)" description="URL d'un JSON publié, sans jeton ni identifiant. Actualisation manuelle." category="Catalogue"]
string S_CatalogUrl = "";

[Setting name="Rechercher automatiquement les nouvelles versions" description="Une vérification au démarrage puis toutes les heures si une URL HTTPS publique est configurée. Aucun WR individuel n'est interrogé." category="Catalogue"]
bool S_AutoUpdates = true;

namespace PM {
    string currentUid = "";
    string currentTitle = "";
    uint currentAuthor = 0;
    uint currentPb = 0;
    bool demo = false;
    uint demoIndex = 0;
    const string[] DEMOS = {"DEMO-PROGRESSIVE-001", "DEMO-PROGRESSIVE-002", "DEMO-PROGRESSIVE-003"};

    void PollMap() {
        if (demo) {
            string uid = DEMOS[demoIndex];
            MapGoals@ sample = FindGoals(uid);
            currentUid = uid;
            currentTitle = sample is null ? "Démo indisponible" : "[DÉMO] " + sample.name;
            currentAuthor = sample is null ? 0 : sample.authorMs;
            return;
        }
        CGameCtnApp@ app = GetApp();
        if (app is null || app.RootMap is null) {
            currentUid = ""; currentTitle = "Aucune carte chargée"; currentAuthor = 0; currentPb = 0;
            return;
        }
        string uid = app.RootMap.IdName;
        if (uid != currentUid) {
            currentUid = uid;
            currentPb = 0;
            trace("Progressive Medals: carte changée " + uid);
        }
        currentTitle = app.RootMap.MapName;
        uint author = app.RootMap.TMObjective_AuthorTime;
        currentAuthor = author == uint(-1) ? 0 : author;
        // Native score manager; no external account, leaderboard request or local PB overwrite.
        try {
            CTrackManiaNetwork@ network = cast<CTrackManiaNetwork>(app.Network);
            if (network is null || network.ClientManiaAppPlayground is null) return;
            CGameUserManagerScript@ users = network.ClientManiaAppPlayground.UserMgr;
            CGameScoreAndLeaderBoardManagerScript@ scores = network.ClientManiaAppPlayground.ScoreMgr;
            if (users is null || scores is null || users.Users.Length == 0) return;
            uint best = uint(scores.Map_GetRecord_v2(users.Users[0].Id, uid, "PersonalBest", "", "TimeAttack", ""));
            if (best != uint(-1) && best > 0 && (currentPb == 0 || best < currentPb)) currentPb = best;
        } catch {
            // The score manager can be absent during loading or in unsupported modes.
        }
    }
}

void Main() {
    PM::LoadIcons();
    PM::LoadCatalog();
    startnew(PM::AutoRefreshLoop);
#if DEPENDENCY_ULTIMATEMEDALSEXTENDED
    RegisterUme();
#endif
    while (true) {
        PM::PollMap();
        sleep(750);
    }
}

void OnDestroyed() {
#if DEPENDENCY_ULTIMATEMEDALSEXTENDED
    UnregisterUme();
#endif
}

void RenderMenu() {
    if (UI::MenuItem("Progressive Medals", "", S_ShowWindow)) S_ShowWindow = !S_ShowWindow;
}

void RenderInterface() {
    if (S_ShowWindow) PM::RenderWindow();
}
