#if DEPENDENCY_ULTIMATEMEDALSEXTENDED
class PM_UmeMedal : UltimateMedalsExtended::IMedal {
    uint index;
    string uid = "";
    PM_UmeMedal(uint i) { index = i; }

    UltimateMedalsExtended::Config GetConfig() override {
        UltimateMedalsExtended::Config c;
        c.defaultName = "Progressive: " + PM::NAMES[index];
        c.icon = "\\$7CF" + Icons::Circle;
        c.shareIcon = false;
        return c;
    }
    void UpdateMedal(const string &in mapUid) override { uid = mapUid; }
    bool HasMedalTime(const string &in mapUid) override {
        PM::MapGoals@ goals = PM::FindGoals(mapUid);
        return PM::IsReleased(goals) && PM::currentUid == mapUid && PM::MatchesAuthor(goals, PM::currentAuthor);
    }
    uint GetMedalTime() override {
        PM::MapGoals@ goals = PM::FindGoals(uid);
        return goals is null ? uint(-1) : goals.times[index];
    }
}

PM_UmeMedal@[] umeMedals;
void RegisterUme() {
    for (uint i = 0; i < PM::COUNT; i++) {
        PM_UmeMedal@ medal = PM_UmeMedal(i);
        umeMedals.InsertLast(medal);
        UltimateMedalsExtended::AddMedal(medal);
    }
}
void UnregisterUme() {
    for (uint i = 0; i < PM::COUNT; i++) UltimateMedalsExtended::RemoveMedal("Progressive: " + PM::NAMES[i]);
    umeMedals.RemoveRange(0, umeMedals.Length);
}
#endif
