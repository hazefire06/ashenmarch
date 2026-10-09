# Ashenmarch: Claude Code phase prompts

One session per phase. Start each session by pasting the phase prompt. Every prompt assumes Claude Code reads `CLAUDE.md` first. Don't skip plan mode.

---

## Phase 0: Repo and scaffold (first session)

```
Read CLAUDE.md. This is a new project.

1. Create a new public GitHub repo hazefire06/ashenmarch (use gh) with the description "Ashenmarch: a real-time strategy (RTS) tactics game built in Godot 4". Clone it into ~/Projects/ashenmarch.
2. Add CLAUDE.md (the file I've placed in this folder) and docs/prompts.md to the repo.
3. Scaffold a Godot 4 project matching the folder layout in CLAUDE.md. Install the GUT addon. Add a .gitignore for Godot.
4. Create sim/world.gd with a fixed 30 tick/sec loop, a seeded RandomNumberGenerator, an entity registry, and a command queue that applies commands at the start of each tick. Write GUT tests proving two worlds with the same seed and same command stream produce identical state after 1000 ticks.
5. Create view/main.tscn that instantiates a World, advances it from _physics_process, and draws a flat placeholder plane.
6. Add a Makefile or scripts/ with: run, test, export-mac.
7. Confirm `godot --headless -s addons/gut/gut_cmdln.gd` runs the tests and passes.

Enter plan mode first and show me the plan before touching anything. Commit on feature/PHASE-0-scaffold and open a PR.
```

---

## Phase 1: Terrain and camera

```
Read CLAUDE.md and docs/prompts.md. Phase 0 is merged.

Goal: a heightmap terrain I can fly around.

1. sim/terrain.gd: load a heightmap (16-bit PNG) plus a passability/water-depth mask into a grid. Provide height_at(x, z) with bilinear sampling, slope_at, water_depth_at, and is_passable(unit_type). All pure functions, tested.
2. view: build a mesh from the heightmap, chunked so a 512x512 map renders well. Flat-shaded placeholder material colored by height and water depth.
3. Camera per CLAUDE.md controls: orbit, zoom, move, pan, all in view/, never touching sim. Camera stays above terrain. Clamp to map bounds.
4. Overhead map toggle (Tab) drawn from the heightmap.
5. Ship one test map (maps/riverside) generated procedurally for now: rolling hills, a creek with a ford at depth 1 and deep sections at depth 3.

Plan mode first. Branch feature/PHASE-1-terrain.
```

---

## Phase 2: Units, selection, movement, formations

```
Read CLAUDE.md. Phases 0-1 merged.

Goal: I can select units and move them around in formation on the terrain.

1. data/units: define UnitType resource with fields from CLAUDE.md (speed, hp, melee/ranged stats, abilities, faction, living/undead, water rules). Create Shieldman and Husk .tres files.
2. sim/units: unit entity with position, facing, state machine (idle, moving, attacking, dead). Movement speed reduced by water depth and steep slope per CLAUDE.md. Living units refuse depth 3+.
3. sim/pathing: grid pathfinding that respects passability and water rules per unit. Path smoothing. Local avoidance so units don't stack. Keep it deterministic.
4. Formations: implement all 10 from CLAUDE.md as slot generators (given N units, a center, and a facing, return N target positions). Tested. A move order with a formation assigns units to slots minimizing total travel.
5. view: billboarded placeholder sprites (colored quad + label) standing on the terrain. Selection: click, drag box, shift-add, double-click type select. Groups Cmd+0-9. Formation keys 1-0 before a move order. Bottom control bar with the same commands.
6. Spawn 20 Shieldmen and 20 Husks on the test map for manual testing.

Plan mode first. Branch feature/PHASE-2-units.
```

---

## Phase 3: Melee combat, death, veterancy

```
Read CLAUDE.md. Phases 0-2 merged.

Goal: units fight and die, and it feels like flanking matters.

1. sim/combat: melee attack with wind-up, cooldown, reach, damage with small seeded variance. Units auto-acquire adjacent enemies; attack-move order. Units engaged from the flank or rear take a small extra damage multiplier and can only fight one target.
2. Health, death, bodies that persist. Cosmetic gibs on overkill (view side, may use Godot physics).
3. Veterancy: kill count per unit; derived modifiers to accuracy, attack rate, and speed with diminishing returns and a cap. Shown in the unit tooltip.
4. Add Reaver and Ripper unit types. Ripper prioritizes ranged/support targets when choosing whom to attack.
5. Tests: 10 Shieldmen vs 10 Husks in a line beats them; 10 Husks surrounding 5 Shieldmen wins; same seed gives same outcome.

Plan mode first. Branch feature/PHASE-3-melee.
```

---

## Phase 4: Ranged combat and projectile physics

```
Read CLAUDE.md. Phases 0-3 merged. This is the most important phase; take it slowly.

Goal: arrows, grenades, and satchel charges that behave like real objects.

1. sim/projectiles: projectile entity with position, velocity, gravity, drag, and terrain collision. Arrows stick where they land. Grenades bounce with restitution, roll on slopes, and have a fuse plus a fizzle chance. Everything deterministic and tested.
2. Aiming: solve launch angle for a target point given launcher height, target height, and unit-specific max velocity. Inaccuracy is a cone scaled by veterancy and by uphill angle (thrown explosives penalized far more than arrows). If the target is out of reach, the unit moves closer or refuses, never throws short into itself unless the physics actually does that.
3. Explosions: radius damage with falloff, knockback impulse on units and loose objects, detonates satchels/unexploded grenades in radius (recursive chain), leaves a crater decal.
4. Satchel charges: Sapper drops one at its feet with T (4 per mission). Placed charges are entities that persist. Dropped on death.
5. Units: Longbow (arrows), Sapper (grenades + satchels), Drifter (floating archer, ignores water and slope for movement). Longbow gets one fire arrow (fire itself comes in Phase 5; for now it does damage and flags the landing spot).
6. Ground-target attack (Ctrl+click). Friendly fire on everything.
7. Tests: grenade thrown up a steep hill can roll back and damage the thrower; chain of 5 satchels detonates from one grenade; same seed gives identical landing positions.

Plan mode first. Branch feature/PHASE-4-projectiles.
```

---

## Phase 5: Weather, water, fire

```
Read CLAUDE.md. Phases 0-4 merged.

Goal: the environment changes tactics.

1. sim/weather: rain and snow intensity 0-1, wind vector (visual only). Burning projectiles have a fizzle chance from precipitation intensity and from snow-covered ground. Fizzled grenades persist as unexploded objects.
2. Water: burning projectiles landing in water depth 1+ are extinguished. Fire cannot spread onto water. Undead at depth 3+ are hidden from the player's view until they surface or are within a small radius.
3. sim/fire: flammability grid derived from the map. Fire arrows ignite a cell; fire spreads to neighbors each tick with a probability, burns out, leaves scorched ground. Fire damages units in it, detonates explosives, and is extinguished by rain over time. No fire on sand or rock.
4. view: rain/snow particles (cosmetic), fire and smoke effects, wet/snow ground tint.
5. Mission-level weather schedule (e.g. rain starts at tick N) driven from data.
6. Tests: 100 grenades in heavy rain fizzle at roughly the configured rate; fire spread is deterministic per seed.

Plan mode first. Branch feature/PHASE-5-weather-fire.
```

---

## Phase 6: Special units and status effects

```
Read CLAUDE.md. Phases 0-5 merged.

Goal: complete the v1 roster.

1. Status effects framework: timed effects on units (Paralysis, Confusion, Burning). Confused units attack the nearest unit regardless of side.
2. Warden: T heals selected friendly with a herb (stack of 6). Healing an undead unit kills it. Herbs drop on death and can be picked up. Herb plants on maps yield 2 roots when attacked.
3. Blightbag: slow walking bomb. T self-detonates. Death by any cause detonates. Explosion plus paralyzing gas cloud that lingers and paralyzes anything entering it.
4. Stormcaller: lightning attack that damages in a line, detonates explosives, has a minimum range dead zone where it cannot fire. Dies to sustained melee.
5. Ripper can pick up loose objects (dropped satchels, gas packets, body parts) and throw them.
6. Unit tooltips and a unit info panel in the HUD.

Plan mode first. Branch feature/PHASE-6-abilities.
```

---

## Phase 7: Enemy AI

```
Read CLAUDE.md. Phases 0-6 merged.

Goal: enemies that patrol, ambush, flank, and protect their own specials.

1. sim/ai: per-group behaviors: idle, patrol (waypoints), guard (radius), hunt (target player units), flank (path around to reach ranged units), ambush (hidden in water until player within radius), retreat when losing badly.
2. Target selection: melee prefers nearest; Rippers prefer Sappers/Longbows/Wardens; Stormcallers hold at max range; Blightbags walk at the biggest cluster.
3. Trigger system for mission scripting: on player-enters-area, on-unit-dies, on-timer, on-wave-cleared, spawn group, set weather, set objective text, win, lose.
4. Difficulty tiers change group sizes and spawn positions from data.
5. AI runs inside the sim tick, deterministic.
6. Tests: a scripted patrol reaches its waypoints; ambush group surfaces when triggered; identical seeds give identical AI decisions.

Plan mode first. Branch feature/PHASE-7-ai.
```

---

## Phase 8: Mission framework and the three campaign maps

```
Read CLAUDE.md. Phases 0-7 merged.

Goal: a playable three-mission campaign with carryover.

1. Mission definition format (JSON or .tres): map, player roster (with carryover slots), enemy groups and their AI, triggers, weather schedule, objectives, win/loss, per-difficulty overrides.
2. Campaign state: survivors and their veterancy carry into the next mission. Save/load between missions.
3. Build the three missions from CLAUDE.md: Riverside, The Ford, Old Mill. Hand-author the heightmaps and passability masks (can be generated with a script, but tuned). Old Mill picks 4 of its 5 waves randomly per seed.
4. Mission briefing screen, objective panel, win/loss screens with stats (kills, losses, per-unit veterancy), difficulty select.
5. Main menu: Campaign, Skirmish (stub), Settings, Quit.
6. Playtest each mission on the middle difficulty and fix the obvious balance problems. Report what you changed.

Plan mode first. Branch feature/PHASE-8-campaign.
```

---

## Phase 9: Skirmish vs AI

```
Read CLAUDE.md. Phases 0-8 merged.

Goal: pick an army and fight the AI on any of the three maps.

1. Modes: Body Count (most kills at time limit), King of the Hill (most time holding a flag), Capture the Flags (hold most of N flags at time limit).
2. Pre-game unit trading: point budget, each unit type has a cost, both sides get the same budget. AI army composition from a few templates.
3. Skirmish AI: reuse Phase 7 behaviors plus a simple commander that picks an objective, keeps ranged units behind melee, and commits when it has local superiority.
4. Scoreboard (F7), time limit, results screen.
5. Map spawn points and flag positions added to the three maps.

Plan mode first. Branch feature/PHASE-9-skirmish.
```

---

## Phase 10: Exports and polish

```
Read CLAUDE.md. Phases 0-9 merged.

1. Export presets for macOS (signed ad-hoc is fine), Windows, and Web. Web needs the cross-origin isolation headers; add a small local serve script that sets them.
2. Verify determinism across platforms: play the same command recording on Mac and Web and compare final sim hashes. If they diverge, find the float that caused it and fix it in sim/.
3. Replay system: record command streams per mission, replay from menu. (This is also the multiplayer foundation.)
4. Performance pass: 100 units and 200 projectiles at 60 fps on the Mac.
5. Settings: keybinds, volume, resolution.

Plan mode first. Branch feature/PHASE-10-exports.
```

---

## Phase 11: Classic controls and gamepad

```
Read CLAUDE.md. Phases 0-10 merged. docs/controls-myth2.md compares our controls with Myth II's; everything it lists as missing, except the center key (Phase 10), comes in here.

1. New orders as sim commands, recorded in replays. CommandCodec kinds are append-only, so old replays still load; give the Move command's new facing field a default for old records.
   - Formation facing: right-drag (Option-drag on Mac) sets the formation's facing. Formations already take a facing; today it is the centroid-to-target direction.
   - Left / Right arrow rotate the pending formation, and a moving one (re-issue its move).
   - Guard (G): hold the spot. Idle units already hold theirs and fight within 3 m; Guard adds ranged units firing at anything in range and repositioning when attacked.
   - Scatter (B). Retreat (R): define it first.
   - Waypoints and patrol: Shift-click the ground, up to 4 points; Shift-click the first point again for a loop, the last for back and forth. This is an order queue on Unit: state, hashing, and how attack-move resumes.
2. View-only: select all visible (Enter), deselect (`), cycle groups (F), clear a group (Del), hold for health bars (F10), right-click the overhead map to send troops, and single-player game speed (F1/F2, 1/2x to 4x; never in lockstep). Mac laptops need fn for F-keys; all of it is rebindable.
3. A "Classic" control preset beside "Modern" in Settings > Controls: left-click orders, A/D turn, Z/X strafe, C zoom in and V zoom out, one group modifier with hold-to-save. Ask me which is the default. Update CLAUDE.md's Controls either way.
4. Xbox controller on macOS, Windows and Web (Godot 4.7: SDL3 on desktop, the Gamepad API on the web, where a pad isn't seen until a button is pressed).
   - Left stick: a virtual cursor that snaps to units. Right stick and triggers: the camera.
   - A select, X order, B cancel, Y special. LB/RB: formation and order radial menus. D-pad: groups. View: overhead map. Menu: pause.
   - Every menu and the control bar reachable by focus (the bar's buttons are FOCUS_NONE today).
   - On-screen prompts switch between key names and pad glyphs (original drawn glyphs).
   - Pad bindings go in Settings > Controls; the saved format already covers pads.
   - Rumble only where it works (not Xbox pads over USB on macOS).
5. Windows, deferred from Phase 10: run `Ashenmarch.console.exe --headless -- --verify-replays` on the Parallels VM (ask before resuming it), and the pad tests there.
6. Tests: the new orders are deterministic and survive the codec and a replay; input mapping from synthetic InputEventJoypad* events; a pad-only playthrough of Riverside.

Plan mode first. Branch feature/PHASE-11-controls.
```

---

## After v1

- Art pass: moved to the parallel art and audio track below.
- Roster expansion from the "later" list in CLAUDE.md.
- More missions: escort, rescue, timed assault, capture, stealth.
- Multiplayer: lockstep over the command stream, LAN first.

---

## Art and audio track (parallel to the phases)

Designed in `docs/specs/2026-10-01-art-audio-design.md`. Work happens in the worktree `../ashenmarch-art`, never in a phase checkout, and never touches `sim/` or `data/units/`. Tim runs every paid API command himself in Terminal.app.

### A1: Unit sprites (Shieldman)

```
Read CLAUDE.md, the art and audio spec, and docs/plans/2026-10-03-art-audio-a0-a1.md. A0 is merged or open.

Build the sprite pipeline and the Shieldman's art per the plan, Part 2 onward. Stop at the candidate sheet and at the contact sheet for my approval before any Godot code. Branch feature/PHASE-A1-unit-sprites.
```

### A2: Audio

```
Read CLAUDE.md and the art and audio spec. A1 is merged.

Plan first: sound generation and processing scripts, the sound bank, AudioDirector, ambience, barks (text first, then the Shieldman's voice), one music loop for Riverside. Branch feature/PHASE-A2-audio.
```

### A3: The rest of the roster

```
Read CLAUDE.md and the art and audio spec. A1 and A2 are merged.

Plan first: art and voices for the other nine units, one contact sheet or line list per unit for my approval. Branch feature/PHASE-A3-roster.
```
