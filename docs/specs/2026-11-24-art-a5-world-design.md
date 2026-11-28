# Art track A5: the world, design

Status: draft, 2026-11-24. Brainstormed with Tim on 2026-11-24. Branch `feature/PHASE-A5-world-art`, worktree `~/Projects/ashenmarch-a5`, from `main` at b97cbab (A2 merged). The dwarf's sim size, which was queued first, is deferred by Tim.

## Why

Tim finds the world "very pixelated" and "not great looking". He wants better-looking ground and buildings, and maps that play better: choke points made by houses or terrain, and natural cover along the paths, such as downed trees. In his words, it should be "both": how the maps look and how fights play. His reference is Myth II, where terrain, building placement and bridges all shape a battle.

Myth II is a reference for **principles only**:
- painted ground draped over a fine mesh;
- real 3D buildings, walls and bridges;
- terrain that offers choices (a long low route against a short high one, crossings as the places to hold).

No layout, name, art or text is taken from it, per the project rule.

## The work is two phases

1. **Phase 1, the look (this spec's build scope).** It is view only: the sim, the maps' height and mask files, and the golden replays don't change.
2. **Phase 2, the play.** The direction is agreed here, and it gets its own spec and plan before any code. It changes the maps and the sim, so the goldens are re-recorded.

The look goes first because it is cheaper, can't break gameplay, and supplies the models Phase 2 places as cover.

## What exists today

- **Ground.** `view/terrain/` draws a 1 m grid in chunks of 64 cells, flat-shaded:
  - Every sample gets one colour by height band, ground type and water depth.
  - That colour is read through `filter_nearest` textures with one texel per sample, which gives the blocky, stair-stepped look.
  - The shader also carries fire, wetness, snow, the water tint and the mission's grade (Atmosphere).
- **Buildings.** There are no models. `MapBuilder.house()` and `wall()` raise a footprint of samples and mark it blocked in the mask:
  - Blocked samples stop movement and projectiles, and are drawn darker.
  - Riverside has 8 village houses, The Ford has houses and a wall with a gate, and Old Mill has the mill (10 × 10 m, 6 m tall) on a raised plateau.
- **Where structures are recorded.** Their positions live only in each map's generator, `scripts/gen_<map>.gd`. The map data keeps just the resulting blocked samples.
- **Water.** It is only a tint on the riverbed. The mask stores a depth class 0 to 4 per sample, not a surface height.
- **Map sizes.** All maps use 1 m cells (`cell_size` 1000). Riverside is 512 × 512, The Ford 384 × 384, and Old Mill 320 × 320. Skirmish uses the same terrains.
- **Budget.** The Web tab measured 514 of 1,000 MB at A2's end; audio is 168 of its own 270 MB. The art in `assets/` and `art-src/` is LFS, and every shipped file has a row in `assets/LICENSES.md`, which allows owned or CC0 sources only.

## Goals

- The ground reads as natural material at the default zoom and up close. Grass, brush, forest floor, sand, rock and mud blend into each other, with no visible grid, square steps or faceted shading.
- Houses, walls and the mill are real 3D models standing where the sim's solid footprints are.
- Water reads as water: a surface at the right height, with shorelines that blend.
- Old Mill keeps its campaign darkening but is no longer one orange-brown. Its plateau, cliff, ramps and units read clearly.
- All three campaign maps and their skirmish versions get the new look, and future maps get it automatically from their data.
- The Web build stays within budget, measured by the `?budget=1` run, the same check A4 and A2 used.

## Non-goals (Phase 1)

- No change to the sim, the height and mask files, passability, line of sight, or the golden replays.
- No new buildings, cover, bridges, standing trees or choke points; those are Phase 2.
- No new map, and no paid asset generation (Meshy stays for later swaps, per Tim).
- No dynamic lighting or shadow overhaul beyond what models need to sit on the ground convincingly.

## Anti-goals (failures even if it technically works)

- A model that doesn't match its solid footprint, so units clip into walls or stop short of them. The sim's footprint is the truth, and the model fits it.
- Visible texture tiling across the map: the same patch repeating in a grid at the default zoom.
- Ground so busy or dark that units, blood, fire and the plateau are harder to read than today. The battle must stay readable.
- A broken grade: Old Mill's darkening, wetness, snow and fire charring must still show on the new ground.
- Anything that breaks the Web budget or drops frame rate noticeably on this Mac.

## Approaches (Tim chose 1 for both, 2026-11-24)

**Ground:**
1. **Chosen: tiling textures blended live in the terrain shader.** Each ground type gets a CC0 photo-style texture set, blended smoothly from the map data with noise along the borders, plus smooth shading.
   - Every map gets it automatically, detail holds up close, and memory is small.
2. **A painted colour map per map, Myth's way.** It's easy to hand-touch, but blurry up close (about 8 px a metre at affordable sizes) and costs 16 to 64 MB per map.
3. **Both.** A small painted map for large-scale character plus approach 1 for detail. It's kept in reserve, if approach 1 alone looks flat.

**Buildings and cover models:**
1. **Chosen: free CC0 kits.** The main source is Quaternius's Medieval Village MegaKit (glTF, CC0, built against Godot 4.3+), re-textured or graded toward the units' look.
2. **Meshy**, the units' pipeline. The style matches, but it costs credits and audition rounds. It stays available to swap any single kit model that clashes.
3. **Simple shapes built in code.** They're free but read as placeholders.

## Phase 1 design

### Sources and pipeline (Claude's calls)

- **Ground textures:** ambientCG or Poly Haven, both CC0 (verified 2026-11-24). Six sets, one per ground look: grass, brush, forest floor (for WOOD), sand, rock, and mud for shorelines and wet banks. Each set is colour and normal maps, at 1K or 2K by eye, compressed S3TC like the unit art.
- **Models:** the Quaternius Medieval Village MegaKit (CC0, verified 2026-11-24). It covers house shells and roofs, stone and timber walls, a gate, and pieces for the mill. Kenney's kits (CC0, already allowed) are the fallback for anything missing.
- **Layout:**
  - The downloaded source packs go in `art-src/world/`, in LFS, where Godot skips them.
  - The chosen, renamed and compressed files go in `assets/world/textures/` and `assets/world/models/`, also LFS.
  - Each shipped file gets a `LICENSES.md` row naming the pack and its CC0 terms. The allowed-sources line at the top of `LICENSES.md` gains ambientCG, Poly Haven and Quaternius.
- **Import step:** one free, local script (`scripts/art/world/`) picks the files, renames them, writes the import settings and the licence rows, and refuses anything not on its CC0 source list.
  - Getting the packs: Claude downloads them from the packs' own pages, which need no account or key. Downloaded archives are untrusted: each is unpacked into its own empty folder, and only image and glTF files are taken.
  - If a pack can't be fetched that way (Quaternius is hosted on itch.io), Claude stops and asks Tim to download the free zip into `art-src/world/`, rather than switching sources silently (Claude's call: a silent switch would change the style).

### Ground

- **Smooth shading:** the terrain mesh shares vertices between neighbouring cells and carries smooth normals. The flat-shaded triangles go. Vertices stay exactly on the sim's sample heights.
- **Blending:**
  - The shader reads ground type and blocked state with smooth filtering instead of `filter_nearest`, so borders become gradients a cell or two wide.
  - Low-frequency noise breaks the border lines and varies tint and brightness across the map, so the tiles don't read as a grid.
  - The textures are a texture array, one layer per ground look, sampled at world scale (about 2 to 4 m per tile, set by eye).
- **Slopes:** faces steeper than walkable blend toward rock whatever their ground type, and cliffs use a projection that doesn't stretch. Old Mill's plateau cliff must read as rock.
- **Kept layers:** fire (glow where burning, charred after), wetness darkening, snow on up-facing faces, the water tint, and the Atmosphere grade (per-ground recolour, desaturation, tint) all apply to the new ground. Blocked darkening stays only as the fallback for a blocked sample that has no model on it.
- **Explosion scars:** `rebuild_region()` keeps working. Scarred ground re-meshes with smooth normals and the same blending.

### Water

- The generators know each water body's real depth in metres. They save a **view-only water-surface map** beside each map, `maps/<id>/water.png`: surface height per sample, zero where dry.
- A water mesh covers the wet samples at that height:
  - It is translucent and darker with depth, with a slow animated ripple and a soft blend at the shoreline.
  - It is coloured by the mission's `water_grade`, so Old Mill's near-black water stays.
- A Husk under deep water stays hidden exactly as today; the surface is drawing only.

### Structures

- **The structure list:** `MapBuilder.house()` and `wall()` also record what they made: kind, centre, footprint, height, wall polyline and gate gaps. `save()` writes the list to a **view-only** `maps/<id>/structures.tres`. The sim never reads it.
- **Regenerating safely:** regenerating a map to write these files must leave `height.png` and `mask.png` **byte-identical**. A check compares them before and after, and `make verify-replays` must still match `main`.
- **`StructuresView`** (new, `view/structures/`) places one model per recorded structure:
  - **Houses:** a kit house matching the footprint's size and height, chosen by footprint shape and varied by a stable seed from the position, so the same map always looks the same.
  - **Walls:** kit wall segments along the polyline, with a gatehouse or open gap at each gate.
  - **Old Mill:** a mill built from kit pieces.
  - Each model is scaled to fill its footprint exactly. Repeated models are drawn as instances to keep draw calls low.
  - It also hides the blocked darkening under the model.
- **Pathing and sight:** buildings and walls are still the sim's raised, blocked samples, so pathing, projectiles and line of sight are unchanged. A projectile visibly hits the model where the sim says it hits the footprint.
- **The ground under a structure (Claude's call):**
  - The raised slab is never seen: the terrain shader hides the footprint's top and steep skirt where a model stands, and the model covers it.
  - A model's top matches the sim's height for that structure: Riverside's houses peak at 3 m (eaves about 2 m), and the mill at 6 m.
  - So an arrow or grenade the sim stops at the slab top visibly stops at the roof, and `TerrainPicker`, which reads sim heights, still agrees with what's drawn.
  - Taller buildings need a taller sim footprint, which is Phase 2, since those maps are rebuilt anyway.
- **Fit (Claude's call):**
  - The sim's blocked samples win, not the generator's nominal rectangle.
  - Every model edge lies within 0.5 m of the edge of its blocked samples, and the GUT test checks that number.
  - Houses are axis-aligned like their footprints. The door faces the nearest open ground the generator knows of (Riverside's square, a road), with the side varied by a stable seed when there's no such ground.
  - Walls follow their polyline piece by piece, scaled per segment. A diagonal run, such as The Ford's palisade ring, may step its pieces, but stays within the same 0.5 m.
- **Fire and scars on structures (Claude's call):**
  - A model reads the fire state of its footprint samples. It glows and flickers while they burn, and is darkened and charred after, as the ground is today, so a burning house still shows.
  - A scar under a model (a satchel cratering the slab) is ignored visually: the model stays standing, since the sim still treats those samples as blocked.
- **The grade on models (answered by the anti-goals):**
  - Models share one material that applies the mission's grade (tint, desaturation), wetness, snow on up-facing roofs and the fire state, the same way the ground does.
  - So Old Mill's buildings darken with its ground.

### Atmospheres

- All three grades are re-tuned by eye on the new ground. They were tuned for flat colours, and textures read differently.
- **Old Mill gets a deliberate pass:** less red in fog, sky and ambient, less desaturation, and the fog thin enough that the plateau, cliff, ramps and units read. It keeps its place in the campaign's darkening: darker and more ashen than The Ford, short of the end.
- Tim judges each grade in a listening-style look build (Riverside, The Ford, Old Mill, a skirmish), as he did A2's sound.

### Budget and performance

- **Memory:** about 12 MB of ground textures at 1K or about 50 MB at 2K, plus a few MB of models. That's well inside the roughly 486 MB left in the 1,000 MB tab.
- **Measuring:** the `?budget=1` run on Web must stay `measured` and PASS. Frame rate is checked in that run and in `make budget` on desktop, against A2's numbers.
- **Draw calls:** instanced models and the existing chunking keep the count bounded, and the budget line's video and textures fields are watched.

### Verification

- **GUT:**
  - the structure list round-trips through `save()`;
  - `StructuresView` places one model per structure, fitting its footprint;
  - the terrain shader still receives every existing uniform (fire, wetness, snow, grade);
  - smooth normals and vertex heights match the sim samples;
  - every map has a water map whose wet samples match its depth classes.
- **Other checks:** `make verify-replays` matches `main`; `make check-sim`, `check-layout` and `check-leaks` pass; the import script has Python tests.
- **Tim's eye:** a look build on macOS and on Web. He approves the look, and the gate is his approval plus a passing Web budget.

### Left as they are in Phase 1 (Claude's calls)

- The overhead map (Tab) and the other views that draw the terrain from `TerrainPalette` keep their flat colours. Phase 1 is the 3D world.
- The renderer is Compatibility, which has no depth texture, so the water's shoreline blend is driven by the water map.

## Phase 2: the play (agreed direction, its own spec later)

- **Choke points** come from houses and terrain: gaps between buildings, passes between rocky slopes, and fords and bridges as the natural places to hold a line.
- **Cover** is natural features along the paths: downed trees, boulders, carts and low walls.
  - Each is a small blocked footprint with a model on it, using rules the sim already has. It stops movement and missiles, and its real height means flat shots are stopped while lobbed ones can still drop over.
  - Cover stops missiles but doesn't hide units (Tim, 2026-11-24). Concealment would need new sight rules and is out.
- **Standing trees** belong here too: they would block arrows, so they're gameplay.
- **Paths** are never sealed: at least 4 m of walkable width, per the slope-ring rule in `docs/architecture.md`.
- **Bridges** are new to the sim: a walkable deck over water that living units can't otherwise cross.
- **The three maps are reworked in place**, keeping their missions: the village hunt, the river escort and holding the mill. Starts, goals and patrol routes are adjusted, the goldens re-recorded, and mission balance re-checked. The Ford's crossing is its mission, so a bridge there must not remove the wading fight.
- **Skirmish starts** stay fair after the changes.

## Decisions

- **Two phases, the look first.** Claude's proposal; Tim accepted it ("good").
- **Ground approach 1 and model approach 1.** Tim chose them, 2026-11-24.
- **Cover stops missiles only, no concealment.** Tim, 2026-11-24.
- **Claude's calls:**
  - the structure and water data are view-only files beside each map, so the sim and goldens don't move in Phase 1;
  - standing trees go in Phase 2;
  - Quaternius is the main model source, with Kenney as the fallback;
  - the downloads and the import are free local steps.
  - after the builder check: the slab is hidden under models and model tops match the sim's heights; fit within 0.5 m of the blocked samples; doors face open ground; models show fire and char, ignore scars, and take the grade, wetness and snow; Tim supplies a pack only if it can't be fetched; the overhead map stays flat-coloured.

## Left to the builder

- The exact texture sets and kit pieces, and the tile scale, noise frequencies, blend widths, slope-to-rock threshold and water look. These are chosen by eye with Tim at the look build.
- How kit houses map to footprint sizes and heights, as long as each model fills its footprint exactly.
- 1K or 2K textures, by eye and budget.

## Risks

- **Kit style against the units.** If a kit model clashes, it is swapped for a Meshy model one at a time, which costs credits and needs Tim's OK.
- **Footprint fit.** The houses' footprints were sized for gameplay, not architecture, so some kit houses may need non-uniform scaling or a custom mix of pieces.
- **Web shader cost.** A texture array plus noise per pixel costs more than today's flat colours. The budget run's frame rate decides whether 2K or extra layers are affordable.
- **Byte-identical regeneration.** If a generator can't reproduce today's height and mask files exactly (for example after an engine noise change), Phase 1 can't regenerate. The structure and water lists would then be written by a separate script that reads today's files and the generators' constants.
