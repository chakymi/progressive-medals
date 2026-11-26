// Track of the Day badges on the native monthly calendar.
// Rendering reads only visible tiles; the PB worker never accesses ManiaLink.
namespace PML {
    const uint64 TOTD_PB_RETRY_MS = 15000;
    const string[] TOTD_MONTH_FR = {"janvier", "février", "mars", "avril", "mai", "juin",
        "juillet", "août", "septembre", "octobre", "novembre", "décembre"};
    const string[] TOTD_MONTH_EN = {"january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december"};

    class TotdGoal {
        string uid;
        int year;
        int month;
        int day;
        uint[] times;
    }

    dictionary totdByUid;      // UID -> TotdGoal@.
    dictionary totdByDate;     // YYYYMMDD -> TotdGoal@.
    dictionary totdFallbackMonth; // Weekday -> unique YYYYMM; 0 means ambiguous.
    uint totdCatalogueVersion = 0;
    PlayerPbs@ totdPbs = PlayerPbs();
    string totdStatus = "Calendrier TOTD en attente";
    int totdLastMonth = 0;
    uint totdLastPbVersion = 0;
    int totdVisibleYear = 0;
    int totdVisibleMonth = 0;

    // Cache only plain text and date values, never Trackmania page pointers.
    string cachedCalendarTitle = "";
    int cachedCalendarWeekday = -1;
    uint cachedCalendarVersion = 0;
    int cachedCalendarYear = 0;
    int cachedCalendarMonth = 0;

    string TotdDateKey(int year, int month, int day) {
        return "" + (year * 10000 + month * 100 + day);
    }

    // 0 = Monday, 6 = Sunday; matches the Trackmania calendar grid.
    int FirstTotdWeekday(int year, int month) {
        if (year < 2021 || year > 2100 || month < 1 || month > 12) return -1;
        const int[] offsets = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};
        int y = month < 3 ? year - 1 : year;
        int sunday = (y + y / 4 - y / 100 + y / 400 + offsets[month - 1] + 1) % 7;
        return (sunday + 6) % 7;
    }

    // Run once after a catalogue update, not every frame.
    void RebuildTotdMonthIndex() {
        totdFallbackMonth.DeleteAll();
        string[]@ keys = totdByUid.GetKeys();
        for (uint i = 0; i < keys.Length; i++) {
            TotdGoal@ goal;
            if (!totdByUid.Get(keys[i], @goal) || goal is null) continue;
            string weekdayKey = "" + FirstTotdWeekday(goal.year, goal.month);
            int monthKey = goal.year * 100 + goal.month;
            int existing = -1;
            if (!totdFallbackMonth.Get(weekdayKey, existing))
                totdFallbackMonth.Set(weekdayKey, monthKey);
            else if (existing != monthKey)
                totdFallbackMonth.Set(weekdayKey, 0);
        }
        cachedCalendarVersion = 0; // Invalidate the resolved-month cache.
    }

    // Empty tiles at the start of the first row reveal the first weekday.
    int FirstVisibleColumn(CGameManialinkPage@ page) {
        if (page is null) return -1;
        int first = -1;
        for (int col = 0; col < int(TOTD_GRID_COLUMNS); col++) {
            CGameManialinkControl@ button = page.GetFirstChild("button-map-" + col + "-0");
            bool visible = button !is null && button.Visible;
            if (visible && first == -1) first = col;
            if (!visible && first != -1) return -1;
        }
        return first;
    }

    // Parse one four-digit year from the title instead of testing 80 years.
    int CalendarYearFromTitle(const string &in title) {
        for (uint i = 0; i + 3 < title.Length; i++) {
            int year = 0;
            bool digits = true;
            for (uint j = 0; j < 4; j++) {
                uint8 c = title[i + j];
                if (c < 48 || c > 57) { digits = false; break; }
                year = year * 10 + int(c - 48);
            }
            if (digits && year >= 2021 && year <= 2100) return year;
        }
        return 0;
    }

    bool MonthFromTitle(const string &in title, int weekday,
                        int &out year, int &out month) {
        year = CalendarYearFromTitle(title);
        if (year == 0) return false;
        for (int m = 1; m <= 12; m++) {
            if (FirstTotdWeekday(year, m) == weekday &&
                    (title.Contains(TOTD_MONTH_FR[m - 1]) ||
                     title.Contains(TOTD_MONTH_EN[m - 1]))) {
                month = m;
                return true;
            }
        }
        return false;
    }

    // Prefer the visible title. Only use the weekday fallback if it uniquely
    // identifies a published month; ambiguous months must never show badges.
    bool ResolveTotdMonth(CGameManialinkPage@ page, int &out year, int &out month,
                          int &out weekday) {
        weekday = FirstVisibleColumn(page);
        if (weekday < 0) return false;
        CGameManialinkLabel@ label = cast<CGameManialinkLabel@>(
            page.GetFirstChild("label-title"));
        string title = "";
        if (label !is null)
            title = Text::StripFormatCodes(string(label.Value)).ToLower();
        if (cachedCalendarVersion != totdCatalogueVersion ||
                cachedCalendarWeekday != weekday || cachedCalendarTitle != title) {
            cachedCalendarTitle = title;
            cachedCalendarWeekday = weekday;
            cachedCalendarVersion = totdCatalogueVersion;
            cachedCalendarYear = 0;
            cachedCalendarMonth = 0;
            if (!MonthFromTitle(title, weekday, cachedCalendarYear, cachedCalendarMonth)) {
                int key = 0;
                if (totdFallbackMonth.Get("" + weekday, key) && key > 0) {
                    cachedCalendarYear = key / 100;
                    cachedCalendarMonth = key % 100;
                }
            }
        }
        year = cachedCalendarYear;
        month = cachedCalendarMonth;
        return year != 0 && month != 0;
    }

    // Fetch the month's published UIDs with the shared official PB reader.
    void FetchTotdPbs(int year, int month) {
        if (year < 2021 || year > 2100 || month < 1 || month > 12 || totdPbs.loading)
            return;
        int monthKey = year * 100 + month;
        if (totdPbs.lastAttempt != 0) {
            uint64 elapsed = Time::Now - totdPbs.lastAttempt;
            if (elapsed < TOTD_PB_RETRY_MS) return;
            if (totdLastMonth == monthKey && totdLastPbVersion == totdCatalogueVersion &&
                    elapsed < PB_REFRESH_MS) return;
        }
        if (!Permissions::ViewRecords() || AuthenticatedAccount().Length == 0) {
            totdStatus = "En attente des autorisations PB Nadeo";
            return;
        }

        string[] uids;
        for (int day = 1; day <= int(TOTD_MAX_DAYS); day++) {
            TotdGoal@ goal;
            if (totdByDate.Get(TotdDateKey(year, month, day), @goal) && goal !is null)
                uids.InsertLast(goal.uid);
        }
        if (uids.IsEmpty()) {
            totdStatus = "Aucune TOTD publiée pour ce mois";
            return;
        }
        totdPbs.loading = true;
        totdPbs.lastAttempt = Time::Now;
        totdLastMonth = monthKey;
        totdLastPbVersion = totdCatalogueVersion;
        totdStatus = "Récupération des PB TOTD...";
        try {
            string account = AuthenticatedAccount();
            dictionary received;
            ReadOfficialPbs(uids, received);
            if (AuthenticatedAccount() != account) throw("Nadeo account changed");
            MergeOfficialPbs(totdPbs, uids, received);
            totdStatus = "PB TOTD chargés : " + received.GetSize() + "/" + uids.Length;
        } catch {
            totdStatus = "PB TOTD indisponibles, prochain essai différé";
            warn(LOG_PREFIX + "TOTD PB: " + getExceptionInfo());
        }
        totdPbs.loading = false;
    }

    void TotdPbWorker() {
        while (true) {
            if (SynchronizeAccount(totdPbs)) {
                totdLastMonth = 0;
                totdLastPbVersion = 0;
            }
            if (PML_ShowTotdBadges && totdCatalogueVersion > 0 &&
                    !totdPbs.loading && totdVisibleYear != 0 && totdVisibleMonth != 0)
                FetchTotdPbs(totdVisibleYear, totdVisibleMonth);
            sleep(2500);
        }
    }

    void RenderTotdBadges() {
        if (badgeTextures.Length != MEDAL_COUNT || totdByDate.IsEmpty()) return;
        CGameManialinkPage@ page = FindBadgeMenuPage(true);
        if (page is null) {
            totdVisibleYear = 0;
            totdVisibleMonth = 0;
            return;
        }
        int year = 0; int month = 0; int weekday = -1;
        if (!ResolveTotdMonth(page, year, month, weekday)) {
            totdVisibleYear = 0;
            totdVisibleMonth = 0;
            totdStatus = "Mois non identifié : aucun badge affiché";
            return;
        }
        totdVisibleYear = year;
        totdVisibleMonth = month;
        if (totdPbs.times.IsEmpty()) return;

        // Preserve the working calendar anchor and grid positions from v0.7.2.
        int spacingCol = weekday < 6 ? weekday : 0;
        int spacingRow = weekday < 6 ? 0 : 1;
        BadgeLayout@ layout = MakeBadgeLayout(page, spacingCol, spacingRow,
            PML_TotdBadgeSize, PML_TotdOffsetX, PML_TotdOffsetY);
        nvg::Save();
        try {
            for (int day = 1; day <= int(TOTD_MAX_DAYS); day++) {
                TotdGoal@ goal;
                if (!totdByDate.Get(TotdDateKey(year, month, day), @goal) || goal is null)
                    continue;
                uint best = 0;
                if (!totdPbs.times.Get(goal.uid, best)) continue;
                int level = HighestBadge(goal.times, best);
                if (level < 0) continue;

                int index = weekday + day - 1;
                if (index < 0 || index >= 42) continue;
                int col = index % int(TOTD_GRID_COLUMNS);
                int row = index / int(TOTD_GRID_COLUMNS);
                CGameManialinkFrame@ frame = cast<CGameManialinkFrame@>(
                    page.GetFirstChild("frame-map-" + col + "-" + row));
                if (frame is null || !frame.Visible) continue;
                CGameManialinkControl@ button = page.GetFirstChild(
                    "button-map-" + col + "-" + row);
                if (button is null || !button.Visible) continue;
                DrawBadge(frame, level, layout);
            }
        } catch {
            totdStatus = "Calendrier en cours de modification, rendu différé";
        }
        nvg::Restore();
    }
}
