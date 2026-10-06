# Ashenmarch

A real-time strategy (RTS) game, tactics-focused with no base building, built in Godot 4 with GDScript. In the spirit of late-90s squad-based tactics games. Personal project, not for release. No assets, names, lore, or text from any existing game may be used. All units, maps, names, and art are original.

## Stack

- Godot 4.x (current stable), GDScript only. No C# (web export doesn't support it).
- Targets, in priority order: macOS, Windows, Web (HTML5).
- Tests: GUT (Godot Unit Test) addon. Simulation code must be unit-testable without a scene tree.
- Repo: github.com/hazefire06/ashenmarch

## Non-negotiable architecture

1. **Deterministic fixed-tick simulation.** All gameplay (movement, combat, projectiles, status effects, AI decisions) runs in `sim/` at a fixed 30 ticks/sec using integers or fixed-point where practical, seeded RNG only, no wall-clock, no `_process` delta. Rendering interpolates between ticks. Rationale: future lockstep multiplayer and replay files.
2. **Own projectile physics.** Do not use Godot's physics servers for gameplay. `sim/` implements gravity, bounce, roll, and terrain collision for projectiles itself. Godot physics may only be used for cosmetic gibs and debris.
3. **Sim and view are separate.** `sim/` has no dependency on any Node. `view/` reads sim state and draws it. Input produces commands; commands are applied on the next tick. This is the same command stream multiplayer would send over the wire.
4. **Data-driven units.** Every unit type is a `.tres` resource (`data/units/*.tres`) with stats, abilities, and sprite references. No unit stats hardcoded in scripts.
5. **Terrain is a heightmap.** Maps are a heightfield mesh plus a passability/water-depth grid. Units are billboarded sprites standing on the mesh.

## Folder layout

```
project.godot
sim/            # pure gameplay logic, no Nodes
  world.gd      # tick loop, entity registry, command queue
  commands/     # tick-stamped command objects (the lockstep/replay stream)
  terrain.gd    # heightmap sampling, passability, water depth
  pathing.gd    # flow-field or A* on the grid
  units/        # unit state machines, formations, veterancy
  combat/       # melee resolution, damage, status effects
  projectiles/  # arrows, grenades, satchels, chain reactions
  weather.gd    # rain/snow/wind state and their gameplay effects
  fire.gd       # brush fire spread
  ai/           # enemy tactical AI, mission scripts
  missions/     # objectives, triggers, win/loss, carryover
view/           # Godot scenes: camera, sprites, HUD, overhead map, effects
data/           # unit .tres files, formation definitions, map data
maps/           # heightmaps, passability masks, spawn/trigger layouts
assets/         # placeholder art and audio (original only)
tests/          # GUT tests for sim/
docs/           # design notes, prompts.md
scripts/        # dev tooling (sim purity check)
```

## Conventions

- GDScript: static typing everywhere (`var x: int`, typed function signatures, typed arrays). `@warning_ignore` only with a comment saying why.
- One class per file, `class_name` declared. Snake_case files, PascalCase classes.
- Sim code never calls `randf()`; it uses the world's seeded `RandomNumberGenerator`.
- Feature branches: `feature/PHASE-N-short-description`. Squash-merge to `main`. Open a PR even solo; it's the change log.
- Before starting any phase: enter plan mode, read this file and `docs/prompts.md`, propose the plan, wait for approval.
- Commit messages: imperative, one line summary, body explains why.
- Placeholder art: colored capsules/quads with a text label. Do not spend time on art until told to.

## Game design

### Core rules
- No resource economy. Each mission gives a fixed roster. Survivors carry over to the next mission with their veterancy.
- Veterancy: each kill improves accuracy, attack rate, and (for some units) move speed, with diminishing returns and a cap.
- Friendly fire on everything: arrows, explosions, fire, lightning, gas.
- Melee has no rock-paper-scissors counters. Outcomes come from numbers, flanking, surrounding, and terrain.
- Losses are permanent within a campaign. No respawns, no healing between missions except via healer units during play.
- The campaign darkens mission by mission toward a hellscape: each mission's Atmosphere (data/atmospheres) grades sky, light, fog, and ground further than the last.

### Terrain and physics
- Projectiles are simulated objects under gravity. Grenades arc, bounce, may fizzle, and can roll back downhill onto the thrower.
- Height affects ranged units only. Shooting uphill reduces range and accuracy; thrown explosives are affected far more than arrows.
- Satchel charges are placed objects. Any explosion, fire, or lightning within radius detonates them, and they chain-react. Unexploded grenades and dropped charges persist as hazards.
- Water has depth levels 0-4. Depth slows living units; depth 3+ is impassable for living units (they path around). Undead units cross any depth and are hidden at depth 3+. Water extinguishes fire and burning projectiles.
- Rain and snow: each has an intensity; probability a burning projectile fizzles scales with intensity. Snow on the ground also raises fizzle chance. Wind only affects precipitation visuals.
- Fire arrows start brush fires that spread across flammable terrain (grass, brush, wood), not sand, rock, or water. Fire damages units in it and detonates explosives.
- Bodies and gibs persist for the mission. Explosions leave craters (cosmetic decal, plus a small terrain scar).
- Indoor/walled maps: walls block line of sight and projectiles. Ranged units cannot target around corners.

### Controls
- Camera: orbit (Q/E), zoom (mouse wheel, V/C), move (WASD), pan (Z/X). Edge scroll optional. Overhead map toggle (Tab).
- Selection: click, drag box, shift-click add, double-click selects all of that type on screen. Groups saved with Cmd/Ctrl+1..0, recalled with Option/Alt+1..0 (plain 1..0 are formations). Stop: H. Pause: P (the sim stops stepping; Esc opens the pause menu, after cancelling an armed order).
- Formations, chosen after selection and applied on the next move order, keys 1-0: short line, long line, loose line, staggered line, box, rabble, shallow encirclement, deep encirclement, wedge, circle.
- Special ability: T. Attack-move (Cmd/Ctrl+right-click) and ground-target attack (Cmd/Ctrl+left-click; Cmd on macOS, where Ctrl+click is a right click) supported.
- Bottom control bar mirrors all of the above so the game is playable with mouse only.

### Status effects
- Paralysis (from touch or gas cloud), Confusion (attacks nearest anything), Burning, Conversion (living units only, permanent), Heal (kills undead outright).
- Chain detonation: target unit explodes; any unit within radius explodes too, recursively, including friendlies.

### Unit roster, v1 (original names, placeholder art)
Light side (player):
1. Shieldman: base melee, sword and shield, cheap and sturdy.
2. Reaver: shock melee, two-handed blade, fast, no shield, high damage.
3. Longbow: archer, long range, one fire arrow each, dagger in melee.
4. Sapper: grenadier, unlimited bottle grenades, carries 4 placeable charges, slow.
5. Warden: healer-fighter with a limited stack of healing herbs, decent melee.

Dark side (enemy, v1):
6. Husk: base undead melee, slow, numerous, hides in deep water.
7. Ripper: fast raider, picks up and throws objects and charges, hunts sappers.
8. Blightbag: walking bomb, slow, explodes into paralyzing gas.
9. Drifter: floating undead archer, crosses water and steep terrain.
10. Stormcaller: lightning caster with a minimum range dead zone.

Later roster (not v1): mortar, invisible scout, giant, fireball/confusion caster, converter, chain-exploder, shadow unit, paralyzing zombie, arrow-resistant armor, swarm critters, wolves.

### Missions, v1 (three maps)
1. **Riverside** (bug hunt, tutorial): clear a village of roaming Husks and a few Rippers. Introduces selection, formations, grenades, fire arrows. Clear weather, shallow creek with one ford.
2. **The Ford** (escort): escort a non-controllable villager across a river to a gate. Husks hide in deep water at the crossing, Drifters patrol, a Ripper pack comes up behind the escort as it wades, and more Rippers flank late. Introduces water depth, carryover.
3. **Old Mill** (hold the line): defend a raised mill against 4 of 5 randomly chosen waves (Husks, Rippers, Blightbags, Drifters, Stormcallers). Rain starts mid-mission. Introduces weather, satchel traps, healer management.

Mission framework must be data-driven so more missions are added as map data plus a script, not engine changes.

### Difficulty
Five tiers. Higher tiers add enemies, change spawn positions, and shorten timers. Data-driven per mission.

### Skirmish vs AI (after campaign v1)
Modes: Body Count, King of the Hill, Capture the Flags. Pre-game unit trading with a point budget. Same maps.

### Later: multiplayer
Lockstep over the command stream. Not in scope until skirmish is done. The determinism rules above exist for this.

## Definition of done for any phase
- Plan approved before code.
- GUT tests pass for all new sim code.
- Runs on macOS export. Windows/Web verified in Phase 10.
- `docs/` updated if a design decision changed.
- PR opened against `main` with a summary of what changed and what's next.
