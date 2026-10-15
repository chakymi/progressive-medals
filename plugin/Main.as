[Setting name="Afficher la fenêtre" category="Affichage"]
bool S_ShowWindow = true;

[Setting name="Afficher Warrior (si installé)" category="Affichage"]
bool S_ShowWarrior = true;

[Setting name="Catalogue public HTTPS (facultatif)" description="Catalogue commun publié par chakymi ; vider pour rester hors ligne." category="Catalogue"]
string S_CatalogUrl = "https://chakymi.github.io/progressive-medals/catalogue.json";

[Setting name="Catalogue mondial Supabase HTTPS (nouvelles cartes)" description="RPC publique des médailles de rang mondial ; le catalogue historique reste indépendant." category="Catalogue"]
string S_WorldCatalogUrl = "https://mfopepdzllvyefwnxvqh.supabase.co/rest/v1/rpc/pm_public_catalog";

[Setting name="Rechercher automatiquement les nouvelles versions" description="Une vérification au démarrage puis toutes les heures si une URL HTTPS publique est configurée. Aucun WR individuel n'est interrogé." category="Catalogue"]
bool S_AutoUpdates = true;

[Setting name="Badges acquis sur la campagne Fall 2026" category="Affichage"]
bool S_MenuBadges = true;

[Setting name="Position horizontale des badges (px à 1080p)" category="Affichage" min=-120 max=120]
int S_MenuBadgeOffsetX = -8;

[Setting name="Position verticale des badges (px à 1080p)" category="Affichage" min=-120 max=120]
int S_MenuBadgeOffsetY = -29;

[Setting name="Taille des badges (px à 1080p)" category="Affichage" min=16 max=100]
int S_MenuBadgeSize = 56;

[Setting name="Fenêtre des positions" category="Affichage"]
bool S_ShowPositionsWindow = false;

[Setting name="Afficher le HUD pendant la course" category="HUD"]
bool S_ShowRaceHud = true;

[Setting name="Afficher aussi Bronze, Argent, Or et Champion" description="Champion est affiché uniquement comme référence externe s'il est disponible." category="HUD"]
bool S_RaceHudAllMedals = false;

[Setting name="Masquer le HUD avec l'interface du jeu" category="HUD"]
bool S_HideRaceHudWithGameUI = true;

namespace PM {
    string currentUid = "";
    string currentTitle = "";
    uint currentAuthor = 0;
    uint currentPb = 0;
    uint64 currentMapChangedAt = 0;
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
            currentMapChangedAt = Time::Now;
            positionsUid = "";
            positionsStatus = "Aucune recherche lancée pour cette carte";
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
            if (best != uint(-1) && best > 0) {
                if (currentPb == 0 || best < currentPb) {
                    currentPb = best;
                    menuNeedsRefresh = true;
                }
                if (best == currentPb) RememberOfficialPb(uid, best);
            }
        } catch {
            // The score manager can be absent during loading or in unsupported modes.
        }
    }
}

void Main() {
    PM::LoadIcons();
    PM::LoadCatalog();
    PM::LoadWorldCache();
    PM::InitMenuBadges();
    NadeoServices::AddAudience("NadeoLiveServices");
    startnew(PM::AutoRefreshLoop);
    startnew(PM::WorldRefreshLoop);
    startnew(PM::MenuBadgeLoop);
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
    if (UI::MenuItem("Progressive Medals — positions", "", S_ShowPositionsWindow)) S_ShowPositionsWindow = !S_ShowPositionsWindow;
}

void RenderInterface() {
    if (S_ShowWindow) PM::RenderWindow();
    if (S_ShowPositionsWindow) PM::RenderPositionsWindow();
}

void Render() {
    PM::RenderCampaignBadges();
    PM::RenderRaceHud();
}
