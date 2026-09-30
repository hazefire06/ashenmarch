# Architecture notes

Decisions made in Phase 0 that later phases build on. CLAUDE.md has the rules; this file records how they're implemented and why.

## Tick model
- `World.TICK_RATE = 30`. One call to `World.step()` simulates one tick.
- The view calls `step()` exactly once per `_physics_process` and sets `Engine.physics_ticks_per_second` from `World.TICK_RATE`. Godot's physics loop is the fixed-step accumulator, and the sim never sees a frame delta.
- Consequence: Godot physics (cosmetic gibs/debris only) also runs at 30 Hz.
- If a frame hitches past Godot's `max_physics_steps_per_frame` (8), the sim slows down rather than skipping ticks.

## Fixed-point units
- Positions are integer milli-units (`World.UNITS_PER_METER = 1000`). Velocities are milli-units per tick.
- Stored as plain `int` (64-bit), not `Vector3i`, whose 32-bit components overflow in fixed-point multiplies.

## Commands
- Every outside change to the sim is a `SimCommand` subclass in `sim/commands/`. Each carries the `tick` it applies at.
- Unit commands (Phase 2): `SpawnUnitCommand` (type id, side, position, facing), `MoveUnitsCommand` (unit ids, target, formation), `StopUnitsCommand` (unit ids). Phase 3 adds `AttackMoveCommand` (same fields as a move). Group commands sort and dedupe their ids and skip missing or dead units, so the order the player selected in doesn't matter.
- `World.enqueue()` rejects ticks already simulated. At the start of each tick, that tick's commands apply in enqueue order.
- Commands are immutable data. A command targeting a missing entity is a no-op.
- This is the stream that lockstep multiplayer and replays will serialize. Serialization is not built yet.

## Randomness
- Gameplay randomness comes only from `World.rng`, a `RandomNumberGenerator` seeded in `World._init`. Use its integer methods (`randi`, `randi_range`) in sim code.
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
  - **G**: reserved for ground type (fire spread, Phase 5).
  - **B**: ≥ 128 means blocked for every mobility.
- Riverside is generated by `scripts/gen_riverside.gd` (`make maps`). The PNGs are committed as the source of truth. The generator uses floats and `FastNoiseLite`, which is fine because it runs offline, not in the sim.

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
  - F9 (debug, until the AI exists) switches the side the mouse commands.
  - Godot key actions match events with extra modifiers, so the number-key actions are checked with `exact_match`.
- **`ControlBar`** mirrors every command for mouse-only play: formation buttons, group slots (click to recall; Set, then a slot, to save), Stop, and Switch side.
- **Spawns:** `MainView` spawns the test squads as tick-0 commands (20 Shieldmen north of the ford, 20 Husks south of the creek; Phase 3 adds a row of 5 Reavers behind the Shieldmen and 5 Rippers behind the Husks). Phase 8 replaces this with mission data.

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
  - An enemy hidden in deep water (`hidden_in_deep_water` at depth 3+), until it surfaces to fight (state ATTACKING).
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
