# Real Tesla FSD vs ours (researched 2026-10-07)

Sources are public release notes and owner reports (search results, not Tesla's engineering docs): notateslaapp.com release notes for FSD 14 (2026.20.x), electrek.co FSD v14 release notes and "Actually Smart Summon" speed increase (2026-05-17), driveteslacanada.ca FSD 14.1 notes, Tesla Motors Club threads on lane changes and highway curves. What I could not find: real numbers for Autopark speed, or how FSD splits steering between neural net and rules. Treat the rest as the public picture, not the source code.

| Real FSD (v14) | Ours | Status |
|---|---|---|
| Arrival options: Parking Lot, Street, Driveway, Parking Garage, Curbside | same options, arrival sheet in the app | have it |
| "Pull over" as a destination: "drive to the vicinity and park if possible, otherwise pull over" | Banish tried spots only and gave up with an error | **fixed 2026.10.7**: Banish pulls over when no spot works |
| Speed profiles Sloth / Chill / Standard / Hurry (profile sets max speed, lane selection, assertiveness) | Sloth..Furious Max | have it |
| Actually Smart Summon tops out at 8 mph (was 6) | Summon / Banish drive by road at road speed; direct parking moves 2-3 m/s | Banish and Summon now start in the Hurry profile (were Standard) |
| Lane changes: signal first, EU rule 3 to 5 s before the move; unknown real US timing, owners report 2-5 s | 0.4 to 3 s depending on profile (was 0.4 to 1.6 s) | now 3 s Sloth/Chill/Standard, 2.5 Hurry |
| Emergency vehicles: pull over or yield | have it | have it |
| Navigation inside the network: blocked roads and detours | replans when off the path, no live blocked-road detection | gap |
| Highway curves: owners report wide or sloppy lines on sharp 65 mph curves, braking in the bend | steering limited to ~4 m/s^2 sideways above 18 mph, slows for bends | ours is deliberately conservative |
| Driver monitoring: camera first, then wheel torque | camera (iPad) or wheel nudge, off by default | have it |
| Reinforcement learning stage in training (v14) | practice runner tunes parking knobs by REINFORCE | much smaller, same idea |

## What this changed in our code
- Banish: falls back to pulling over (like the real "park if possible, otherwise pull over"), and uses the Hurry profile.
- Lane change signal lead time 3 s (2.5 s Hurry) so it reads like the real car.
- Parking moves a little faster (approach 2.5 m/s, back-out 2.2, three-point turn 1.8-2.2, arrival slowdown starts 30 m out at 4.5 m/s). Reverse back-in stays at 1.4 m/s because every faster try lost accuracy in the simulator (crooked finishes); the practice runner can still learn faster values within its range.

## Ideas not done (ask if you want them)
1. Blocked-road detour: when the map graph says a road is blocked by a stopped car for 20 s, route around it.
2. Speed profile that adapts to traffic ("FSD determines the appropriate speed from profile, limit and surrounding traffic").
3. Parking "vicinity" search: spiral outward from the destination instead of a fixed 400 m nearest-first list.
