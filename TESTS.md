# Manual tests required in Trackmania / Openplanet

- [ ] Openplanet compiles all six `.as` files with no errors or warnings.
- [ ] Launch Fall 2026 and verify the positions and sizes of earned badges.
- [ ] The same maps and records yield the same badge tiers as v0.7.2.
- [ ] Open the TOTD calendar without crashing, including month transitions.
- [ ] TOTD 2026-11-11: a PB of 41.885s is Emerald with a 42.440s threshold
      in the reference snapshot.
- [ ] Open an unpublished TOTD; no custom medal appears.
- [ ] Open a month without a unique calendar match; no incorrect badges appear.
- [ ] Change Nadeo account (or sign out) and verify previous PBs disappear.
- [ ] Improve a local PB and check it overrides a slower cached official PB.
- [ ] Test offline goals using the bundled Sheet snapshot and stored cache.
- [ ] Verify bad and partial CSV data never overwrite validated targets.
- [ ] Test another resolution/UI scale if available.

Offline checks examine code shape, catalogue data and preservation of
coordinates. They are **not** game runtime tests. Keep the verified v0.7.2 ZIP
available as a rollback while testing this refactor.
