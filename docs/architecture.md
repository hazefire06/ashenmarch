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
- Heights are milli-units, stored as `PackedInt32Array`.

### Queries (all integer)
- **`height_at(x, z)`**: bilinear between the four surrounding samples, rounded half up. Off-map points clamp to the edge.
- **`gradient_at(x, z)`**: the exact derivative of that bilinear surface, `(dh/dx, dh/dz)`, as a `Vector2i`.
  - Units are permille: millimetres of rise per metre of run, so 1000 = 45°.
  - It uses the cell containing the point. Cells are half-open.
- **`slope_at(x, z)`**: the magnitude of the gradient, via `FixedMath.isqrt`.
  - `isqrt` takes a float starting guess and corrects it to the exact floor, so the result never depends on float rounding.
- **`water_depth_at(x, z)`** and **`is_passable(x, z, mobility)`**: use the nearest sample, so a point query always agrees with the sample grid that pathing will run on. `is_sample_passable(i, j, mobility)` is the grid form.
- **Passability slope**: uses a per-sample central-difference slope (`sample_slopes`, precomputed at load), not the bilinear gradient.

### Mobility
`UnitType` arrives in Phase 2, so passability takes `Terrain.Mobility` instead. Phase 2's `UnitType` gets a `mobility` field.

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
