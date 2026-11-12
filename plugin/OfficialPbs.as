// Shared, read-only access to the logged-in player's personal bests.
// Called by the campaign and TOTD workers. Never call from Render().
namespace PML {
    const uint64 OFFICIAL_PB_TIMEOUT_MS = 12000;
    const uint OFFICIAL_PB_MAX_BYTES = 65536;

    // Validate integer millisecond values received from JSON.
    bool ReadPositiveMs(const Json::Value@ object, const string &in key, uint &out value) {
        value = 0;
        if (object is null || !object.HasKey(key)) return false;
        const Json::Value@ node = object.Get(key);
        if (node is null || node.GetType() != Json::Type::Number) return false;
        double n = double(node);
        if (n < 1 || n > double(MAX_TIME_MS) || n != double(uint(n))) return false;
        value = uint(n);
        return true;
    }


    // One Nadeo request for up to 31 maps. Missing records are normal.
    // Throws on unexpected data so callers never use a partial response.
    void ReadOfficialPbs(const string[] &in uids, dictionary &out result) {
        if (uids.Length == 0 || uids.Length > 31)
            throw("Nombre de cartes PB invalide");

        string body = "{\"maps\":[";
        for (uint i = 0; i < uids.Length; i++) {
            if (!IsValidUid(uids[i])) throw("UID PB invalide");
            if (i > 0) body += ",";
            body += "{\"mapUid\":\"" + uids[i] + "\",\"groupUid\":\"Personal_Best\"}";
        }
        body += "]}";

        Net::HttpRequest@ request = NadeoServices::Post("NadeoLiveServices",
            NadeoServices::BaseURLLive() + "/api/token/leaderboard/group/map", body);
        request.Start();
        uint64 started = Time::Now;
        while (!request.Finished()) {
            if (Time::Now - started > OFFICIAL_PB_TIMEOUT_MS ||
                    request.ProgressDownload() > OFFICIAL_PB_MAX_BYTES) {
                request.Cancel();
                throw("Requête PB trop longue ou volumineuse");
            }
            sleep(100);
        }
        if (request.ResponseCode() != 200 ||
                request.ProgressDownload() > OFFICIAL_PB_MAX_BYTES)
            throw("Service PB indisponible (HTTP " + request.ResponseCode() + ")");

        string response = request.String();
        if (response.Length > OFFICIAL_PB_MAX_BYTES)
            throw("Réponse PB trop volumineuse");
        Json::Value@ records = Json::Parse(response);
        if (records is null || records.GetType() != Json::Type::Array ||
                records.Length > uids.Length)
            throw("Liste de PB incorrecte");

        dictionary verified;
        for (uint i = 0; i < records.Length; i++) {
            const Json::Value@ record = records[i];
            if (record is null || record.GetType() != Json::Type::Object ||
                    !record.HasKey("mapUid") || !record.HasKey("groupUid"))
                throw("Ligne PB incorrecte");
            const Json::Value@ uidNode = record.Get("mapUid");
            const Json::Value@ groupNode = record.Get("groupUid");
            if (uidNode is null || uidNode.GetType() != Json::Type::String ||
                    groupNode is null || groupNode.GetType() != Json::Type::String ||
                    string(groupNode) != "Personal_Best")
                throw("Groupe PB inattendu");

            string uid = string(uidNode);
            bool allowed = false;
            for (uint j = 0; j < uids.Length; j++) {
                if (uids[j] == uid) { allowed = true; break; }
            }
            uint score = 0;
            if (!allowed || verified.Exists(uid) || !ReadPositiveMs(record, "score", score))
                throw("PB invalide, inconnu ou en doublon");
            verified.Set(uid, score);
        }
        result = verified;
    }
}
