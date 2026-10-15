namespace PM {
    // -1: no result, -2: already obtained (Nadeo cannot query slower scores).
    int[] positionRanks = {-1, -1, -1};
    dictionary positionLastByUid;
    uint64 positionsGlobalAt = 0;
    string positionsUid = "";
    uint positionsVersion = 0;
    string positionsStatus = "Aucune recherche lancée";
    bool positionsLoading = false;

    int ParseWorldPosition(const Json::Value@ root, const string &in uid, uint target) {
        if (root is null || root.GetType() != Json::Type::Object || !root.HasKey("mapUid") ||
                string(root.Get("mapUid")) != uid || !root.HasKey("tops")) return -1;
        const Json::Value@ zones = root.Get("tops");
        if (zones is null || zones.GetType() != Json::Type::Array || zones.Length > 10) return -1;
        for (uint i = 0; i < zones.Length; i++) {
            const Json::Value@ zone = zones[i];
            if (zone is null || zone.GetType() != Json::Type::Object || !zone.HasKey("zoneId") ||
                    string(zone.Get("zoneId")) != "301e1b69-7e13-11e8-8060-e284abfd2bc4" || !zone.HasKey("top")) continue;
            const Json::Value@ entries = zone.Get("top");
            if (entries is null || entries.GetType() != Json::Type::Array || entries.Length > 3) return -1;
            for (uint j = 0; j < entries.Length; j++) {
                const Json::Value@ entry = entries[j];
                uint score = 0;
                if (entry is null || entry.GetType() != Json::Type::Object || !ReadInt(entry, "score", score) || score != target || !entry.HasKey("position")) continue;
                const Json::Value@ pos = entry.Get("position");
                if (pos is null || pos.GetType() != Json::Type::Number) continue;
                double n = double(pos);
                if (n >= 1 && n <= 100000 && n == double(int(n))) return int(n);
            }
        }
        return -1;
    }

    void RefreshPositions() {
        if (positionsLoading || demo || currentUid.Length == 0) return;
        MapGoals@ goals = FindGoals(currentUid);
        if (!IsReleased(goals) || !MatchesAuthor(goals, currentAuthor)) {
            positionsStatus = "Aucune médaille publiée pour cette carte"; return;
        }
        if (!Permissions::ViewRecords()) { positionsStatus = "Classements fermés ou non accessibles (School Mode)"; return; }
        if (!NadeoServices::IsAuthenticated("NadeoLiveServices")) { positionsStatus = "Authentification Nadeo en attente"; return; }
        uint64 previous = 0;
        if (positionLastByUid.Get(currentUid, previous) && Time::Now - previous < 300000) {
            positionsStatus = "Attendre 5 minutes avant une autre recherche sur cette carte"; return;
        }
        if (positionsGlobalAt != 0 && Time::Now - positionsGlobalAt < 60000) {
            positionsStatus = "Attendre 1 minute entre deux cartes"; return;
        }
        string uid = currentUid;
        uint version = goals.calculationVersion >= 5 ? worldVersion : catalogVersion;
        uint pb = currentPb;
        uint[] targets = goals.times;
        positionLastByUid.Set(uid, Time::Now);
        positionsGlobalAt = Time::Now;
        positionsLoading = true;
        positionsUid = uid;
        positionsVersion = version;
        positionsStatus = "Consultation des positions officielles (max. 3)...";
        for (uint i = 0; i < COUNT; i++) positionRanks[i] = -1;
        try {
            for (uint i = 0; i < COUNT; i++) {
                if (uid != currentUid || version != (goals.calculationVersion >= 5 ? worldVersion : catalogVersion)) throw("carte ou catalogue modifié pendant la lecture");
                if (pb > 0 && pb <= targets[i]) { positionRanks[i] = -2; continue; }
                string url = NadeoServices::BaseURLLive() + "/api/token/leaderboard/group/Personal_Best/map/" +
                    uid + "/surround/0/0?score=" + targets[i] + "&onlyWorld=true";
                Net::HttpRequest@ request = NadeoServices::Get("NadeoLiveServices", url);
                request.Start();
                uint64 started = Time::Now;
                while (!request.Finished()) {
                    if (Time::Now - started > 10000 || request.ProgressDownload() > 32768) {
                        request.Cancel(); throw("réponse du classement expirée ou trop volumineuse");
                    }
                    sleep(100);
                }
                if (request.ResponseCode() != 200 || request.ProgressDownload() > 32768) throw("classement indisponible");
                string body = request.String();
                if (body.Length > 32768) throw("réponse du classement trop volumineuse");
                positionRanks[i] = ParseWorldPosition(Json::Parse(body), uid, targets[i]);
                if (i + 1 < COUNT) sleep(500);
            }
            if (uid != currentUid || version != (goals.calculationVersion >= 5 ? worldVersion : catalogVersion)) throw("carte modifiée");
            positionsStatus = "Positions indicatives récupérées (sans modifier les médailles)";
        } catch {
            for (uint i = 0; i < COUNT; i++) positionRanks[i] = -1;
            positionsStatus = "Positions indisponibles ; les objectifs du catalogue restent valables";
            warn("Progressive Medals: consultation bornée des positions impossible : " + getExceptionInfo());
        }
        positionsLoading = false;
    }

    void RenderPositionsWindow() {
        UI::SetNextWindowSize(490, 310, UI::Cond::FirstUseEver);
        if (UI::Begin("Progressive Medals — positions", S_ShowPositionsWindow)) {
            UI::TextWrapped(currentTitle);
            UI::TextDisabled("Positions mondiales indicatives ; fenêtre indépendante d'Extra Leaderboard Positions.");
            MapGoals@ goals = FindGoals(currentUid);
            if (demo || !IsReleased(goals) || !MatchesAuthor(goals, currentAuthor)) {
                UI::TextWrapped("Charger une carte réelle avec des objectifs publiés pour consulter ses positions.");
            } else {
                UI::Text("PB officiel : " + (currentPb == 0 ? "indisponible" : FormatTime(currentPb)));
                if (UI::Button("Estimer les positions mondiales") && !positionsLoading) startnew(RefreshPositions);
                UI::TextWrapped(positionsStatus);
                UI::Separator();
                for (uint i = 0; i < COUNT; i++) {
                    if (i < medalTextures.Length && medalTextures[i] !is null) {
                        UI::Image(medalTextures[i], vec2(30, 30)); UI::SameLine();
                    }
                    string result = "Non consultée";
                    if (positionsUid == currentUid && positionsVersion == (goals.calculationVersion >= 5 ? worldVersion : catalogVersion)) {
                        if (positionRanks[i] == -2) result = "Déjà obtenue (rang du seuil non fourni par Nadeo)";
                        else if (positionRanks[i] > 0) result = "environ top " + positionRanks[i] + " mondial";
                        else if (!positionsLoading) result = "Position non disponible";
                    }
                    UI::Text(NAMES[i] + " — " + FormatTime(goals.times[i]) + " : " + result);
                }
                UI::TextDisabled("Les positions bougent avec le classement ; les temps des médailles restent figés.");
            }
        }
        UI::End();
    }
}
