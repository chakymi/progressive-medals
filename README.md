# Progressive Medals — v0.8.0 (review candidate)

An unofficial AngelScript/Openplanet plugin for Trackmania 2020. It overlays
Platinum, Emerald and Diamond badges on the **Fall 2026** campaign menu and
on the **TOTD** calendar, according to the current player's personal best.
These badges are *not* native Trackmania medals.

## Data flow

- **Medal goals:** published `Medals` rows in the public Google Sheet, read by
  CSV export every 15 minutes. No Supabase or Apps Script is required.
- **Offline goals:** the bundled snapshot of those same published Sheet rows,
  followed by the most recently validated local cache.
- **Fall 2026 order:** `catalog/fall-2026-goals.json` contains *only* the 25
  ordered map UIDs. Its first two maps have historical exceptions in the Sheet;
  the plugin does not override or recalculate those times.
- **Player records:** grouped Nadeo Live Services requests. Local PBs can
  improve the cached records immediately; sign-out/account changes clear them.
- **Rendering:** NanoVG badges placed on visible native menu tiles. No
  native ManiaLink controls are modified or cached across frames.

## Source files

| File | Responsibility |
| --- | --- |
| `Main.as` | Settings, main loop, local PB reading and status window |
| `BadgeCommon.as` | Shared medal validation, PB/account state and badge drawing |
| `MenuBadges.as` | Fall 2026 playlist and menu-specific rendering |
| `TotdBadges.as` | Calendar month resolution and TOTD-specific rendering |
| `SheetCatalogue.as` | Google Sheet CSV parsing, cache and published target data |
| `OfficialPbs.as` | Validated grouped player-record request to Nadeo |

All **source comments are in English**. User-facing messages and setting labels
remain in French. Display defaults are unchanged: campaign badges 61 px,
TOTD badges 56 px (reference resolution: 1080p).

## Install locally

1. Close Trackmania, and remove other versions of this plugin.
2. Copy the complete `ProgressiveMedals_Sheets` folder into the Openplanet
   development plugins directory, retaining `.as`, `assets/` and `catalog/`.
3. Install/enable the `NadeoServices` dependency.
4. Restart in **Developer mode**. Check compilation and the status window.
5. Test Fall 2026 first, then the TOTD calendar (see `TESTS.md`).

Openplanet Regular mode requires an appropriate plugin signature. This
refactoring does not bypass or obtain one.

## Review status

This refactor has passed offline data and structural checks, **not an Openplanet
compile or in-game regression test**. `REVIEW.md` records the main changes and
remaining risks. The code was prepared with AI assistance; human review is
required before submitting it for signing or distribution.
