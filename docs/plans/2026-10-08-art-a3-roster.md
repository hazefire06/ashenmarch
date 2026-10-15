# Art track A3: the rest of the roster — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the nine other v1 units (Reaver, Longbow, Sapper, Warden, Husk, Ripper, Blightbag, Drifter, Stormcaller) approved sprite art through the A1 pipeline. First comes a handful of free pipeline changes the roster needs; then the units in four Tim-gated batches.

**Architecture:**
- Part 1 is code (free):
  - recipe fields;
  - two renderer tasks;
  - one game-side task;
  - a re-render of the Shieldman so his art gains the new figure height and stops shipping an audition clip.
- Part 2 is four batches. Each is recipes, then Tim's paid Meshy runs and picks, then free renders, a contact-sheet gate and a commit.
- Nothing here touches the sim. Nothing touches Phase 11's files (input, selection, `main.gd`).

**Tech Stack:**
- Python 3.12 (stdlib only) for `scripts/art/`, plus headless Blender 5.2.2 LTS;
- Godot 4.7 GDScript with GUT 9.7.1;
- Meshy API: Tim runs the paid commands;
- Git LFS.

**Spec:** `docs/specs/2026-10-01-art-audio-design.md`, §5–7 and §11 (A3, decided 2026-10-08). §11 is binding for scope, batches, clips, props and credits.

## Global Constraints

- **Render format.** Sprite cells are 160 px with a 4 px gutter (stride 168), the feet 40 px up, 52 px per metre, 50° orthographic camera, 12 fps, 8 directions.
- **Sheet size.** Sheets wrap at 4096 px wide (`columns`, `rows_per_direction` in the sidecar), and from Task 2 must also be at most 4096 px tall.
- **Candidates.** 4 Lite candidates per unit: `[candidates] lite = 4, full = 0, polycount = 30000`. Props: `lite = 2, full = 0, polycount = 6000`.
- **Paid commands are Tim's.** Tim runs every paid command (`candidates`, `build`, `prop-candidates`, `prop-build`) in Terminal.app, unpiped, with `--max-credits`. Agents never run them, never call Meshy, and never read `~/.config/ashenmarch`.
- **Python.** `scripts/art/` is stdlib-only Python with type hints. GDScript is statically typed, one class per file, `class_name`.
- **Original work only.** No names, looks or text from existing games or books (CLAUDE.md). Every prompt below is original.
- **Off-limits files.** `view/input_bindings.gd`, `view/main.gd` and `view/units/selection_controller.gd` (Phase 11 is changing them); and `sim/`.
- **Commits.** Imperative subject, why-body. Stage by name, never `git add -A` or `git add .`. End each message with exactly:
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`
- **Licences.** Every shipped file under `assets/` gets a row in `assets/LICENSES.md`.

## Review Focus

1. **Clicking a unit in a dense formation of art units** selects the unit drawn under the cursor, not the one in front. Pinned by Task 4's test that an art sprite's `height` is its figure height, which is what the picking code reads.
2. **A unit with no `attack` clip that is told to melee** (for example a confused Drifter) plays its strike clip rather than freezing on idle. Pinned by Task 4's animator test.
3. **A Blightbag killed with no overkill** (friendly fire, burning) bursts into gibs; it doesn't stand as an idle "corpse". With gibs off, its body disappears. Pinned by Task 4's tests.
4. **A hovering unit's idle loops without a hitch:** the bob completes whole cycles, so the first and last frames sit at the same height. Pinned by Task 3's test.
5. **The re-rendered Shieldman looks the same.** Its game sheets match the committed ones apart from the dropped audition sheet, and the game loads the new sidecar. Pinned by Task 5's comparison step.

---

## File map

| File | Change | Task |
|---|---|---|
| `scripts/art/unit_spec.py`, `scripts/art/test_unit_spec.py` | `AnimEntry.audition`, `bob_m`, `bob_hz`, `stride_m`; validation | 1 |
| `art-src/units/shieldman/spec.toml` | `attack_alt` becomes `audition = true` | 1 |
| `scripts/art/render_sprites.py`, `scripts/art/blender_test_render.py` | figure height; audition clips review-only; sheet-height cap; no-action error; ffmpeg up front | 2 |
| same | hover bob and stride override | 3 |
| `view/units/unit_art.gd`, `scripts/art/unit_art_builder.gd`, `view/units/unit_sprite.gd`, `view/units/units_view.gd`, `view/units/unit_animator.gd`, `tests/view/test_unit_art.gd`, `tests/view/test_unit_art_view.gd`, `tests/view/test_unit_animator.gd`, `tests/support/test_art.gd` | figure height in game; relaxed strike-clip validation; forced burst; strike fallback | 4 |
| `assets/units/shieldman/*`, `data/art/shieldman.tres`, `art-src/units/shieldman/review/*`, `assets/LICENSES.md` | Shieldman re-render (no `attack_alt.png`) | 5 |
| `art-src/units/{reaver,longbow}/spec.toml`, `art-src/props/{claymore,longbow_bow}/spec.toml`, then their art | batch 1 | 6 |
| `art-src/units/{sapper,warden}/…`, `art-src/props/{satchel,warden_staff}/…` | batch 2 | 7 |
| `art-src/units/{husk,ripper,blightbag}/…` | batch 3 | 8 |
| `art-src/units/{drifter,stormcaller}/…`, `art-src/props/{drifter_bow,storm_staff}/…` | batch 4 | 9 |
| `docs/architecture.md`, `docs/prompts.md` | A3 notes; PR | 10 |

---

# Part 1: pipeline (free)

### Task 1: Recipe fields for audition clips, hover and stride override

**Files:**
- Modify: `scripts/art/unit_spec.py` (`AnimEntry`, `_anim`)
- Modify: `art-src/units/shieldman/spec.toml` (`[animations.attack_alt]`)
- Test: `scripts/art/test_unit_spec.py`

**Interfaces:**
- Produces: `AnimEntry` gains four fields, all with defaults so existing callers keep working:
  - `audition: bool = False`;
  - `bob_m: float = 0.0`;
  - `bob_hz: float = 0.0`;
  - `stride_m: float | None = None`.
- Produces: `GAME_ANIMS: frozenset[str] = frozenset({"idle", "walk", "attack", "die", "shoot", "throw", "cast", "place"})` in `unit_spec.py`. It must match `UnitArtBuilder.GAME_ANIMS` in GDScript.

- [ ] **Step 1: Write the failing tests** (append to `scripts/art/test_unit_spec.py`, in the style of its existing recipe tests that write a temp `spec.toml` and call `load_spec`):

```python
class A3RecipeFieldsTest(unittest.TestCase):
    def _load(self, animations: str) -> UnitSpec:
        folder = Path(self._tmp.name) / "unit_x"
        folder.mkdir()
        (folder / "spec.toml").write_text(
            'id = "unit_x"\nfaction = "dark"\nheight_m = 1.8\nprompt = "x"\n' + animations, encoding="utf-8")
        return load_spec(folder / "spec.toml")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_new_fields_default_off(self) -> None:
        spec = self._load('[animations.idle]\naction = 0\nclip = "Idle"\n')
        entry = spec.animations[0]
        self.assertEqual((entry.audition, entry.bob_m, entry.bob_hz, entry.stride_m), (False, 0.0, 0.0, None))

    def test_an_audition_clip_parses(self) -> None:
        spec = self._load('[animations.attack_alt]\naction = 128\nclip = "Heavy_Hammer_Swing"\nimpact = 0.5\naudition = true\n')
        self.assertTrue(spec.animations[0].audition)

    def test_a_game_clip_cannot_be_an_audition(self) -> None:
        with self.assertRaises(SpecError):
            self._load('[animations.attack]\naction = 97\nclip = "Left_Slash"\naudition = true\n')

    def test_hover_and_stride_parse(self) -> None:
        spec = self._load('[animations.walk]\naction = 0\nclip = "Idle"\nbob_m = 0.08\nbob_hz = 0.8\nstride_m = 1.2\n')
        entry = spec.animations[0]
        self.assertEqual((entry.bob_m, entry.bob_hz, entry.stride_m), (0.08, 0.8, 1.2))

    def test_bad_hover_and_stride_are_refused(self) -> None:
        for bad in ("bob_m = -0.1\nbob_hz = 1.0\n", "bob_m = 0.1\n", "bob_m = 0.1\nbob_hz = 0.0\n",
                    "bob_m = nan\nbob_hz = 1.0\n", "stride_m = 0.0\n", "stride_m = inf\n", "bob_m = true\nbob_hz = 1.0\n"):
            with self.subTest(bad=bad), self.assertRaises(SpecError):
                self._load('[animations.walk]\naction = 0\nclip = "Idle"\n' + bad)
```

Also extend the real-recipe test to pin the Shieldman's audition clip: in `ShieldmanSpecTest.test_the_committed_recipe_parses`, add
`self.assertTrue(next(a for a in spec.animations if a.name == "attack_alt").audition)`.

- [ ] **Step 2: Run them to see them fail**

Run: `python3 -m unittest discover -s scripts/art -p "test_unit_spec.py" -v`
Expected: FAIL with `TypeError`/`AttributeError` (no `audition` field) and missing `SpecError`s.

- [ ] **Step 3: Implement**

In `scripts/art/unit_spec.py`:
- **`GAME_ANIMS`.** Add the constant above, with the comment `# Mirrors UnitArtBuilder.GAME_ANIMS: the clips the game plays. Anything else is an audition.`
- **`AnimEntry`.** Add the four fields after `loop`, with defaults.
- **`_anim(name, entry)`.**
  1. Read `audition = entry.get("audition", False)`. If it isn't a `bool`, raise `SpecError(f"animation {name}: audition is true or false")`. If it is true and `name in GAME_ANIMS`, raise `SpecError(f"animation {name}: a clip the game plays can't be an audition")`.
  2. Read `bob_m` and `bob_hz` with a helper `_non_negative(name, key, value) -> float`. It rejects bools, non-numbers and non-finite values, and requires the value to be 0 or more. If `bob_m > 0`, require `bob_hz > 0` (`SpecError(f"animation {name}: a bob needs bob_hz > 0")`).
  3. Read `stride_m`. If present it must be a finite number above 0 and not a bool.
  4. If `_anim` rejects unknown keys, add the four new keys to its allowed set.
- Update the module docstring with one line per new field.

In `art-src/units/shieldman/spec.toml`, under `[animations.attack_alt]`, replace the comment `# Auditioned on the contact sheet only; the game plays "attack".` with:
```toml
# Auditioned on the contact sheet only (review/), never shipped; the game plays "attack".
[animations.attack_alt]
action = 97
clip = "Left_Slash"
impact = 0.45
audition = true
```

- [ ] **Step 4: Run them to see them pass**

Run: `python3 -m unittest discover -s scripts/art -p "test_*.py"` and `python3 scripts/art/meshy.py plan shieldman` (free).
Expected: all OK. The plan output is unchanged: auditions are still bought, because they are rendered for review.

- [ ] **Step 5: Commit**

```bash
git add scripts/art/unit_spec.py scripts/art/test_unit_spec.py art-src/units/shieldman/spec.toml
git commit -F - <<'EOF'
Add audition, hover and stride-override fields to unit recipes

A3's roster needs clips rendered for review only, a floating unit's bob,
and a fixed stride where no foot touches the ground. A game clip can't be
an audition, and bad numbers are refused as the recipe loads.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

---

### Task 2: Renderer — figure height, review-only auditions and three guards

**Files:**
- Modify: `scripts/art/render_sprites.py` (`Extents`, `stage_animation`, `render_animation`, `render_unit`, `render_attach`, `render_candidates`, `render_prop_candidates`, a new `MAX_SHEET_ROWS` constant)
- Test: `scripts/art/blender_test_render.py`

**Interfaces:**
- Consumes: `AnimEntry.audition` (Task 1).
- Produces: the sidecar gains a top-level `"figure_height_m": float`. It is the drawn body's height above the feet, from idle, props excluded, worst over idle's frames and directions, rounded to 0.001. It is omitted if no `idle` clip was rendered.
- Produces: audition clips write `review/<name>.gif` and a contact-sheet row only. They get no `assets/units/<id>/<name>.png`, no `.png.import` and no sidecar entry.

- [ ] **Step 1: Write the failing tests** (in `scripts/art/blender_test_render.py`, using the existing generated fixture and its `render_fixture` helper; add a test class or extend `RenderSpritesTest`):

```python
    def test_figure_height_comes_from_the_body_not_the_props(self) -> None:
        # The fixture block is 1.8 m tall, seen from 50 degrees: its top sits at
        # (highest px - FEET_PX) / PIXELS_PER_METER. The prop test variant attaches
        # a stick above the head, which must not raise it.
        plain = self.sidecar["figure_height_m"]
        self.assertGreater(plain, 1.0)
        self.assertLess(plain, 1.8)
        with_prop = render_fixture_with_prop_above_the_head(self.root)   # helper: as the prop tests do, bone at the head, offset +0.5 m up
        self.assertAlmostEqual(with_prop["figure_height_m"], plain, delta=0.01)

    def test_an_audition_clip_is_review_only(self) -> None:
        sidecar, assets, review = render_fixture_with_audition(self.root)  # helper: fixture spec plus [animations.idle_alt] file=anims/idle.glb, audition=true
        self.assertNotIn("idle_alt", sidecar["animations"])
        self.assertFalse((assets / "idle_alt.png").exists())
        self.assertFalse((assets / "idle_alt.png.import").exists())
        self.assertTrue((review / "idle_alt.gif").exists())

    def test_a_sheet_taller_than_4096_px_is_refused(self) -> None:
        with mock.patch.object(rs, "MAX_SHEET_ROWS", 1):   # 8 rows of 168 px; the 30-frame walk needs 16
            with self.assertRaisesRegex(RuntimeError, "taller than"):
                render_fixture(self.root, parented=False)

    def test_a_clip_whose_file_has_no_animation_is_an_error(self) -> None:
        # The fixture's walk GLB, re-exported without its action, under an entry
        # that names a clip: the render must stop, not draw one frame.
        with self.assertRaisesRegex(RuntimeError, "no animation"):
            render_fixture_without_actions(self.root)          # helper: spec entry [animations.walk] file=anims/static.glb clip="walk"

    def test_ffmpeg_is_checked_before_rendering(self) -> None:
        with mock.patch.object(rs.shutil, "which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "ffmpeg"):
                render_fixture(self.root, parented=False)
        # nothing was rendered: no frames, no sheets
        self.assertFalse(any((self.root / "assets").rglob("*.png")))
```

Write the three helpers next to `render_fixture`, building their variant fixture the way the existing prop and in-place-walk fixtures are built: a temp `art-src`, a recipe string, and GLBs exported in the test.

- [ ] **Step 2: Run them to see them fail**

Run: `make test-art`
Expected: the Blender tests fail with `KeyError: 'figure_height_m'` and the missing refusals.

- [ ] **Step 3: Implement**

In `scripts/art/render_sprites.py`:

```python
MAX_SHEET_ROWS = MAX_SHEET_PX // STRIDE  # 24 rows of 168 px; 8 directions x 3 = 72 frames at most


def require_ffmpeg() -> None:
    if shutil.which("ffmpeg") is None:
        raise RuntimeError("ffmpeg not found (brew install ffmpeg); checked before rendering so no work is wasted")
```

- **ffmpeg check.** Call `require_ffmpeg()` first thing in `render_unit`, `render_attach`, `render_candidates` and `render_prop_candidates`, before `reset_scene()` or any import.
- **No-animation error.** In `stage_animation`, after `import_glb`: if `not actions and (entry.clip or entry.action_id is not None)`, raise `RuntimeError(f"{glb.name}: no animation in the file, but {entry.name} names clip {entry.clip!r}")`. A plain `file=` entry with no clip, as fixtures use, still renders as a still.
- **Figure height.** Track it with a second `Extents` over the body only. `staged.prop_meshes` lists the props, so the body is `[o for o in bpy.context.scene.objects if o.type == "MESH" and o not in staged.prop_meshes]`.
  - In `render_animation`, for `entry.name == "idle"`, add `world_vertices(body)` to a `body_extents` each frame and direction.
  - Return `"figure_px": body_extents.highest - FEET_PX` in the info for idle only.
  - In `render_unit`, pop it and set `sidecar["figure_height_m"] = round(figure_px / PIXELS_PER_METER, 3)`.
- **Sheet-height cap.** In `render_animation`, after `columns, rows = sheet_layout(frames)`:

```python
    if DIRECTIONS * rows > MAX_SHEET_ROWS:
        raise RuntimeError(f"{entry.name}: {frames} frames at {FPS} fps makes a sheet {DIRECTIONS * rows * STRIDE} px "
                           f"taller than {MAX_SHEET_PX}; pick a shorter clip or mark it audition = true")
```

  Audition clips are exempt: they make no sheet. Check `entry.audition` first.
- **Audition clips.** In `render_unit`'s loop:
  - `if entry.audition:` write only the GIF to `review/` and add its contact-sheet row. Do not `tile()` to `out_dir`, do not `write_import_settings`, and do not add the clip to `sidecar["animations"]`. Its `clipped` frames still count.
  - Otherwise keep today's path.
  - `render_attach` keeps previewing `attack*` clips, auditions included, because tuning a prop needs them.
- Update the module docstring: figure height, auditions, and the three guards.

- [ ] **Step 4: Run them to see them pass**

Run: `make test-art`
Expected: Python tests OK; Blender tests OK, including the five new ones.

- [ ] **Step 5: Commit**

```bash
git add scripts/art/render_sprites.py scripts/art/blender_test_render.py
git commit -F - <<'EOF'
Measure figure height and keep audition clips out of the game

Picking and overlays need the drawn body's height, which is shorter than
the placeholder's at a 50 degree camera; props are excluded so a raised
sword doesn't count. Auditions are for Tim's review only, so they no
longer ship a sheet. A sheet over 4096 px tall, a clip file with no
animation, and a missing ffmpeg now stop the render before any work.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

---

### Task 3: Renderer — hover bob and stride override

**Files:**
- Modify: `scripts/art/render_sprites.py` (`pose_at`, `render_animation`, `measure_stride`)
- Test: `scripts/art/blender_test_render.py`

**Interfaces:**
- Consumes: `AnimEntry.bob_m`, `bob_hz`, `stride_m` (Task 1).
- Produces: a bobbing clip whose loop is seamless, and a sidecar `stride_m` equal to the recipe's override when one is set.

- [ ] **Step 1: Write the failing tests**

```python
    def test_a_hover_bob_moves_the_figure_and_loops_seamlessly(self) -> None:
        sidecar, sheet = render_fixture_with_bob(self.root, bob_m=0.2, bob_hz=1.0)   # idle 1 s, bob 0.2 m
        frames = sidecar["animations"]["idle"]["frames"]
        lows = [lowest_opaque_row(sheet, f, 4, sidecar["animations"]["idle"]) for f in range(frames)]
        # 0.2 m up and down at 50 degrees is about 0.2 * cos(50) * 52 = 6.7 px each way
        self.assertGreaterEqual(max(lows) - min(lows), 10)
        # whole cycles: a looping clip's first frame and the frame after its last coincide,
        # so frame 0 and the last frame differ by one step of the sine, not a jump
        self.assertLessEqual(abs(lows[0] - lows[-1]), 3)

    def test_a_stride_override_replaces_the_measurement(self) -> None:
        sidecar = render_fixture_with_walk_override(self.root, stride_m=0.9)   # in-place walk fixture plus stride_m = 0.9
        self.assertAlmostEqual(sidecar["animations"]["walk"]["stride_m"], 0.9, places=4)
```

`lowest_opaque_row(sheet, frame, direction, info)` reads the cell through the existing `cell()` helper, honouring `columns` and `rows_per_direction`, and returns the lowest row with alpha above 0.

- [ ] **Step 2: Run them to see them fail**

Run: `make test-art`. Expected: the two new tests fail. The figure doesn't move, and the stride is the measured one.

- [ ] **Step 3: Implement**

```python
def bob_offset(entry: AnimEntry, start: float, end: float, frame: float, rate: float) -> float:
    """Metres to lift the figure at frame: a sine of bob_m whose period is stretched so the
    clip holds a whole number of cycles (at least one), so a looping clip stays seamless."""
    if entry.bob_m <= 0.0:
        return 0.0
    duration = max((end - start) / rate, 1e-6)
    cycles = max(1, round(entry.bob_hz * duration))
    t = (frame - start) / rate
    return entry.bob_m * math.sin(2.0 * math.pi * cycles * t / duration)
```

- **Bob.** `pose_at(staged, frame)` gains `entry: AnimEntry` and adds `bob_offset(...)` to `staged.holder.location.z` after the root cancel. It is applied before `world_vertices`, so extents and clipping include the bob. `render_attach` passes the entry too.
- **Stride override.** In `render_animation`, `stride_m = entry.stride_m if entry.stride_m is not None else (measure_stride(staged, entry) if … as today)`.

- [ ] **Step 4: Run them to see them pass.** Run `make test-art`; everything is OK.

- [ ] **Step 5: Commit**

```bash
git add scripts/art/render_sprites.py scripts/art/blender_test_render.py
git commit -F - <<'EOF'
Bob hovering units and let a recipe fix a stride

The Drifter floats: its idle and glide get a gentle bob that completes
whole cycles per clip, so loops don't jump. A floating walk has no foot
contact to measure, so the recipe's stride_m is used instead.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

---

### Task 4: Game side — figure height, strike clips, forced bursts

**Files:**
- Modify: `view/units/unit_art.gd` (`figure_height_m`, `STRIKE_ANIMS`, `TIMED_ANIMS`, `validate`)
- Modify: `scripts/art/unit_art_builder.gd` (read optional `figure_height_m`)
- Modify: `view/units/unit_sprite.gd` (`setup`: an art body's `height`)
- Modify: `view/units/units_view.gd` (KILL handling: bursts)
- Modify: `view/units/unit_animator.gd` (melee strike fallback)
- Modify: `tests/support/test_art.gd` (optional `figure_height_m`)
- Test: `tests/view/test_unit_art.gd`, `tests/view/test_unit_art_view.gd`, `tests/view/test_unit_animator.gd`

**Interfaces:**
- Consumes: the sidecar's optional `figure_height_m` (Task 2).
- Produces:
  - `UnitArt.figure_height_m: float`, where 0 means unknown;
  - `UnitArt.STRIKE_ANIMS: Array[StringName] = [&"attack", &"shoot", &"throw", &"cast"]`;
  - `UnitArt.TIMED_ANIMS: Array[StringName] = [&"attack", &"shoot", &"throw", &"cast", &"place"]`.

- [ ] **Step 1: Write the failing tests**

In `tests/view/test_unit_art.gd`:

```gdscript
func test_a_unit_without_melee_needs_no_attack_clip() -> void:
	var art: UnitArt = TestArt.art(&"x", {
		"idle": [1, 12, true, -1], "walk": [12, 12, true, -1], "shoot": [8, 12, false, 5], "die": [4, 12, false, -1],
	})
	assert_eq(art.validate(), PackedStringArray())


func test_some_strike_clip_is_required() -> void:
	var art: UnitArt = TestArt.art(&"x", {"idle": [1, 12, true, -1], "walk": [12, 12, true, -1], "die": [4, 12, false, -1]})
	assert_string_contains(" ".join(art.validate()), "no strike clip")


func test_every_strike_and_act_clip_needs_an_impact_frame() -> void:
	for anim: String in ["shoot", "throw", "cast", "place"]:
		var anims: Dictionary = {"idle": [1, 12, true, -1], "walk": [12, 12, true, -1], "attack": [6, 12, false, 3], "die": [4, 12, false, -1]}
		anims[anim] = [6, 12, false, -1]
		assert_string_contains(" ".join(TestArt.art(&"x", anims).validate()), "%s has no impact frame" % anim, anim)


func test_the_builder_reads_figure_height_when_present() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	assert_eq(UnitArtBuilder.build(side, TestArt.sheets(side)).figure_height_m, 0.0, "absent: unknown")
	side["figure_height_m"] = 1.41
	assert_almost_eq(UnitArtBuilder.build(side, TestArt.sheets(side)).figure_height_m, 1.41, 0.0001)
```

In `tests/view/test_unit_art_view.gd`, using its existing fixtures and helpers. `before_each` builds `_world` with `_shieldman` and `_longbow` and a live `_gibs`. The helpers are `_art_view(world, art, selection, gibs)`, `_sprite(unit)`, `_sprite_in(view, unit)` and `_kill(unit, source_x, source_z, overkill)`:

```gdscript
func test_an_art_body_is_as_tall_as_its_figure() -> void:
	var art: UnitArt = TestArt.art(&"shieldman")
	art.figure_height_m = 1.4
	var view: UnitsView = _art_view(_world, art, UnitSelection.new(), _gibs)
	assert_almost_eq(_sprite_in(view, _shieldman).height, 1.4, 0.0001)
	var placeholder: float = _longbow.type.body_height / float(World.UNITS_PER_METER)
	assert_almost_eq(_sprite_in(view, _longbow).height, placeholder, 0.0001, "placeholders unchanged")


func test_an_art_body_with_unknown_figure_height_keeps_the_type_height() -> void:
	# before_each's art has figure_height_m = 0
	assert_almost_eq(_sprite(_shieldman).height, _shieldman.type.body_height / float(World.UNITS_PER_METER), 0.0001)


func test_a_bursting_art_body_always_bursts() -> void:
	var view: UnitsView = _art_view(_world, TestArt.art(&"shieldman", {}, true), UnitSelection.new(), _gibs)
	var before: int = _gibs.live_chunk_count()
	_kill_in(view, _world, _shieldman, 30 * M, 29 * M, 0)
	assert_gt(_gibs.live_chunk_count(), before, "burst with no overkill")
	assert_false(_art_body(_sprite_in(view, _shieldman)).visible, "the body is gone")


func test_a_bursting_art_body_with_no_gibs_still_goes() -> void:
	var view: UnitsView = _art_view(_world, TestArt.art(&"shieldman", {}, true), UnitSelection.new(), null)
	_kill_in(view, _world, _shieldman, 30 * M, 29 * M, 0)
	assert_false(_art_body(_sprite_in(view, _shieldman)).visible, "no gibs, but the body still goes")
```

`UnitSprite.set_gibbed()` hides the art body node (`_art_body.visible = false`), so the tests read it through the file's `_art_body(sprite)` helper.

In `tests/view/test_unit_animator.gd`:

```gdscript
func test_a_melee_strike_without_an_attack_clip_plays_a_strike_clip() -> void:
	var animator: UnitAnimator = UnitAnimator.new(TestArt.art(&"x", {
		"idle": [1, 12, true, -1], "walk": [12, 12, true, -1], "shoot": [8, 12, false, 5], "die": [4, 12, false, -1],
	}))
	var input: UnitAnimator.AnimInput = UnitAnimator.AnimInput.new()
	input.alive = true
	input.windup_left = 6
	assert_eq(animator.after_tick(input).anim, &"shoot")
```

- [ ] **Step 2: Run them to see them fail**

Run: `make test`.
Expected: the new tests fail (`figure_height_m` unknown, `missing attack`, no burst, `&"idle"` chosen). Everything else passes.

- [ ] **Step 3: Implement**

`view/units/unit_art.gd`:

```gdscript
## Every art has idle and walk, die unless the body bursts, and at least one strike clip.
const REQUIRED: Array[StringName] = [&"idle", &"walk"]
## A strike: the melee swing, or the release of a shot, a throw or a spell.
const STRIKE_ANIMS: Array[StringName] = [&"attack", &"shoot", &"throw", &"cast"]
## Clips timed to land on a sim tick, so each needs its impact frame.
const TIMED_ANIMS: Array[StringName] = [&"attack", &"shoot", &"throw", &"cast", &"place"]

## Meters from the feet to the top of the drawn body (idle, props left out);
## 0 when the render didn't record it. Picking and overlays use it.
@export var figure_height_m: float = 0.0
```

In `validate()`:
- After the `needed` loop, add: `if not STRIKE_ANIMS.any(func(a: StringName) -> bool: return has_anim(a)): errors.append("%s: no strike clip (attack, shoot, throw or cast)" % who)`.
- Replace the attack-only impact check with: `for anim: StringName in TIMED_ANIMS: if has_anim(anim) and not impact_frames.has(anim): errors.append("%s: %s has no impact frame" % [who, anim])`.
- Add `if figure_height_m < 0.0: errors.append(...)`.

`scripts/art/unit_art_builder.gd` `build()`: add `art.figure_height_m = float(sidecar.get("figure_height_m", 0.0))`.

`view/units/unit_sprite.gd` `setup()`: right after `_art = art`:

```gdscript
	# An art body is as tall as the figure it draws (shorter than the type's
	# body at the 50 degree render), so picking and overlays match it.
	if _art != null and _art.figure_height_m > 0.0:
		height = _art.figure_height_m
```

`view/units/units_view.gd`, in the KILL branch:

```gdscript
				var art: UnitArt = _art_for(target)
				var bursts: bool = art != null and art.bursts_on_death
				if _gibs != null and (bursts or Gibs.should_gib(event.overkill, target.type.max_hp)):
					_burst(target, blow)
				elif bursts:
					# No gibs to throw (a test, or gore off): the body still goes.
					_sprite_for(target).set_gibbed()
					_gibbed[target.id] = true
```

`view/units/unit_animator.gd`, in `_strike_started`, change the melee wind-up line from
```gdscript
		return _timed(_pick([&"attack"], &"idle"), input.windup_left)
```
to
```gdscript
		# attack first; a unit with no melee clip (a confused archer) uses its other strike clip
		return _timed(_pick(UnitArt.STRIKE_ANIMS, &"idle"), input.windup_left)
```
`STRIKE_ANIMS` starts with `attack`, so every unit that has one behaves as before.

`tests/support/test_art.gd` needs no change, since `figure_height_m` defaults to 0. Leave it alone unless a test needs a value.

- [ ] **Step 4: Run them to see them pass**

Run: `make test`.
Expected: all GUT tests pass (the earlier total plus the new ones), and sim purity is ok. Existing tests that pinned "missing attack" or "attack has no impact frame" still pass, because those clips have attack.

- [ ] **Step 5: Commit**

```bash
git add view/units/unit_art.gd scripts/art/unit_art_builder.gd view/units/unit_sprite.gd view/units/units_view.gd view/units/unit_animator.gd tests/view/test_unit_art.gd tests/view/test_unit_art_view.gd tests/view/test_unit_animator.gd
git commit -F - <<'EOF'
Size art units to their figure and accept units without melee

Picking and overlays now follow the drawn figure, so clicking a rear-rank
unit no longer selects the one in front. Archers and casters need a
strike clip, not a melee attack, and every timed clip needs its impact
frame. A unit whose body bursts always bursts, even with no overkill.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

---

### Task 5: Re-render the Shieldman with the new pipeline

The Shieldman's committed sidecar lacks `figure_height_m`, and it ships `attack_alt.png`. Re-rendering is free and deterministic in content: same model, rig, clips and attach.

**Files:**
- Regenerate: `assets/units/shieldman/{idle,walk,attack,die}.png{,.import}`, `assets/units/shieldman/shieldman.json`, `art-src/units/shieldman/review/*`
- Delete: `assets/units/shieldman/attack_alt.png`, `assets/units/shieldman/attack_alt.png.import`
- Regenerate: `data/art/shieldman.tres`, `data/art/catalog.tres` (via `make art-build`)
- Modify: `assets/LICENSES.md` (drop the `attack_alt.png` row)

- [ ] **Step 1: Keep the old sheets for comparison:** `mkdir -p <scratchpad>/shieldman-before && cp assets/units/shieldman/*.png <scratchpad>/shieldman-before/`
- [ ] **Step 2: Render:** `make art-render UNIT=shieldman`, then `make art-build UNIT=shieldman`. Expected:
  - extents print as in A1;
  - `figure_height_m` is about 1.4 in the sidecar;
  - no `attack_alt` in the sidecar or under `assets/`;
  - `review/attack_alt.gif` exists.
- [ ] **Step 3: Compare.** For `idle`, `walk`, `attack` and `die`, compare old and new PNGs with Python and PIL:
  - same size;
  - mean absolute RGBA difference under 2/255, or the differences explained (e.g. EEVEE noise) and shown to Tim as a side-by-side image.
  
  Then `git rm assets/units/shieldman/attack_alt.png assets/units/shieldman/attack_alt.png.import`, and drop its `LICENSES.md` row.
- [ ] **Step 4: Run** `make test`. The real-data tests in `test_unit_art_catalog.gd` still pass, and `data/art/shieldman.tres` has `figure_height_m`.
- [ ] **Step 5: Commit** with LFS checked (`git lfs status` shows the PNGs as LFS objects):

```bash
git add assets/units/shieldman data/art art-src/units/shieldman/review assets/LICENSES.md
git commit -F - <<'EOF'
Re-render the Shieldman with figure height and no shipped audition

Same model, rig, clips and attach; the sidecar now records the drawn
figure's height for picking and overlays, and attack_alt stays in review
as an audition instead of shipping a 3.4 MB sheet nothing plays.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

---

# Part 2: the roster in four batches (paid; Tim gates)

**Every batch follows the same runbook.** These steps are repeated in each batch task, so the batch can be run on its own.

1. **Recipes (free; the agent writes them).** Write `art-src/units/<id>/spec.toml` per unit and `art-src/props/<id>/spec.toml` per prop, with the content given in the batch task. Check them with `python3 scripts/art/meshy.py plan <unit>` and `prop-plan <prop>` (free). Commit the recipes.
2. **Candidates (paid; Tim).** `python3 scripts/art/meshy.py candidates <unit> --max-credits 20` per unit, and `prop-candidates <prop> --max-credits 10` per prop.
3. **Candidate sheets (free).** `make art-candidates UNIT=<unit>` and `make art-prop-candidates PROP=<prop>`, plus large views like A1's `candidates-large.png`. The controller describes each candidate. **Gate 1:** Tim picks a body per unit and a prop per prop.
4. **Builds (paid; Tim).** `build <unit> --pick N --max-credits <estimate>`, with the estimate from `plan`, and `prop-build <prop> --pick N --max-credits 10`.
5. **Attach (free; controller).** Solve offsets and rotations from the meshes, as in A1:
   - a hand grip for blades;
   - a centre grip for bows and staffs;
   - a strapped back plane for a satchel or shield.
   
   Render the plausible variants, pick by eye, write them into `[[attach]]`, and check with `make art-attach UNIT=<unit>`.
6. **Render and build (free).** `make art-render UNIT=<unit>` (no clipped frames; the extents in range) and `make art-build UNIT=<unit>`. **Gate 2:** a review page with every clip's GIF and the contact sheet, for Tim's approval.
7. **Commit.** Commit the art (LFS checked) with `LICENSES.md` rows, then `make test` and `make test-art`.

**Credits.** Check each `plan` estimate against these numbers:
- **Per unit:** 20 (4 Lite) + 10 refine + 5 rig + 3 per action.
- **Per prop:** 10 + 10.

The key's monthly cap must cover the batch, so Tim raises it before the batch's first paid command.

### Task 6: Batch 1 — Reaver and Longbow (~134 credits)

**Files:**
- Create: `art-src/units/reaver/spec.toml`, `art-src/units/longbow/spec.toml`, `art-src/props/claymore/spec.toml`, `art-src/props/longbow_bow/spec.toml`
- Then: their art under `art-src/` and `assets/units/{reaver,longbow}/`, `data/art/{reaver,longbow}.tres`, `data/art/catalog.tres`, `assets/LICENSES.md`

`art-src/units/reaver/spec.toml`:

```toml
# The Reaver's art recipe (spec §5, §11). Shock melee: bare-chested berserker.
id = "reaver"
faction = "light"
height_m = 1.85
prompt = "Scottish highland berserker, bare-chested and heavily muscled, blue woad swirl tattoos across chest and arms, wild mane of copper-red hair and a braided beard, kilt in dark red and green tartan held by a wide studded leather belt, leather bracers, fur-trimmed leather boots, battle scars, empty hands"
die_falls_forward = false

# Held gear (spec §6.2a); offsets and rotations solved from the meshes, then tuned with make art-attach.
[[attach]]
prop = "claymore"
bone = "RightHand"

[candidates]
lite = 4
full = 0
polycount = 30000

[animations.idle]
action = 89
clip = "Combat_Stance"

[animations.walk]
rig = "run"

[animations.attack]
action = 237
clip = "Charged_Axe_Chop"
impact = 0.5

[animations.attack_alt]
action = 128
clip = "Heavy_Hammer_Swing"
impact = 0.5
audition = true

[animations.die]
action = 183
clip = "Shot_and_Fall_Backward"
```

`art-src/units/longbow/spec.toml`:

```toml
# The Longbow's art recipe (spec §5, §11). Archer; the dagger in melee is too small to model.
id = "longbow"
faction = "light"
height_m = 1.78
prompt = "Scottish highland archer and gamekeeper, hooded cloak in muted green and brown hunting tartan, leather jerkin over a linen shirt, kilt, quiver of arrows on the back, hunting knife at the belt, short beard, weathered calm face, soft leather boots, empty hands"
die_falls_forward = true

[[attach]]
prop = "longbow_bow"
bone = "LeftHand"

[candidates]
lite = 4
full = 0
polycount = 30000

[animations.idle]
action = 0
clip = "Idle"

[animations.walk]
rig = "walk"

[animations.shoot]
action = 224
clip = "Archery_Shot"
impact = 0.55

[animations.attack]
action = 97
clip = "Left_Slash"
impact = 0.45

[animations.die]
action = 184
clip = "Shot_and_Fall_Forward"
```

`art-src/props/claymore/spec.toml`:

```toml
# The Reaver's two-handed sword (spec §6.2a, §11).
id = "claymore"
faction = "light"
length_m = 1.35
prompt = "Scottish two-handed claymore greatsword, long straight double-edged steel blade, cross-guard with downward-angled arms ending in quatrefoils, long leather-wrapped grip, round wheel pommel"

[candidates]
lite = 2
full = 0
polycount = 6000
```

`art-src/props/longbow_bow/spec.toml`:

```toml
# The Longbow's bow (spec §6.2a, §11).
id = "longbow_bow"
faction = "light"
length_m = 1.75
prompt = "Tall wooden longbow, a single gently curved stave of yew with a leather-wrapped handgrip in the middle, taut bowstring, plain and sturdy"

[candidates]
lite = 2
full = 0
polycount = 6000
```

- [ ] **Step 1: Write the four recipes, check them, commit.** `plan reaver`, `plan longbow`, `prop-plan claymore` and `prop-plan longbow_bow` should show about 47 + 47 credits for the units and 20 + 20 for the props. `make test-art` must pass (the real-recipe tests load every recipe). Commit with message `Add batch 1 recipes: Reaver and Longbow` and a why-body.
- [ ] **Step 2: Tim buys the candidates.** Before this, Tim checks the key's monthly cap covers about 135 credits.

```
cd ~/Projects/ashenmarch-a3
python3 scripts/art/meshy.py candidates reaver --max-credits 20
python3 scripts/art/meshy.py candidates longbow --max-credits 20
python3 scripts/art/meshy.py prop-candidates claymore --max-credits 10
python3 scripts/art/meshy.py prop-candidates longbow_bow --max-credits 10
```

- [ ] **Step 3: Render the candidate sheets and large views, and describe each candidate.** **Gate 1:** Tim picks.
- [ ] **Step 4: Tim builds the picks:** `build reaver --pick N --max-credits 30`, `build longbow --pick N --max-credits 30`, `prop-build claymore --pick N --max-credits 10`, `prop-build longbow_bow --pick N --max-credits 10`.
- [ ] **Step 5: Solve the attachments.**
  - Claymore: a hand grip, like A1's broadsword.
  - Bow: a centre grip in the left hand, the stave upright.
  
  Write the result into `[[attach]]`, check with `make art-attach`, and commit the recipe.
- [ ] **Step 6: Render and build.** `make art-render` and `make art-build` for both units: no clipped frames, a `figure_height_m` recorded, the `attack_alt` audition in review only. **Gate 2:** the review page for Tim.
- [ ] **Step 7: Commit the art.** Check LFS, add `LICENSES.md` rows (as the Shieldman's), and run `make test` and `make test-art`.

### Task 7: Batch 2 — Sapper and Warden (~140 credits)

**Files:**
- Create: `art-src/units/sapper/spec.toml`, `art-src/units/warden/spec.toml`, `art-src/props/satchel/spec.toml`, `art-src/props/warden_staff/spec.toml`
- Then: their art, as in Task 6

`art-src/units/sapper/spec.toml`:

```toml
# The Sapper's art recipe (spec §5, §11). Grenadier: bottles thrown, satchels placed.
id = "sapper"
faction = "light"
height_m = 1.72
prompt = "Scottish highland tinkerer and grenadier, stocky, singed eyebrows and soot-smudged face, bushy sideburns, leather apron over a rolled-sleeve shirt, kilt, thick leather gloves, brass goggles pushed up on a woollen cap, bandolier of corked glass bottles across the chest, sturdy boots, empty hands"
die_falls_forward = true

[[attach]]
prop = "satchel"
bone = "Hips"

[candidates]
lite = 4
full = 0
polycount = 30000

[animations.idle]
action = 0
clip = "Idle"

[animations.walk]
rig = "walk"

[animations.throw]
action = 239
clip = "Crouch_Pull_and_Throw"
impact = 0.6

[animations.throw_alt]
action = 421
clip = "Over_Shoulder_Throw"
impact = 0.55
audition = true

[animations.place]
action = 274
clip = "Female_Crouch_Pick_Up_Place_Side"
impact = 0.5

[animations.attack]
action = 97
clip = "Left_Slash"
impact = 0.45

[animations.die]
action = 8
clip = "Dead"
```

`art-src/units/warden/spec.toml`:

```toml
# The Warden's art recipe (spec §5, §11). Healer-fighter: the clan's herb-wife.
id = "warden"
faction = "light"
height_m = 1.7
prompt = "Scottish highland herb-wife and healer, stern middle-aged woman, grey-streaked braided hair, woollen shawl in muted blue and green tartan over a long dark dress, leather belt hung with herb pouches and bundles of dried herbs, sturdy boots, empty hands"
die_falls_forward = false

[[attach]]
prop = "warden_staff"
bone = "RightHand"

[candidates]
lite = 4
full = 0
polycount = 30000

[animations.idle]
action = 0
clip = "Idle"

[animations.walk]
rig = "walk"

[animations.attack]
action = 219
clip = "Right_Hand_Sword_Slash"
impact = 0.45

# The heal. Meshy's library spells it "mage_soell_cast" (unverified letter by
# letter); a wrong name fails at the free render, never at purchase.
[animations.cast]
action = 129
clip = "mage_soell_cast"
impact = 0.5

[animations.die]
action = 189
clip = "dying_backwards"
```

`art-src/props/satchel/spec.toml`:

```toml
# The Sapper's satchel, worn at the hip (spec §6.2a, §11).
id = "satchel"
faction = "light"
length_m = 0.45
prompt = "Leather satchel bag bulging with corked glass bottles, brass buckle, short shoulder strap, worn and singed leather"

[candidates]
lite = 2
full = 0
polycount = 6000
```

`art-src/props/warden_staff/spec.toml`:

```toml
# The Warden's staff (spec §6.2a, §11).
id = "warden_staff"
faction = "light"
length_m = 1.7
prompt = "Gnarled wooden walking staff of rowan wood, knotted head wrapped in leather and tied with sprigs of heather, iron ferrule at the foot"

[candidates]
lite = 2
full = 0
polycount = 6000
```

- [ ] **Steps 1–7:** as in Task 6's runbook.
  - Candidates: `candidates sapper`, `candidates warden` (20 each); `prop-candidates satchel`, `prop-candidates warden_staff` (10 each).
  - Builds: Sapper about 33 credits (6 actions), Warden about 27.
  - Attach: the satchel is a back plane against the hip, offset to the right side; the staff takes a centre grip.

### Task 8: Batch 3 — Husk, Ripper and Blightbag (~144 credits)

**Files:**
- Create: `art-src/units/{husk,ripper,blightbag}/spec.toml`
- Then: their art (no props)

`art-src/units/husk/spec.toml`:

```toml
# The Husk's art recipe (spec §5, §11). Base undead melee.
id = "husk"
faction = "dark"
height_m = 1.75
prompt = "Shambling undead corpse wrapped in rotted peat-bog cloth and sacking, leathery dark brown skin shrunken over bones, sunken eye sockets, matted hair, torn rags, bare bony feet, hunched posture, empty clawed hands"
die_falls_forward = false

[candidates]
lite = 4
full = 0
polycount = 30000

[animations.idle]
action = 0
clip = "Idle"

[animations.walk]
action = 123
clip = "Unsteady_Walk"

[animations.attack]
action = 198
clip = "Punch_Combo"
impact = 0.4

[animations.die]
action = 187
clip = "Knock_Down"
```

`art-src/units/ripper/spec.toml`:

```toml
# The Ripper's art recipe (spec §5, §11). Fast raider that picks up and throws.
id = "ripper"
faction = "dark"
height_m = 1.8
prompt = "Gaunt hunched ghoul, emaciated grey-green skin stretched over ribs, long thin limbs, elongated clawed fingers, lank black hair, torn loincloth, bare feet, feral stance, empty hands"
die_falls_forward = false

[candidates]
lite = 4
full = 0
polycount = 30000

[animations.idle]
action = 0
clip = "Idle"

[animations.walk]
action = 16
clip = "RunFast"

[animations.attack]
action = 192
clip = "Right_Jab_from_Guard"
impact = 0.4

[animations.throw]
action = 421
clip = "Over_Shoulder_Throw"
impact = 0.55

# The pick-up of a charge or object, played as the act clip.
[animations.place]
action = 276
clip = "Male_Bend_Over_Pick_Up"
impact = 0.5

[animations.die]
action = 182
clip = "Shot_and_Blown_Back"
```

`art-src/units/blightbag/spec.toml`:

```toml
# The Blightbag's art recipe (spec §5, §11). Walking bomb; bursts into gibs, so it has
# no death clip. Designed humanoid (clear limbs) so Meshy can rig it (Tim, 2026-10-08).
id = "blightbag"
faction = "dark"
height_m = 1.8
prompt = "Bloated undead corpse standing upright, swollen pale green-grey body with large translucent gas sacs bulging from the torso and back, clearly separate arms and legs, ragged burial cloth, faint sickly glow inside the sacs, empty hands"
bursts_on_death = true

[candidates]
lite = 4
full = 0
polycount = 30000

[animations.idle]
action = 0
clip = "Idle"

[animations.walk]
action = 119
clip = "Slow_Orc_Walk"

[animations.attack]
action = 255
clip = "Angry_Ground_Stomp"
impact = 0.6
```

- [ ] **Steps 1–7:** as in Task 6's runbook, without props.
  - Builds: Husk about 27 credits, Ripper about 33, Blightbag about 24.
  - **If the Blightbag's rig task fails,** stop and show Tim the candidate. The fix is a more humanoid prompt plus new candidates (20 credits). Tim's ruling was to redesign it, not to use Mixamo.

### Task 9: Batch 4 — Drifter and Stormcaller (~128 credits)

**Files:**
- Create: `art-src/units/{drifter,stormcaller}/spec.toml`, `art-src/props/{drifter_bow,storm_staff}/spec.toml`
- Then: their art

`art-src/units/drifter/spec.toml`:

```toml
# The Drifter's art recipe (spec §5, §11). Floating undead archer: long robes, a hover bob,
# and a glide that reuses the idle clip with a fixed stride (no foot contact to measure).
id = "drifter"
faction = "dark"
height_m = 1.85
prompt = "Hooded spectre in long tattered grey-black robes reaching the ankles, thin legs barely visible beneath, gaunt bone-white face in shadow under the hood, thin bony hands, faint sickly green glow under the hood, empty hands"
die_falls_forward = false

[[attach]]
prop = "drifter_bow"
bone = "LeftHand"

[candidates]
lite = 4
full = 0
polycount = 30000

[animations.idle]
action = 0
clip = "Idle"
bob_m = 0.08
bob_hz = 0.8

[animations.walk]
action = 0
clip = "Idle"
bob_m = 0.08
bob_hz = 1.2
stride_m = 1.2

[animations.shoot]
action = 224
clip = "Archery_Shot"
impact = 0.55

[animations.die]
action = 8
clip = "Dead"
```

`art-src/units/stormcaller/spec.toml`:

```toml
# The Stormcaller's art recipe (spec §5, §11). Lightning caster.
id = "stormcaller"
faction = "dark"
height_m = 1.85
prompt = "Gaunt undead sorcerer, tall and thin, cracked grey skin marked with glowing blue-white lightning scars, tattered dark hooded mantle with a high collar, rune-marked cloth wrappings, bony hands, wild white hair, empty hands"
die_falls_forward = false

[[attach]]
prop = "storm_staff"
bone = "RightHand"

[candidates]
lite = 4
full = 0
polycount = 30000

[animations.idle]
action = 0
clip = "Idle"

[animations.walk]
rig = "walk"

# The lightning. Meshy's library spells it "mage_soell_cast_2" (unverified letter
# by letter); a wrong name fails at the free render, never at purchase.
[animations.cast]
action = 131
clip = "mage_soell_cast_2"
impact = 0.55

[animations.die]
action = 181
clip = "Electrocuted_Fall"
```

`art-src/props/drifter_bow/spec.toml`:

```toml
# The Drifter's bow (spec §6.2a, §11).
id = "drifter_bow"
faction = "dark"
length_m = 1.3
prompt = "Dark recurve bow of warped black wood bound with pale sinew, tattered cloth wrapped at the grip, frayed bowstring"

[candidates]
lite = 2
full = 0
polycount = 6000
```

`art-src/props/storm_staff/spec.toml`:

```toml
# The Stormcaller's staff (spec §6.2a, §11).
id = "storm_staff"
faction = "dark"
length_m = 1.9
prompt = "Crooked staff of scorched dark wood bound with iron rings, topped with a forked iron crown holding a cracked crystal glowing blue"

[candidates]
lite = 2
full = 0
polycount = 6000
```

- [ ] **Steps 1–7:** as in Task 6's runbook.
  - Builds: Drifter about 24 credits, Stormcaller about 24.
  - Attach: both take a centre grip.
  - **If the Drifter's robes stop it rigging,** stop and show Tim. The fix is a prompt with the robes split at the front over clearly defined legs.

### Task 10: Docs and the PR

**Files:**
- Modify: `docs/architecture.md` (the Unit art section: §11's pipeline changes, a roster line, and the A3 lessons)
- Modify: `docs/prompts.md` (the A3 prompt: art only; voices moved to A2)

- [ ] **Step 1: Update the docs.** Write one or two lines per change, matching the existing style.
- [ ] **Step 2: Run the suites.** `make test`, `make test-art`, `make check-leaks` and `bash scripts/check_asset_layout.sh` all pass.
- [ ] **Step 3: Commit** with a message like `Document the A3 roster and its pipeline changes`.
- [ ] **Step 4: Final whole-branch review,** then the PR. Tim runs the push and `gh pr create --base main` (his hook blocks commands that name `main`). The PR's body lists credits spent per batch.
