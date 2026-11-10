# Progressive Medals — review candidate 0.2.1

An **unofficial Trackmania 2020 / Openplanet plugin** that shows Platinum,
Emerald and Diamond PNG badges on the **Fall 2026** campaign map grid.
A player's personal best determines the highest earned badge. Badges are
a NanoVG overlay, **not** new native Trackmania medals.

**Status:** functional menu presentation was demonstrated in-game by the owner
for the prior baseline. The 0.2.1 changes have **not** yet received an in-game
regression test or independent human review. This is not an approved Openplanet
release. Source was created and revised with generative AI assistance.

## What it does

- Reads the 25 Fall 2026 map UIDs and fixed target times from
  `plugin/catalog/fall-2026-goals.json`. Two user-approved historical exceptions
  are included for maps 01 and 02. Country-named maps follow playlist order.
- Retrieves the signed-in player's Fall 2026 PBs with **one grouped Nadeo Live
  Services request**, at most every 30 minutes while the menu is open.
- Uses a public Google Apps Script endpoint to retrieve three fixed goal times
  for the current loaded map. Published triples are cached in memory.
- Displays the highest earned medal on each map tile, using supplied PNGs.
  Default size **58px**, X offset **+3px**, Y offset **−28px** at 1080p.

No API credentials belong in this repository. The backend that captures and
publishes world-rank goals is a separate service; the plugin does not recalculate
or publish those goals.

## Local test installation

Copy the contents of the `plugin/` folder into one Openplanet development
plugin folder, preserving `info.toml`, both `.as` files, `assets/` and
`catalog/`. Install `NadeoServices`. Disable earlier Progressive Medals
versions to prevent duplicate overlays. Reload, open the Fall 2026 campaign
map selection grid, and check both earned and unearned medals.

The current-map status window can be toggled from the Openplanet menu. Its
three API requests are made only when a map needs goal data; unpublished
`-1` results are retried after ten minutes.

## Source layout

| File | Purpose |
| --- | --- |
| `plugin/Main.as` | Current-map goal fetch/cache, local PB, settings and UI |
| `plugin/MenuBadges.as` | Fall 2026 roster, grouped player PBs, map-grid drawing |
| `plugin/catalog/fall-2026-goals.json` | Immutable Fall 2026 target snapshot |
| `plugin/assets/*.png` | Three user-supplied medal icons |
| `tools/validate_project.py` | Offline integrity checks only |
| `REVIEW.md` | Human review checklist and known limitations |
| `TESTS.md` | Evidence versus tests still required |

## Not implemented / not guaranteed

- Campaign-menu badges for **future campaigns** or **TOTDs**.
- Compatibility with future changes to Trackmania's internal menu controls.
- Published-game support for every resolution or UI scale.
- Compilation/test certification for this GitHub review branch.

Please read `REVIEW.md` before submitting or publishing anything.

## Historical code

This branch intentionally removes the obsolete Supabase publisher, old
GitHub Actions publishing workflows, and the original large AngelScript
implementation from the proposed current tree. They remain available in Git
history and the unchanged `main` branch until this proposal is reviewed.

## Provenance

The owner specified the medal design and ranking rules. The code has been
developed with AI assistance. Independent technical review and confirmation of
PNG redistribution rights are required before a release.
