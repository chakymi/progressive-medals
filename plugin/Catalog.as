namespace PM {
    dictionary catalog;
    uint catalogVersion = 0;
    string catalogSource = "aucun";
    string catalogError = "";
    const string BUNDLED = "catalog/catalog-v2.json";
    const string CACHE = "catalog-cache.json";
    const uint MAX_CATALOG_BYTES = 524288;
    const int64 EARLIEST_UTC = 1609459200; // 2021-01-01 UTC
    const int64 LATEST_UTC = 4102444800; // 2100-01-01 UTC

    bool ReadStamp(const Json::Value@ obj, const string &in key, int64 &out value) {
        if (obj is null || !obj.HasKey(key)) return false;
        const Json::Value@ node = obj.Get(key);
        if (node is null || node.GetType() != Json::Type::Number) return false;
        double n = double(node);
        if (n < double(EARLIEST_UTC) || n > double(LATEST_UTC) || n != double(int64(n))) return false;
        value = int64(n);
        return true;
    }

    bool ReadInt(const Json::Value@ obj, const string &in key, uint &out value) {
        if (obj is null || !obj.HasKey(key)) return false;
        const Json::Value@ node = obj.Get(key);
        if (node is null || node.GetType() != Json::Type::Number) return false;
        double n = double(node);
        if (n < 1 || n > double(MAX_TIME) || n != double(uint(n))) return false;
        value = uint(n);
        return true;
    }

    bool Decode(const Json::Value@ root, dictionary &out result, uint &out version, string &out reason) {
        reason = "";
        if (root is null || root.GetType() != Json::Type::Object || !root.HasKey("schema") || !root.HasKey("version") || !root.HasKey("maps")) {
            reason = "en-tête absent"; return false;
        }
        const Json::Value@ schema = root.Get("schema");
        const Json::Value@ revision = root.Get("version");
        const Json::Value@ maps = root.Get("maps");
        if (schema is null || schema.GetType() != Json::Type::Number || (double(schema) != 1.0 && double(schema) != 2.0) || revision is null || revision.GetType() != Json::Type::Number || maps is null || maps.GetType() != Json::Type::Object) {
            reason = "schéma incompatible"; return false;
        }
        double v = double(revision);
        if (v < 1 || v > 1000000 || v != double(uint(v)) || maps.Length > 5000) {
            reason = "version ou taille invalide"; return false;
        }
        version = uint(v);
        bool scheduled = double(schema) == 2.0;
        if (scheduled && version < 3) { reason = "schéma 2 réservé aux versions 3+"; return false; }
        if (!scheduled && version == 1) { reason = "catalogue historique 10 paliers incompatible avec cette version"; return false; }
        int64 commonLaunch = 0;
        if (scheduled && root.HasKey("launchAtUtc") && !ReadStamp(root, "launchAtUtc", commonLaunch)) {
            reason = "heure commune de lancement invalide"; return false;
        }
        string[]@ keys = maps.GetKeys();
        for (uint k = 0; k < keys.Length; k++) {
            string uid = keys[k];
            if (uid.Length == 0 || uid.Length > 128 || uid.Contains("/") || uid.Contains("\\")) { reason = "UID invalide"; return false; }
            const Json::Value@ entry = maps.Get(uid);
            if (entry is null || entry.GetType() != Json::Type::Object || !entry.HasKey("name") || !entry.HasKey("timesMs")) { reason = "carte incomplète"; return false; }
            const Json::Value@ title = entry.Get("name");
            const Json::Value@ times = entry.Get("timesMs");
            if (title is null || title.GetType() != Json::Type::String || times is null || times.GetType() != Json::Type::Array || times.Length != COUNT) { reason = "nom ou nombre de paliers invalide"; return false; }
            MapGoals@ goal = MapGoals();
            goal.uid = uid;
            goal.name = string(title);
            if (goal.name.Length == 0 || goal.name.Length > 160 || !ReadInt(entry, "authorMs", goal.authorMs) || !ReadInt(entry, "referenceWrMs", goal.referenceWrMs) || goal.referenceWrMs >= goal.authorMs || goal.authorMs - goal.referenceWrMs < COUNT) {
                reason = "références invalides"; return false;
            }
            if (!scheduled) {
                // Legacy schema cannot publish live map goals without an agreed release schedule.
                if (uid != "DEMO-PROGRESSIVE-001" && uid != "DEMO-PROGRESSIVE-002" && uid != "DEMO-PROGRESSIVE-003") {
                    reason = "schéma 1 réservé aux cartes fictives"; return false;
                }
            } else {
                if (!entry.HasKey("release")) { reason = "calendrier absent"; return false; }
                const Json::Value@ release = entry.Get("release");
                if (release is null || release.GetType() != Json::Type::Object || !release.HasKey("kind")) {
                    reason = "calendrier absent"; return false;
                }
                const Json::Value@ kind = release.Get("kind");
                if (kind is null || kind.GetType() != Json::Type::String) { reason = "type de carte invalide"; return false; }
                goal.releaseKind = string(kind);
                if (goal.releaseKind == "demo" && (uid == "DEMO-PROGRESSIVE-001" || uid == "DEMO-PROGRESSIVE-002" || uid == "DEMO-PROGRESSIVE-003")) {
                    if (release.GetKeys().Length != 1) { reason = "calendrier démo invalide"; return false; }
                } else {
                    int64 anchor = 0;
                    int64 captured = 0;
                    int64 published = 0;
                    int64 claimedAvailable = 0;
                    int64 delay = 0;
                    if (goal.releaseKind == "campaign") delay = 604800;
                    else if (goal.releaseKind == "totd" || goal.releaseKind == "launchCampaign") delay = 3600;
                    else { reason = "type de carte inconnu"; return false; }
                    if (release.GetKeys().Length != 5 || !ReadStamp(release, "anchorAtUtc", anchor) || !ReadStamp(release, "availableAtUtc", claimedAvailable) || !ReadStamp(release, "wrCapturedAtUtc", captured) || !ReadStamp(release, "publishedAtUtc", published) || anchor > LATEST_UTC - delay || claimedAvailable != anchor + delay || captured < claimedAvailable || published < captured) {
                        reason = "publication anticipée ou calendrier invalide"; return false;
                    }
                    if (goal.releaseKind == "launchCampaign" && (commonLaunch == 0 || anchor != commonLaunch)) {
                        reason = "heure de lancement commune incohérente"; return false;
                    }
                    goal.availableAtUtc = claimedAvailable;
                    goal.publishedAtUtc = published;
                }
            }
            uint previous = goal.authorMs;
            for (uint i = 0; i < COUNT; i++) {
                const Json::Value@ target = times[i];
                if (target is null || target.GetType() != Json::Type::Number) { reason = "temps non entier"; return false; }
                double n = double(target);
                if (n < double(goal.referenceWrMs) || n >= double(previous) || n != double(uint(n))) { reason = "paliers non stricts ou hors bornes"; return false; }
                previous = uint(n);
                goal.times.InsertLast(previous);
            }
            result.Set(uid, @goal);
        }
        return true;
    }

    bool InstallCatalog(const Json::Value@ root, const string &in source, bool persist) {
        dictionary next;
        uint version = 0;
        string reason;
        if (!Decode(root, next, version, reason)) {
            catalogError = source + " : " + reason;
            warn("Progressive Medals: catalogue rejeté (" + catalogError + ")");
            return false;
        }
        if (version <= catalogVersion) {
            if (source != "cache") catalogError = "version déjà présente ou antérieure : incrémenter la version";
            return false;
        }
        if (persist) {
            try { Json::ToFile(IO::FromStorageFolder(CACHE), root); }
            catch { warn("Progressive Medals: cache non écrit : " + getExceptionInfo()); }
        }
        catalog = next;
        catalogVersion = version;
        catalogSource = source;
        catalogError = "";
        trace("Progressive Medals: catalogue " + version + " chargé depuis " + source + " (" + catalog.GetSize() + " cartes)");
        return true;
    }

    void LoadCatalog() {
        try { InstallCatalog(Json::FromFile(BUNDLED), "embarqué", false); }
        catch { warn("Progressive Medals: catalogue embarqué illisible : " + getExceptionInfo()); }
        string path = IO::FromStorageFolder(CACHE);
        if (IO::FileExists(path) && IO::FileSize(path) <= MAX_CATALOG_BYTES) {
            try { InstallCatalog(Json::FromFile(path), "cache", false); }
            catch { warn("Progressive Medals: cache illisible : " + getExceptionInfo()); }
        }
    }

    MapGoals@ FindGoals(const string &in uid) {
        MapGoals@ result;
        if (uid.Length > 0) catalog.Get(uid, @result);
        return result;
    }

    // Manual in-game parser smoke check; exercises the actual AngelScript loader.
    string CheckLoader() {
        dictionary trial;
        uint version = 0;
        string reason;
        try {
            Json::Value@ bundled = Json::FromFile(BUNDLED);
            if (!Decode(bundled, trial, version, reason) || version != 2 || trial.GetSize() != 3)
                return "Échec catalogue embarqué : " + reason;
            Json::Value@ broken = Json::Parse("{\"schema\":1,\"version\":2,\"maps\":{\"DEMO-PROGRESSIVE-001\":{\"name\":\"x\",\"authorMs\":100,\"referenceWrMs\":90,\"timesMs\":[99,99,97]}}}");
            dictionary discarded;
            if (Decode(broken, discarded, version, reason)) return "Échec : doublon accepté";
            Json::Value@ onTime = Json::Parse("{\"schema\":2,\"version\":3,\"maps\":{\"test-UID\":{\"name\":\"Campagne\",\"authorMs\":100,\"referenceWrMs\":90,\"timesMs\":[99,97,93],\"release\":{\"kind\":\"campaign\",\"anchorAtUtc\":1700000000,\"availableAtUtc\":1700604800,\"wrCapturedAtUtc\":1700604800,\"publishedAtUtc\":1700604800}}}}");
            dictionary validSchedule;
            if (!Decode(onTime, validSchedule, version, reason) || validSchedule.GetSize() != 1) return "Échec calendrier valide : " + reason;
            Json::Value@ tooEarly = Json::Parse("{\"schema\":2,\"version\":3,\"maps\":{\"test-UID\":{\"name\":\"Campagne\",\"authorMs\":100,\"referenceWrMs\":90,\"timesMs\":[99,97,93],\"release\":{\"kind\":\"campaign\",\"anchorAtUtc\":1700000000,\"availableAtUtc\":1700604800,\"wrCapturedAtUtc\":1700604799,\"publishedAtUtc\":1700604800}}}}");
            dictionary invalidSchedule;
            if (Decode(tooEarly, invalidSchedule, version, reason)) return "Échec : WR anticipé accepté";
            return "Chargeur v2 OK : 3 paliers, doublon et WR anticipé refusés";
        } catch { return "Échec chargeur : " + getExceptionInfo(); }
    }

    // Never invoked from Render or on each map switch: manual or hourly only.
    bool downloading = false;
    uint64 lastAttempt = 0;
    void AutoRefreshLoop() {
        while (true) {
            if (S_AutoUpdates && S_CatalogUrl.Length > 0 && !downloading) RefreshCatalog();
            sleep(3600000); // Once per hour; no request at all until URL is configured.
        }
    }
    void RefreshCatalog() {
        if (downloading || S_CatalogUrl.Length == 0 || !S_CatalogUrl.StartsWith("https://") || S_CatalogUrl.Contains("@") || S_CatalogUrl.Contains("#") || S_CatalogUrl.Contains("?") || S_CatalogUrl.Contains(" ")) {
            catalogError = "URL HTTPS publique requise, sans identifiants";
            return;
        }
        if (lastAttempt != 0 && Time::Now - lastAttempt < 300000) {
            catalogError = "attendre 5 minutes entre les actualisations"; return;
        }
        lastAttempt = Time::Now;
        downloading = true;
        try {
            Net::HttpRequest@ request = Net::HttpGet(S_CatalogUrl);
            uint64 started = Time::Now;
            while (!request.Finished()) {
                if (Time::Now - started > 12000 || request.ProgressDownload() > MAX_CATALOG_BYTES) {
                    request.Cancel();
                    catalogError = "téléchargement expiré ou trop volumineux";
                    downloading = false; return;
                }
                sleep(100);
            }
            if (request.ResponseCode() != 200 || request.ProgressDownload() > MAX_CATALOG_BYTES) {
                catalogError = "HTTP " + request.ResponseCode();
            } else {
                string body = request.String();
                if (body.Length > MAX_CATALOG_BYTES) catalogError = "catalogue trop volumineux";
                else InstallCatalog(Json::Parse(body), "HTTPS", true);
            }
        } catch {
            catalogError = "réseau/JSON : " + getExceptionInfo();
            warn("Progressive Medals: " + catalogError);
        }
        downloading = false;
    }
}
