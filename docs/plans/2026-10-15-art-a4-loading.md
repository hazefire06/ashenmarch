# Art track A4: unit art per roster and a Web texture budget — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load only the unit art a game can show, trim and pack the sheets losslessly, and prove in the Web export that the worst-case game fits in 1,000 MB of tab memory. Also start each unit's walk and idle loops at its own frame.

**Architecture:**
- **Budget check.** A `BudgetRun` mode (`?budget=1`, `-- --budget`) plays the worst case and reports memory. It is built first, so today's build gets measured.
- **Packing.** `make art-build` packs the renderer's grid sheets (moved to `art-src/units/<id>/sheets/`) with a pure `UnitArtPacker`. The builder turns each packed frame into an `AtlasTexture` whose margin restores the full cell, so the sprite code is unchanged.
- **Loading.** The catalog holds paths. `MissionLaunch.unit_types()` feeds a `UnitArtSet` that preloads the launch's types before the first frame.

**Tech stack:** Godot 4.7.2, GDScript, GUT; Python 3 and headless Blender for the renderer's tests; Chrome through the chrome-devtools MCP for the Web measurement.

**Spec:** `docs/specs/2026-10-15-art-a4-loading-design.md`. Read it with this plan.

## Global Constraints

- Work in `~/Projects/ashenmarch-a4` on `feature/PHASE-A4-art-loading` only.
- Never read `~/.config/ashenmarch`. Never run `scripts/art/meshy.py` `candidates`, `build`, `prop-candidates` or `prop-build`: they are paid, and Tim runs them.
- `sim/`, `data/units/` and `data/replays/golden/` don't change. `make check-sim` passes and `make verify-replays` stays identical to `main`.
- GDScript conventions:
  - static typing everywhere;
  - one class per file, with `class_name`;
  - snake_case files and PascalCase classes;
  - `@warning_ignore` only with a comment saying why;
  - comments match the surrounding code's density and voice.
- Run GUT without `-d`. `make test` passes `-d`, which hangs on a script error, so:
  - all tests: `godot --headless --path . -s addons/gut/gut_cmdln.gd`;
  - one file: `godot --headless --path . -s addons/gut/gut_cmdln.gd -gconfig= -gtest=res://tests/view/<file>.gd -gexit`.
  - Run `make import` first when a `class_name` is new.
- Exact values from the spec:
  - budget: 1,000 MB of tab memory; worst case: Old Mill, every buyable type, 2 of each per side, 60 s (1,800 ticks), seed 1000;
  - padding 8 px, blocks 4 px, sheets at most 4096 px;
  - loop phase step 0.6180339887.
- Commits: an imperative one-line summary, and a body that says why. End every message with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Pushing and opening the PR: Tim runs those commands himself with `!`, because the prod-guard hook blocks commands that mention `main`.
- macOS has no `timeout` command; don't rely on it.
- `<scratchpad>` below means `/private/tmp/claude-501/-Users-timk-Projects-ashenmarch/b5725fc3-76c9-4523-8b76-6119db6f1285/scratchpad`, this session's scratch folder. In another session, use that session's.
- Keep git commands plain, one action each, with no `$(…)` or loops. The worktree guard refuses commands it can't verify.

## Review Focus

These five cases are implied by the spec but easy to leave untested. Each is pinned by a test in the task named.

1. **A figure touching its cell's edge** (the Reaver has 35 clipped frames) stays lossless, and stays at least 2 × 8 px from its neighbors in the packed sheet. Task 3: `test_figures_touching_the_cell_edge_keep_their_distance`.
2. **A stale packed sheet**, one whose size doesn't match the sidecar's `sheet_size`, is refused by the builder rather than cut in the wrong places. Task 5: `test_layout_rejects_a_stale_packed_sheet`.
3. **A planted symlink** in `assets/units/<id>/` or `art-src/units/<id>/sheets/` (the repo is public) makes the packer refuse before it writes anything. Task 5: `test_planted_links_are_found`.
4. **A page that can't measure its memory** (not cross-origin isolated, or Safari) reports UNKNOWN, never PASS. Task 1: `test_an_unread_page_is_unknown_not_a_pass`.
5. **A type the list missed, or broken art found mid-game**, warns once, then draws late art or a placeholder: no warning every frame, no crash. Task 6: `test_a_type_the_list_missed_loads_late_with_one_warning` and `test_broken_art_is_left_out_with_a_warning_per_reason`.

## Changes from the spec, decided while planning

- **No `RenderingServer.texture_debug_usage()`.** A probe showed Godot 4.7 doesn't expose it to scripts. Unit art bytes are computed from each sheet's size and `get_format()` (`UnitArt.texture_bytes`), the spec's own fallback, and the line says so.
- **The Web fallback is the JS heap alone.** Without cross-origin isolation the check reads Chrome's `performance.memory.totalJSHeapSize` only, labeled `fallback`: the wasm memory isn't reachable from the page. With neither, it reports `unknown` and the verdict is UNKNOWN.
- **Regions snap to 4 px in the cell, not just in size.** Each 4×4 DXT block then holds exactly the pixels it held in the grid, so full-size compression is unchanged. The sheet adds padding only where the cell's edge cut a region short. Two figures are still at least 16 px apart.
- **The lossless proof is the probe (Task 4) and a byte check of every committed frame (Task 5).** The Riverside captures can't be compared pixel for pixel: sprites animate on real time, and the capture fast-forwards as fast as the machine allows. They become a before-and-after for Tim's eye, with a new close-zoom shot.
- **ETC2 goes off in Task 2**, right after the before measurement, so the packed sheets' `.import` files are written once without it. ETC2 doesn't change runtime memory, so the before numbers stand.

## Files

| File | Change | Responsibility |
|---|---|---|
| `view/budget/budget_run.gd` | new | The budget check: worst-case setup, measurement, the line |
| `view/units/unit_art.gd` | modify | `texture_bytes`, `sheet_bytes`; `validate` checks each frame is a whole cell |
| `view/units/unit_art_catalog.gd` | rewrite | Unit id to UnitArt path, with no resources |
| `view/units/unit_art_set.gd` | new | One game's loaded art: preload, late load, validation |
| `view/units/units_view.gd` | modify | Draws from a `UnitArtSet`; `loaded_arts()` |
| `view/units/unit_animator.gd` | modify | `loop_start_frame` |
| `view/units/unit_sprite.gd` | modify | A new loop starts on the unit's own frame |
| `view/mission_launch.gd` | modify | `unit_types()` |
| `view/main.gd` | modify | Loads the launch's art; `art_load_ms`, `loaded_arts()`, `art_catalog_path` |
| `view/app/app.gd` | modify | Runs `BudgetRun` when asked |
| `scripts/art/unit_art_packer.gd` | new | Trimming, slots, shelf packing; grid checks (moved from the builder); symlink guard |
| `scripts/art/pack_unit_art.gd` | new | CLI: pack one unit's grid render into `assets/` |
| `scripts/art/pack_probe.gd` | new | Windowed proof that packed frames draw like grid ones |
| `scripts/art/unit_art_builder.gd` | modify | Builds from a packed sidecar |
| `scripts/art/build_unit_art.gd` | modify | Doc lines; lists the unit by path |
| `scripts/art/render_sprites.py`, `scripts/art/blender_test_render.py` | modify | Grids go to `art-src/units/<id>/sheets/`, with no `.import` |
| `scripts/capture_missions.gd` | modify | A close-zoom shot after the opening |
| `scripts/check_asset_layout.sh` | modify | The new LFS and plain paths |
| `Makefile` | modify | `art-build` (pack, import, build), `art-probe`, `budget`, `budget-app` |
| `project.godot` | modify | `import_etc2_astc=false` |
| `tests/support/test_art.gd` | modify | `grids()`, `pack()`; `art()` packs |
| `tests/view/test_budget_run.gd`, `test_unit_art_packer.gd`, `test_unit_art_set.gd`, `test_mission_launch_types.gd` | new | |
| `tests/view/test_unit_art.gd`, `test_unit_art_catalog.gd`, `test_unit_art_view.gd`, `test_unit_art_timing.gd`, `test_unit_animator.gd`, `test_main_view.gd` | modify | |
| `assets/units/<id>/*` → `art-src/units/<id>/sheets/` | move | The grids |
| `assets/units/<id>/*.png`, `<id>.json`, `data/art/*.tres` | regenerate | Packed |
| `docs/plans/2026-10-15-art-a4-measurements.md` | new | The raw `BUDGET` lines, before and after |
| `docs/architecture.md`, `docs/specs/2026-10-01-art-audio-design.md`, `docs/specs/2026-10-15-art-a4-loading-design.md`, `CLAUDE.md` | modify | Docs |

---

### Task 1: The budget check, and today's numbers

**Files:**
- Create: `view/budget/budget_run.gd`
- Modify: `view/units/unit_art.gd`, `view/units/units_view.gd`, `view/main.gd`, `view/app/app.gd`, `scripts/capture_missions.gd`, `Makefile`
- Test: `tests/view/test_budget_run.gd`, `tests/view/test_unit_art.gd`
- Create: `docs/plans/2026-10-15-art-a4-measurements.md`

**Interfaces:**
- Produces:
  - `static func UnitArt.texture_bytes(width: int, height: int, format: Image.Format, mipmaps: bool) -> int`
  - `static func UnitArt.texture_bytes_of(sheet: Texture2D) -> int`
  - `func UnitArt.sheet_bytes() -> int`
  - `func UnitsView.loaded_arts() -> Array[UnitArt]`
  - `var MainView.art_load_ms: int`, `func MainView.loaded_arts() -> Array[UnitArt]`
  - `class BudgetRun`:
    - `static requested() -> bool`, `static asked_in_query(search: String) -> bool`
    - `static worst_case_setup(units: UnitCatalog, skirmishes: SkirmishCatalog) -> SkirmishSetup`
    - `static verdict(tab_mb: float) -> String`, `static web_line(f: Dictionary) -> String`, `static desktop_line(f: Dictionary) -> String`
    - `var play_ticks: int`, `var line: String`, `var main: MainView`, `signal finished(line: String)`, `func start()`

- [ ] **Step 1: Write the failing tests for sheet bytes**

Append to `tests/view/test_unit_art.gd`:

```gdscript
func test_texture_bytes_count_blocks_and_mipmaps() -> void:
	assert_eq(UnitArt.texture_bytes(8, 8, Image.FORMAT_DXT5, false), 64, "four 16-byte blocks")
	assert_eq(UnitArt.texture_bytes(8, 8, Image.FORMAT_DXT5, true), 64 + 16 + 16 + 16, "8x8, then 4x4, 2x2 and 1x1 as one block each")
	assert_eq(UnitArt.texture_bytes(6, 2, Image.FORMAT_DXT1, false), 2 * 8, "a part block counts whole")
	assert_eq(UnitArt.texture_bytes(4, 4, Image.FORMAT_RGBA8, false), 64)
	assert_eq(UnitArt.texture_bytes(4, 2, Image.FORMAT_RGBA8, true), 32 + 8 + 4, "4x2, 2x1, 1x1")


func test_sheet_bytes_count_each_sheet_once() -> void:
	var art: UnitArt = TestArt.art()
	var sheets: Dictionary[Texture2D, bool] = {}
	for name: String in art.frames.get_animation_names():
		sheets[(art.frames.get_frame_texture(name, 0) as AtlasTexture).atlas] = true
	var expected: int = 0
	for sheet: Texture2D in sheets:
		expected += UnitArt.texture_bytes(sheet.get_width(), sheet.get_height(), Image.FORMAT_RGBA8, false)
	assert_eq(sheets.size(), 4, "idle, walk, attack and die")
	assert_eq(art.sheet_bytes(), expected)
```

- [ ] **Step 2: Run them; they fail**

Run: `godot --headless --path . -s addons/gut/gut_cmdln.gd -gconfig= -gtest=res://tests/view/test_unit_art.gd -gexit`
Expected: FAIL, parse error: `texture_bytes` not found in `UnitArt`.

- [ ] **Step 3: Implement them in `view/units/unit_art.gd`**

After the `TIMED_ANIMS` constant:

```gdscript
## Bytes a 4x4 block takes in each block-compressed format the importer can
## write, by Image.Format. Any other format is counted per pixel.
const BLOCK_BYTES: Dictionary[int, int] = {
	Image.FORMAT_DXT1: 8, Image.FORMAT_DXT3: 16, Image.FORMAT_DXT5: 16, Image.FORMAT_BPTC_RGBA: 16,
	Image.FORMAT_ETC: 8, Image.FORMAT_ETC2_RGB8: 8, Image.FORMAT_ETC2_RGBA8: 16, Image.FORMAT_ETC2_RGB8A1: 8,
	Image.FORMAT_ASTC_4x4: 16,
}
```

After `direction_index`:

```gdscript
## GPU bytes of a width x height texture in this format, with its mipmaps down
## to 1x1 when mipmaps is set: block formats by their 4x4 blocks, others by
## their bytes per pixel. What the budget check counts per sheet; a driver may
## round or pad.
static func texture_bytes(width: int, height: int, format: Image.Format, mipmaps: bool) -> int:
	var block: int = BLOCK_BYTES.get(format, 0)
	var per_pixel: int = 0
	if block == 0:
		per_pixel = Image.create_empty(1, 1, false, format).get_data().size()
	var total: int = 0
	var w: int = width
	var h: int = height
	while true:
		total += ceili(w / 4.0) * ceili(h / 4.0) * block if block > 0 else w * h * per_pixel
		if not mipmaps or (w == 1 and h == 1):
			break
		w = maxi(1, w >> 1)
		h = maxi(1, h >> 1)
	return total


## GPU bytes of one sheet, from its size and format (texture_bytes). An
## imported sheet (CompressedTexture2D) and an ImageTexture (tests, the pack
## probe) say their format; anything else counts as RGBA8.
static func texture_bytes_of(sheet: Texture2D) -> int:
	var format: Image.Format = Image.FORMAT_RGBA8
	if sheet is CompressedTexture2D:
		format = (sheet as CompressedTexture2D).get_format()
	elif sheet is ImageTexture:
		format = (sheet as ImageTexture).get_format()
	return texture_bytes(sheet.get_width(), sheet.get_height(), format, sheet.has_mipmaps())
```

After `has_anim`:

```gdscript
## GPU bytes of every sheet this art's frames are cut from, each counted once.
func sheet_bytes() -> int:
	if frames == null:
		return 0
	var seen: Dictionary[Texture2D, bool] = {}
	var total: int = 0
	for name: String in frames.get_animation_names():
		for i: int in frames.get_frame_count(name):
			var texture: Texture2D = frames.get_frame_texture(name, i)
			var atlas: AtlasTexture = texture as AtlasTexture
			var sheet: Texture2D = atlas.atlas if atlas != null else texture
			if sheet != null and not seen.has(sheet):
				seen[sheet] = true
				total += texture_bytes_of(sheet)
	return total
```

- [ ] **Step 4: Run them; they pass**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 5: Write the failing BudgetRun tests**

Create `tests/view/test_budget_run.gd`:

```gdscript
extends GutTest
## The budget check's parts: when it is asked for, the worst case it plays,
## and its line and verdict. The memory numbers themselves come from real
## runs (docs/specs/2026-10-15-art-a4-loading-design.md §6).


func _units() -> UnitCatalog:
	return load(App.CATALOG_PATH) as UnitCatalog


func _skirmishes() -> SkirmishCatalog:
	return load(App.SKIRMISH_PATH) as SkirmishCatalog


func _fields() -> Dictionary:
	return {
		"js_bytes": 400e6, "how": "measured", "video": 200e6, "textures": 190e6, "static": 50e6,
		"art": 188e6, "types": 10, "art_load_ms": 850, "pck": 196e6, "wire": 60e6, "s3tc": true,
		"ticks": 1800, "seconds": 61,
	}


func test_the_page_asks_with_budget_1() -> void:
	assert_true(BudgetRun.asked_in_query("?budget=1"))
	assert_true(BudgetRun.asked_in_query("?verify=0&budget=yes"))
	assert_false(BudgetRun.asked_in_query(""))
	assert_false(BudgetRun.asked_in_query("?budget=0"))
	assert_false(BudgetRun.asked_in_query("?budget"))
	assert_false(BudgetRun.asked_in_query("?budgets=1"))


func test_the_worst_case_fields_every_buyable_type_on_old_mill() -> void:
	var units: UnitCatalog = _units()
	var setup: SkirmishSetup = BudgetRun.worst_case_setup(units, _skirmishes())
	assert_eq(setup.validate(units), PackedStringArray())
	assert_eq(setup.map.id, &"old_mill")
	assert_true(setup.player_is_ai, "AI against AI")
	var fielded: Array[StringName] = []
	for army: Army in setup.armies:
		for type_id: StringName in army.counts:
			assert_eq(army.count_of(type_id), BudgetRun.EACH, "%s" % type_id)
			fielded.append(type_id)
	for type: UnitType in units.types:
		if type.cost > 0:
			assert_has(fielded, type.id)
	assert_eq(fielded.size(), 10, "the ten v1 types; the villager is not for sale")


func test_the_verdict() -> void:
	assert_eq(BudgetRun.verdict(999.6), "PASS")
	assert_eq(BudgetRun.verdict(1000.0), "PASS")
	assert_eq(BudgetRun.verdict(1000.4), "FAIL")
	assert_eq(BudgetRun.verdict(-1.0), "UNKNOWN")


func test_the_web_line_adds_the_page_and_the_gpu() -> void:
	assert_eq(
		BudgetRun.web_line(_fields()),
		"BUDGET tab=600 limit=1000 PASS js_wasm=400 (measured) video=200 textures=190 art=188 types=10"
		+ " art_load=850 pck=196 wire=60 s3tc=yes ticks=1800 seconds=61 on=web"
	)


func test_an_unread_page_is_unknown_not_a_pass() -> void:
	var f: Dictionary = _fields()
	f["js_bytes"] = -1.0
	f["how"] = "unknown"
	assert_string_contains(BudgetRun.web_line(f), "tab=-1 limit=1000 UNKNOWN js_wasm=-1 (unknown)")


func test_the_desktop_line_has_no_verdict() -> void:
	var line: String = BudgetRun.desktop_line(_fields())
	assert_string_starts_with(line, "BUDGET video=200 textures=190 static=50 art=188 types=10 art_load=850 ticks=1800 seconds=61 on=")
	assert_false(line.contains("PASS"))


func test_a_short_run_plays_and_prints_a_line() -> void:
	var run: BudgetRun = BudgetRun.new()
	run.catalog = _units()
	run.skirmish = _skirmishes()
	run.play_ticks = 3
	add_child_autofree(run)
	run.start()
	await wait_for_signal(run.finished, 20)
	assert_string_starts_with(run.line, "BUDGET video=")
	assert_gte(run.main.world.tick, 3)
	assert_eq(run.main.loaded_arts().size(), 10, "every v1 type's art is on the field")
```

- [ ] **Step 6: Run them; they fail**

Run: `make import && godot --headless --path . -s addons/gut/gut_cmdln.gd -gconfig= -gtest=res://tests/view/test_budget_run.gd -gexit`
Expected: FAIL, parse error: `BudgetRun` is not declared.

- [ ] **Step 7: Add `loaded_arts` and `art_load_ms`**

In `view/units/units_view.gd`, after `art_enabled()`:

```gdscript
## The art this view draws with, one per type.
func loaded_arts() -> Array[UnitArt]:
	var out: Array[UnitArt] = []
	out.assign(_arts.arts)
	return out
```

In `view/main.gd`, after `var last_step_ms`:

```gdscript
## How long loading this game's unit art took, in ms; the budget check reports it.
var art_load_ms: int = 0
```

Replace `_units_view.setup(world, _selection.selection, _gibs, load_art())` with:

```gdscript
	var art_started_ms: int = Time.get_ticks_msec()
	var arts: UnitArtCatalog = load_art()
	art_load_ms = Time.get_ticks_msec() - art_started_ms
	_units_view.setup(world, _selection.selection, _gibs, arts)
```

After `load_art`:

```gdscript
## The unit art this game loaded, for the budget check.
func loaded_arts() -> Array[UnitArt]:
	return _units_view.loaded_arts()
```

- [ ] **Step 8: Write `view/budget/budget_run.gd`**

```gdscript
class_name BudgetRun
extends Node
## The Web texture budget's check (docs/specs/2026-10-15-art-a4-loading-design.md
## §6). The App runs it instead of the menus when asked:
##   native: <game> -- --budget        (make budget, make budget-app)
##   web:    index.html?budget=1       (make export-web serve-web)
## It plays the worst case for texture memory, rendered: an AI-against-AI
## skirmish on Old Mill with every buyable type, EACH of each per side, until
## the world has played play_ticks (60 s). Then it measures, prints one line
## and shows it on screen:
##   web:     BUDGET tab=<MB> limit=1000 PASS|FAIL|UNKNOWN js_wasm=<MB> (<how>) video=<MB>
##            textures=<MB> art=<MB> types=<n> art_load=<ms> pck=<MB> wire=<MB> s3tc=<yes|no>
##            ticks=<n> seconds=<s> on=web
##   desktop: BUDGET video=<MB> textures=<MB> static=<MB> art=<MB> types=<n> art_load=<ms>
##            ticks=<n> seconds=<s> on=<os>
## tab is js_wasm plus video. js_wasm is measureUserAgentSpecificMemory when
## the page is cross-origin isolated ("measured"), else Chrome's JS heap alone
## ("fallback"), else unknown (-1, and the verdict is UNKNOWN). art is the
## loaded unit sheets' bytes, computed from their sizes and formats
## (UnitArt.sheet_bytes): Godot 4.7 doesn't give scripts the driver's own
## count per texture. Desktop has no budget, so its line has no verdict. The
## page sets window.__amBudgetLine to the line, for a script to read.

signal finished(line: String)

const LIMIT_MB: int = 1000
const EACH: int = 2
const MAP_ID: StringName = &"old_mill"
const SEED: int = 1000
const MINUTES: int = 10
## Frames to wait for the browser's memory measurement, which Chrome takes at
## its next garbage collection, before giving up on it.
const JS_WAIT_FRAMES: int = 1800
const MAIN_SCENE: String = "res://view/main.tscn"
const MB: float = 1_000_000.0
## Starts the page's measurement; window.__amBudget gets its JSON.
const JS_MEASURE: String = """
window.__amBudget = null;
(async () => {
	const out = {how: 'unknown', bytes: -1, pck: -1, wire: -1, s3tc: false};
	const pck = performance.getEntriesByType('resource').find((e) => e.name.split('?')[0].endsWith('.pck'));
	if (pck) { out.pck = pck.decodedBodySize; out.wire = pck.transferSize; }
	const gl = document.createElement('canvas').getContext('webgl2');
	out.s3tc = !!(gl && gl.getExtension('WEBGL_compressed_texture_s3tc'));
	try {
		if (!self.crossOriginIsolated || !performance.measureUserAgentSpecificMemory) throw new Error('unavailable');
		out.bytes = (await performance.measureUserAgentSpecificMemory()).bytes;
		out.how = 'measured';
	} catch (e) {
		if (performance.memory) { out.bytes = performance.memory.totalJSHeapSize; out.how = 'fallback'; }
	}
	window.__amBudget = JSON.stringify(out);
})();
"""

var catalog: UnitCatalog
var skirmish: SkirmishCatalog
## Sim ticks to play before measuring.
var play_ticks: int = 60 * World.TICK_RATE
var main: MainView
## The result, once measured.
var line: String = ""

var _started_ms: int = 0
var _measuring: bool = false
var _js_frames: int = 0
var _fields: Dictionary = {}
var _label: Label


## True when the command line or the page's URL asks for the check.
static func requested() -> bool:
	if OS.has_feature("web"):
		return asked_in_query(str(JavaScriptBridge.eval("window.location.search", true)))
	return "--budget" in OS.get_cmdline_user_args()


## True when a page's search string (?a=1&budget=1) holds budget=<not 0>.
static func asked_in_query(search: String) -> bool:
	for pair: String in search.trim_prefix("?").split("&", false):
		var kv: PackedStringArray = pair.split("=", true, 1)
		if kv[0].uri_decode() == "budget":
			var value: String = kv[1].uri_decode() if kv.size() > 1 else ""
			return value != "" and value != "0"
	return false


## The worst case for texture memory: every buyable type of each side, EACH of
## each, AI against AI on Old Mill, with a budget that buys both armies.
static func worst_case_setup(units: UnitCatalog, skirmishes: SkirmishCatalog) -> SkirmishSetup:
	var setup: SkirmishSetup = SkirmishSetup.new()
	setup.map = skirmishes.skirmish_map(MAP_ID)
	setup.rules = SkirmishRules.for_map(setup.map, SkirmishRules.Mode.BODY_COUNT, MINUTES, UnitType.Faction.LIGHT)
	var light: Army = Army.new(UnitType.Faction.LIGHT)
	var dark: Army = Army.new(UnitType.Faction.DARK)
	for type: UnitType in units.types:
		if type.cost <= 0:
			continue
		(light if type.faction == UnitType.Faction.LIGHT else dark).set_count(type.id, EACH)
	setup.armies = [light, dark]
	setup.budget = maxi(light.cost(units), dark.cost(units))
	setup.player_is_ai = true
	setup.world_seed = SEED
	return setup


## PASS within LIMIT_MB, FAIL over it, UNKNOWN when the tab's memory couldn't
## be read (negative).
static func verdict(tab_mb: float) -> String:
	if tab_mb < 0.0:
		return "UNKNOWN"
	return "PASS" if tab_mb <= LIMIT_MB else "FAIL"


## The web line from the fields (see the head). js_bytes is -1 when unread.
static func web_line(f: Dictionary) -> String:
	var js: float = float(f["js_bytes"])
	var tab: float = js + float(f["video"]) if js >= 0.0 else -1.0
	return (
		"BUDGET tab=%d limit=%d %s js_wasm=%d (%s) video=%d textures=%d art=%d types=%d art_load=%d"
		+ " pck=%d wire=%d s3tc=%s ticks=%d seconds=%d on=web"
	) % [
		_mb(tab), LIMIT_MB, verdict(tab / MB if tab >= 0.0 else -1.0), _mb(js), f["how"], _mb(f["video"]),
		_mb(f["textures"]), _mb(f["art"]), f["types"], f["art_load_ms"], _mb(f["pck"]), _mb(f["wire"]),
		"yes" if f["s3tc"] else "no", f["ticks"], f["seconds"],
	]


## The desktop line from the fields (see the head).
static func desktop_line(f: Dictionary) -> String:
	return "BUDGET video=%d textures=%d static=%d art=%d types=%d art_load=%d ticks=%d seconds=%d on=%s" % [
		_mb(f["video"]), _mb(f["textures"]), _mb(f["static"]), _mb(f["art"]), f["types"], f["art_load_ms"],
		f["ticks"], f["seconds"], OS.get_name().to_lower(),
	]


# Whole MB, or -1 for a count that couldn't be read.
static func _mb(bytes: float) -> int:
	return -1 if bytes < 0.0 else roundi(bytes / MB)


## Builds the worst case and starts playing it.
func start() -> void:
	main = (load(MAIN_SCENE) as PackedScene).instantiate() as MainView
	main.launch = MissionLaunch.for_skirmish(worst_case_setup(catalog, skirmish))
	# Not campaign mode: a window opened from a terminal starts unfocused, and
	# campaign mode pauses when the window loses focus.
	main.launch.campaign_mode = false
	add_child(main)
	_started_ms = Time.get_ticks_msec()
	var layer: CanvasLayer = CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(16.0, 16.0)
	_label.text = "Budget check: playing %d s..." % roundi(play_ticks / float(World.TICK_RATE))
	layer.add_child(_label)


func _process(_delta: float) -> void:
	if main == null or main.world == null or not line.is_empty():
		return
	if main.paused:
		main.paused = false
	if not _measuring:
		if main.world.tick >= play_ticks or main.is_frozen():
			_measure()
		return
	if OS.has_feature("web"):
		_poll_page()


func _measure() -> void:
	_measuring = true
	var arts: Array[UnitArt] = main.loaded_arts()
	var art_bytes: int = 0
	for art: UnitArt in arts:
		art_bytes += art.sheet_bytes()
	_fields = {
		"video": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED),
		"textures": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED),
		"static": float(OS.get_static_memory_usage()),
		"art": float(art_bytes),
		"types": arts.size(),
		"art_load_ms": main.art_load_ms,
		"ticks": main.world.tick,
		"seconds": roundi((Time.get_ticks_msec() - _started_ms) / 1000.0),
	}
	if OS.has_feature("web"):
		JavaScriptBridge.eval(JS_MEASURE, true)
	else:
		_finish(desktop_line(_fields))


# Reads the page's measurement once it is there, or gives up on it.
func _poll_page() -> void:
	_js_frames += 1
	var raw: Variant = JavaScriptBridge.eval("window.__amBudget", true)
	if not raw is String or (raw as String).is_empty():
		if _js_frames < JS_WAIT_FRAMES:
			return
		raw = "{}"
	var parsed: Variant = JSON.parse_string(raw)
	var page: Dictionary = parsed if parsed is Dictionary else {}
	_fields["js_bytes"] = float(page.get("bytes", -1))
	_fields["how"] = str(page.get("how", "unknown"))
	_fields["pck"] = float(page.get("pck", -1))
	_fields["wire"] = float(page.get("wire", -1))
	_fields["s3tc"] = bool(page.get("s3tc", false))
	_finish(web_line(_fields))


func _finish(text: String) -> void:
	line = text
	print(line)
	_label.text = line
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__amBudgetLine = %s;" % JSON.stringify(line), true)
	finished.emit(line)
```

- [ ] **Step 9: Wire it into the App**

In `view/app/app.gd` `_ready()`, right after the verifier's `return`:

```gdscript
	if BudgetRun.requested():
		_run_budget()
		return
```

After `_run_verifier`:

```gdscript
# The Web texture budget's check (BudgetRun) in place of the menus. A native
# run quits once the line is printed; the web page stays up to show it.
func _run_budget() -> void:
	var run: BudgetRun = BudgetRun.new()
	run.name = "BudgetRun"
	run.catalog = load(CATALOG_PATH) as UnitCatalog
	run.skirmish = load(SKIRMISH_PATH) as SkirmishCatalog
	run.finished.connect(func(_line: String) -> void:
		if not OS.has_feature("web"):
			get_tree().quit(0)
	)
	add_child(run)
	run.start()
```

- [ ] **Step 10: Make targets, and a close shot in the capture**

In `Makefile`, add `budget budget-app` to `.PHONY`, and after `profile-sim`:

```make
# The Web texture budget's check (docs/specs/2026-10-15-art-a4-loading-design.md
# §6), windowed: an AI-against-AI skirmish on Old Mill with every v1 type for
# 60 s, then one BUDGET line. The web build runs it at
# http://127.0.0.1:8060/?budget=1 (make export-web serve-web); budget-app runs it
# in the exported macOS app (make export-mac first).
budget: import
	$(GODOT) --path . -- --budget

budget-app:
	$(MAC_APP)/Contents/MacOS/Ashenmarch -- --budget
```

In `scripts/capture_missions.gd`:
- In the head, after the opening-view line, add `## - the closest zoom on the squad (RtsCamera.MIN_DISTANCE), right after;`. Change "three screenshots" to "four screenshots".
- Give `_look_at_the_squad` a distance:

```gdscript
# Puts the camera over the middle of the soldiers still standing, keeping its
# angle, at `distance` (its own when negative): the opening view looks where
# the mission starts.
func _look_at_the_squad(distance: float = -1.0) -> void:
```

  Make its last line `rig.set_pose(sum / count, rig.yaw, rig.distance if distance < 0.0 else distance)`.
- After `await _save(mission.id, "opening")`:

```gdscript
	# The closest zoom, where a sheet's resolution and trimming show most.
	var rig: RtsCamera = _main.get_node("CameraRig") as RtsCamera
	var opening_distance: float = rig.distance
	_look_at_the_squad(RtsCamera.MIN_DISTANCE)
	await _save(mission.id, "close")
	_look_at_the_squad(opening_distance)
```

In the Makefile's `capture` comment, change "three screenshots" to "four screenshots", and add "the closest zoom on the squad" after "the opening view".

- [ ] **Step 11: Run the tests; they pass**

Run: `make import && godot --headless --path . -s addons/gut/gut_cmdln.gd -gconfig= -gtest=res://tests/view/test_budget_run.gd -gexit`, then the same for `test_unit_art.gd`.
Expected: PASS. Then run the whole suite and `make check-sim`. Expected: PASS.

- [ ] **Step 12: Measure today's build, desktop**

Run `make budget` (a window opens; wait for it to quit). Then run `make export-mac && make budget-app`. Expected: one `BUDGET video=… art=554 types=10 …` line each, about 554 MB of art. Copy both lines into `docs/plans/2026-10-15-art-a4-measurements.md`:

```markdown
# A4 measurements

Raw `BUDGET` lines from the budget check (view/budget/budget_run.gd). Before = main at 46ab149 plus the check, after = this branch.

## Before

- editor, macOS arm64: `<line>`
- release app, macOS arm64: `<line>`
- Web, Chrome on this Mac: `<line>`
```

- [ ] **Step 13: Measure today's build, Web in Chrome**

1. Run `make export-web`.
2. Start `python3 scripts/serve_web.py --port 8064` in the background. It's another port than 8060, in case something else serves there.
3. In the chrome-devtools MCP, open a new page: `url: http://127.0.0.1:8064/?budget=1`, `isolatedContext: "a4-budget"`, in the foreground. A background tab is throttled and won't play.
4. Every 30 s, `evaluate_script` `() => window.__amBudgetLine || null` until it returns a line. The run takes about 60–120 s of play, then up to about 20 s for the measurement.
5. Copy the line into the measurements file. Expected: `tab=` about 1300, FAIL, `art=554`.
6. If the page shows no line after 5 minutes, take a screenshot and `list_console_messages`. Stop and report; don't retry more than twice.
7. Stop the server.

- [ ] **Step 14: Capture Riverside before**

Run: `CAPTURE=/private/tmp/claude-501/-Users-timk-Projects-ashenmarch/b5725fc3-76c9-4523-8b76-6119db6f1285/scratchpad/a4/capture-before MISSIONS=riverside make capture`
Expected: four PNGs (`40-riverside-opening.png`, `41-riverside-close.png`, `42-riverside-overhead.png`, `43-riverside-battle.png`). Look at the close one, and keep the folder for Task 8.

- [ ] **Step 15: Commit**

```bash
git add view/budget view/units/unit_art.gd view/units/units_view.gd view/main.gd view/app/app.gd scripts/capture_missions.gd Makefile tests/view/test_budget_run.gd tests/view/test_unit_art.gd docs/plans/2026-10-15-art-a4-measurements.md
git commit -m "Add the Web texture budget check and measure today's build" -m "A4 needs a budget measured in a real build, before and after. ?budget=1 (-- --budget on desktop) plays the worst case for texture memory, every v1 type in an Old Mill skirmish, and prints tab memory against 1,000 MB. Today's numbers are recorded. The capture gets a close-zoom shot for the before-and-after.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: ETC2 import off

**Files:**
- Modify: `project.godot`, then every `*.import` the reimport rewrites

**Interfaces:** none.

- [ ] **Step 1: Turn it off**

In `project.godot`, under `[rendering]`, change `textures/vram_compression/import_etc2_astc=true` to `textures/vram_compression/import_etc2_astc=false`.

- [ ] **Step 2: Reimport and check**

Run: `make import`, then `grep -rl "etc2" --include=*.import . | grep -v "^./.godot" | wc -l`.
Expected: `0`.

If it isn't 0, Godot didn't reimport. Run `godot --headless --path . --import` once more and check again. If it is still non-zero, stop and report: the setting didn't take.

Run `git status --short | grep -c "\.import$"` and note the count for the commit message.

- [ ] **Step 3: Check the exports carry S3TC only**

Run `make export-web export-mac`. Then for each pck:

`LC_ALL=C grep -a -o 'imported/[A-Za-z0-9_.-]*\.\(s3tc\|etc2\|bptc\|astc\)\.ctex' build/web/index.pck | sed 's/.*\.\([a-z0-9]*\)\.ctex/\1/' | sort | uniq -c`

and the same on `build/mac/Ashenmarch.app/Contents/Resources/Ashenmarch.pck`. Expected: only `s3tc` lines, as before.

- [ ] **Step 4: The suite and the game**

Run the whole suite and `make check-sim`; expected PASS. Run `make run` and start Riverside from the menu. Look: units and terrain draw as before. Quit.

- [ ] **Step 5: Commit**

Run `git status --short`. Expected: only `project.godot` and `.import` files modified. If anything else shows, find out why before committing.

```bash
git add -u
git commit -m "Stop importing textures as ETC2" -m "No export ships ETC2: the Web preset is desktop-only, and the universal macOS and Windows exports take S3TC (measured from the pcks). The second format only doubled the import cache. Godot rewrote <n> .import files.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The packer's core

**Files:**
- Create: `scripts/art/unit_art_packer.gd`
- Modify: `tests/support/test_art.gd` (add `grids()`)
- Test: `tests/view/test_unit_art_packer.gd`

**Interfaces:**
- Consumes: `UnitArtBuilder.GAME_ANIMS`, `UnitArt.DIRECTIONS`.
- Produces `class UnitArtPacker`:
  - `const PAD = 8`, `ALIGN = 4`, `MAX_SHEET = 4096`, `LAYOUT = "packed"`, `GRID_KEYS`, `GRID_ANIMATION_KEYS`
  - `static region_in_cell(used: Rect2i, cell: int) -> Rect2i`
  - `static slot_margins(used: Rect2i, region: Rect2i) -> PackedInt32Array` ([left, top, right, bottom])
  - `static shelf_pack(sizes: Array[Vector2i], max_width: int) -> Array[Vector2i]`, `static sheet_size(sizes: Array[Vector2i], positions: Array[Vector2i]) -> Vector2i`
  - `static pack_animation(grid: Image, frames: int, columns: int, rows_per_direction: int, cell: int, stride: int, gutter: int, max_sheet: int = MAX_SHEET) -> Dictionary`: `{"image": Image, "rects": Array}`, or `{"error": String}`. Each rect is `[x, y, w, h, cell_x, cell_y]`, direction-major: frame i of direction d is entry `d * frames + i`.
  - `static pack(sidecar: Dictionary, grids: Dictionary) -> Dictionary`: `{"sidecar": Dictionary, "sheets": Dictionary[StringName, Image], "errors": PackedStringArray}`
- Produces: `static TestArt.grids(side: Dictionary) -> Dictionary`, blank grid `Image`s by animation.

- [ ] **Step 1: Add `TestArt.grids`**

In `tests/support/test_art.gd`, replace the body of `sheets()` so it wraps a new `grids()`:

```gdscript
## Blank grid Images the size the sidecar implies: columns wide (the frame
## count when the sidecar gives none) and rows_per_direction rows (1) for
## each of the directions.
static func grids(side: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for anim: String in side["animations"]:
		var info: Dictionary = side["animations"][anim]
		var columns: int = int(info.get("columns", info["frames"]))
		var rows: int = int(info.get("rows_per_direction", 1))
		out[StringName(anim)] = Image.create_empty(columns * STRIDE, UnitArt.DIRECTIONS * rows * STRIDE, false, Image.FORMAT_RGBA8)
	return out


## The same as textures, for the builder while it still cuts grids.
static func sheets(side: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var images: Dictionary = grids(side)
	for anim: StringName in images:
		out[anim] = ImageTexture.create_from_image(images[anim])
	return out
```

- [ ] **Step 2: Write the failing packer tests**

Create `tests/view/test_unit_art_packer.gd`:

```gdscript
extends GutTest
## UnitArtPacker: a grid render's frames trimmed to the part of the cell that
## holds the figure, padded, and packed, losslessly
## (docs/specs/2026-10-15-art-a4-loading-design.md §4).

const CELL: int = 32
const GUTTER: int = 4
const STRIDE: int = CELL + 2 * GUTTER
const PAD: int = UnitArtPacker.PAD
## Transparent, but coloured: the renderer leaves colour in pixels it never
## drew, so the packer must copy a region's pixels exactly, not just its alpha.
const BACKGROUND: Color = Color(0.5, 0.2, 0.1, 0.0)


# The box frame k (direction-major) draws, or an empty one: boxes move about
# the cell, some touch its left or right and bottom edges, and frame 3 draws nothing.
func _box(k: int) -> Rect2i:
	if k == 3:
		return Rect2i()
	var size: Vector2i = Vector2i(3 + k % 5, 4 + k % 7)
	var at: Vector2i = Vector2i((k * 7) % (CELL - size.x), (k * 5) % (CELL - size.y))
	match k % 4:
		1:
			at.x = 0
		2:
			at = Vector2i(CELL - size.x, CELL - size.y)
	return Rect2i(at, size)


# A grid of `frames` frames per direction, `columns` across and
# rows_per_direction rows each, every cell BACKGROUND with its frame's box in a
# colour of its own.
func _grid(frames: int, columns: int, rows_per_direction: int) -> Image:
	var image: Image = Image.create_empty(columns * STRIDE, UnitArt.DIRECTIONS * rows_per_direction * STRIDE, false, Image.FORMAT_RGBA8)
	image.fill(BACKGROUND)
	for dir: int in UnitArt.DIRECTIONS:
		for i: int in frames:
			var k: int = dir * frames + i
			var box: Rect2i = _box(k)
			if box.has_area():
				image.fill_rect(Rect2i(_origin(i, dir, columns, rows_per_direction) + box.position, box.size), Color8(k * 13 % 256, k * 29 % 256, k * 53 % 256, 255))
	return image


func _origin(i: int, dir: int, columns: int, rows_per_direction: int) -> Vector2i:
	@warning_ignore("integer_division") # Floor on purpose: the wrapped row.
	return Vector2i((i % columns) * STRIDE + GUTTER, (dir * rows_per_direction + i / columns) * STRIDE + GUTTER)


func _pack(frames: int = 30, columns: int = 24, rows_per_direction: int = 2) -> Dictionary:
	return UnitArtPacker.pack_animation(_grid(frames, columns, rows_per_direction), frames, columns, rows_per_direction, CELL, STRIDE, GUTTER)


func test_a_region_is_the_box_padded_out_to_whole_blocks_inside_the_cell() -> void:
	assert_eq(UnitArtPacker.region_in_cell(Rect2i(10, 13, 5, 6), CELL), Rect2i(0, 4, 24, 24))
	assert_eq(UnitArtPacker.region_in_cell(Rect2i(27, 28, 5, 4), CELL), Rect2i(16, 20, 16, 12), "cut short by the cell's edge")
	assert_eq(UnitArtPacker.region_in_cell(Rect2i(), CELL), Rect2i(0, 0, 4, 4), "an empty cell keeps one block")


func test_the_sheet_pads_only_where_the_cell_cut_a_region_short() -> void:
	var inside: Rect2i = Rect2i(10, 13, 5, 6)
	assert_eq(UnitArtPacker.slot_margins(inside, UnitArtPacker.region_in_cell(inside, CELL)), PackedInt32Array([0, 0, 0, 0]))
	var corner: Rect2i = Rect2i(27, 28, 5, 4)
	assert_eq(UnitArtPacker.slot_margins(corner, UnitArtPacker.region_in_cell(corner, CELL)), PackedInt32Array([0, 0, 8, 8]))
	var left_edge: Rect2i = Rect2i(0, 10, 4, 4)
	assert_eq(UnitArtPacker.slot_margins(left_edge, UnitArtPacker.region_in_cell(left_edge, CELL)), PackedInt32Array([8, 0, 0, 0]))


func test_shelves_take_the_tallest_first_and_wrap() -> void:
	var sizes: Array[Vector2i] = [Vector2i(8, 4), Vector2i(8, 12), Vector2i(16, 8), Vector2i(8, 12)]
	var positions: Array[Vector2i] = UnitArtPacker.shelf_pack(sizes, 24)
	assert_eq(positions, [Vector2i(16, 12), Vector2i(0, 0), Vector2i(0, 12), Vector2i(8, 0)] as Array[Vector2i])
	assert_eq(UnitArtPacker.sheet_size(sizes, positions), Vector2i(24, 20))


func test_every_packed_frame_is_its_grid_cell_byte_for_byte() -> void:
	var frames: int = 30
	var grid: Image = _grid(frames, 24, 2)
	var packed: Dictionary = _pack(frames)
	var sheet: Image = packed["image"]
	var rects: Array = packed["rects"]
	assert_eq(rects.size(), UnitArt.DIRECTIONS * frames)
	for dir: int in UnitArt.DIRECTIONS:
		for i: int in frames:
			var r: Array = rects[dir * frames + i]
			var region: Rect2i = Rect2i(r[4], r[5], r[2], r[3])
			var origin: Vector2i = _origin(i, dir, 24, 2)
			var kept: PackedByteArray = sheet.get_region(Rect2i(r[0], r[1], r[2], r[3])).get_data()
			var cut: PackedByteArray = grid.get_region(Rect2i(origin + region.position, region.size)).get_data()
			assert_eq(kept, cut, "d%d f%d: the region's pixels, colour in its transparency too" % [dir, i])
			var used: Rect2i = grid.get_region(Rect2i(origin, Vector2i(CELL, CELL))).get_used_rect()
			if used.has_area():
				assert_true(region.encloses(used), "d%d f%d: everything the figure draws is kept" % [dir, i])


func test_packed_frames_sit_on_whole_blocks_and_never_overlap() -> void:
	var rects: Array = _pack()["rects"]
	var placed: Array[Rect2i] = []
	for r: Array in rects:
		for v: int in [r[0], r[1], r[2], r[3], r[4], r[5]]:
			assert_eq(v % UnitArtPacker.ALIGN, 0, "on the 4 px block grid: %s" % [r])
		var here: Rect2i = Rect2i(r[0], r[1], r[2], r[3])
		for other: Rect2i in placed:
			assert_false(here.intersects(other), "%s overlaps %s" % [here, other])
		placed.append(here)


func test_figures_touching_the_cell_edge_keep_their_distance() -> void:
	var frames: int = 30
	var packed: Dictionary = _pack(frames)
	var rects: Array = packed["rects"]
	# Where each figure ended up in the packed sheet, grown by PAD: no two touch.
	var figures: Array[Rect2i] = []
	for k: int in rects.size():
		var box: Rect2i = _box(k)
		if not box.has_area():
			continue
		var r: Array = rects[k]
		figures.append(Rect2i(Vector2i(r[0], r[1]) + box.position - Vector2i(r[4], r[5]), box.size).grow(PAD))
	for a: int in figures.size():
		for b: int in range(a + 1, figures.size()):
			assert_false(figures[a].intersects(figures[b]), "figures %d and %d are under %d px apart" % [a, b, 2 * PAD])


func test_packing_twice_gives_the_same_bytes() -> void:
	var first: Dictionary = _pack()
	var second: Dictionary = _pack()
	assert_eq(first["rects"], second["rects"])
	assert_eq((first["image"] as Image).save_png_to_buffer(), (second["image"] as Image).save_png_to_buffer())


func test_a_sheet_that_would_be_too_tall_is_an_error() -> void:
	var out: Dictionary = UnitArtPacker.pack_animation(_grid(30, 24, 2), 30, 24, 2, CELL, STRIDE, GUTTER, 64)
	assert_true(out.has("error"))
	assert_string_contains(str(out["error"]), "over 64")


func test_pack_keeps_the_sidecar_and_drops_the_grid_keys() -> void:
	var side: Dictionary = TestArt.sidecar(&"x", {
		"idle": [1, 12, true, -1], "walk": [12, 12, true, -1],
		"attack": [6, 12, false, 3], "attack_alt": [6, 12, false, 3], "die": [4, 12, false, -1],
	})
	side["figure_height_m"] = 1.41
	side["animations"]["attack"]["columns"] = 4
	side["animations"]["attack"]["rows_per_direction"] = 2
	var out: Dictionary = UnitArtPacker.pack(side, TestArt.grids(side))
	assert_eq(out["errors"], PackedStringArray())
	var packed: Dictionary = out["sidecar"]
	assert_eq(packed["layout"], UnitArtPacker.LAYOUT)
	assert_eq(packed["pad"], UnitArtPacker.PAD)
	assert_false(packed.has("stride") or packed.has("gutter"))
	assert_eq(packed["figure_height_m"], 1.41, "every other key carries over")
	assert_false((packed["animations"] as Dictionary).has("attack_alt"), "only the clips the game plays")
	var attack: Dictionary = packed["animations"]["attack"]
	assert_false(attack.has("columns") or attack.has("rows_per_direction"))
	assert_eq((attack["rects"] as Array).size(), UnitArt.DIRECTIONS * 6)
	var image: Image = out["sheets"][&"attack"]
	assert_eq(attack["sheet_size"], [image.get_width(), image.get_height()])
	assert_eq(side["animations"]["attack"]["columns"], 4, "the grid sidecar is left as it was")
```

- [ ] **Step 3: Run them; they fail**

Run: `godot --headless --path . -s addons/gut/gut_cmdln.gd -gconfig= -gtest=res://tests/view/test_unit_art_packer.gd -gexit`
Expected: FAIL, `UnitArtPacker` not declared.

- [ ] **Step 4: Write `scripts/art/unit_art_packer.gd`**

```gdscript
class_name UnitArtPacker
extends RefCounted
## Packs the renderer's grid sheets (art-src/units/<id>/sheets/): every frame
## trimmed to the part of its cell that holds the figure, then shelf-packed
## into a sheet at most MAX_SHEET px a side. A grid frame's figure fills about
## a quarter of its cell, so a packed sheet takes about a third of its grid's
## GPU memory (docs/specs/2026-10-15-art-a4-loading-design.md §3, §4).
##
## A frame keeps region_in_cell: its used alpha box grown by PAD px, out to
## the cell's 4 px block grid, inside the cell. Every pixel the figure draws is
## kept byte for byte, and every 4x4 DXT block holds the pixels it held in the
## grid. Beside a region the sheet adds transparency only where the cell's
## edge cut the region short (slot_margins), so two figures always lie at least
## 2 * PAD px apart and mipmaps through level 2 never mix them.
##
## The packed sidecar says, per frame, where its region sits in the sheet and
## in the cell. The builder makes each frame an AtlasTexture whose region is
## the first and whose margin puts back the rest of the cell.

const PAD: int = 8
## DXT blocks are 4x4: regions start and end on this grid.
const ALIGN: int = 4
const MAX_SHEET: int = 4096
## A packed sidecar's "layout".
const LAYOUT: String = "packed"
## Grid-only keys a packed sidecar drops.
const GRID_KEYS: Array[String] = ["stride", "gutter"]
const GRID_ANIMATION_KEYS: Array[String] = ["columns", "rows_per_direction"]


## The part of a cell a packed frame keeps, in cell coordinates. used is the
## cell's used alpha box (Image.get_used_rect); a cell with nothing drawn keeps
## one transparent block at its corner.
static func region_in_cell(used: Rect2i, cell: int) -> Rect2i:
	if not used.has_area():
		return Rect2i(0, 0, ALIGN, ALIGN)
	var left: int = _floor_to_block(maxi(used.position.x - PAD, 0))
	var top: int = _floor_to_block(maxi(used.position.y - PAD, 0))
	var right: int = mini(_ceil_to_block(used.end.x + PAD), cell)
	var bottom: int = mini(_ceil_to_block(used.end.y + PAD), cell)
	return Rect2i(left, top, right - left, bottom - top)


## The transparency the sheet adds around a region, as [left, top, right,
## bottom] px: enough that PAD px lie between the figure and its slot's edge on
## every side, rounded up to whole blocks. The region holds them already unless
## the cell's edge cut it short.
static func slot_margins(used: Rect2i, region: Rect2i) -> PackedInt32Array:
	if not used.has_area():
		return PackedInt32Array([0, 0, 0, 0])
	return PackedInt32Array([
		_ceil_to_block(maxi(PAD - (used.position.x - region.position.x), 0)),
		_ceil_to_block(maxi(PAD - (used.position.y - region.position.y), 0)),
		_ceil_to_block(maxi(PAD - (region.end.x - used.end.x), 0)),
		_ceil_to_block(maxi(PAD - (region.end.y - used.end.y), 0)),
	])


## Where each box goes on shelves at most max_width wide: tallest first, then
## widest, then in list order, so the same boxes always pack the same way.
## Boxes whose sides are whole blocks land on whole blocks.
static func shelf_pack(sizes: Array[Vector2i], max_width: int) -> Array[Vector2i]:
	var order: Array[int] = []
	for i: int in sizes.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		if sizes[a].y != sizes[b].y:
			return sizes[a].y > sizes[b].y
		if sizes[a].x != sizes[b].x:
			return sizes[a].x > sizes[b].x
		return a < b
	)
	var positions: Array[Vector2i] = []
	positions.resize(sizes.size())
	var x: int = 0
	var y: int = 0
	var shelf: int = 0
	for i: int in order:
		if x > 0 and x + sizes[i].x > max_width:
			y += shelf
			x = 0
			shelf = 0
		positions[i] = Vector2i(x, y)
		x += sizes[i].x
		shelf = maxi(shelf, sizes[i].y)
	return positions


## The smallest sheet that holds every box at its position.
static func sheet_size(sizes: Array[Vector2i], positions: Array[Vector2i]) -> Vector2i:
	var size: Vector2i = Vector2i.ZERO
	for i: int in sizes.size():
		size = size.max(positions[i] + sizes[i])
	return size


## One animation of a grid sheet, packed: {"image": an RGBA8 Image, "rects":
## per frame, direction-major (frame i of direction d is entry d * frames + i),
## [x, y, w, h, cell_x, cell_y]: the region's place in the sheet, its size,
## and its place in the cell}, or {"error": String} when the sheet would be
## taller than max_sheet. grid holds `frames` frames per direction, columns
## across and rows_per_direction rows each, every cell a gutter inside its
## stride; the caller has checked that layout (layout_errors).
static func pack_animation(
	grid: Image, frames: int, columns: int, rows_per_direction: int, cell: int, stride: int, gutter: int,
	max_sheet: int = MAX_SHEET
) -> Dictionary:
	var source: Image = grid
	if source.get_format() != Image.FORMAT_RGBA8:
		source = grid.duplicate() as Image
		source.convert(Image.FORMAT_RGBA8)
	var origins: Array[Vector2i] = []
	var regions: Array[Rect2i] = []
	var margins: Array[PackedInt32Array] = []
	var slots: Array[Vector2i] = []
	for dir: int in UnitArt.DIRECTIONS:
		for i: int in frames:
			@warning_ignore("integer_division") # Floor on purpose: the wrapped row.
			var row: int = dir * rows_per_direction + i / columns
			var origin: Vector2i = Vector2i((i % columns) * stride + gutter, row * stride + gutter)
			var used: Rect2i = source.get_region(Rect2i(origin, Vector2i(cell, cell))).get_used_rect()
			var region: Rect2i = region_in_cell(used, cell)
			var margin: PackedInt32Array = slot_margins(used, region)
			origins.append(origin)
			regions.append(region)
			margins.append(margin)
			slots.append(region.size + Vector2i(margin[0] + margin[2], margin[1] + margin[3]))
	var positions: Array[Vector2i] = shelf_pack(slots, max_sheet)
	var size: Vector2i = sheet_size(slots, positions)
	if size.y > max_sheet:
		return {"error": "the packed sheet would be %d px tall, over %d" % [size.y, max_sheet]}
	var image: Image = Image.create_empty(maxi(size.x, ALIGN), maxi(size.y, ALIGN), false, Image.FORMAT_RGBA8)
	var rects: Array = []
	for k: int in regions.size():
		var at: Vector2i = positions[k] + Vector2i(margins[k][0], margins[k][1])
		image.blit_rect(source, Rect2i(origins[k] + regions[k].position, regions[k].size), at)
		rects.append([at.x, at.y, regions[k].size.x, regions[k].size.y, regions[k].position.x, regions[k].position.y])
	return {"image": image, "rects": rects}


## A grid sidecar and its sheets (Images by animation), packed: {"sidecar":
## the packed sidecar, "sheets": Dictionary[StringName, Image], "errors":
## PackedStringArray}. Only the clips the game plays are packed. The packed
## sidecar keeps the grid one's other keys, drops its own (GRID_KEYS,
## GRID_ANIMATION_KEYS), and adds "layout", "pad", and per animation "rects"
## and "sheet_size". The grid sidecar is left as it was. Call it on a sidecar
## that sidecar_errors and layout_errors pass.
static func pack(sidecar: Dictionary, grids: Dictionary) -> Dictionary:
	var packed: Dictionary = sidecar.duplicate(true)
	for key: String in GRID_KEYS:
		packed.erase(key)
	packed["layout"] = LAYOUT
	packed["pad"] = PAD
	var cell: int = int(sidecar["cell"])
	var stride: int = int(sidecar["stride"])
	var gutter: int = int(sidecar["gutter"])
	var anims: Dictionary = {}
	var sheets: Dictionary[StringName, Image] = {}
	var errors: PackedStringArray = PackedStringArray()
	for key: String in sidecar["animations"]:
		if StringName(key) not in UnitArtBuilder.GAME_ANIMS:
			continue
		var info: Dictionary = (sidecar["animations"][key] as Dictionary).duplicate(true)
		var count: int = int(info["frames"])
		var out: Dictionary = pack_animation(
			grids[StringName(key)], count, int(info.get("columns", count)), int(info.get("rows_per_direction", 1)),
			cell, stride, gutter
		)
		if out.has("error"):
			errors.append("%s: %s" % [key, out["error"]])
			continue
		for grid_key: String in GRID_ANIMATION_KEYS:
			info.erase(grid_key)
		var image: Image = out["image"]
		info["rects"] = out["rects"]
		info["sheet_size"] = [image.get_width(), image.get_height()]
		anims[key] = info
		sheets[StringName(key)] = image
	packed["animations"] = anims
	return {"sidecar": packed, "sheets": sheets, "errors": errors}


static func _floor_to_block(v: int) -> int:
	return v - posmod(v, ALIGN)


static func _ceil_to_block(v: int) -> int:
	return _floor_to_block(v + ALIGN - 1)
```

- [ ] **Step 5: Run the tests; they pass**

Run: `make import && godot --headless --path . -s addons/gut/gut_cmdln.gd -gconfig= -gtest=res://tests/view/test_unit_art_packer.gd -gexit`
Expected: PASS. If `test_shelves_take_the_tallest_first_and_wrap` fails, the sort or wrap is wrong; fix the code, not the expected positions. They follow the rule: tallest, then widest, then list order.

- [ ] **Step 6: Commit**

```bash
git add scripts/art/unit_art_packer.gd tests/view/test_unit_art_packer.gd tests/support/test_art.gd
git commit -m "Add UnitArtPacker: trim each frame to its figure and shelf-pack it" -m "A figure fills about a quarter of its grid cell, so most of the 554 MB of unit sheets is transparency. A frame keeps its used box grown by 8 px, snapped to the cell's 4 px block grid, so every drawn pixel and every DXT block is as it was. The sheet pads only where the cell's edge cut a region short.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Prove packed frames draw like grid ones, in engine

This is the spec's §8 step 2 gate. If a close-distance case or an AABB differs, **stop and report to Tim**: the plan rests on margins drawing correctly.

**Files:**
- Create: `scripts/art/pack_probe.gd`
- Modify: `Makefile` (`art-probe`)

**Interfaces:**
- Consumes: `UnitArtPacker.pack`, `UnitArtBuilder.GAME_ANIMS`, `RtsCamera.MIN_DISTANCE`, `RtsCamera.MAX_DISTANCE`, `MainView.CAMERA_START_DISTANCE`.

- [ ] **Step 1: Write `scripts/art/pack_probe.gd`**

```gdscript
extends SceneTree
## Proves packed frames draw as the grid ones do (docs/specs/2026-10-15-art-a4-loading-design.md
## §8, step 2). Windowed, since headless has nothing to read back:
## `make art-probe` (UNITS=a,b for some units, OUT=<dir> to save pairs).
##
## For each unit with a grid render (art-src/units/<unit>/sheets/, or before
## A4's move assets/units/<unit>/), it packs the grid in memory with
## UnitArtPacker and draws chosen frames twice, set up as UnitSprite sets up an
## art body: once cut from the grid, once from the packed sheet (region plus
## margin). Both sheets are uncompressed ImageTextures with mipmaps, so only
## the packing differs. Each pair is drawn from the closest, the opening and
## the farthest camera distance and compared (Image.compute_image_metrics).
## One line each:
##   PROBE <unit> <anim>_<dir> frame=<i> d=<m> max=<0..255> mean=<x> aabb=<same|DIFFERENT>
## then PROBE SUMMARY cases=<n> close_bad=<n> far_bad=<n> aabb_bad=<n>. Exit
## status 1 if a close case differs by more than TOLERANCE, or any AABB does.
## Far differences are for a person to judge: OUT saves every pair over
## TOLERANCE, and one close pair per unit, side by side.

const DISTANCES: Array[float] = [RtsCamera.MIN_DISTANCE, MainView.CAMERA_START_DISTANCE, RtsCamera.MAX_DISTANCE]
const PITCH_DEG: float = 50.0
const SIZE: int = 1024
## The largest channel difference, of 255, still counted as the same pixel.
const TOLERANCE: float = 2.0
const PROBE_ANIMS: Array[StringName] = [&"idle", &"walk", &"attack", &"shoot", &"throw", &"cast", &"place", &"die"]
const PROBE_DIRS: Array[int] = [1, 4]

var _viewport: SubViewport
var _camera: Camera3D
var _sprite: AnimatedSprite3D
var _out: String = OS.get_environment("OUT")
var _cases: int = 0
var _close_bad: int = 0
var _far_bad: int = 0
var _aabb_bad: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_build_stage()
	if not _out.is_empty():
		DirAccess.make_dir_recursive_absolute(_out)
	for unit: String in _units():
		await _probe_unit(unit)
	print("PROBE SUMMARY cases=%d close_bad=%d far_bad=%d aabb_bad=%d" % [_cases, _close_bad, _far_bad, _aabb_bad])
	quit(1 if _close_bad > 0 or _aabb_bad > 0 else 0)


func _build_stage() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(SIZE, SIZE)
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	_camera = Camera3D.new()
	_camera.fov = 75.0
	_viewport.add_child(_camera)
	_sprite = AnimatedSprite3D.new()
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_viewport.add_child(_sprite)


func _units() -> PackedStringArray:
	var asked: String = OS.get_environment("UNITS").strip_edges()
	if not asked.is_empty():
		return asked.split(",", false)
	var out: PackedStringArray = PackedStringArray()
	for unit: String in DirAccess.get_directories_at("res://art-src/units"):
		if not _grid_folder(unit).is_empty():
			out.append(unit)
	return out


# Where the unit's grid render is: art-src once A4 has moved it, else assets
# while its sidecar there is still a grid one.
func _grid_folder(unit: String) -> String:
	var moved: String = "res://art-src/units/%s/sheets/" % unit
	if FileAccess.file_exists(moved + unit + ".json"):
		return moved
	var old: String = "res://assets/units/%s/" % unit
	if FileAccess.file_exists(old + unit + ".json"):
		var side: Variant = JSON.parse_string(FileAccess.get_file_as_string(old + unit + ".json"))
		if side is Dictionary and not (side as Dictionary).has("layout"):
			return old
	return ""


func _probe_unit(unit: String) -> void:
	var folder: String = _grid_folder(unit)
	if folder.is_empty():
		print("PROBE %s SKIPPED no grid render" % unit)
		return
	var sidecar: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(folder + unit + ".json"))
	var grids: Dictionary = {}
	for key: String in sidecar["animations"]:
		if StringName(key) in UnitArtBuilder.GAME_ANIMS:
			var path: String = ProjectSettings.globalize_path(folder + String(sidecar["animations"][key]["sheet"]))
			grids[StringName(key)] = Image.load_from_file(path)
	var packed: Dictionary = UnitArtPacker.pack(sidecar, grids)
	var cell: int = int(sidecar["cell"])
	var stride: int = int(sidecar["stride"])
	var gutter: int = int(sidecar["gutter"])
	_sprite.pixel_size = 1.0 / float(sidecar["pixels_per_meter"])
	_sprite.offset = Vector2(0.0, cell * 0.5 - int(sidecar["feet_px"]))
	var saved_close: bool = false
	for anim: StringName in PROBE_ANIMS:
		if not grids.has(anim):
			continue
		var info: Dictionary = sidecar["animations"][String(anim)]
		var count: int = int(info["frames"])
		var columns: int = int(info.get("columns", count))
		var rows: int = int(info.get("rows_per_direction", 1))
		var grid_sheet: ImageTexture = _mipmapped(grids[anim])
		var packed_sheet: ImageTexture = _mipmapped(packed["sheets"][anim])
		var rects: Array = packed["sidecar"]["animations"][String(anim)]["rects"]
		var frame: int = _probe_frame(anim, info)
		for dir: int in PROBE_DIRS:
			@warning_ignore("integer_division") # Floor on purpose: the wrapped row.
			var row: int = dir * rows + frame / columns
			var from_grid: AtlasTexture = AtlasTexture.new()
			from_grid.atlas = grid_sheet
			from_grid.region = Rect2((frame % columns) * stride + gutter, row * stride + gutter, cell, cell)
			var r: Array = rects[dir * count + frame]
			var from_pack: AtlasTexture = AtlasTexture.new()
			from_pack.atlas = packed_sheet
			from_pack.region = Rect2(r[0], r[1], r[2], r[3])
			from_pack.margin = Rect2(r[4], r[5], cell - int(r[2]), cell - int(r[3]))
			for d: float in DISTANCES:
				_aim(d)
				var a: Image = await _draw(from_grid)
				var aabb_a: AABB = _sprite.get_aabb()
				var b: Image = await _draw(from_pack)
				var aabb_b: AABB = _sprite.get_aabb()
				var metrics: Dictionary = a.compute_image_metrics(b, false)
				var worst: float = float(metrics["max"])
				var same_box: bool = aabb_a.is_equal_approx(aabb_b)
				_cases += 1
				var close: bool = is_equal_approx(d, DISTANCES[0])
				if worst > TOLERANCE:
					if close:
						_close_bad += 1
					else:
						_far_bad += 1
				if not same_box:
					_aabb_bad += 1
				print("PROBE %s %s_%d frame=%d d=%.0f max=%.0f mean=%.4f aabb=%s" % [
					unit, anim, dir, frame, d, worst, float(metrics["mean"]), "same" if same_box else "DIFFERENT",
				])
				if not _out.is_empty() and (worst > TOLERANCE or (close and not saved_close)):
					saved_close = saved_close or close
					_save_pair(a, b, "%s-%s_%d-d%.0f.png" % [unit, anim, dir, d])


# The frame a probe looks at: the middle of an idle, a third into a walk, a
# corpse, and a strike's impact.
func _probe_frame(anim: StringName, info: Dictionary) -> int:
	var count: int = int(info["frames"])
	match anim:
		&"walk":
			@warning_ignore("integer_division") # A frame index: floor on purpose.
			return count / 3
		&"die":
			return count - 1
		&"idle":
			@warning_ignore("integer_division") # A frame index: floor on purpose.
			return count / 2
	var impact: int = int(info.get("impact_frame", -1))
	@warning_ignore("integer_division") # A frame index: floor on purpose.
	return impact if impact >= 0 else count / 2


func _mipmapped(image: Image) -> ImageTexture:
	var copy: Image = image.duplicate() as Image
	if copy.get_format() != Image.FORMAT_RGBA8:
		copy.convert(Image.FORMAT_RGBA8)
	copy.generate_mipmaps()
	return ImageTexture.create_from_image(copy)


# The camera at distance d, pitched as a mission's, looking at the figure's middle.
func _aim(d: float) -> void:
	var target: Vector3 = Vector3(0.0, 0.7, 0.0)
	var pitch: float = deg_to_rad(PITCH_DEG)
	_camera.position = target + Vector3(0.0, sin(pitch), cos(pitch)) * d
	_camera.look_at(target)


func _draw(texture: Texture2D) -> Image:
	var frames: SpriteFrames = SpriteFrames.new()
	frames.add_frame(&"default", texture)
	_sprite.sprite_frames = frames
	_sprite.animation = &"default"
	_sprite.frame = 0
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return _viewport.get_texture().get_image()


func _save_pair(a: Image, b: Image, file: String) -> void:
	var pair: Image = Image.create_empty(SIZE * 2, SIZE, false, a.get_format())
	pair.blit_rect(a, Rect2i(Vector2i.ZERO, a.get_size()), Vector2i.ZERO)
	pair.blit_rect(b, Rect2i(Vector2i.ZERO, b.get_size()), Vector2i(SIZE, 0))
	pair.save_png(_out.path_join(file))
```

- [ ] **Step 2: Make target**

In `Makefile`, add `art-probe` to `.PHONY`, and after `art-attach`:

```make
# Proves packed frames draw like the grid ones (windowed; see the head of
# scripts/art/pack_probe.gd). UNITS=a,b limits it; OUT=<dir> saves pairs.
art-probe: import
	UNITS=$(UNITS) OUT=$(OUT) $(GODOT) --path . -s scripts/art/pack_probe.gd
```

- [ ] **Step 3: Run it on the Shieldman, then on all ten**

Run: `UNITS=shieldman OUT=/private/tmp/claude-501/-Users-timk-Projects-ashenmarch/b5725fc3-76c9-4523-8b76-6119db6f1285/scratchpad/a4/probe make art-probe`
Expected: `PROBE … d=8 max=0 … aabb=same` lines, and `PROBE SUMMARY … close_bad=0 … aabb_bad=0`, exit 0.

Then run `make art-probe OUT=…/probe` for all ten. Open the saved close pair for one unit with the Read tool: the two halves should look identical.

- **If `close_bad` or `aabb_bad` is above 0:** stop. Report the failing lines and one saved pair to Tim. Don't go on to Task 5.
- **If only `far_bad` is above 0:** open the worst far pair. Note its `max` and `mean` for the Task 8 report, then go on.

- [ ] **Step 4: Commit**

```bash
git add scripts/art/pack_probe.gd Makefile
git commit -m "Add make art-probe: packed frames drawn against their grid cells" -m "The plan rests on AtlasTexture margins restoring a trimmed frame's cell in an AnimatedSprite3D. The probe draws chosen frames of every unit both ways, at the closest, opening and farthest camera distances, and compares the pixels. Result on all ten: <SUMMARY line>.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: The packed pipeline, end to end

**Files:**
- Modify: `scripts/art/render_sprites.py`, `scripts/art/blender_test_render.py`
- Modify: `scripts/art/unit_art_packer.gd` (grid checks, symlink guard), `scripts/art/unit_art_builder.gd`, `scripts/art/build_unit_art.gd`
- Create: `scripts/art/pack_unit_art.gd`
- Modify: `view/units/unit_art.gd` (`validate`), `tests/support/test_art.gd`, `tests/view/test_unit_art.gd`, `tests/view/test_unit_art_packer.gd`, `tests/view/test_unit_art_catalog.gd`
- Modify: `Makefile` (`art-build`, `art-render` comment), `scripts/check_asset_layout.sh`
- Move: `assets/units/<id>/<anim>.png` and `assets/units/<id>/<id>.json` → `art-src/units/<id>/sheets/`
- Regenerate: `assets/units/<id>/*.png`, `assets/units/<id>/<id>.json`, `data/art/*.tres`, `data/art/catalog.tres`

**Interfaces:**
- Produces:
  - `static UnitArtPacker.sidecar_errors(sidecar: Dictionary) -> PackedStringArray` and `static UnitArtPacker.layout_errors(sidecar: Dictionary, grids: Dictionary) -> PackedStringArray`: the grid checks, moved from the builder. `grids` holds `Image`s.
  - `static UnitArtPacker.planted_links(folders: PackedStringArray) -> PackedStringArray`
  - `UnitArtBuilder.sidecar_errors`, `layout_errors` and `build` now take a **packed** sidecar.
  - `static TestArt.pack(side: Dictionary) -> Dictionary`: `{"sidecar", "sheets", "textures", "errors"}`. `TestArt.sheets()` is removed.

- [ ] **Step 1: The renderer writes grids to `art-src/units/<id>/sheets/`**

In `scripts/art/render_sprites.py`:
- Delete `IMPORT_SETTINGS` and `write_import_settings`, and the `write_import_settings(out_dir / sheet)` call in `render_unit`.
- Add `SHEETS_DIR = "sheets"` beside `PROP_CELL`.
- In `render_unit`, make `out_dir = out_root / unit / SHEETS_DIR`.
- In `main()`:

```python
        sidecar = render_unit(parsed.name, REPO / "art-src", REPO / "art-src" / "units", parsed.engine, REPO)
        print(f"rendered {parsed.name}: {sorted(sidecar['animations'])} -> art-src/units/{parsed.name}/sheets/ (make art-build packs them)")
```

- In the module docstring, change "Sheets, import settings and a JSON sidecar go to assets/units/<unit>/" to "Grid sheets and a JSON sidecar go to art-src/units/<unit>/sheets/, where make art-build packs them into assets/units/<unit>/". Drop "import settings" from the audition sentence.

In `scripts/art/blender_test_render.py`:
- `render()` returns `root / "assets" / "units" / "fixture" / "sheets"`.
- `test_sheet_layout_and_import_settings` becomes:

```python
    def test_sheet_layout_and_no_import_settings(self) -> None:
        walk = self.sidecar["animations"]["walk"]
        self.assertEqual((walk["columns"], walk["rows_per_direction"]), (12, 1))
        self.assertEqual(self.walk.shape[:2], (8 * rs.STRIDE, 12 * rs.STRIDE))
        self.assertFalse((self.out / "walk.png.import").exists(), "a grid is packed before Godot sees it")
```

- `test_symlinked_file_in_the_output_folder_is_refused` plants `out = self.root / "assets" / "units" / "fixture" / "sheets"`, then `(out / "idle.png").symlink_to(self.elsewhere / "victim")`, and asserts `"idle.png"` is in the message.
- `test_symlinked_output_folder_is_refused` makes `self.root / "assets" / "units" / "fixture"` and symlinks its `sheets`:

```python
    def test_symlinked_output_folder_is_refused(self) -> None:
        (self.root / "assets" / "units" / "fixture").mkdir(parents=True)
        (self.root / "assets" / "units" / "fixture" / "sheets").symlink_to(self.elsewhere, target_is_directory=True)
        self.assertIn("symlink", self.refused(self.render_unit))
```

- In the audition test that calls `render_fixture_with_audition` (around line 689), delete the `self.assertFalse((assets / "idle_alt.png.import").exists())` line. No `.import` files are written now, so it would pass vacuously.

In `Makefile`, change the `art-render` comment to: "Renders UNIT's animations into art-src/units/UNIT/sheets/ (grids; make art-build packs them) plus its review sheets (free)."

Run `make test-art`. Expected: all Python and Blender tests pass. Then commit:

```bash
git add scripts/art/render_sprites.py scripts/art/blender_test_render.py Makefile
git commit -m "Render unit grids into art-src/units/<id>/sheets/" -m "The grid sheets become source: make art-build packs them into game-ready sheets in assets/. Godot skips art-src, so the grids get no import settings and never reach an export.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 2: Move the grid checks into the packer**

Cut these from `scripts/art/unit_art_builder.gd` and paste them into `scripts/art/unit_art_packer.gd`, below `GRID_ANIMATION_KEYS`:
- `SIDECAR_KEYS` and `ANIMATION_KEYS`, renamed `GRID_SIDECAR_KEYS` and `GRID_ANIMATION_REQUIRED`;
- `sidecar_errors`;
- `layout_errors`.

In the pasted `sidecar_errors`, use the new names: `SIDECAR_KEYS` → `GRID_SIDECAR_KEYS`, `ANIMATION_KEYS` → `GRID_ANIMATION_REQUIRED`. Its doc's "build() and layout_errors()" becomes "pack() and layout_errors()".

Then in the pasted `layout_errors`:
- its doc's "sheets is as for build()" becomes "grids maps each animation name (StringName) to its grid Image";
- the parameter is `grids: Dictionary`;
- `var sheet: Texture2D = sheets.get(anim) as Texture2D` becomes `var sheet: Image = grids.get(anim) as Image`;
- `var size: Vector2 = sheet.get_size()` becomes `var size: Vector2i = sheet.get_size()`.

Every message stays word for word.

Add the symlink guard to the packer:

```gdscript
## Symlinks at or on the way to these folders (res:// or user:// paths), or
## inside them. The repo is public, so a PR could plant a symlinked sheet or
## folder and have a pack written over a file elsewhere; render_sprites.py
## refuses the same. A folder that doesn't exist yet passes.
static func planted_links(folders: PackedStringArray) -> PackedStringArray:
	var found: PackedStringArray = PackedStringArray()
	for folder: String in folders:
		var scheme_end: int = folder.find("://") + 3
		var walked: String = folder.substr(0, scheme_end)
		var whole: bool = true
		for part: String in folder.substr(scheme_end).split("/", false):
			var parent: DirAccess = DirAccess.open(walked)
			if parent == null:
				whole = false
				break
			if parent.is_link(part):
				found.append(walked.path_join(part))
				whole = false
				break
			walked = walked.path_join(part)
		if not whole:
			continue
		var inside: DirAccess = DirAccess.open(folder)
		if inside == null:
			continue
		inside.include_hidden = true
		inside.list_dir_begin()
		var name: String = inside.get_next()
		while not name.is_empty():
			if inside.is_link(name):
				found.append(folder.path_join(name))
			name = inside.get_next()
		inside.list_dir_end()
	return found
```

- [ ] **Step 3: Move the grid tests, and add the guard's test**

Cut these from `tests/view/test_unit_art.gd` and paste them into `tests/view/test_unit_art_packer.gd`:
- every test from `test_a_sound_layout_has_no_errors` through `test_sidecar_errors_ignore_animations_the_game_does_not_play`;
- the `_blank_sheet` helper.

Then, in the pasted text only:
- `UnitArtBuilder.layout_errors(` → `UnitArtPacker.layout_errors(`
- `UnitArtBuilder.sidecar_errors(` → `UnitArtPacker.sidecar_errors(`
- `TestArt.sheets(side)` → `TestArt.grids(side)`
- `ImageTexture.create_from_image(X)` → `X` (two places use it)
- `_blank_sheet` returns `Image`:

```gdscript
# A blank grid Image of exactly this size.
func _blank_sheet(width: int, height: int) -> Image:
	return Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
```

Delete `test_wrapped_sheets_find_each_frame` from `test_unit_art.gd`. `test_every_packed_frame_is_its_grid_cell_byte_for_byte` packs a wrapped layout (30 frames, 24 columns, 2 rows) and covers it.

Append to `tests/view/test_unit_art_packer.gd`:

```gdscript
func test_planted_links_are_found() -> void:
	var root: String = "user://test_packer_links"
	DirAccess.make_dir_recursive_absolute(root + "/out")
	DirAccess.make_dir_recursive_absolute(root + "/elsewhere")
	var out: DirAccess = DirAccess.open(root + "/out")
	if not out.file_exists("idle.png"):
		assert_eq(out.create_link(ProjectSettings.globalize_path(root + "/elsewhere/victim.png"), "idle.png"), OK)
	assert_eq(UnitArtPacker.planted_links(PackedStringArray([root + "/out"])), PackedStringArray([root + "/out/idle.png"]))
	var top: DirAccess = DirAccess.open(root)
	if not top.dir_exists("linked"):
		assert_eq(top.create_link(ProjectSettings.globalize_path(root + "/elsewhere"), "linked"), OK)
	assert_eq(UnitArtPacker.planted_links(PackedStringArray([root + "/linked/units"])), PackedStringArray([root + "/linked"]), "a link on the way")
	assert_eq(UnitArtPacker.planted_links(PackedStringArray([root + "/elsewhere", root + "/not_yet"])), PackedStringArray())


func test_the_real_shieldman_grid_has_a_sound_layout() -> void:
	var folder: String = "res://art-src/units/shieldman/sheets/"
	if not FileAccess.file_exists(folder + "shieldman.json"):
		pending("%sshieldman.json is not rendered; run make art-render UNIT=shieldman" % folder)
		return
	var side: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(folder + "shieldman.json"))
	assert_eq(UnitArtPacker.sidecar_errors(side), PackedStringArray())
	var grids: Dictionary = {}
	for key: String in side["animations"]:
		grids[StringName(key)] = Image.load_from_file(ProjectSettings.globalize_path(folder + String(side["animations"][key]["sheet"])))
	assert_eq(UnitArtPacker.layout_errors(side, grids), PackedStringArray())


# A committed PNG, read as pixels (not the imported texture).
func _png(path: String) -> Image:
	var image: Image = Image.load_from_file(ProjectSettings.globalize_path(path))
	if image != null and image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image


func test_every_committed_frame_is_its_grid_cell_byte_for_byte() -> void:
	var checked: int = 0
	for unit: String in DirAccess.get_directories_at("res://art-src/units"):
		var grid_dir: String = "res://art-src/units/%s/sheets/" % unit
		var packed_dir: String = "res://assets/units/%s/" % unit
		if not FileAccess.file_exists(grid_dir + unit + ".json"):
			continue
		var grid_side: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(grid_dir + unit + ".json"))
		var packed_side: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(packed_dir + unit + ".json"))
		var cell: int = int(grid_side["cell"])
		var stride: int = int(grid_side["stride"])
		var gutter: int = int(grid_side["gutter"])
		for key: String in packed_side["animations"]:
			var g: Dictionary = grid_side["animations"][key]
			var p: Dictionary = packed_side["animations"][key]
			var grid: Image = _png(grid_dir + String(g["sheet"]))
			var packed: Image = _png(packed_dir + String(p["sheet"]))
			var count: int = int(g["frames"])
			var columns: int = int(g.get("columns", count))
			var rows: int = int(g.get("rows_per_direction", 1))
			for dir: int in UnitArt.DIRECTIONS:
				for i: int in count:
					var r: Array = p["rects"][dir * count + i]
					@warning_ignore("integer_division") # Floor on purpose: the wrapped row.
					var origin: Vector2i = Vector2i((i % columns) * stride + gutter, (dir * rows + i / columns) * stride + gutter)
					var region: Rect2i = Rect2i(int(r[4]), int(r[5]), int(r[2]), int(r[3]))
					var kept: PackedByteArray = packed.get_region(Rect2i(int(r[0]), int(r[1]), region.size.x, region.size.y)).get_data()
					if kept != grid.get_region(Rect2i(origin + region.position, region.size)).get_data():
						fail_test("%s %s d%d f%d: the packed frame differs from its grid cell" % [unit, key, dir, i])
						return
					var used: Rect2i = grid.get_region(Rect2i(origin, Vector2i(cell, cell))).get_used_rect()
					if used.has_area() and not region.encloses(used):
						fail_test("%s %s d%d f%d: the figure reaches outside its packed region" % [unit, key, dir, i])
						return
					checked += 1
	if checked == 0:
		pending("no grid render in art-src/units/*/sheets/")
		return
	pass_test("%d committed frames are their grid cells" % checked)
```

- [ ] **Step 4: The builder takes packed sidecars**

In `scripts/art/unit_art_builder.gd`:

1. Rewrite the class doc. The builder turns a **packed** sidecar (`assets/units/<id>/<id>.json`, written by `pack_unit_art.gd`) and its sheets into a UnitArt. Each frame is an `AtlasTexture` whose region is its rect in the packed sheet and whose margin puts back the rest of the cell, so every frame is `cell` px square.
2. Replace the constants:

```gdscript
## What build() and layout_errors() read from a packed sidecar without a default.
const SIDECAR_KEYS: Array[String] = ["unit", "cell", "feet_px", "pixels_per_meter", "animations", "layout"]
const ANIMATION_KEYS: Array[String] = ["sheet", "frames", "fps", "loop", "rects", "sheet_size"]
```

3. `sidecar_errors` keeps its body. After the top-level key loop, add:

```gdscript
	if sidecar.has("layout") and sidecar["layout"] != UnitArtPacker.LAYOUT:
		errors.append("layout is \"%s\", not \"%s\"" % [sidecar["layout"], UnitArtPacker.LAYOUT])
```

4. Replace `layout_errors`:

```gdscript
## Why the packed sidecar doesn't fit its sheets, or an empty array if it
## does. Only the animations the game plays are checked. A sheet must be
## exactly the size the pack made it (sheet_size): a stale sheet beside a newer
## sidecar would be cut in the wrong places without a word. Every rect must be
## [x, y, w, h, cell_x, cell_y], lie inside its sheet and inside the cell, and
## there must be one per frame per direction. sheets is as for build().
static func layout_errors(sidecar: Dictionary, sheets: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var cell: int = int(sidecar["cell"])
	var anims: Dictionary = sidecar["animations"]
	for key: String in anims:
		var anim: StringName = StringName(key)
		if anim not in GAME_ANIMS:
			continue
		var info: Dictionary = anims[key]
		var count: int = int(info["frames"])
		var sheet: Texture2D = sheets.get(anim) as Texture2D
		if sheet == null:
			errors.append("%s: no sheet" % key)
			continue
		var size: Vector2i = Vector2i(sheet.get_size())
		var packed_size: Array = info["sheet_size"]
		if packed_size.size() != 2 or size != Vector2i(int(packed_size[0]), int(packed_size[1])):
			errors.append("%s: the sheet is %dx%d, but the sidecar packed it %s" % [key, size.x, size.y, packed_size])
			continue
		var rects: Array = info["rects"]
		if rects.size() != UnitArt.DIRECTIONS * count:
			errors.append("%s: %d rects for %d frames in %d directions" % [key, rects.size(), count, UnitArt.DIRECTIONS])
			continue
		for k: int in rects.size():
			var r: Variant = rects[k]
			if not r is Array or (r as Array).size() != 6:
				errors.append("%s: rect %d is not [x, y, w, h, cell_x, cell_y]" % [key, k])
				break
			var x: int = int(r[0])
			var y: int = int(r[1])
			var w: int = int(r[2])
			var h: int = int(r[3])
			if w <= 0 or h <= 0 or x < 0 or y < 0 or x + w > size.x or y + h > size.y:
				errors.append("%s: rect %d (%d, %d, %d, %d) is not inside the %dx%d sheet" % [key, k, x, y, w, h, size.x, size.y])
				break
			if int(r[4]) < 0 or int(r[5]) < 0 or int(r[4]) + w > cell or int(r[5]) + h > cell:
				errors.append("%s: rect %d sits outside the %d px cell" % [key, k, cell])
				break
	return errors
```

5. In `build()`:
   - drop `var stride` and `var gutter`;
   - drop `columns` and `rows_per_direction`;
   - add `var rects: Array = info["rects"]` after `var count`;
   - the inner loop becomes:

```gdscript
			for i: int in count:
				var r: Array = rects[dir * count + i]
				var frame: AtlasTexture = AtlasTexture.new()
				frame.atlas = sheet
				frame.region = Rect2(r[0], r[1], r[2], r[3])
				# What the trim took, put back: every frame is the whole cell again.
				frame.margin = Rect2(r[4], r[5], art.cell_px - int(r[2]), art.cell_px - int(r[3]))
				frames.add_frame(name, frame)
```

In `scripts/art/build_unit_art.gd`, the head's first sentence becomes: "Builds data/art/<unit>.tres from the packed sheets in assets/units/<unit>/ (pack_unit_art.gd), and lists it in data/art/catalog.tres." Its error hints say `make art-build UNIT=%s`, which packs first, instead of `make art-render`.

- [ ] **Step 5: `validate` checks each frame is a whole cell; TestArt packs**

In `view/units/unit_art.gd` `validate()`, replace the per-direction loop:

```gdscript
	for anim: StringName in _anims():
		for dir: int in DIRECTIONS:
			var name: StringName = anim_name(anim, dir)
			if not frames.has_animation(name) or frames.get_frame_count(name) == 0:
				errors.append("%s: %s has no frames for direction %d" % [who, anim, dir])
				continue
			for i: int in frames.get_frame_count(name):
				var frame: Texture2D = frames.get_frame_texture(name, i)
				if frame == null or frame.get_width() != cell_px or frame.get_height() != cell_px:
					errors.append("%s: %s frame %d of direction %d is not a whole %d px cell" % [who, anim, i, dir, cell_px])
					break
```

In `tests/support/test_art.gd`:
- update the head comment: TestArt is built the way the real one is (packed by `UnitArtPacker`, built by `UnitArtBuilder`) from blank grids;
- delete `sheets()`;
- `art()` becomes:

```gdscript
static func art(unit_id: StringName = &"shieldman", anims: Dictionary = {}, bursts: bool = false) -> UnitArt:
	var packed: Dictionary = pack(sidecar(unit_id, anims, bursts))
	return UnitArtBuilder.build(packed["sidecar"], packed["textures"])


## The grid sidecar packed as make art-build packs a render: UnitArtPacker.pack's
## {"sidecar", "sheets", "errors"} plus "textures", an ImageTexture of each sheet.
static func pack(side: Dictionary) -> Dictionary:
	var packed: Dictionary = UnitArtPacker.pack(side, grids(side))
	var textures: Dictionary = {}
	for anim: StringName in packed["sheets"]:
		textures[anim] = ImageTexture.create_from_image(packed["sheets"][anim])
	packed["textures"] = textures
	return packed
```

Then run `grep -rn "TestArt.sheets" tests` and replace every remaining caller:
- `UnitArtBuilder.build(side, TestArt.sheets(side))` → `UnitArtBuilder.build(TestArt.pack(side)["sidecar"], TestArt.pack(side)["textures"])`, with the pack held in a local first;
- any layout check → `UnitArtPacker` with `TestArt.grids`.

- [ ] **Step 6: Update the builder tests**

In `tests/view/test_unit_art.gd`, in `test_built_art_is_valid_and_laid_out_like_the_sheet`, replace the region assertion (`var atlas … assert_eq(atlas.region, …)`) with:

```gdscript
	var atlas: AtlasTexture = art.frames.get_frame_texture(walk, 1) as AtlasTexture
	assert_eq(Vector2i(atlas.get_width(), atlas.get_height()), Vector2i(TestArt.CELL, TestArt.CELL), "a packed frame is its whole cell again")
	var rect: Array = TestArt.pack(TestArt.sidecar(&"shieldman"))["sidecar"]["animations"]["walk"]["rects"][2 * 12 + 1]
	assert_eq(atlas.region, Rect2(rect[0], rect[1], rect[2], rect[3]))
	assert_eq(atlas.margin, Rect2(rect[4], rect[5], TestArt.CELL - int(rect[2]), TestArt.CELL - int(rect[3])))
```

`test_the_builder_reads_figure_height_when_present` becomes:

```gdscript
func test_the_builder_reads_figure_height_when_present() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	var packed: Dictionary = TestArt.pack(side)
	assert_eq(UnitArtBuilder.build(packed["sidecar"], packed["textures"]).figure_height_m, 0.0, "absent: unknown")
	side["figure_height_m"] = 1.41
	packed = TestArt.pack(side)
	assert_almost_eq(UnitArtBuilder.build(packed["sidecar"], packed["textures"]).figure_height_m, 1.41, 0.0001)
```

Append:

```gdscript
func test_a_sound_packed_layout_has_no_errors() -> void:
	var packed: Dictionary = TestArt.pack(TestArt.sidecar(&"x"))
	assert_eq(UnitArtBuilder.sidecar_errors(packed["sidecar"]), PackedStringArray())
	assert_eq(UnitArtBuilder.layout_errors(packed["sidecar"], packed["textures"]), PackedStringArray())


func test_a_grid_sidecar_is_refused_by_the_builder() -> void:
	var errors: String = " ".join(UnitArtBuilder.sidecar_errors(TestArt.sidecar(&"x")))
	assert_string_contains(errors, "no \"layout\"")
	assert_string_contains(errors, "walk: no \"rects\"")


func test_layout_rejects_a_stale_packed_sheet() -> void:
	var packed: Dictionary = TestArt.pack(TestArt.sidecar(&"x"))
	var stale: Image = Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	packed["textures"][&"walk"] = ImageTexture.create_from_image(stale)
	assert_string_contains(" ".join(UnitArtBuilder.layout_errors(packed["sidecar"], packed["textures"])), "walk: the sheet is 4x4, but the sidecar packed it")


func test_layout_rejects_rects_that_do_not_fit() -> void:
	var packed: Dictionary = TestArt.pack(TestArt.sidecar(&"x"))
	var side: Dictionary = packed["sidecar"]
	(side["animations"]["walk"]["rects"] as Array).pop_back()
	side["animations"]["attack"]["rects"][0] = [0, 0, 100000, 4, 0, 0]
	side["animations"]["die"]["rects"][0] = [0, 0, 4, 4, TestArt.CELL, 0]
	side["animations"]["idle"]["rects"][0] = [1, 2, 3]
	var errors: String = " ".join(UnitArtBuilder.layout_errors(side, packed["textures"]))
	assert_string_contains(errors, "walk: 95 rects for 12 frames in 8 directions")
	assert_string_contains(errors, "attack: rect 0 (0, 0, 100000, 4) is not inside")
	assert_string_contains(errors, "die: rect 0 sits outside the 8 px cell")
	assert_string_contains(errors, "idle: rect 0 is not [x, y, w, h, cell_x, cell_y]")


func test_validate_catches_a_frame_that_is_not_a_whole_cell() -> void:
	var art: UnitArt = TestArt.art()
	var cut: AtlasTexture = art.frames.get_frame_texture(&"walk_2", 3) as AtlasTexture
	cut.margin = Rect2()
	assert_string_contains(" ".join(art.validate()), "walk frame 3 of direction 2 is not a whole 8 px cell")
```

Keep `test_the_real_shieldman_sidecar_has_a_sound_layout` as it is. After Step 8 it reads the packed sidecar and the imported packed sheets.

In `tests/view/test_unit_art_catalog.gd`, in `test_the_committed_shieldman_art_is_valid_and_laid_out_like_the_render`, replace the two `wrapped` lines with:

```gdscript
	var wrapped: AtlasTexture = art.frames.get_frame_texture(&"die_3", 25) as AtlasTexture
	assert_eq(Vector2i(wrapped.get_width(), wrapped.get_height()), Vector2i(160, 160), "a packed frame is its whole cell")
	assert_true(Rect2(Vector2.ZERO, wrapped.atlas.get_size()).encloses(wrapped.region), "cut from inside its sheet")
```

- [ ] **Step 7: `pack_unit_art.gd`, `make art-build`, the layout check**

Create `scripts/art/pack_unit_art.gd`:

```gdscript
extends SceneTree
## Packs one unit's grid render, art-src/units/<unit>/sheets/ (the sidecar
## <unit>.json and a sheet per animation, from make art-render), into
## assets/units/<unit>/: a trimmed sheet per clip the game plays, its
## .png.import (written only when missing, so a repacked sheet keeps its uid),
## and the packed sidecar <unit>.json. UnitArtPacker says how. Run
## `make art-build UNIT=<unit>`, which packs, imports, then builds the UnitArt.
## Nothing is read or written through a symlink.

const SOURCE: String = "res://art-src/units/%s/sheets/"
const OUTPUT: String = "res://assets/units/%s/"
## Mipmapped, VRAM-compressed sprite sheets; Godot fills in the rest on import.
const IMPORT_SETTINGS: String = """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
mipmaps/generate=true
mipmaps/limit=-1
process/fix_alpha_border=true
process/premult_alpha=false
detect_3d/compress_to=0
"""


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("usage: godot --headless --path . -s scripts/art/pack_unit_art.gd -- <unit_id>")
		quit(2)
		return
	quit(0 if _pack(args[0]) else 1)


## True when the unit was packed. As in build_unit_art.gd, false is the failure
## value, so an unforeseen script error exits non-zero instead of looking like
## success.
func _pack(unit: String) -> bool:
	if RegEx.create_from_string("^[a-z0-9_]+$").search(unit) == null:
		printerr("pack_unit_art: %s is not a unit name (lowercase letters, digits and _)" % unit)
		return false
	var source: String = SOURCE % unit
	var output: String = OUTPUT % unit
	var links: PackedStringArray = UnitArtPacker.planted_links(PackedStringArray([source, output]))
	if not links.is_empty():
		printerr("pack_unit_art: refusing to read or write through a symlink: %s" % ", ".join(links))
		return false
	var sidecar_path: String = source + unit + ".json"
	var sidecar: Variant = null
	if FileAccess.file_exists(sidecar_path):
		sidecar = JSON.parse_string(FileAccess.get_file_as_string(sidecar_path))
	if not sidecar is Dictionary:
		printerr("pack_unit_art: %s is missing or not JSON; run make art-render UNIT=%s" % [sidecar_path, unit])
		return false
	var missing: PackedStringArray = UnitArtPacker.sidecar_errors(sidecar)
	if not missing.is_empty():
		printerr("pack_unit_art: %s is incomplete; run make art-render UNIT=%s\n%s" % [sidecar_path, unit, "\n".join(missing)])
		return false
	if String(sidecar["unit"]) != unit:
		printerr("pack_unit_art: %s is for unit \"%s\", not \"%s\"" % [sidecar_path, sidecar["unit"], unit])
		return false
	var grids: Dictionary = {}
	for key: String in sidecar["animations"]:
		if StringName(key) not in UnitArtBuilder.GAME_ANIMS:
			continue
		var path: String = source + String(sidecar["animations"][key]["sheet"])
		var grid: Image = Image.load_from_file(ProjectSettings.globalize_path(path)) if FileAccess.file_exists(path) else null
		if grid == null:
			printerr("pack_unit_art: %s did not load" % path)
			return false
		grids[StringName(key)] = grid
	var layout: PackedStringArray = UnitArtPacker.layout_errors(sidecar, grids)
	if not layout.is_empty():
		printerr("pack_unit_art: %s does not fit its sheets:\n%s" % [sidecar_path, "\n".join(layout)])
		return false
	var packed: Dictionary = UnitArtPacker.pack(sidecar, grids)
	var errors: PackedStringArray = packed["errors"]
	if not errors.is_empty():
		printerr("pack_unit_art: %s" % "\n".join(errors))
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var before: int = 0
	var after: int = 0
	var sheets: Dictionary = packed["sheets"]
	for anim: StringName in sheets:
		var image: Image = sheets[anim]
		var sheet: String = output + String(packed["sidecar"]["animations"][String(anim)]["sheet"])
		if image.save_png(ProjectSettings.globalize_path(sheet)) != OK:
			printerr("pack_unit_art: could not write %s" % sheet)
			return false
		if not FileAccess.file_exists(sheet + ".import"):
			var settings: FileAccess = FileAccess.open(sheet + ".import", FileAccess.WRITE)
			if settings == null:
				printerr("pack_unit_art: could not write %s.import" % sheet)
				return false
			settings.store_string(IMPORT_SETTINGS)
			settings.close()
		var grid: Image = grids[anim]
		before += UnitArt.texture_bytes(grid.get_width(), grid.get_height(), Image.FORMAT_DXT5, true)
		after += UnitArt.texture_bytes(image.get_width(), image.get_height(), Image.FORMAT_DXT5, true)
	var out_sidecar: FileAccess = FileAccess.open(output + unit + ".json", FileAccess.WRITE)
	if out_sidecar == null:
		printerr("pack_unit_art: could not write %s%s.json" % [output, unit])
		return false
	out_sidecar.store_string(JSON.stringify(packed["sidecar"], "  ", true) + "\n")
	out_sidecar.close()
	print("packed %s: %d sheets, %.1f MB -> %.1f MB at DXT5 with mipmaps, into %s" % [unit, sheets.size(), before / 1e6, after / 1e6, output])
	return true
```

In `Makefile`, replace `art-build`:

```make
# Packs UNIT's grid render (art-src/units/UNIT/sheets/) into trimmed sheets in
# assets/units/UNIT/, imports them, then builds data/art/UNIT.tres and lists it
# in data/art/catalog.tres (scripts/art/pack_unit_art.gd, build_unit_art.gd).
art-build: import
	$(GODOT) --headless --path . -s scripts/art/pack_unit_art.gd -- $(UNIT)
	$(GODOT) --headless --path . --import
	$(GODOT) --headless --path . -s scripts/art/build_unit_art.gd -- $(UNIT)
```

In `scripts/check_asset_layout.sh`, after `expect_lfs assets/units/shieldman/walk.png`:

```bash
expect_lfs art-src/units/shieldman/sheets/walk.png
expect_plain art-src/units/shieldman/sheets/shieldman.json
expect_plain assets/units/shieldman/shieldman.json
```

- [ ] **Step 8: Move the grids, then repack and rebuild all ten**

For each unit in `blightbag drifter husk longbow reaver ripper sapper shieldman stormcaller warden`:

```bash
mkdir -p art-src/units/<unit>/sheets
git mv assets/units/<unit>/<anim>.png art-src/units/<unit>/sheets/<anim>.png   # each of its sheets
git mv assets/units/<unit>/<unit>.json art-src/units/<unit>/sheets/<unit>.json
```

Run one plain `git mv` per file if the worktree guard refuses a loop. The `.png.import` files stay in `assets/units/<unit>/`, so each repacked sheet keeps its uid.

Then, per unit: `make art-build UNIT=<unit>`. Expected, ten times: `packed <unit>: N sheets, X MB -> Y MB …`, with the total about 554 → 188 MB, then `built res://data/art/<unit>.tres …`.

Run `make check-layout`. Expected: all `ok`.

- [ ] **Step 9: Verify everything**

1. Run `make import`, the whole suite and `make check-sim`. Expected: PASS, including:
   - `test_every_committed_frame_is_its_grid_cell_byte_for_byte` (about 10,000 frames);
   - `test_every_v1_unit_has_valid_committed_art`;
   - `test_unit_art_timing.gd`.
2. Run `make test-art`. Expected: PASS.
3. Run `make art-probe`. Expected: the same SUMMARY as Task 4: the grids are now in `art-src`.
4. Run `make export-web`, then `ls -l build/web/index.pck`. Expected: about 195 MB.
5. Check the pck carries no grid, no sidecar JSON and no etc2: `LC_ALL=C grep -a -c 'art-src/' build/web/index.pck` gives `0`, and so does the same grep for `units/[a-z_]*/[a-z_]*\.json`.
6. Get the LFS growth: `git lfs ls-files -s`, summed as in brainstorming. Note it for the PR.

- [ ] **Step 10: Commit**

```bash
git add -A assets/units art-src/units data/art scripts/art tests view/units/unit_art.gd Makefile scripts/check_asset_layout.sh
git commit -m "Pack every unit's sheets: 554 MB of DXT5 becomes about <n> MB" -m "make art-build now packs the renderer's grids (moved to art-src/units/<id>/sheets/) into trimmed sheets, then builds each frame as an AtlasTexture whose margin restores its cell, so UnitSprite is unchanged. Every committed frame is checked byte for byte against its grid cell, and the probe still draws them identically.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Load art per roster

**Files:**
- Rewrite: `view/units/unit_art_catalog.gd`
- Create: `view/units/unit_art_set.gd`
- Modify: `view/mission_launch.gd`, `view/units/units_view.gd`, `view/main.gd`, `scripts/art/build_unit_art.gd`
- Regenerate: `data/art/catalog.tres`
- Test: `tests/view/test_unit_art_set.gd`, `tests/view/test_mission_launch_types.gd` (new); `tests/view/test_unit_art_catalog.gd`, `test_main_view.gd`, `test_unit_art_view.gd`, `test_unit_art_timing.gd` (modify)

**Interfaces:**
- Consumes: `UnitArt.sheet_bytes()`, `MainView.art_load_ms`, `UnitsView.loaded_arts()` (Task 1).
- Produces:
  - `UnitArtCatalog`: `@export var paths: Dictionary[StringName, String]`, `has(id) -> bool`, `path_of(id) -> String`, `ids() -> Array[StringName]` (sorted), `put(id, path)`, `load_art(id) -> UnitArt`, `static load_or_new(path)`. Removed: `arts`, `find`, `invalid_reasons`, `without_invalid`.
  - `UnitArtSet`: `static for_types(type_ids: Array[StringName], catalog: UnitArtCatalog) -> UnitArtSet`, `static of(arts: Array[UnitArt]) -> UnitArtSet`, `find(id) -> UnitArt`, `loaded_ids() -> Array[StringName]`, `arts() -> Array[UnitArt]`, `sheet_bytes() -> int`, `var load_ms: int`.
  - `MissionLaunch.unit_types() -> Array[StringName]` (sorted, no repeats).
  - `UnitsView.setup(world, selection, gibs, arts: UnitArtSet = null)`.
  - `var MainView.art_catalog_path: String`. `MainView.load_art` is removed.

- [ ] **Step 1: Write the failing tests**

Create `tests/view/test_unit_art_set.gd`:

```gdscript
extends GutTest
## UnitArtSet: one game's unit art. The types it is given load at once and no
## others do. A type it missed loads late, with one warning. Broken art is left
## out with a warning per reason. Releasing the set releases its art.

const DIR: String = "user://test_unit_art_set"


func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)


# A catalog listing TestArt for each id, each saved to DIR/<id>.tres; those in
# `broken` lack a direction of idle.
func _catalog(ids: Array[StringName], broken: Array[StringName] = []) -> UnitArtCatalog:
	var catalog: UnitArtCatalog = UnitArtCatalog.new()
	for id: StringName in ids + broken:
		var art: UnitArt = TestArt.art(id)
		if id in broken:
			art.frames.remove_animation(&"idle_5")
		var path: String = "%s/%s.tres" % [DIR, id]
		assert_eq(ResourceSaver.save(art, path), OK)
		catalog.put(id, path)
	return catalog


func test_it_loads_the_types_it_is_given_and_no_others() -> void:
	var catalog: UnitArtCatalog = _catalog([&"shieldman", &"husk", &"ripper"])
	var arts: UnitArtSet = UnitArtSet.for_types([&"shieldman", &"husk"], catalog)
	assert_eq(Array(arts.loaded_ids()), [&"husk", &"shieldman"])
	assert_true(ResourceLoader.has_cached(DIR + "/shieldman.tres"))
	assert_false(ResourceLoader.has_cached(DIR + "/ripper.tres"), "not asked for, not loaded")


func test_a_type_the_list_missed_loads_late_with_one_warning() -> void:
	var arts: UnitArtSet = UnitArtSet.for_types([&"shieldman"], _catalog([&"shieldman", &"ripper"]))
	assert_not_null(arts.find(&"ripper"), "a stray type still gets its art")
	assert_not_null(arts.find(&"ripper"))
	assert_push_warning("UnitArtSet: ripper's art loaded late")
	assert_push_warning_count(1)


func test_a_type_without_art_is_a_quiet_placeholder() -> void:
	var arts: UnitArtSet = UnitArtSet.for_types([&"shieldman", &"villager"], _catalog([&"shieldman"]))
	assert_null(arts.find(&"villager"))
	assert_push_warning_count(0)


func test_broken_art_is_left_out_with_a_warning_per_reason() -> void:
	var arts: UnitArtSet = UnitArtSet.for_types([&"shieldman", &"reaver"], _catalog([&"shieldman"], [&"reaver"]))
	assert_null(arts.find(&"reaver"), "a placeholder, and the game starts")
	assert_null(arts.find(&"reaver"), "tried once")
	assert_push_warning("UnitArtSet: unit art left out: reaver: idle has no frames for direction 5")
	assert_push_warning_count(1)
	assert_eq(Array(arts.loaded_ids()), [&"shieldman"])


func test_sheet_bytes_add_up_the_loaded_art() -> void:
	var arts: UnitArtSet = UnitArtSet.for_types([&"shieldman", &"husk"], _catalog([&"shieldman", &"husk"]))
	var expected: int = 0
	for art: UnitArt in arts.arts():
		expected += art.sheet_bytes()
	assert_gt(expected, 0)
	assert_eq(arts.sheet_bytes(), expected)


func test_releasing_the_set_releases_its_art() -> void:
	var arts: UnitArtSet = UnitArtSet.for_types([&"shieldman"], _catalog([&"shieldman"]))
	assert_true(ResourceLoader.has_cached(DIR + "/shieldman.tres"))
	arts = null
	assert_false(ResourceLoader.has_cached(DIR + "/shieldman.tres"))


func test_art_in_memory_needs_no_catalog() -> void:
	var arts: UnitArtSet = UnitArtSet.of([TestArt.art(&"shieldman")])
	assert_not_null(arts.find(&"shieldman"))
	assert_null(arts.find(&"husk"))
	assert_push_warning_count(0)
```

Create `tests/view/test_mission_launch_types.gd`:

```gdscript
extends GutTest
## MissionLaunch.unit_types: the types a launch can bring onto the field, which
## MainView loads art for before the first frame. The golden replays pin that
## nothing in a real game fields a type the list missed.


func test_a_mission_brings_its_roster_and_every_group_of_its_script() -> void:
	var mission: MissionDef = load("res://data/missions/old_mill/mission.tres") as MissionDef
	var types: Array[StringName] = MissionLaunch.new(mission, 4, 1).unit_types()
	for entry: RosterEntry in mission.roster:
		assert_has(types, entry.type_id)
	for group: AiGroupSpec in mission.rules.groups:
		for unit_entry: AiUnitEntry in group.units:
			assert_has(types, unit_entry.type_id)
	assert_eq(types.size(), 10, "Old Mill can field every v1 type")


func test_riverside_brings_six_types() -> void:
	var mission: MissionDef = load("res://data/missions/riverside/mission.tres") as MissionDef
	assert_eq(Array(MissionLaunch.new(mission, 2, 1).unit_types()), [&"husk", &"longbow", &"reaver", &"ripper", &"sapper", &"shieldman"])


func test_the_deploy_adds_its_types() -> void:
	var launch: MissionLaunch = ViewFixtures.launch()
	launch.deploy.type_ids.append(&"warden")
	assert_has(launch.unit_types(), &"warden")


func test_a_skirmish_brings_both_armies() -> void:
	assert_eq(Array(MissionLaunch.for_skirmish(ViewFixtures.skirmish_setup()).unit_types()), [&"husk", &"shieldman"])


func test_a_launch_of_neither_brings_nothing() -> void:
	assert_eq(MissionLaunch.new().unit_types().size(), 0)


func test_the_list_is_sorted_with_no_repeats() -> void:
	var mission: MissionDef = load("res://data/missions/the_ford/mission.tres") as MissionDef
	var types: Array[StringName] = MissionLaunch.new(mission, 2, 1).unit_types()
	var sorted: Array[StringName] = types.duplicate()
	sorted.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	assert_eq(types, sorted)
	for type_id: StringName in types:
		assert_eq(types.count(type_id), 1, "%s once" % type_id)


func test_no_golden_replay_fields_a_type_its_launch_did_not_list() -> void:
	var units: UnitCatalog = load(App.CATALOG_PATH) as UnitCatalog
	var paths: PackedStringArray = ReplayVerifier.golden_paths()
	assert_gt(paths.size(), 0)
	for path: String in paths:
		var replay: Replay = ReplayStore.load_file(path)
		assert_not_null(replay, path)
		var launch: MissionLaunch = MissionLaunch.for_replay(replay)
		assert_not_null(launch, path)
		var listed: Array[StringName] = launch.unit_types()
		var player: ReplayPlayer = ReplayPlayer.new(replay, units)
		var seen: Dictionary[StringName, bool] = {}
		while not player.is_done():
			player.step()
			for unit: Unit in player.world.units:
				seen[unit.type.id] = true
		for type_id: StringName in seen:
			assert_has(listed, type_id, "%s fields %s" % [path.get_file(), type_id])
```

In `tests/view/test_unit_art_catalog.gd`:
- update the head comment: unit id to UnitArt path, and loading it loads no art;
- delete `test_find_and_put_replace_and_keep_order` and `test_invalid_art_is_left_out`;
- in the missing-catalog and not-a-catalog tests, `catalog.arts.size()` → `catalog.ids().size()`;
- in `test_the_committed_catalog_lists_the_shieldman_by_reference`, the body after the pending check becomes:

```gdscript
	var catalog: UnitArtCatalog = UnitArtCatalog.load_or_new()
	assert_eq(catalog.path_of(&"shieldman"), SHIELDMAN_PATH, "by its path, not the art itself")
	assert_eq(catalog.load_art(&"shieldman").resource_path, SHIELDMAN_PATH)
```

- in `test_every_v1_unit_has_valid_committed_art`, `catalog.arts.is_empty()` → `catalog.ids().is_empty()`, and `catalog.find(id)` → `catalog.load_art(id)`. Add:

```gdscript
const TEST_DIR: String = "user://test_unit_art_catalog"


func test_put_lists_a_path_per_unit_sorted() -> void:
	var catalog: UnitArtCatalog = UnitArtCatalog.new()
	catalog.put(&"shieldman", "res://a.tres")
	catalog.put(&"reaver", "res://b.tres")
	catalog.put(&"shieldman", "res://c.tres")
	assert_eq(Array(catalog.ids()), [&"reaver", &"shieldman"])
	assert_eq(catalog.path_of(&"shieldman"), "res://c.tres")
	assert_eq(catalog.paths.keys()[0], &"reaver", "sorted in the file too, so it diffs cleanly")
	assert_eq(catalog.path_of(&"husk"), "")
	assert_false(catalog.has(&"husk"))


func test_loading_the_catalog_loads_no_art() -> void:
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	var art_path: String = TEST_DIR + "/shieldman.tres"
	assert_eq(ResourceSaver.save(TestArt.art(&"shieldman"), art_path), OK)
	var catalog: UnitArtCatalog = UnitArtCatalog.new()
	catalog.put(&"shieldman", art_path)
	var catalog_path: String = TEST_DIR + "/catalog.tres"
	assert_eq(ResourceSaver.save(catalog, catalog_path), OK)
	var loaded: UnitArtCatalog = UnitArtCatalog.load_or_new(catalog_path)
	assert_true(loaded.has(&"shieldman"))
	assert_false(ResourceLoader.has_cached(art_path), "a path, not the art")
	assert_not_null(loaded.load_art(&"shieldman"))
	assert_null(loaded.load_art(&"husk"))
```

In `tests/view/test_unit_art_view.gd`, `_art_view` becomes:

```gdscript
# A UnitsView of world that draws art's type with it.
func _art_view(world: World, art: UnitArt, selection: UnitSelection, gibs: Gibs = null) -> UnitsView:
	var view: UnitsView = UnitsView.new()
	add_child_autofree(view)
	view.setup(world, selection, gibs, UnitArtSet.of([art]))
	return view
```

In `tests/view/test_unit_art_timing.gd`:
- `_have_art`: `_arts.arts.is_empty()` → `_arts.ids().is_empty()`;
- both `for art: UnitArt in _arts.arts:` → `for art: UnitArt in _all_art():`;
- add:

```gdscript
# Every unit's committed art, loaded.
func _all_art() -> Array[UnitArt]:
	var out: Array[UnitArt] = []
	for id: StringName in _arts.ids():
		var art: UnitArt = _arts.load_art(id)
		assert_not_null(art, "%s's art loads" % id)
		if art != null:
			out.append(art)
	return out
```

In `tests/view/test_main_view.gd`:
- In the three tests that call `MainView.load_art()` to decide which sprites should have art, use `var arts: UnitArtCatalog = UnitArtCatalog.load_or_new()` and `arts.has(id)` in place of `arts.find(id) != null`.
- Delete `test_load_art_gives_the_committed_shieldman_art`, `test_load_art_is_empty_without_a_catalog` and `test_load_art_leaves_out_art_that_fails_validation_and_keeps_the_rest`. `test_unit_art_set.gd` covers them.
- Add:

```gdscript
func test_a_campaign_game_loads_the_art_of_its_launch_and_no_more() -> void:
	if _skip_unless_art_is_built():
		return
	var main: MainView = _view()
	var catalog: UnitArtCatalog = UnitArtCatalog.load_or_new()
	var wanted: Array[StringName] = []
	for type_id: StringName in main.launch.unit_types():
		if catalog.has(type_id):
			wanted.append(type_id)
	var loaded: Array[StringName] = []
	for art: UnitArt in main.loaded_arts():
		loaded.append(art.unit_id)
	assert_eq(loaded, wanted)
	assert_lt(loaded.size(), catalog.ids().size(), "fewer than every type")


func test_the_sandbox_loads_every_type() -> void:
	if _skip_unless_art_is_built():
		return
	var main: MainView = _sandbox()
	assert_eq(main.loaded_arts().size(), UnitArtCatalog.load_or_new().ids().size())


func test_leaving_a_game_frees_its_unit_art() -> void:
	DirAccess.make_dir_recursive_absolute(ART_DIR)
	var art_path: String = ART_DIR + "/leaving_shieldman.tres"
	assert_eq(ResourceSaver.save(TestArt.art(&"shieldman"), art_path), OK)
	var catalog: UnitArtCatalog = UnitArtCatalog.new()
	catalog.put(&"shieldman", art_path)
	var catalog_path: String = ART_DIR + "/leaving_catalog.tres"
	assert_eq(ResourceSaver.save(catalog, catalog_path), OK)
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = ViewFixtures.launch()
	main.art_catalog_path = catalog_path
	add_child(main)
	_step(main)
	assert_true(ResourceLoader.has_cached(art_path), "the roster's Shieldman art is loaded")
	main.free()
	assert_false(ResourceLoader.has_cached(art_path), "and freed with the game")
```

- [ ] **Step 2: Run them; they fail**

Run: `make import && godot --headless --path . -s addons/gut/gut_cmdln.gd -gconfig= -gtest=res://tests/view/test_unit_art_set.gd -gexit`
Expected: FAIL, `UnitArtSet` not declared.

- [ ] **Step 3: Rewrite `view/units/unit_art_catalog.gd`**

```gdscript
class_name UnitArtCatalog
extends Resource
## Where each unit type's art is: its id to its data/art/<id>.tres, as
## data/art/catalog.tres, rewritten by scripts/art/build_unit_art.gd. It holds
## paths, not the art, so loading it loads no sheets: a game loads only the
## types it can show (UnitArtSet). A type missing here keeps its placeholder
## quad, so new units work before their art exists.

const DEFAULT_PATH: String = "res://data/art/catalog.tres"

@export var paths: Dictionary[StringName, String] = {}


func has(unit_id: StringName) -> bool:
	return paths.has(unit_id)


## The unit's art file, or "" when it has none.
func path_of(unit_id: StringName) -> String:
	return paths.get(unit_id, "")


## Every unit listed, sorted by id.
func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	out.assign(paths.keys())
	out.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return out


## Lists unit_id's art at path, replacing any. Kept sorted by id, so the file
## diffs cleanly.
func put(unit_id: StringName, path: String) -> void:
	paths[unit_id] = path
	var sorted: Dictionary[StringName, String] = {}
	for id: StringName in ids():
		sorted[id] = paths[id]
	paths = sorted


## The unit's art, loaded now, or null when it isn't listed or its file isn't
## a UnitArt. The caller validates it.
func load_art(unit_id: StringName) -> UnitArt:
	var path: String = path_of(unit_id)
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as UnitArt


## The catalog at path, or an empty one when there is none yet or the file
## isn't a catalog. Every unit is then drawn as a placeholder.
static func load_or_new(path: String = DEFAULT_PATH) -> UnitArtCatalog:
	if not ResourceLoader.exists(path):
		return UnitArtCatalog.new()
	var catalog: UnitArtCatalog = load(path) as UnitArtCatalog
	return catalog if catalog != null else UnitArtCatalog.new()
```

- [ ] **Step 4: Write `view/units/unit_art_set.gd`**

```gdscript
class_name UnitArtSet
extends RefCounted
## The unit art one game draws with (docs/specs/2026-10-15-art-a4-loading-design.md
## §5). MainView builds it from the types its launch can bring on
## (MissionLaunch.unit_types), which load and validate before the first frame,
## so a battle never stops to load. A type the list missed that the catalog
## has art for loads on its first sprite, with one warning: a hitch, never a
## missing body. Art that fails UnitArt.validate() is left out with a warning
## per reason, and its unit stays a placeholder. Each type is tried once. The
## MainView owns the set, so leaving a game frees its sheets.

## How long the first load took, in ms.
var load_ms: int = 0

var _catalog: UnitArtCatalog
var _arts: Dictionary[StringName, UnitArt] = {}
## Types tried that have no usable art.
var _none: Dictionary[StringName, bool] = {}


## The art of type_ids from catalog, loaded now.
static func for_types(type_ids: Array[StringName], catalog: UnitArtCatalog) -> UnitArtSet:
	var arts: UnitArtSet = UnitArtSet.new()
	arts._catalog = catalog
	var started_ms: int = Time.get_ticks_msec()
	for type_id: StringName in type_ids:
		arts._load(type_id)
	arts.load_ms = Time.get_ticks_msec() - started_ms
	return arts


## Art already in memory, with no catalog behind it: tests, and art built in
## code. Art that fails validation is left out, with a warning per reason.
static func of(arts: Array[UnitArt]) -> UnitArtSet:
	var out: UnitArtSet = UnitArtSet.new()
	for art: UnitArt in arts:
		out._keep(art.unit_id, art)
	return out


## The type's art, or null to draw it as a placeholder. A type not loaded yet
## that the catalog has art for loads now, with a warning.
func find(type_id: StringName) -> UnitArt:
	if _arts.has(type_id):
		return _arts[type_id]
	if _none.has(type_id) or _catalog == null or not _catalog.has(type_id):
		return null
	push_warning("UnitArtSet: %s's art loaded late, on its first sprite; MissionLaunch.unit_types() should list it" % type_id)
	return _load(type_id)


## The types whose art is loaded, sorted.
func loaded_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	out.assign(_arts.keys())
	out.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return out


## The loaded art, by type id.
func arts() -> Array[UnitArt]:
	var out: Array[UnitArt] = []
	for type_id: StringName in loaded_ids():
		out.append(_arts[type_id])
	return out


## GPU bytes of every loaded sheet (UnitArt.sheet_bytes).
func sheet_bytes() -> int:
	var total: int = 0
	for art: UnitArt in _arts.values():
		total += art.sheet_bytes()
	return total


func _load(type_id: StringName) -> UnitArt:
	if _arts.has(type_id):
		return _arts[type_id]
	if _none.has(type_id):
		return null
	var art: UnitArt = _catalog.load_art(type_id) if _catalog != null else null
	if art == null:
		if _catalog != null and _catalog.has(type_id):
			push_warning("UnitArtSet: unit art left out: %s: %s is not a UnitArt" % [type_id, _catalog.path_of(type_id)])
		_none[type_id] = true
		return null
	return _keep(type_id, art)


func _keep(type_id: StringName, art: UnitArt) -> UnitArt:
	var reasons: PackedStringArray = art.validate()
	if not reasons.is_empty():
		for reason: String in reasons:
			push_warning("UnitArtSet: unit art left out: %s" % reason)
		_none[type_id] = true
		return null
	_arts[type_id] = art
	return art
```

- [ ] **Step 5: `MissionLaunch.unit_types()`**

In `view/mission_launch.gd`, after `player_faction()`:

```gdscript
## Every unit type this launch can bring onto the field, sorted, each once.
## A mission: its roster, its deploy (the carryover) and every group its
## script can spawn, Old Mill's undrawn waves included. A skirmish: both
## armies. A replay is one of those once for_replay has resolved it.
## MainView loads unit art for these before the first frame; A2 can load
## voices by the same list.
func unit_types() -> Array[StringName]:
	var found: Dictionary[StringName, bool] = {}
	if skirmish != null:
		for army: Army in skirmish.armies:
			if army != null:
				for type_id: StringName in army.counts:
					found[type_id] = true
	if mission != null:
		for entry: RosterEntry in mission.roster:
			found[entry.type_id] = true
		if mission.rules != null:
			for group: AiGroupSpec in mission.rules.groups:
				for unit_entry: AiUnitEntry in group.units:
					found[unit_entry.type_id] = true
	if deploy != null:
		for type_id: StringName in deploy.type_ids:
			found[type_id] = true
	var out: Array[StringName] = []
	out.assign(found.keys())
	out.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return out
```

- [ ] **Step 6: UnitsView and MainView use the set**

In `view/units/units_view.gd`:
- `var _arts: UnitArtCatalog = UnitArtCatalog.new()` → `var _arts: UnitArtSet = UnitArtSet.new()`.
- `setup(..., arts: UnitArtCatalog = null)` → `arts: UnitArtSet = null`.
- In the class doc, "(setup's UnitArtCatalog)" → "(setup's UnitArtSet, loaded for the launch's types)".
- `loaded_arts()` becomes `return _arts.arts()`.

In `view/main.gd`:
- After `art_load_ms`:

```gdscript
## Where the unit art catalog is read from. Tests point it at their own.
var art_catalog_path: String = UnitArtCatalog.DEFAULT_PATH
```

- Replace the Task 1 block in `_ready` with:

```gdscript
	var art_catalog: UnitArtCatalog = UnitArtCatalog.load_or_new(art_catalog_path)
	# Only what this game can bring on (MissionLaunch.unit_types). The sandbox
	# and the demos have no launch, and load every type.
	var art_types: Array[StringName] = launch.unit_types() if launch != null else art_catalog.ids()
	var arts: UnitArtSet = UnitArtSet.for_types(art_types, art_catalog)
	art_load_ms = arts.load_ms
	print("unit art: %d types, %.1f MB of sheets, loaded in %d ms" % [arts.loaded_ids().size(), arts.sheet_bytes() / 1e6, arts.load_ms])
	_units_view.setup(world, _selection.selection, _gibs, arts)
```

- Delete `static func load_art` and its doc comment.
- In the class doc, "(load_art)" → "(only the types its launch can bring on; see UnitArtSet)".

In `scripts/art/build_unit_art.gd`, `catalog.put(saved)` becomes `catalog.put(saved.unit_id, out)`. Update the comment above it: the catalog holds the art's path, so the saved file must load back as a UnitArt.

- [ ] **Step 7: Regenerate the catalog**

Run `rm data/art/catalog.tres`, then `make import`. The old file's `arts` property no longer exists, so it must not be loaded. Then, for each of the ten units:

`godot --headless --path . -s scripts/art/build_unit_art.gd -- <unit>`

Expected: `data/art/catalog.tres` holds `paths = Dictionary[StringName, String]({&"blightbag": "res://data/art/blightbag.tres", …})`, ten entries in id order. Run `git diff --stat data/art`: only `catalog.tres` changed, and every `data/art/<unit>.tres` is byte-identical.

- [ ] **Step 8: Run all tests; they pass**

Run `make import`, the whole suite and `make check-sim`. Expected: PASS. The golden guard plays all four goldens and takes the longest, about a minute.

If a test fails on the late-load warning, check where it comes from:
- a test's own art: give that test's view its type through `UnitArtSet.of`;
- a real launch: `unit_types()` missed a spawn source. Fix `unit_types()`, never the guard.

- [ ] **Step 9: Commit**

```bash
git add view/units view/mission_launch.gd view/main.gd scripts/art/build_unit_art.gd data/art/catalog.tres tests
git commit -m "Load only the unit art a game's launch can bring on" -m "The catalog now holds paths, so loading it loads no sheets. MissionLaunch.unit_types() lists a mission's roster, deploy and script groups, or a skirmish's armies, and MainView loads that art before the first frame: Riverside loads 6 types, not 10. A type the list missed loads on its first sprite with one warning. A test plays every golden replay to show none does.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Out-of-step walk and idle

**Files:**
- Modify: `view/units/unit_animator.gd`, `view/units/unit_sprite.gd`
- Test: `tests/view/test_unit_animator.gd`, `tests/view/test_unit_art_view.gd`

**Interfaces:**
- Produces: `const UnitAnimator.LOOP_PHASE_STEP: float`, `static UnitAnimator.loop_start_frame(unit_id: int, count: int) -> int`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/view/test_unit_animator.gd`:

```gdscript
func test_a_loop_starts_on_the_units_own_frame() -> void:
	for id: int in 200:
		var frame: int = UnitAnimator.loop_start_frame(id, 12)
		assert_between(frame, 0, 11)
		assert_eq(UnitAnimator.loop_start_frame(id, 12), frame, "the same every time, so a replay matches")
	assert_eq(UnitAnimator.loop_start_frame(5, 1), 0, "a one-frame loop has one frame")
	assert_eq(UnitAnimator.loop_start_frame(5, 0), 0)


func test_neighbours_in_a_side_start_a_quarter_cycle_apart() -> void:
	for id: int in Army.MAX_UNITS - 1:
		var a: float = fposmod(id * UnitAnimator.LOOP_PHASE_STEP, 1.0)
		var b: float = fposmod((id + 1) * UnitAnimator.LOOP_PHASE_STEP, 1.0)
		var apart: float = absf(a - b)
		assert_gte(minf(apart, 1.0 - apart), 0.25, "ids %d and %d" % [id, id + 1])
```

Append to `tests/view/test_unit_art_view.gd`:

```gdscript
# TestArt with a 12-frame idle, so two idles can be out of step.
func _looping_art() -> UnitArt:
	return TestArt.art(&"shieldman", {
		"idle": [12, 12, true, -1], "walk": [12, 12, true, -1],
		"attack": [6, 12, false, 3], "die": [4, 12, false, -1],
	})


func test_units_that_set_off_together_walk_out_of_step() -> void:
	var second: Unit = _world.spawn_unit(_catalog.index_of(&"shieldman"), LIGHT, 32 * M, 30 * M, 0, 1)
	_view.after_step()
	for unit: Unit in [_shieldman, second]:
		unit.transition_to(Unit.State.MOVING)
		unit.x += 100
	_view.after_step()
	_view._process(0.0)
	var first_frame: int = _art_body(_sprite(_shieldman)).frame
	var second_frame: int = _art_body(_sprite(second)).frame
	assert_eq(first_frame, UnitAnimator.loop_start_frame(_shieldman.id, 12))
	assert_eq(second_frame, UnitAnimator.loop_start_frame(second.id, 12))
	assert_ne(first_frame, second_frame, "two ids, two steps")


func test_units_that_stand_together_idle_out_of_step() -> void:
	var world: World = World.new(1, TestTerrains.flat(60, 60), _catalog)
	var a: Unit = world.spawn_unit(_catalog.index_of(&"shieldman"), LIGHT, 30 * M, 30 * M, 0, 1)
	var b: Unit = world.spawn_unit(_catalog.index_of(&"shieldman"), LIGHT, 32 * M, 30 * M, 0, 1)
	var view: UnitsView = _art_view(world, _looping_art(), UnitSelection.new())
	view.after_step()
	view._process(0.0)
	assert_eq(_art_body(_sprite_in(view, a)).animation, &"idle_4")
	assert_ne(_art_body(_sprite_in(view, a)).frame, _art_body(_sprite_in(view, b)).frame)


func test_a_strike_that_ends_in_a_walk_resumes_on_the_units_own_frame() -> void:
	_shieldman.windup_left = 8
	_view.after_step()
	_shieldman.windup_left = 0
	_shieldman.transition_to(Unit.State.MOVING)
	# Long enough for TestArt's 6-frame swing at 12 fps (15 ticks) to play out.
	for _tick: int in 40:
		_shieldman.x += 100
		_view.after_step()
	_view._process(0.0)
	assert_eq(_sprite(_shieldman).shown_animation(), &"walk_4")
	assert_eq(_art_body(_sprite(_shieldman)).frame, UnitAnimator.loop_start_frame(_shieldman.id, 12))
```

- [ ] **Step 2: Run them; they fail**

Run the two files with `-gtest=`. Expected: FAIL. `loop_start_frame` isn't declared, and the frames are both 0.

- [ ] **Step 3: Implement**

In `view/units/unit_animator.gd`, after `ACT_ANIMS`:

```gdscript
## The golden ratio's fractional part. Consecutive unit ids start a loop this
## far apart in its cycle, at least 0.38 of it, so units ordered together don't
## step in unison (docs/specs/2026-10-15-art-a4-loading-design.md §13).
const LOOP_PHASE_STEP: float = 0.6180339887
```

After `mark_dead()`:

```gdscript
## The frame a unit starts a looping animation of `count` frames on: its own,
## from its id alone, so the same game and its replay show the same frames.
static func loop_start_frame(unit_id: int, count: int) -> int:
	if count <= 0:
		return 0
	return clampi(floori(fposmod(unit_id * LOOP_PHASE_STEP, 1.0) * count), 0, count - 1)
```

In `view/units/unit_sprite.gd` `_show()`, after the `elif same_motion:` branch:

```gdscript
	elif _art.frames.get_animation_loop(wanted):
		# A new loop starts on the unit's own frame, so a group that sets off,
		# stops or spawns together doesn't move in unison.
		_art_body.set_frame_and_progress(UnitAnimator.loop_start_frame(unit_id, _art.frames.get_frame_count(wanted)), 0.0)
```

Update the doc above `_show`: "…a change of animation starts it from the top" → "…a new strike or death starts from its top, and a new loop (idle, walk) on the unit's own frame (UnitAnimator.loop_start_frame)".

- [ ] **Step 4: Run them, then the suite**

Run the two files, then the whole suite. Expected: PASS.

An older test that expected a new loop at frame 0 now fails. Update its expectation to `UnitAnimator.loop_start_frame(<unit>.id, <count>)`, and say so in the commit body. Never change the new behavior to fit the old test.

- [ ] **Step 5: Commit**

```bash
git add view/units/unit_animator.gd view/units/unit_sprite.gd tests/view
git commit -m "Start each unit's walk and idle on its own frame" -m "A group order started every walk on frame 0 on the same tick, so a formation stepped in unison, and units that spawned together idled in unison. Each unit now starts a loop at a frame from its id, a golden-ratio step: neighbors start at least 0.38 of a cycle apart, and replays still match. Tim asked for this during A4's spec review; a 1 s delay would have slid units with their legs still.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Measure after, check by eye, document, review

**Files:**
- Modify: `docs/plans/2026-10-15-art-a4-measurements.md`, `docs/architecture.md`, `docs/specs/2026-10-01-art-audio-design.md`, `docs/specs/2026-10-15-art-a4-loading-design.md`, `CLAUDE.md`

- [ ] **Step 1: The budget, after**

Run the Task 1 Steps 12–13 measurements again. Add each line under `## After` in the measurements file.

Expected on Web:
- `tab=` about 600, PASS;
- `art=` about 188;
- `pck=` about 195.

If Web says FAIL or UNKNOWN in Chrome, stop. Report the line to Tim, with what the numbers point at.

Run `make verify-replays`. Expected: every golden `OK`, with the same final hashes as `docs/architecture.md`'s determinism table. A4 changes no sim code.

- [ ] **Step 2: Other browsers and Windows**

1. Run `ls /Applications | grep -i -E "^(safari|firefox)"`.
2. For each one installed:
   - with the server on 8064, run `open -a "<App>" "http://127.0.0.1:8064/?budget=1"`;
   - wait about 3 minutes, then run `screencapture -x <scratchpad>/a4/<app>.png`;
   - read the on-screen line from the image;
   - record it, s3tc included. UNKNOWN is expected on Safari: it has neither memory API.
3. Run `make export-windows`. Then run the Task 2 Step 3 grep on `build/windows/Ashenmarch.exe`, where the pck is embedded. Expected: `s3tc` only.

- [ ] **Step 3: Riverside, after, for Tim's eye**

Run: `CAPTURE=<scratchpad>/a4/capture-after MISSIONS=riverside make capture`

Put each before/after pair side by side with a small `Image` script, or just name the two folders. List the four pairs for Tim in the final report.

The frames can't match pixel for pixel: they're timed by wall-clock, and §13 starts loops on other frames. The pixel-level proof is Task 4's probe and Task 5's byte check.

- [ ] **Step 4: Docs**

In `docs/architecture.md`, "Unit art (tracks A1 and A3)":
- Rename it "Unit art (tracks A1, A3 and A4)", and add the A4 spec and this plan to its first line.
- **Pipeline:**
  - the renderer's output is grids in `art-src/units/<id>/sheets/`;
  - a new bullet for the pack step: `UnitArtPacker` regions and padding, with the 8 px, 4 px and 4096 px figures;
  - lossless, deterministic, the symlink guard;
  - `make art-build` = pack, import, build;
  - `make art-probe`.
- **In game:**
  - replace the `MainView.load_art` sentence with `MissionLaunch.unit_types()` → `UnitArtSet`: preload, late load with one warning, release with the MainView;
  - add the loop phase (§13).
- **A new "Web budget" subsection:**
  - the budget (1,000 MB tab, worst case);
  - `?budget=1` and `make budget`/`budget-app`;
  - a before/after table from the measurements file;
  - the browsers' s3tc results;
  - ETC2 off.
- **"Not yet":** delete the "Texture memory" bullet. Add:
  - a desktop browser without S3TC would fail the budget (RGBA8, 4×);
  - half resolution stays available as a lever (67 MB);
  - Safari reports UNKNOWN.

In `docs/specs/2026-10-01-art-audio-design.md`:
- the status line adds "A4 implemented (2026-10-…)";
- the §9 "Unit sheet texture memory" row's mitigation becomes "Done in A4: see `2026-10-15-art-a4-loading-design.md`".

In `docs/specs/2026-10-15-art-a4-loading-design.md`, the status line becomes "Approved by Tim on 2026-10-15; implemented by `docs/plans/2026-10-15-art-a4-loading.md`."

In `CLAUDE.md`'s folder layout, the `art-src/` line becomes: `art-src/        # art recipes, Meshy models, render grids and review sheets (LFS; Godot skips it)`.

- [ ] **Step 5: Review**

Run the superpowers:requesting-code-review skill on the branch against `main`. Then send the `security-reviewer` agent:
- `UnitArtPacker.planted_links` and `pack_unit_art.gd`'s writes (public repo, planted links);
- `BudgetRun`'s URL parsing and `JavaScriptBridge.eval` calls, which should only ever evaluate the constant strings and a `JSON.stringify`'d line.

Fix what they confirm, rerun the suite, and commit the fixes.

- [ ] **Step 6: Commit the docs, and hand over the PR**

```bash
git add docs CLAUDE.md
git commit -m "Document A4: packed sheets, per-roster loading, the Web budget" -m "<the before and after tab memory, from the measurements file>

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

Write the PR body to `<scratchpad>/a4/pr-a4.md`:
- what changed;
- the before/after table;
- LFS growth;
- the probe summary;
- what's next: A2, then the dwarf's sim size, then world textures. Tim decides where they go.

End it with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

Give Tim these two commands to run:

```
! git push -u origin feature/PHASE-A4-art-loading
! gh pr create --base main --head feature/PHASE-A4-art-loading --title "Art track A4: unit art per roster, packed sheets, Web budget" --body-file <scratchpad>/a4/pr-a4.md
```

Update the auto-memory `art-track-state.md`: A4's PR is open, and what comes next.
