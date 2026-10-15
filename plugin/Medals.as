namespace PM {
    const uint COUNT = 3;
    const uint MAX_TIME = 86400000; // One day, in milliseconds.
    const string[] NAMES = {"Platine", "Émeraude", "Diamant"};
    // Fallback labels when a PNG cannot be loaded.
    const string[] ICONS = {"01", "02", "03"};
    const string[] ICON_FILES = {"assets/platinum.png", "assets/emerald.png", "assets/diamond.png"};
    UI::Texture@[] medalTextures;

    void LoadIcons() {
        medalTextures.RemoveRange(0, medalTextures.Length);
        for (uint i = 0; i < COUNT; i++) {
            UI::Texture@ icon;
            try { @icon = UI::LoadTexture(ICON_FILES[i]); }
            catch { warn("Progressive Medals: icône indisponible : " + ICON_FILES[i] + " — " + getExceptionInfo()); }
            medalTextures.InsertLast(icon);
        }
    }

    class MapGoals {
        string uid;
        string name;
        uint authorMs;
        uint referenceWrMs;
        uint[] times;
        uint calculationVersion = 4; // Historical AT/WR catalogue; 5 = exact world ranks.
        string source = "catalogue historique";
        // Schema 1 is reserved for the three bundled fictitious maps.
        string releaseKind = "demo";
        int64 availableAtUtc = 0;
        int64 publishedAtUtc = 0;
    }

    bool IsReleased(const MapGoals@ goals) {
        return goals !is null && Time::Stamp >= goals.availableAtUtc && Time::Stamp >= goals.publishedAtUtc;
    }

    bool MatchesAuthor(const MapGoals@ goals, uint author) {
        return goals !is null && (goals.calculationVersion >= 5 || (author != 0 && author == goals.authorMs));
    }

    string FormatTime(uint ms) {
        uint minutes = ms / 60000;
        uint seconds = (ms / 1000) % 60;
        uint millis = ms % 1000;
        return (minutes < 10 ? "0" : "") + minutes + ":" + (seconds < 10 ? "0" : "") + seconds + "." + (millis < 100 ? "0" : "") + (millis < 10 ? "0" : "") + millis;
    }

    // Highest obtained level, -1 if none. The next target is index result + 1.
    int HighestLevel(const MapGoals@ goals, uint pb) {
        if (!IsReleased(goals) || pb == 0 || pb == uint(-1)) return -1;
        int result = -1;
        for (uint i = 0; i < COUNT; i++) {
            if (pb <= goals.times[i]) result = int(i);
        }
        return result;
    }
}
