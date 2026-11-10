# Validation record

| Check | Status | Evidence |
| --- | --- | --- |
| Fall 2026 roster and unique UIDs | Offline check | `tools/validate_project.py` |
| Platinum / Emerald / Diamond time ordering | Offline check | Same |
| Fall 01 / 02 historical exceptions | Offline check | 20143/20098/20058 and 21564/21510/21425 ms |
| PNG resource presence and manifest | Offline check | Same (PNG signatures + RGBA) |
| Visual badge positioning in menu | User-confirmed on **previous** baseline | Screenshot shared on 10 November 2026 |
| 0.2.1 AngelScript compilation | **Not tested** | Requires installed Openplanet |
| 0.2.1 game runtime | **Not tested** | Requires Trackmania |
| Partial PB reply / account switch | **Not game-tested** | Manual test needed |
| TOTD/future season menu support | **Not implemented** | No such test possible |

Do not mark a runtime feature as validated until it is observed in game,
with the tested Openplanet version and a reproducible test case.
