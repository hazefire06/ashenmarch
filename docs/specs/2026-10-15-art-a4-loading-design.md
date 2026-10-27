# Art track A4: unit art per roster, and a Web texture budget

Status: approved by Tim on 2026-10-15 and implemented by `docs/plans/2026-10-15-art-a4-loading.md`; the plan's ledger rulings and §7 below record where implementation changed it. Brainstormed with Tim on 2026-10-15, section by section. Branch `feature/PHASE-A4-art-loading`, worktree `~/Projects/ashenmarch-a4`, from `main` at 46ab149.

## 1. Goal

Load only the unit art a game can show, and make the Web build fit a memory budget agreed with Tim and measured in a real build.

Success looks like this:

- **Budget.** The worst-case launch (§6) uses at most 1,000 MB of browser tab memory in the Web export, measured by the budget check (§6), and passes in Chrome on this Mac.
- **No visual loss.** Desktop looks no worse than today: trimming is lossless, and nothing changes resolution, frame rate or directions.
- **Per roster.** A campaign mission or skirmish loads the art of the types it can bring on, and no other.
- **Out of step.** Units that start walking or idling on the same tick no longer move their legs in unison (§13, added by Tim during spec review).
- **Nothing else moves.** Every unit still has its art, placeholders still work, and F12 still switches. `sim/` is untouched, so the golden replays and `make verify-replays` stay identical.

### What comes after A4

Tim added two items on 2026-10-15, to follow once A4 is complete. Each is its own sub-project, with its own spec or plan, branch and PR:

1. **A2 audio** (`feature/PHASE-A2-audio`). Its design is §8 of `2026-10-01-art-audio-design.md`, already approved, so it needs a plan. Tim runs the paid ElevenLabs and Suno steps. A2 measures its memory against the same 1,000 MB budget, using the budget check from §6.
2. **The dwarf's sim size**, on a branch of its own. `data/units/sapper.tres` (`body_height` 1750, `ranged_launch_height` 1700) is still human-sized, while the drawn dwarf is 0.99 m. Changing it is a sim data change: it re-records the goldens and needs a balance playtest, so it is kept off art branches.

### Non-goals

| Item | Why |
|---|---|
| A2, the dwarf's sim size | After A4, as above |
| The late herb-plant strikes (`architecture.md`, Unit art, Not yet) | Out of scope unless Tim adds it |
| Half resolution, fewer frames, mirrored directions | The budget is met without a visual trade (§3) |
| Merging identical frames, or one atlas per unit | Not needed for the budget |
| Precompressing the pck for a host | The budget is memory, which compression doesn't change; the download size is reported, not budgeted |
| Mobile Web | No touch input, and the Web preset ships no ETC2 |
| Running the Windows export | Needs Tim's Parallels VM; A4 only checks the Windows pck's formats |

## 2. What was measured (2026-10-15, `main` at 46ab149)

The Web and macOS exports were built in the worktree. Engine behavior was checked against the Godot 4.7-stable source by a research pass; anything it could not confirm is marked.

| Item | Finding |
|---|---|
| Web pck | 557.6 MB, S3TC only (`index.pck`) |
| macOS pck (universal) | 557.6 MB, S3TC only. A universal export declares `s3tc` and `bptc`, never `etc2` (`platform/macos/export/export_plugin.cpp`, `get_preset_features`) |
| ETC2 | `import_etc2_astc=true` since the Phase 0 scaffold, but no export carries it. It doubles the import cache (528 MiB per format) |
| Everything but unit art | Under 4 MB of the pck |
| In the browser | The whole pck is downloaded and copied into Emscripten's in-memory filesystem, a JS-heap buffer, for the session (`platform/web/js/engine/preloader.js`, `library_godot_os.js` `copy_to_fs`). Chrome's JS heap was 568 MB, and `measureUserAgentSpecificMemory` reported 740 MB |
| GPU | The page uploaded 553.9 MB of DXT5 (`COMPRESSED_RGBA_S3TC_DXT5`), counted by hooking WebGL's `compressedTexImage2D`: all 45 sheets with their mipmaps |
| On the wire | 42 MB gzipped, 37 MB with brotli. Godot's Web export doesn't precompress, so the host must |
| Browser support | Chrome on this M4 Max (ANGLE on Metal) exposes `WEBGL_compressed_texture_s3tc`. Without it, Godot decompresses S3TC to RGBA8 at load, which is 4x the memory (`texture_storage.cpp`, `_get_gl_image_and_format`) |
| Rosters | Riverside has 6 art types, The Ford 8 (plus the villager, a placeholder), Old Mill all 10. A skirmish can field all 10 |
| Cells | On average a figure's alpha box fills 26% of its cell (160–216 px) |
| Camera | Missions start at 75 m with a 75° FOV, so a unit is drawn at about 9 px/m at 1080p and 19 at 4K, against 52 px/m in the sheet |

The browser run was not clean. The tab had reached the Campaign menu and loaded a mission's terrain without any input from this session, then vanished: another session may share that browser. The numbers fit the export and the source, but the before measurement is taken again with the budget check (§8, step 1).

**What follows from it.** Per-roster loading doesn't lower the worst case, because Old Mill and a skirmish field every type. The sheets' size sets the budget. The browser holds the pck and the GPU textures both, so tab memory is roughly twice the unit art plus the engine.

## 3. Decisions

| Decision | Why |
|---|---|
| **The Web target is an ordinary 8 GB laptop** with integrated graphics, in any current desktop browser (Tim) | Sets the budget: at most 1,000 MB of tab memory |
| **Trim and pack at build time, from the committed renders** (Tim, approach 1 of 3) | Lossless; needs neither Blender nor Meshy; testable with GUT. Packing inside the Blender renderer would need a re-render of all ten units and Blender-only tests |
| **Preload the launch's types; load a stray type on its first sprite** (Tim) | First-sprite loading alone would load about 20 MB mid-battle when a wave brings a new type (Old Mill's Blightbags, The Ford's late Rippers): a hitch, worst on Web |
| **8 px of padding per frame, rects on 4 px** | Mipmaps through level 2 never mix two frames. A 4x4 DXT block never holds two frames. Alpha-cut discards the faint bleed beyond that |
| **ETC2 import off** | No export uses it |
| **No resolution, frame-rate or direction change** | The 1,000 MB budget is met losslessly, with about 400 MB to spare for A2 and map art. Half resolution stays available as a later lever (67 MB for all ten): softer only when zoomed closer than about 27 m at 1080p or 54 m at 4K |

Simulated GPU memory for all ten units (DXT5 with mipmaps, shelf-packed, rects rounded to 4 px):

| Option | All ten | Of today |
|---|---|---|
| Today's grids | 554 MB | 100% |
| Trim and pack, 4 px padding | 162 MB | 29% |
| **Trim and pack, 8 px padding (chosen)** | **188 MB** | **34%** |
| Trim and pack, 5 directions rendered and 3 mirrored | 112 MB | 20% |
| Trim and pack at half resolution | 67 MB | 12% |

## 4. The pipeline: render, pack, import, build

```
art-src/units/<id>/sheets/   the renderer's grid sheets and grid sidecar (LFS; Godot skips art-src)
  <anim>.png, <id>.json
assets/units/<id>/           game-ready, written by the packer (LFS)
  <anim>.png, <anim>.png.import, <id>.json (the packed sidecar)
data/art/<id>.tres           the UnitArt, written by the builder
data/art/catalog.tres        unit id -> UnitArt path, written by the builder
```

**Render** (`make art-render UNIT=<id>`). Unchanged, except that the grid sheets and the grid sidecar are written to `art-src/units/<id>/sheets/`. Grid sheets get no `.import` there, since Godot never sees that folder. The 45 committed grids move there with `git mv`, which adds no LFS objects.

**Pack** (`scripts/art/pack_unit_art.gd`, headless Godot; the logic lives in a static `UnitArtPacker` that works on `Image`s and needs no scene tree). For each animation the game plays:

1. Cut each cell from the grid, using the sidecar's `columns`, `rows_per_direction`, `cell` and `gutter`.
2. Trim it to its used alpha box (`Image.get_used_rect`). An empty cell keeps a 1x1 box.
3. Pad the box with 8 px of transparency on every side, then round its width and height up to a multiple of 4.
4. Shelf-pack the boxes, tallest first with a stable tie-break, into a sheet at most 4096 px wide. Every size is a multiple of 4 and packing starts at 0, so every rect's position is a multiple of 4 too. A sheet taller than 4096 px is an error that names the animation.
5. Write `assets/units/<id>/<anim>.png` and its `.png.import` (VRAM compressed, mipmaps, S3TC only). Write the packed sidecar `assets/units/<id>/<id>.json`: every field of the grid sidecar, plus for each animation, direction and frame the frame's rect in the sheet and the trimmed box's offset in the cell.

Packing is deterministic: the same render packs to the same bytes, so a rerun doesn't churn LFS.

**Import, then build.** `build_unit_art.gd` reads the packed sidecar and the imported sheets. Each frame becomes an `AtlasTexture`:
- `region` is the frame's rect in the packed sheet;
- `margin` puts back what the trim and padding removed, so `get_width()` and `get_height()` return `cell_px` again.

`AtlasTexture.get_rect_region()` applies the margin, and `SpriteBase3D.draw_texture_rect` calls it (`scene/3d/sprite_3d.cpp`). `UnitArt`, `UnitSprite`, the feet offset, picking and the overlays are therefore unchanged. `filter_clip` isn't used by 3D sprites, which is why the padding is in the sheet.

**Make.** `make art-build UNIT=<id>` runs pack, `--import`, then build. `make art-render` is unchanged in use.

## 5. Loading at runtime

**Catalog.** `UnitArtCatalog` holds `paths: Dictionary[StringName, String]` (unit id to `data/art/<id>.tres`) instead of `UnitArt` resources, so loading `catalog.tres` loads no art. The builder lists each unit it builds, as now.

**The types a launch can bring on: `MissionLaunch.unit_types() -> Array[StringName]`.**
- **A mission:** the roster's types, the deploy's types (carryover) and every unit entry of every group in `rules.groups`. That includes Old Mill's undrawn waves, at the cost of at most one extra type.
- **A skirmish:** both armies' types.
- **A replay:** `MissionLaunch.for_replay` already resolves it to one of the two above.
- **No launch** (the sandbox and the demos): every type in the catalog.

Nothing in it is art-specific; A2 can use the same list to load voice banks per roster.

**`UnitArtSet`** (new, `view/units/unit_art_set.gd`) replaces the catalog inside `UnitsView`:
- `MainView` builds it from the launch's types where `load_art()` runs today, so they load and validate before the first frame. It logs one line: the types, the MB of sheets, the ms taken.
- `find(type_id)` returns loaded art. A type outside the list that the catalog has is loaded there, on its first sprite, with a `push_warning` naming it. This covers a debug-key spawn in a development launch; it costs a hitch, never a missing sprite.
- Art that fails `UnitArt.validate()` is left out with a warning, and its unit stays a placeholder, as now.
- `MainView.load_art` becomes `load_art(type_ids)`. Its callers and tests move with it.

**Release.** The set is owned by the `MainView`, so leaving a game frees its sheets. Restart builds the new `MainView` before the old one is freed: a type both use comes from Godot's resource cache and is not loaded twice. Between missions, the results and briefing screens come between, so the two sets never overlap.

**Unchanged:** F12 (`UnitsView.set_art_enabled`), `UnitSprite`, `UnitAnimator`, and `test_unit_art_timing.gd`, which loads every unit, as tests may.

## 6. The Web budget and the budget check

**The budget.** At most **1,000 MB of tab memory**, in the Web export, for the worst-case launch after 60 s of play. Tab memory is the sum of:
- `performance.measureUserAgentSpecificMemory().bytes`: JS and wasm, which includes the resident pck;
- Godot's `Performance.RENDER_VIDEO_MEM_USED`: textures, render buffers and mesh buffers as the GLES3 driver counts them. It counts a texture at its source format's size, so it would under-report a texture decompressed for want of S3TC.

The expected result is about 600 MB: a pck of about 190 MB held twice (in the JS heap, and on the GPU once uploaded), plus the engine. That leaves about 400 MB for A2 and later map art. A2 measures against the same 1,000 MB.

**The worst-case launch.** An AI-against-AI skirmish on Old Mill (`player_is_ai`) with every v1 type on the field, 2 of each per side, its budget set to the armies' cost. The number of types sets texture memory; the number of units doesn't.

**The budget check** (`view/budget/budget_run.gd`, wired into `App._ready` the way `ReplayVerifier` is):
- Started by `?budget=1` on Web and `-- --budget` on desktop. It skips the menus, plays the worst-case launch rendered for 60 s at 1x, then prints one `budget:` line and shows it on screen:
  - tab memory against 1,000 MB, with PASS or FAIL (Web only);
  - unit art: the bytes of the sheets the `UnitArtSet` loaded, from `RenderingServer.texture_debug_usage()`. If release templates don't provide it, the bytes come from the sheets' sizes at DXT5 with mipmaps, labeled as computed;
  - the art load time;
  - the pck's decoded and transferred size (Web, from the page's resource timing);
  - `RENDER_TEXTURE_MEM_USED` and `OS.get_static_memory_usage()`.
- `measureUserAgentSpecificMemory` needs cross-origin isolation, which `serve_web.py` provides. On a host without it, the check shows Chrome's `performance.memory` JS heap, labeled as a fallback, and says UNKNOWN. (Changed in review: the wasm memory's size isn't reachable from the page, and the JS heap alone leaves out the wasm memory and the resident pck, so a fallback verdict could pass a tab over the limit.)
- Desktop prints the same line and exits 0. Desktop has no budget, but the numbers go into the docs.
- Make targets: `make budget` (the editor, windowed) and `make budget-app` (the exported macOS app). On Web: `make export-web serve-web`, then `http://127.0.0.1:8060/?budget=1`.

**Before and after.** The check is built first (§8, step 1) and run on today's build, so `architecture.md` records a measured before (expected about 1.3 GB) and after, rather than the estimates above.

**Browsers.** Chrome on this Mac is the pass/fail run. Safari and Firefox are run by hand if installed, and their `s3tc` support recorded. A desktop browser without S3TC would get RGBA8, about 750 MB for all ten units, and fail the budget. That is a documented risk; A4 doesn't handle it.

## 7. Formats and exports

- ~~`rendering/textures/vram_compression/import_etc2_astc=false`.~~ Withdrawn in implementation: Godot 4.7 refuses a universal or arm64 macOS export without the ETC2/ASTC import, although the pck carries S3TC only. The setting stays on, pinned by a test, and the import cache keeps both formats.
- `make run` and the exported macOS app must still draw every texture.
- The Web preset stays as it is: S3TC for desktop, nothing for mobile.
- The pcks' file lists are checked: no `art-src` grid, no sidecar JSON, no `etc2` file. The Windows export is built to confirm S3TC only, but not run.

## 8. Order of work (for the plan)

1. **The budget check, measured on today's build.** Desktop and Web, giving the before numbers.
2. **Prove margins in 3D.** One committed unit, packed and built by hand, shown in-engine next to its grid version: a screenshot at the closest and the farthest camera distance. This is done before anything else depends on it.
3. The packer, with its tests. Move the grids to `art-src`, and change the renderer's output path.
4. The builder reads the packed sidecar. Repack and rebuild all ten units.
5. Catalog paths, `MissionLaunch.unit_types()`, `UnitArtSet`, and the MainView and UnitsView changes.
6. ETC2 import off.
7. Out-of-step loops (§13), in a commit of their own.
8. The budget check again on Web and desktop, then the visual check, then the docs.

## 9. Tests (GUT, run without `-d`)

**Packer** (synthetic `Image`s and the committed renders):
- trim, padding and 4 px rounding math, including an empty cell;
- no two rects overlap, every rect lies inside its sheet, and no sheet is over 4096 px;
- packing twice gives identical bytes;
- **losslessness:** for every committed frame, the cell rebuilt from the packed sheet (region plus margin) equals the grid cell, byte for byte.

**Built art.** Every frame of every committed unit reports a `cell_px` square, and its region lies inside its atlas.

**Catalog and set:**
- loading `catalog.tres` caches no sheet (`ResourceLoader.has_cached`);
- a set built for some types loads those and no others;
- a type outside the list loads late with a warning;
- broken art stays a placeholder;
- freeing a `MainView` releases its art.

**`MissionLaunch.unit_types()`:**
- each mission at each tier, a skirmish, a replay of each kind, and no launch;
- **the golden guard:** playing each golden replay, every type that appears on the field is in that launch's `unit_types()`. A future mission that spawns a type some other way fails this test instead of hitching in game.

**Budget check.** The scenario builds a valid all-types skirmish, and the PASS/FAIL arithmetic and the line's fields are right. The numbers themselves come from the real runs.

**Out-of-step loops** (§13):
- `UnitAnimator.loop_start_frame` is always in `0..count-1`, and is the same every time for the same id;
- for ids 0 to 59 (a full side), consecutive ids are at least a quarter of a cycle apart;
- two art sprites with different ids, told to walk on the same tick, show different frames, and so do two that idle;
- a strike that ends in a walk resumes the walk on the unit's own frame;
- a turn mid-walk still keeps the frame (the existing test), and strikes and deaths still start on the frame the animator gives.

**Existing checks:**
- the whole suite and the sim purity check;
- `make test-art`, since the renderer's output path changes;
- `make verify-replays`, which must stay identical.

**Visual.** `make capture` of Riverside before and after, at the opening view and zoomed to the closest distance. Trimming is lossless, so the frames should match. Any difference is shown to Tim.

## 10. Docs

- This spec, and the A4 plan in `docs/plans/`.
- `architecture.md`, "Unit art": the pack step and the grids in `art-src`; `UnitArtSet` and `unit_types()`; the budget check; the measured before and after; each unit's own loop phase under "In game"; a rewritten "Not yet" (the Texture memory item replaced by its result).
- `2026-10-01-art-audio-design.md`: its status line, and the texture-memory row of §9 pointing here.
- CLAUDE.md, folder layout: `art-src/` now holds the render grids too.

## 11. Risks and unverified items

| Item | Mitigation |
|---|---|
| `AtlasTexture.margin` in `AnimatedSprite3D` (confirmed in source, not yet in game) | §8 step 2 proves it in game first |
| Mipmap bleeding between packed frames at far zoom | 8 px padding and alpha-cut; checked at the maximum camera distance |
| A desktop browser without `WEBGL_compressed_texture_s3tc` | RGBA8 at 4x would fail the budget. Recorded, not handled |
| `RenderingServer.texture_debug_usage()` in release templates (unverified) | Fall back to computed sheet sizes, labeled |
| LFS growth: the packed sheets are new objects, estimated at about 100 MB (433 MB today). Tim's GitHub LFS quota was not checked | Reported in the PR |
| The web budget check's 60 s run in a browser tab that loses focus | Run it in a foreground tab; the line records the ticks played |

## 12. Done criteria

- Tim's CLAUDE.md definition of done: plan approved before code, GUT tests pass, runs on the macOS export, docs updated, PR opened against `main`.
- The budget check reports **PASS** in the Web export in Chrome on this Mac, and its before and after are recorded in `architecture.md`.
- The budget check runs in the exported macOS app.
- `make verify-replays` is identical to `main`.
- The Riverside captures before and after match, or Tim has seen and accepted every difference. The out-of-step loops are expected to change the frames shown, so the lossless comparison is taken before §13 lands; after it, Tim watches a formation move in game.

## 13. Out-of-step loops (added by Tim, 2026-10-15)

**The problem.** A group order starts every unit walking on the same tick. `UnitSprite._show` starts a new motion's animation at frame 0, and units in formation move at the same speed, so the whole group steps in unison. Units that spawn or stop together idle in unison too.

**Not a delay.** Tim first asked for a 1 s delay between neighbors. That was dropped for two reasons:
- A unit moves the tick the sim moves it, so a delayed walk would slide with its legs still.
- Most walk cycles are exactly 1 s (12 frames at 12 fps for the Shieldman, Longbow, Sapper, Warden and Stormcaller), so a 1 s delay starts them back in step.

**The design.** Each unit starts a looping animation at its own frame:
- `UnitAnimator.loop_start_frame(unit_id, count) -> int` returns `floor(frac(unit_id × 0.6180339887) × count)`, a pure static. It's a golden-ratio step: ids next to each other (a formation's units are numbered together) land at least 0.38 of a cycle apart, so no neighbor search is needed. Ids a Fibonacci number apart come closer (5 apart: 0.09 of a cycle; 8 apart: 0.06), so in a box five or eight wide the unit directly behind may step nearly with the one in front. A whole rank never steps together. If that shows in game, the fallback is a hashed phase per id.
- `UnitSprite._show` uses it when it switches into a looping animation (`SpriteFrames.get_animation_loop`; today idle and walk) from a different motion. That covers idle to walk, walk to idle, a strike ending in either, and a unit's first idle.
- **Unchanged:**
  - a turn mid-motion keeps the frame and progress, as now;
  - a restart (a strike, a death) starts on the frame the animator gives;
  - walk speed still follows the ground speed;
  - placeholders have no animation and are untouched.
- The phase comes from the unit's id, so the same game, and its replay, shows the same frames. It's view-only, adds no frames, and doesn't affect the budget.
