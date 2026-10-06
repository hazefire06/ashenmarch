# Phase 9 playtest and balance record

What the Phase 9 balance pass measured and changed: the skirmish unit costs, one army template and one map's flags, tuned from tables made by bots playing skirmishes headless through the real sim (`make skirmish-playtest`, `scripts/skirmish_playtest.gd`). `docs/architecture.md` (Skirmish vs AI, Phase 9) describes the harness and how the commander and the data fit together.

## Reproducing

Every setting is an environment variable (all optional; the full list is at the head of `scripts/skirmish_playtest.gd` and in the Makefile):

| variable | meaning | default |
|---|---|---|
| `MATRIX` | `A` (commander against commander), `B` (a pilot plays Light against the Dark commander) | both |
| `MAPS`, `MODES` | `riverside,the_ford,old_mill`; `body_count,king_of_the_hill,capture_the_flags` | all |
| `SEEDS`, `SEED_BASE` | runs per cell (2 for A, 5 for B); first world seed, run i uses `SEED_BASE + i` | 1000 |
| `BUDGET`, `MINUTES` | points each army is bought with; the clock | 1000, 10 |
| `PILOTS` | (B) `competent`, `naive` | both |
| `PAIRINGS` | (A) `<light template>:<dark template>` list | each Light template against `dark_balanced`, `light_balanced` against each Dark one (7) |
| `DARK_TEMPLATES`, `LIGHT_TEMPLATES` | (B) the commander's armies; the pilot's | all four; `light_balanced` |
| `STARTS` | the starts Light plays from | A: both; B: by seed parity |
| `RAW`, `REPORT`, `OUT`, `TRACE` | write each run as JSON; merge RAW files into tables instead of playing; write the tables; a status line every N game seconds | |

A cell is a map and a mode (and a pairing and a start for A, a template and a pilot for B). Runs are deterministic and independent, so the matrices split across processes by matrix, map and mode, each writing RAW, and `REPORT` merges them:

```
for M in A B; do for MAP in riverside the_ford old_mill; do for MODE in body_count king_of_the_hill capture_the_flags; do
  MATRIX=$M MAPS=$MAP MODES=$MODE RAW=runs/$M-$MAP-$MODE.jsonl make skirmish-playtest &
done; done; done; wait
REPORT=$(ls runs/*.jsonl | paste -sd, -) OUT=tables.md make skirmish-playtest
MATRIX=B MAPS=old_mill MODES=king_of_the_hill SEEDS=1 SEED_BASE=1003 PILOTS=naive TRACE=10 make skirmish-playtest   # one run, watched
```

The full matrices (612 runs) took 38 minutes on 14 processes with the machine otherwise busy; a 10-minute skirmish that runs to time is about 30 s, most end by elimination in 2 to 4 game minutes.

## Targets (from the plan) and where they ended

| | target | result |
|---|---|---|
| A: Light wins overall | 40 to 60% | **53%** |
| A: each map and mode | 30 to 70% | **36 to 64%** |
| A: no pairing above | 85% | **86%** (Shield Wall against Balanced, 36 runs, about ±6%): at the line |
| A: draws | under 15% | **1%** |
| B: competent pilot wins | 60 to 85% | **60%** |
| B: naive pilot wins | 20 to 50% | **62%**: missed, see below |

**Why the naive target can't be met by costs.** In a skirmish the two pilots play alike: 60% and 62% here, 72% and 72% at one screen, 39% and 33% at another. Phase 8's competent pilot earns its margin from mission knowledge (the ramps, the escort, satchels laid ahead of waves); a skirmish is one or two big fights, which a blob that attack-moves (the naive pilot) wins about as often as a careful one. Costs move both together, so they were tuned to parity commander against commander (A), the one measure that compares the sides under equal control. A person, who uses formations, focus fire and terrain, should do better than either bot. A skirmish difficulty setting would be the lever (Not yet).

## The baseline, before (first-guess costs)

Costs: Shieldman 30, Reaver 40, Longbow 45, Sapper 55, Warden 50; Husk 20, Ripper 35, Blightbag 40, Drifter 40, Stormcaller 70. **One seed per cell** (198 runs, not the full 612: the first full run was stopped at 58 runs once it was plain how lopsided it was, to spend the machine on the screens instead).

### Matrix A: commander against commander (126 runs)

#### Overall

| scope | runs | Light win | Dark win | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|
| all runs | 126 | 97% | 3% | 0% | 0% | 98% | 4.0 | 7.3 | 34.0 |

#### By map and mode

| map / mode | runs | Light win | Dark win | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|
| riverside / body_count | 14 | 93% | 7% | 0% | 0% | 100% | 4.9 | 10.6 | 33.6 |
| riverside / king_of_the_hill | 14 | 100% | 0% | 0% | 0% | 100% | 8.5 | 5.6 | 34.6 |
| riverside / capture_the_flags | 14 | 100% | 0% | 0% | 0% | 79% | 7.4 | 6.9 | 33.9 |
| the_ford / body_count | 14 | 100% | 0% | 0% | 0% | 100% | 3.7 | 8.9 | 34.6 |
| the_ford / king_of_the_hill | 14 | 100% | 0% | 0% | 0% | 100% | 8.5 | 4.3 | 34.6 |
| the_ford / capture_the_flags | 14 | 86% | 14% | 0% | 0% | 100% | 2.3 | 12.5 | 31.4 |
| old_mill / body_count | 14 | 100% | 0% | 0% | 0% | 100% | 3.4 | 6.3 | 34.6 |
| old_mill / king_of_the_hill | 14 | 100% | 0% | 0% | 0% | 100% | 8.7 | 3.4 | 34.6 |
| old_mill / capture_the_flags | 14 | 93% | 7% | 0% | 0% | 100% | 1.8 | 7.2 | 34.1 |

#### By pairing of army templates

| Light vs Dark | runs | Light win | Dark win | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|
| light_balanced vs dark_balanced | 18 | 89% | 11% | 0% | 0% | 94% | 3.6 | 8.8 | 32.2 |
| light_balanced vs dark_horde | 18 | 100% | 0% | 0% | 0% | 100% | 4.0 | 5.3 | 39.0 |
| light_balanced vs dark_raiders | 18 | 100% | 0% | 0% | 0% | 100% | 4.0 | 5.1 | 35.0 |
| light_balanced vs dark_storm | 18 | 89% | 11% | 0% | 0% | 94% | 4.1 | 10.2 | 30.1 |
| light_shield_wall vs dark_balanced | 18 | 100% | 0% | 0% | 0% | 100% | 6.1 | 5.1 | 34.0 |
| light_shock vs dark_balanced | 18 | 100% | 0% | 0% | 0% | 100% | 3.3 | 10.2 | 34.0 |
| light_siege vs dark_balanced | 18 | 100% | 0% | 0% | 0% | 94% | 4.3 | 6.3 | 33.7 |

#### By Light's start

| Light starts at | runs | Light win | Dark win | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|
| start A | 63 | 97% | 3% | 0% | 0% | 98% | 3.7 | 8.0 | 34.0 |
| start B | 63 | 97% | 3% | 0% | 0% | 97% | 4.9 | 6.6 | 34.0 |

### Matrix B: a pilot plays Light against the Dark commander (72 runs)

Win is the pilot's, loss the commander's.

#### By pilot

| pilot | scope | runs | win | loss | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|---|
| competent | all | 36 | 100% | 0% | 0% | 0% | 97% | 3.6 | 6.6 | 34.6 |
| naive | all | 36 | 94% | 6% | 0% | 0% | 97% | 4.9 | 6.2 | 33.8 |

#### By pilot and Dark template

| pilot | Dark template | runs | win | loss | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|---|
| competent | dark_balanced | 9 | 100% | 0% | 0% | 0% | 100% | 3.4 | 8.4 | 34.0 |
| competent | dark_horde | 9 | 100% | 0% | 0% | 0% | 100% | 2.7 | 6.6 | 39.0 |
| competent | dark_raiders | 9 | 100% | 0% | 0% | 0% | 100% | 4.8 | 2.2 | 35.0 |
| competent | dark_storm | 9 | 100% | 0% | 0% | 0% | 89% | 5.9 | 9.1 | 30.4 |
| naive | dark_balanced | 9 | 100% | 0% | 0% | 0% | 100% | 5.8 | 6.6 | 34.0 |
| naive | dark_horde | 9 | 100% | 0% | 0% | 0% | 100% | 3.9 | 4.0 | 39.0 |
| naive | dark_raiders | 9 | 89% | 11% | 0% | 0% | 89% | 3.7 | 2.6 | 32.7 |
| naive | dark_storm | 9 | 89% | 11% | 0% | 0% | 100% | 5.4 | 11.9 | 29.7 |

#### By pilot, map and mode

| pilot | map / mode | runs | win | loss | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|---|
| competent | riverside / body_count | 4 | 100% | 0% | 0% | 0% | 100% | 5.1 | 7.5 | 35.0 |
| competent | riverside / king_of_the_hill | 4 | 100% | 0% | 0% | 0% | 100% | 5.2 | 3.5 | 35.0 |
| competent | riverside / capture_the_flags | 4 | 100% | 0% | 0% | 0% | 75% | 5.2 | 5.0 | 31.5 |
| competent | the_ford / body_count | 4 | 100% | 0% | 0% | 0% | 100% | 2.8 | 7.5 | 35.0 |
| competent | the_ford / king_of_the_hill | 4 | 100% | 0% | 0% | 0% | 100% | 8.3 | 2.0 | 35.0 |
| competent | the_ford / capture_the_flags | 4 | 100% | 0% | 0% | 0% | 100% | 2.4 | 9.8 | 35.0 |
| competent | old_mill / body_count | 4 | 100% | 0% | 0% | 0% | 100% | 3.2 | 12.2 | 35.0 |
| competent | old_mill / king_of_the_hill | 4 | 100% | 0% | 0% | 0% | 100% | 8.2 | 6.0 | 35.0 |
| competent | old_mill / capture_the_flags | 4 | 100% | 0% | 0% | 0% | 100% | 1.8 | 5.8 | 35.0 |
| naive | riverside / body_count | 4 | 100% | 0% | 0% | 0% | 100% | 5.9 | 8.8 | 35.0 |
| naive | riverside / king_of_the_hill | 4 | 100% | 0% | 0% | 0% | 100% | 8.4 | 4.5 | 35.0 |
| naive | riverside / capture_the_flags | 4 | 75% | 25% | 0% | 0% | 75% | 5.6 | 4.5 | 29.8 |
| naive | the_ford / body_count | 4 | 100% | 0% | 0% | 0% | 100% | 3.4 | 8.2 | 35.0 |
| naive | the_ford / king_of_the_hill | 4 | 100% | 0% | 0% | 0% | 100% | 8.6 | 4.5 | 35.0 |
| naive | the_ford / capture_the_flags | 4 | 75% | 25% | 0% | 0% | 100% | 2.4 | 9.5 | 29.8 |
| naive | old_mill / body_count | 4 | 100% | 0% | 0% | 0% | 100% | 3.8 | 5.5 | 35.0 |
| naive | old_mill / king_of_the_hill | 4 | 100% | 0% | 0% | 0% | 100% | 8.6 | 3.8 | 35.0 |
| naive | old_mill / capture_the_flags | 4 | 100% | 0% | 0% | 0% | 100% | 2.0 | 7.0 | 35.0 |

### Anomalies

None: every run was decided by its rules.

## What changed, in order

Each screen was 72 runs (A: Balanced against Balanced, every map and mode, both starts, 2 seeds; B: both pilots against Dark Balanced, 2 seeds) or, from the third, the 198-run one-seed matrix with every pairing.

| step | change | A: Light wins | B: competent / naive |
|---|---|---|---|
| baseline | first guesses | 97% | 100% / 94% |
| 1 | Light costs x2.2 (Shieldman 65, Reaver 85, Longbow 100, Sapper 120, Warden 110) | 33% | 39% / 33% |
| 2 | Light x1.7 (50, 65, 75, 95, 85) | 72% | 72% / 72% |
| 3 | Light about x1.95 (58, 75, 88, 108, 98); the full pairings show Raiders weak (Light 94%), Storm strong (33%), Shield Wall strong (89%), Shock weak (22%) | 58% | 58% / 33% |
| 4 | Shieldman 62, Reaver 64, Longbow 90; Ripper 28, Drifter 44, Stormcaller 88 | 67% | 81% / 56% |
| 5 | Shieldman 68, Reaver 68, Longbow 95; Ripper 24, Stormcaller 80; Raiders template 45% Husks, 40% Rippers, 15% Blightbags (was 35/50/15) | 50% | 53% / 50% |
| 6 | Sapper 100, Ripper 22, Stormcaller 88: the full matrices, 612 runs | 47% | 58% / 60% |
| 7 | The Ford's two outer flags moved to the ford's landings (its Capture the Flags was 11% Light) | 53% | 60% / 62% |

**What the numbers said:**
- **A Light unit is worth about three Dark ones.** At the first guesses a Shieldman's shield took Husks six for one (an instrumented Riverside fight: 24 Husks killed by Shieldmen for 4 Shieldmen lost), and even 56 Dark units against 25 Light lost 16 times in 18. Light costs roughly doubled, rather than Dark's halving, because the 60-unit cap would have capped Dark's hordes at 1500 points and skewed the balance by budget.
- **Stormcallers are the strongest Dark unit for their price,** and the count is lumpy: at a 35% share a price of 80 buys four, 88 buys three, and Storm swung from 28% to 56% Light between them.
- **Rippers trade badly** (about 16 dead for 3 kills in a Raiders fight): cheaper, and the Raiders template keeps more Husks to screen them.
- **The Ford's Capture the Flags was a map problem, not a price.** The dead wade the river anywhere and the living only at the ford, so flags on the far banks were Dark's (Light 11%, the competent pilot 15%). At the landings every flag is fought for at the crossing: Light 64%, the pilots 35% and 40%. Only that map and mode reads those flags, so its 68 runs were played again and spliced into the 612-run tables below in place of the old ones.
- **The start matters on the river maps:** A against commander, Light wins 45% from start A and 61% from start B. On Riverside it is 38% and 69% (start A has to cross the creek, which slows and funnels a living army; path length, which the map tests compare, doesn't see that), on The Ford 31% and 48% before the flag change; Old Mill is even. Averaged over the starts each map is inside the targets, and the player picks the start.

## Final tables (committed data, 612 runs)

Costs: Shieldman 68, Reaver 68, Longbow 95, Sapper 100, Warden 98; Husk 20, Ripper 22, Blightbag 40, Drifter 44, Stormcaller 88. Budget 1000, 10 minutes, seeds 1000 and up.

### Matrix A: commander against commander (252 runs)

#### Overall

| scope | runs | Light win | Dark win | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|
| all runs | 252 | 53% | 46% | 1% | 0% | 93% | 2.4 | 8.8 | 29.7 |

#### By map and mode

| map / mode | runs | Light win | Dark win | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|
| riverside / body_count | 28 | 54% | 46% | 0% | 0% | 100% | 2.7 | 9.4 | 31.7 |
| riverside / king_of_the_hill | 28 | 57% | 43% | 0% | 0% | 96% | 5.3 | 8.6 | 31.0 |
| riverside / capture_the_flags | 28 | 50% | 50% | 0% | 0% | 43% | 10.0 | 8.0 | 19.2 |
| the_ford / body_count | 28 | 46% | 54% | 0% | 0% | 96% | 2.3 | 10.1 | 30.3 |
| the_ford / king_of_the_hill | 28 | 61% | 36% | 4% | 0% | 100% | 2.0 | 8.1 | 32.6 |
| the_ford / capture_the_flags | 28 | 64% | 32% | 4% | 0% | 100% | 2.2 | 9.1 | 34.3 |
| old_mill / body_count | 28 | 54% | 46% | 0% | 0% | 100% | 3.4 | 8.9 | 30.4 |
| old_mill / king_of_the_hill | 28 | 57% | 43% | 0% | 0% | 100% | 2.1 | 7.5 | 31.5 |
| old_mill / capture_the_flags | 28 | 36% | 64% | 0% | 0% | 100% | 1.9 | 9.7 | 26.2 |

#### By pairing of army templates

| Light vs Dark | runs | Light win | Dark win | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|
| light_balanced vs dark_balanced | 36 | 44% | 53% | 3% | 0% | 97% | 2.3 | 9.4 | 31.4 |
| light_balanced vs dark_horde | 36 | 39% | 58% | 3% | 0% | 89% | 2.3 | 9.5 | 26.9 |
| light_balanced vs dark_raiders | 36 | 53% | 47% | 0% | 0% | 94% | 2.4 | 9.5 | 37.1 |
| light_balanced vs dark_storm | 36 | 42% | 58% | 0% | 0% | 94% | 2.3 | 9.1 | 19.3 |
| light_shield_wall vs dark_balanced | 36 | 86% | 14% | 0% | 0% | 92% | 3.3 | 6.0 | 33.7 |
| light_shock vs dark_balanced | 36 | 58% | 42% | 0% | 0% | 89% | 2.2 | 10.1 | 31.2 |
| light_siege vs dark_balanced | 36 | 50% | 50% | 0% | 0% | 94% | 2.4 | 8.2 | 28.2 |

#### By Light's start

| Light starts at | runs | Light win | Dark win | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|
| start A | 126 | 45% | 53% | 2% | 0% | 97% | 2.3 | 9.6 | 29.0 |
| start B | 126 | 61% | 39% | 0% | 0% | 89% | 2.6 | 8.0 | 30.4 |

### Matrix B: a pilot plays Light against the Dark commander (360 runs)

Win is the pilot's, loss the commander's.

#### By pilot

| pilot | scope | runs | win | loss | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|---|
| competent | all | 180 | 60% | 40% | 0% | 0% | 96% | 2.3 | 8.1 | 32.6 |
| naive | all | 180 | 62% | 38% | 1% | 0% | 97% | 2.4 | 8.2 | 33.0 |

#### By pilot and Dark template

| pilot | Dark template | runs | win | loss | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|---|
| competent | dark_balanced | 45 | 67% | 33% | 0% | 0% | 93% | 3.1 | 7.5 | 33.0 |
| competent | dark_horde | 45 | 78% | 22% | 0% | 0% | 91% | 2.2 | 6.8 | 35.9 |
| competent | dark_raiders | 45 | 58% | 42% | 0% | 0% | 100% | 2.3 | 8.7 | 38.7 |
| competent | dark_storm | 45 | 38% | 62% | 0% | 0% | 98% | 2.1 | 9.5 | 22.9 |
| naive | dark_balanced | 45 | 69% | 31% | 0% | 0% | 100% | 2.5 | 7.8 | 33.9 |
| naive | dark_horde | 45 | 56% | 42% | 2% | 0% | 96% | 2.1 | 8.4 | 34.4 |
| naive | dark_raiders | 45 | 80% | 20% | 0% | 0% | 93% | 4.2 | 6.3 | 41.3 |
| naive | dark_storm | 45 | 42% | 58% | 0% | 0% | 100% | 2.2 | 10.1 | 22.6 |

#### By pilot, map and mode

| pilot | map / mode | runs | win | loss | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |
|---|---|---|---|---|---|---|---|---|---|---|
| competent | riverside / body_count | 20 | 65% | 35% | 0% | 0% | 100% | 2.4 | 9.0 | 32.6 |
| competent | riverside / king_of_the_hill | 20 | 85% | 15% | 0% | 0% | 100% | 3.2 | 6.7 | 36.0 |
| competent | riverside / capture_the_flags | 20 | 40% | 60% | 0% | 0% | 60% | 9.7 | 5.8 | 29.0 |
| competent | the_ford / body_count | 20 | 70% | 30% | 0% | 0% | 100% | 2.0 | 8.6 | 32.7 |
| competent | the_ford / king_of_the_hill | 20 | 60% | 40% | 0% | 0% | 100% | 2.2 | 8.1 | 32.9 |
| competent | the_ford / capture_the_flags | 20 | 35% | 65% | 0% | 0% | 100% | 2.0 | 10.6 | 32.2 |
| competent | old_mill / body_count | 20 | 75% | 25% | 0% | 0% | 100% | 3.2 | 8.3 | 34.1 |
| competent | old_mill / king_of_the_hill | 20 | 75% | 25% | 0% | 0% | 100% | 2.6 | 6.6 | 35.0 |
| competent | old_mill / capture_the_flags | 20 | 35% | 65% | 0% | 0% | 100% | 2.0 | 9.7 | 29.1 |
| naive | riverside / body_count | 20 | 60% | 40% | 0% | 0% | 100% | 2.8 | 9.3 | 33.2 |
| naive | riverside / king_of_the_hill | 20 | 80% | 20% | 0% | 0% | 100% | 8.2 | 6.8 | 34.3 |
| naive | riverside / capture_the_flags | 20 | 50% | 50% | 0% | 0% | 75% | 6.8 | 6.2 | 30.6 |
| naive | the_ford / body_count | 20 | 55% | 45% | 0% | 0% | 100% | 2.0 | 8.9 | 32.6 |
| naive | the_ford / king_of_the_hill | 20 | 55% | 45% | 0% | 0% | 100% | 2.1 | 9.9 | 33.6 |
| naive | the_ford / capture_the_flags | 20 | 40% | 60% | 0% | 0% | 100% | 2.0 | 9.5 | 31.2 |
| naive | old_mill / body_count | 20 | 60% | 35% | 5% | 0% | 100% | 3.9 | 9.3 | 32.4 |
| naive | old_mill / king_of_the_hill | 20 | 75% | 25% | 0% | 0% | 100% | 2.3 | 6.8 | 34.1 |
| naive | old_mill / capture_the_flags | 20 | 80% | 20% | 0% | 0% | 100% | 2.1 | 6.5 | 35.2 |

### Anomalies

None: every run was decided by its rules.
