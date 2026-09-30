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
- Unit commands (Phase 2): `SpawnUnitCommand` (type id, side, position, facing), `MoveUnitsCommand` (unit ids, target, formation), `StopUnitsCommand` (unit ids). Group commands sort and dedupe their ids and skip missing or dead units, so the order the player selected in doesn't matter.
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
  - Combat: melee and ranged stats, abilities.
  - View only: placeholder color and sprite.
- Gameplay fields are integers. Required ones default to 0 and `validate()` rejects 0, for the same `.tres` reason as `MapInfo`.
  - Validation also rejects a water table with 0 speed at a depth the mobility can enter, which would strand the unit there.
- **`UnitCatalog`** (`data/units/catalog.tres`) is an explicit, ordered list. Units hash their catalog index. A directory scan would break in exports, which rename `.tres` files to `.res` plus `.remap`.

### Unit entity
- **`Unit extends SimEntity`**: type, side, hp, facing, state, current order, and path.
  - Facing is a direction vector of length `FixedMath.DIR_ONE`.
  - State is IDLE, MOVING, ATTACKING or DEAD. ATTACKING is reserved for Phase 3; DEAD is terminal.
- `SimEntity.hash_fields()` feeds `World.state_hash()`. `Unit` appends every field, path included, and the path queue is hashed too.
- **World step order:** commands → `UnitMovement.update()` → integrate.
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
- **Speed per tick** = type speed (capped at the group's slowest member) × water table[depth] × uphill factor.
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
- **Spawns:** `MainView` spawns the test squads as tick-0 commands (20 Shieldmen north of the ford, 20 Husks south of the creek). Phase 8 replaces this with mission data.
