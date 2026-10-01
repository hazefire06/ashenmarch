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
  - **G**: ground type × 50, decoded to the nearest type: 0 grass, 50 brush, 100 wood, 150 sand, 200 rock (Phase 5). 0 is grass, the normal case, as R = 0 is dry.
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
  - `wind_x`, `wind_z`: mm/s. **Visual only**; nothing in the sim reads it.
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
- **Schedules are commands.** A `WeatherSchedule` is `WeatherChange`s in strictly ascending tick order. `commands()` turns them into `SetWeatherCommand`s that are enqueued at mission start, like the spawns, so a replay's command stream carries the weather. Phase 7's "set weather" trigger will call `change_to()` directly.
- **Riverside test schedule** (`data/weather/riverside_showers.tres`):
  - a breeze;
  - showers at 70 % from 45 s;
  - a downpour at 2 min;
  - clearing at 3 min.

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
- **Water, no dice.** A lit fuse that touches water of depth ≥ 1 (a bounce, a roll step, coming to rest) goes out at once (FIZZLE, with `depth`). The grenade is a dud, which a blast or a fire can still set off. A fire arrow landing in water lights nothing, because water cells can't burn.
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
3. **Burn-outs:** from a bucket keyed by tick.
4. **Damage**, on its interval: units in ascending id.
5. **Explosives:** projectiles in ascending id.

**Cost.** Only the front does spreading work and burn-outs are bucketed, so the cost per tick tracks the fire's edge, not its area. Front membership changes how much work a tick does, never what happens, so it isn't hashed.

**Hash.**
- `hash_fields()`: the burning cells (index, burn-out tick, lighter).
- `World.state_hash()` adds the dense state bytes.
- The grid is allocated on the first fire, so a world that never burns carries none.

### Visibility
- **`Visibility.is_submerged`** is `MeleeCombat.is_hidden` moved, unchanged. Submerged units can't be targeted or hit by anyone.
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
  - Enqueues the schedule at tick 0, and adds the `Fire` and `Precipitation` views.
  - Feeds the terrain the fire and weather after every step.
  - The stats line shows rain, snow, wetness, cover, and burning cells.
  - **F6** (debug) cycles clear → rain → heavy rain → snow through a `SetWeatherCommand` ramped over 3 s.

### Measured (M4 Max, headless)
| Scenario | Result |
|---|---|
| Riverside ford battle (34 units) plus five grass fires lit at tick 0, clear for 30 s (about 1,250 cells burning) | 1.80 ms/tick mean, 7.5 ms worst (the Phase 4 aiming spikes) |
| The same as heavy rain arrives | Every fire out within 15 s; 1.04 ms/tick |
| `state_hash()` with the 512² fire grid | 0.66 ms |
| Lockstep test: the ford battle with fire arrows into the grass and rain from tick 450 | Hash-identical across worlds; 2.05 ms/tick per world |

### Not yet
- Units don't path around fire (Phase 7 AI).
- No Burning status on units (Phase 6).
- Blasts and lightning don't light grass.
- Wind doesn't push fire.
