// Shared medal rules, account handling and native-menu drawing.
// Only the render callbacks access ManiaLink controls; no UI pointers are cached.
namespace PML {
    const string LOG_PREFIX = "Progressive Medals: ";
    const uint MEDAL_COUNT = 3;
    const uint FALL_MAP_COUNT = 25;
    const uint FALL_GRID_SIDE = 5;
    const uint TOTD_GRID_COLUMNS = 7;
    const uint TOTD_MAX_DAYS = 31;
    const uint64 PB_REFRESH_MS = 1800000; // 30 minutes.

    // The order is Platinum, Emerald, Diamond (slowest to fastest target).
    bool AreValidMedalTimes(const uint[] &in times) {
        return times.Length == MEDAL_COUNT && times[0] > 0 &&
            times[0] <= MAX_TIME_MS && times[0] >= times[1] &&
            times[1] >= times[2] && times[2] > 0;
    }

    int HighestBadge(const uint[] &in times, uint best) {
        if (!AreValidMedalTimes(times) || best == 0 || best > MAX_TIME_MS) return -1;
        int result = -1;
        for (uint i = 0; i < MEDAL_COUNT; i++) {
            if (best <= times[i]) result = int(i);
        }
        return result;
    }

    class PlayerPbs {
        dictionary times; // Map UID -> best time for this account.
        string account = "";
        uint64 lastAttempt = 0;
        bool loading = false;
    }

    string AuthenticatedAccount() {
        if (!NadeoServices::IsAuthenticated("NadeoLiveServices")) return "";
        return NadeoServices::GetAccountID();
    }

    // Clearing both the account and its records prevents cross-account badges.
    // Returns true when the identity changed (including sign-out).
    bool SynchronizeAccount(PlayerPbs@ player) {
        string account = AuthenticatedAccount();
        if (player.account == account) return false;
        player.times.DeleteAll();
        player.account = account;
        player.lastAttempt = 0;
        return true;
    }

    // Keep a faster local result when the official API has not caught up yet.
    void RememberBestPb(PlayerPbs@ player, const string &in uid, uint best) {
        if (best == 0 || best > MAX_TIME_MS || AuthenticatedAccount().Length == 0) return;
        SynchronizeAccount(player);
        uint previous = 0;
        if (!player.times.Get(uid, previous) || best < previous)
            player.times.Set(uid, best);
    }

    void MergeOfficialPbs(PlayerPbs@ player, const string[] &in uids,
                          dictionary &in received) {
        for (uint i = 0; i < uids.Length; i++) {
            uint best = 0;
            if (!received.Get(uids[i], best)) continue;
            uint previous = 0;
            if (!player.times.Get(uids[i], previous) || best < previous)
                player.times.Set(uids[i], best);
        }
    }

    // Both pages use the same visible menu layers, with different anchors.
    // Scan only while needed; never keep a page or control between frames.
    CGameManialinkPage@ FindBadgeMenuPage(bool calendar) {
        try {
            CTrackMania@ app = cast<CTrackMania@>(GetApp());
            if (app is null || app.Editor !is null || app.CurrentPlayground !is null ||
                    app.MenuManager is null || app.MenuManager.MenuCustom_CurrentManiaApp is null)
                return null;
            auto layers = app.MenuManager.MenuCustom_CurrentManiaApp.UILayers;
            for (uint i = 0; i < layers.Length && i < 100; i++) {
                CGameUILayer@ layer = layers[i];
                if (layer is null || !layer.IsVisible || layer.LocalPage is null) continue;
                CGameManialinkPage@ page = layer.LocalPage;
                CGameManialinkControl@ zone = page.GetFirstChild("frame-zone-selection");
                CGameManialinkControl@ club = page.GetFirstChild("frame-pinned-club");
                if ((zone !is null && zone.Visible) || (club !is null && club.Visible))
                    continue;
                if (calendar) {
                    if (page.GetFirstChild("button-previous-month") !is null &&
                            page.GetFirstChild("frame-map-rankings") !is null) return page;
                } else {
                    if (page.GetFirstChild("frame-map-0-0") is null) continue;
                    CGameManialinkLabel@ label = cast<CGameManialinkLabel@>(
                        page.GetFirstChild("label-title"));
                    if (label is null) continue;
                    string title = Text::StripFormatCodes(string(label.Value)).ToLower();
                    if (title.Contains("2026") &&
                            (title.Contains("automne") || title.Contains("fall"))) return page;
                }
            }
        } catch {
            // Trackmania may rebuild a menu during navigation.
        }
        return null;
    }

    // Shared fallback position for a tile without a visible native medal.
    bool MeasureGridSpacing(CGameManialinkPage@ page, int col, int row,
                            vec2 &out spacing) {
        if (page is null) return false;
        CGameManialinkFrame@ first = cast<CGameManialinkFrame@>(
            page.GetFirstChild("frame-map-" + col + "-" + row));
        CGameManialinkFrame@ right = cast<CGameManialinkFrame@>(
            page.GetFirstChild("frame-map-" + (col + 1) + "-" + row));
        CGameManialinkFrame@ below = cast<CGameManialinkFrame@>(
            page.GetFirstChild("frame-map-" + col + "-" + (row + 1)));
        if (first is null || right is null || below is null) return false;
        vec3 p = first.AbsolutePosition;
        vec3 r = right.AbsolutePosition;
        vec3 b = below.AbsolutePosition;
        spacing = vec2(r.x - p.x, b.y - p.y);
        return spacing.x >= 8.0f && spacing.x <= 80.0f &&
               spacing.y <= -3.0f && spacing.y >= -45.0f;
    }

    class BadgeLayout {
        float unit;
        float size;
        vec2 offset;
        vec2 gridSpacing;
        bool hasGrid;
    }

    BadgeLayout@ MakeBadgeLayout(CGameManialinkPage@ page, int gridCol, int gridRow,
                                 int sizePx, int offsetXPx, int offsetYPx) {
        BadgeLayout@ layout = BadgeLayout();
        float scale = float(Display::GetHeight()) / 1080.0f;
        layout.unit = Math::Min(float(Display::GetWidth()) / 320.0f,
                                float(Display::GetHeight()) / 180.0f);
        layout.size = float(sizePx) * scale;
        layout.offset = vec2(float(offsetXPx) * scale, float(offsetYPx) * scale);
        layout.hasGrid = MeasureGridSpacing(page, gridCol, gridRow, layout.gridSpacing);
        return layout;
    }

    // Call between nvg::Save()/Restore(), from Render() only.
    void DrawBadge(CGameManialinkFrame@ frame, int level, BadgeLayout@ layout) {
        if (frame is null || !frame.Visible || layout is null || level < 0 ||
                uint(level) >= badgeTextures.Length || badgeTextures[uint(level)] is null)
            return;
        CGameManialinkControl@ nativeMedal = frame.GetFirstChild("quad-medal");
        vec3 pos;
        if (nativeMedal !is null && nativeMedal.Visible) {
            pos = nativeMedal.AbsolutePosition;
        } else {
            if (!layout.hasGrid) return;
            pos = frame.AbsolutePosition;
            pos.x += layout.gridSpacing.x * 0.72f;
            pos.y += layout.gridSpacing.y * 0.35f;
        }
        float x = float(Display::GetWidth()) * 0.5f + pos.x * layout.unit + layout.offset.x;
        float y = float(Display::GetHeight()) * 0.5f - pos.y * layout.unit + layout.offset.y;
        if (x < 0 || y < 0 || x + layout.size > Display::GetWidth() ||
                y + layout.size > Display::GetHeight()) return;
        nvg::BeginPath();
        nvg::Rect(x, y, layout.size, layout.size);
        nvg::FillPaint(nvg::TexturePattern(vec2(x, y), vec2(layout.size, layout.size),
            0.0f, badgeTextures[uint(level)], 1.0f));
        nvg::Fill();
        nvg::ClosePath();
    }
}
