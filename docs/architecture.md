# Architecture notes

Decisions made in Phase 0 that later phases build on. CLAUDE.md has the rules; this file records how they're implemented and why.

## Tick model
- `World.TICK_RATE = 30`. One call to `World.step()` simulates one tick.
- The view calls `step()` exactly once per `_physics_process` (Phase 8: unless the game is paused or a campaign mission has ended, when it doesn't call it at all) and sets `Engine.physics_ticks_per_second` from `World.TICK_RATE`. Godot's physics loop is the fixed-step accumulator, and the sim never sees a frame delta.
- Consequence: Godot physics (cosmetic gibs/debris only) also runs at 30 Hz.
- If a frame hitches past Godot's `max_physics_steps_per_frame` (8), the sim slows down rather than skipping ticks.

## Fixed-point units
- Positions are integer milli-units (`World.UNITS_PER_METER = 1000`). Velocities are milli-units per tick.
- Stored as plain `int` (64-bit), not `Vector3i`, whose 32-bit components overflow in fixed-point multiplies.

## Commands
- Every outside change to the sim is a `SimCommand` subclass in `sim/commands/`. Each carries the `tick` it applies at.
- Unit commands (Phase 2): `SpawnUnitCommand` (type id, side, position, facing), `MoveUnitsCommand` (unit ids, target, formation), `StopUnitsCommand` (unit ids). Phase 3 adds `AttackMoveCommand` (same fields as a move), and Phase 8 `DeployCommand` (a campaign roster, with each soldier's kills and health, at tick 0). Group commands sort and dedupe their ids and skip missing or dead units, so the order the player selected in doesn't matter.
- `World.enqueue()` rejects ticks already simulated. At the start of each tick, that tick's commands apply in enqueue order.
- Commands are immutable data. A command targeting a missing entity is a no-op.
- This is the stream that lockstep multiplayer and replays will serialize. Serialization is not built yet.

## Randomness
- Gameplay randomness comes only from `World.rng`, a `RandomNumberGenerator` seeded in `World._init`. Use its integer methods (`randi`, `randi_range`) in sim code. One exception, Phase 8's mission wave draw, uses a generator of its own and never touches `world.rng`; see Mission framework and campaign (Phase 8), RNG.
- `scripts/check_sim_purity.sh` (run by `make test`) fails the build if `sim/` uses:
  - Nodes or frame callbacks
  - wall-clock reads
  - global/unseeded random calls
  - Godot physics

## Determinism check
- `World.state_hash()` is a SHA-256 over:
  - the tick
  - the RNG seed and state
  - the next entity id and the pending-command count
  - every entity's fields, in id order
- Packed arrays are hashed in native byte order. That is little-endian on every current target (x86_64, arm64, wasm).
- `tests/sim/test_world.gd` proves that the same seed and stream give an identical hash after 1000 ticks, and that changing either one changes it.

## Rendering
- The Compatibility renderer is used on every platform. Web export forces it regardless (`rendering_method.web`), and using one renderer everywhere keeps Mac and Web visually identical.
- Switch `rendering/renderer/rendering_method` if Forward+ features are ever needed on desktop.

## Tests on a fresh clone
- GUT needs the `.godot/` class_name cache, which isn't committed.
- **On a fresh clone, `godot --headless -s addons/gut/gut_cmdln.gd` prints "Some GUT class_names have not been imported", runs zero tests, and exits 0.** This was verified on GUT 9.7.1 / Godot 4.7.2.
- Use `make test`, which imports first, or run `godot --headless --import` once before calling `gut_cmdln.gd` directly. CI must do the same, or it will pass without testing anything.

## Terrain (Phase 1)
`sim/terrain.gd` (`Terrain`) holds the ground: a heightfield plus a per-sample water depth and blocked flag. `World.terrain` owns it, and the view reads it from there.

### Grid conventions
- Samples sit at grid vertices. Sample `(i, j)` is at `x = i * cell_size`, `z = j * cell_size`, in milli-units.
- A map of `size_x × size_z` samples spans `(size_x - 1) × (size_z - 1)` cells. Riverside is 512² samples at 1 m, so it covers 511 m.
- `i` is the image column (+x). `j` is the image row (+z), and the top image row is `z = 0`.
- Heights are milli-units, stored as `PackedInt32Array`. They may go negative once explosions scar the ground. `height_at` rounds with `FixedMath.div_floor`, so negative values round the same way as positive ones.

### Queries (all integer)
- **`height_at(x, z)`**: bilinear between the four surrounding samples, rounded half up. Off-map points clamp to the edge.
- **`gradient_at(x, z)`**: the exact derivative of that bilinear surface, `(dh/dx, dh/dz)`, as a `Vector2i`.
  - Units are permille: millimetres of rise per metre of run, so 1000 = 45°.
  - It uses the cell containing the point. Cells are half-open.
  - Off the map, `height_at` is constant along any clamped axis, so that gradient component is 0 there.
- **`slope_at(x, z)`**: the magnitude of the gradient, via `FixedMath.isqrt`.
  - `isqrt` takes a float starting guess and corrects it to the exact floor, so the result never depends on float rounding.
- **`water_depth_at(x, z)`** and **`is_passable(x, z, mobility)`**: use the nearest sample, so a point query always agrees with the sample grid that pathing will run on. `is_sample_passable(i, j, mobility)` is the grid form.
- **Passability slope**: uses a per-sample slope (`sample_slopes`, precomputed at load), not the bilinear gradient.
  - Along each axis it takes the steeper of the two edges to the neighboring samples.
  - A central difference would halve a one-cell cliff and let walkers climb it.

### Mobility
Passability takes a `Terrain.Mobility`; each `UnitType` has a `mobility` field.

| Mobility | Water depth 3+ | Slope > `max_walkable_slope` | Blocked sample | Off the map |
|---|---|---|---|---|
| `LIVING` | impassable | impassable | impassable | impassable |
| `UNDEAD` | passable | impassable | impassable | impassable |
| `FLOATING` (Drifter) | passable | passable | impassable | impassable |

### Bilinear sim vs. flat-shaded mesh
- The render mesh splits each cell along its `(i, j)-(i+1, j+1)` diagonal into two flat triangles. The sim's bilinear surface differs from them inside a cell by at most `|h00 - h10 - h01 + h11| / 4`.
- At 1 m cells that is under 1 cm on rolling hills and a few cm on creek banks.
- Mesh vertices equal the sim's sample heights exactly (tested in `tests/view/test_terrain_mesh_builder.gd`).
- If Phase 4 bounces look wrong against the facets, switch `height_at`/`gradient_at` to triangle interpolation on the same diagonal. That's a one-function change.

### Not in `state_hash` yet
The terrain is static in Phase 1. When explosions start scarring it (Phase 4), add a terrain hash to `World.state_hash()`.

## Map format
A map is a folder `maps/<name>/` holding three files.

- **`<name>.tres`**: a `MapInfo` resource.
  - Fields: `display_name`, `heightmap_path`, `mask_path`, `cell_size` (milli-units), `max_height` (milli-units at the maximum raw value), `max_walkable_slope` (permille).
  - The numeric fields default to 0, and `Terrain.load_map` rejects 0. Godot omits default values from `.tres` files, so a non-zero default would let a map's scale change silently if the default changed.
- **Heightmap**: an 8- or 16-bit grayscale PNG. Raw `0..max` maps linearly to `0..max_height`.
- **Mask**: an 8-bit RGB or RGBA PNG, the same size as the heightmap.
  - **R**: water depth level × 60 (0, 60, 120, 180, 240), decoded to the nearest level (0–4), so levels are visible in an image editor.
  - **G**: ground type × 50, decoded to the nearest type: 0 grass, 50 brush, 100 wood, 150 sand, 200 rock (Phase 5). 0 is grass, the normal case, as R = 0 is dry.
  - **B**: ≥ 128 means blocked for every mobility.
- Maps are generated by `scripts/gen_<map>.gd`, and `make maps` runs every one of them. The PNGs are committed as the source of truth. The generators use floats and `FastNoiseLite`, which is fine because they run offline, not in the sim.
- **`MapBuilder`** (`scripts/mapgen/map_builder.gd`, Phase 8) is the tool code the generators share; it owns the rasters, the stamps (house, wall, plateau, road, patch), `save` and `report`. See Mission framework and campaign (Phase 8), Maps.

### Why the sim decodes PNGs itself
- Godot's PNG loader (`drivers/png/png_driver_common.cpp`) masks out `PNG_FORMAT_FLAG_LINEAR`, so 16-bit images load as 8-bit. That would terrace a 40 m heightmap into about 16 cm steps.
- `sim/png_codec.gd` parses PNGs itself:
  - It supports 8- and 16-bit gray, gray+alpha, RGB, and RGBA, non-interlaced, all five row filters.
  - It rejects palette images, sub-8-bit depths, and Adam7 with a clear error.
  - It rejects images over 64 MiB unfiltered, IDAT data too small to inflate to the stated size, and data that isn't a zlib stream, all before allocating pixel buffers.
  - A well-formed zlib stream that inflates to the wrong size still returns a clean error, but `decompress()` also prints an engine error that can't be suppressed from GDScript.
  - IDAT is inflated with `PackedByteArray.decompress(..., COMPRESSION_DEFLATE)`, which is a zlib stream (window bits 15) as PNG requires.
- It's tested three ways:
  - against fixtures from a separate Python encoder (`tests/fixtures/png/make_png_fixtures.py`, `make fixtures`)
  - against Godot's libpng for 8-bit images
  - in round trips

### Map PNGs must use the "keep" importer
- By default, Godot imports every PNG under `res://` as a texture. On export it ships the converted `.ctex` and drops the original file, so `FileAccess` can't read it in an exported build.
- Map and fixture PNGs therefore have committed `.import` files containing `importer="keep"` ("Keep File (exported as is)").
- **Any new map PNG needs the same `.import` file before Godot first scans it.**

## View (Phase 1)
- **Terrain mesh**: `TerrainView` builds one `MeshInstance3D` per 64×64-cell chunk with `TerrainMeshBuilder`. For 512², that's 8×8 chunks, frustum-culled per chunk.
  - Meshes are indexed. Full chunks share one index array.
  - `terrain.gdshader` derives flat face normals from screen-space derivatives. It colors by banded height (`TerrainPalette`) plus a water-depth tint texture sampled with nearest filtering, which is the same nearest-sample rule as the sim.
- **Camera**: `RtsCamera`, updated in `_process` and never touching the sim.
  - Orbit Q/E rotates around the focus point. Swivel Z/X ("pan" in CLAUDE.md) turns the camera in place, so the focus swings around it. WASD translates.
  - Zoom: mouse wheel steps and V (in) / C (out) held. Pitch follows zoom.
  - The focus is clamped to the map bounds. The camera stays at least 2 m above the terrain under it.
- **Input**: actions are registered in code by `InputBindings.install()` with physical keycodes, not in `project.godot`, so Phase 10 can rebind them at runtime.
- **Overhead map**: `OverheadMap` (Tab) is built once from the heightmap (height ramp, hillshade, water tint). It shows the camera focus and view direction. Clicking recenters the camera.

## Units (Phase 2)

### Data
- **`UnitType`** (`sim/units/unit_type.gd`, one `.tres` per type in `data/units/`) holds every gameplay number for a unit.
  - Identity: side, nature (LIVING/UNDEAD, for heal and conversion), mobility.
  - Body: hp, radius, height.
  - Movement: speed in mm/s, a 5-entry water speed table in permille by depth, and `uphill_slowdown_permille`.
  - Combat: melee stats (damage, accuracy, reach, wind-up, cooldown, shield block) and ranged stats, abilities.
  - Targeting (Phase 3): role (melee/ranged/support), preferred target roles, attack-move acquire radius.
  - Veterancy (Phase 3): per-stat caps for accuracy, attack rate, and speed.
  - View only: placeholder color and sprite.
- Gameplay fields are integers. Required ones default to 0 and `validate()` rejects 0, for the same `.tres` reason as `MapInfo`.
  - Validation also rejects a water table with 0 speed at a depth the mobility can enter, which would strand the unit there.
- **`UnitCatalog`** (`data/units/catalog.tres`) is an explicit, ordered list. Units hash their catalog index. A directory scan would break in exports, which rename `.tres` files to `.res` plus `.remap`.

### Unit entity
- **`Unit extends SimEntity`**: type, side, hp, facing, state, current order, and path.
  - Facing is a direction vector of length `FixedMath.DIR_ONE`.
  - State is IDLE, MOVING, ATTACKING or DEAD. DEAD is terminal. Phase 3 adds a standing order next to the state; see Combat.
- `SimEntity.hash_fields()` feeds `World.state_hash()`. `Unit` appends every field, path included, and the path queue is hashed too.
- **World step order:** commands → `MeleeCombat.update()` (Phase 3) → `UnitMovement.update()` → integrate.
  - Steering sets `vx`/`vz`, plus `vy = ground height at the next position − y`. Integration therefore puts units exactly on the ground, and velocity equals the real displacement, which the view uses for interpolation.
  - Units need a terrain and a catalog. Worlds without them still run plain entities.

### Integer trig
- `FixedMath` uses binary angles: 1024 per turn, sin/cos scaled so 65536 = 1.0.
- The quarter-wave table is committed, generated by `scripts/gen_sine_table.py`. libm `sin()` differs in the last bit across platforms, enough to desync once rounded.
- The purity check fails the build on `sin/cos/tan/atan2/pow/exp/log` or float `Vector2/3/4` in `sim/`.

### Pathing
- **`Pathing`** (`sim/pathing.gd`) holds one `PathLayer` per mobility, built on first use. Each layer has:
  - per-sample passability and A* weight;
  - connected components, from union-find over row runs;
  - an `AStarGrid2D`.
- **Why `AStarGrid2D` is deterministic here:**
  - It scores in `real_t` (float32).
  - With Chebyshev compute and estimate heuristics and whole-number weight scales, every g and f is an integer-valued float below 2^24. The arithmetic is exact, so FMA contraction and compiler differences can't change a result.
  - The open list breaks ties by f, then g, never by pointer. (Verified in `core/math/a_star_grid_2d.{h,cpp}`.)
  - Octile and Euclidean multiply by √2 and would break this. `test_pathing.gd` pins the settings.
- **Why not GDScript A\*:** it's about 30–100× slower. A Riverside creek detour is 100+ ms per unit there.
- **Weights:** LIVING pays 2 at depth 1 and 3 at depth 2, so it prefers dry ground and fords. UNDEAD and FLOATING pay 1 everywhere. Exact speeds stay per type.
- **`find_path` steps:**
  1. Snap the goal into the start's component (nearest reachable sample), so A* never floods a whole map for an unreachable click.
  2. Walk straight if `can_walk_straight` allows it.
  3. Otherwise run A*.
  4. String-pull to corners in two passes.
- **Line of sight** is an integer cell walk in the nearest-sample cell frame. Crossing exactly through a cell corner needs both side cells open (no diagonal squeeze). It is tested against fine point sampling.
- **Shortcuts are weight-aware.** A straight segment may not cross ground heavier than the heaviest point it replaces. Otherwise smoothing would undo A*'s dry detour and wade through the shallows.
- **Budget:** `UnitMovement` runs at most 6 A* solves per tick, oldest request first. It's a count, not a time budget, so every peer solves the same requests on the same tick.
- **Measured:** 40 units with random orders on Riverside average about 1.2 ms per tick (M4 Max, headless). Building the LIVING layer plus one creek detour takes about 125 ms, once per map.

### Movement and avoidance (`sim/units/unit_movement.gd`)
- **Speed per tick** = type speed with veterancy (capped at the group's slowest member) × water table[depth] × uphill factor.
  - The uphill factor is the grade along the heading × `uphill_slowdown_permille`, with a floor of 25%. Crossing a slope isn't slowed.
  - The integer remainder carries to the next tick, so long-run speed is exact.
- **Avoidance:**
  - Velocity heading into a body the unit would touch this tick is removed, so units slide around each other. Head-on, a unit sidesteps to its right, so two units meeting pass each other.
  - Any overlap that happens anyway is pushed apart at 25% per tick. An idle unit yields at a quarter of that, so a unit walking past a standing formation goes around it.
- **Terrain clip:** a step onto ground the mobility forbids slides along the open axis or stops. This is what keeps living units out of depth 3+ water.
- **Order independence:** every velocity is computed from start-of-tick positions, and states are settled in an earlier pass, so update order can't bias the result.
- **Stuck handling:** progress is measured toward the current waypoint, not the goal, since a detour to a ford moves away from the goal.
  - Within 2 m of the goal and stuck for 1 s: settle there.
  - Otherwise: re-path every 2 s and give up at 6 s.

### Formations (`sim/units/formations.gd`)
- Ten kinds on keys 1..0: short line, long line, loose line, staggered line, box, rabble, shallow encirclement, deep encirclement, wedge, circle.
- **Geometry:**
  - Slots are built in a local (right, forward) frame and rotated by the order facing, which points from the group's centroid to the target, or keeps the mean facing if the target is within 2 m.
  - Spacing = 2 × largest radius + 0.6 m.
  - Encirclements are arcs concave toward the facing, with the apex on the click. Units face the arc's center.
  - Circles are hollow rings; units face out.
  - Rabble jitters a box by an integer hash of the slot index, not the RNG.
  - Arcs and rings interpolate 8 extra bits between sine-table entries so neighbors are evenly spaced.
- **Assignment:** `SlotAssignment` is the Hungarian algorithm on straight-line distance, in integers. It takes about 9.5 ms for 100 units. Path length would need N² A* solves.
  - Each slot is then snapped into that unit's reachable component.

### View (`view/units/`, `view/hud/control_bar.gd`)
- **Sprites:**
  - `UnitsView` keeps one `UnitSprite` per unit and draws it between its last two tick positions by the physics interpolation fraction.
  - Each sprite is a full camera-facing quad pivoting on its feet. A vertical-axis-only billboard looks squashed and leans with perspective at RTS pitch.
  - The name label is hidden beyond 35 m. There's also a facing tick on the ground and a selection ring.
- **Selection:** `UnitSelection` is pure `RefCounted` state: selection plus 10 groups, pruned of dead units every frame. It's local to the player, not sim state.
- **`SelectionController`** turns input into selection changes and commands.
  - Press is read in `_unhandled_input`, so HUD clicks never select. Drag and release are read in `_input`, so a drag ending over the bar still completes.
  - Picking is screen-space against each quad's rectangle.
  - Right-click ground picking is `TerrainPicker`: a ray march plus bisection on the sim's own `height_at`. There are no physics colliders.
- **Keys:**
  - 1..0 set the formation for the next order. It's sticky and shown on the bar.
  - Cmd/Ctrl+1..0 save a group; Option/Alt+1..0 recall it.
  - H stops.
  - F9 (debug) switches the side the mouse commands. It stays now that the AI exists: the AI keeps driving its groups whichever side that is.
  - Godot key actions match events with extra modifiers, so the number-key actions are checked with `exact_match`.
- **`ControlBar`** mirrors every command for mouse-only play: formation buttons, group slots (click to recall; Set, then a slot, to save), Stop, and Switch side.
- **Spawns:** `MainView` spawns the Light test squad as tick-0 commands (20 Shieldmen north of the ford; Phase 3 adds a row of 5 Reavers behind them, Phases 4 and 6 Longbows, Sappers, and Wardens). The Dark side is no longer a test squad: since Phase 7 it is the Riverside AI mission (`data/missions/riverside_ai.tres`), whose groups spawn inside `World.step()`. `MainView.mission_path` picks the mission, and empty starts none. Phase 8: a campaign mission has no test squad. `MainView` builds its world from a `MissionLaunch` (`MissionSetup`, a `DeployCommand` roster), and the test squad is the sandbox's alone (`MainView.launch` null, which the demos use).

## Combat (Phase 3)
`sim/combat/melee_combat.gd` (`MeleeCombat`) resolves melee each tick. `Targeting` ranks enemies, `Veterancy` (`sim/units/veterancy.gd`) turns kills into bonuses, and `CombatEvent` reports what happened to the view.

### Orders vs. state
`Unit.order` is the standing order. `Unit.state` is what the unit is doing right now.

| Order | Fights | Ends |
|---|---|---|
| `NONE` (idle, stopped, arrived) | Enemies within reach + 1 m, and only those within 3 m of the spot it holds (`order_x/z`) | Never; the default |
| `MOVE` | Nothing | On arrival, becomes `NONE` holding that spot |
| `ATTACK_MOVE` | Enemies within the type's `acquire_radius`; chases up to 1.5× that | On arrival at its slot, becomes `NONE` |

- **ATTACKING**: the target is in reach. The unit stands, faces the target, and winds up or recovers.
- **Chasing**: the unit is `MOVING` with a `target_id`, using the normal movement path, A*, stuck handling and avoidance. It re-paths only when the target has moved more than 1 m from the chase goal.
- **Resuming**: after a fight, an attack-mover resumes toward its slot with its group's speed cap (`order_x/z`, `order_facing`, `order_speed_cap`). A holding unit stands where the fight ended.

### Tick
- **Order**: `MeleeCombat` runs after commands and before `UnitMovement`. Chases it starts are steered in the same tick, and units it kills get zero velocity.
- **Decide pass**, in ascending id order:
  - Each unit updates only itself: its target, chase path, facing, wind-up and cooldown.
  - It reads other units' positions, which nothing changes before movement, so iteration order can't matter.
  - Its candidate search uses a fresh `UnitGrid` with 8 m buckets.
- **Strike pass**: every blow due this tick lands in attacker-id order.
  - Blows are simultaneous. A unit killed this tick still lands its own blow, so two units can kill each other.
  - A blow at a target already killed this tick is wasted.

### Engagement
- **Reach** is measured edge to edge: center distance − both body radii ≤ `melee_reach`.
- **One target at a time.** Once the target is in reach, or a swing is under way, the unit keeps that target until it dies or gets away.
  - It doesn't turn to face other attackers, so enemies on its flank or rear get free blows.
  - While still approaching, it switches only to a preferred role, or to an enemy at least 1 m nearer. That stops chases flip-flopping between near-equal targets.
- **Wind-ups are committed.** A swing lands `melee_windup_ticks` after it starts, even if the target has moved.
  - If the target is then beyond reach + 0.25 m, it's a miss, and the cooldown is still paid.
  - A new order abandons the swing. The cooldown keeps running.
- **Timing**: the cooldown (`melee_cooldown_ticks`, shortened by veterancy) runs from the blow to the next swing, so one attack cycle is wind-up + cooldown.
- **Who can't be picked**:
  - An enemy hidden in deep water (`hidden_in_deep_water` at depth 3+), until it surfaces to fight (state ATTACKING). A unit that has sprung from an ambush (`Unit.surfaced`, Phase 7) stays surfaced for good, whether it is fighting or not.
  - An enemy the unit can't walk to (a different pathing component for its mobility), unless it is already in reach. A Shieldman on the bank can hit a Husk in the shallows next to it, but won't chase one into deep water.

### Blows
- **RNG draws** from `World.rng`, in this order:
  1. The hit roll, against `Veterancy.melee_accuracy`.
  2. A block roll, only if the blow comes from the front and the target has `shield_block_permille > 0`.
  3. The damage variance roll.
- **Aspect** is the cosine between the target's facing and the direction to the attacker, in integer permille:

| Aspect | Arc | Damage | Shield |
|---|---|---|---|
| Front | within 60° of facing | ×1.0 | blocks |
| Flank | 60°–120° | ×1.2 | no |
| Rear | beyond 120° | ×1.4 | no |

- **Damage** = `div_round(melee_damage × (1000 ± up to 100) × aspect multiplier, 10⁶)`, minimum 1.
- **Death**: hp ≤ 0 calls `Unit.kill()`.
  - The unit is DEAD, stays in `world.units` and the entity registry as a body, and is still hashed.
  - Movement already skips dead units, so bodies never block or push.
  - The killer gets `kills += 1`, but only for a unit of the other side.

### Targeting
`Targeting.pick` ranks candidates in this order:
1. A role the unit's type prefers (`preferred_target_roles`, bits of `UnitType.Role`).
2. Nearest body edge.
3. Lower id.

The Ripper prefers ranged and support units, so an attack-moving Ripper runs past a nearer Shieldman to reach an archer. Every other v1 type takes the nearest enemy.

### Veterancy
- **Curve**: `bonus = cap × kills / (kills + 4)`, in integer permille per stat, with the caps set per type.
  - Every early kill helps, each helps less than the last, half the cap arrives at 4 kills, and the cap is never reached.
- **Accuracy** adds hit-chance points, capped at 100%.
- **Attack rate**: cooldown × 1000 / (1000 + bonus), minimum 1 tick.
- **Speed** scales `move_speed`, including a group's march cap.
- Nothing is cached. The bonuses are pure functions of type and `kills`, and `kills` is hashed and carries over with the unit (Phase 8).

### Events
- `World.combat_events` lists this tick's SWING, HIT, BLOCK, MISS and KILL events. Each has the attacker, target, damage, overkill (KILL only) and aspect.
- The list is cleared at the start of each step and is not part of `state_hash()`. It is output for the view.
- The view reads it after every step, which `MainView` guarantees by calling `after_step()` once per `step()`.

### View
- **Reading combat**: `UnitsView.after_step()` reads `World.combat_events`.
  - HIT and BLOCK flash the target's quad (white, and steel blue for a block).
  - A KILL records the blow direction, and bursts the body into gibs when the overkill is large enough.
  - A unit seen dead for the first time lies down exactly once.
- **Sprites**
  - The HP bar is two billboarded quads, fill and empty side by side so they can't z-fight. It shows only while the unit is hurt or selected.
  - A dead body stops billboarding and lies flat, head along the killing blow and tilted to the ground normal from the sim's `gradient_at`. It is dimmed and stays for the mission.
  - Picking a body uses the quad's projected corners, and a standing unit wins over a body under it.
- **Gibs** (`view/effects/gibs.gd`) are the only Godot physics in the game, and cosmetic only.
  - **Trigger**: overkill ≥ 25% of the victim's max hp, so mostly Reaver blows today; explosions later.
  - **Ground**: a `StaticBody3D` with a `HeightMapShape3D` built from the sim heights, offset by half the map extent because the shape is centered on its origin.
  - **Layers**: chunks sit on physics layers 9 (ground) and 10 (gibs) and collide only with those.
  - **Settling**: physics runs at the 30 Hz tick rate, so chunks use continuous collision detection. A chunk freezes once it sleeps, or after 4 s, and stays for the mission. At most 150 simulate at once; the oldest freeze first.
- **Tooltip** (`view/hud/unit_tooltip.gd`)
  - Hovering over any unit, either side, alive or dead, shows its name and side, HP and activity, kills, and its veterancy-adjusted accuracy, attack rate and speed.
  - It is hidden over HUD controls and never takes mouse input.
  - The text comes from the pure `UnitTooltip.describe()`, which is tested.
- **Attack-move input**
  - Cmd/Ctrl + right-click is the `ATTACK_MOVE` action, checked with `exact_match` before the plain move, because mouse actions also match with extra modifiers.
  - The control bar's **Move** and **Attack-move** toggles arm that order for the next *left* click on the ground, once, with a crosshair cursor while armed. That way a one-button mouse or a trackpad can give every order.
  - Right-click, Esc, pressing the toggle again, or losing the selection cancels. Nothing arms with nothing selected.
  - The order marker is red for an attack-move.
  - The status line shows living units per side.

### Design decisions
- **Frontal shields** (decided with Tim). A flank multiplier alone would make a surround matter mostly through numbers, and 10 Husks beat 5 Shieldmen on numbers with or without it. The Shieldman's 35% frontal block means a Shieldman line is strong from the front and collapses when surrounded. The Reaver has no shield and hits harder.
- **Ripper is LIVING** (decided with Tim). Deep water stops it, so it has to path around (e.g. flanking at The Ford), and it isn't killed by healing.
- **Husks never improve** (all veterancy caps 0): they are mindless.
- **Reach cut from 1.3–1.5 m to 0.5–1.0 m edge to edge.** At the old reach a second rank could strike through the first, which made holding a gap pointless.

### Battle tests (`tests/sim/test_battles.gd`)
Each scenario runs on five seeds, with the shipped data.

| Scenario | Result (seeds 1–5) |
|---|---|
| 10 Shieldmen holding a line vs 10 Husks attack-moving through it | Shieldmen win 10–0 every seed, in about 14 s |
| 10 Husks on a ring closing on 5 Shieldmen | Husks win with 4–8 left |
| Control: the same 5 Shieldmen in a 7 m gap vs the same 10 Husks | Shieldmen win with 3–4 left |

- **Where blows land**: blows on Shieldmen come from the flank or rear about 67% of the time in the surround, and 0% in the line.
- **Lockstep**: a 40-unit attack-move battle across the Riverside ford stays hash-identical between two worlds, at about 1.2 ms per tick per world (M4 Max, headless).

## Projectiles (Phase 4)
Arrows, grenades, and satchel charges are sim entities with their own physics. There is no Godot physics.

**Files** (all in `sim/projectiles/` except where noted)

| File | Role |
|---|---|
| `FlightState` | The integrator |
| `Ballistics` | Aiming |
| `ProjectileCollision` | Swept contact tests |
| `ProjectileSystem` | Motion |
| `Explosions` | Blasts |
| `sim/combat/ranged_combat.gd` | Who shoots at what |
| `sim/combat/damage.gd` | The one path hit points leave a unit |

### Units and the integrator
- **Micrometres.** Projectiles keep position in µm and velocity in µm/tick (`FlightState.SUB` = 1000 per milli-unit).
  - Milli-units are too coarse for drag: a grenade loses well under 1 mm/tick per tick to the air.
  - `SimEntity.x/y/z` mirror the flight in milli-units (floored). `vx/vy/vz` are the last tick's displacement, for the view.
- **One integrator:** `FlightState.advance(drag)`, semi-implicit Euler.
  1. `vy -= 10_900` (exactly 9.81 m/s² at 30 Hz).
  2. Quadratic drag: `v -= v·|v|·drag_ppm_per_m / 10¹²`, with `|v|` from `isqrt`.
  3. `p += v`.
- The live flight, the aiming solver, and the clear-path check all call this one function. A solved aim is therefore exactly the flight that happens.
- `SimEntity.integrate()` is virtual. `World._integrate()` calls it for every entity; `Projectile` overrides it with a no-op, because `ProjectileSystem` moves projectiles with collision.
- **Overflow.** The largest products are drag (`v·|v|·ppm`, under 10¹⁸) and dot products with 65536-long normals (about 10¹¹).
  - Body and blast tests run in milli-units, where the swept-cylinder quadratic stays under 10¹⁶.
  - µm → mm always uses `div_floor`, because positions under craters and off the map edge can be negative.

### Data
- **`ProjectileType`** (`data/projectiles/*.tres`) follows the same conventions as `UnitType`.
  - Behavior: `STICKS` (arrows) or `BOUNCES` (grenades, charges).
  - Radius and drag.
  - Contact: restitution, friction, roll acceleration, rolling resistance, rest speed, steepest resting slope.
  - Impact damage and `marks_fire`.
  - Fuse, fuse variance, and fizzle chance.
  - Blast: radius, inner radius, damage, knockback radius and speed, crater radius and depth, `chain_detonates`.
- The types live in **`UnitCatalog.projectile_types`**:
  - a unit type is only usable with the projectiles it names;
  - one resource validates the cross-references;
  - `World.new`'s signature stays unchanged.
- **`UnitType` ranged fields:**
  - `ranged_projectile` (empty means no ranged attack)
  - `ranged_aim` (DIRECT or LOB), launch speed (the maximum), lob grade, launch height
  - min and max range, draw (windup) and cooldown ticks
  - spread, uphill spread, uphill range
  - ammo (−1 is unlimited)
- **`UnitType` special fields:** `special_ability` (NONE, FIRE_ARROW or SATCHEL; Phase 6 appends), charges, and the special projectile.
- **`UnitType` body:** `hover_height`.
- Veterancy's accuracy cap also narrows the aim cone.
- The unused Phase 2 placeholders `ranged_damage`, `ammo`, and `abilities` are gone.

**Shipped projectiles:**

| Type | Numbers |
|---|---|
| Arrow | 18 damage, drag 0.5 %/m |
| Fire arrow | 30 damage, marks fire |
| Grenade (bottle) | Fuse 3.5 s ±10 %, fizzle 5 %, restitution 0.35, friction 0.7, blast 3.5 m / 60 (full within 0.75 m), knockback 5 m at 6 m/s, crater 1.2 m × 15 cm |
| Satchel | No fuse, blast 5 m / 150 (full within 1.5 m), knockback 7 m at 9 m/s, rests on up to 24°, crater 2 m × 40 cm |

**Shipped units** are appended to the catalog, so earlier indices and hashes don't move:

| Unit | Side | Stats |
|---|---|---|
| Longbow | Light, living | 70 hp, 2.8 m/s, dagger. Arrows direct at 34 m/s, lob fallback 31°, 2–50 m, 0.4 s draw, 1.5 s cooldown, spread 25 ‰. One fire arrow |
| Sapper | Light, living | 80 hp, 2.0 m/s, weak melee. Grenades lobbed at 45° up to 17.5 m/s, 5–28 m, spread 60 ‰, uphill spread ×4. Four satchels |
| Drifter | Dark, undead, floating | 50 hp, 2.2 m/s, hovers 0.6 m. Arrows direct at 28 m/s, 3–40 m, no melee, never improves |

### Tick order
`World.step()` runs, in order:
1. commands
2. `MeleeCombat`
3. `RangedCombat`
4. `UnitMovement` (now with knockback and hover)
5. integrate units
6. `ProjectileSystem`
7. `Explosions`
8. drop removed projectiles

- Projectiles are tested against the units' positions after this tick's movement.
- **Iteration rules:**
  - Projectile loops run by index up to the size at the start of the pass. Charges dropped mid-pass first move next tick.
  - Removal only sets `removed`; the array is compacted at the end of the tick.
  - The explosion queue is FIFO within the tick.
  - A projectile launched in the loose pass advances once in the same tick. The solver counts its first step the same way.

### Flight and contact (`ProjectileSystem`)
- **FLYING.** Each tick is one `advance()`. The swept segment is tested against:
  - **the ground:** sub-steps of at most 250 mm, then 8 bisections to about 1 mm. The whole test is skipped when the segment flies above `Terrain.max_height_in`, the per-8×8-cell tile maximum.
  - **living, visible bodies:** upright cylinders from `y` to `y + body_height`, where `y` already includes hover.

  The earliest contact wins. A body wins a tie with the ground, and the lower id wins among bodies. A projectile passes through its launcher for 8 ticks after release. A unit killed earlier in the same pass no longer stops later arrows.
- **Arrows (STICKS).**
  - **In a body:** a frontal shield rolls to block it (the same `shield_block_permille` and 60° arc as melee), otherwise ±10 % damage through `Damage.apply`. A fire arrow also leaves a fire mark there.
  - **In the ground:** the sim emits STICK and forgets the arrow. Stuck arrows are cosmetic and live in the view, which keeps sim state bounded (thousands of arrows per mission would otherwise sit in the hash).
- **Bounces (BOUNCES).** The normal comes from `gradient_at` (permille truncation is under 0.1° of error).
  - Formula: `v' = v_tangent·friction − v_normal·restitution`.
  - A rebound under 1.5 m/s starts ROLLING.
  - The rest of that tick's travel is dropped: at most 33 ms per bounce, and only one contact per tick.
  - Bodies deflect grenades and charges the same way, with no harm, so a grenade thrown at a unit drops at its feet.
- **ROLLING.**
  - The velocity is kept tangent to the ground: any component into it is removed every tick.
  - Gravity's pull along the slope (`G·ny·n − ŷG`, i.e. g·sin θ) is scaled by `roll_accel`.
  - Rolling resistance is scaled by cos θ.
  - It lifts off (FLYING) where the ground drops more than 2 cm below it, and rests when slower than `rest_speed` on ground no steeper than `static_slope`.
  - The draft version integrated horizontal velocity only and gained energy on uphill transitions. The test "never gains energy" now pins this.
- **RESTING:** skipped until a blast moves it.
- **Fuses.** A burning fuse ends in a fizzle roll (`ProjectileSystem.fizzle_permille`, the hook Phase 5 extends for rain, snow and water) or a burst.
  - A fizzled grenade is a **dud**: it lies inert for the mission, but a blast still sets it off.
- **Off the map:** flying projectiles more than 50 m outside the map are removed. Rolling ones stop at the edge.

### Aiming (`Ballistics`)
- **Parametrization.** A launch is a bearing and a speed.
  - The bearing is `(h, t)`: `h` is the horizontal unit vector, 65536 long (1000 would put 5 cm of sideways error on a 50 m shot), and `t` is the grade `tan(elevation)` in 1/65536.
  - Velocity is `speed · (h, t) / √(1 + t²)`. No trig anywhere.
- **`solve_direct`** (archers): full speed, find the grade on the low arc.
- **`solve_lob`** (throwers): fixed grade, find the speed, up to the unit's maximum. Tim chose this over the literal "max speed, solve the angle": a full-speed 8 m throw leaves at about 9° and skips far past its target.
- **How both solve.**
  - Each is a bracketed Illinois root-find on how far above the target the real integrator's flight passes.
  - It is seeded by the exact no-drag answer, computed in milli-units with g = 109/10 mm/tick². The scaled µm form overflowed inside Longbow range.
  - Drag and the discrete step only ever shorten a flight, so no no-drag solution means none at all: a free early out.
  - It stops within 5 mm, allows at most 16 flights, and rejects a best miss over 10 cm (only shots at the very edge of reach fall between the two).
- **Fallback.** Each unit tries its own style first, then the other, taking the first launch whose path `is_clear()`:
  - no ground more than 1 m short of the target;
  - for auto-picked targets, no friendly body anywhere in the aim cone. Bodies are tested against a projectile that grows by spread × distance flown.

  The cone rule came from a battle test in which 14 % of arrow hits landed on friends: the center line cleared their heads by centimetres. Friendly bodies are pre-filtered to the corridor around the line to the target, because with no wind a flight stays in one vertical plane.
- **Lead.** A walker is led by the flight time of an unchecked solve at its current position.
- **Aim points:** arrows aim at the chest (60 % of body height), explosives at the ground under the feet.
- **Spread.** `perturb()` spreads the launch into a cone of half-width `spread` (tan × 1000), uniform over the cross-section (r = spread·√u), keeping the speed.
  - It always makes exactly two RNG draws.
  - `spread = base × (1000 − veterancy accuracy bonus)/1000 × (1000 + uphill grade × uphill_spread/1000)/1000`.
- **Uphill range:** effective max range = `max_range × 1000/(1000 + uphill grade × uphill_range/1000)`. Slow throws need none, because physics already shortens them.
- **Measured reach, flat vs 8 m up** (`test_ballistics`):
  - arrow at 34 m/s: 82 → 75 m (−9 %)
  - throw at 17.5 m/s: 29 → 20 m (−31 %)

  So thrown explosives suffer far more uphill, from physics alone.

### Ranged combat (`RangedCombat`)
- **Two passes:** decide in ascending id, where each unit updates only itself; then loose in ascending id, where RNG draws and spawns happen.
- **Doesn't shoot:**
  - a unit melee owns (`target_id` set)
  - one reeling from knockback
  - one on a MOVE order
  - one out of ammo
- **Holding (NONE) or ATTACK_MOVE:**
  - **Candidates:** visible enemies within `[min, effective max]`, ranked by `Targeting`.
  - **Re-picks** happen on the unit's staggered tick, every 6 ticks, or at once when its target goes. A unit with nothing it can hit also waits for its tick instead of retrying every tick.
  - **Kept target:** it stays while no other is worth switching to, without re-solving; the shot re-aims anyway.
  - **New targets:** up to 3 are tried with the solver and the clear-path check.
  - **Throwers** skip a target with a friend, themselves included, within blast radius + 1 m of the aim point.
  - **Archers** skip one whose aim point (after lead) is within 1 m of a friend's body. An arrow a hand off target would hit the friend.
  - An attack-mover halts to shoot (state SHOOTING) and marches on when nothing is left in range.
- **GROUND_ATTACK** (Cmd/Ctrl + left click, `GroundAttackCommand`):
  - fires at the spot until another order;
  - walks toward it if it's out of reach, checking again every 10 ticks;
  - gives up with a CANT_REACH event and holds if, once stopped, it still can't reach it, or if the spot is inside its minimum range;
  - ignores friendly bodies: the player chose the spot.
- **Melee interplay.**
  - A ranged unit only takes melee targets within reach + 1 m, whatever its order, and never chases. Its fight is at range.
  - Taking up melee abandons a draw. After the fight a ground attacker gets to walk into range again.
  - A unit without melee now ends an attack-move on arrival. Before, the no-melee early return skipped the arrival hold, and a Drifter would have attack-moved forever.
- **T** (`UseSpecialCommand`):
  - a Sapper drops a resting satchel at its feet (4 per mission);
  - a Longbow nocks its fire arrow, which its next shot fires (auto-picked or ground attack), spending the charge.
- Kills by arrow count toward veterancy, like melee kills.

### Explosions (`Explosions`) and damage (`Damage`)
- **`Damage.apply`** is shared by melee, arrows, and blasts. It handles hp, the kill, credit (enemies only), the CombatEvent (now with `source_x/z`, where the blow came from), and death drops.
  - It rolls no dice. Each source rolls its own dice first, in its own order, which is why the Phase 3 melee fingerprints are bit-identical after the refactor.
  - A dying Sapper's unused satchels fall in a fixed ring around its feet. There's no RNG, so it can't disturb the draw order of the blows that killed it.
- **One burst:**
  1. **Units** within blast radius, measured as the 3D distance to the nearest point of the body cylinder, friend and foe, in ascending id. Damage is full within the inner radius and falls off linearly to 0; there's no roll.
  2. **Knockback** within its radius: horizontal, outward, fastest at the center, into `Unit.knock_v`.
     - `UnitMovement` adds it before the terrain clip, so no blast can throw anyone into water or onto ground they can't stand on.
     - It keeps 80 % per tick. While faster than 1 m/s the unit is reeling: no walking, swinging, or shooting, and a swing or draw in progress is lost.
  3. **Death drops** land now, so a Sapper killed by a blast cooks off its own satchels.
  4. **Loose objects:** anything `chain_detonates` inside the blast that isn't already `detonating` is caught. It goes off 4 ticks later (a visible ripple), credited to this burst's instigator. Others inside the knockback radius are thrown out and up.
  5. **A crater**, if the burst is within `crater_radius` of the ground.
- **Craters.**
  - `Terrain.scar()` digs a bowl, capping each sample's total at 1 m, stored as sparse scars and hashed.
  - **Craters never change passability:** `sample_slopes` and the path layers stay as loaded, so pathing never rebuilds mid-mission. Units and objects do sit in the crater, because heights change.
  - `crater_radius ≤ blast_radius` is validated, so anything a crater could unsettle has already been set off or thrown. That's why craters don't wake objects.
- **Kill credit** goes to the instigator: the thrower of a grenade, or whoever set off the blast that caught a charge.
- **Terrain ownership.** Each `World` owns its own heights (`Terrain.copy_for_world`).
  - Packed arrays are shared by reference in Godot 4, so without the copy two lockstep worlds built from one loaded map scarred each other. A test pins that.
  - Water, blocked samples, slopes and the tile maxima stay shared and read-only. Craters only lower ground, so the shared tile maxima stay valid upper bounds.

### RNG draw order
| When | Draws, in order |
|---|---|
| A shot leaves (loose pass, shooter id order) | spread bearing, spread radius; then fuse variance for a fused projectile |
| An arrow strikes a body (projectile id order) | shield block (front arc, shielded target only), then damage variance |
| A fire arrow lands, in a body or the ground (Phase 5) | its flame's fizzle, only when the chance isn't zero |
| A fuse burns down (projectile id order) | fizzle (now with the weather in the chance) |
| A melee blow (unchanged) | hit, block (front, shielded), variance |
| `Fire.update` (Phase 5), after Explosions | douse per burning cell (only in rain), then spread per front cell and neighbor (only for a non-zero chance); see Fire below |

### Hash
`state_hash()` adds:
- the projectiles, as entities with every field;
- the terrain scars;
- `fire_marks` (gone in Phase 5: the fire grid replaced it);
- the explosion queue length (always 0 between ticks);
- the new `Unit` fields.

`projectile_events` is output only, like `combat_events`.

### Decisions
- **Ground attack is Cmd/Ctrl + left click** (Tim). Attack-move keeps Cmd/Ctrl + right click. On macOS it's Cmd, because Godot turns Ctrl + left click into a right click there (checked in `platform/macos/godot_content_view.mm`, `mouseDown`).
- **Throwers lob; archers shoot flat** (Tim). Each falls back to the other style when its own path isn't clear.
- **Shields block arrows from the front** (Tim), with the same chance and arc as melee.
- **T is instant** (Tim): a Sapper drops a charge, a Longbow nocks. It works on a mixed selection.
- **Auto-fire avoids friends; ordered fire doesn't.** Archers and throwers won't auto-pick a shot that endangers a friend (the aim cone, the blast, a target locked in melee with one). A ground attack fires where it's told. Friendly fire is real either way: spread, leading, bounces, and rolling grenades still hit friends.
- **The terrain stays bilinear.** The mesh's triangles differ from it by a few cm on banks, which is invisible at RTS distance for 6 cm grenades. Switching `height_at`/`gradient_at` to triangles would also re-pin Phase 1–3 tests.

### Battle and performance (M4 Max, headless)
| Measurement | Result |
|---|---|
| 10 Shieldmen hold a line vs 15 Husks, alone (5 seeds) | Light wins with no losses, 26.3 s average |
| The same with 5 Longbows behind | Light wins with no losses, 22.1 s; 1 of 172 arrow hits on a friend (14 % before the aim-cone rule) |
| Riverside ford battle, 34 units, Longbows, Sappers and Drifters, satchels, 900 ticks | 2.0 ms/tick per world, hash-identical across worlds. Most of it is aiming: about 90 µs for a direct solve, 180 µs for a lob, 90–450 µs for the clear-path check |

Peaks reach about 6 ms on ticks where several units re-pick and every candidate is blocked. Phase 10's performance pass has a count-based aim budget per tick (round-robin, deterministic) ready to cap that if 100 units need it.

### Not yet
- Indoor maps: walls stopping projectiles. Blocked samples don't stop them; there is no wall height data yet.
- Terrain shielding units from a blast.
- Orders to attack a specific unit.

## Weather, water, fire (Phase 5)
The environment changes tactics:
- Rain makes grenades and fire arrows unreliable.
- Water puts out anything burning.
- Fire runs through grass, brush, and wood, stops at sand, rock, and water, and burns out.
- Husks in the deep creek can't be seen until you are on the bank.

**Files**

| File | Role |
|---|---|
| `sim/weather.gd` | `Weather`: rain, snow, wind, snow cover, wetness |
| `sim/weather_change.gd`, `sim/weather_schedule.gd` | A mission's weather as data (`data/weather/*.tres`) |
| `sim/commands/set_weather_command.gd` | The only way weather changes from outside |
| `sim/fire.gd` | `Fire`: the burn grid |
| `sim/units/visibility.gd` | `Visibility`: submerged units and what each side sees |
| `view/debug_weather.gd` | F6 weather presets |

### Tick order
`World.step()` now runs:
1. commands
2. **`Weather.update`**
3. `MeleeCombat`
4. `RangedCombat`
5. `UnitMovement`
6. integrate units
7. `ProjectileSystem`: fizzle reads the weather, water douses, fire arrows ignite
8. `Explosions`
9. **`Fire.update`**
10. drop removed projectiles

`fire.changed` is cleared at the start of each step, like the event lists.

### Weather
- **State, all integers and hashed:**
  - `rain`, `snow`: intensity in permille.
  - `wind_x`, `wind_z`: mm/s, clamped to ±50 m/s so a ramp's products can't overflow. **Visual only**; nothing in the sim reads it.
  - `snow_cover_ppm`, `wetness_ppm`: parts per million, exposed as permille.
  - The ramp in progress.
- **`change_to(start_tick, …, ramp_ticks, snow_cover = -1)`:**
  - Ramps linearly from wherever the weather is at `start_tick` (the old ramp evaluated there, so ramps chain without a jump) to the new values.
  - Uses `FixedMath.div_round`, so the endpoints are exact.
  - `snow_cover >= 0` sets the cover outright, for a map that starts white.
- **The ground responds every tick.** The tick constants divide 10⁶, so every rate is a whole number of ppm per tick:
  - snow builds cover (full after 2000 ticks of full snow, about 67 s);
  - rain soaks (1000 ticks, about 33 s);
  - cover melts once snow stops (5000 ticks);
  - the ground dries once rain stops (4000 ticks).
- **Schedules are commands.** A `WeatherSchedule` is `WeatherChange`s in strictly ascending tick order. `commands()` turns them into `SetWeatherCommand`s that are enqueued at mission start, like the spawns, so a replay's command stream carries the weather. Phase 7's SET_WEATHER trigger action calls `change_to()` directly, the call `SetWeatherCommand.apply` makes: a trigger is sim state, not an outside change, so it isn't in the command stream (see Enemy AI and mission triggers).
- **Riverside test schedule** (`data/weather/riverside_showers.tres`):
  - a breeze;
  - showers at 70 % from 45 s;
  - a downpour at 2 min;
  - clearing at 3 min.

  Phase 7 stopped loading it in the game: the Riverside AI mission's `raid` trigger brings the rain instead. `test_weather` still loads it.

### Fizzle and water
- **What burns:** a projectile with a lit fuse (`fuse_ticks > 0`) or `marks_fire`. Satchels don't.
- **Per-type data on `ProjectileType`:** `rain_fizzle_permille`, `snow_fizzle_permille`, `snow_cover_fizzle_permille`. Each is the chance at full intensity or cover, scaled linearly, and ignored on anything that doesn't burn (so a test can take a grenade's fuse out without touching them).
- **`ProjectileSystem.fizzle_permille(world, p, on_ground)`** combines the type's own chance with these as independent chances, in integers: `1000 − (1000−base)(1000−rain)(1000−snow)(1000−cover)/10⁹`.
- **Grenades:**
  - Still one roll, when the fuse burns down, so the Phase 4 draw order is unchanged.
  - On the ground (motion ≠ FLYING), the snow cover counts too.
  - The shipped grenade (400/250/150) fizzles at **430 ‰ in heavy rain**. In the test, 100 grenades per seed gave 44, 41, and 51.
- **Fire arrows:**
  - One roll for the flame when the arrow lands, after the block and variance draws.
  - The roll is skipped when the chance is 0, so in clear weather a fire arrow draws nothing a plain arrow doesn't.
  - A fizzled arrow still wounds; it just lights nothing.
  - Shipped values: 500/300/400.
- **Water, no dice.**
  - A lit fuse that touches water of depth ≥ 1 (a bounce, a roll step, coming to rest) goes out at once (FIZZLE, with `depth`). The grenade is a dud, which a blast or a fire can still set off.
  - A fire arrow landing in water goes out the same way: FIZZLE, no roll, nothing lit.
  - A fire arrow striking a unit that stands in water has nothing to light, so it doesn't roll either.
- **Throwers** don't auto-pick an enemy standing in water: the throw would be wasted. A ground attack still throws where it's told.
  - The Riverside lockstep battle's Sappers used to bombard the ford itself; they now shell the dry far bank.

### Fire (`Fire`)
- **Cells are terrain samples**, the same nearest-sample rule as water and pathing.
- **What catches:** grass, brush, and wood, if dry (water 0) and unburnt. Sand, rock, and water never burn, so they're firebreaks. A blocked sample burns as its ground.
- **Burning:** a cell lit during tick L burns until the end of tick L + `BURN_TICKS`, then is SCORCHED for good. It's lit by a fire arrow, through `World.ignite`, which emits `IGNITE` (renamed from `FIRE_MARK`, same enum slot).
- **Spread:**
  - Each tick, each burning cell rolls once per unburnt flammable neighbor: 8 neighbors, diagonals at 707/1000.
  - The chance is the neighbor's ground's `SPREAD_PPM`, damped by rain (−90 % at full), wetness (−80 %), and snow cover (−90 %). The three compound.
- **Rain douses:** every burning cell rolls 15,000 ppm per tick at full rain (about 2 s), and a doused cell is scorched.
- **Damage:** every 10 ticks, each living unit on a burning sample loses 3 hp (9 hp/s) through `Damage.apply`.
  - The kill is credited to whoever lit the fire. Cells lit by the spread inherit their source's lighter.
  - There's no RNG.
- **Explosives:** a charge, grenade, or dud lying or rolling (not flying) on a burning cell is caught through `Explosions.catch`, the same path and 4-tick delay a blast uses, credited to the fire's lighter.

**Tuning.** With per-tick rolls:
- **Speed** follows the chance.
- **Survival:** a fire keeps going only while chance × burn time stays above about 1.
- **The first rates were six times too fast.** They came from one neighbor's average wait (17,000 ppm for grass at 0.5 m/s), but many paths race, and grass actually ran at about 3 m/s.
- **Shipped values**, measured on open 1 m ground in clear weather (4 seeds each):

| Ground | Spread | Burns | Front speed |
|---|---|---|---|
| Grass | 4,000 ppm | 300 ticks (10 s) | 0.59 m/s |
| Brush | 2,000 ppm | 600 ticks (20 s) | 0.30 m/s |
| Wood | 1,000 ppm | 1200 ticks (40 s) | 0.15 m/s |

- Chance × time is 1.2 for each:
  - **dry:** no fire died out, and none left unburnt patches;
  - **heavy rain:** a fire never gets going;
  - **soaked ground:** it crawls.
- The burning band is about 6 m deep.

**Update order and RNG.** Lists are walked in ascending sample index:
1. **Douse:** one roll per burning cell, only while it rains.
2. **Spread:** the *front*, as it stood at the start of the pass.
   - The front is the burning cells that may still have an unburnt flammable neighbor.
   - One roll per such neighbor with a non-zero chance, in row-major neighbor order.
   - A neighbor lit now burns at once, so no later cell rolls for it, but it spreads only from next tick.
   - A front cell with nothing left to light leaves the front for good, because cells only go unburnt → burning → scorched.
3. **Damage**, on its interval: units in ascending id.
4. **Explosives:** projectiles in ascending id.
5. **Burn-outs:** from a bucket keyed by tick. They come last, so a cell still hurts and sets things off in its final tick, L + `BURN_TICKS`.
   - A cell an arrow lit during tick L is in that tick's front, since it was lit before the pass, and spreads from L.
   - A cell the spread lit during tick L first spreads at L + 1.
   - Both burn out at the end of L + `BURN_TICKS`.

**Cost.** Only the front does spreading work and burn-outs are bucketed, so the cost per tick tracks the fire's edge, not its area. Front membership changes how much work a tick does, never what happens, so it isn't hashed.
- `test_spreading_only_from_the_front_changes_nothing` proves it. A world whose front is every burning cell before every tick (brute force) stays hash-identical to the real one for 1000 ticks of mixed ground, water, rain, and snow.

**Hash.**
- `hash_fields()`: the burning cells (index, burn-out tick, lighter).
- `World.state_hash()` adds the dense state bytes.
- The grid is allocated on the first fire, so a world that never burns carries none.

### Visibility
- **`Visibility.is_submerged`** is `MeleeCombat.is_hidden` moved, unchanged in Phase 5. Phase 7 adds one exception: a unit with `Unit.surfaced` set is never submerged. Submerged units can't be targeted or hit by anyone (blasts excepted).
- **`Visibility.seen_by(world, unit, side)`** is for the view. A side sees:
  - its own units;
  - anything not submerged;
  - a submerged unit while one of its living units is within the hider's new `UnitType.reveal_radius` (Husk 4 m, horizontal, center to center).
- **Decision (in the approved plan):** the reveal radius is view-only.
  - Seeing a Husk under water doesn't let you shoot it: arrows still pass over it. An archer targeting something it can't hit would waste its arrows.
  - `test_enemy_hidden_in_deep_water_is_not_picked` keeps its meaning.

### Map: ground types
- **`scripts/gen_riverside.gd` writes G:**
  - **sand** within 4.5 m of the channel on both banks, and on the creek bed;
  - **rock** on crests above 21 m, or over 550 ‰;
  - **wood** copses and **brush** patches from two noise layers;
  - **grass** elsewhere.
- **Counts:** grass 163,084, brush 49,611, wood 30,845, sand 15,679, rock 2,925 samples.
- **Heights and water are untouched:**
  - `height.png` is byte-identical;
  - `test_riverside_map` pins a SHA-256 of the heights, water, and blocked samples as Phase 1 made them;
  - it also proves every bank sample is sand and that no 8-connected run of flammable ground crosses the creek.
- **Synthetic terrains:** `Terrain.new`'s new trailing `ground_types` defaults to all grass. `TestTerrains.from_ascii` takes `b` (brush), `w` (wood), `s` (sand), and `r` (rock).

### View
- **Terrain:**
  - Ground types tint the height bands, on the terrain and the overhead map alike, so firebreaks read before anything is lit.
  - Blocked samples (houses, walls; Phase 8) are drawn darker and greyer on the terrain, so a house reads as solid: see Mission framework and campaign (Phase 8), Maps.
  - An R8 texel per sample follows `fire.changed` (burning glows with emission, scorched is charred), with one `ImageTexture.update()` per tick that changed.
  - `wetness` darkens and cools the ground.
  - `snow_cover` whitens faces whose world normal points up (smoothstep 0.55–0.85), not steep faces, and not water, which is drawn over it.
- **Snow and fire on the terrain:** snow can cover burnt ground, but a burning cell melts its own.
- **No particle nodes.** Rain, snow, flames, and smoke are each one `MultiMeshInstance3D` of quads that a vertex shader animates from `TIME`, with a per-instance phase in `INSTANCE_CUSTOM`. This is the Godot docs' "animating thousands of fish" pattern, and it behaves the same in Compatibility on Mac and Web. Custom data is packed to 16 bits in Compatibility, so it only carries 0..1 values.
- **`PrecipitationView`** (`view/weather/`):
  - Up to 6000 rain streaks and 4000 flakes in a 60 × 30 × 60 m box on the camera's focus.
  - Intensity only sets `visible_instance_count`, so more rain reveals more of the same drops.
  - The shader wraps positions in world space against the box corner, so the camera slides over weather that stays put.
  - Wind tilts the streaks. Its drift is integrated on the CPU, because `TIME × wind` would jerk every drop whenever the slowly ramping wind changed.
  - Drops fade near the box faces and the lens, and keep a minimum on-screen size.
  - At far zoom the rain reads as a patch around the focus. Scaling the box with distance would thin it.
- **`FireView`** (`view/effects/`):
  - One flame billboard per burning cell (additive, flickering, up to 4096).
  - A rising smoke puff on every cell with `(i + j) % 3 == 0`, drifting with the wind.
  - Each cell's jitter, scale, and phase come from a hash of its index, so the buffers can be rewritten whole on any tick the fire changed without anything jumping. That rewrite costs about 1 ms for a few hundred cells and about 3 ms at the cap (debug build).
- **Checked in a window** (GL Compatibility on Metal): screenshots of grass fires, the downpour putting them out, and snow over the scorch.
- **Not checked:** WebGL2 and Windows. Phase 10 does the cross-platform pass.
- **Units:**
  - A sprite is drawn only if the side the mouse commands sees it, and `sprites()` (picking, hovering) lists only drawn ones.
  - F9 switches the viewer along with the side.
- **ExplosionsView:**
  - FIZZLE puffs now also mark rain-fizzled arrows and doused fuses.
  - The Phase 4 fire-mark disc is gone.
- **Main scene:**
  - Adds the `Fire` and `Precipitation` views. Phase 5 also enqueued the schedule at tick 0; Phase 7 removed that, because the mission's triggers own the weather now.
  - Feeds the terrain the fire and weather after every step.
  - The stats line shows rain, snow, wetness, cover, and burning cells.
  - **F6** (debug) cycles clear → rain → heavy rain → snow through a `SetWeatherCommand` ramped over 3 s. It lasts until the mission's next weather change (a trigger's SET_WEATHER) or the next F6.

### Measured (M4 Max, headless)
| Scenario | Result |
|---|---|
| Riverside ford battle (34 units) plus five grass fires lit at tick 0, clear for 30 s (about 1,250 cells burning) | 1.80 ms/tick mean, 7.5 ms worst (the Phase 4 aiming spikes) |
| The same as heavy rain arrives | Every fire out within 15 s; 1.04 ms/tick |
| `state_hash()` with the 512² fire grid | 0.66 ms |
| Lockstep test: the ford battle with fire arrows into the grass and rain from tick 450 | Hash-identical across worlds; 2.05 ms/tick per world |

### Not yet
- Units don't path around fire. Phase 7's AI doesn't either (its groups walk through burning ground), so this moved to a later phase.
- No Burning status on units (done in Phase 6).
- Blasts and lightning don't light grass.
- Wind doesn't push fire.

## Special units and status effects (Phase 6)
The v1 roster is complete:
- **Warden:** heals with herbs.
- **Blightbag:** a walking bomb that leaves paralyzing gas.
- **Stormcaller:** casts lightning down a line.
- **Ripper:** now carries and throws whatever lies about.

Units have status effects, and a HUD panel shows the selection.

**Files**

| File | Role |
|---|---|
| `sim/combat/status_effects.gd` | `StatusEffects`: paralysis, confusion, burning, and gas clouds paralyzing |
| `sim/combat/gas_cloud.gd` | `GasCloud`: an entity that paralyzes what is in it |
| `sim/units/interactions.gd` | `Interactions`: errands (heal, pick up, strike a plant, tear a part off a body), herb gathering, scavenging |
| `sim/projectiles/lightning.gd` | `Lightning`: the bolt as a line |
| `sim/herb_plant.gd` | `HerbPlant`: struck once for two herbs |
| `sim/commands/` | `HealCommand`, `InteractCommand`, `ApplyStatusCommand`, `SpawnHerbPlantCommand` |
| `view/hud/unit_info.gd`, `unit_info_panel.gd` | The HUD's words for units and things, and the selection panel |
| `view/effects/gas_clouds_view.gd`, `view/units/herb_plants_view.gd` | Clouds and plants |
| `scripts/demo_abilities.gd` | `make demo-abilities` |

### Tick order
`World.step()` now runs:
1. commands
2. `Weather`
3. **`StatusEffects`**
4. `MeleeCombat`
5. **`Interactions`**
6. `RangedCombat`: bolts strike at the end of it
7. `UnitMovement`
8. integrate
9. `ProjectileSystem`: carried objects follow their carriers
10. `Explosions`: clouds and scattered packets
11. `Fire`: sets units alight
12. drop removed projectiles and spent clouds

### Status effects (`StatusEffects`)
- **State.** Each unit keeps the last tick it is affected per kind (`Unit.status_until`, `NONE` = −1) and `burn_credit_id`. Both are hashed.
  - `apply(kind, ticks)` sets `max(until, tick + ticks − 1)`, so an effect refreshes and never stacks.
  - An effect applied during commands lasts exactly `ticks` ticks, counting the current one.
  - `cure()` clears every effect (a herb). `kill()` clears them too, and a body takes no new ones.
- **Paralysis.**
  - The unit doesn't walk, turn, swing, shoot, cast, or work on an errand, and a wind-up in progress is lost.
  - `UnitMovement._advance` skips it, so it isn't counted as stuck and its order is still there afterwards.
  - Blasts and separation still push it.
  - Its shield doesn't block (`MeleeCombat.can_block`, for melee and arrows). That skips the block roll, which shifts the RNG stream only when paralysis is present.
- **Confusion.**
  - Melee picks the nearest unit of either side within `acquire_radius`, whatever the order (MOVE included). It ignores role preference (`Targeting` with `nearest_only`) and the hold leash.
  - Ranged shoots the nearest anyone in range, ground attack included, with no friend checks. A confused ground attacker aims at the unit, not its spot.
  - A kill of a friend earns no veterancy, as before.
  - The tick after it wears off, `UnitOrders.resume()` drops the fight and the shot. MOVE and ATTACK_MOVE re-march to `order_x/z`, GROUND_ATTACK stands, INTERACT restarts its walk, and anything else holds where it stands.
  - `_kept_target` now also drops a friend for a unit in its right mind.
  - No v1 unit causes confusion; F8 does, and so will the later confusion caster.
- **Burning.**
  - `BURN_DAMAGE` (3) every `BURN_INTERVAL_TICKS` (10) on the world's tick, credited to the latest source.
  - Water of depth 1+ puts it out.
  - **Fire now works through it:** a burning cell sets units on it alight for `FIRE_BURN_TICKS` (2 s), every tick, so they burn on after stepping off. It used to damage them directly.
  - A fire arrow whose flame holds also sets the unit it strikes alight for 5 s.
  - The rate is unchanged at 9 hp/s, but the first hurt lands at the next 10-tick boundary after the cell sets the unit alight.
- **Paralyzing touch:** `UnitType.melee_status` and `melee_status_ticks` are applied on every melee HIT. No v1 unit uses them; the later paralyzing zombie will.
- **A melee blow that lands spoils the target's draw, cast, or errand wind-up**, for every unit. This is how sustained melee shuts a Stormcaller down. It also means Drifters stop shooting while they are stabbed.
- **Debug:** F8 cycles paralysis, confusion, and burning (5 s each) on the selection through `ApplyStatusCommand`, so it is part of the command stream.

### Errands (`Interactions`)
- **The order.** `Order.INTERACT` (appended) uses `interact_id` (any entity), `resume_order`, and `act_left`. All are hashed.
- **The action** follows from the pair (`action_for`):

| Who | On what | Does |
|---|---|---|
| A HEAL unit with herbs | A living friend that is hurt or affected | Heals `heal_hp`, cures |
| A HEAL unit with herbs | Anything undead, either side | Kills it (credited) |
| A HEAL unit with room | A resting herb | Takes it |
| A `throws_carried` unit, empty-handed | A resting CARRY object | Picks it up |
| The same | A body with `parts_taken < 2` (not a Blightbag) | Tears off its `scavenged_projectile`, straight into its hand |
| A unit with melee damage | An unspent herb plant | Strikes it: two herbs drop, it is spent |

  A living enemy, or a friend with nothing to heal, is refused.
- **The walk and the act.**
  - The unit walks at the target, re-pathing after 1 m of drift. Within `REACH` (0.6 m, edge to edge) it stops, faces the target, and winds up: `heal_windup_ticks`, `melee_windup_ticks` for a plant, 9 ticks to pick up.
  - The act lands if the target is still within reach + 0.25 m. Otherwise the wind-up is lost and nothing is spent, the same rule as a melee whiff.
  - Then it goes back to `resume_order`: an attack-move marches on, anything else holds where it stands.
- **Giving up.**
  - Commands refuse a target outside the unit's pathing component, unless it is already in reach.
  - A unit that has walked to its target, stopped, and still can't reach it gives up (`ground_walked` doubles as the "has walked" flag).
  - A target that stops being actionable (taken by someone else, healed to full, dead) ends the errand.
- **What skips it:** melee and ranged skip INTERACT units unless confused, and never run the MOVE arrival `hold()` on them. A paralyzed or reeling unit makes no progress.
- **Commands.**
  - `HealCommand` sends only healers; `InteractCommand` sends anyone who can.
  - Either way the nearest qualifying unit goes (ties to the lower id), and the rest keep their orders.
- **Herbs on contact:** a healer with room picks up any resting or rolling herb within 0.3 m of its body edge, errand or not.
- **Scavenging** (`scavenge_radius`, Rippers 8 m) runs on the unit's staggered 6-tick slot.
  - It applies to a unit that is holding or attack-moving, empty-handed, and not fighting, shooting, reeling, paralyzed, or confused.
  - The unit takes the nearest resting CARRY object or tearable body in range (ties to the lower id). It skips things inside a live gas cloud, things another unit is already going for (claims are taken in id order, so a lower id claims first), and things it can't walk to.
  - The errand resumes the order the unit had.

### Warden and herbs
- **`Special.HEAL`** (appended): the stack is `special_charges`, and `special_projectile` must be a HERB pickup (checked by the catalog).
- **Death drops:** `Damage.drop_on_death` drops a HEAL unit's remaining herbs in the same fixed ring as a Sapper's satchels.
- **Herbs** are BOUNCES projectiles (`pickup = HERB`), so blasts toss them like anything else.
- **Herb plants** are map data: `MapInfo.herb_plants` is x, z pairs in milli-units.
  - MainView plants them with tick-0 `SpawnHerbPlantCommand`s, like the spawns.
  - Riverside has four, two on each bank, tested dry and walkable; `gen_riverside.gd` writes them.
  - A plant is never touched by blasts, fire, or bodies.

### Blightbag and gas
- **The unit.** UNDEAD nature and mobility.
  - `melee_detonates`: it chases and winds up (20 ticks) like a melee unit, and the blow is `Damage.self_destruct`. There is no roll; a target that slipped out of reach is a miss.
  - `UnitType.has_melee()` (damage or detonating) replaces `melee_damage > 0` where it matters.
  - T (`Special.DETONATE`, 1 charge) is the same self-kill.
- **Death bursts it, every time:**
  - `drop_on_death` drops its `special_projectile` (`blight_burst`) and `Explosions.catch`es it, credited to the killer (a self-kill to itself).
  - **Chain delays are now exact:** `catch` adds a tick when it runs before `ProjectileSystem` this tick (`World.projectile_pass_begun`), so a charge caught by melee, lightning, burning, or a herb goes off exactly 4 ticks later, like one caught by a blast or a fire. Before, an early catch would have gone off a tick sooner, because the pass counts down what was there when it began.
  - `Damage.apply` now ignores dead targets. Without that, a Blightbag killed earlier in a strike pass would have burst again on its own landing blow, and two blows meeting in one tick would credit two kills.
- **The burst** (`blight_burst`): blast 4 m / 50 (full damage within 1 m), knockback 5 m at 5 m/s, no crater.
  - It leaves a **GasCloud**: 5 m, 10 s, paralysis lasting 2 s past leaving.
  - It **scatters** two `gas_packet`s, resting, 4.5 m out. They are placed after the burst's object-catch step, so it doesn't set them off.
- **`GasCloud`** is an entity (hashed). From the tick after it appears, it paralyzes every living unit whose body edge is within its radius and whose feet are within 3 m of its height: both sides, undead, Blightbags. Then it counts down, and is dropped at the end of its last tick. It neither drifts nor spreads.
- **Gas packets** (`pickup = CARRY`, `chain_detonates`, `bursts_on_impact`, gas only: 3.5 m, 6 s, 2 s).
  - A blast, fire, or lightning sets them off.
  - One a unit threw (`Projectile.thrown`) bursts on its first contact, ground or body, in the same tick.
  - One knocked by a blast just lands.
- **Gas alone sets nothing off:** the catch radius is the blast's, which is 0. `ProjectileType.bursts()` (blast or gas) and `effect_radius()` replace `is_explosive()` where gas counts: validation, and throwers' friend checks.

### Stormcaller and lightning
- **The lightning.** A `BOLT` projectile (appended behavior) is never spawned.
  - `radius` is the line's half-width (0.35 m), and `impact_damage` is 45.
  - The Stormcaller is LIVING (`ranged_projectile = lightning`): 75 hp, no melee, 8–40 m (the 8 m minimum range is the dead zone), a 1 s cast, a 4 s cooldown, spread 30 ‰.
- **Aiming** (`RangedCombat`):
  - Bolts aim at the chest with no lead.
  - `Lightning.is_clear` needs the ground clear up to 1 m short of the aim point.
  - For auto-picked targets, it also needs no friend anywhere on the whole line out to its reach, within half-width + `PATH_MARGIN` + spread × the friend's own distance out. The spread swings the whole line about the caster, so the corridor widens along it; a corridor sized at the target's distance let a friend 25 m out be struck now and then.
  - **A Stormcaller behind its own line therefore won't cast;** Phase 7's AI positions it. The lockstep battle puts the Stormcallers on a flank for that reason.
  - Ground attack, and confusion, skip the friend check.
- **Casting:**
  - The loose pass makes one lateral spread draw (uniform within ± spread × distance) and queues the bolt.
  - After every shot has left, the queued bolts strike in caster id order. Like melee blows, they are simultaneous: a caster killed by an earlier bolt that tick still casts.
- **`Lightning.strike`:**
  - The line runs from the launch point through the aim point to the full reach, cut where it meets the ground.
  - Every living, non-submerged body it touches (caster excepted) takes 45 ± 10 % in ascending id. Shields don't stop it.
  - Every non-detonating `chain_detonates` projectile within reach of the line is caught, wherever it is.
  - It emits `ProjectileEvent.BOLT` with the end point.
- **The overflow lesson.**
  - `ProjectileCollision.cylinder_contact`'s quadratic overflows 64 bits for a body hundreds of metres to the side of a 40 m line. The true discriminant (about −5·10¹⁹) doesn't fit, and the wrapped value can read as a hit.
  - The demo's first bolt struck the whole Light army at the ford, 180 m off.
  - ProjectileSystem never hit this, because it asks only about bodies its grid found near the segment. `Lightning` now rules out bodies outside the segment's box first.
  - `test_a_bolt_never_strikes_anything_far_off_its_line` pins it. Any new caller of `cylinder_contact` must pre-filter the same way.
- **Validation:** launch speed and lob grade moved from `UnitType` to `UnitCatalog._validate_references`, which knows the projectile: a bolt needs neither.

### Ripper: carry and throw
- **Carrying.** `Projectile.Motion.CARRIED` (appended) and `carrier_id` link to `Unit.carried_id`.
  - `ProjectileSystem` puts a carried object at the carrier's hand (`Interactions.hand_y`, 75 % of body height) after movement. It does no collision checks.
  - A blast doesn't knock it out of the hand, but does catch it. Fire under the carrier catches it too, since the rule only excludes flying objects. Either way it goes off in the hand.
  - `World.remove_projectile` and `despawn_entity` clear the link, and `World.carried_by()` treats a link to a removed object as empty-handed.
  - A dying carrier drops what it holds, resting, at its feet.
- **Throwing.** `throws_carried` reuses the `ranged_*` fields as the throw: Ripper lobs at 0.8 grade, up to 15 m/s, 3–20 m, a 0.4 s wind-up, a 1 s cooldown, spread 80 ‰. It ships `ranged_ammo = −1`, and `ranged_projectile` stays empty.
  - `Unit.fights_at_range()` (shoots, or holds something) replaces `has_ranged()` for melee's adjacent-only rule and for who runs in `RangedCombat`.
  - `next_projectile` returns the carried type.
  - The throw launches the object itself: owner, instigator, ignore window, and `thrown` are set, and nothing new is spawned.
  - Once its hands are empty, `RangedCombat` still counts down its throw cooldown and stands it down out of SHOOTING. Without that, an attack-mover stopped for good after its throw, and a holder never scavenged again.
  - Aiming is as for any thrower: role preference (Rippers hunt ranged and support), and friend checks over the object's `effect_radius`. Things with impact damage aim at the chest.
- **Thrown impacts:**
  - A body part (`impact_damage` 8) hurts the first body it flies into, with no roll, credited to the thrower.
  - A gas packet bursts on contact.
  - Either way the first contact ends `thrown`.
- **CARRY pickups** are satchels, gas packets, and body parts. Herbs are for healers only.

### Data (appended; earlier catalog indices and hashes don't move)

| Unit | Numbers |
|---|---|
| Warden | Light, living, support. 85 hp, 2.6 m/s, melee 9 at 75 %. 6 herbs, 60 hp each, 0.5 s to apply |
| Blightbag | Dark, undead. 40 hp, 1.1 m/s, acquires at 10 m, bursts on contact after 20 ticks |
| Stormcaller | Dark, living, ranged. 75 hp, 2.0 m/s, lightning 8–40 m |
| Ripper (changed) | Carries and throws; scavenges within 8 m |

| Projectile | Numbers |
|---|---|
| `herb` | BOUNCES, HERB |
| `gas_packet` | BOUNCES, CARRY, gas 3.5 m / 6 s / 2 s, bursts on impact |
| `blight_burst` | Blast 4 m / 50, gas 5 m / 10 s / 2 s, scatters 2 packets at 4.5 m |
| `lightning` | BOLT, 45, half-width 0.35 m |
| `body_part` | BOUNCES, CARRY, impact 8 |
| `satchel` (changed) | Now a CARRY pickup |

**Catalog checks added:**
- A HEAL herb must be a HERB pickup.
- A DETONATE special must burst.
- Scavenged parts must be CARRY.
- Scatter projectiles must exist.

### RNG draw order (additions)

| When | Draws |
|---|---|
| A bolt is loosed (loose pass, caster id order) | lateral spread |
| Bolts strike (after the loose pass, caster id order) | per bolt, one damage roll per body struck, ascending id |
| A carrier's throw | the two spread draws, as any throw; no fuse draw |
| Status effects, gas, errands, scavenging, herbs, impacts of thrown objects | none |
| A blow or arrow at a paralyzed shielded target | the block roll is skipped |

### Hash
`state_hash()` gains:
- **on `Unit`:** status timers, `burn_credit_id`, `interact_id`, `resume_order`, `act_left`, `carried_id`, `parts_taken` (Phase 7 appends `surfaced`);
- **on `Projectile`:** `carrier_id`, `thrown`;
- **new entities:** gas clouds and herb plants.

The bolt queue and `projectile_pass_begun` are always empty or false between ticks.

### View and HUD
- **Sprites:**
  - A status tints the body (paralysis pale blue, confusion magenta, burning a flickering orange) and names itself in a tag over it.
  - A heal flashes the target green (`CombatEvent.HEAL`).
- **Effects:**
  - **Gas clouds:** translucent hemispheres that fade in and fade out over their last 2 s.
  - **Bolts:** jagged chains of thin boxes with a flash where they ended, gone in 0.2 s.
  - **A gas-only burst:** a green puff instead of a flash.
  - **Herb plants:** green bushes that shrink and brown once spent.
  - **Loose objects:** labeled "Charge" for anything with a blast, else by name.
- **Input:**
  - T with a Warden that has herbs also arms Heal (`ArmedOrder.HEAL`): the next left click on a living unit sends a `HealCommand`. A click on nothing leaves it armed; right click and Esc cancel, as before.
  - Right-click on a herb plant, a loose object, or a body sends an `InteractCommand`, but only if a selected unit could act on it (`Interactions.action_for`). Otherwise it is a plain move.
  - Picking: `ProjectilesView.object_at` and `HerbPlantsView.plant_at` are screen-space radius picks.
- **`UnitInfo`** has the HUD's words, shared by the tooltip and the panel:
  - status effects with seconds left;
  - "Herbs 4/6", "Bursts when it dies", "Lightning: unlimited · dead zone 8 m", "Carrying: Satchel charge";
  - errands named Healing, Fetching, Gathering herbs, or Scavenging.

  The tooltip also names the herb plant or loose object under the cursor.
- **`UnitInfoPanel`** is docked above the control bar's left end and hidden with nothing selected.
  - One unit: its name, a health bar, and its details.
  - Several: the counts by type, and a cell per unit (up to 24) in its type's color, with a health bar and a frame tinted by status. Click a cell to select just that unit; shift-click to drop it.
- **MainView** adds 3 Wardens to the Light test squad and (until Phase 7) 3 Blightbags and 2 Stormcallers to the Dark one, and plants Riverside's herbs.

### Decisions
- **Tim chose** (plan approval):
  - each Blightbag burst scatters two gas packets;
  - body parts are torn from bodies (two per body), not spawned by gibbing, so gibs stay cosmetic;
  - Rippers scavenge on their own before Phase 7's AI;
  - T arms Heal and a click picks the patient.
- **Defaults in the approved plan:**
  - The Stormcaller is living, so a herb doesn't kill it and only sustained melee or missiles do.
  - The Blightbag is undead, so a herb kills it and it bursts on the Warden.
  - A herb cures every status.
  - A paralyzed unit can't block.
  - Burning replaces direct fire damage, with a 2 s afterburn.
  - A blow that lands spoils any draw.
- **Gibbed bodies still give up parts in the sim:** the pieces are lying there, and gibbing is view-only.

### Behavior changes to earlier phases
- **Fire hurts through Burning.** The first hurt comes at the next 10-tick boundary after a cell sets a unit alight, and it burns on for 2 s. `test_fire` re-pins four tests: the hit schedule, the last-tick test (now an afterburn test), a burning Sapper's satchels, and the fire kill credit.
- **A melee blow that lands spoils a draw:** Drifters too.
- **No block roll on a paralyzed target.**
- **Validation:** launch speed and lob grade are checked by the catalog (`test_validate_rejects_half_defined_ranged` expects 5 errors, not 7). `chain_detonates` and fuses accept gas-only bursts.
- **Satchels can be picked up and thrown by Rippers.**

### Measured (M4 Max, headless)

| Scenario | Result |
|---|---|
| Full-roster ford battle, 42 units with herbs, a plant, heals, confusion, gas, lightning, and scavenging; 1500 ticks, two worlds (`test_roster_lockstep`) | Hash-identical. 1.40 ms/tick per world, worst 5.4 ms after tick 0 (tick 0 builds three pathing layers) |
| `make demo-abilities` at 3× (windowed) | Every event plays out; the finale ends Light 9/37, Dark 0/36 |
| The same since Phase 7's final fix wave, headless | Every event plays out. The finale ends Light 19/37, Dark 0/36 at 3×, and Light 8/37, Dark 0/36 at 30×. The demo now turns the AI mission off and stands its own Dark squad at the finale, where MainView used to (see Phase 7's Demo). It waits on wall-clock timers between events, so its numbers move with speed and frame timing |
| Test suite | 598 tests, about 45 s, when this row was measured; Phase 6 merged with 602, Phase 7's baseline |

### Not yet
- AI that uses the new units well. Phase 7 did two of the four:
  - Stormcallers that hold where their lines are clear (done);
  - Blightbags walking at clusters (done);
  - Wardens healing on their own (deferred);
  - Rippers choosing what to fetch (deferred).
- Lightning doesn't light grass, and rain doesn't affect it.
- A burning unit doesn't spread fire to the ground it walks on.
- Gas doesn't drift with the wind, and rain doesn't thin it.
- Conversion (a later caster).

## Enemy AI and mission triggers (Phase 7)
The Dark side now plays, and a mission is data:
- **Groups:** squads that patrol, guard, hunt, flank, lie in ambush, or fall back when they are losing.
- **Tactics:** Stormcallers hold at range where their line is clear, Blightbags walk at the thickest knot of enemies, and a caster's escorts go for whatever threatens it.
- **Triggers:** a mission's rules (a unit enters an area, a timer runs out, a group is cleared) spawn groups, change the weather, set the objective, switch a group's behavior, and decide the outcome.
- **Riverside:** its Dark side is `data/missions/riverside_ai.tres`, hand-written. The game shows the objective and a Victory or Defeat banner, and F5 shows what the AI is doing.

The AI and the triggers run inside `World.step()`. They draw no random numbers, and they order units through `UnitOrders`, the way a player's commands do.

**Files**

| File | Role |
|---|---|
| `sim/ai/ai_group_spec.gd`, `ai_unit_entry.gd` | `AiGroupSpec`, `AiUnitEntry`: one group as data |
| `sim/missions/mission_script.gd`, `trigger_spec.gd`, `trigger_action.gd` | `MissionScript` (a mission's groups and triggers), `TriggerSpec`, `TriggerAction` |
| `sim/missions/difficulty.gd` | `Difficulty`: the five tiers, and per-tier values |
| `sim/missions/mission_runtime.gd`, `mission_event.gd` | `MissionRuntime`: which triggers fired, the objective, the outcome; `MissionEvent` |
| `sim/ai/ai_director.gd` | `AiDirector`: spawns groups, think cadence, behavior switches, the ambush spring |
| `sim/ai/ai_group.gd`, `ai_event.gd` | `AiGroup`: one spawned group's state; `AiEvent` |
| `sim/ai/ai_behaviors.gd` | `AiBehaviors`: IDLE, PATROL, GUARD, HUNT, AMBUSH, RETREAT, and legs |
| `sim/ai/ai_orders.gd` | `AiOrders`: free members, buckets, march, engage |
| `sim/ai/ai_tactics.gd`, `standoff_spot.gd`, `cluster_finder.gd` | STANDOFF, CLUSTER, and the bodyguard rule |
| `sim/ai/ai_flank.gd`, `flank_route.gd` | FLANK: the plan, and the route's geometry |
| `data/missions/riverside_ai.tres` | The Dark side of Riverside |
| `view/hud/mission_hud.gd` | `MissionHud`: the objective and the banner |
| `view/ai/ai_debug_view.gd` | `AiDebugView`: the F5 overlay |
| `scripts/demo_ai.gd` | `make demo-ai` |

### Tick order
`World.step()` now runs:
1. commands
2. **`MissionRuntime.update`**: the triggers (only in a world with a mission)
3. **`AiDirector.update`**: groups think (only once a group exists)
4. `Weather`
5. `StatusEffects`
6. `MeleeCombat`
7. `Interactions`
8. `RangedCombat`
9. `UnitMovement`
10. integrate
11. `ProjectileSystem`
12. `Explosions`
13. `Fire`
14. drop removed projectiles and spent clouds

- **Why here:** right after the commands and before anything reads a unit's order, so the AI's orders are in place the way a player's are. An order given in step 3 is steered in step 9 of the same tick. A group a trigger spawns or switches in step 2 is there for the AI in step 3.
- `world.ai_events` and `world.mission_events` are cleared at the start of each step, like the other event lists. They are output for the view and tests. Nothing in the sim reads them, and they aren't hashed.
- Once a mission has an outcome the triggers stop. The AI and the rest of the sim keep running.

### Data
- **Everything is a `.tres` `Resource`**, like `UnitType` and `WeatherChange`, with a `validate()` that lists every problem.
  - That includes an enum field holding a value outside its enum: a group's `behavior`, `faction`, `patrol_mode`, `formation`, and `on_alert`; a trigger's `condition` and `faction`; an action's `kind` and `behavior`. A hand-written `.tres` can hold any integer there, and an unknown value would fall through every `match` without a word.
  - Specs are read-only at runtime, because `load()` hands every world the same instance. A group's progress lives in `AiGroup`, a mission's in `MissionRuntime`, and both feed `state_hash()`.
  - `riverside_ai.tres` is written by hand with `;` comments. The editor drops them if it re-saves the file.
- **`MissionScript`** holds `groups: Array[AiGroupSpec]` and `triggers: Array[TriggerSpec]`.
  - `World.start_mission(mission_script, tier)` creates the `MissionRuntime`. It refuses, with a `push_error` and `false`, in a world with no terrain or catalog, one that has already stepped or started a mission, a null script, a tier outside 0..4, or a script that doesn't validate. Nothing spawns until the first step.
  - The parameter is `mission_script`, not `script`: `script` is a native `Object` property and won't compile as a member name.
- **`AiGroupSpec`** (`faction` defaults to DARK; a LIGHT group is driven the same way):

| Field | Meaning |
|---|---|
| `name` | Unique in the script; triggers refer to a group by it |
| `units` | `AiUnitEntry`s: a `type_id` and per-tier `counts` |
| `spawns`, `spawn_by_tier` | Spawn points as x, z pairs, and which one each tier uses |
| `facing_x/z`, `formation` | Shape it spawns and marches in (default BOX); 0, 0 faces north |
| `spawn_at_start` | Spawns on the mission's first tick; otherwise a SPAWN_GROUP action does it |
| `behavior` | What it does from the moment it spawns |
| `waypoints`, `patrol_mode` | PATROL: x, z pairs; LOOP or PING_PONG |
| `guard_radius` | GUARD: how far from its anchor it chases |
| `alert_radius`, `on_alert` | PATROL: an enemy this close switches it to `on_alert` (0 never). AMBUSH: the spring radius, which must be above 0. GUARD: hurt from outside `guard_radius`, it switches to `on_alert` (see Behaviors). `on_alert` is GUARD, HUNT (default), or FLANK |
| `flank_roles` | Role bits FLANK goes after (default 6: ranged and support) |
| `retreat_below_permille`, `retreat_point` | Fall back below this share of its starting health (0 never); where to (default: its spawn point) |

  - `Behavior` is IDLE, PATROL, GUARD, HUNT, FLANK, AMBUSH, RETREAT (Phase 8 appends ESCORT, with `escort_radius`). The order is the hash order, so only append. RETREAT can't be a starting behavior or a SET_BEHAVIOR target: the AI enters it.
  - A behavior needs its parameters: PATROL two or more waypoints, GUARD a radius, AMBUSH an `alert_radius`, FLANK at least one role. `params_errors(b)` is public because a SET_BEHAVIOR action is checked against its target group with it. `on_alert` needs its parameters too in a group that starts as PATROL, AMBUSH, or GUARD, the three that can switch to it.
  - Several defaults are non-zero on purpose (faction, formation, `on_alert`, `flank_roles`; `TriggerSpec` faction LIGHT, `min_count` and `count` 1, `ticks` [0]), like `WeatherChange`: they are the common case, and `validate()` checks every field that has a range.
  - **List melee entries before ranged.** A group spawns front to back in the order the entries are listed, and a STANDOFF group marches its casters 6 m behind the rest, so melee that starts behind them has to squeeze past (see Tactics).
- **Difficulty tiers.** Five, 0 (easiest) to 4. Anything that varies by tier is a `PackedInt32Array` of 1 entry (used at every tier) or 5, so a mission only spells out the tiers it changes (`Difficulty.is_valid`, `Difficulty.pick`).
  - Per tier: each entry's unit counts (a harder tier can add a type an easier one lacks), the spawn point (`spawn_by_tier` indexes `spawns`), and a TIMER's `ticks`.
  - A tier where a group has no units still creates the (empty) group, so GROUP_CLEARED sees it spawned. Validation rejects a group that spawns nothing at any tier.
  - The sandbox `MainView` plays tier 2. A campaign mission plays the tier the player chose at New Campaign (Phase 8's difficulty select), kept in `CampaignState.tier`.
- **`UnitType` AI fields** (an `AI` export group, after Veterancy and before View): `ai_tactic` (`ASSAULT` default, `STANDOFF`, `CLUSTER`) and `ai_standoff_permille`.
  - STANDOFF needs a ranged attack and a permille of 1..950 (`UnitType.MAX_STANDOFF_PERMILLE`). At 1000 a unit walking to its spot overshoots by up to 250 mm, fails `holds`' range check where it stops, and is sent to a new spot at every think. Any other tactic needs 0.
  - No unit type was added, so catalog indices don't move.

| Unit | Tactic |
|---|---|
| Stormcaller | STANDOFF at 900 ‰ of its 40 m range (36 m) |
| Drifter | STANDOFF at 850 ‰ (34 m) |
| Blightbag | CLUSTER |
| Every other type | ASSAULT |

### Triggers (`MissionRuntime`)

| Condition | Holds when |
|---|---|
| AREA_ENTERED | `min_count` living units of `faction` are within `area` (x, z, radius), center to center |
| UNIT_DIES | `count` of the units the groups in `names` ever had are dead or gone, summed across the groups |
| TIMER | `ticks` (per tier) have passed since the trigger became active |
| GROUP_CLEARED | every group in `names` has spawned, and none of the units they ever had is left |
| FACTION_ELIMINATED | `faction` has no living unit, and has had one since the mission started |

Phase 8 appends two conditions (TRIGGERS_FIRED, PLAYER_ELIMINATED), three objective actions (SHOW, COMPLETE and FAIL_OBJECTIVE) and a `names` filter on AREA_ENTERED, and the draws that bind wave aliases: see Mission framework and campaign (Phase 8).

- **Actions**, in data order:
  - SPAWN_GROUP spawns the group, directly with `World.spawn_unit`, not through a `SpawnUnitCommand`.
  - SET_WEATHER takes a `WeatherChange` whose `tick` is 0 and calls `Weather.change_to()` now, the call `SetWeatherCommand.apply` makes.
  - SET_OBJECTIVE sets the text (empty clears it).
  - SET_BEHAVIOR switches every spawned group of the spec.
  - WIN and LOSE are described below.
- **Two passes.** The first checks the condition of every trigger that hasn't fired and is active, before any trigger's actions run. The second fires the due ones in index order, each applying its actions in data order. A trigger's effects therefore never make another fire on the same tick, and the order triggers are listed in changes only the order their actions run. A trigger fires once.
- **`after` opens at T+1.** A trigger with `after` is active from the tick after its prerequisite fired, never the same tick. A TIMER counts from that activation (`fired_tick + 1`), or from the mission's start tick when it has no `after`. A trigger with no actions is a gate for the ones that name it.
- **Spawns and the first tick.** Starting groups spawn at the top of the first update, before any condition is read, so a GROUP_CLEARED on a group with no units at this tier can fire on tick 0. A group a trigger spawns is first seen by conditions on the next tick.
- **LOSE beats WIN.** WIN and LOSE are recorded rather than applied on the spot, so the firing trigger's other actions still run. If a LOSE fired this tick the outcome is LOST, even when a WIN fired on the same tick. The WON or LOST event carries the first trigger whose action decided it.
- **Nothing is evaluated after an outcome.** `update` returns at once.
- **FACTION_ELIMINATED needs the side seen.** `seen_factions` gets a bit for every faction that has had a living unit since the mission started, read every tick before the passes. Without it a side that hasn't spawned yet counts as eliminated, and a "Light eliminated" LOSE would fire on tick 0 in a mission whose Light units arrive later.
- **Counting the dead.** UNIT_DIES and GROUP_CLEARED look at each group's `spawned_ids`, which is never pruned. A spec named twice in `names` counts once.
- **Objective text** is display only, so it isn't hashed. The trigger that set it and a revision counter are, and they change whenever the text does.
- **Events.** `MissionEvent` kinds are TRIGGER_FIRED, OBJECTIVE, WON, and LOST (Phase 8 appends OBJECTIVE_STATE). `to_array()` leaves the text out.

### AI groups (`AiDirector`, `AiGroup`, `AiBehaviors`, `AiOrders`)
- **A group** is one spawned instance of a spec (a spec spawned twice makes two groups).
  - `AiDirector.spawn_group` lays the tier's units on formation slots at the tier's spawn point and records their total hit points (`start_hp`).
  - `members` are the living units still on the group's side, ascending. `AiGroup.prune` drops one that died, vanished, or changed side, and it never comes back. `spawned_ids` keeps everyone the group ever had. An emptied group stays in `AiDirector.groups`.
- **Orders only through `UnitOrders`.** The AI never enqueues a command. It calls `UnitOrders.move` and `UnitOrders.stop`, sets `Unit.surfaced` when an ambush springs, and ends errands (`Unit.clear_errand`). Melee, ranged, and movement carry the orders out as they do a player's. What the AI last sent each member (`ordered_x/z`, the objective, whether it was an attack-move) stays in `AiGroup`, parallel to `members`.
- **Seeing.** The AI sees every enemy on the map that isn't submerged (`Visibility.is_submerged`). It has no sight range, so a HUNT group marches at the nearest enemy anywhere and a Blightbag at the thickest knot anywhere. The reveal radius (`Visibility.seen_by`) is view-only, and the AI doesn't use it.
- **Think cadence.** `AiDirector.update` runs once a tick over the groups in creation order. It prunes each, and a group with members thinks every 15 ticks (0.5 s), staggered by its id: `(tick + id) % 15 == 0`. `think_now` plans at once instead.
  - `set_behavior` sets `think_now`. The triggers run first in the tick, so a SET_BEHAVIOR trigger becomes orders on its own tick, and an ambush springs on the exact tick its trigger fires.
  - An alert (`AiBehaviors.switch_to`) plans under the new behavior in the same call and spends the request.
  - A freshly spawned group doesn't ask for a plan. Its first think is on its staggered tick.
- **Free members.** Only a free member gets a new order (`AiOrders.is_free`): alive, not confused, not on an errand, no target, not standing to fight or shoot, no draw or wind-up under way, and not waiting on a path. `UnitOrders.move` drops fights, casts, and swings and replaces an errand's order, and a pending path solve would be thrown away. A busy member carries on and is sent once it is free.
  - Four things override that, on purpose: a retreat's first march, the GUARD leash recall, a STANDOFF member's dead-zone escape, and an ambush spring. The spring surfaces every living member, busy or not, but issues no orders itself: the behavior it switches to orders only free members.
  - A leg's retry is a forced march too, but it only happens once every member has finished and is free, so it overrides the already-sent filter, not anyone's fight.
  - Every order goes through `AiOrders.send`, which first ends the unit's errand (see Decisions).
- **Buckets.** `engage` and `march` order members in buckets: the members of one tactic and type standing in one pathing component (`AiOrders._bucket_key`, the one definition). Keys ascend, so ASSAULT buckets go first, then STANDOFF, then CLUSTER. Each bucket gets one `UnitOrders.move` and one ORDER event.
  - **Per type**, because `UnitOrders.move` caps a group at its slowest member's speed. A bucket of Rippers and Husks would march at a Husk's pace.
  - **Per component**, because a bucket's leader (its lowest id) picks the objective and every member must be able to walk to it. A member across the river from its leader would be sent at something it can never reach, stop on its own bank, and be sent again at every think.
- **Objectives (ASSAULT).** The leader picks among the candidates it can walk to or already reach in melee (`AiOrders.reachable`, so a Shieldman on the bank counts a Husk in the shallows beside it). `Targeting.pick` ranks them as melee does: a preferred role first (Rippers go for ranged and support), then the nearest body edge, then the lower id. The bucket attack-moves to the pick in one order. Ahead of that ranking come a threat to one of the group's casters (the bodyguard rule) and then a FLANK's focus.
- **Hysteresis and the A\* budget.** Every ordered member that can't walk straight to its goal (`Pathing.can_walk_straight`) queues an A* solve, and `UnitMovement` runs at most 6 a tick (Phase 2). At that rate 40 members take 7 ticks to get their paths, so an AI that re-ordered everyone at every think would keep them waiting on paths for up to half of each 15-tick interval. It orders sparingly:
  - one move per bucket, not per unit;
  - only members the plan changed for: the recorded goal or objective differs from the new one;
  - a member already sent after an objective is re-sent only if the objective has drifted from where the member was sent by more than a quarter of the member's distance to it (at least 4 m, `REORDER_MIN`), or if the member finished its order farther than its `acquire_radius` from the objective. Inside the acquire radius `MeleeCombat`'s own chase re-paths every metre of drift, so the AI doesn't;
  - never a member that is waiting on a path.

  Tests pin it: 4 grunts hunting two standing targets give fewer than 6 ORDER events in 600 ticks (2 when it landed, against 40 for one per think), and 4 grunts after a quarry that walks away give fewer than 20 (13 when it landed).
- **Legs.** A leg is one march to one goal (`AiBehaviors.leg`). PATROL, a FLANK's approach, and RETREAT all use it.
  - It starts with an ordinary march: free members go, and busy ones are picked up when they are free.
  - Once every member has finished, is free, and was last sent to the goal, the leg looks at where they ended up. If the centroid of the members that aren't STANDOFF is within 4 m (`LEG_ARRIVE_RADIUS`) of the goal, the leg ARRIVED. Slots spread about the goal, and units a slot can't hold settle near it, so the centroid is the test.
  - Otherwise one retry, a forced march for everyone (a WAYPOINT_FAILED event with value −1), then FAILED.
- **Events.** `AiEvent` kinds are SPAWNED, BEHAVIOR, ORDER, WAYPOINT_REACHED, WAYPOINT_FAILED, AMBUSH_SPRUNG, FLANK_WAYPOINT, STANDOFF, and RETREAT. `to_array()` is the form determinism logs compare. Events appended by `spawn_group` or `set_behavior` between ticks are cleared by the next step before anything reads them.

### Behaviors

| Behavior | What it does |
|---|---|
| IDLE | Nothing. The members hold where they stand and fight what comes adjacent |
| PATROL | Walks the waypoints one leg at a time, attack-moving, so it fights what it meets and walks on. LOOP wraps; PING_PONG turns round at either end. An enemy within `alert_radius` of any member (center to center) switches it to `on_alert`; into GUARD, it guards where it was alerted (below) |
| GUARD | Holds its anchor (the spawn point, a retreat point, or where a patrol was alerted) and engages enemies within `guard_radius` of it. Hurt from outside the radius, it switches to `on_alert`. See the leash and the provoked rule below |
| HUNT | Engages every enemy it can see |
| FLANK | Goes after the roles in `flank_roles`, round the end of any melee screening them. See below |
| AMBUSH | Lies still: a free member that has an order is told to hold where it stands. Switches to `on_alert` when disturbed: a visible enemy within `alert_radius` of any member, hit points lost since the last think (a blast reaches units under the water; a member dying counts), or any member fighting |
| RETREAT | Entered by the AI, once (`retreated`). See below |

- **AMBUSH springs through `set_behavior`.** A group leaving AMBUSH springs first (`AiDirector.spring`), so whatever ends the ambush, an alert or a trigger's SET_BEHAVIOR, brings the lurkers up. Every living member gets `Unit.surfaced`, and one AMBUSH_SPRUNG (at the centroid, with the member count) is reported before the BEHAVIOR event. A group with no living member reports nothing, and AMBUSH to AMBUSH doesn't spring.
- **GUARD's leash.** The radius is the spec's, or 10 m when it has none (a group the AI sent to guard).
  - Intruders are visible enemies within the radius of the anchor. With none, or none the group can get at, free members outside the radius attack-move back.
  - Busy members farther than 1.5 × the radius (`GUARD_LEASH_PERMILLE`) are recalled with a forced plain move to the anchor. A recalled member is left alone until its walk home ends, even while an intruder is still inside the radius: re-engaging at the edge picked the outside enemy up again and cycled.
  - STANDOFF members are exempt from the recall while there are intruders, and the bodyguard rule only counts threats within the leash of the anchor (see Decisions).
- **GUARD provoked.** A GUARD group whose hit points dropped since its last think (a member dying counts), with no intruder inside its radius at this think or at the one before, is being hit from outside the radius: archers, a Sapper's grenades, a Stormcaller's bolts, a fire. Holding the post would only let it bleed, so it switches to `on_alert` (`switch_to`), one way, like an ambush springing, and plans under it at once.
  - Not a group that has `retreated`: it fell back to hold that post, and holds it, bleeding or not.
  - Not when `on_alert` is GUARD: the group stays as it is, with no BEHAVIOR event.
  - **The think before must have had no intruder too.** `AiGroup.phase` is 1 when the last think saw intruders. Without that, an intruder that landed a blow and died between two thinks left the guard hurt with nobody inside, read as fire from outside, and sent it off its post: in a probe of one melee intruder against 1 to 4 guards, 40 of 144 fights ended that way. With it, none did.
  - Before this rule, Riverside's storm camp lost 4 Husks to Longbows 48 m away without giving an order.
- **The anchor after an alert.** A PATROL whose `on_alert` is GUARD makes its members' centroid the anchor before it switches, so it guards where it was alerted. It used to keep its spawn point and walk home first. A trigger's SET_BEHAVIOR GUARD leaves the anchor alone: the spawn point, or the retreat point of a group that has retreated.
- **RETREAT.** Before anything else, whatever the group is doing (an AMBUSH springs first), a group that has not retreated, whose spec sets a threshold, falls back if:
  - its hit points are below `retreat_below_permille` of what it spawned with, and
  - the enemies against it have more hit points between them than it has left (`AiBehaviors._threat`). Those are, each counted once:
    - every visible enemy within 20 m (`RETREAT_THREAT_RADIUS`, center to center) of any living member;
    - every living enemy, seen or not, whose melee target (`target_id`) or shot target (`shot_target_id`) is a living member, wherever it stands.

    A group losing to nothing in particular stands. The radius used to be measured from the group's centroid, with no shooters, so a group losing to archers, or reduced to its STANDOFF casters 36 m from the enemy, never retreated: the storm camp bled to 14 % with a threat of 0 at every think. A hidden enemy still doesn't count for standing near, only for fighting or shooting a member.

  The first think forces a plain move for every member to the retreat point, dropping the fights they are in. Then it is a leg. Whether it arrives or fails, the point becomes the anchor and the group guards it. `retreated` stays set, so it never retreats twice.
- **FLANK** (`AiFlank`, `FlankRoute`) has three phases, kept in `AiGroup.phase`:
  - **Plan.** The focus is the nearest visible enemy (to the group's centroid) whose role is in `flank_roles` and that the group's leader can walk to or reach. Once picked it is kept while it is alive, seen, of such a role, and any member, not only the leader, can walk to or reach it. With none, the group hunts that think.
    - The screen is the visible enemy melee units within 30 m of the focus, other than the focus. It blocks if one stands within 6 m (`CLEARANCE`) of the straight line from the group's centroid to the focus.
    - A group already in contact (as in the approach, below) strikes instead of planning. Not blocked: strike at once. Blocked: a route of two waypoints round the end of the screen, on the side that goes out less. Each waypoint is clamped onto the map, and a side is rejected only if a clamped waypoint lies outside the group's pathing component; then the other side is tried. If neither works: strike.
    - W1 is `SIDE_MARGIN` short of the screen's front and out past its end by `SIDE_MARGIN`. W2 is level with the focus and the same distance out. Each is a FLANK_WAYPOINT event.
  - **Approach.** One leg per waypoint with plain moves, so nothing on the way stops it to fight. It plans again if the focus moves more than 8 m from where it stood at planning, and strikes early on **contact**: any visible enemy within 3 m (edge to edge) of a member. Hit points lost don't count.
  - **Strike.** `engage` every visible enemy, the ASSAULT buckets going for the focus first. If the focus dies the group plans again.

### Tactics (`AiTactics`)
- **Bodyguard rule.** The threats to a group's casters are the visible enemies within 10 m of any living STANDOFF member. The ASSAULT buckets go for the one their leader ranks best before anything else. Inside GUARD only threats within the leash of the anchor count.
- **STANDOFF** (Stormcaller, Drifter) holds where it can shoot from, using `StandoffSpot`.
  - **A spot** is on the circle of `ai_standoff_permille` of its range about the target. Five are tried: straight back from the target along the line to the unit, then swung 22.5° and 45° either way. The first that passes wins:
    - it is on the map and in the unit's own pathing component, and farther from the unit than a move's arrival radius (`UnitMovement.ARRIVE_RADIUS`, 0.25 m): a move to a nearer one ends before it starts, so a unit that can't shoot from where it stands would be sent there at every think and never move (Phase 8: a Drifter on Old Mill's west cliff face, where 18 cm up the slope lifted its launch over the lip);
    - no visible enemy is within the dead zone there (minimum range + 2 m);
    - the target is in range from it, shortened uphill;
    - the line is clear. For a bolt that is the check `RangedCombat` makes before it casts (`Lightning.is_clear_from`, from the spot; `Lightning.is_clear` now calls it with the launch point, no behavior change). For other projectiles it is no friend within 1.5 m of the line, and (Phase 8) the check `RangedCombat` makes before it takes a target: `RangedCombat.clear_launch_from`, from the spot's launch point, the unit's own aim style then the other, the flight clear of the ground (a cliff's lip, a wall) and of friends' bodies, at the chest (the feet for a bouncing throw). `RangedCombat._aim` calls it with the unit's launch point, no behavior change. Before it, a Drifter at the foot of Old Mill's west cliff held a spot in range from which every arrow met the lip, and its wave never cleared.
  - **Each think, per member** (`AiTactics.standoff`):
    - An enemy inside its dead zone: it finds a spot and goes, busy or not, dropping a cast or a fight. With no spot it stays.
    - Otherwise a busy member is left alone.
    - Where it stands will do (`holds`): left alone. An attack-mover is stopped there so `RangedCombat` shoots. One walking a plain move is left to arrive.
    - Otherwise it is sent to a spot. With none it attack-moves at the objective, which `RangedCombat` halts in range, unless it already has a shot. It is re-sent only for a new objective or one that has drifted, not for having stopped.
  - **An attack march** (a PATROL leg, a GUARD's stray return) stops STANDOFF members 6 m short of the goal, on the line from the centroid of the members marched in that call, so they come up behind the rest. A leg judges arrival by the others.
    - **A plain move** (a retreat, a GUARD recall, a FLANK's approach legs) sends them to the goal itself. Nobody is fighting there to stand behind, and in a retreat the side the group came from is the enemy's: stopped short of the retreat point, the casters stood on the enemy side of it.
    - **The centroid is of the members marched,** not of the whole group. A member marched on its own (freed from a fight, recalled) would otherwise stop on whatever side the rest of the group stood, which can be through the goal from itself.
    - The goal itself too when that centroid is the goal, and for a group of nothing but STANDOFF units: with nobody in front the offset would leave its centroid beyond the arrival radius and fail every leg.
  - It tries only five spots, so a unit cornered against a map edge may have none. It ignores `ammo_left`, which no v1 STANDOFF type runs out of.
- **CLUSTER** (Blightbag) walks at the thickest knot (`ClusterFinder`) of the enemies it can walk to: the one with the most enemies within 5 m (itself included; ties go to the one nearer the Blightbag, then the lower id), at the mean position of that neighborhood. Beyond its `acquire_radius` it takes a plain move, so nothing on the way stops it, and is re-sent when the knot drifts more than 3 m or it stopped short. Within it, one attack-move: melee picks a body in the knot and the burst does the rest.

### Visibility (`surfaced`)
- **`Unit.surfaced`** is set on every living member of an ambush when it springs, and never reset. `Visibility.is_submerged` is now true only for a unit whose type hides in deep water, that has not surfaced, is not ATTACKING, and stands at depth 3+.
- A sprung ambusher stays visible and targetable in deep water for the rest of the mission: it has shown itself, and going back under doesn't un-show it. Otherwise a Husk that had sprung would be untargetable again until its first swing.
- `Visibility.seen_by` needed no change: a unit that isn't submerged is seen by everyone.

### RNG: none
- The AI and the triggers draw no random numbers. Nothing under `sim/ai` or `sim/missions` touches `world.rng`. What would be a coin flip is a rule: nearest, then lower id. Every sort ends in an id tie-break, and every loop runs in ascending unit id, group creation order, or sorted bucket keys.
- So no RNG draw-order table gains a row, and the tables above stand. A world with no mission plays out exactly as before; only its state hash differs (see Hash).
- **Why:** the AI's choices are then a function of sim state alone. A peer or a replay can recompute them from the state without sharing draws, and the draw-order tables stay valid.
- `make check-sim` enforces it: besides the global random calls it bans anywhere in `sim/`, it fails if any code line under `sim/ai` or `sim/missions` mentions `rng` (comment lines are ignored, as for its other checks).

### Hash
`state_hash()` gains, after the weather and before the terrain scars:
- **the director** (`AiDirector.hash_fields`): the next group id and the group count, then each group's fields.
  - Every `AiGroup` field except `spec`. The spec's index goes in instead: everything is hashed by index, never by name. Behavior, phase, `think_now`, spawn and anchor, the waypoint index and step, the leg, the focus, route and plan point, `start_hp`, `last_hp`, `retreated`, and the packed arrays (`spawned_ids`, `members`, the order records), each after its size.
  - It is hashed in every world, as two words when there are no groups. Hashes from before Phase 7 aren't comparable with later ones. No test pins an absolute hash.
- **the mission** (`MissionRuntime.hash_fields`, only with a mission): the tier, start tick, `started`, `seen_factions`, the objective's trigger and revision, the outcome and its tick, and `fired_tick` per trigger by index (Phase 8 appends the draw's bindings, the objective states and `seen_commanded`). The objective's text and the script aren't hashed.
- **on `Unit`:** `surfaced`, appended after `parts_taken`.

`ai_events` and `mission_events` are output only, like `combat_events`.

### View and HUD
- **`MissionHud`** (`view/hud/mission_hud.gd`) shows the objective at the top centre, below the stats label's two lines, and a large Victory (green) or Defeat (red) banner in the middle once the mission has an outcome. It is hidden in a world with no mission. `MainView` calls `show_world` after each step, a label is only touched when its text changes, and it takes no mouse input, so it can't block a click. The banner pauses nothing in the sandbox; a campaign mission freezes the view at the outcome (Phase 8).
- **`AiDebugView`** (`view/ai/ai_debug_view.gd`) is the F5 overlay (`InputBindings.TOGGLE_AI_DEBUG`). It was F7 until Phase 9's plan claimed F7 for the scoreboard; nothing else binds F5. It is hidden until toggled, redraws after every step while shown, and only reads the world. Its lines are floats in metres, which `view/` may use.
  - A camera-facing label over each group with living members, at the centroid: "name: BEHAVIOR", colored by behavior.
  - Lines 0.3 m above the ground, unshaded and drawn over everything, cut into 4 m pieces so they follow hills:
    - a PATROL's waypoints as a loop or a polyline, only while the group is PATROL;
    - a 32-segment circle for a GUARD's radius and for an AMBUSH's alert radius, around the anchor;
    - the part of a FLANK's route still to walk, and a line to its focus;
    - every AREA_ENTERED trigger's circle, gray until it fires and green after.
  - Tests cover the labels, the line counts, and that drawing leaves `state_hash()` unchanged. The colors and the rendering were checked in a window, not by a test.
- **`MainView`:**
  - `mission_path` (default `riverside_ai.tres`; empty starts none) is read in `_ready`, and the mission starts at tier 2 before the first step (the sandbox; Phase 8's `MainView.launch` plays a campaign mission instead). The Light test squad and the herb plants stay as tick-0 commands.
  - The Dark test squads and the weather schedule are gone. The groups spawn inside the first step, and the triggers bring the rain.
  - F6 and F9 still work. The stats line ends with "(F5 AI overlay, F6 weather)".

### The Riverside AI mission (`data/missions/riverside_ai.tres`)
Positions are meters on the Riverside map: the ford is at x = 300, shallow (depth 1) from z = 218 to 234, the Light squad starts on the north bank around (290, 185), and the ground south of z = 236 is dry.

| Group | Units | Behavior and place |
|---|---|---|
| `south_patrol` | 6 Husks | PATROL, looping a triangle on the south bank east of the ford; `alert_radius` 12 m; spawns at start |
| `ford_ambush` | 4, 5, 6, 7, 8 Husks by tier | AMBUSH at (284, 222), 17 m west of the ford; `alert_radius` 8 m; at start |
| `raiders` | 5 Rippers | FLANK, from (340, 272); spawned by the `raid` trigger |
| `storm` | 6 Husks, then 2 Stormcallers | GUARD at (250, 275), radius 25 m; retreats below 400 ‰ to (250, 305); at start |
| `bags` | 3 Blightbags | HUNT, from (270, 262); at start |
| `drifters` | 6 Drifters | PATROL, looping west of the ford; `alert_radius` 30 m; at start |

- **Triggers, in order:**
  - `start`: a TIMER of 0 sets the objective "Cross the creek and clear the south bank".
  - `ford`: a Light unit within 15 m of the middle of the ford sets "Hold the ford" and `ford_ambush` to HUNT, which springs it.
  - `raid`: a TIMER of 2700 (90 s) spawns `raiders`, ramps rain to 700 ‰ over 150 ticks (with a light wind, which only the view reads), and sets "Raiders on the flank".
  - `raid_over`: `raiders` cleared sets "Clear the south bank".
  - `win`: FACTION_ELIMINATED for Dark, `after` `raid`. Without the gate a straight assault won at tick 2539, before the raid at 2700, and skipped the raiders, the rain, and the last objective. Once the raid has fired the raiders are on the map, so `win` can't come before they are dead either.
  - `lose`: FACTION_ELIMINATED for Light.
- At tier 2 it spawns 29 Dark units at the start (18 Husks, 2 Stormcallers, 3 Blightbags, 6 Drifters) and 5 Rippers at 90 s.
- `test_riverside_ai_mission` checks that it validates against the shipped catalog; that every spawn point, waypoint, and retreat point is passable for its group's mobilities; that the ambush's whole ±3 m neighborhood is depth 3+, 12 to 20 m west of the ford; that every trigger area is on the map; that `ford` fires for a Light unit at the ford and not for one 40 m off; that the raid timer fires on tick 2700; and that `win` waits for the raid (every Dark unit killed at tick 1 gives no victory).

### Demo (`make demo-ai`)
- Seven captioned stages on Riverside, with F5 on throughout: a patrol, an ambush, a flank, a standoff, a cluster, a retreat, and a trigger-driven finale (objective text, a Dark line, reinforcements and rain, a Victory banner). `DEMO_SPEED=2` runs it faster, `DEMO_STAGE=3` runs one stage alone (group ids differ, so a solo stage can play slightly differently), and `DEMO_CAPTURE=<dir>` saves a screenshot at each result.
- **Light is driven by commands**, exactly like player input. **Dark is the AI:** stages 1 to 6 spawn each group with `AiDirector.spawn_group` and switch behavior with `set_behavior`, and the finale runs on the demo's own `MissionScript`, so its triggers are real.
- **Every wait counts sim ticks**, and each stage starts on a whole second of ticks. Wall-clock waits made the finale flip between Victory and Defeat with frame timing. Now two runs print identical result lines.
- **The mission seam.** `MainView.mission_path` is set to empty before the scene enters the tree, and the demo calls `World.start_mission` on the fresh world, between `MainView._ready` and the first step. The first version set `world.mission = null` to get rid of the game's mission, which pokes a world field the demo shouldn't touch.
- `MainView` still spawns the Light test squad at tick 0. The demo despawns it at tick 1, and each stage clears the one before, because every AI group scans the whole map: Blightbags would hunt the densest knot anywhere.
- **Stage 3 uses Wardens behind the line, not Longbows.** Three Longbows kill five Rippers on their 14 s walk round the line (see Not yet).

### Decisions
- **Tim chose** (plan approval):
  - A sprung ambusher surfaces for good (`Unit.surfaced`), instead of diving back under between fights.
  - Mission data is `.tres` resources, like units and weather, not code or JSON. The editor opens it and `validate()` checks it, and a new mission is data, not engine code, as CLAUDE.md asks.
- **In the approved plan:**
  - **The AI isn't in the command stream.** It runs inside `World.step()` as a function of sim state, so a lockstep peer or a replay recomputes the same orders from the same state, and only a human's commands have to cross the wire or be recorded. The cost: the AI's code and the mission data become part of what must match. Peers and replays need the same build, the same mission file, and the same tier. Triggers are the same, which is why SET_WEATHER calls `change_to()` instead of enqueuing a `SetWeatherCommand`.
  - **No RNG** (see above).
  - **Orders go out in buckets** of one tactic, type, and pathing component. The plan said by type. The component came from review of the first AI task, and the tactic with the tactics. See AI groups for why.
  - **Only free members get orders.** The overrides are a retreat, the GUARD leash, a STANDOFF member's dead-zone escape, and an ambush spring (which surfaces busy members but orders nobody). A leg's retry forces a march only once everyone is free.
  - **Triggers evaluate in two passes**, so no trigger's effects leak into another's condition on the same tick and the result doesn't depend on the order they are listed in. A trigger first checks one tick after its `after` fired, so a chain takes a tick a link and never zero. A defeat outranks a victory on the same tick. Nothing is evaluated after an outcome.
  - **Stormcaller 900 ‰, Drifter 850 ‰** (`ai_standoff_permille`), so a unit that stands back doesn't sit at the very edge of its reach, where one step of the target out of range would stop it shooting.
  - **Warden auto-heal and Ripper fetch priority are deferred.** A Warden still heals only when told (`HealCommand`), and a Ripper still scavenges on its own as in Phase 6 (nearest first, within 8 m). The AI doesn't cut an errand short for an ordinary order: a unit on one isn't free. The reasons recorded at plan approval:
    - Warden auto-heal is player-side: Wardens are Light, so it is a question of how the player's units behave, not of the enemy AI, and Old Mill is meant to teach healer management, which a Warden that heals on its own would take away.
    - Ripper fetch priority (what a Ripper chooses to pick up) was outside the Phase 7 prompt's scope, so Phase 6's nearest-first rule stays.
- **Rulings in the final fix wave** (from the whole-branch review), each with its reason:
  - **RETREAT counts enemies near any member and anyone fighting or shooting a member.** See RETREAT. The cost: a hidden enemy that has a member as its target counts, though the group can't see it. It is plainly fighting the group.
  - **GUARD hurt from outside its radius switches to `on_alert`,** unless it has retreated or `on_alert` is GUARD. See GUARD provoked. The ruling was the hit-point drop with no intruder now; the check that the think before had none either was added in the implementation, with a regression test, because the bare rule sent a guard that had just killed its intruder off hunting (40 of 144 probe fights). The cost: a guard standing in a brush fire, or hit by a blast it can't see the source of, also switches. In `make demo-ai` the finale's GUARD line is now provoked into HUNT about 15 s after it appears and charges the Light force (it used to stand and bleed), and stage 4's guard is provoked into HUNT partway through, after which its Stormcaller is no longer walked back to the post.
  - **STANDOFF members stop short only on attack marches,** measured from the members marched. See Tactics.
  - **A PATROL alerted into GUARD guards where it was alerted;** a trigger's SET_BEHAVIOR GUARD keeps the anchor. A trigger names a post on purpose (the spawn point, or the retreat point); an alert happens wherever the patrol was.
  - **`ai_standoff_permille` is capped at 950,** not given a tolerance in `holds`, so the range check stays the one `RangedCombat` makes.
  - **The AI overlay is F5,** not F7, which Phase 9's plan reserves for the scoreboard.
- **Rulings during the build,** each with its reason:
  - **FLANK's `SIDE_MARGIN` is 6 m, not the 4 m first specified.** A group walks the route with its center on the line, so its nearest member passes the end of the screen at the margin less two body radii and half the group's width. At 4 m that was about 2.5 m edge to edge for three raiders, inside the 3 m contact distance, so every flank was found out by the end unit of the screen it was rounding and cut the corner (a measured 83 mm from a screen unit). At 6 m, equal to `CLEARANCE`, a box of five Rippers keeps 3.8 m by the arithmetic.
  - **A FLANK strikes early on contact only, not when it loses hit points.** Archers always shoot a flank on its way round, so a group that broke off at the first arrow charged the screen it was rounding (demo stage 3). The cost: a flank under heavy fire takes the long way and may arrive weaker instead of charging. AMBUSH's hit-point spring and RETREAT are unchanged.
  - **A leg starts with an ordinary march, not a forced one.** Only retries and RETREAT force. That keeps the list of overrides honest. The cost: a member fighting when the leg starts lags its group.
  - **GUARD's leash and recall.** Each rule below came from a recall-and-engage cycle (one repro gave 55 ORDER events in 900 ticks):
    - a recalled member is left alone until its walk home ends, not only while it is outside the radius;
    - GUARD falls through to the stray return when `engage` reaches no intruder, so members aren't stranded outside the radius;
    - the bodyguard rule counts only threats within the leash of the anchor, so a caster standing far out gets no melee help.
  - **STANDOFF members are exempt from the leash while there are intruders.** A firing spot 28 to 36 m out is usually past the leash. Recalled, the caster dropped its cast, walked home, was engaged again, and walked out again. The cost: a caster may stand up to about its range beyond the guard zone during a fight. They come home through the stray return once no intruder is left.
  - **A STANDOFF member walking a plain move isn't stopped when its position would do.** Stopping it at once parks it at 40,000 mm, the very edge of its range, which defeats `ai_standoff_permille`, and an escaping caster stopped at the edge of its dead zone with the enemy a step behind.
  - **`AiOrders.send` ends the errand of every unit it orders, and `is_free` doesn't read `act_left` alone.** A forced move left a mid-pickup scavenger with `act_left > 0` and a dead errand. It was never free again, and a retreating group wedged in RETREAT. `act_left` only counts down during INTERACT, which `is_free` already excludes.
  - **An ambush's spot is a sample whose whole ±3 m neighborhood is depth 3+.** A single deep sample left a BOX of Husks partly in depth 1 to 2, visible, and shot by Longbows, so the ambush sprang before its trigger. Riverside ships (284, 222) m; the mission test asserts that its whole ±3 m neighborhood is depth 3+ and that it lies 12 to 20 m from the ford, not the coordinates themselves. (280, 221) m is `test_ai_determinism`'s own spot, which that test finds by scanning west from x = 280 m, not the shipped one.

### Behavior changes to earlier phases
- **A sprung ambusher stays surfaced.** Phase 3's targeting rule and Phase 5's `Visibility.is_submerged` each gained the exception, and both sections say so.
- **`MainView` no longer spawns the Dark test squads or enqueues the weather schedule.** The Riverside AI mission does both. F6 now lasts until the mission's next weather change, and F9 stays.
- **`Lightning.is_clear` calls the new `Lightning.is_clear_from`,** which takes the launch point as a parameter. No behavior change: the Phase 6 lightning tests pass unmodified.
- **Every world hashes the director,** so hash values from before Phase 7 aren't comparable.
- **The combat, projectile, and abilities demos turn the AI mission off.** They load `main.tscn`, which now starts the Riverside AI mission, and its 29 AI units hunted across every staged event. Each sets `MainView.mission_path` to empty before the scene enters the tree, as `demo-ai` does, and its finale spawns the Dark test squad its phase had, where MainView used to stand it (`demo` Husks and Rippers; `demo-projectiles` those and Drifters; `demo-abilities` the whole roster). `demo`'s finale took MainView's first 50 units, which assumed the Dark squads; it takes the Shieldmen and Reavers now. Headless at `DEMO_SPEED=30` their finales end Light 23/25 vs Dark 0/25, Light 34/37 vs Dark 0/31, and Light 8/37 vs Dark 0/36 (19/37 at 3×; see Phase 6's Measured).
- No earlier test changed: the 602 tests that existed when Phase 7 started pass unmodified.

### Measured (M4 Max, headless)

| Scenario | Result |
|---|---|
| `test_ai_determinism`: Riverside, shipped units, 10 Light against 17 Dark in four groups (a patrol, a Husk ambush, three Rippers on a flank that a timer spawns, a hunting column with a Stormcaller and a Blightbag), 1500 ticks, worlds on seed 7, seed 8, and seed 7 again | The two seed-7 worlds make identical AI and mission events on every tick and identical hashes every 100 ticks and at the end. Seed 8 first differs at tick 462. 0.73 to 1.15 ms/tick per world across runs, higher when the machine is busy (0.95 / 1.00 / 1.15 on the last); the file runs in about 5 s |
| Events in that run, seed 7 / seed 8 | 4 groups spawned; 29 / 28 ORDER; 3 WAYPOINT_REACHED; 1 AMBUSH_SPRUNG, on tick 319 from the `ford` trigger; 2 FLANK_WAYPOINT; 17 / 16 STANDOFF; 0 RETREAT. 3 triggers fired (flank timer tick 300, ford 319, rain 600). 14 / 16 units dead, and no outcome in 1500 ticks |
| A Stormcaller against a dummy 50 m off (`test_ai_targeting`) | Holds 36.2 m from it (900 ‰ of 40 m), first bolt on tick 258, 5 by tick 900 |
| The same caster with a slow walker closing | The walker gets within 9.5 m once, the caster escapes once and never spends a tick inside 8 m, and the walker is dead on tick 654 |
| A Blightbag with a decoy 14 m off and a knot of 5 about 33 m off | Bursts on tick 884, 2.7 m from the knot's center, after two orders; the decoy is untouched |
| 3 raiders flank a screen of 9 with two archers behind it | Route (30.2, 23.5) then (29.9, 33.7) m. They stay at least 2.6 m (edge to edge; 2.4 m for five raiders) from every screen unit until the first swing, which is at an archer on tick 633. Without the screen the first swing is on tick 421 |
| The shipped Riverside AI mission in `MainView`, tier 2, against the 37-unit Light test squad (final review) | The whole sim about 1.5 to 1.65 ms/tick. The AI's own orders never put more than 1 path on the A* queue; the player's attack-move of all 37 Light units peaks it at 31 |
| Test suite | 932 tests (602 before Phase 7; 906 before the final fix wave), 65 to 97 s depending on load |

`make demo-ai` prints these result lines, the same on every run (headless, at `DEMO_SPEED=30`):

| Stage | Result |
|---|---|
| 1 Patrol | 3 waypoints in 26 s. It spotted the Shieldmen 7 s after they set out and switched to HUNT. Shieldmen 3/4, Husks 0/5 |
| 2 Ambush | Sprang 6.9 s after the Shieldmen set out, as the first reached the ford; 6/6 Husks surfaced. Shieldmen 8/8, Husks 0/6 |
| 3 Flank | A 2-waypoint route round the line, struck 16 s after setting out: 37 swings at Wardens, 0 at Shieldmen. Wardens 0/3, Shieldmen 8/8, Rippers 5/5 |
| 4 Standoff | 2 bolts and 58 moves to a new firing spot. After 60 s the Stormcaller is alive, Husks 0/6, Reavers 5/6. (Before the final fix wave: 26 moves, dead after 43 s. Its group is now provoked into HUNT partway through, hit from outside its 45 m radius, so the stray return no longer walks the caster back to the post) |
| 5 Cluster | 3/3 Blightbags burst, the nearest 2.8 m from the knot's middle and 16.9 m from the straggler. 3 of the knot killed, 7 paralyzed, the straggler untouched |
| 6 Retreat | Fell back 12 s after the Shieldmen set out with 2/4 left and 45 % of their starting health, walked to the point 36 m from the post, and is guarding it. Shieldmen 10/10 |
| 7 Finale | Victory banner after 43 s. Rain and reinforcements came at 24 s. Light 20/20 standing, Dark 15/15 down. (Before the final fix wave: after 52 s, Light 15/20. The GUARD line, hit from outside its radius, is now provoked into HUNT and charges instead of standing to bleed) |

### Not yet
- **Balance was untuned** (done for the campaign in Phase 8). `make playtest` measured the three campaign missions and a balance pass tuned their data (see Playtest and balance). `riverside_ai.tres`, the Phase 7 test mission, was not retuned, so what was noted here still stands for it:
  - In a scripted run, 37 attack-moving Light units wore the Dark side down to 3 to 8 units by tick 2400.
  - The Blightbags walk at 1.1 m/s, so they take about 75 s to cross and start hunting well before the player arrives.
  - With GUARD provoked by fire, the shipped 20 Light units in the `demo-ai` finale win with all 20; the knife-edge sweep (16 lose, 18 win with 14 left, 22 with 20) hasn't been re-run.
  - Three Longbows kill all five Rippers on their way round (7 swings at the Longbows, none lost), which is why demo stage 3 uses Wardens.
- **A Stormcaller vs faster melee** re-spots at almost every think and rarely casts (demo stage 4: 58 moves to a new spot for 2 bolts in 60 s; 26 in 43 s before the final fix wave). A lone caster circling 36 m out from standing Reavers made 40 re-spots for 1 bolt in 60 s. A STANDOFF unit whose target never closes keeps looking for a spot instead of casting. Phase 8 didn't change this; its balance pass saw it once more (see Phase 8's Not yet).
- **`riverside_ai`'s objective can still go backwards.** `ford` fires the first time Light reaches the ford, which can be after `raid` has set "Raiders on the flank", and it overwrites that. Phase 8 left that file alone (it is the sandbox and test mission). The campaign missions use SHOW, COMPLETE and FAIL_OBJECTIVE, whose DONE and FAILED states are terminal, and keep SET_OBJECTIVE for hints, which can still overwrite each other.
- **The banner doesn't pause anything in the sandbox** (done for the campaign in Phase 8). After Victory or Defeat the triggers stop, but the sandbox world keeps stepping and input still works. A campaign mission freezes the view at the outcome tick and hands over to the results screen.
- **Warden auto-heal and Ripper fetch priority** (see Decisions).
- **Units don't path around fire,** the AI's included. It was Phase 7's in the Phase 5 notes and has moved to a later phase. A GUARD group burning with no intruder inside its radius reads the fire as an attack from outside and switches to `on_alert`.
- **Random wave selection** (done in Phase 8). Old Mill picks 4 of its 5 waves per seed; the roll lives in `World.roll_bindings`, which uses a generator of its own seeded from the world seed, so neither the AI nor a trigger draws dice and the draw-order tables stand.
- **The AI has no sight range.** It knows every enemy on the map that isn't submerged. A skirmish AI (Phase 9) may want fog.
- **STANDOFF** ignores ammo. (Its spot check for arrows was range and a friend corridor only, with no terrain; Phase 8 added the real flight, above.) With no spot at all, a member holding with an enemy in range (`AiTactics._has_shot`, range only, no line) stays where it is, shot or no shot: rarer now that a spot needs a real flight, but a unit penned where every spot fails could still wait for ever.
- **A FLANK's `SIDE_MARGIN`** is sized for a box of up to about ten members. A wider group needs a margin that scales with its width.
- **Conversion.** A converted unit leaves its group when it is pruned, but UNIT_DIES and GROUP_CLEARED still count it as standing. Decide that when the converter exists.

## Mission framework and campaign (Phase 8)
The game is a campaign now: Riverside, The Ford and Old Mill, played in order, the survivors carrying over, with menus, a briefing and a results screen, pause, and a balance pass measured by a bot:
- **A mission is data.** A `MissionDef` (map, roster, deploy point, briefing, camera, atmosphere) points at a `MissionScript` (Phase 7's groups and triggers, plus objectives and random wave draws). A new mission is a map generator, those two `.tres` files, an atmosphere and a line in `campaign.tres`: no engine change.
- **A campaign is data and a save.** A `CampaignDef` lists the missions. A `CampaignState` is one player's progress (each soldier's kills and wounds, the fallen, the mission index, the tier, a seed), and is saved as JSON.
- **The sim gained four things:** a `DeployCommand` (a roster with its history, applied at tick 0, in the replay stream), objectives with states, a random draw of waves rolled outside `world.rng`, and an ESCORT behavior for a Light unit the player doesn't command.
- **The view gained the rest:** the `App` shell and its screens, pause, a frozen end, the objective panel, and an `Atmosphere` per mission that darkens the campaign toward a hellscape.
- **Balance is measured:** `make playtest` plays the campaign headless through the real sim with two bots (see Playtest and balance).

**Files**

| File | Role |
|---|---|
| `sim/missions/mission_def.gd`, `roster_entry.gd`, `campaign_def.gd` | `MissionDef`, `RosterEntry`, `CampaignDef`: a mission, one roster line, the campaign |
| `sim/missions/objective_spec.gd`, `mission_draw.gd` | `ObjectiveSpec`, `MissionDraw`: what a `MissionScript` gained |
| `sim/missions/mission_runtime.gd`, `mission_script.gd`, `trigger_spec.gd`, `trigger_action.gd`, `mission_event.gd` | Phase 7's, extended: aliases, objectives, the new conditions and actions |
| `sim/missions/campaign_state.gd`, `soldier.gd`, `deploy_plan.gd` | `CampaignState` (progress, carryover, the save's dictionary), `Soldier`, `DeployPlan` (who fills which slot) |
| `sim/missions/mission_stats.gd`, `mission_setup.gd` | `MissionStats` (the results screen's numbers, an observer); `MissionSetup.create_world` (the one world builder) |
| `sim/commands/deploy_command.gd` | `DeployCommand`: a roster into the world at tick 0 |
| `sim/world.gd` | `spawn_block` (the formation layout), `roll_bindings` (the draw), `DRAW_SALT` |
| `sim/ai/ai_behaviors.gd`, `ai_group_spec.gd`, `ai_director.gd` | ESCORT; `AiDirector.controls` |
| `data/units/villager.tres` | The Ford's villager, catalog index 10 |
| `data/campaign/campaign.tres`, `data/missions/<id>/mission.tres` and `rules.tres`, `data/atmospheres/<id>.tres` | The campaign's data, for `riverside`, `the_ford` and `old_mill` |
| `view/atmosphere/atmosphere.gd`, `atmosphere_view.gd` | `Atmosphere` (data), `AtmosphereView` (applies it) |
| `view/mission_launch.gd`, `view/main.gd` | `MissionLaunch`; `MainView.launch`, pause, freeze |
| `view/hud/pause_menu.gd`, `objective_panel.gd` | `PauseMenu`, `ObjectivePanel` |
| `view/app/*` | `App` (`app.tscn` is the main scene), `MainMenu`, `CampaignMenu`, `Briefing`, `Results`, `CampaignComplete`, `ConfirmDialog`, `MenuScreen`, `MenuKit` |
| `view/campaign/campaign_store.gd`, `view/settings/settings.gd`, `settings_menu.gd` | The save file, the player's settings |
| `scripts/mapgen/map_builder.gd`, `scripts/gen_<map>.gd` | `MapBuilder` and the three map generators |
| `scripts/playtest.gd`, `scripts/playtest/*` | `make playtest`: `PlaytestPilot`, `PlaytestRoutes`, `PlaytestRunner`, `PlaytestResult`, `PlaytestReport` |
| `scripts/capture_missions.gd` | `make capture`: windowed screenshots of each mission |

### Tick order
Phase 7's list stands; nothing was added to it. What changed inside it:
- **Step 1, commands:** a `DeployCommand` applies at tick 0. `MissionSetup` enqueues it first, then a `SpawnHerbPlantCommand` per map plant, then calls `start_mission`, so entity ids run as MainView's test squad did: soldiers, then herbs, then the starting groups' units (a test pins it).
- **Step 2, `MissionRuntime.update`:** group names in conditions and actions go through the draw's bindings; two conditions and three actions are new; objectives change state here.
- **Step 3, `AiDirector.update`:** ESCORT is one more behavior. `AiDirector.controls(id)` is true for any unit a group ever spawned.
- **Outside the tick:** pause and the freeze at an outcome are the view declining to call `step()`. The sim never hears of either.

### Data (the mission format)
All of it is `.tres` `Resource`s with a `validate()` that lists every problem, like Phase 7's. Defaults that aren't zero are deliberate and documented.

| Resource | Fields |
|---|---|
| `MissionDef` (`mission.tres`) | `id`, `display_name`, `briefing`; `map: MapInfo`; `rules: MissionScript`; `roster: Array[RosterEntry]` (melee entries first: the squad deploys front to back in list order). Deploy: `deploy` (x, z in milli-units), `deploy_facing_x/z` (default 0, 1: south), `deploy_formation` (default BOX). A View group: `camera_start`, `camera_distance` (default 75 m), `atmosphere: Atmosphere` (null is the view's default look). Nothing that steps a world reads the View group; `UnitType.placeholder_color` is the precedent |
| `RosterEntry` | `type_id`, `counts` (1 or 5 entries, by tier, as everywhere), `carryover` (default true: a veteran may fill the slot; false: always a recruit) |
| `CampaignDef` (`campaign.tres`) | `missions` in play order, `soldier_names` (64 original given names; at least 50) |
| `ObjectiveSpec` | `name`, `text`, `optional` (winning doesn't need it; the panel says so), `shown_at_start` (default true; false stays hidden until a SHOW_OBJECTIVE) |
| `MissionDraw` | `slots` (aliases such as `wave1` to `wave4`), `pool` (group names), `ordered` (sort the picks by pool position, so waves escalate) |

`MissionScript` gains `objectives` and `draws`. Everything below is appended, because these enums are hashed or saved:
- **`TriggerSpec.Condition`:** `TRIGGERS_FIRED` (5), `PLAYER_ELIMINATED` (6).
- **`TriggerAction.Kind`:** `SHOW_OBJECTIVE` (6), `COMPLETE_OBJECTIVE` (7), `FAIL_OBJECTIVE` (8), with a new `objective` field. `SET_OBJECTIVE` is unchanged: it is the message line at the top of the screen, which the tutorial hints use.
- **`AiGroupSpec.Behavior`:** `ESCORT` (7), with `escort_radius`. **`AiEvent.Kind`:** `ESCORT_WAIT`, `ESCORT_GO`. **`MissionEvent.Kind`:** `OBJECTIVE_STATE` (its `objective` is the objective's index, `value` the new state; `to_array()` is `[kind, trigger_index, objective, value]` for that kind only).
- **`AREA_ENTERED`** honors `names` when set: only the units of those groups count ("the villager reaches the gate"). It is empty in every Phase 7 trigger, so nothing there changes.

| Condition | Holds when |
|---|---|
| TRIGGERS_FIRED | `min_count` of the triggers in `names` fired on an earlier tick (`0 <= fired_tick < tick`), so "the next wave when the last is cleared plus 25 s, or 150 s after it spawned" can never spawn twice |
| PLAYER_ELIMINATED | `faction` (default LIGHT) has had a unit the AI doesn't control and has none living now. FACTION_ELIMINATED can't be the Light loss: it never fires while The Ford's Light villager lives |

- **Objectives** have four states, `HIDDEN`, `ACTIVE`, `DONE`, `FAILED`. SHOW moves HIDDEN to ACTIVE only. COMPLETE and FAIL work from HIDDEN or ACTIVE. DONE and FAILED are terminal, so a trigger can't take a win back, and nothing is reported for a change that doesn't happen. Every real change emits `OBJECTIVE_STATE`.
- **Weather is triggers.** TIMER plus SET_WEATHER already gives per-tier timing and `after` gating, and the starting weather is a TIMER of 0. A third weather path would have added state for nothing.
- **Validation, for the script** (fails at load, every problem listed):
  - Draws: aliases are unique and don't collide with a group name. Pool groups exist, are unique across all draws, and don't `spawn_at_start`. A draw has at least one slot and no more slots than pool entries.
  - **No trigger may name a pool group directly**, only through an alias: an undrawn group would never be cleared, a soft lock. A SET_BEHAVIOR on an alias is checked against every pool group of its draw.
  - Aliases are accepted wherever a group name is (UNIT_DIES, GROUP_CLEARED, AREA_ENTERED names, SPAWN_GROUP, SET_BEHAVIOR).
  - TRIGGERS_FIRED names resolve to triggers, with no self-reference or duplicates and `1 <= min_count <= names.size()`.
  - Objective names are unique and every objective action names one that exists.
  - ESCORT needs at least one waypoint, `escort_radius > 0` and `retreat_below_permille == 0`.
- **Validation, for `MissionDef`:** id and name; map and rules present, and `rules.validate(catalog)` clean (each problem prefixed `rules:`); one non-negative `deploy` pair and one `camera_start` pair; `camera_distance > 0`; a valid formation; every roster entry a Light unit that exists, valid `counts`, none negative, and at least one soldier at every tier. **A roster type must be a combatant** (`melee_damage` above 0, or a ranged projectile, or a special ability): the villager is the only type that isn't, and a data-free rule is easier to keep true than a name check.
- **`CampaignDef`:** at least one mission, no duplicate ids, each mission's problems prefixed `mission <id>:`, at least 50 names, none empty or repeated.

### Writing a mission (no engine change)
1. **The map.** Write `scripts/gen_<map>.gd` on `MapBuilder` (see Maps), run `make maps` (it picks the script up by name), commit the PNGs, their keep-importer files and the `MapInfo`.
2. **The rules**, `data/missions/<id>/rules.tres`: groups, triggers, objectives, draws. Hand-written with `;` comments and a legend of the enum values it uses (the editor drops comments if it re-saves a file). Every mission wants a PLAYER_ELIMINATED LOSE and a WIN; the tutorial hints are SET_OBJECTIVE messages.
3. **The mission**, `data/missions/<id>/mission.tres`: roster by tier, deploy, camera, briefing; and `data/atmospheres/<id>.tres`.
4. **The campaign:** add the mission to `campaign.tres`. `MissionSetup`, the App, the briefing and results need nothing else.
5. **Tests**, on the pattern of `tests/sim/test_campaign_missions.gd`: the data validates against the shipped catalog; every spawn, waypoint and deploy point is passable for its group and in the right component; coordinates that come from the generator are read back from `get_script_constant_map()` and must match within 0.5 m; a fixpoint over the trigger graph proves every trigger, and so the win, can fire at every tier; a scripted player wins and each loss condition fires; two worlds built the way a campaign builds them hash alike.
6. **Balance:** `make playtest` needs a route for the mission in `scripts/playtest/routes.gd` (an unknown mission's route is its deploy point, so the pilots would stand still), then the data is tuned from the tables.

### Runtime (sim)
- **Draws.** `World.start_mission` fills the draws with `World.roll_bindings(script, rng_seed)`: a flat `PackedInt32Array` with, per draw in script order, one group index per slot. A partial Fisher-Yates picks `slots.size()` distinct pool entries, and `ordered` sorts the picks by pool position. `MissionRuntime.bindings` holds the result and `_init` resolves every trigger's `names` and every action's target once, so `_cleared`, `_groups_named`, `_units_inside` and `_apply` see group indices only. A pool group that wasn't drawn never spawns and nothing can name it.
- **ESCORT** (`AiBehaviors._escort`, `AiGroup.phase` 0 walking, 1 waiting, 2 arrived): the group walks its waypoints with plain-move legs, so nothing on the way stops it to fight.
  - A friend is a living Light unit the AI doesn't control, within reach of any one member. Walking, the group holds up when no friend is within `escort_radius + 2 m` or a visible enemy is within `alert_radius` (0 means enemies never hold it up). Waiting, it resumes only when a friend is within `escort_radius` and no visible enemy is within `alert_radius + 2 m`. The 2 m is hysteresis, so the edge of a radius doesn't flicker it.
  - Holding up stops each member, records its order at its own position, and drops the leg, so the resume starts a fresh leg with its own retry. `ESCORT_WAIT` (at the members' centroid) and `ESCORT_GO` (at the waypoint) are reported. The group reacts at its next think, up to half a second later.
  - **A failed leg never advances**, so the villager can't skip the ford; an unreachable waypoint repeats its failure forever, which is why the tests put every waypoint in the villager's component. It never retreats, even if a trigger switches a group with a threshold to ESCORT.
- **The villager** is `data/units/villager.tres` at catalog index 10, appended so no earlier index or hash moves: Light, living, 60 hp, 2.2 m/s (slower than a Ripper, faster than a Sapper's 2.0), `melee_damage` 0, role SUPPORT. It never acquires a target or swings, but enemies still target it, and SUPPORT puts it among a Ripper pack's `flank_roles` by default, which is the escort's tension.
- **`DeployCommand`** carries parallel arrays (`type_ids`, `soldier_ids`, `kills`, `hp`), the deploy point, facing and formation. It skips unknown types, clamps `hp` to 1 to max (0 or less means full), keeps `kills` at 0 or more, and does nothing but `push_error` on arrays of different lengths. The layout is `World.spawn_block(type_indices, faction, x, z, fx, fz, formation)`, which `AiDirector.spawn_group` now uses too, so the two can't drift: spacing from the largest body radius, `Formations.slots`, one unit per slot in list order.
- **`Unit.soldier_id`** (0 for everyone the AI spawns) ties a unit to its `Soldier` record. `MissionStats`, `CampaignState.apply_victory` and the results screen find a soldier's unit through it.
- **`MissionStats`** is an observer, not state, and is not hashed. Whatever drives the world calls `begin` after the first step (the deploy applies on it), `observe` after every step (events are cleared at the start of each), `finish` at the end. It gives each soldier's kills this mission (end minus deploy), the soldiers lost (dead, or no longer Light), friendly-fire deaths (a KILL whose attacker was on the victim's side, himself included, or whose death was credited to no one), the enemy dead by type, and the end tick.
- **`MissionSetup.create_world(mission, tier, world_seed, deploy, catalog)`** is the one world builder: the App and the playtest use it, so a playtest seed is a game seed. It returns null after a `push_error` for a null input, a map that won't load, or a script that doesn't validate.

### RNG: one exception
- `World.roll_bindings` draws from a generator **of its own**, seeded with `rng_seed ^ DRAW_SALT` (an arbitrary constant, the xorshift* multiplier; changing it re-rolls every mission's draw, so it is part of the save format). It never touches `world.rng`.
- **Why:** a mission with draws then consumes the same world random numbers as one without, so the RNG draw-order tables in the earlier phases stay valid, tuning a pool doesn't reshuffle combat dice, and a test can predict the picks without building a world.
- **Why it lives in `world.gd`:** `make check-sim` bans anything mentioning `rng` under `sim/ai` and `sim/missions`, and the exception is kept honest by living outside them. Every other draw-order table is unchanged and no row was added.

### Hash
`state_hash()` gains:
- **on `Unit`:** `soldier_id`, appended after `surfaced`;
- **the mission** (`MissionRuntime.hash_fields`): after Phase 7's fields, the bindings (size first), the objective states (size first), and `seen_commanded`. Objective text isn't hashed, as before.
- **Not hashed:** `AiDirector`'s controlled-unit set (derived from the hashed `spawned_ids`), `MissionStats`, anything in the view.

Hashes from before Phase 8 aren't comparable with later ones. The replay a lockstep peer needs is the map, the mission file, the tier, the world seed, the `DeployCommand` at tick 0 and the player's commands after it.

### Carryover and the save (`CampaignState`)
- **State:** `Soldier`s (`id`, `type_id`, `name`, `kills`, `hp`, `missions`, `fallen_in`) in `soldiers` (alive, the reserve included) and `fallen`; `next_soldier_id`; `tier`; `campaign_seed`; `mission_index`; and `history` (per mission: id, ticks, enemy kills, losses). A soldier keeps only kills and hp. Special charges, herbs and ammo are not his: they refill every mission, and wounds carry over (CLAUDE.md: no healing between missions). `hp` 0 means full health, so a later retune of a type's `max_hp` can't leave a whole soldier "wounded"; read it through `Soldier.current_hp(max_hp)`.
- **`plan_deploy(mission, benched, names) -> DeployPlan`** changes nothing. For each roster entry, in order, and each slot the tier's `counts` give: a `carryover` slot takes the best available soldier of that type (not benched, not placed): most kills, then most health (full above any wound), then lowest id. Any slot left is a recruit with a provisional id (`next_soldier_id`, +1, ...) and the next name from `soldier_names` (`name_for`: `names[(id - 1) % n]`, then " II", " III" and so on on later laps). Everyone else, the benched and the surplus included, is the reserve (`reserve_for`).
- **`DeployPlan.command(0, mission)`** builds the `DeployCommand`. `apply_victory` must get the plan from the same `plan_deploy` call that built the world.
- **`apply_victory(mission, plan, world, stats)`** commits a win. It refuses, with a `push_error` and the state untouched, a plan for another mission, one made at an earlier mission index (the shape an already applied plan has), one whose recruit ids are no longer next, or one that names a veteran no longer on the roll. Otherwise: recruits join (a recruit who died is committed and falls like anyone, so his id is spent); a deployed soldier alive and still Light keeps his kills and wounds and `missions` goes up; one dead or no longer Light (conversion isn't in the sim yet, but the rule is coded and tested) moves to `fallen` with `fallen_in`, keeping his kills; the history gets an entry; the index moves on.
- **A defeat applies nothing.** The state in memory is the pre-mission state, so a retry has the same plan and the same seed, and so the same waves.
- **`mission_seed(index)`** is a non-negative 63-bit mix of the campaign seed and the mission index, independent of the tier. It is a chain of the repo's 32-bit mix over the seed's two halves, not splitmix64, which GDScript can't write (its constants don't fit an `int` literal and `>>` sign-extends); six values are pinned, cross-checked against Python.
- **Save format:** `to_dict` / `from_dict`, `VERSION` 1. The seed is a decimal string, because JSON numbers are doubles and a 63-bit seed would round; every number is `int()`'d on read. `from_dict(d, error_out)` returns null and puts one message in `error_out` for anything wrong: not a dictionary, another version, a missing key, a wrong shape or range, a malformed soldier or history entry, an id used twice, or an id at or past `next_soldier_id`. It shares nothing with `d`, writes no file and calls no `push_error`: a damaged save is a user case, not a programmer error.

### The mission screen
- **`MissionLaunch`** (`view/mission_launch.gd`) is what `MainView` needs for one mission: the `MissionDef`, tier, world seed, the tick-0 `DeployCommand`, and `campaign_mode`. Set `MainView.launch` before the scene enters the tree. With no launch `MainView` is the sandbox of earlier phases (test squad, `riverside_ai`, the debug keys, never freezing), and the demos rely on that.
- **With a launch:** the world comes from `MissionSetup.create_world`, the camera from `camera_start` / `camera_distance`, no test squads or extra herbs. `MissionStats` wraps the stepping: `begin` after the first step, `observe` after every step, `finish` at the end. In campaign mode the debug keys (F9 side switch, F8 status, F6 weather) do nothing and the bar's Switch side is hidden; F5 stays. F6 also does nothing while paused, since it would queue a command for the resume.
- **Freeze:** once `world.mission.outcome` is not `NONE` after a step, the view stops stepping (the sim's last tick is the outcome tick), calls `stats.finish`, and keeps drawing with the banner up. The pause menu is switched off with it (`PauseMenu.enabled`: `open()` refuses, so Esc and the bar's Menu button, which is also disabled, can't open a menu with Restart and Quit on it). After `end_delay` real seconds (2.5, public so a test sets it to 0) it emits `mission_ended(outcome, stats)` once.
- **Pause is view-only:** `paused` makes `_physics_process` skip `world.step()`, so the sim never hears of it and a paused-then-resumed world hashes the same as one that wasn't. While paused `SelectionController` refuses to enqueue or arm anything, the bar's order buttons are disabled, and `UnitsView` / `ProjectilesView` hold their sprites at the latest tick (`frozen`), because the physics fraction would otherwise swing them between the last two ticks. Esc (or the bar's Menu button, for a mouse alone) opens `PauseMenu` (`view/hud/pause_menu.gd`), P pauses without it, and a campaign mission pauses when the window loses focus (not undone by regaining it).
- **Esc order:** later nodes get `_unhandled_input` first, so `PauseMenu` sits before `Selection` under `Hud`: the controller consumes Esc while an order is armed and otherwise lets it through. Tree order is also draw and click order, so the menu's screens live on a `CanvasLayer` above the HUD's: a `z_index` draws over the control bar but a click still lands on it (checked in a window).
- **Selection gate:** `SelectionController._selectable` rejects a Light unit that `world.ai.controls(id)`, so the Ford's Light villager can't be selected, and the bar's Light count leaves such units out. Only Light: in the sandbox every Dark unit is the AI's, and F9 must still let the mouse command them.
- **Objectives:** `ObjectivePanel` lists the objectives that aren't `HIDDEN` (○ active, ✓ done, ✗ failed, "(optional)") top right, below the message line, rebuilt only after an `OBJECTIVE_STATE` event. `MissionHud` keeps the SET_OBJECTIVE message line and the banner.
- **Edge scroll:** `RtsCamera.edge_scroll` (off by default) pans when the mouse is within 12 px of a window edge, except while the mouse is over a button (so reaching for the control bar's buttons doesn't drag the map) and while it is outside the window. The control bar keeps 12 px of padding under its last row, so the bottom edge strip is bar background, not a button, and still scrolls.
- **AI overlay:** F5 now draws an ESCORT group's remaining route, in its own color.
- **Atmosphere:** `AtmosphereView.apply` runs after the views it grades exist (below).

### Atmosphere (the hellscape arc)
- **Decision (Tim):** the campaign darkens toward a hellscape, mission by mission, from data. Each mission's `Atmosphere` grades sky, light, fog and ground further than the last (CLAUDE.md, Core rules). Old Mill sits at roughly 70% of the arc, so later missions have headroom: its ash and desaturation are well under 1. The maps escalate too (The Ford has more sand, rock and dead brush than Riverside), and the briefings carry the corruption in original prose.
- **`Atmosphere`** (`view/atmosphere/atmosphere.gd`, a `Resource` with no Nodes; the `MissionDef` View group holds one): `background_color`; ambient (`ambient_color`, `ambient_energy`); the sun (`sun_color`, `sun_energy`, `sun_pitch_degrees`, `sun_yaw_degrees`, where pitch is the light's `rotation_degrees.x`, so -90 is straight down and 0 along the ground, and `validate()` wants -90 to 0); exponential depth fog (`fog_enabled`, `fog_color`, `fog_density`); the terrain grade (`terrain_tint`, `terrain_desaturation`, `ground_recolor`, one colour per `Terrain.Ground` or none, and `water_tint`); and view-only ash (`ash_fall`, `ash_color`). The defaults are `main.tscn`'s own look, so `apply(Atmosphere.new())` restores it, and a null atmosphere does nothing. `validate()` lists every out-of-range value.
- **Atmosphere:** `AtmosphereView.apply(Atmosphere)` sets the `WorldEnvironment` (background, ambient, exponential depth fog), the sun (color, energy, pitch and yaw as `rotation_degrees`), `TerrainView.set_grade` (shader uniforms `grade_tint`, `grade_desaturation`, `ground_recolor[5]`, `water_grade`, plus a once-written `ground_kind` texture so the shader knows each sample's ground type) and `PrecipitationView.set_ash` (a third, view-only layer made only when there is ash). The grade applies to the ground after its height color, ground tint, and recolor, and before blocked samples, fire, wetness, and snow; every uniform defaults to "no change", so the sandbox renders as before (a pixel comparison of the sandbox against the previous commit showed only the run-to-run noise). `main.tscn`'s Environment is `resource_local_to_scene`, so one mission's look never leaks into the next scene.

| | Riverside (about 10%) | The Ford (about 40%) | Old Mill (about 70%) |
|---|---|---|---|
| Sky | (0.56, 0.62, 0.66) | (0.46, 0.50, 0.46) | (0.42, 0.20, 0.10) |
| Ambient | (0.78, 0.76, 0.74) x 0.50 | (0.62, 0.66, 0.62) x 0.55 | (0.58, 0.45, 0.38) x 0.48 |
| Sun | (1, 0.96, 0.86) x 1.00 at -26 degrees | (0.82, 0.86, 0.80) x 0.60 at -50 degrees | (1, 0.62, 0.36) x 1.25 at -35 degrees |
| Fog | (0.74, 0.72, 0.66), 0.0025 | (0.55, 0.60, 0.55), 0.0035 | (0.37, 0.19, 0.11), 0.0042 |
| Ground | tint (1, 0.98, 0.93) | tint (0.92, 0.95, 0.88), desaturation 0.35, dead-grass recolour on all five grounds | tint (0.95, 0.86, 0.78), desaturation 0.42, scorched recolour on all five |
| Water | as the scene | murky, alpha 0.55 | near-black, alpha 0.85 |
| Ash | none | none | 0.6 |

- **Tuned by eye** (GL Compatibility on Metal, 1152x648). Godot's fog takes `1 - e^(-density * distance)` of the view, so the first-guess densities hid the map: 0.014 at Old Mill was two thirds fog at the camera's 75 m and the plateau vanished. They are now 0.0025, 0.0035 and 0.0042.
- **Old Mill was lifted in the balance pass** because it read as one red-brown at the default zoom. Before to after: ambient energy 0.32 to 0.48 (still under Riverside's 0.5) and its colour (0.45, 0.28, 0.22) to (0.58, 0.45, 0.38); sun energy 0.75 to 1.25, pitch -12 to -35 degrees (so the plateau's top is lit and its cliff in shade) and colour (1, 0.55, 0.25) to (1, 0.62, 0.36); fog 0.005 to 0.0042 and colour (0.38, 0.18, 0.10) to (0.37, 0.19, 0.11); terrain tint (0.85, 0.65, 0.55) to (0.95, 0.86, 0.78) and desaturation 0.55 to 0.42; and the grass scorched brown (alpha 0.6 to 0.3) rather than near-black, so the burned brush fields stand out from the lanes. **The ember sky, the near-black water and the ash (0.6) are as they were.** The change log in `docs/phase8-playtest.md` has every value.
- **Ash is view-only:** `PrecipitationView.set_ash` makes a third snow-style layer, never the sim's snow, so fizzle odds are untouched. Depth fog is supported by the Compatibility renderer, volumetric fog is not; the Web export needs a check (Not yet).

### The front end
- **`App`** (`view/app/app.tscn`, `run/main_scene`) holds one screen at a time (`show_screen`) and walks the campaign: `MainMenu` -> `CampaignMenu` -> `Briefing` -> the mission (`res://view/main.tscn` with a `MissionLaunch`) -> `Results` -> the next `Briefing`, or `CampaignComplete` after the last mission. The four demo scripts load `main.tscn` directly and never see it. Screens are code-built Controls on `MenuScreen` (a full-window backdrop, Esc = Back through `InputBindings.CANCEL`, keyboard focus on the first button), styled by `MenuKit` (the HUD's cream and the pause menu's panel; placeholder). A screen only shows what it was given and signals; the `App` decides what happens next, so each can be built alone from a fixture.
- **What the App owns:** `state` (the `CampaignState` in play), the `DeployPlan` the current mission was built from, and who is benched. A new campaign's seed comes from the view's own `RandomNumberGenerator` (`App.rng`), 63 bits, never negative. Everything that changes the campaign goes through the App:
  - **New Campaign** makes the state and saves it (autosave one).
  - **A mission is built from the state exactly:** seed `state.mission_seed(state.mission_index)`, deploy `plan.command(0, mission)`, tier `state.tier`, `campaign_mode` on, edge scroll from the settings.
  - **A victory is applied the moment Results appears** (`App.show_results`, after the screen is built from the state as it stood before), with the very plan that built the deploy, then saved (autosave two), so closing the window on the Results screen loses nothing. Continue and Main menu then only navigate. The result is dropped once applied, so a second Continue applies nothing. A defeat is never applied.
  - **Retry** drops the result, reloads `campaign.json` (the state before the mission), and shows that mission's briefing again with the same soldiers benched, so the player can re-bench or just press Start. The seed is the same, so the waves come the same. The file is trusted only if it is the same campaign at the same point (seed, tier, mission index): a failed autosave, which the App carries on after, can leave it a victory behind or another campaign's, and then the unchanged state in memory (a mission never changes it) is written back and used, as it is when the file is gone or unreadable. The pause menu's **Restart mission** skips the briefing: it asks first ("Restart this mission?"), then builds a fresh `MainView` from the same plan and seed.
- **`MainView`'s signals:** `mission_ended` -> `Results` (the world and stats are read before the scene is freed); `restart_requested` -> the question, then a fresh mission; `settings_requested` -> the Settings overlay; `quit_requested` -> the main menu (the pause menu already asked), saving nothing; `build_failed` (the mission's world couldn't be built: a missing map, rules that refuse; sent deferred from `_ready`) -> the main menu with a notice, the campaign untouched. The mission screen also holds the camera's edge scroll off whenever the pause menu is open (its dim layer is a `ColorRect`, not a button, so the camera's over-a-button check doesn't see it), and a pause without the menu (P, or the window losing focus) shows "Paused (P to resume)".
- **Overlays** (Settings, the Restart question) live on a `CanvasLayer` at layer 20, above the pause menu's 10, so a click can't reach what is under them (a `z_index` would not stop it; see the mission screen). While one is up over a mission the `App` switches the pause menu off (its Esc would close it behind the overlay) and edge scroll off (the camera would pan behind a dim layer), and puts both back when it closes, with the keyboard where it was. Changing the screen closes any overlay. An overlay sits after the screen in the tree, so it sees Esc first.
- **`CampaignStore`** (`view/campaign/campaign_store.gd`) is the only code that knows the save is a file: `user://campaign.json` (path injectable), JSON of `CampaignState.to_dict()`.
  - `save` writes `campaign.json.tmp` and renames it over the save, so a failed write leaves the old save intact; a stale `.tmp` is never read.
  - `load` returns null with `last_error` on a missing, empty, damaged, other-version, or out-of-range file (whatever `CampaignState.from_dict` says).
  - A save that can't be written is told to the player (a notice line) and the campaign goes on.
- **`CampaignMenu`:** Continue is on only for a save that loads and fits this campaign, and names the next mission and difficulty ("Campaign complete" for a finished one, which shows its roll). A file that is there but unusable says why. New Campaign opens the five tiers as a radio row (Easy, Moderate, Normal, Hard, Brutal; Normal, tier 2, chosen) and asks before replacing any existing file, readable or not.
- **`Briefing`:** the mission's text, the objectives that `shown_at_start`, the roster slot by slot from `plan_deploy` (veteran: name, type, kills, accuracy / attack-rate / speed bonuses as a percentage from `Veterancy.bonus_permille` and the type's caps, hp / max, wounded in amber; or "Recruit"), a Bench checkbox on every fielded veteran that plans again, and the reserve (a benched veteran waits there with his box still ticked). Nothing is committed by planning.
- **`Results`:** Victory / Defeat, time, enemies killed by type, Light losses and friendly-fire deaths by name, each objective's final state (hidden ones left out), and a table of every soldier who deployed (kills this mission, total, bonuses, hp, status Survived / Fallen / Recruit). It is built from `MissionStats`, the finished world and the plan alone.
- **`GameSettings`** (`view/settings/settings.gd`): static helpers over a `ConfigFile` (`user://settings.cfg`, path injectable), `[display] fullscreen` and `[controls] edge_scroll`, both off by default. Damaged files and wrongly typed values read as the defaults; a setter loads, changes one key and saves, so Phase 10's keys survive. The Settings screen applies only what was saved: a write that fails puts the box back and says "the change was not applied", since the App re-reads the file. The window mode is applied by the App at boot (only if fullscreen is on) and when the Fullscreen choice itself changes, never for another toggle, so flipping Edge scroll can't drop the player out of fullscreen; it is skipped without a window (`DisplayServer.get_name() == "headless"`).
- **Not checked:** the save's rename over an existing file on Windows and Web, `user://` persistence on Web, and the glyphs without system fonts: see Not yet. Keybinds, volume and resolution are Phase 10; Skirmish is Phase 9.

### Maps (`MapBuilder`, the generators)
- **`MapBuilder`** (`scripts/mapgen/map_builder.gd`) is the offline tool code the three generators share (floats and `FastNoiseLite` are fine there: it never runs in the sim):
  - It owns the height raster (16-bit gray), the mask raster (RGB8), and float working arrays for height (m), depth level, ground, and blocked.
  - `fill(height_and_depth, ground_type)` is the two-pass base fill: heights and depth first, then ground types, which need the slope.
  - Stamps then change the working arrays, so order is part of a map's recipe:
    - `house(cx, cz, w, d, height)`: raised to the highest ground under it plus `height`, blocked, WOOD.
    - `wall(points, thickness, height, gaps)`: raised along a polyline, blocked, ROCK, with open gates.
    - `plateau(center, radius, top, cliff_width, ramps)` and `plateau_polygon(...)`: a flat top, a ROCK cliff band steeper than the walkable limit, and graded ramps up.
    - `road(points, width)`: SAND, which can't burn.
    - `patch(center, radius, noise, threshold, type)`: a ground type where its noise is high.
  - There is no water stamp: a stamp can't carve water after the fill, so a river, pond, or stream goes into the `height_and_depth` callable. `MapBuilder.profile(keys, at)` is the piecewise-linear helper for a smooth bed (the sim's slope limit applies to the undead units that wade through deep water), and `level_depths_m` takes a fourth threshold for a depth-4 core.
  - A generator runs as `godot --headless -s scripts/gen_<map>.gd`, checks that the saved map reloads (`quit(1)` if not), and takes an optional `-- --out=<dir>` so the tests can regenerate into a scratch directory and compare bytes.
  - `save(dir, name, display_name, herb_plants)` writes both PNGs, their keep-importer files (before the PNGs, so Godot never imports them as textures), and the `MapInfo`. `report()` reloads the result through the sim and prints what is in it.
  - **Raised structures leave a steep ring.** The sim's per-sample slope takes the steeper edge to a neighbor, so a 3 m step to a house makes the sample beside it unwalkable too. A gate in a wall, or a ramp, needs about four samples of width to keep a walkable core; the builder warns about narrower ones.
- **Blocked samples are drawn darker** (houses, walls), 45% darker and 25% greyer, on the terrain only. Their height was already in the mesh, but nothing marked them, so a house read as a bump. `TerrainView` writes an R8 `blocked_map` texel per sample once, because the sim never unblocks anything, and the shader's `blocked_tint` uniform (`TerrainPalette.BLOCKED_DARKEN`, `BLOCKED_DESATURATE`) says how. It is applied right after the ground-type tint, so fire, wetness, snow and water still go on top.

### Map: the Riverside village
- **What:** a south-bank village the tutorial mission clears, stamped by `scripts/gen_riverside.gd` through `MapBuilder` after the base fill. It is hand-placed constants, not noise, so the layout reads and stays put.
  - Eight wooden houses (5–8 m footprints, 3 m tall) ring an open square centered on (445, 375) m. The nearest house sample is 17.8 m from the center and the nearest unwalkable one 17 m, so the 13 m of clear, walkable, dry ground it promises has room to spare. The gap in the north-west is where the lane comes in.
  - A sand plaza (7 m) sits at the square's heart, with a main lane in from the north-west, four spurs, and a 3 m sand road that runs back toward the ford.
  - Brush and wood patches go in first, so houses and lanes overwrite them.
- **Where:** the houses stand inside x 405–485 m, z 335–415 m, 25 m or more from the creek. The road is ground only and stops 24 m short of the mission's nearest point, because the patrols and the ambush around the ford landing keep their ground as it was.
- **What it changes:** 346 blocked, WOOD samples. Counts are now grass 162,258, brush 49,528, wood 31,163, sand 16,270, rock 2,925.
  - Houses stop arrows and grenades, because projectile contact reads the height field, and pathing treats them as solid. They burn.
  - The sim's per-sample slope takes the steeper edge, so every house also leaves a one-sample ring of unwalkable ground.
  - The roof is the highest ground under the footprint plus 3 m, so on a slope the low side stands taller.
- **What it must not change:** `test_map_builder.gd` pins a SHA-256 of every sample outside the village's box and the road's corridor to Phase 7's, so the creek, the ford, the herb plants, and every point of `riverside_ai.tres` are as they were. It also keeps the village 10 m from the spots earlier tests pin, proves the square is walkable and in the same `LIVING` component as the north-bank deploy point (290, 180) m through the ford, and that every house can be reached on foot. `PHASE_1_SHAPE_HASH` in `test_riverside_map.gd` was updated for the houses.

### Maps: The Ford and Old Mill
- **What:** the two other campaign maps, written by `scripts/gen_the_ford.gd` and `scripts/gen_old_mill.gd` through `MapBuilder`. Every layout number is a constant in the generator. `tests/sim/test_campaign_maps.gd` reads them, and `test_campaign_missions.gd` checks the hand-written mission data against them, so a coordinate lives in one place and a regenerated map that moves a point fails a test.
- **The Ford** (`maps/the_ford/`, 384², 30 m height range): an escort across a wide river.
  - **Plain:** gentle rolling ground, 3 to 10 m, further into the blight than Riverside: grass 46%, brush 22%, sand 20%, rock 5%, wood 6%, against Riverside's 62%, 19%, 6%, 1%, 12%.
  - **River:** west to east, centerline `z = 192 + 8 sin(2 pi x / 300)`, 44 m of water. Depth level 4 within 6 m of the centerline, 3 to 11 m, 2 to 16 m, 1 to 22 m, sand within 4 m of the water. The bed is a smooth profile (under 0.2 m per m), so Husks can cross it.
  - **The ford** (x 186 to 198): the depth is capped at level 2 across the whole channel and at level 1 within x 189 to 195, relaxing to full depth by x 180 and 204 (under 0.45 m per m). The whole channel is capped, not just the middle, and nothing else on the map is shallower than level 3 across the river, so it is the only crossing for living units: the test shuts x 180 to 204 and a flood from the deploy area can't reach the north bank.
  - **Ambush pools:** two beds a few meters off the centerline (west `(166, 196)` on the south shoulder, east `(218, 178)` on the north), forced to level 4 within 7 m of the center and shelving to dry at 14 m. A living unit can't stand in them; they join the undead component that includes the landing.
  - **Road and hamlet:** a 4 m sand road from the deploy area north across the ford, bending north-east to a hamlet. Its palisade is a ring 30 m in radius (2 m thick, 3 m tall, ROCK, blocked) round `(255, 60)`, with a 7 m gate gap on the south-west side where the road arrives, five wooden houses inside, and a flat pad under all of it so the wall stands level. The gate area, where the escort ends, is 4 m inside the gap with a 7 m radius, so it reaches out through the gap.
  - **East woods:** wood and dead brush over x 280 to 360, z 100 to 185 with a ragged edge. The Rippers spawn there and walk to the landing without crossing the river.
- **Old Mill** (`maps/old_mill/`, 320², 30 m height range): a raised mill to hold.
  - **Plain:** 3 to 6 m, mostly grass, with brush fields (the wheat) in a ring 35 to 75 m from the plateau's center, cut by six grass lanes (the two ramps and the four compass directions), and scorched patches of rock and sand beyond 38 m.
  - **Plateau:** its top is flat at 12 m with a radius of 28 m wandering between 24 and 30 m round the compass. A 4 m ROCK band, at least 1.5 m per m, falls to the plain all round. The only ways up are two 8 m ramps, north-west and south-east, each about 27 m long and climbing 0.32 (north-west) and 0.28 (south-east) m per m. A test shuts both ramps and floods from the plain, and every walkable sample at cliff height must lie on a ramp strip.
  - **Mill and yard:** a 10 by 10 m wooden house 6 m tall (blocked, so it stops arrows), and an open yard of 7 m radius south of it, starting one sample clear of the mill because the sim treats the ring round a raised structure as unwalkable.
  - **Water:** a millstream (6 m, depth 1 to 2, sand banks) from the north edge through a pond (18 m radius, depth 3 in the middle) to the south edge. The stream can be waded (depth 2 at most), so it is a firebreak and a slowdown, not a wall; the pond core is the one place a living unit can't go. The east edge spawn is across it. The pond is 22 m from the cliff.
  - **Spawns and deploy:** four edge spawn zones (N, W, S, E) all in the plateau's single `LIVING` component, the deploy point on the top south-west of the mill.
- **Connectivity:** each map came out as one `LIVING` and one `UNDEAD` component when generated (measured, not asserted). The tests assert the reachability the missions need instead: every spawn, waypoint, deploy point and escort waypoint is in the right component, and the ford, the ramps and the gate are the only ways across or in.
- **Determinism:** every noise has a fixed seed. The tests regenerate each map in a second process and compare the PNGs byte for byte.

### The campaign data
- **Files:** `data/campaign/campaign.tres` (a `CampaignDef`: the three missions in order and 64 given names), `data/missions/<id>/mission.tres` (a `MissionDef`: map, roster, deploy, camera, atmosphere, briefing), `data/missions/<id>/rules.tres` (a `MissionScript`), and `data/atmospheres/<id>.tres` (an `Atmosphere`), for `riverside`, `the_ford`, and `old_mill`. All are hand-written with `;` comments (the editor drops them if it re-saves a file) and a legend of the numeric enum values each file uses. `tests/sim/test_campaign_missions.gd` checks every number against its enum name, so a wrong one fails a test. `riverside_ai.tres` is the Phase 7 test mission; `MainView` plays it only as the sandbox (no `MissionLaunch`), which the demos use.
- **Riverside** (tutorial, clear weather): seven Dark groups, all on the south bank. Two Husk field patrols (the south landing, then the sand road to the village) are placed and radius-checked so no alert reaches the north bank; a Husk patrol walks the village lanes (waypoints on the generator's lane polylines); a Husk guard holds the square (6 to 12 Husks by tier); two bands of Husks roam the far fields, their waypoints 95 to 118 m south and 107 to 142 m south-west of the square, and `stirring` (40 s after `hint_grenade`, the squad reaching the village) sets them hunting; the raiders (Rippers, 2 to 7) spawn at the village's far south-east corner when 6 of the roamers have died. The tutorial hints are `SET_OBJECTIVE` messages on `TIMER` and `AREA_ENTERED` triggers. "Cross the ford" is done by `at_ford`, the squad on the dry south landing (8 m round (300, 244); the creek's depth-3 core makes the ford the only way there, which a test floods the map to prove), not by reaching the water; the water tip comes from `in_ford`, the squad in the ford itself. `win` waits for `raid`, so an early straight assault can't win before the raiders exist.
- **The Ford** (escort): the villager is a Light `ESCORT` group along the generator's waypoints. Two Husk `AMBUSH` groups lie in the depth-4 pools, and `crossing` (the villager at the ford) springs both with `SET_BEHAVIOR` HUNT (the road is 26 m from each, beyond their own 12 m alert); a Husk `GUARD` holds the north landing, and the optional "Clear the north landing" objective is shown by `north` (the villager landed) and done by `landing_cleared`, a `GROUP_CLEARED` of that guard (so it can complete before the villager lands; reaching the gate doesn't complete it); the Drifters are **one** `PATROL`/`PING_PONG` group with one four-point route that covers both river reaches and passes over the ford, so the squad meets them as it wades. Two Ripper packs (`FLANK`, ranged and support, which includes the villager): `rippers_rear`, spawned by `rear` 3 s after `crossing` on the south bank 75 m south-west of the ford, comes up behind the escort while it is in the water; `rippers`, from the east woods, by `flank`, a `TRIGGERS_FIRED` of `north` (the villager landed) or `flank_timer` (a tier-scaled timer). `home` fires when the villager is in the gate area, which reaches about 3 m out through the gap, so it fires at the gate mouth.
- **Old Mill** (hold the line): five wave groups in one `MissionDraw` (4 slots, `ordered`, pool listed easiest first), none spawning at start. Each takes its edge from `spawn_by_tier`: tiers 0 and 1 all from the north (one ramp to mine), tier 2 from the north, west, and south (both ramps), tiers 3 and 4 from all four edges with no wave on the same edge as at the tier before. The storm's edge matters most (lightning needs a line up a ramp's axis): it comes from the north at tiers 0 and 1, the south (the worst approach, up the south-east ramp) at tiers 2 and 4, the west at tier 3, with one Stormcaller at tiers 0 to 2 and two at 3 and 4. The waves are hordes (40 Husks in the Husk wave at tier 2), sized for a squad that leaves the plateau rather than one that holds the ramps. The pacing is a chain of gate triggers: `w{k-1}_clear` then a 750-tick `w{k}_breather`, or `w{k}_late` (a deadline after wave k-1 spawned), and `w{k}` is a `TRIGGERS_FIRED` of the two; `rain` starts the tick after wave 3. `overrun` loses the mission when 6 Dark units are in the 7 m mill yard at once.
- **Tests prove, rather than assume:** every spawn, waypoint, and deploy point is passable for its group's mobilities; the coordinates that come from a map generator are read back from `get_script_constant_map()` and must match within 0.5 m, so a regenerated map that moves a point fails; a fixpoint over the trigger graph proves every trigger (and so `win`) can fire at every tier, since `validate()` only catches `after` loops; a scripted player (Dark killed on sight, the squad walking beside the villager) wins each mission, and each loss condition fires; and two worlds built the way a campaign builds them (`CampaignState` plan, `MissionSetup.create_world`) hash identically every 500 ticks for 3000.
- **Atmospheres** are described under Atmosphere, and what the balance pass changed in each mission, and why, under Playtest and balance.

### Playtest and balance (`make playtest`)
- **The harness** (`scripts/playtest.gd`, headless, no view) builds every world through `MissionSetup` from a `CampaignState` plan and `mission_seed`, exactly as the App does, so a seed printed in a table is a seed that reproduces in the game: run `i` uses campaign seed `SEED_BASE + i`, so `SEED_BASE=<seed> SEEDS=1` replays one run. The settings are environment variables, documented in the Makefile and the script's header (`MISSIONS`, `TIERS`, `SEEDS`, `SEED_BASE`, `PILOTS`, `CHAIN`, `MAX_MINUTES`, `OUT`, `TRACE`, `RAW`, `REPORT`). Runs are independent and deterministic, so a batch splits across processes by mission or pilot, each writing `RAW`, and `REPORT` merges them. It exits 1 if a world can't be built or a file can't be written.
- **The tables:** per mission, tier and pilot, win, lose and timeout percentages, median and 90th-percentile minutes (and the median of the wins), losses (count, share of the roster, per win), kills, friendly-fire deaths and stuck units; then The Ford (how often the villager died and to whom, his lowest health, whether the pool ambushes sprang), Old Mill (the waves drawn, where a bad run ended, when the charges were laid, sorties), the chained campaign, and anomalies with their seeds.
- **Two pilots** (`PlaytestPilot`) play the Light side through `world.enqueue`, once a second, like input. They see what a player sees (a submerged Husk is not in their list) and order only soldiers the player commands, never the villager. The numbers are a bracket, not a player: **keep the pilots fixed while tuning data**, so a before and after differ only in the data.
  - **Naive** (the lower bound): everyone attack-moves along the route, advancing when the army's centroid arrives and not waiting for stragglers, then at the nearest visible enemy once the route is done. On The Ford the route is ford, landing, gate, and it walks back to the villager when he is 25 m or more behind every soldier (a person reads the hint). No formations, specials, healing or holding.
  - **Competent** (an upper bound: perfect once-a-second micro, and it knows the map): the melee attack-moves in a short line with the rest following 8 m behind; Sappers lob at clusters of 3 or more with no friend within 6 m of the aim; Longbows fire-arrow clusters on brush or wood when no friend is near the aim or the line and no charge is lying within 15 m; Wardens heal the lowest-health friend below 60%. On The Ford the melee stays 8 m ahead of the villager and the ranged beside him; at Old Mill the Sappers lay all their charges down the two ramps first (done by about 32 s), then the melee holds both ramp heads and the ranged stand behind them. A **sortie** rule sends the melee out when a fight has been quiet for 60 s with an enemy in sight, for the Drifter stand-off below.
- **Targets** (tier 2 unless stated; the plan's, refined per mission role by ruling): Riverside is a tutorial, so easier; The Ford and Old Mill harder. Competent wins 100% on Riverside, at least 85% on The Ford and 80% on Old Mill; competent losses 10 to 25% of the roster on Riverside, 15 to 35% on The Ford and 25 to 45% on Old Mill; naive wins 60 to 90% on Riverside, 30 to 70% on The Ford (the villager's death the expected failure) and 20 to 60% on Old Mill with under 10% timeouts; median length of the wins at least 4 minutes on Riverside and The Ford and 6 to 15 on Old Mill; losses rise and wins fall or stay at 100% from tier 0 to 2 to 4; competent tier 4 wins 40 to 80% on The Ford and Old Mill; the chained campaign wins Old Mill at least 70%. The final run is under Measured.
- **What the balance pass found, and changed** (all data, plus one code fix; every number is tier 2, 20 seeds, competent and naive, before to after on the same code):
  - **A Drifter stalemate, a code fix** (`StandoffSpot`). A STANDOFF archer's spot checked range and a 1.5 m friend corridor but not the flight `RangedCombat` needs, so a Drifter at the foot of Old Mill's west cliff held a spot in range from which every arrow hit the lip, and its wave never cleared: the first naive pilot, which holds the yard, timed out on 14 of 20 seeds. `RangedCombat._aim` split its ballistic half into the static `clear_launch_from(...)` (as `Lightning.is_clear_from` was split), `_fits` asks it from the spot's launch point, and `find` skips a spot within a move's arrival radius of the unit, the same stalemate's second face (a move that short ends before it starts, so a Drifter on the cliff face was re-sent for ever). Result: 20 wins in 8.8 to 9.1 min with 0 or 1 lost; everything else unchanged.
  - **The Ford:** the pool ambushes never sprang (the road is 26 m from each pool and their alert radius was 8 m). `crossing` now sets both pools hunting, and their own alert radius is 12 m (measured to change nothing, since the trigger always fires first). A new Ripper pack `rippers_rear` spawns 3 s after `crossing`, 75 m south-west of the ford, so it reaches the escort while it is still in the water; the east-woods pack and the pools grew. Competent 100% wins, 2% lost, 2.1 min to 95%, 21%, 2.4 min; naive 100%, 2% to 45%, 42% (the villager died in 55%, all to Rippers); pools sprung 0 to 100%. **Why a pack from behind:** a threat from the front or the sides hurt the competent pilot's villager and never the naive one's, because the naive army walks at a Sapper's 2.0 m/s with the villager (2.2) right behind it; only a threat from behind separates a squad that guards its rear from one that doesn't. Its timing decides: 3 s later or 20 m farther away it is a nuisance.
  - **Old Mill:** the tier inversion (tier 4 easier than 2) was geometry, not wave splitting. Lightning needs a clear line up a ramp's axis, and the storm wave costs a held ramp 6.9 soldiers from the south, 4.1 from the north, 3.9 from the east and 0.9 from the west; tier 2 sent it from the south and tier 4 from the north. Tier 4 now sends the storm from the south and the Rippers from the north. A held ramp is nearly free against Husks, Blightbags and Drifters at any size tried (satchels, grenades and four Longbows on a plateau 12 m up shred whatever climbs), so the waves became hordes sized to break a squad that leaves the plateau (40 Husks in the tier-2 Husk wave; each wave has its own unit entries now). Competent 100%, 26% lost, 8.4 min to 100%, 30%, 9.3 min; naive 100%, 32% to 45%, 78%, 6.7 min with no timeouts; losses at tiers 0 / 2 / 4, 12 / 26 / 8% to 7 / 30 / 55%.
  - **Riverside:** two roaming Husk bands loop the far fields and a new `stirring` trigger sets them hunting 40 s after the squad reaches the village; the raid now fires on 6 roamer deaths and comes out of the far south-east corner with more Rippers; patrols went 5 to 7 Husks and the guard grew. Competent 100%, 6% lost, 2.3 min to 100%, 17%, 4.0 min; naive 95%, 20%, 2.8 min to 90% (95% over 40 seeds), 39%, 4.0 min; tiers 0 / 4 losses 2 / 13% to 8 / 40%.
  - **Visual (data):** The Ford's camera moved 30 m up the road so the squad stops hiding under the control bar, and Old Mill was lifted until the plateau read (see Atmosphere).
- **A bot is not a human.** The competent pilot holds both ramp heads perfectly over its charges and never sorties against Stormcallers, which is why Husk, Blightbag and Drifter waves are nearly free for it at any size and lightning is its main cost (5.6 of a storm draw's 7.2). A person would probably pay more against the hordes and less against the storm, and the friendly fire the pilots take (0.4 to 1.3 soldiers a run, 2 to 3 for the naive pilot) is counted, not investigated. Twenty seeds give wide error bars: a rate under about 15% can move 10 points between seed blocks (The Ford's naive win rate was 45% on seeds 1000 to 1019 and 65% on 1020 to 1039). Tim should play it.

### Decisions
- **Tim chose** (plan approval, 2026-10-03):
  - **A fixed roster per mission, with carryover slots.** Surviving veterans fill same-type slots; an empty slot gets a fresh recruit; extra veterans wait in reserve.
  - **Defeat offers Retry from the pre-mission save**, with the same seed (so the same waves). The failed attempt's losses are discarded.
  - **Wounds carry over** (CLAUDE.md: no healing between missions). The briefing lets the player bench a wounded veteran for a recruit. Charges, herbs and ammo refill each mission.
  - **Menus and pause exist in single player.** Pause freezes the sim by the view not stepping it; lockstep multiplayer will need a pause command (Not yet).
  - **The campaign darkens toward a hellscape**, mission by mission, from data (Atmosphere).
  - **Mission data stays `.tres`,** his Phase 7 choice carried over: a new mission is data and a map.
- **Defaults in the approved plan:**
  - **The weather schedule is triggers** (TIMER plus SET_WEATHER), not a third mechanism.
  - **The draw is rolled by `World.roll_bindings` from its own generator** (RNG: one exception).
  - **`DeployCommand` is in the command stream,** so a replay or a lockstep peer gets the roster, its veterancy and its wounds from the stream rather than from a file.
  - **The view freezes at the outcome tick** so nobody dies after a win; pause is view-only.
  - **The villager is SUPPORT,** so flanking Rippers hunt him (the escort's tension); `flank_roles` on a group lowers that if it proves too harsh.
  - **Skirmish is a stub** ("Skirmish arrives in Phase 9"); keybinds, volume and resolution are Phase 10.
- **Rulings during the build,** each with its reason and what it costs if wrong:
  - **`MissionDef.validate` rejects non-combatant roster types** (`melee_damage` 0, no ranged projectile, no special): the villager is the only one, and a data-free rule is cheaper than a name check. A future non-combatant player unit would need the rule widened.
  - **The Briefing's test computes Riverside's roster from its `MissionDef`** (14 slots at tier 2: 6 + 3 + 3 + 2), not the brief's shorthand "6 recruits".
  - **`apply_victory` refuses a stale plan, and `Soldier.current_hp` hides the 0-means-full convention.** The App, the briefing and the results screen build directly on both, so they were fixed in review rather than left as minors. Cost if wrong: one extra small fix round.
  - **The Ford's sand road stops short of the ford (a trail that fades),** because every `riverside_ai.tres` point and the Phase 7 hash outside the village were to stay frozen; sand is cosmetic and a firebreak, and players find the ford by the creek and the tutorial hint. A road to the ford would mean retaking that hash.
  - **`wave_drifters` lists Husks before Drifters,** the documented "melee before ranged" spawn convention, so ranged stand behind.
  - **Old Mill must stay readable:** terrain features and units distinguishable at the default zoom. Ambient and sun were lifted and the grade eased; the ember sky and the ash stay. The Ford's camera starts at (192, 285). Cost if wrong: a less oppressive Old Mill that Tim can darken later.
  - **The selection gate rejects only Light units the AI controls.** The brief's "every AI-controlled unit" collided with "the sandbox exactly as before": F9 gives the mouse the Dark side, whose units are all the AI's. Cost: a Dark AI unit is selectable after F9 in the sandbox (debug only).
  - **Edge scroll is held off only over buttons,** and the control bar keeps 12 px of padding under its last row, so the bottom edge still scrolls while reaching for a button doesn't drag the map.
  - **Campaign mode also ignores F8** (debug statuses could maim permanent soldiers); F5, read-only and useful for playtests, stays. Cost: F5 reveals ambushes in a campaign.
  - **Retry returns to that mission's Briefing** with the same bench (one extra click), so the player can re-bench after seeing who fell; the pause menu's Restart is the instant one, and it asks first because it discards the attempt. Retry trusts the file on disk only if it is the same campaign at the same point.
  - **The naive pilot attack-moves along the route,** advancing when its centroid arrives and not waiting for stragglers, then at the nearest visible enemy; on The Ford its route is ford, landing, gate, and it walks back to the villager when he is 25 m or more behind every soldier. A first naive pilot that held the yard and walked the villager's own waypoints was no usable lower bound (it timed out on Old Mill's Drifter stand-off and lost nothing on The Ford). Cost if wrong: the naive numbers shift; the competent ones don't.
  - **The Old Mill stand-off was an AI defect, fixed in code** (the single code change the balance pass was allowed), with tests, and `riverside_ai` and every AI test unchanged. `StandoffSpot.find` skips a spot within `ARRIVE_RADIUS`, the same stalemate's second face; cost if wrong: a unit occasionally re-spots one think later.
  - **The targets were refined per mission role,** and **The Ford is accepted at about 2.4 minutes,** short of the 4-minute target. The target was the controller's, not Tim's, and the escort is short by design (240 m of road at 2.2 m/s is about two minutes); content can only add time by stopping the villager, which means a fight at his side long enough to kill him first. The data-only lever that would change the shape, a gate that holds until the Rippers are dead, is offered to Tim (Not yet). Cost if wrong: a short second mission.

### Behavior changes to earlier phases
- **The Riverside map has a village and a road.** 346 blocked WOOD samples and new ground counts. `PHASE_1_SHAPE_HASH` in `test_riverside_map.gd` was updated (the one pre-approved edit to an existing test), and `test_map_builder.gd` pins that every sample outside the village's box and the road's corridor still hashes as Phase 7's, so the creek, the ford, the herb plants and every point of `riverside_ai.tres` are as they were. `make maps` reproduces all three maps byte for byte; Riverside's PNGs were proven byte-identical after the move onto `MapBuilder`, before the village.
- **`AiDirector.spawn_group` calls `World.spawn_block`.** The same layout and ids. `test_deploy.gd` checks `spawn_block`'s positions, ids and spacing against `Formations.slots` re-derived in the test with the same spacing rule, so it guards the layout's shape, not its equivalence with the old inline code; that guarantee is the unmodified pre-existing AI tests, which still pass.
- **`RangedCombat._aim` calls the new `clear_launch_from`,** no change for the unit's own shots. **`StandoffSpot`** now needs a spot with a real flight and skips spots within a move's arrival radius, so Drifters and Stormcallers pick fewer spots on rough ground. The existing AI tests pass unmodified, and `make demo-ai` prints the same result lines.
- **The main scene is the App,** so `make run` opens the main menu. The demo scripts load `main.tscn` directly and never see it. `MainView` without a `MissionLaunch` is the sandbox of earlier phases: the test squad, `riverside_ai` at tier 2, every debug key, never freezing.
- **`main.tscn`'s Environment is `resource_local_to_scene`,** so one mission's look can't leak into the next scene.
- **A world hashes `soldier_id` and the mission's bindings, objective states and `seen_commanded`.** Hashes from before Phase 8 aren't comparable.
- **The terrain shader** has the blocked tint and the grade uniforms; every uniform defaults to "no change", and a window comparison of the sandbox against the previous commit showed only run-to-run noise.
- **CLAUDE.md** gained "Pause: P" under Controls, the darkening arc under Core rules, and The Ford's rear Ripper pack under Missions.
- No earlier test changed except `PHASE_1_SHAPE_HASH` (and a header comment in `test_standoff_spot.gd`). The AI fix gained new tests beside the Phase 7 ones; none was edited.

### Measured (M4 Max)

| Scenario | Result |
|---|---|
| Playtest, tier 2, 20 seeds, competent (the final playtest in `docs/phase8-playtest.md`, committed data) | Riverside 100% won, 17% of the roster lost, 4.0 min; The Ford 95%, 21%, 2.4 min; Old Mill 100%, 30%, 9.3 min |
| The same, naive | Riverside 90% (95% over 40 seeds), 39%, 4.0 min; The Ford 45% (the villager died in 55%), 42%, 2.5 min; Old Mill 45%, 78%, 6.7 min, no timeouts |
| Competent losses at tiers 0 / 2 / 4 (10 seeds; 20 in brackets) | Riverside 11 / 17 / 38% (8 / 17 / 40%); The Ford 7 / 21 / 34% (4 / 21 / 32%); Old Mill 7 / 30 / 57% (7 / 30 / 55%). Wins at tier 4: 100%, 60%, 70% (95%, 60%, 60%) |
| The campaign chained, survivors carrying over, competent, tier 2 | Cleared 20 of 20; losses per mission 2.1, 4.5, 3.7 (10 seeds) |
| Playtest run | 300 runs, no timeouts, no instant losses. The matrix of 210 runs took 559 s over 12 processes; 0.8 to 1.5 ms per simulated tick with ten processes sharing 14 cores, a competent run 4 to 13 s. The default `make playtest` (tier 2, both pilots, 20 seeds) is about 16 minutes in one process |
| Old Mill with the hordes | About 100 kills a run (48 before); 1.35 ms a tick against 0.80 in an isolated run, inside the 33 ms tick |
| Windowed (`make capture`, GL Compatibility on Metal) | The mid-battle frames of the three missions show the sim at 0.75 to 3.2 ms a tick, with 45 to 60 units and up to 12 projectiles |
| Determinism | Each mission, built as a campaign builds it, hashes identically every 500 ticks for 3000 with the same attack-move; `DeployCommand` ids, `spawn_block` layout and ESCORT event logs are pinned |
| Test suite | 1642 tests in 95 scripts (932 before Phase 8), all passing, with `check-sim` ok; about 70 to 130 s depending on load |

### Not yet
- **Line of sight around corners.** Raised terrain and walls stop projectiles and the direct-shot `is_clear`, but a ranged unit can still target something it can't see round a corner (CLAUDE.md: it cannot). None of the three v1 maps depends on it.
- **`AiTactics._has_shot` is range only,** no line. With no standoff spot at all a STANDOFF member holding with an enemy in range stays where it is, shot or no shot. The spot check itself now needs a real flight, so this is rarer, but a unit penned where every spot fails could still wait for ever. A STANDOFF unit whose target keeps moving re-spots instead of casting (Phase 7), and seen once more in Phase 8: on a tier-4 candidate one step harder than the shipped one (seed 1007) the last Drifter and both Stormcallers circled the map edge for ten minutes and the run timed out. It did not occur in the 300 final runs.
- **A lockstep pause command.** Pause is the view not stepping. Multiplayer needs a command in the stream (and a rule for who may pause), which Phase 9 or later decides.
- **Keybinds, volume and resolution are Phase 10,** with Skirmish (Phase 9, a stub panel now). `GameSettings` keeps unknown keys, so Phase 10's survive.
- **Windows and Web.** Not checked: that `DirAccess.rename_absolute` overwrites an existing file there (the save's atomic write; the store returns the error and keeps the old save if not), `user://` persistence in a Web export, the objective panel's glyphs (○ ✓ ✗ rendered with a macOS fallback font; the menus use ASCII and drawn icons), depth fog and the grade shader on WebGL2, and the atmospheres on anything but Metal. The map regeneration test byte-compares PNGs, which pins the generating platform (`FastNoiseLite` and libm may differ on x86 or Windows), hides the child process's stderr and has no timeout.
- **The Ford's length, for Tim.** The Ford is about 2.4 minutes against a 4-minute target (see Decisions). The lever that would lengthen it without a map change is a gate that stays shut until the Rippers are dead (the briefing says the hamlet "will open its gate to no one it cannot name"); a slower or more cautious villager, or a longer road (a map change), are the others.
- **Riverside's naive pilot wins 90 to 95%,** at the edge of its 60 to 90% target (90% on seeds 1000 to 1019, 95% over 40). It loses 39% of its roster, but a squad that marches as one block through one group at a time rarely loses outright. Every variant that took it lower used 7 or more Rippers or a bigger guard, which took the competent pilot past 25% lost or the raid past CLAUDE.md's "a few Rippers" for Riverside, so the tutorial keeps 5 Rippers at tier 2 (7 at tier 4).
- **Mission validation gaps.** `TRIGGERS_FIRED` and `after` liveness aren't validated: a cycle (A waits on B waits on A, or `after` plus `TRIGGERS_FIRED`) passes `validate()` and never fires. Each shipped mission's test catches it with a fixpoint over the trigger graph, but a new mission relies on writing one; a "can ever fire" check replacing `_after_loops` would make it a load error. `MissionRuntime._init` doesn't check `bindings.size()` against the draw's slot count (a seam for a replay or save loader), and the reachability test's `_condition_possible` indexes a group's draw without resolving aliases in UNIT_DIES.
- **Naming and small seams in the sim:** `MissionEvent.objective` is an objective's index while `MissionRuntime.objective` is the message line's string; "is lost" is judged in two places (`MissionStats` and `CampaignState`) and the history's loss count is counted separately; `CampaignState.from_dict` doesn't check `fallen_in` against the history; `MissionStats.enemy_dead` counts Dark bodies already dead before `begin`; `MissionSetup` doesn't check that the deploy's tick is the world's. Conversion isn't in the sim, so "converted" is coded and tested by flipping a faction by hand.
- **Maps.** The overhead map (Tab) draws no blocked marking, and houses read very dark (`TerrainPalette.BLOCKED_DARKEN` is the one number); wooden houses burn, and brush or wood patches touching a house can carry fire to it; `MapBuilder.report()` failing to reload doesn't fail the generator (`make maps` exits 0); `MapBuilder.profile` doesn't check its keys are sorted; the generators repeat their boilerplate (`out_dir`, save and reload, level depths), and `gen_riverside.gd` lacks `--out`. The Ford's gate (a 7 m gap leaves a 5 m walkable core) is one constant, `GATE_WIDTH_M`, if a big block finds it tight.
- **Menus.** The Briefing, Results and CampaignComplete repeat layout code that `MenuKit` could hold before Phase 9 adds screens; the Briefing's reserve list sits under the roster, so with 16 or more slots a benched veteran is below the fold; the pause menu's two confirmations are styled differently; a failed settings write doesn't apply for the session (the App re-reads the file); a damaged `settings.cfg` logs a parse error on every read; `main.gd` is about 440 lines mixing the sandbox, the campaign flow, pause and debug keys.
- **The playtest and its tests.** `report.gd` hardcodes the three mission ids; the fire arrow is released still nocked after `FIRE_PATIENCE` without re-checking the aim's safety, and a grenade bombardment isn't stopped when the aim becomes unsafe; the cluster and follower loops are duplicated; determinism is tested only on the tiny mission; the walk-back has no hysteresis. In tests, `assert()` in `tests/support/` helpers hangs under `-d` instead of failing a named test, `tests/view/test_gibs.gd` flaked once in a full run (a gib tunnelled through the heightfield under Godot physics, probably also the assert-count wobble of about two between runs), and one timer test has a 0.1 s real-time margin.
- **Atmospheres were tuned by eye** on one machine; `Atmosphere`'s header says "linear" while the shader's colour uniforms are `source_color` sRGB, which is the project's convention (the file is authored by eye).

## Skirmish vs AI (Phase 9)
The second way to play: pick a map, a mode, a side and an army bought from a point budget, and fight an AI commander until the clock runs out or one side is wiped out.
- **Three modes.** Body Count (enemy deaths), King of the Hill (time holding the hill alone), Capture the Flags (flags owned at the limit). Elimination ends any mode at once.
- **Either side.** The player picks Light or Dark; the AI plays the other. The sim never assumed the player was Light; the view now doesn't either.
- **Armies are bought.** Every unit type has a cost (data); both sides get the same budget. The AI's army comes from one of four templates per side.
- **The AI has a general.** A `SkirmishCommander` per AI side sits over Phase 7's groups: it picks the mode's objective, stages out of the enemy's reach, commits when it is locally stronger, and keeps its ranged and support behind its melee. A new ADVANCE behavior and a MEDIC tactic are what it needed below it.
- **Spawns and flags live beside each map** (`maps/<id>/skirmish.tres`), placed by a pathing probe so neither start is favored, and pinned by tests.
- **A skirmish is data.** `SkirmishSetup` (map, rules, both armies, the start, the seed) plus the player's commands is the whole game: the replay and lockstep property the mission format has.

**Files**

| File | Role |
|---|---|
| `sim/skirmish/army.gd`, `army_template.gd`, `skirmish_catalog.gd` | `Army` (a side's counts, its cost and deploy order), `ArmyTemplate` (an AI army recipe, `fill(budget)`), `SkirmishCatalog` (`data/skirmish/skirmish.tres`: maps, templates, budgets, time limits) |
| `sim/skirmish/skirmish_map.gd`, `maps/<id>/skirmish.tres` | `SkirmishMap`: the starts, the flags, the hill, the flag radius, and a View group |
| `sim/skirmish/skirmish_rules.gd`, `skirmish_runtime.gd` | `SkirmishRules` (mode, clock, flags, the player's side), `SkirmishRuntime` (the score, the flags, the outcome) |
| `sim/skirmish/skirmish_setup.gd` | `SkirmishSetup` and `create_world`, the one skirmish world builder |
| `sim/ai/skirmish_commander.gd` | `SkirmishCommander` |
| `sim/ai/ai_behaviors.gd`, `ai_director.gd`, `ai_group.gd`, `ai_group_spec.gd`, `ai_tactics.gd`, `ai_orders.gd`, `ai_event.gd` | ADVANCE, `AiDirector.advance` and `commanders`, `ranged_behind`, MEDIC, the COMMANDER and HEAL events |
| `sim/missions/mission_runtime.gd`, `mission_event.gd` | `Outcome.DRAW`, `conclude()`, `MissionEvent.Kind.DRAWN` |
| `data/units/*.tres` | `cost` on every buyable type; the Warden is MEDIC |
| `data/skirmish/templates/*.tres` | The eight AI army templates |
| `view/mission_launch.gd`, `view/main.gd` | `MissionLaunch.for_skirmish`; MainView builds, frames and ends a skirmish |
| `view/skirmish/side_colors.gd`, `flags_view.gd`, `skirmish_hud.gd` | `SideColors`, `FlagsView` (the flags in the world), `SkirmishHud` (the score line and the F7 scoreboard) |
| `view/hud/mission_hud.gd`, `overhead_map.gd`, `control_bar.gd`, `view/ai/ai_debug_view.gd`, `view/input_bindings.gd` | The Draw banner, flags on the overhead map, the skirmish status line, the commander on F5, F7 |
| `view/app/skirmish_menu.gd`, `skirmish_results.gd`, `app.gd`, `main_menu.gd`, `view/settings/settings.gd` | The setup and army-builder screen, the results screen, the App's skirmish walk, the remembered setup |
| `scripts/skirmish_playtest.gd`, `scripts/playtest/skirmish_runner.gd`, `skirmish_result.gd`, `skirmish_report.gd` | `make skirmish-playtest` |

### Tick order
One step is inserted; the rest of Phase 7's list stands:
1. commands
2. `MissionRuntime.update` (the triggers; a skirmish has none, but its groups spawn here on tick 0)
   - **2b. `SkirmishRuntime.update`**, only in a skirmish
3. `AiDirector.update`: **the commanders first**, then the groups
4. and on as before.

- **Why 2b:** after the mission, so the AI's starting groups exist on tick 0 when the skirmish records the armies; before the AI, so the commanders read this tick's score. Like the triggers it reads the state the previous tick left: deaths in tick N are counted in tick N + 1.
- **After the outcome** the runtime freezes (nothing it holds changes again), the triggers already stop, the AI and the rest of the sim keep running, and the view freezes on that tick as for a mission.

### Data
- **`UnitType.cost`** (a "Skirmish" export group): the points one unit costs. 0 can't be bought: the villager. Negative is a validation error. The balance pass set the values (see Playtest and balance).
- **`Army`** is a faction and counts by type id. `validate(catalog, budget)` wants at least one unit, at most `MAX_UNITS` (60, for performance), every type known, on the army's side and buyable, and the cost within budget. **`type_list` sorts by role, then catalog index**, never by dictionary order, because the order a block is laid out in decides entity ids: melee first, so the box puts it in front.
- **`ArmyTemplate`**: `type_ids` and `shares_permille` in parallel (shares sum to 1000). `fill(budget)` is deterministic: each entry gets what its share buys, rounded down; over the 60-unit cap the counts are scaled to it in proportion (largest remainders take the left-over slots, ties to the earlier entry) and a type scaled to none takes one back from the most numerous, so a cheap horde never crowds a type out; then the rest goes a unit at a time to the affordable entry furthest below its share in points, ties to the earlier entry.
- **`SkirmishCatalog`** (`data/skirmish/skirmish.tres`, hand-written): the maps (Riverside, The Ford, Old Mill), the eight templates, budgets 600 / 1000 / 1500 (default 1000) and time limits 5 / 10 / 15 / 20 minutes (default 10). An explicit list, for the reason `UnitCatalog` gives (exported builds rename `.tres` files).
- **`SkirmishMap`** (`maps/<id>/skirmish.tres`, beside the heightmap; `MapInfo` and the PNGs are untouched): two starts with a facing each, an odd number of flags (3 or 5; odd so all flags owned can't be level), which flag is the hill, `flag_radius` (8 m; 6 m on The Ford so its ford flag reaches no deep water), and a View group (`camera_distance`, `atmosphere`, the mission's own look reused).

| Map | Start A | Start B | Hill | Other flags |
|---|---|---|---|---|
| Riverside | (295, 85) north bank, facing south | (310, 430) west of the village, facing north | (300, 262), the dry landing south of the ford | (150, 190), (450, 190) north of the creek; (450, 325), (150, 335) south |
| The Ford | (192, 330) south bank, facing north | (192, 54) north bank, west of the palisade, facing south | (192, 192), in the ford itself (depth 2 at most) | (192, 218) and (192, 154), the ford's south and north landings (moved by the balance pass from the far banks) |
| Old Mill | (68, 40) north-west | (232, 292) south-east, west of the millstream | (166, 157), the mill yard (`YARD_CENTER`) | (119, 104) and (214, 210), the feet of the two ramps |

- **Placed by a probe, pinned by tests.** A throwaway script printed each map's components, depths and path lengths, and the positions were moved until each start is as far from the hill as the other, and, sorted, as far from its own flags as the other is from its own, for living and undead units alike, within 15%. `test_skirmish_maps.gd` re-measures that with `Pathing.find_path` (and insists each path ends on the flag, since `find_path` falls back to the nearest reachable point), and checks every start and flag is passable and in one component for both mobilities, no flag zone reaches depth 3, and a 60-unit box fits at each start.

### Rules and runtime (sim)
- **`SkirmishRules`** is a RefCounted, not a resource: built from the map at setup (`for_map(map, mode, minutes, side)`), read-only once the skirmish starts, and hashed. `CAPTURE_TICKS` is 150 (5 s).
- **`World.start_skirmish(rules)`** refuses, with a `push_error`, what `start_mission` refuses, a world with no mission (the AI's army is the mission's starting groups), a second skirmish, and rules that don't validate.
- **Each update** (`SkirmishRuntime`):
  1. the first time, records every living unit by faction (`roster_ids`): the player's deploy and the AI's groups;
  2. counts each side's units dead, gone or no longer on its side (`deaths`) and alive;
  3. a side with a roster and nobody left loses at once (ELIMINATION); both at once is a draw;
  4. at `start_tick + time_limit_ticks` the score decides (TIME);
  5. otherwise scores the tick.
- **Scoring.** Presence at a flag is a living unit within `flag_radius`, center to center, that isn't submerged (a Husk lurking in deep water holds nothing).
  - **Body Count:** a side's score is the other side's deaths, whatever the cause. A Light Sapper's grenade killing a Shieldman scores for Dark.
  - **King of the Hill:** `hold_ticks` grows for the side alone on the hill; contested or empty, nobody's does.
  - **Capture the Flags:** standing alone at a flag `capture_ticks` captures it; the progress resets whenever who stands there alone changes; a flag stays owned when its side leaves. The score is flags owned; a tie is broken by flag-ticks owned (`owned_ticks`), then it is a draw.
- **Deciding.** `winner` is a faction or `DRAW` (2): the sim's own record, side-neutral, which a lockstep game would use. `MissionRuntime.conclude(world, outcome)` then sets the mission's outcome from the player's side (`rules.player_faction`): WON, LOST or the appended DRAW, with an appended `MissionEvent.Kind.DRAWN` (WON and LOST name trigger -1 from `conclude`). The scores and a per-unit alive snapshot (`final_alive`) freeze at the decision, because the rest of the deciding tick can still kill: the results screen reads the snapshot and never disagrees with the banner.
- **`SkirmishSetup.create_world(setup, catalog)`** mirrors `MissionSetup.create_world`: the terrain, the world, the player's army as a tick-0 `DeployCommand` (zero soldier ids, kills and hp, the player's faction, at the player's start, in a box), a `SpawnHerbPlantCommand` per map plant, `start_mission` with a `MissionScript` built in code (the AI's groups, no triggers, tier 2), `start_skirmish`, and a commander per AI side. Entity ids run deploy, herbs, groups, as in the campaign. With `player_is_ai` (the playtest's AI-against-AI runs) both armies are AI groups with a commander each.
- **An AI army is two groups,** both `spawn_at_start`, ADVANCE, `ranged_behind`, no retreat threshold: `main` (everything but the raiders, melee first) at the start, and `raiders` (melee types that prefer ranged or support targets: Rippers) beside it, offset sideways by half of each block's width plus 4 m. One main group rather than a melee group and a ranged group, because the bodyguard rule, `front`/`behind` and the 6 m march offset all work within a group: split them and nobody guards the archers.

### The AI below the commander
- **ADVANCE** (appended to `AiGroupSpec.Behavior`; the group's `engage_radius`, `hold_radius` and `march_attack` are appended to `AiGroup` and hashed). Each think:
  0. a free MEDIC member with someone to heal goes (below);
  1. attack-marching, visible enemies within `engage_radius` of the front members' centroid are engaged (`AiOrders.engage`, so tactics and the bodyguard rule apply);
  2. walking (phase 0), one leg to the anchor; arrived or failed, it holds (phase 1);
  3. holding, if no member is within the hold radius of the anchor, the free members walk back, and free members done with a chase beyond `engage_radius` walk back too (a forced march for one already recorded as sent there, since a march skips those).
  - It never force-moves a member that isn't free, never switches on its own and never retreats: the commander decides. A spec that starts in ADVANCE needs `guard_radius`, its first engage radius.
- **`AiDirector.advance(world, group, x, z, engage, hold, attack)`** moves the anchor. A group already advancing keeps its march unless the new point is more than max(4 m, a quarter of the members' distance) from the old one, or `attack` changed; the radii change either way. That slack is what keeps a commander nudging the anchor every second from burning the A* budget (a test pins at most 6 ORDER events in 900 ticks of nudging).
- **`AiGroupSpec.ranged_behind`** (appended, default false): in such a group `AiTactics.is_back` is true for any ranged or support member and any MEDIC, not only STANDOFF ones, so attack marches stop them 6 m short, legs judge arrival by the rest (`front(units, group)`), and the melee goes first for enemies near them (`threats`). Longbows and Sappers stay ASSAULT: an attack-moving archer stops at range to shoot by itself, and STANDOFF would have Sappers churn in and out of their 7 m dead zone. Phase 7's groups leave the flag off, and every Phase 7 test passes unchanged.
- **MEDIC** (appended to `UnitType.AiTactic`; the Warden's tactic). A member with herbs: the most wounded living friend within 20 m below 60% health that no other MEDIC of the group is already going to (`Interactions.order(..., HEAL)`, the HealCommand path), else a visible undead enemy within 8 m (a herb kills it), else in a fight it stands 6 m behind the front's centroid on its own side. Out of herbs it fights as ASSAULT. ADVANCE runs the errand every think, so the wounded are tended between fights too. `UnitType.validate` wants HEAL for MEDIC and now range-checks `ai_tactic`.

### The commander (`SkirmishCommander`)
- **Owned and hashed by `AiDirector`** (`commanders`; `hash_fields` appends their count, then each one's fields). Each thinks every 30 ticks, staggered by its id, before the groups, so its orders are planned the same tick. No random numbers; ties go to the nearer, then the lower index. Each think reports a COMMANDER event (its main group, objective, posture, flag).
- **Strength** is Σ cost × hp / max_hp in permille-points, the budget's own currency. Its own units count submerged or not; enemies only if seen. **Threat** is the larger of the enemy strength within 40 m of the objective and within 40 m of its main group.
- **Objective:** the hill (King of the Hill); the flag not its own that minimizes distance × (own + 2 × guard) / own, kept until it is owned or another costs under 70% of it, and with every flag its own the one nearest the enemy (Capture the Flags); the map's centre between the starts, then the enemy's densest knot (`ClusterFinder`, 20 m) once its whole strength is 1.1 times the enemy's, or it is behind or desperate (Body Count).
- **Postures** (held at least 10 s, except to commit on an unguarded objective, out of desperation, or to stage for a new flag):
  - **STAGE:** advance to a point short of the objective on its own side, at max(40 m, the longest enemy reach + 8 m), past its 25 m engage radius, so a staged army doesn't go for the enemy standing on the objective and Longbows at 50 m can't reach it. Bleeding there with nobody to fight: commit if at least 0.8 times the threat, else 20 m further back (up to 60 m).
  - **COMMIT:** onto the objective (hold radius the flag's less 2 m), engage radius 25 m; the raiders FLANK. Entered when gathered (70% of its strength near the staging point) and its local strength is at least the required ratio of the threat: 1.25 to take a held objective, 0.9 in Body Count's open field, easing as the clock runs toward 0.7 when behind on score (1.0 when level), or at once when the objective is unguarded or it is desperate (behind or level with under a quarter of the clock left, and at least the last minute).
  - **Fall back** from COMMIT below 0.8 of the threat: a plain-move advance to the staging point, so fighters finish their fights rather than being pulled out (a GUARD re-anchor's leash would have pulled them).
  - **DEFEND:** holding the objective and ahead: the raiders stay with the main group.
  - An emptied main group hands over to the raiders.

### Hash
`state_hash()` gains:
- **the skirmish** (`SkirmishRuntime.hash_fields`, only in a skirmish, after the mission): the rules, then the start, the winner and reason and tick, deaths, alive, hold and owned ticks, the rosters and the snapshot (each after its size), and each flag's owner, capture side and progress;
- **on `AiGroup`:** `engage_radius`, `hold_radius`, `march_attack`, at the end;
- **on `AiDirector`:** the commander count and each commander's fields. The director's hash is three words, not two, in a world with no groups.

Hashes from before Phase 9 aren't comparable. No test pins an absolute hash.

### RNG: none
The commander, ADVANCE, MEDIC and the skirmish rules draw no random numbers; `make check-sim` now bans `rng` under `sim/skirmish` as well as `sim/ai` and `sim/missions`. The App draws the AI's template (when the player leaves it to chance) and then the world's seed from its own generator before the world exists, so the world only ever sees a concrete army and seed.

### The skirmish screen (view)
- **`MissionLaunch.for_skirmish(setup)`**: `mission` and `deploy` null, tier 2, the setup's seed, `campaign_mode` on (no debug keys, a lost focus pauses; the Phase 8 comment that a skirmish would leave it off is corrected). `player_faction()` is the skirmish's choice, Light in the campaign.
- **`MainView`** builds the world with `SkirmishSetup.create_world`, starts the camera 15 m ahead of the player's army looking the way it faces (the camera sits on the +Z side of its focus at yaw 0, so the yaw is `atan2(-fx, -fz)`), applies the map's atmosphere, and sets `SelectionController.side` and `UnitsView.set_viewer` to the player's faction (a side already sees its own submerged units, and `_selectable` already wants `faction == side`, so that is all a Dark player needed). There are no `MissionStats` in a skirmish (`_freeze` checks), and the end is `skirmish_ended(outcome)`, not `mission_ended`.
- **`FlagsView`** (in the world): per flag the mode uses (none in Body Count, the hill in King of the Hill, all in Capture the Flags) a pole, a camera-facing banner and a ground ring at the capture radius, in the holder's `SideColors` (grey, blue, crimson). A banner climbs the pole as a capture progresses and sits at the top once owned; one being taken from its owner shifts toward the capturer's color; the contested hill flashes between the two sides, in real time, view-only.
- **`SkirmishHud`** (under the HUD, in the slot MissionHud's empty message line would use): always on, "King of the Hill · 7:32 · Hill: Light (you) 1:12 · Dark 0:48" (and the like for the other modes); on **F7** (`InputBindings.TOGGLE_SCOREBOARD`) a scoreboard with, per side, the player's first, alive of deployed, lost, enemy killed and the mode's score, and in Capture the Flags who owns each flag.
- **Elsewhere:** the overhead map draws the same flags (`setup(terrain, camera, world)`); the control bar's status line reads "You (Light) 14 · Enemy (Dark) 11 alive" and counts both armies in full (a Dark player's enemies are AI-led Light units); MissionHud shows an amber Draw; the F5 overlay draws an ADVANCE group's anchor and engage and hold circles, and each commander's line to its objective, its staging circle and its posture. Every one reads the world and never writes it (tests check the hash).

### The front end
- **Main menu → `SkirmishMenu` → the skirmish → `SkirmishResults`**, then Rematch, Change army or Main menu. Nothing is saved but the last setup chosen.
- **`SkirmishMenu`**, one screen: radio rows for map, mode, time, budget, side, start (A or B) and the enemy's army (Random or one of that side's templates), and the army builder: per buyable type of the player's side, the role, hp, cost, − count +, and the points; the points left (red when over), the count against 60, a Fill button per template and Clear. Start is on only for an army that validates. Choosing the other side swaps in that side's Balanced army; a new budget keeps the counts. It emits the player's half of a `SkirmishSetup` and the enemy choice.
- **The App resolves the rest:** the enemy's template (a random choice drawn from `App.rng`), its army filled at the budget, and the world's seed (63 bits, as for a campaign), in that order, so one `App.rng` seed always makes the same skirmish. Rematch keeps both armies and draws a new seed on a copy of the setup; the pause menu's Restart asks, then replays the same seed. The skirmish's signals are wired by launch kind; `mission_ended` stays the campaign's.
- **`SkirmishResults`**: Victory, Defeat or Draw, why (time ran out, or a side was wiped out), the time played, the mode's final score per side, and per side each type's deployed and lost from the runtime's frozen snapshot, with the AI template's name.
- **Remembered setup:** `GameSettings` gains a `[skirmish]` section (typed int and String keys) holding the last choice and army ("shieldman:10,longbow:4" with its side). A remembered value that no longer fits is ignored on its own and the rest kept.

### Playtest and balance (`make skirmish-playtest`)
- **The harness** (`scripts/skirmish_playtest.gd`, `scripts/playtest/skirmish_runner.gd`, `skirmish_result.gd`, `skirmish_report.gd`) builds every world through `SkirmishSetup.create_world`, so a run's settings and seed reproduce in the game. Settings are environment variables (MATRIX, MAPS, MODES, SEEDS, SEED_BASE, BUDGET, MINUTES, PILOTS, PAIRINGS, DARK_TEMPLATES, LIGHT_TEMPLATES, STARTS, RAW, REPORT, OUT, TRACE); an unknown value stops it with exit 1 rather than running a subset. Runs split across processes and `REPORT` merges their RAW files.
- **Matrix A**, commander against commander (`player_is_ai`): every Light template against Dark Balanced and Light Balanced against every Dark template, every map and mode, from both starts. It is the one measure of the sides under equal control. It measures the AI's two-group layout on both sides, not a human's single deploy block.
- **Matrix B**: Phase 8's `PlaytestPilot` plays Light against the Dark commander. The pilot gained a mission-less path: `set_route(points, hold_at_end)`, the competent pilot then plays the generic march (never The Ford's escort or Old Mill's ramps), and at the end of its route it holds (King of the Hill: the hill; Capture the Flags: every flag nearest first, then the hill) or hunts (Body Count, from the centre). The campaign playtest gives identical result lines before and after. `PlaytestRunner` reports a DRAW as a draw.
- **What the pass found and changed** (`docs/phase9-playtest.md` has every table): at the first-guess costs Light won 97% of A and the pilots 94 to 100%, because a Light unit is worth about three Dark ones (a Shieldman's shield takes Husks six for one). Light costs roughly doubled, which keeps Dark's hordes under the cap at 1500 points; per type Rippers came down and Stormcallers and Drifters up; the Raiders template keeps more Husks. The Ford's Capture the Flags (Light 11%) was the map: its flags moved to the ford's landings. Final, 612 runs: A 53% Light, every map and mode 36 to 64%, the worst pairing 86% (Shield Wall against Balanced); B 60% for the competent pilot and 62% for the naive one.
- **The two pilots play alike in a skirmish** (within a few points at every cost tried), so Matrix B's naive target (20 to 50%) can't be met by costs: the costs were tuned to A, and B is reported as it is.

| Unit | Cost | Unit | Cost |
|---|---|---|---|
| Shieldman | 68 | Husk | 20 |
| Reaver | 68 | Ripper | 22 |
| Longbow | 95 | Blightbag | 40 |
| Sapper | 100 | Drifter | 44 |
| Warden | 98 | Stormcaller | 88 |

### Decisions
- **Tim chose** (plan approval, 2026-10-06):
  - **The player picks a side, Light or Dark.** So the commander drives either faction (and MEDIC exists so an AI Light army uses its Wardens), and the view takes the player's side from the launch.
  - **Costs tuned by a playtest pass,** the Phase 8 method.
  - **Body Count scores every enemy death, whatever the cause.** Friendly fire scores for the other side; fire and gas deaths, which often have no credited killer, count.
- **Defaults in the approved plan:** the same budget both sides and no skirmish difficulty (worlds at tier 2); elimination ends any mode; draws at the limit (Capture the Flags breaks a tie by flag-ticks); 5 s alone captures a flag, which stays owned until taken; budgets 600 / 1000 / 1500, limits 5 to 20 minutes, a 60-unit cap; the AI's army from templates, "Random" resolved by the App; no fire arrows, satchels or Blightbag T for the AI; Longbows and Sappers stay ASSAULT; `sim/skirmish/` joins the rng ban.
- **From the plan's review** (an adversarial pass over the draft before any code): one main group plus raiders, not separate melee and ranged groups (the per-group tactics need them together); a new ADVANCE behavior rather than re-anchoring GUARD (whose leash and provoked rule would have yanked fighters and flipped groups to HUNT); the commander's thresholds with hysteresis, a 10 s minimum per posture and an urgency ramp, because two equal commanders otherwise both wait; staging past the engage radius and Longbow range; the scores and an alive snapshot frozen at the decision; `type_list` in a sorted order.
- **Rulings during the build,** each with its reason and its cost if wrong:
  - **Staging moved out to 40 m and the engage radius in to 25 m** after a test: at 30 and 30 a staged army went for the enemy standing on the hill. Cost: a staged army reacts later to an enemy coming at it from the objective's side.
  - **The skirmish world's tier is 2** and nothing in skirmish reads it but the AI's own groups, which spawn the same at every tier.
  - **The fairness test compares path lengths,** for living and undead units, within 15%. It doesn't see water slowdown or a crossing's funnel, which the playtest shows matter on the river maps (Light wins 38% from Riverside's start A and 69% from B, commander against commander). Each map averages inside the targets and the player picks the start, so the starts stay. Cost: a player who always takes start A on Riverside as Light has a harder game.
  - **The Ford's Capture the Flags flags moved to the landings** rather than repricing anything: only that map and mode was off, and by a mechanism (the dead wade anywhere) no price fixes.
  - **Light costs went up rather than Dark's down,** to keep Dark's hordes under the 60-unit cap at 1500 points. Cost: a Light army is small (12 units at 1000 points against 30 to 45).
  - **The "before" record is one seed per cell** (198 runs); the full 612-run matrices were run for the after record only.
  - **The subagents' commits keep their own attribution** (Claude Sonnet 5.5): the match view, the front end and the harness were written by parallel agents in their own worktrees and reviewed before they were applied.

### Behavior changes to earlier phases
- **`MissionRuntime.Outcome` gained DRAW and `MissionEvent.Kind` gained DRAWN** (appended). Only `conclude()` sets them; no campaign mission can draw. MissionHud shows an amber Draw; `PlaytestRunner` reports a draw instead of a timeout.
- **`AiTactics.front`, `behind` and `threats` go through `is_back`,** which is the old STANDOFF test unless a group's spec sets `ranged_behind`. Every Phase 7 and 8 AI test passes unchanged.
- **The Warden's `ai_tactic` is MEDIC.** `ai_tactic` is read only by the AI, so a player's Wardens and the campaign are unchanged; the pinned shipped-tactics test changed on the Warden line only (approved in the plan).
- **Every buyable unit type has a `cost`;** the villager has none.
- **The director's hash has a commander count,** and AiGroup's three new fields, so every world's hash differs from Phase 8's; no test pins one.
- **`World.step()` has a step 2b** (the skirmish), and `World` has `skirmish` and `start_skirmish`.
- **The main menu's Skirmish opens the skirmish screen;** the Phase 8 stub ("Skirmish arrives in Phase 9") is gone, and its tests were replaced (approved). `test_app.gd`'s App gets a skirmish catalog over the tiny test map.
- **`MissionLaunch.campaign_mode` is on for a skirmish too** (its comment said a skirmish would leave it off).
- **CLAUDE.md** gained `sim/skirmish/` in the folder layout, the skirmish spawns and flags under `maps/`, F7 under Controls, and the skirmish rules.
- **`make check-sim`** bans `rng` under `sim/skirmish` too.

### Measured (M4 Max)

| Scenario | Result |
|---|---|
| Playtest, final, 612 runs (`docs/phase9-playtest.md`) | A: Light 53%, Dark 46%, draws 1%, 93% decided by elimination, median 2.4 min; B: competent 60%, naive 62% |
| Playtest, before (first guesses), 198 runs | A: Light 97%; B: competent 100%, naive 94% |
| A skirmish headless | 1.7 to 2.4 ms a tick alone with 45 to 50 units (25 to 40 a side), 4 to 6 ms with 14 processes sharing 14 cores; a 10-minute run that goes to time about 30 s alone |
| The full matrices | 38 minutes for 612 runs on 14 processes, the machine otherwise busy |
| Windowed (`make capture-skirmish`, GL Compatibility on Metal, 1152x648) | The setup screen, the score line, the F7 scoreboard, the flags on the map and the overhead map, a battle and the Victory banner all drawn as designed, as Light and as Dark. Frame rates weren't measured: the capture steps the sim as fast as it can, and a window macOS hasn't brought forward draws irregularly |
| Determinism | Two worlds from one setup hash alike every 500 ticks over 1500, for three map-mode pairs and a Dark player, with identical AI event logs; commander logs pinned the same way |
| Test suite | 1974 tests in 106 scripts, all passing, with `check-sim` ok; about 170 s |

### Not yet
- **Skirmish difficulty or a handicap.** Both sides get the same budget, and the commander has one temper. The pilots win about 60% against it; a player should do better. A budget handicap, or the commander's thresholds per tier, would be the levers.
- **The AI using fire arrows, satchels or Blightbag T,** and a Dark pilot for Matrix B (a Dark player's challenge is estimated from Matrix A only).
- **The starts on the river maps.** Light does better from Riverside's start B and The Ford's start B (see Decisions). A fairness check that weighs water and chokes, or hills placed at the crossings, would even them.
- **Shield Wall is the strongest Light army** (86% against Dark Balanced, commander against commander, at the 85% line). If it plays dominant, Shieldman and Longbow are the prices to move.
- **Skirmishes are short:** most end by elimination in 2 to 4 game minutes, one decisive fight, because both commanders go for an unguarded objective at once and armies don't come back. The mode decides where the fight is more than how long it lasts.
- **Weather in skirmish, more than two sides, remembering a separate army per side, friendly-fire counts on the results screen,** and a lockstep pause command (still the view not stepping).
- **`make capture-skirmish` needs the window in front:** macOS doesn't draw a window it hasn't brought forward, and a shot then waits up to 2 s for a frame and saves what there is.
