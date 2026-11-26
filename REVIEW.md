# Developer review — v0.8.0

## Why this refactor exists

Xertox identified duplication across the campaign and TOTD paths, redundant
checks, inconsistent PB/account handling, repeated data, mixed-language
comments and per-frame calendar lookups. The v0.7.2 gameplay behavior was
reported working, so **this change intentionally avoids redesigning the native
ManiaLink selectors, grid indices or overlay coordinates**.

## Changes

1. `BadgeCommon.as` owns the shared NanoVG drawing, scale, screen-boundary
   checks, native-medal/fallback position, grid spacing and menu-layer search.
2. The shared `PlayerPbs` object handles authentication changes and the
   fastest known PB consistently for both campaign and TOTD.
3. One function (`AreValidMedalTimes`) checks the ordering of the three goals,
   and `HighestBadge` uses it for both menu types.
4. `FindFall2026IndexByUid` is the only campaign UID index lookup;
   `MenuTarget`, `IsMenuUid`, duplicate texture lists and unused name reading
   have been removed. Image paths are declared once in `Main.as`.
5. All hard-coded references to the Fall 2026 cardinality use
   `FALL_MAP_COUNT`; the existing fixed 5x5 layout still uses
   `FALL_GRID_SIDE`.
6. `CalendarYearFromTitle` parses the visible year rather than scanning
   80 years × 12 months each frame. `ResolveTotdMonth` caches the answer
   by title/weekday/catalogue version. A prebuilt fallback index replaces
   rebuilding the catalogue UID key list on every frame.
7. Removed the redundant completed-request size check from `OfficialPbs.as`.
   Progressive download limits and final response-length limits remain.
8. `fall-2026-goals.json` contains ordered UIDs only; the bundled Sheet
   snapshot and the Sheet cache remain the sole source of target times.
9. All AngelScript comments are in English. UI strings remain in French.
   The plugin title and warning prefix are consistently `Progressive Medals`.

## Preservation and safety

- The exact Fall 2026 tile coordinates (`i / 5`, `i % 5`) are unchanged.
- The TOTD weekday/day-to-tile mapping and the native-medal fallback offsets
  (`0.72`, `0.35`) are unchanged.
- The two historical Fall 2026 exceptions are retained *in the Sheet snapshot*,
  not silently recalculated; no threshold values were changed.
- The cached Sheet snapshot and all three PNG assets are unchanged.
- The same three background tasks remain; workers never cache ManiaLink pages.
- When a future Sheet export has no Fall 2026 rows, previously validated
  Fall targets can be retained, without inventing new scores.

## Review and runtime risks

- **Mandatory:** compile against the target Openplanet version and test the
  actual campaign and TOTD menus; static checks cannot certify AngelScript.
- Native menu control names are undocumented and can change in Trackmania.
- Account switches during pending Nadeo network requests should be tested.
- Month inference from the calendar layout is deliberately conservative;
  ambiguous months display no badge when the title gives no unique month.
- The plugin uses a fixed Fall 2026 roster. Future campaign discovery is
  intentionally outside this refactor's scope.
- This code was developed with AI assistance and requires independent review.
