namespace PM {
    bool ValidHudTime(uint ms) {
        return ms > 0 && ms != uint(-1) && ms <= MAX_TIME;
    }

    void HudRow(const string &in label, const string &in value, const vec4 &in dotColor) {
        UI::PushStyleColor(UI::Col::Text, dotColor);
        UI::Text(Icons::Circle);
        UI::PopStyleColor();
        UI::SameLine();
        UI::Text(label);
        UI::SameLine(132);
        UI::Text(value);
    }

    void RenderRaceHud() {
        if (!S_ShowRaceHud || demo || (S_HideRaceHudWithGameUI && !UI::IsGameUIVisible())) return;
        CGameCtnApp@ app = GetApp();
        if (app is null || app.RootMap is null || app.Editor !is null || app.CurrentPlayground is null ||
                currentUid.Length == 0 || currentUid != app.RootMap.IdName) return;
        MapGoals@ goals = FindGoals(currentUid);
        if (!IsReleased(goals) || !MatchesAuthor(goals, currentAuthor)) return;

        int flags = UI::WindowFlags::NoResize | UI::WindowFlags::NoCollapse |
                    UI::WindowFlags::NoScrollbar | UI::WindowFlags::AlwaysAutoResize |
                    UI::WindowFlags::NoDocking;
        if (!UI::IsOverlayShown()) flags |= UI::WindowFlags::NoTitleBar | UI::WindowFlags::NoMove | UI::WindowFlags::NoInputs;
        float scale = UI::GetScale();
        if (scale <= 0) scale = 1.0f;
        UI::SetNextWindowPos(int(float(Display::GetWidth()) / scale) - 16, 26, UI::Cond::FirstUseEver, 1.0f, 0.0f);
        UI::SetNextWindowBgAlpha(1.0f);
        UI::PushStyleColor(UI::Col::WindowBg, vec4(0.075f, 0.08f, 0.095f, 1.0f));
        if (UI::Begin("Progressive Medals — HUD##PMRaceHud", S_ShowRaceHud, flags)) {
            string[] labels;
            uint[] times;
            vec4[] colors;
            if (S_RaceHudAllMedals) {
                labels.InsertLast("Bronze"); times.InsertLast(app.RootMap.TMObjective_BronzeTime); colors.InsertLast(vec4(0.75f, 0.47f, 0.3f, 1.0f));
                labels.InsertLast("Argent"); times.InsertLast(app.RootMap.TMObjective_SilverTime); colors.InsertLast(vec4(0.75f, 0.8f, 0.84f, 1.0f));
                labels.InsertLast("Or"); times.InsertLast(app.RootMap.TMObjective_GoldTime); colors.InsertLast(vec4(0.98f, 0.78f, 0.28f, 1.0f));
            }
            labels.InsertLast("Auteur"); times.InsertLast(currentAuthor); colors.InsertLast(vec4(0.24f, 0.88f, 0.45f, 1.0f));
            labels.InsertLast(NAMES[0]); times.InsertLast(goals.times[0]); colors.InsertLast(vec4(0.7f, 0.85f, 0.96f, 1.0f));
            labels.InsertLast(NAMES[1]); times.InsertLast(goals.times[1]); colors.InsertLast(vec4(0.26f, 0.87f, 0.48f, 1.0f));
            labels.InsertLast(NAMES[2]); times.InsertLast(goals.times[2]); colors.InsertLast(vec4(0.38f, 0.65f, 1.0f, 1.0f));

            if (S_RaceHudAllMedals) {
#if DEPENDENCY_CHAMPIONMEDALS
                uint champion = 0;
                Meta::Plugin@ plugin = Meta::GetPluginFromID("ChampionMedals");
                if (plugin !is null && plugin.Enabled && Time::Now - currentMapChangedAt >= 1500) {
                    champion = ChampionMedals::GetCMTime(); // Display only; never used to generate our thresholds.
                }
                times.InsertLast(champion);
#else
                times.InsertLast(0);
#endif
                labels.InsertLast("Champion*"); colors.InsertLast(vec4(1.0f, 0.3f, 0.63f, 1.0f));
            }

            // PB is a time, not a medal: insert it at its actual difficulty.
            // If the native PB is absent, keep an explicit unavailable row.
            if (ValidHudTime(currentPb)) {
                labels.InsertLast("PB"); times.InsertLast(currentPb); colors.InsertLast(vec4(0.18f, 0.9f, 0.4f, 1.0f));
            } else {
                HudRow("PB", "—", vec4(0.55f, 0.55f, 0.55f, 1.0f));
            }

            // Smallest time first = hardest target (closest to the WR) first. Unavailable optional
            // times go last; PB follows the medal on an exact tie.
            for (uint i = 0; i < times.Length; i++) {
                for (uint j = i + 1; j < times.Length; j++) {
                    bool swap = (ValidHudTime(times[j]) && !ValidHudTime(times[i])) ||
                        (ValidHudTime(times[j]) && ValidHudTime(times[i]) && times[j] < times[i]) ||
                        (times[j] == times[i] && labels[i] == "PB" && labels[j] != "PB");
                    if (swap) {
                        uint oldTime = times[i]; times[i] = times[j]; times[j] = oldTime;
                        string oldLabel = labels[i]; labels[i] = labels[j]; labels[j] = oldLabel;
                        vec4 oldColor = colors[i]; colors[i] = colors[j]; colors[j] = oldColor;
                    }
                }
            }
            for (uint i = 0; i < times.Length; i++) {
                HudRow(labels[i], ValidHudTime(times[i]) ? FormatTime(times[i]) : "—", colors[i]);
            }
            if (S_RaceHudAllMedals) {
                UI::TextDisabled("* Référence externe indépendante");
            }
        }
        UI::End();
        UI::PopStyleColor();
    }
}
