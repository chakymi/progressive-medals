// Google Sheets is the ONLY source for published medal targets.
// The public Medals tab is read directly as CSV, without Apps Script.
// CSV rows are validated and converted into a JSON catalogue in memory.
// A validated local snapshot is retained if the network is unavailable.
namespace PML {
    // The sheet is already shared "anyone with the link: reader".
    // Export only the Medals tab. No extra service or token is needed.
    const string SHEET_CSV_URL =
        "https://docs.google.com/spreadsheets/d/1fQDDAL-zag_7PlhQ8XZC0b2r8xzVeVHf0IKGSEbQBFA/export?format=csv&gid=694803941";
    const string SHEET_CACHE_FILE = "sheet-medals-csv-cache-v2.json";
    const uint64 SHEET_REFRESH_MS = 900000; // Every 15 minutes, never per frame.
    const uint64 SHEET_TIMEOUT_MS = 20000;
    const uint SHEET_MAX_BYTES = 524288;

    uint sheetCatalogueVersion = 0;
    uint64 sheetLastAttempt = 0;
    bool sheetForceRefresh = false;
    string sheetFingerprint = "";
    // Visible in the plugin window: avoid hiding the reason behind "unavailable".
    string sheetLastError = "Aucun téléchargement réussi pour le moment.";

    // A TOTD date must be taken from the actual UTC release_at_utc column,
    // never from its map name or the user's local timezone.
    bool ReadUtcDatePart(const string &in value, uint begin, uint length, int &out number) {
        number = 0;
        if (value.Length < begin + length) return false;
        for (uint i = begin; i < begin + length; i++) {
            if (value[i] < 48 || value[i] > 57) return false;
            number = number * 10 + int(value[i] - 48);
        }
        return true;
    }

    bool ReadTotdDate(const string &in timestamp, int &out year,
                      int &out month, int &out day) {
        if (timestamp.Length < 20 || timestamp[4] != 45 ||
                timestamp[7] != 45 || timestamp[10] != 84 ||
                timestamp[timestamp.Length - 1] != 90 ||
                !ReadUtcDatePart(timestamp, 0, 4, year) ||
                !ReadUtcDatePart(timestamp, 5, 2, month) ||
                !ReadUtcDatePart(timestamp, 8, 2, day)) return false;
        if (year < 2021 || year > 2100 || month < 1 || month > 12) return false;
        int days = 31;
        if (month == 4 || month == 6 || month == 9 || month == 11) days = 30;
        if (month == 2) {
            bool leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
            days = leap ? 29 : 28;
        }
        return day >= 1 && day <= days;
    }

    // Use map UIDs to locate Fall 2026 cards, not their display names.
    // The last five cards have country names in the Sheet, and card names
    // can change without changing the map. The known 25-card order is loaded
    // by InitMenuBadges() from the original Fall 2026 catalogue.
    int FindFall2026IndexByUid(const string &in uid) {
        for (uint i = 0; i < menuUids.Length; i++) {
            if (menuUids[i] == uid) return int(i);
        }
        return -1;
    }

    bool ReadSheetCatalogue(const Json::Value@ root, dictionary &out allGoals,
                            dictionary &out campaignGoals, string[] &out campaignUids,
                            dictionary &out dayGoals, dictionary &out dateGoals,
                            string &out fingerprint) {
        if (root is null || root.GetType() != Json::Type::Object ||
                !root.HasKey("schema") || !root.HasKey("maps")) return false;
        const Json::Value@ schema = root.Get("schema");
        const Json::Value@ maps = root.Get("maps");
        if (schema is null || schema.GetType() != Json::Type::Number ||
                double(schema) != 1 || maps is null ||
                maps.GetType() != Json::Type::Array ||
                maps.Length > 3000) return false;

        string[] fallUids(25);
        dictionary seen;
        fingerprint = "";
        for (uint i = 0; i < maps.Length; i++) {
            const Json::Value@ row = maps[i];
            if (row is null || row.GetType() != Json::Type::Object ||
                    !row.HasKey("map_uid") || !row.HasKey("map_name") ||
                    !row.HasKey("map_type") || !row.HasKey("release_at_utc") ||
                    !row.HasKey("status")) return false;
            string uid = string(row.Get("map_uid"));
            string name = string(row.Get("map_name"));
            string type = string(row.Get("map_type"));
            string released = string(row.Get("release_at_utc"));
            if (!IsValidUid(uid) || seen.Exists(uid) ||
                    string(row.Get("status")) != "PUBLISHED" ||
                    (type != "campaign" && type != "totd")) return false;

            uint p = 0; uint e = 0; uint d = 0;
            if (!ReadPositiveMs(row, "platinum_ms", p) ||
                    !ReadPositiveMs(row, "emerald_ms", e) ||
                    !ReadPositiveMs(row, "diamond_ms", d) ||
                    p < e || e < d) return false;
            seen.Set(uid, true);
            uint[] times = {p, e, d};
            Goals@ goal = Goals();
            goal.times = times;
            allGoals.Set(uid, @goal);
            fingerprint += uid + ":" + p + ":" + e + ":" + d + ";";

            if (type == "campaign") {
                int index = FindFall2026IndexByUid(uid);
                if (index >= 0) {
                    if (fallUids[index].Length != 0) return false;
                    fallUids[index] = uid;
                    MenuTarget@ target = MenuTarget();
                    target.times = times;
                    campaignGoals.Set(uid, @target);
                }
            } else {
                int year = 0; int month = 0; int day = 0;
                if (!ReadTotdDate(released, year, month, day)) return false;
                string dateKey = TotdDateKey(year, month, day);
                if (dateGoals.Exists(dateKey)) return false;
                TotdGoal@ target = TotdGoal();
                target.uid = uid;
                target.year = year;
                target.month = month;
                target.day = day;
                target.times = times;
                dayGoals.Set(uid, @target);
                dateGoals.Set(dateKey, @target);
                fingerprint += released + ";";
            }
        }
        if (seen.IsEmpty()) return false;
        // Fall 2026 is either complete (25 cards), or not displayed at all.
        for (uint i = 0; i < fallUids.Length; i++) {
            if (fallUids[i].Length == 0) {
                if (!campaignGoals.IsEmpty()) return false;
                break;
            }
        }
        for (uint i = 0; i < fallUids.Length; i++) {
            if (fallUids[i].Length > 0) campaignUids.InsertLast(fallUids[i]);
        }
        return true;
    }

    bool InstallSheetCatalogue(const Json::Value@ root, bool saveCache) {
        dictionary goals;
        dictionary campaign;
        string[] fallUids;
        dictionary day;
        dictionary date;
        string fingerprint;
        if (!ReadSheetCatalogue(root, goals, campaign, fallUids, day, date, fingerprint))
            return false;
        if (sheetCatalogueVersion != 0 && fingerprint == sheetFingerprint) {
            status = "Google Sheets : objectifs à jour";
            sheetLastError = "";
            return true;
        }

        // One cooperative-thread update: no partial catalogue can be displayed.
        publishedByUid = goals;
        // Never clear the working campaign UI if the export contains no Fall set.
        if (fallUids.Length == 25) {
            menuTargets = campaign;
            menuUids = fallUids;
        }
        totdByUid = day;
        totdByDate = date;
        sheetFingerprint = fingerprint;
        sheetCatalogueVersion++;
        totdCatalogueVersion = sheetCatalogueVersion;
        menuStatus = "Google Sheets : " + menuUids.Length + " cartes Fall 2026";
        totdStatus = "Google Sheets : " + totdByUid.GetSize() + " TOTD publiées";
        status = "Google Sheets : " + publishedByUid.GetSize() + " cartes publiées";
        sheetLastError = "";
        if (saveCache) {
            try { Json::ToFile(IO::FromStorageFolder(SHEET_CACHE_FILE), root); }
            catch { warn("Progressive Medals : sauvegarde du cache Google Sheets impossible"); }
        }
        return true;
    }

    void InitSheetCatalogue() {
        // Bundled data is a snapshot of published rows in the same Sheet,
        // not a second service. It prevents blank badges while offline.
        try {
            InstallSheetCatalogue(Json::FromFile("catalog/sheet-medals-bootstrap.json"), false);
        } catch { warn("Progressive Medals : snapshot Google Sheet illisible"); }

        string path = IO::FromStorageFolder(SHEET_CACHE_FILE);
        if (!IO::FileExists(path) || IO::FileSize(path) > SHEET_MAX_BYTES) return;
        try { InstallSheetCatalogue(Json::FromFile(path), false); }
        catch { warn("Progressive Medals : dernier cache Google Sheet invalide"); }
    }

    // Escape CSV cell values before placing them in the JSON catalogue. Google Sheets may contain quotes
    // or commas in a map name; never interpolate unescaped content in JSON.
    string JsonEscapeCsv(const string &in value) {
        string result = "\"";
        for (uint i = 0; i < value.Length; i++) {
            uint8 c = value[i];
            if (c == 34 || c == 92) result += "\\";
            if (c < 32) result += " ";
            else result += value.SubStr(i, 1);
        }
        return result + "\"";
    }

    // Parse a positive integer in milliseconds, without accepting 20.123 or HTML.
    bool ReadCsvMs(const string &in raw, uint &out timeMs) {
        timeMs = 0;
        if (raw.Length == 0 || raw.Length > 8) return false;
        for (uint i = 0; i < raw.Length; i++) {
            uint8 c = raw[i];
            if (c < 48 || c > 57) return false;
            timeMs = timeMs * 10 + (c - 48);
        }
        return timeMs > 0 && timeMs <= MAX_TIME_MS;
    }

    // Keeps CSV conversion state in one object. Openplanet AngelScript does not
    // accept &inout for string/uint in function arguments.
    class CsvCatalogueBuilder {
        string jsonText;
        uint publishedCount;
    }

    // Convert one CSV row to JSON. Unpublished rows are deliberately skipped.
    bool AppendCsvRow(const string[] &in cells, uint lineNumber,
                      CsvCatalogueBuilder@ builder) {
        if (builder is null) return false;
        if (lineNumber == 1) {
            const string[] expected = {"map_uid", "map_name", "map_type",
                "release_at_utc", "status", "initial_due_utc", "threshold_seen_at_utc",
                "capture_due_utc", "captured_at_utc", "platinum_ms", "emerald_ms",
                "diamond_ms"};
            if (cells.Length < expected.Length) return false;
            for (uint i = 0; i < expected.Length; i++)
                if (cells[i] != expected[i]) return false;
            return true;
        }
        if (cells.Length == 1 && cells[0].Length == 0) return true;
        if (cells.Length < 12) return false;
        if (cells[4] != "PUBLISHED") return true;

        string uid = cells[0];
        string name = cells[1];
        string kind = cells[2];
        string released = cells[3];
        if (!IsValidUid(uid) || (kind != "totd" && kind != "campaign") ||
                name.Length == 0 || name.Length > 120) return false;
        uint p = 0; uint e = 0; uint d = 0;
        if (!ReadCsvMs(cells[9], p) || !ReadCsvMs(cells[10], e) ||
                !ReadCsvMs(cells[11], d) || p < e || e < d) return false;
        if (builder.publishedCount != 0) builder.jsonText += ",";
        builder.jsonText += "{\"map_uid\":" + JsonEscapeCsv(uid) +
            ",\"map_name\":" + JsonEscapeCsv(name) +
            ",\"map_type\":" + JsonEscapeCsv(kind) +
            ",\"release_at_utc\":" + JsonEscapeCsv(released) +
            ",\"status\":\"PUBLISHED\",\"platinum_ms\":" + p +
            ",\"emerald_ms\":" + e + ",\"diamond_ms\":" + d + "}";
        builder.publishedCount++;
        return builder.publishedCount <= 3000;
    }

    // Quoted CSV supports commas, CRLFs, escaped quotes, and line breaks.
    // Parse it once per download, never in Render().
    Json::Value@ CsvToCatalogue(const string &in csv) {
        CsvCatalogueBuilder@ builder = CsvCatalogueBuilder();
        builder.jsonText = "{\"schema\":1,\"maps\":[";
        builder.publishedCount = 0;
        string field = "";
        string[] cells;
        bool insideQuotes = false;
        uint lineNumber = 1;
        for (uint i = 0; i < csv.Length; i++) {
            uint8 c = csv[i];
            if (insideQuotes) {
                if (c == 34) {
                    if (i + 1 < csv.Length && csv[i + 1] == 34) {
                        field += "\"";
                        i++;
                    } else insideQuotes = false;
                } else field += csv.SubStr(i, 1);
            } else if (c == 34) {
                if (field.Length != 0) return null;
                insideQuotes = true;
            } else if (c == 44) {
                cells.InsertLast(field);
                field = "";
            } else if (c == 10) {
                cells.InsertLast(field);
                if (!AppendCsvRow(cells, lineNumber, builder)) return null;
                cells.RemoveRange(0, cells.Length);
                field = "";
                lineNumber++;
            } else if (c != 13) field += csv.SubStr(i, 1);
        }
        if (insideQuotes) return null;
        if (cells.Length != 0 || field.Length != 0) {
            cells.InsertLast(field);
            if (!AppendCsvRow(cells, lineNumber, builder)) return null;
        }
        if (lineNumber <= 1 || builder.publishedCount == 0) return null;
        builder.jsonText += "]}";
        try { return Json::Parse(builder.jsonText); }
        catch { return null; }
    }

    // Direct, anonymous read of the public Google Sheet.
    void DownloadSheetCatalogue() {
        try {
            Net::HttpRequest@ request = Net::HttpRequest(SHEET_CSV_URL);
            request.Redirect = true;
            request.Start();
            uint64 started = Time::Now;
            while (!request.Finished()) {
                if (Time::Now - started > SHEET_TIMEOUT_MS ||
                        request.ProgressDownload() > SHEET_MAX_BYTES) {
                    request.Cancel();
                    throw("Délai dépassé ou export CSV trop volumineux");
                }
                sleep(100);
            }
            if (request.ResponseCode() != 200) {
                throw("Export Google Sheets : HTTP " + request.ResponseCode() +
                    " (vérifier le partage public en lecture)");
            }
            string response = request.String();
            if (response.Length == 0 || response.Length > SHEET_MAX_BYTES)
                throw("Export Google Sheets vide ou trop volumineux");
            Json::Value@ parsed = CsvToCatalogue(response);
            if (parsed is null)
                throw("Export CSV invalide (vérifier le gid et les colonnes Medals)");
            if (!InstallSheetCatalogue(parsed, true))
                throw("Lignes publiées invalides; dernière version conservée");
        } catch {
            sheetLastError = getExceptionInfo();
            status = sheetCatalogueVersion == 0 ?
                "Google Sheets : aucun catalogue disponible" :
                "Google Sheets : lecture impossible (dernier catalogue conservé)";
            warn("Progressive Medals - Google Sheets : " + sheetLastError);
        }
    }

    void SheetCatalogueWorker() {
        while (true) {
            bool due = sheetLastAttempt == 0 ||
                Time::Now - sheetLastAttempt >= SHEET_REFRESH_MS;
            if (sheetForceRefresh || (PML_AutoFetch && due)) {
                sheetForceRefresh = false;
                sheetLastAttempt = Time::Now;
                DownloadSheetCatalogue();
            }
            sleep(2000);
        }
    }
}
