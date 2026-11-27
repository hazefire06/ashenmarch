# Phase 12: The Corner Map Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** an always-on top-right map that shows your troops, spotted enemies and fading last-seen marks.

**Architecture:**
- **Spotting:** a pure, display-only function in `sim/units/visibility.gd`, driven by a new data field `UnitType.sight_radius`. Nothing in the sim step calls it, and nothing hashed changes.
- **Memory:** a small view-side model (`view/hud/spotting_memory.gd`) holds what is spotted now and the last-seen marks.
- **Map control:** `view/hud/minimap.gd` draws the Tab map's terrain image (shared builder) plus the dots, and routes clicks the way OverheadMap does.

**Tech Stack:** Godot 4.7, GDScript (static typing), GUT.

**Spec:** `docs/specs/2026-11-26-phase-12-minimap-design.md`

## Global Constraints

- No edits to the sim step or to anything `state_hash()` covers. `make verify-replays` must print ok=4. If adding `sight_radius` changes any hash or a golden, stop and report; don't re-record.
- Integer and fixed-point maths in `sim/`, with no RNG and no Nodes.
- Static typing everywhere; one class per file with `class_name`; `@warning_ignore` only with a reason.
- Unit stats are data: sight ranges live in `data/units/*.tres`, not in scripts.
- GUT: never pass `-d`. Read GUT's output, not its exit status.
- macOS export must run. The Web build must not regress.

## Review Focus

1. **A unit on a ridge top** looking down the far side: it should see over the crest. The sight line runs eye to body centre, so the near crest must not block the target.
2. **An enemy right behind The Ford's wall:** it is unspotted from the other side, but spotted from on top of the gate opening.
3. **The last viewer dies** while an enemy is spotted: the enemy turns into a fading mark, not a dot that stays.
4. **Map clicks while an order is armed** (attack-move or ground-target): the click goes the same way as on the Tab map, and the camera doesn't jump unexpectedly.
5. **Small windows (1280×720) and the UI scale:** the map, the objectives panel and the toasts don't overlap.

---

### Task 1: Sight data, `spotted_by`, and the spotting memory

**Files:**
- Modify: `sim/units/unit_type.gd` (add `@export var sight_radius: int = 50000` beside `acquire_radius`, with a doc comment saying it is display only and the sim step never reads it), `data/units/longbow.tres` (`sight_radius = 60000`).
- Modify: `sim/units/visibility.gd`, adding `static func spotted_by(world: World, unit: Unit, viewer: UnitType.Faction) -> bool` and `static func clear_sight(world: World, from_unit: Unit, to_unit: Unit) -> bool`.
- Create: `view/hud/spotting_memory.gd` (`class_name SpottingMemory`, RefCounted).
- Tests: `tests/sim/test_visibility_spotting.gd`, `tests/view/test_spotting_memory.gd`.

**Interfaces:**
- Produces:
  - `Visibility.spotted_by(world, unit, viewer) -> bool`. True for the viewer's own units. Otherwise `seen_by` must hold, and some living unit of the viewer's side must be within its type's `sight_radius` (horizontal, milli-units) with `clear_sight`.
  - `Visibility.clear_sight`: march from the viewer's eye (`body_height` above its ground) to the target's body centre (half `body_height`), one terrain sample per cell, in integer maths. Blocked if the terrain height at any intermediate sample is above the line.
  - `SpottingMemory`:
    - `FADE_TICKS: int = 300` (10 s at 30 ticks/s);
    - `update(world: World, viewer: UnitType.Faction) -> void`;
    - `spotted() -> PackedInt32Array` (unit ids spotted now);
    - `marks() -> Array[Dictionary]` with keys `position: Vector2` (map metres x,z) and `alpha: float` (1 → 0 over FADE_TICKS since last seen);
    - `clear() -> void`.
    - A re-spotted unit drops its mark. A dead unit's mark is dropped. A mark is created when a spotted enemy leaves sight.

- [ ] **Step 1:** Write the failing tests:
  - in range and clear, true;
  - beyond `sight_radius`, false;
  - a crest between them, false;
  - The Ford's wall slab between them, false (build a small Terrain with a raised strip);
  - over a crest from a ridge top, true;
  - a submerged Husk outside `reveal_radius`, false;
  - own units, true;
  - only dead viewers, false;
  - for the memory: fade alpha at 0, 150 and 300 ticks; re-spot removes the mark; death drops the mark.
- [ ] **Step 2:** Run them and see them fail: `godot --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://tests/sim/test_visibility_spotting.gd -gexit` (and the memory file).
- [ ] **Step 3:** Implement. `spotted_by` is O(viewers) per unit. `SpottingMemory.update` is meant to run every 8 ticks.
- [ ] **Step 4:** Run the tests until they pass. Then run the full suite once and `make verify-replays`, expecting ok=4.
- [ ] **Step 5:** Commit: "Add display-only spotting with sight ranges".

### Task 2: The corner map, layout and setting

**Files:**
- Create: `view/hud/minimap.gd` (`class_name Minimap`, Control).
- Create: `view/hud/map_image.gd` (`class_name MapImage`), extracting OverheadMap's hillshade and water-tint image builder so both maps share it. OverheadMap then calls it.
- Modify:
  - `view/hud/overhead_map.gd` to use MapImage. Its behaviour must not change; its existing tests must still pass.
  - `view/main.gd` and `view/main.tscn` to add `$Hud/Minimap`, feed it the world, camera, selection, viewer side and flags, run `SpottingMemory.update` every 8 ticks in `_advance()`, and hide it while the Tab map is open.
  - The ObjectivePanel layout, which moves below the minimap, right-aligned.
  - `view/settings/settings.gd` and `settings_menu.gd`: Interface gets "Corner map", on by default.
- Tests: `tests/view/test_minimap.gd`, plus the existing overhead map, HUD and settings tests.

**Interfaces:**
- Consumes: `SpottingMemory` and `Visibility.spotted_by` (Task 1); OverheadMap's click routing (move, attack-move with Cmd/Ctrl, route point with Shift, order button = right click or Option-click; `click_at` for the pad cursor). Reuse it, don't copy it: extract a shared helper if needed.
- Produces:
  - `Minimap.SIZE_PX: int = 220`, scaled by the UI scale;
  - `Minimap.map_to_local(p: Vector2) -> Vector2` and `local_to_map(p: Vector2) -> Vector2`, north-up like OverheadMap;
  - `Minimap.click_at(local: Vector2, button: MouseButton, mods: int) -> void`.
- Draws:
  - your units: green dots, white when selected;
  - spotted enemies: red;
  - marks: dim red × alpha;
  - the camera's ground footprint: the four screen corners raycast to the ground plane at the focus height;
  - skirmish flags, as on the Tab map;
  - a thin border.
- Viewer side: the commanding side, or the replay's watched side.

- [ ] **Step 1:** Write the failing tests:
  - the coordinate round trip;
  - a left click moves the camera focus;
  - a right click issues the same command OverheadMap would (compare the queued commands);
  - the minimap is hidden while the overhead map is visible;
  - the ObjectivePanel's top is at or below the minimap's bottom at 1280×720 and at 1920×1080;
  - the setting off hides it.
- [ ] **Step 2:** Run them and see them fail.
- [ ] **Step 3:** Implement. Draw in `_draw()`, queue a redraw on spotting updates and when the camera moves, and build the image once per map load.
- [ ] **Step 4:** Run the tests until they pass, then the full suite.
- [ ] **Step 5:** Run `CAPTURE=<workspace>/capture SECONDS=20 make capture` and look at every mission's opening and battle shots: map top-right, objectives below it, dots right, no overlap.
- [ ] **Step 6:** Commit: "Show an always-on corner map with spotted enemies".

### Task 3: Budget, docs, PR

- [ ] **Step 1:** Run `make budget` on macOS and compare it with main; the frame rate must be within 5%. If it isn't, throttle the redraws.
- [ ] **Step 2:** Docs:
  - CLAUDE.md Controls gets a line on the corner map;
  - `docs/prompts.md` gets a Phase 12 entry;
  - architecture.md gets a note that spotting is display only.
- [ ] **Step 3:** Run every check: the full suite, `make verify-replays` ok=4, and `make export-mac`.
- [ ] **Step 4:** Commit. Then write the PR body to the workspace (it ends with "🤖 Generated with [Claude Code](https://claude.com/claude-code)") and give Tim the `!` push and PR commands.
