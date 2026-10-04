# Phase 8 playtest and balance record

What the Phase 8 balance pass measured and changed, kept in the repository: the final playtest tables, the baseline they are compared with, and the change log of every number moved. The numbers come from `scripts/playtest.gd`, a bot playing the three campaign missions headless through the real sim (`PlaytestPilot`: a *competent* pilot that plays like a careful player, and a *naive* one that attack-moves along the route). `docs/architecture.md` (Mission framework and campaign, Phase 8) describes how the harness and the data fit together.

## Reproducing

`make playtest` runs it; every setting is an environment variable (all optional; the full list is in the Makefile):

| variable | meaning | default |
|---|---|---|
| `MISSIONS` | `riverside,the_ford,old_mill` or any subset | all |
| `TIERS` | difficulty tiers 0 to 4 | 2 (the middle) |
| `SEEDS` | runs per mission, tier and pilot | 20 |
| `SEED_BASE` | first campaign seed; run i uses `SEED_BASE + i`, so `SEED_BASE=<seed> SEEDS=1` replays one run | 1000 |
| `PILOTS` | `competent`, `naive` | both |
| `CHAIN=1` | play the whole campaign per seed, survivors carrying over | 0 (fresh recruits) |
| `MAX_MINUTES` | game minutes before a run counts as a timeout | 25 |
| `OUT`, `RAW`, `REPORT`, `TRACE` | write the tables, write each run as JSON, merge `RAW` files into tables instead of playing, print a status line every N game seconds | |

```
make playtest                                                    # tier 2, both pilots, 20 seeds each, all missions (about 15 minutes)
MISSIONS=riverside TIERS=2 SEEDS=10 PILOTS=competent,naive make playtest
MISSIONS=old_mill TIERS=0,4 SEEDS=10 PILOTS=competent make playtest
CHAIN=1 TIERS=2 SEEDS=10 PILOTS=competent make playtest
MISSIONS=the_ford SEEDS=1 SEED_BASE=1003 PILOTS=naive TRACE=10 make playtest   # one run, watched
```

Seeds are `CampaignState.new_campaign(seed, tier)` with seed = 1000 + the run's index, and the world's seed is `mission_seed(index)` exactly as the App uses it. A run is exactly repeatable from its seed.

## The baseline, for comparison

The baseline is the campaign data as it stood before the balance pass (harness commit `13258d8`), tier 2 being the middle difficulty. It was re-run after the Old Mill stand-off fix (`8c12868`) so every before/after below has the same code. Its headline, from the refreshed first run of 210 runs:

At tier 2 every mission is won by almost any pilot that walks forward and fights; the real numbers are in the costs.

- **Competent pilot, tier 2: wins 100% of Riverside (20/20), The Ford (20/20) and Old Mill (20/20)**; mean losses 6%, 2% and 26% of the roster; 2.3, 2.1 and 8.3 minutes. A chained campaign (survivors carrying over) is cleared 10/10, with 0.8, 0.7 and 4.4 losses per mission.
- **Naive pilot (everyone attack-moves along the route, then at the nearest visible enemy; on The Ford back to the villager if he falls 25 m behind), tier 2: Riverside 95% wins (20% of the roster lost; one wipe-out, seed 1002, at 3.0 minutes), The Ford 100% (2%), Old Mill 100% (33%, 6.4 minutes).** No timeouts anywhere in 210 runs, and the only loss is that one Riverside run.
- **Old Mill's cost is one wave.** With the Stormcaller wave drawn (14 of 20 seeds, always wave 4) the competent pilot loses 7.0 soldiers (a third of the roster), 5 to 8 a run; without it 0.8. The naive pilot loses 7.0 with it and 5.5 without.
- **Old Mill's difficulty is not monotonic in the tier**: competent losses on the same 10 seeds are 8%, 26%, 8% of the roster at tiers 0, 2, 4 (the storm wave alone costs 2.7, 7.2 and 2.2 soldiers).

## The final playtest

The balance pass's closing run: the matrix the balance pass was asked for (tiers 0, 2 and 4, both pilots, chained), on the committed data (`2ea9cfb`: the STANDOFF fix `8c12868`, the visual data `8ca1929`, The Ford `a0441cb`, Old Mill `c1357a6`, Riverside `2ea9cfb`), with both pilots exactly as `13258d8` left them. Every number is the real sim driven headless by `scripts/playtest.gd`; seeds are `CampaignState.new_campaign(seed, tier)` with seed = 1000 + run index, so `SEED_BASE=<seed> SEEDS=1` replays any run.

### How it was run

| batch | settings | runs |
|---|---|---|
| tier 2, both pilots | `TIERS=2 SEEDS=20 PILOTS=<p>`, each mission (Old Mill split in two processes of 10) | 120 |
| tiers 0 and 4, competent | `TIERS=0,4 SEEDS=10 PILOTS=competent`, each mission | 60 |
| chained campaign, competent | `CHAIN=1 TIERS=2 SEEDS=10 PILOTS=competent` | 30 |
| extra, for steadier tier and chain rates | the same tier 0 / 4 and chain batches with `SEED_BASE=1010` | 90 |

12 processes for the matrix (559 s wall clock) and 4 for the extra seeds alongside it (552 s), each writing `RAW`, merged with `REPORT`. Cap 25 game minutes; nothing hit it. The tables under "The matrix" are the 210 runs of the planned matrix; "Twenty seeds" merges in the extra 90.

### Against the targets

The targets are the balance pass's goals: a win-rate band, a loss band and a length for each mission and pilot.

| target (tier 2 unless stated) | result | |
|---|---|---|
| Riverside: competent wins 100% | 100% | met |
| Riverside: competent losses 10-25% | 17% (2.4 of 14) | met |
| Riverside: naive wins 60-90% | 90% (95% on seeds 1000-1039) | met on these 20 seeds, at the edge; not over 40 |
| Riverside: median (won) >= 4 min | 4.0 (competent), 4.0 (naive) | met (just) |
| The Ford: competent wins >= 85% | 95% | met |
| The Ford: competent losses 15-35% | 21% (3.3 of 16) | met |
| The Ford: naive wins 30-70% (villager deaths the expected failure) | 45%; the villager died in 55% (killed by Rippers 11 of 11) | met |
| The Ford: pool ambushes spring in most runs | 100% of runs, every tier | met |
| The Ford: median (won) >= 4 min | 2.4 | **not met** (see "The Ford" in the change log below) |
| Old Mill: competent wins >= 80% | 100% | met |
| Old Mill: competent losses 25-45% | 30% (6.0 of 20) | met |
| Old Mill: naive wins 20-60%, timeouts < 10% | 45%, 0% timeouts | met |
| Old Mill: median (won) 6-15 min | 9.3 (competent), 6.7 (naive) | met |
| Tiers: losses rise, wins fall or stay at 100%, 0 -> 2 -> 4 (competent) | Riverside 11 / 17 / 38% lost, 100 / 100 / 100% won (20 seeds: 8 / 17 / 40%, 100 / 100 / 95%); The Ford 7 / 21 / 34%, 100 / 95 / 60% (20 seeds: 4 / 21 / 32%); Old Mill 7 / 30 / 57%, 100 / 100 / 70% (20 seeds: 7 / 30 / 55%, 100 / 100 / 60%) | met |
| Tier 4 competent wins 40-80% on The Ford and Old Mill | The Ford 60% (60% on 20 seeds), Old Mill 70% (60% on 20) | met |
| CHAIN: Old Mill wins >= 70% | 100% (10 of 10; 20 of 20) | met |

### Before and after (tier 2, 20 seeds; baseline re-run on the same code after the STANDOFF fix)

| | baseline | final |
|---|---|---|
| Riverside, competent | 100%, 6% lost, 2.3 min | 100%, 17% lost, 4.0 min |
| Riverside, naive | 95%, 20% lost, 2.8 min | 90%, 39% lost, 4.0 min |
| The Ford, competent | 100%, 2% lost, 2.1 min, pools sprung 0% | 95%, 21% lost, 2.4 min, sprung 100% |
| The Ford, naive | 100%, 2% lost, 2.1 min | 45%, 42% lost, 2.5 min |
| Old Mill, competent | 100%, 26% lost, 8.4 min | 100%, 30% lost, 9.3 min |
| Old Mill, naive | 100%, 32% lost, 6.3 min | 45%, 78% lost, 6.7 min, 0 timeouts |
| competent losses at tiers 0 / 2 / 4 | Riverside 2 / 6 / 13%, The Ford 1 / 2 / 9%, Old Mill 12 / 26 / 8% | Riverside 11 / 17 / 38%, The Ford 7 / 21 / 34%, Old Mill 7 / 30 / 57% |
| chained campaign, losses per mission | 0.8, 0.7, 4.4; cleared 100% | 2.1, 4.5, 3.7; cleared 100% |

### Old Mill: what each wave costs (tier 2, 20 seeds)

Each soldier's death is charged to the waves standing at that moment, split evenly (a scratch probe, not the harness):

| wave (times drawn) | husks (15) | rippers (16) | bags (17) | drifters (18) | storm (14) |
|---|---|---|---|---|---|
| competent, baseline | 0.0 | 0.9 | 0.0 | 0.0 | 6.2 |
| competent, final | 0.0 | 2.3 | 0.0 | 0.3 | 5.6 |
| naive, baseline | 0.9 | 2.1 | 0.2 | 1.4 | 3.4 |
| naive, final | 7.7 | 2.9 | 3.7 | 4.0 | 1.8 |

A storm draw costs a held ramp 7.2 soldiers, a draw without it 3.3 (baseline 6.9 and 0.8).

### The matrix (210 runs)

#### Results by mission, tier and pilot

| mission | tier | pilot | runs | win | lose | timeout | min (median) | min (p90) | min (median of wins) | losses/run | losses % of roster | losses/win | kills/run | friendly-fire deaths/run | stuck units/run |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| riverside | 0 | competent | 10 | 100% | 0% | 0% | 4.0 | 4.1 | 4.0 | 1.7 | 11% | 1.7 | 37.0 | 1.30 | 0.00 |
| riverside | 2 | competent | 20 | 100% | 0% | 0% | 4.0 | 4.1 | 4.0 | 2.4 | 17% | 2.4 | 48.0 | 0.75 | 0.05 |
| riverside | 2 | naive | 20 | 90% | 10% | 0% | 4.0 | 4.2 | 4.0 | 5.5 | 39% | 4.6 | 47.0 | 2.85 | 0.00 |
| riverside | 4 | competent | 10 | 100% | 0% | 0% | 4.0 | 4.1 | 4.0 | 4.9 | 38% | 4.9 | 56.0 | 0.40 | 0.00 |
| riverside (chain) | 2 | competent | 10 | 100% | 0% | 0% | 4.1 | 4.1 | 4.1 | 2.1 | 15% | 2.1 | 48.0 | 0.90 | 0.10 |
| the_ford | 0 | competent | 10 | 100% | 0% | 0% | 2.3 | 2.3 | 2.3 | 1.4 | 7% | 1.4 | 22.0 | 1.00 | 0.00 |
| the_ford | 2 | competent | 20 | 95% | 5% | 0% | 2.4 | 2.5 | 2.4 | 3.3 | 21% | 3.5 | 32.5 | 0.00 | 0.00 |
| the_ford | 2 | naive | 20 | 45% | 55% | 0% | 2.4 | 2.6 | 2.5 | 6.7 | 42% | 6.6 | 31.2 | 0.10 | 0.00 |
| the_ford | 4 | competent | 10 | 60% | 40% | 0% | 2.5 | 2.6 | 2.6 | 5.1 | 34% | 7.2 | 31.9 | 0.00 | 0.70 |
| the_ford (chain) | 2 | competent | 10 | 100% | 0% | 0% | 2.4 | 2.4 | 2.4 | 4.5 | 28% | 4.5 | 32.8 | 0.10 | 0.20 |
| old_mill | 0 | competent | 10 | 100% | 0% | 0% | 8.2 | 8.4 | 8.2 | 1.5 | 7% | 1.5 | 66.6 | 0.00 | 2.30 |
| old_mill | 2 | competent | 20 | 100% | 0% | 0% | 9.3 | 9.7 | 9.3 | 6.0 | 30% | 6.0 | 98.3 | 0.10 | 2.05 |
| old_mill | 2 | naive | 20 | 45% | 55% | 0% | 6.7 | 7.2 | 6.7 | 15.6 | 78% | 11.7 | 85.5 | 2.05 | 1.35 |
| old_mill | 4 | competent | 10 | 70% | 30% | 0% | 8.3 | 9.8 | 8.9 | 10.8 | 57% | 11.3 | 105.3 | 0.90 | 2.50 |
| old_mill (chain) | 2 | competent | 10 | 100% | 0% | 0% | 9.2 | 9.6 | 9.2 | 3.7 | 18% | 3.7 | 97.6 | 0.10 | 1.70 |

#### The Ford: the villager

| mode | tier | pilot | runs | villager died | killed by | his lowest hp, median / worst (%) | pool ambush sprung |
|---|---|---|---|---|---|---|---|
| fresh | 0 | competent | 10 | 0% | - | 100 / 100 | 100% |
| fresh | 2 | competent | 20 | 5% | husk 1 | 100 / 0 | 100% |
| fresh | 2 | naive | 20 | 55% | ripper 11 | 0 / 0 | 100% |
| fresh | 4 | competent | 10 | 40% | husk 4 | 24 / 0 | 100% |
| chain | 2 | competent | 10 | 0% | - | 100 / 72 | 100% |

#### Old Mill: the waves

| mode | tier | pilot | runs | waves drawn (runs) | ended badly in | charges laid by (median s) | sorties to finish a stand-off |
|---|---|---|---|---|---|---|---|
| fresh | 0 | competent | 10 | bags 9, drifters 9, rippers 9, husks 7, storm 6 | - | 33 | 0 |
| fresh | 2 | competent | 20 | drifters 18, bags 17, rippers 16, husks 15, storm 14 | - | 32 | 0 |
| fresh | 2 | naive | 20 | drifters 18, bags 17, rippers 16, husks 15, storm 14 | lost in wave 2 (rippers) 3, lost in wave 4 (drifters) 3, lost in wave 4 (storm) 3, lost in wave 3 (bags) 2 | n/a | 0 |
| fresh | 4 | competent | 10 | bags 9, drifters 9, rippers 9, husks 7, storm 6 | lost in wave 4 (storm) 3 | 32 | 1 |
| chain | 2 | competent | 10 | bags 9, drifters 9, rippers 9, husks 7, storm 6 | - | 32 | 0 |

#### The campaign chained (survivors carry over)

| tier | pilot | campaigns | riverside won | the_ford reached / won | old_mill reached / won | cleared |
|---|---|---|---|---|---|---|
| 2 | competent | 10 | 10 | 10 / 10 | 10 / 10 | 100% |

### Twenty seeds for the tier and chain rows (the matrix plus seeds 1010-1019)

| mission | tier | pilot | runs | win | lose | timeout | min (median) | min (p90) | min (median of wins) | losses/run | losses % of roster | losses/win | kills/run | friendly-fire deaths/run | stuck units/run |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| riverside | 0 | competent | 20 | 100% | 0% | 0% | 4.1 | 4.2 | 4.1 | 1.2 | 8% | 1.2 | 37.0 | 0.85 | 0.05 |
| riverside | 2 | competent | 20 | 100% | 0% | 0% | 4.0 | 4.1 | 4.0 | 2.4 | 17% | 2.4 | 48.0 | 0.75 | 0.05 |
| riverside | 2 | naive | 20 | 90% | 10% | 0% | 4.0 | 4.2 | 4.0 | 5.5 | 39% | 4.6 | 47.0 | 2.85 | 0.00 |
| riverside | 4 | competent | 20 | 95% | 5% | 0% | 4.0 | 4.1 | 4.0 | 5.2 | 40% | 4.7 | 55.9 | 0.75 | 0.00 |
| riverside (chain) | 2 | competent | 20 | 100% | 0% | 0% | 4.0 | 4.1 | 4.0 | 2.4 | 17% | 2.4 | 48.0 | 0.75 | 0.05 |
| the_ford | 0 | competent | 20 | 100% | 0% | 0% | 2.3 | 2.3 | 2.3 | 0.8 | 4% | 0.8 | 22.0 | 0.50 | 0.00 |
| the_ford | 2 | competent | 20 | 95% | 5% | 0% | 2.4 | 2.5 | 2.4 | 3.3 | 21% | 3.5 | 32.5 | 0.00 | 0.00 |
| the_ford | 2 | naive | 20 | 45% | 55% | 0% | 2.4 | 2.6 | 2.5 | 6.7 | 42% | 6.6 | 31.2 | 0.10 | 0.00 |
| the_ford | 4 | competent | 20 | 60% | 40% | 0% | 2.5 | 2.6 | 2.6 | 4.8 | 32% | 6.4 | 32.5 | 0.00 | 0.60 |
| the_ford (chain) | 2 | competent | 20 | 100% | 0% | 0% | 2.4 | 2.5 | 2.4 | 3.9 | 24% | 3.9 | 33.4 | 0.05 | 0.15 |
| old_mill | 0 | competent | 20 | 100% | 0% | 0% | 8.2 | 8.4 | 8.2 | 1.6 | 7% | 1.6 | 66.6 | 0.00 | 2.30 |
| old_mill | 2 | competent | 20 | 100% | 0% | 0% | 9.3 | 9.7 | 9.3 | 6.0 | 30% | 6.0 | 98.3 | 0.10 | 2.05 |
| old_mill | 2 | naive | 20 | 45% | 55% | 0% | 6.7 | 7.2 | 6.7 | 15.6 | 78% | 11.7 | 85.5 | 2.05 | 1.35 |
| old_mill | 4 | competent | 20 | 60% | 40% | 0% | 8.1 | 9.1 | 8.2 | 10.4 | 55% | 8.9 | 103.8 | 0.60 | 2.25 |
| old_mill (chain) | 2 | competent | 20 | 100% | 0% | 0% | 9.1 | 9.6 | 9.1 | 4.5 | 23% | 4.5 | 98.3 | 0.10 | 1.95 |

#### The campaign chained (survivors carry over)

| tier | pilot | campaigns | riverside won | the_ford reached / won | old_mill reached / won | cleared |
|---|---|---|---|---|---|---|
| 2 | competent | 20 | 20 | 20 / 20 | 20 / 20 | 100% |

### Anomalies (the matrix)

- riverside tier 2 competent: units stuck (walking 4 s without nearer a waypoint) in 1 of 20 runs, 1 units in all, seeds 1008.
  - seed 1008: stuck at tick 6270: shieldman #4 at (446, 379) m, water 0, MOVING, order ATTACK_MOVE, group no group
- riverside (chain) tier 2 competent: units stuck (walking 4 s without nearer a waypoint) in 1 of 10 runs, 1 units in all, seeds 1008.
  - seed 1008: stuck at tick 6270: shieldman #4 at (446, 379) m, water 0, MOVING, order ATTACK_MOVE, group no group
- the_ford tier 4 competent: units stuck (walking 4 s without nearer a waypoint) in 7 of 10 runs, 7 units in all, seeds 1000, 1001, 1002, 1003, 1005, 1006, 1009.
  - seed 1000: stuck at tick 1230: drifter #46 at (172, 192) m, water 4, MOVING, order ATTACK_MOVE, group drifters/PATROL
- the_ford (chain) tier 2 competent: units stuck (walking 4 s without nearer a waypoint) in 2 of 10 runs, 2 units in all, seeds 1001, 1002.
  - seed 1001: stuck at tick 1200: drifter #40 at (171, 191) m, water 4, MOVING, order ATTACK_MOVE, group drifters/PATROL
- old_mill tier 0 competent: units stuck (walking 4 s without nearer a waypoint) in 10 of 10 runs, 23 units in all, seeds 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007 and 2 more.
  - seed 1000: stuck at tick 1110: sapper #19 at (177, 169) m, water 0, MOVING, order ATTACK_MOVE, group no group
  - seed 1000: stuck at tick 1230: sapper #18 at (141, 129) m, water 0, MOVING, order ATTACK_MOVE, group no group
- old_mill tier 2 competent: units stuck (walking 4 s without nearer a waypoint) in 20 of 20 runs, 41 units in all, seeds 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007 and 12 more.
  - seed 1000: stuck at tick 1170: sapper #17 at (178, 169) m, water 0, MOVING, order ATTACK_MOVE, group no group
  - seed 1000: stuck at tick 3870: husk #64 at (127, 106) m, water 0, MOVING, order ATTACK_MOVE, group wave_husks/HUNT
- old_mill tier 2 naive: units stuck (walking 4 s without nearer a waypoint) in 13 of 20 runs, 27 units in all, seeds 1000, 1001, 1002, 1004, 1006, 1007, 1009, 1010 and 5 more.
  - seed 1000: stuck at tick 3540: husk #30 at (128, 80) m, water 0, MOVING, order ATTACK_MOVE, group wave_husks/HUNT
- old_mill tier 4 competent: units stuck (walking 4 s without nearer a waypoint) in 8 of 10 runs, 25 units in all, seeds 1000, 1001, 1002, 1003, 1005, 1006, 1008, 1009.
  - seed 1000: stuck at tick 3510: husk #40 at (198, 186) m, water 0, MOVING, order ATTACK_MOVE, group wave_husks/HUNT
  - seed 1000: stuck at tick 3570: husk #48 at (201, 187) m, water 0, MOVING, order ATTACK_MOVE, group wave_husks/HUNT
  - seed 1000: stuck at tick 3600: husk #59 at (201, 186) m, water 0, MOVING, order ATTACK_MOVE, group wave_husks/HUNT
- old_mill (chain) tier 2 competent: units stuck (walking 4 s without nearer a waypoint) in 9 of 10 runs, 17 units in all, seeds 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1008 and 1 more.
  - seed 1000: stuck at tick 3810: husk #76 at (127, 106) m, water 0, MOVING, order ATTACK_MOVE, group wave_husks/HUNT

Notes on them:
- **No timeouts, no instant losses, no stalemates** in the 300 runs. The Old Mill Drifter stand-off under the west cliff (a baseline finding, fixed by the STANDOFF fix below) is gone: the first naive pilot, which holds the yard and never hunts, now wins all 20 tier-2 seeds it used to time out 14 times in.
- **Old Mill, stuck units**: besides the Sappers coming back to the ramp heads (as in the baseline), the larger hordes now crowd the ramp feet: Husks of the 40-strong wave waiting their turn at (127, 106) and (200, 186). Crowding, not a path fault; they reach the ramp once those ahead are cut down.
- **The Ford, a Drifter stalled over deep water** at about (172, 192) at tier 4 and in chained runs: a baseline finding, unchanged.
- **Riverside, one Shieldman** stuck once for 4 s in the village (seed 1008), at the square.

## After the final review (Riverside's ford objective, The Ford's landing objective)

The whole-branch review changed two objectives' triggers (data only; no group, count, spawn or timer moved):

- **Riverside:** "Cross the ford" (`at_ford`) moved from the middle of the ford (300, 226) m, radius 15, which fired about 5 m short of the water, to the dry south landing, radius 8 m round (300, 244) m. The water tip ("The water slows you.") moved to a new `in_ford` trigger on the old spot, radius 8.
- **The Ford:** the optional objective is now "Clear the north landing", done by a new `landing_cleared` trigger (the landing guard group cleared), not by reaching the gate.

Neither trigger starts a spawn, a behaviour or a win, so the sim plays the same fights. The harness had read its Riverside route's first leg from `at_ford`'s centre; it now reads `in_ford`'s (the same point as before), so both pilots march exactly the route they did. Checked with the baseline code (`76bb906`) and the fixed code, `MISSIONS=riverside,the_ford TIERS=2 SEEDS=10 PILOTS=competent,naive`:

| | before the fix | after the fix |
|---|---|---|
| Riverside, tier 2, seeds 1000-1009 | competent 100%, 2.1 lost (15%), 4.1 min; naive 90%, 5.5 lost (39%), 4.0 min | the same on every one of the 20 runs (identical ticks, losses, kills and friendly-fire deaths) |
| The Ford, tier 2, seeds 1000-1009 | competent 90%, 2.5 lost (16%), 2.4 min; naive 40%, 7.1 lost (44%), 2.5 min | the same on every one of the 20 runs |

(The Ford's runs are identical whatever the harness reads, since its route uses `crossing`, `north` and `home`.) The 20-seed Riverside rows in the final tables above were re-derived from the baseline code on seeds 1000-1019 as a check and come out as printed: competent 100%, 17% lost; naive 90%, 39%.

A first attempt left the harness reading `at_ford`, so the pilots' first leg ended on the south bank, 18 m farther on. The runs it produced differed (a different first leg reshuffles every later draw): competent 100%, 16% lost, 4.0 min; naive 100% over 40 seeds (it was 95%), 30% lost (it was 37%). Nothing in the missions had changed; that is the harness's route shifting, and why the route now stays at the ford's middle.

## The change log

Every number is from `scripts/playtest.gd` on the real sim, both pilots unchanged from `13258d8`. "Tier 2" rows are 20 seeds (1000 to 1019) per pilot unless noted; tier 0 and 4 rows are competent only. "Losses" is soldiers dead or converted per run (and % of the roster); "min" is the median length of the won runs. The baseline is the refreshed Task 9 baseline re-run after the STANDOFF fix, so every before/after below has the same code.

### 0. The STANDOFF fix (code, commit `8c12868`)

`StandoffSpot._fits` now requires the same clear flight `RangedCombat` checks before it takes a target (`RangedCombat.clear_launch_from`, lifted out of `_aim`), and `find` skips a spot within a move's arrival radius of the unit (a second face of the same stalemate: on the cliff face a spot 18 cm away fitted, but a move that short ends before it starts, so the Drifter was re-sent there for ever).

| | before | after |
|---|---|---|
| Old Mill, the first (holding) naive pilot, tier 2, 20 seeds | 14 timeouts, 2 Drifters idle at (130, 159-161) | 20 wins, 8.8-9.1 min, 0-1 lost |
| Old Mill, current pilots, tier 2 (competent / naive) | 100% / 100%, 26% / 33% lost | 100% / 100%, 26% / 32% lost |
| Old Mill, competent, tiers 0 / 4 | 8% / 8% lost | 12% / 8% lost |
| Riverside, The Ford | | identical |

### 1. The Ford

Baseline, tier 2: competent 100% wins, 0.3 lost (2%), 2.1 min; naive 100%, 0.3 (2%), 2.1 min; pool ambushes sprung 0%; villager never died (lowest hp 68%). Tiers 0 / 2 / 4 competent: 1% / 2% / 9% lost, all 100%.

#### 1a. The pools spring at the crossing

The `crossing` trigger (villager within 12 m of the ford's middle) now also SET_BEHAVIORs `pool_w` and `pool_e` to HUNT, which springs them (surfaces the Husks). The road is 26 m from each pool and their alert radius was 8 m, so they had never sprung. Their own alert radius goes 8 → 12 m (a soldier on a pool's shallow shelf springs it early); measured to make no difference to either pilot, since the trigger always fires first.

| tier 2 | competent | naive |
|---|---|---|
| before | 100%, 0.3 lost (2%), 2.1 min, sprung 0% | 100%, 0.3 (2%), 2.1 min, sprung 0% |
| after | 100%, 0.8 lost (5%), 2.3 min, sprung 100% | 100%, 2.4 (15%), 2.3 min, sprung 100% |

#### 1b. A Ripper pack behind the escort, more Rippers, deeper pools

What was learned first (all tier 2, 20 seeds, from 1a):
- Threats that meet the escort from the front or the sides hurt the competent pilot and never the naive one. The naive army moves at its slowest soldier's pace (a Sapper's 2.0 m/s), so the villager (2.2 m/s) trails right behind it and is never the nearest target; the competent pilot keeps the melee 8 m ahead and only the Longbows and Wardens at his sides, and when the melee is busy he keeps walking (a soldier is within 12 m) into whatever is next. Examples: Rippers on `crossing` from the east woods (4 → 6): competent 85% wins, naive 90%; 8 Husks a pool: competent 70%, naive 100%, naive villager never touched; rousing the landing guard on `crossing`: competent 25%, naive 100%; pools that FLANK the villager: competent 75%, naive 100%.
- A threat from behind is what separates them: the naive villager is last in line, while the competent pilot's Sappers walk 6 m behind him (a Ripper pack's focus) and its melee turns back for anything within 25 m of him.
- Its timing is everything. Six rear Rippers spawned the tick after `crossing` from (100, 260) m: naive 65% wins on seeds 1000-1019 but 85% on 1020-1039; 3 s later, 95%; from 20 m farther, 95%; from 20 m nearer, 60%.

The change:
- New group `rippers_rear` (FLANK, ranged and support), 3 / 4 / 6 / 6 / 7 Rippers by tier, spawned by a new `rear` trigger 3 s (90 ticks) after `crossing` (so its warning, "Rippers on the south bank, behind you!", follows the crossing's hint), at (130, 250) m: 75 m south-west of where the road enters the water, so it reaches the escort while it is still in the water fighting the pools.
- The east-woods `rippers` (still late, on `north`): 3 / 3 / 4 / 5 / 6 → 3 / 4 / 6 / 6 / 7.
- Husks per pool: 4 / 4 / 5 / 6 / 7 → 4 / 5 / 6 / 6 / 7.

| | competent | naive |
|---|---|---|
| tier 2, before (1a) | 100%, 0.8 lost (5%), 2.3 min | 100%, 2.4 (15%), 2.3 min |
| tier 2, after, seeds 1000-1019 | 95%, 3.3 lost (21%), 2.4 min | 45%, 6.7 (42%), 2.5 min; villager died 55% |
| tier 2, after, seeds 1020-1039 | 100%, 3.0 lost (19%), 2.4 min | 65%, 6.3 (40%), 2.5 min; villager died 35% |
| tier 0, after (20 seeds) | 100%, 0.8 lost (4%) | |
| tier 4, after (20 seeds) | 60%, 4.8 lost (32%) | |

Tier 4 was first 8 / 8 / 8 (pools, rear, east): 20% wins, 41% lost. Measured mixes (20 seeds): 7 / 7 / 7 60% (32% lost), 7 / 6 / 6 70% (25%), 8 / 7 / 6 50% (37%), 8 / 6 / 7 35% (27%); 7 / 7 / 7 kept.

**Length is not met** (2.4 min against ≥ 4). The villager walks about 240 m of road at 2.2 m/s (about 2 minutes); content only adds time by stopping him (a visible enemy within 10 m), which means fighting at his side, and a fight long enough to add two minutes there kills him for the competent pilot first.

### 2. Old Mill

Baseline (after the STANDOFF fix), tier 2: competent 100% wins, 5.1 lost (26%), 8.4 min; naive 100%, 6.4 (32%), 6.3 min, no timeouts. Tiers 0 / 2 / 4 competent: 12% / 26% / 8% lost, all won. Chained: 100%, 4.4 lost.

What each wave cost, charging every death to the waves standing at that moment (tier 2, 20 seeds, from a throwaway probe that was not kept):

| wave (times drawn) | husks (15) | rippers (16) | bags (17) | drifters (18) | storm (14) |
|---|---|---|---|---|---|
| competent, baseline | 0.0 | 0.9 | 0.0 | 0.0 | 6.2 |
| naive, baseline | 0.9 | 2.1 | 0.2 | 1.4 | 3.4 |

What was learned:
- **The storm's edge decides its cost.** Two Stormcallers and 8 Husks at tier 2, competent, the same 20 seeds, by edge: north 4.1 lost, west 0.9, south 6.9, east 3.9 (without the storm 0.8). Lightning needs a clear line up a ramp's axis to the soldiers holding its head; from the south the approach runs up the south-east ramp's axis, from the west it never does. Tier 2 sent the storm from the south and tier 4 from the north, which is why tier 4 was the easier one (the baseline's non-monotonic Old Mill tiers), not "wave splitting".
- **A held ramp is nearly free against everything else.** Twice the Husks in every wave (28 Husks; rippers 6+12; bags 4+16; drifters 12+6) cost the competent pilot 0.7 a run without the storm; 9 Rippers, 6 Blightbags, 8 Drifters 1.3. Satchels, grenades and four Longbows on a plateau 12 m up (50 m against the Drifters' 40, shortened uphill) shred whatever climbs a ramp. Only the Rippers (fast, going for the archers and Sappers) and lightning get through.
- **The naive pilot fights in the open** (no fog of war: it sees each wave as it spawns at the edge and marches out to it), so the same sizes that cost a held ramp nothing grind it down; its other failure is an overrun, when fast Rippers chase its slow Sappers and Wardens into the yard while the army is out.

Steps (tier 2, 20 seeds each, both pilots; competent / naive):

| step | competent | naive |
|---|---|---|
| baseline | 100%, 26% lost (storm draws 6.9, others 0.8) | 100%, 32% |
| 1.5x Husks in every wave | 100%, 30% (8.3 / 1.0) | 95%, 38% |
| 2x Husks | 100%, 32% (8.9 / 0.7) | 100%, 50% |
| 30 Husks, rippers 10+10, bags 6+16, drifters 12+8, storm 12+2 | 100%, 35% (8.9 / 2.7) | 90%, 47% |
| the same with one Stormcaller | 100%, 23% (5.5 / 2.7) | 95%, 42% |
| 36 Husks, rippers 12+6, bags 8+16, drifters 12+12, storm 16+1 | 95%, 27% (6.6 / 2.7) | 65%, 66% |
| **kept: as above with 40 Husks** | **100%, 30% (7.2 / 3.3), 9.3 min** | **45%, 78%, 6.8 min, 0 timeouts** |

The change (all per tier, 0 to 4; each wave now has its own unit entries, since the old ones were shared between waves):

| wave | before | after |
|---|---|---|
| husks | Husks 10, 12, 14, 16, 18 | 24, 30, 40, 42, 44 |
| rippers | 6 Rippers + 6 Husks | Rippers 8, 10, 12, 13, 14 + 6 Husks |
| bags | 4 Blightbags + 8 Husks | Blightbags 6, 7, 8, 8, 9 + Husks 12, 14, 16, 17, 18 |
| drifters | 6 Husks + 6 Drifters | Husks and Drifters 8, 10, 12, 13, 14 each |
| storm | 8 Husks + 2 Stormcallers | Husks 10, 13, 16, 16, 16 + Stormcallers 1, 1, 1, 2, 2 |
| edges, tier 4 | rippers south, storm north | rippers north, storm south (tier 3 unchanged: rippers east, storm west) |

Results (competent unless noted; 20 seeds):

| | before | after |
|---|---|---|
| tier 0 | 100%, 12% lost | 100%, 7% lost, 8.2 min |
| tier 2 competent | 100%, 26% lost, 8.4 min | 100%, 30% lost, 9.3 min |
| tier 2 naive | 100%, 32% lost, 6.3 min | 45% wins, 78% lost, 6.8 min, 0 timeouts |
| tier 4 | 100%, 8% lost (10 seeds) | 60% wins, 55% lost, 8.2 min, 0 timeouts |
| per wave, competent (husks / rippers / bags / drifters / storm) | 0.0 / 0.9 / 0.0 / 0.0 / 6.2 | 0.0 / 2.3 / 0.0 / 0.3 / 5.6 |
| per wave, naive | 0.9 / 2.1 / 0.2 / 1.4 / 3.4 | 7.7 / 2.9 / 3.7 / 4.0 / 1.8 |

Tier 4 was first sized with the tier-2 steps carried on (44 Husks, rippers 16, bags 10+20, drifters 16+16, storm 20+2): 30% wins, 74% lost, and one timeout (seed 1007: the last Drifter and both Stormcallers circled the whole map edge for ten minutes ahead of six soldiers; the playtest's note on a Drifter that circles the map edge). The kept tier 4 is a step down from that.

The storm still costs a held ramp the most (5.6 of the 7.2 a storm draw costs), but no longer six times the rest: a draw without it costs 3.3 (was 0.8). The Husk, Blightbag and Drifter waves cost a squad that holds both ramp heads almost nothing at any size tried; that is the competent pilot's perfect chokepoint play, and they are what breaks a squad that leaves the plateau.

### 3. Riverside

Baseline, tier 2: competent 100% wins, 0.8 lost (6%), 2.3 min; naive 95%, 2.8 (20%), 2.8 min (the one loss a wipe, seed 1002). Tiers 0 / 2 / 4 competent: 2% / 6% / 13% lost, all won. The squad crosses the ford by about 40 s, meets the second field patrol at 75 s and the village at 105 s, and every fight (five Husks, then eight) is over in seconds; the raid (3 Rippers at 11 Husk deaths) was dead by 136 s.

What was tried (tier 2, competent / naive, 20 seeds each unless noted):

| step | competent | naive |
|---|---|---|
| baseline | 100%, 6%, 2.3 min | 95%, 20%, 2.8 min |
| two roaming bands of 6 (south and south-west fields; measured from the square at (445, 375) the kept waypoints are 95-118 m south and 107-142 m south-west, not the "90-125 m" first written here), roused 20 s after the squad reaches the village; raid at 24 Husk deaths, 4 Rippers from (505, 480) | 100%, 8%, 3.3 min | 100%, 30%, 3.7 min |
| roused at 40 s, raid at 28 deaths, from (505, 505) | 100%, 10%, 4.0 min | 100%, 21%, 4.0 min |
| ...with 6 Rippers | 100%, 12%, 4.1 min | 100%, 23%, 4.0 min |
| ...and a village guard of 10 | 100%, 18%, 3.9 min | 95%, 27%, 4.0 min |
| ...and 7 Husks in each field and village patrol (the raid at 28 deaths now came before the roamers: 3.6 min) | 100%, 18%, 3.6 min | 85%, 47%, 3.8 min |
| raid on 6 roamer deaths instead | 100%, 17%, 4.0 min | 90%, 39%, 4.0 min (95% on 40 seeds) |
| ...7 Rippers | 100%, 22%, 4.0 min | 92% on 40 seeds |
| ...7 Rippers, raid on 4 roamer deaths, bands of 7 | 100%, 14%, 4.0 min | 90% on 40 seeds |
| ...7 Rippers, guard 12 | 100%, 27%, 4.1 min | 92% on 40 seeds |
| **kept: 5 Rippers, raid on 6 roamer deaths, bands of 6, guard 10, patrols of 7** | **100%, 17%, 4.0 min** | **95% (40 seeds), 37%, 4.0 min** |

The change:
- Field and village patrols 5 → 7 Husks (one entry for the three, as before).
- Village guard 6 / 7 / 8 / 9 / 10 → 6 / 8 / 10 / 11 / 12.
- Two new PATROL bands, `field_roamers_s` (loop (420, 490), (470, 490), (445, 470)) and `field_roamers_w` (loop (350, 480), (380, 470), (360, 440)), 4 / 5 / 6 / 7 / 8 Husks each, alert 12 m; a new trigger `stirring` 40 s (1200 ticks) after `hint_grenade` sets both hunting: "The dead in the fields have heard you. They are coming."
- `raid` fires on 6 roamer deaths (was 11 deaths across the four first Husk groups), so the Rippers come as the field dead fall; raiders 2 / 3 / 3 / 4 / 5 → 2 / 3 / 5 / 6 / 7, spawned at (505, 505) m, the village's far south-east corner (was (492, 405)).

| | before | after |
|---|---|---|
| tier 2 competent | 100%, 0.8 lost (6%), 2.3 min | 100%, 2.4 lost (17%), 4.0 min |
| tier 2 naive | 95%, 2.8 lost (20%), 2.8 min | 95% (38 of 40), 5.2 lost (37%), 4.0 min |
| tier 0 / 4 competent (20 seeds) | 100% / 100%, 2% / 13% lost | 100% / 95%, 8% / 40% lost |

**Naive wins are not brought into 60-90%** (95% over 40 seeds, against 60-90). Every change that pushed them under 90% did it with more Rippers (7 or more at tier 2) or a bigger guard, which also took the competent pilot past 25% lost or the raid past "a few Rippers"; the naive pilot's losses rose from 20% to 37% of the roster, but a squad that marches as one block through one group at a time rarely loses outright. Kept at 5 Rippers for the tutorial's promise.

### 4. Visual (commit `8ca1929`)

Windowed captures (GL Compatibility on Metal, 1152x648) were compared before and after (`make capture` takes them again; the pictures themselves are not committed). Before = `git show 13258d8:data/atmospheres/old_mill.tres`, after = the committed file. Colours are the file's `Color(r, g, b, a)` values (sRGB by the project's convention, tuned by eye).

#### The Ford's camera

| | before | after |
|---|---|---|
| `camera_start` (mission.tres) and `CAMERA_START` (gen_the_ford.gd) | (192, 255) m | (192, 285) m |

The squad deploys at (192, 300): the old focus was 45 m north of it, so the camera, which sits south of its focus, put the squad directly under it, behind the control bar. The new focus is 15 m up the road from the squad.

#### Old Mill's atmosphere (`data/atmospheres/old_mill.tres`)

Changed (every colour moved, not only the brightness):

| field | before | after |
|---|---|---|
| `ambient_color` | (0.45, 0.28, 0.22) | (0.58, 0.45, 0.38) |
| `ambient_energy` | 0.32 | 0.48 (Riverside's is 0.5) |
| `sun_color` | (1, 0.55, 0.25) | (1, 0.62, 0.36) |
| `sun_energy` | 0.75 | 1.25 |
| `sun_pitch_degrees` | -12 | -35 |
| `fog_color` | (0.38, 0.18, 0.10) | (0.37, 0.19, 0.11) |
| `fog_density` | 0.005 | 0.0042 |
| `terrain_tint` | (0.85, 0.65, 0.55) | (0.95, 0.86, 0.78) |
| `terrain_desaturation` | 0.55 | 0.42 |
| `ground_recolor[0]` GRASS | (0.16, 0.10, 0.07, 0.6) | (0.30, 0.20, 0.12, 0.3) |
| `ground_recolor[1]` BRUSH | (0.10, 0.06, 0.04, 0.65) | (0.14, 0.08, 0.05, 0.5) |
| `ground_recolor[2]` WOOD | (0.08, 0.05, 0.04, 0.6) | (0.08, 0.05, 0.04, 0.5) |
| `ground_recolor[3]` SAND | (0.28, 0.20, 0.15, 0.4) | (0.42, 0.32, 0.22, 0.3) |
| `ground_recolor[4]` ROCK | (0.20, 0.15, 0.13, 0.3) | (0.38, 0.32, 0.28, 0.2) |

Unchanged: `background_color` (0.42, 0.20, 0.10) (the ember sky), `water_tint` (0.03, 0.02, 0.03, 0.85), `ash_fall` 0.6, `ash_color` (0.30, 0.26, 0.24), `fog_enabled`, `sun_yaw_degrees`.

The test pin on the exact 0.55 desaturation became a 0.4-0.6 range; the ordering (Riverside < The Ford < Old Mill) and headroom checks remain. `docs/architecture.md` has the same numbers under Atmosphere.

