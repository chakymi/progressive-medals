# Maintainer review — Progressive Medals 0.2.1

## Purpose of this change

Replace the older Supabase-dependent code with a narrow client that only reads
the already published goal times and draws three custom icons for Fall 2026.

The authoring process used generative AI. A code review by an experienced
AngelScript/Openplanet developer is required; being shorter is not proof of
quality or safety.

## Scope kept deliberately small

- Current map: read-only public Apps Script API (positive milliseconds or `-1`).
- Fall 2026 menu: immutable 25-map published target snapshot, including the two
  historically adjusted maps and the five country-named maps in playlist order.
- Player PBs: grouped record lookup scoped to the authenticated account.
- Rendering: NanoVG overlay located by existing Trackmania menu control names.
- User-approved visual defaults: size 58 px, X +3 px at 1080p.

## Known technical review items

1. **Compile against the user's current Openplanet version.** The connector
   environment cannot compile AngelScript or load Trackmania.
2. Verify `NadeoServices::Post` response structure, error handling, permissions,
   authentication changes and record matching.
3. Test `Net::HttpGet` redirect handling from Apps Script to googleusercontent.
4. Inspect coroutine timing and ensure requests stay outside render callbacks.
5. Exercise account switching, partial responses, local PB changes and reconnection.
6. Test the `frame-map-*` / `quad-medal` anchors at multiple resolutions and
   UI scales. Trackmania may change these undocumented menu controls.
7. Review all included PNG assets and obtain redistribution permission.
8. Separate possible game UI/menu changes from the stable remote target data.

## Behavior not claimed as complete

- No menu integration for future official seasons or TOTDs.
- No standalone automatic campaign roster discovery.
- No independent certification of the code or packaging.
- No assertion that the Openplanet review team will accept the project.

## Non-destructive migration

The proposal lives in a review branch. Existing `main` remains unchanged.
The prior source, Supabase migrations, workflow scripts and GitHub Pages data
are available in commit history. Do not re-enable an obsolete publisher or
merge without reviewing the removal of those components.
