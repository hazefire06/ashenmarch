# Phase 12: the corner map

Status: draft, 2026-11-26. Branch `feature/PHASE-12-minimap`, worktree `~/Projects/ashenmarch-minimap`, from `main` at b97cbab. Runs in parallel with A5 (world art).

## Why

Tim: "I want a small 2D map to always be displayed in the upper right hand corner. It doesn't show enemy positions unless you have spotted them, but it does show your location of troops on the map."

## Decisions (Tim, 2026-11-26)

- **Spotting:** an enemy is spotted when it is within the sight range of any of your living units and the line between them isn't blocked by a hill crest or a wall. A submerged undead stays unspotted unless `Visibility.seen_by` already lets you see it.
- **Memory:** an enemy that leaves sight leaves a dim last-seen mark that fades over 10 s.
- **Layout:** the map sits in the top-right corner, and the objectives panel moves to just below it.
- **Branch:** its own branch, built in parallel with A5.

## Design

### Spotting (sim side, pure, display only)

- **New field:** `UnitType.sight_radius`, in milli-units like `acquire_radius`.
  - Default 50 m. The Longbow gets 60 m; flying and caster types use the default.
  - It is data, per the data-driven rule. The sim step never reads it.
- **New function:** `static func spotted_by(world: World, unit: Unit, viewer: UnitType.Faction) -> bool` in `sim/units/visibility.gd`.
  - It is true when `seen_by` is true and some living unit of the viewer's side is within its `sight_radius` (horizontal) with a clear sight line.
  - **Sight line:** march the terrain height from eye height (`body_height`) to the target's body centre, one sample per cell. It is blocked if the ground rises above the line. Walls and Old Mill's slab are already in the sim's heights, so they block too.
  - It uses only integer and fixed-point maths, with no RNG.
- **Nothing hashed changes:** spotting is a pure function that nothing in the sim step calls. `state_hash()` is unchanged, and `make verify-replays` must print ok=4. If adding the field to UnitType changes a hash, the plan stops and reports before re-recording anything.

### The corner map (`view/hud/minimap.gd`, class `Minimap`)

- **Placement:** always shown, top-right, about 220 px square (scales with the UI scale), drawn over the 3D view with a thin border.
- **Terrain:** the same shaded, water-tinted image as the Tab map (shared builder, built once per map load) and the same north-up axes.
- **What it shows:**
  - your units as green dots, white when selected;
  - spotted enemies as red dots;
  - last-seen marks as dim red dots fading over 10 s;
  - the camera's view as an outline of what the screen shows on the ground;
  - skirmish flags, the same as on the Tab map.
- **Clicks:** the same as the Tab map:
  - a left click moves the camera;
  - the order button (right click, or Option-click) sends the selection there as a move in formation;
  - Cmd/Ctrl gives an attack-move; Shift gives a route point;
  - the pad cursor clicks it through `click_at`.
- **Viewer:** the commanding side. In a replay, the side the replay is watched from.
- **Refresh:** spotting is recomputed every 8 ticks (about 0.27 s), not every frame. Dots are drawn at the latest positions of the units that are spotted now.
- **Tab map:** the corner map is hidden while the Tab map is open. The Tab map itself is unchanged: it shows your units only.

### Layout

- `ObjectivePanel` moves below the corner map, right-aligned, with the same margin.
- Nothing else in the HUD moves. Toast messages stay top-centre.

### Settings

- Settings > Interface gets a "Corner map" toggle, on by default. Tim asked for "always", but a toggle costs nothing.

## Testing

- **GUT tests for `spotted_by`:**
  - in range with a clear line;
  - out of range;
  - blocked by a crest;
  - blocked by a wall's slab;
  - a submerged Husk, unspotted unless within `reveal_radius`;
  - your own units always seen;
  - dead viewers don't spot.
- **GUT tests for the memory:**
  - the fade reaches 0 at 10 s;
  - a re-spotted unit replaces its mark;
  - a dead unit's mark is dropped.
- **GUT tests for the corner map:**
  - the map-to-minimap coordinate transform round-trips;
  - clicks route the same way as on the Tab map;
  - the objectives panel sits below the map.
- **Whole-project checks:** the full suite; `make verify-replays` ok=4; a `make capture` shot of each mission, looked at by eye; `make budget` frame rate within 5%.

## Out of scope

Fog of war in the 3D view, enemies hidden on screen, and the AI's use of sight. Spotting is display only for now. A real fog of war would be a sim change and its own phase.
