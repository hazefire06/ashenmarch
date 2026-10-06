"""Blender test for render_sprites.py, on generated fixture characters.

    make test-art     (or: $BLENDER -b --factory-startup --python-exit-code 1
                       --python scripts/art/blender_test_render.py)

The fixture is a grey 0.5 x 0.3 x 1.8 m block with a red "nose" on its
chest, facing -Y (glTF +Z, like Meshy's characters), skinned to a root bone,
Hips. A second bone, Hand, sticks out sideways (+X) from the chest; no mesh
follows it, but props attach to it. Its clips:
- walk: carries it 1.2 m forward in one second with a small bob, while the
  hand drops 0.6 m and turns 90 degrees about its own Z;
- idle: holds still;
- rise: lifts it 1 m over 30 rendered frames, so its sheet wraps;
- in place, over 1 s (in_place) or 2 s (in_place_slow): the root stays put
  while two foot boxes, on LeftFoot and RightFoot, take turns sliding
  backward while planted, one 1.2 m stride per cycle (the way Meshy's rig
  walk plays).
The prop, "stick", is a blue 0.6 x 0.2 x 0.2 m box, long along its own X,
whose recipe sizes it to 0.9 m. Everything goes through the real glTF
export and import, then the renderer, with Workbench's flat lighting so the
colours are exact.
"""
from __future__ import annotations

import contextlib
import io
import math
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

import bmesh
import bpy
import numpy as np
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Euler, Matrix, Quaternion, Vector

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import render_sprites as rs  # noqa: E402

STRIDE_M = 1.2
HAND_HEAD = (0.25, 0.0, 1.3)
# Hand's own axes in world space, as built and as imported: X is world -Y, Y (along the bone) is world +X, Z is world +Z.
HAND_AXES = Matrix(((0.0, 1.0, 0.0), (-1.0, 0.0, 0.0), (0.0, 0.0, 1.0)))
HAND_DROP_M = 0.6
HAND_TURN_DEG = 90.0
RISE_M = 1.0
RISE_SPAN = 58   # scene frames at 24 fps: 29 steps at 12 fps, so 30 rendered frames (it doesn't loop)
STICK_SIZE = (0.6, 0.2, 0.2)
STICK_CENTRE = (0.3, -0.2, 0.5)  # off the origin, so the centring is tested
STICK_M = 0.9
# In Hand's axes: 0.1 m toward direction 4's camera (X), 0.6 m further out (Y) and 0.45 m up (Z), which centres the
# stick at (0.85, -0.1, 1.75). All three angles are set, so the XYZ order matters: they tip the stick's long axis (its
# X) 30 degrees below level along world +X and roll it 20 degrees about itself. Its top reaches about 2.14 m, over the
# 1.8 m head, so a fit that counted it would shrink the body by about 11 px.
STICK_OFFSET = (0.1, 0.6, 0.45)
STICK_ROTATION = (20.0, 30.0, 90.0)
ELEVATION = math.radians(rs.ELEVATION_DEG)

HEAD = """id = "fixture"
faction = "light"
height_m = {height}
prompt = "test fixture"
"""
IDLE = """
[animations.idle]
file = "anims/idle.glb"
"""
WALK = """
[animations.walk]
file = "anims/walk.glb"
"""
RUN = """
[animations.run]
file = "anims/run.glb"
"""
RISE = """
[animations.rise]
file = "anims/rise.glb"
"""
ATTACK = """
[animations.attack]
file = "anims/idle.glb"
impact = 0.5
"""
STICK_SPEC = """id = "stick"
faction = "light"
length_m = 0.9
prompt = "test stick"
"""
EXTENTS = re.compile(r"extents (\w+): lowest (-?[\d.]+) above the bottom, highest (-?[\d.]+), half-width (-?[\d.]+) \(cell (\d+)\)")


def attach_toml(bone: str) -> str:
    """The unit's [[attach]] table for the stick, from STICK_OFFSET and STICK_ROTATION."""
    return (f'\n[[attach]]\nprop = "stick"\nbone = "{bone}"\n'
            f"offset = [{', '.join(map(str, STICK_OFFSET))}]\nrotation = [{', '.join(map(str, STICK_ROTATION))}]\n")


def fixture_spec(*parts: str, height: float = 1.8, bone: str = "Hand", attach: bool = False) -> str:
    return HEAD.format(height=height) + (attach_toml(bone) if attach else "") + "".join(parts)


def make_material(name: str, rgba: tuple[float, float, float, float]) -> bpy.types.Material:
    mat = bpy.data.materials.new(name)
    if mat.node_tree is None:
        mat.use_nodes = True
    bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = rgba
    mat.diffuse_color = rgba
    return mat


def add_box(bm: bmesh.types.BMesh, center: tuple[float, float, float], size: tuple[float, float, float], material: int) -> list[int]:
    """Adds a box and returns its vertex indices."""
    verts = bmesh.ops.create_cube(bm, size=1.0)["verts"]
    for v in verts:
        v.co = Vector((v.co.x * size[0] + center[0], v.co.y * size[1] + center[1], v.co.z * size[2] + center[2]))
    for face in {f for v in verts for f in v.link_faces}:
        face.material_index = material
    bm.verts.index_update()
    return [v.index for v in verts]


def foot_path(phase: float) -> Vector:
    """A foot's offset from rest over one cycle: planted for the first half,
    sliding backward (+Y, the unit faces -Y) by half a stride, then swung
    forward through the air. The ground covers one stride, STRIDE_M, per
    cycle, however long the cycle lasts."""
    if phase < 0.5:
        return Vector((0.0, STRIDE_M * (phase - 0.25), 0.0))
    u = (phase - 0.5) / 0.5
    return Vector((0.0, STRIDE_M * (0.25 - 0.5 * u), 0.12 * math.sin(math.pi * u)))


def build_fixture(path: Path, clip: str, parented: bool = False) -> None:
    """Writes the fixture GLB with one clip: idle, walk, rise, in_place (1 s) or in_place_slow (2 s).

    With parented, the armature hangs under an Empty scaled 0.01 and is
    itself scaled 100 (net identity), the way some exporters hand over a
    centimetre-unit rig; the importer keeps that hierarchy. The Empty also
    sits 0.3 m up, so the renderer has feet to drop back to the ground."""
    rs.reset_scene()
    scene = bpy.context.scene
    arm_data = bpy.data.armatures.new("Rig")
    arm = bpy.data.objects.new("Rig", arm_data)
    scene.collection.objects.link(arm)
    if parented:
        top = bpy.data.objects.new("Top", None)
        top.scale = (0.01, 0.01, 0.01)
        top.location = (0.0, 0.0, 0.3)
        scene.collection.objects.link(top)
        arm.parent = top
        arm.scale = (100.0, 100.0, 100.0)
    feet = {"LeftFoot": 0.15, "RightFoot": -0.15} if clip.startswith("in_place") else {}
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    hips = arm_data.edit_bones.new("Hips")
    hips.head = (0.0, 0.0, 0.9)
    hips.tail = (0.0, 0.0, 1.4)
    hand = arm_data.edit_bones.new("Hand")
    hand.head = HAND_HEAD
    hand.tail = (HAND_HEAD[0] + 0.3, HAND_HEAD[1], HAND_HEAD[2])
    hand.parent = hips
    for name, x in feet.items():
        foot = arm_data.edit_bones.new(name)
        foot.head = (x, 0.0, 0.05)
        foot.tail = (x, 0.0, 0.25)
        foot.parent = hips
    bpy.ops.object.mode_set(mode="OBJECT")

    mesh = bpy.data.meshes.new("Body")
    bm = bmesh.new()
    groups = {"Hips": add_box(bm, (0.0, 0.0, 0.9), (0.5, 0.3, 1.8), 0) + add_box(bm, (0.0, -0.25, 1.0), (0.2, 0.2, 0.2), 1)}
    for name, x in feet.items():
        groups[name] = add_box(bm, (x, 0.0, 0.05), (0.12, 0.25, 0.1), 0)
    bm.to_mesh(mesh)
    bm.free()
    mesh.materials.append(make_material("Grey", (0.5, 0.5, 0.5, 1.0)))
    mesh.materials.append(make_material("Red", (1.0, 0.0, 0.0, 1.0)))
    body = bpy.data.objects.new("Body", mesh)
    scene.collection.objects.link(body)
    body.parent = arm
    for name, indices in groups.items():
        body.vertex_groups.new(name=name).add(indices, 1.0, "REPLACE")
    body.modifiers.new("Armature", "ARMATURE").object = arm

    def key(bone: str, frame: int, world_delta: Vector) -> None:
        pose = arm.pose.bones[bone]
        pose.location = arm_data.bones[bone].matrix_local.to_3x3().inverted() @ world_delta
        pose.keyframe_insert("location", frame=frame)

    def turn(bone: str, frame: int, degrees: float) -> None:
        pose = arm.pose.bones[bone]
        pose.rotation_quaternion = Quaternion((0.0, 0.0, 1.0), math.radians(degrees))  # about the bone's own Z
        pose.keyframe_insert("rotation_quaternion", frame=frame)

    span = {"idle": 1, "walk": 24, "rise": RISE_SPAN, "in_place": 24, "in_place_slow": 48}[clip]
    for frame in range(1, span + 2):
        t = (frame - 1) / span
        if clip == "walk":
            key("Hips", frame, Vector((0.0, -STRIDE_M * t, 0.05 * math.sin(4.0 * math.pi * t))))
            key("Hand", frame, Vector((0.0, 0.0, -HAND_DROP_M * t)))
            turn("Hand", frame, HAND_TURN_DEG * t)
        elif clip == "rise":
            key("Hips", frame, Vector((0.0, 0.0, RISE_M * t)))
        else:
            key("Hips", frame, Vector())
        for name in feet:
            key(name, frame, foot_path(t if name == "LeftFoot" else (t + 0.5) % 1.0))
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB", export_animations=True)


def build_stick(path: Path) -> None:
    """The prop: a blue STICK_SIZE box, long along its own X, centred off its origin."""
    rs.reset_scene()
    mesh = bpy.data.meshes.new("Stick")
    bm = bmesh.new()
    add_box(bm, STICK_CENTRE, STICK_SIZE, 0)
    bm.to_mesh(mesh)
    bm.free()
    mesh.materials.append(make_material("Blue", (0.0, 0.0, 1.0, 1.0)))
    stick = bpy.data.objects.new("Stick", mesh)
    bpy.context.scene.collection.objects.link(stick)
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB")


def make_unit(root: Path, spec: str, clips: dict[str, str], parented: bool = False, stick: bool = False) -> Path:
    """Writes art-src/units/fixture (spec plus one GLB per clip, named <name>.glb) and, with stick, art-src/props/stick."""
    unit_dir = root / "art-src" / "units" / "fixture"
    (unit_dir / "anims").mkdir(parents=True)
    (unit_dir / "spec.toml").write_text(spec, encoding="utf-8")
    for name, clip in clips.items():
        build_fixture(unit_dir / "anims" / f"{name}.glb", clip, parented)
    if stick:
        prop_dir = root / "art-src" / "props" / "stick"
        prop_dir.mkdir(parents=True)
        (prop_dir / "spec.toml").write_text(STICK_SPEC, encoding="utf-8")
        build_stick(prop_dir / "model" / "textured.glb")
    return unit_dir


def render(root: Path) -> tuple[Path, dict, str]:
    """Renders the fixture under root; returns (out_dir, sidecar, what it printed)."""
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        sidecar = rs.render_unit("fixture", root / "art-src", root / "assets" / "units", engine="WORKBENCH")
    print(printed.getvalue(), end="")
    return root / "assets" / "units" / "fixture", sidecar, printed.getvalue()


def at(sheet: np.ndarray, row: int, column: int, size: int = rs.CELL) -> np.ndarray:
    """One cell of a sheet read by rs.read_rgba (row 0 is the bottom of the image), by grid position from the top left."""
    stride = size + 2 * rs.GUTTER
    top = sheet.shape[0] - row * stride - rs.GUTTER
    left = column * stride + rs.GUTTER
    return sheet[top - size:top, left:left + size]


def cell(sheet: np.ndarray, frame: int, direction: int, info: dict | None = None) -> np.ndarray:
    """Frame `frame` of direction `direction`, laid out as the sidecar entry `info` says (one row per direction without it)."""
    columns = info["columns"] if info else sheet.shape[1] // rs.STRIDE
    rows = info["rows_per_direction"] if info else 1
    return at(sheet, direction * rows + frame // columns, frame % columns)


def red_mask(px: np.ndarray) -> np.ndarray:
    return (px[..., 0] > 0.8) & (px[..., 1] < 0.3) & (px[..., 2] < 0.3) & (px[..., 3] > 0.5)


def blue_mask(px: np.ndarray) -> np.ndarray:
    return (px[..., 2] > 0.8) & (px[..., 0] < 0.3) & (px[..., 1] < 0.3) & (px[..., 3] > 0.5)


def grey_mask(px: np.ndarray) -> np.ndarray:
    return (np.abs(px[..., 0] - px[..., 1]) < 0.1) & (px[..., 0] > 0.2) & (px[..., 0] < 0.9) & (px[..., 3] > 0.5)


def mean_x(mask: np.ndarray) -> float:
    return float(np.nonzero(mask)[1].mean())


def mean_y(mask: np.ndarray) -> float:
    return float(np.nonzero(mask)[0].mean())


def rows_of(mask: np.ndarray) -> tuple[int, int]:
    """Lowest and highest row holding the mask (row 0 is the bottom)."""
    rows = np.nonzero(mask.any(axis=1))[0]
    return int(rows.min()), int(rows.max())


def columns_of(mask: np.ndarray) -> tuple[int, int]:
    columns = np.nonzero(mask.any(axis=0))[0]
    return int(columns.min()), int(columns.max())


def opaque(px: np.ndarray) -> np.ndarray:
    return px[..., 3] > 0.5


def mask_box(mask: np.ndarray) -> tuple[float, float, float, float]:
    """Left, right, bottom and top edges of a mask in px; right and top are one past its last pixel."""
    (left, right), (bottom, top) = columns_of(mask), rows_of(mask)
    return float(left), float(right + 1), float(bottom), float(top + 1)


def alpha_centroid_y(px: np.ndarray) -> float:
    """The alpha-weighted mean row (row 0 is the bottom). It's sub-pixel, so it tracks a shape that moves by a fraction of a pixel."""
    alpha = px[..., 3]
    return float((alpha.sum(axis=1) * np.arange(px.shape[0])).sum() / alpha.sum())


def stick_corners(head: tuple[float, float, float], turn_deg: float = 0.0) -> np.ndarray:
    """World corners (8, 3) of the attached stick, worked out from the fixture's geometry alone.

    Hand's head is at head, and Hand has turned turn_deg about its own Z. The
    stick is scaled so its longest side is STICK_M, turned by the XYZ Euler
    rotation, and centred at the head plus the offset, all in Hand's axes."""
    axes = HAND_AXES @ Matrix.Rotation(math.radians(turn_deg), 3, "Z")
    rotation = Euler([math.radians(a) for a in STICK_ROTATION], "XYZ").to_matrix()
    half = Vector(STICK_SIZE) * (STICK_M / max(STICK_SIZE) / 2)
    centre = Vector(head) + axes @ Vector(STICK_OFFSET)
    return np.array([tuple(centre + axes @ rotation @ Vector((x * half.x, y * half.y, z * half.z)))
                     for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)])


def box_px(corners: np.ndarray, direction: int) -> tuple[float, float, float, float]:
    """Left, right, bottom and top of world corners projected into a game cell (rs.project matches Blender's camera; see ProjectionTest)."""
    x, y = rs.project(corners, direction)
    return float(x.min()), float(x.max()), float(y.min()), float(y.max())


def extents(printed: str) -> dict[str, tuple[float, float, float, int]]:
    return {m[1]: (float(m[2]), float(m[3]), float(m[4]), int(m[5])) for m in EXTENTS.finditer(printed)}


def body_rows_in_front_view() -> tuple[float, float]:
    """Where the fixture's 0.5 x 0.3 x 1.8 m body lands in direction 4, in px from the bottom: its near bottom edge and far top edge."""
    return (rs.FEET_PX - 0.15 * math.sin(ELEVATION) * rs.PIXELS_PER_METER,
            rs.FEET_PX + (1.8 * math.cos(ELEVATION) + 0.15 * math.sin(ELEVATION)) * rs.PIXELS_PER_METER)


class RenderSpritesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._tmp = tempfile.TemporaryDirectory()
        root = Path(cls._tmp.name)
        cls.unit_dir = make_unit(root, fixture_spec(IDLE, WALK, RISE), {"idle": "idle", "walk": "walk", "rise": "rise"})
        cls.out, cls.sidecar, cls.printed = render(root)
        cls.walk = rs.read_rgba(cls.out / "walk.png")
        cls.idle = rs.read_rgba(cls.out / "idle.png")
        cls.rise = rs.read_rgba(cls.out / "rise.png")

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmp.cleanup()

    def test_walk_is_one_second_of_looping_frames(self) -> None:
        walk = self.sidecar["animations"]["walk"]
        self.assertEqual((walk["frames"], walk["fps"], walk["loop"]), (12, 12, True))
        self.assertEqual(self.sidecar["animations"]["idle"]["frames"], 1)

    def test_cell_pivot_and_stride(self) -> None:
        self.assertEqual((self.sidecar["cell"], self.sidecar["feet_px"], self.sidecar["stride"]), (160, 40, 168))

    def test_sheet_layout_and_import_settings(self) -> None:
        walk = self.sidecar["animations"]["walk"]
        self.assertEqual((walk["columns"], walk["rows_per_direction"]), (12, 1))
        self.assertEqual(self.walk.shape[:2], (8 * rs.STRIDE, 12 * rs.STRIDE))
        settings = (self.out / "walk.png.import").read_text(encoding="utf-8")
        self.assertIn("mipmaps/generate=true", settings)

    def test_a_long_animation_wraps_at_4096_px(self) -> None:
        rise = self.sidecar["animations"]["rise"]
        self.assertEqual((rise["frames"], rise["columns"], rise["rows_per_direction"]), (30, 24, 2))
        self.assertEqual(self.rise.shape[:2], (8 * 2 * rs.STRIDE, 24 * rs.STRIDE))
        self.assertLessEqual(self.rise.shape[1], rs.MAX_SHEET_PX)

    def test_frames_past_the_last_column_continue_on_the_next_row(self) -> None:
        # The body rises 1.15 px a frame. Every frame, read where the layout puts it, must stand at its own height to
        # well within half a frame's rise, so no frame (24 on the next row included) can stand in for its neighbour.
        rise = self.sidecar["animations"]["rise"]
        per_frame = RISE_M / 29 * math.cos(ELEVATION) * rs.PIXELS_PER_METER
        for d in range(rs.DIRECTIONS):
            base = alpha_centroid_y(at(self.rise, 2 * d, 0))
            for frame in range(rise["frames"]):
                height = alpha_centroid_y(cell(self.rise, frame, d, rise)) - base
                self.assertAlmostEqual(height, frame * per_frame, delta=0.4, msg=f"d{d} f{frame}")
            for column in range(6, 24):  # frames 30..47 don't exist: transparent
                self.assertEqual(float(at(self.rise, 2 * d + 1, column)[..., 3].max()), 0.0, column)

    def test_stride_is_measured(self) -> None:
        self.assertAlmostEqual(self.sidecar["animations"]["walk"]["stride_m"], STRIDE_M, delta=0.03)

    def test_root_motion_is_removed(self) -> None:
        xs = [mean_x(cell(self.walk, f, 2)[..., 3] > 0.5) for f in range(12)]
        self.assertLessEqual(max(xs) - min(xs), 2.0, xs)

    def test_direction_convention(self) -> None:
        side_left = cell(self.idle, 0, 2)
        side_right = cell(self.idle, 0, 6)
        self.assertLess(mean_x(red_mask(side_left)), mean_x(grey_mask(side_left)), "dir 2 faces screen-left")
        self.assertGreater(mean_x(red_mask(side_right)), mean_x(grey_mask(side_right)), "dir 6 faces screen-right")
        self.assertGreater(int(red_mask(cell(self.idle, 0, 4)).sum()), 20, "dir 4 shows the front")
        self.assertLessEqual(int(red_mask(cell(self.idle, 0, 0)).sum()), 2, "dir 0 shows the back")

    def test_feet_sit_on_the_pivot(self) -> None:
        rows = np.nonzero((cell(self.idle, 0, 4)[..., 3] > 0.5).any(axis=1))[0]
        self.assertTrue(rs.FEET_PX - 8 <= int(rows.min()) <= rs.FEET_PX, int(rows.min()))

    def test_nothing_is_clipped(self) -> None:
        self.assertEqual(self.sidecar["clipped"], [])

    def test_review_sheets_and_gib_color(self) -> None:
        self.assertTrue((self.unit_dir / "review" / "contact.png").exists())
        self.assertTrue((self.unit_dir / "review" / "walk.gif").exists())
        self.assertTrue((self.unit_dir / "review" / "rise.gif").exists())
        self.assertEqual(len(self.sidecar["gib_color"]), 3)
        self.assertTrue(all(0.0 <= c <= 1.0 for c in self.sidecar["gib_color"]))

    def test_extents_report_matches_the_pixels(self) -> None:
        report = extents(self.printed)
        self.assertEqual(sorted(report), ["idle", "rise", "walk"])
        lowest, highest, half, cell_px = report["idle"]
        self.assertEqual(cell_px, 160)
        low, high, wide = math.inf, -math.inf, 0.0
        for d in range(rs.DIRECTIONS):
            mask = opaque(cell(self.idle, 0, d))
            rows, columns = rows_of(mask), columns_of(mask)
            low, high = min(low, rows[0]), max(high, rows[1] + 1)
            wide = max(wide, rs.CELL / 2 - columns[0], columns[1] + 1 - rs.CELL / 2)
        self.assertAlmostEqual(lowest, low, delta=1.5)
        self.assertAlmostEqual(highest, high, delta=1.5)
        self.assertAlmostEqual(half, wide, delta=1.5)
        self.assertGreater(report["rise"][1], highest + 0.9 * RISE_M * math.cos(ELEVATION) * rs.PIXELS_PER_METER, "worst over all frames")

    def test_extents_are_not_in_the_sidecar(self) -> None:
        self.assertNotIn("extents", self.sidecar["animations"]["idle"])


class ParentedRenderTest(unittest.TestCase):
    """The same fixture with its armature under a scaled parent node. Root
    motion and the feet offset must work in world space, not the armature's
    parent-relative location."""

    @classmethod
    def setUpClass(cls) -> None:
        cls._tmp = tempfile.TemporaryDirectory()
        root = Path(cls._tmp.name)
        make_unit(root, fixture_spec(IDLE, WALK), {"idle": "idle", "walk": "walk"}, parented=True)
        cls.out, cls.sidecar, _ = render(root)
        cls.walk = rs.read_rgba(cls.out / "walk.png")
        cls.idle = rs.read_rgba(cls.out / "idle.png")

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmp.cleanup()

    def test_root_motion_is_removed(self) -> None:
        xs = [mean_x(cell(self.walk, f, 2)[..., 3] > 0.5) for f in range(12)]
        self.assertLessEqual(max(xs) - min(xs), 2.0, xs)

    def test_stride_is_measured(self) -> None:
        self.assertAlmostEqual(self.sidecar["animations"]["walk"]["stride_m"], STRIDE_M, delta=0.03)

    def test_nothing_is_clipped(self) -> None:
        self.assertEqual(self.sidecar["clipped"], [])

    def test_feet_sit_on_the_pivot(self) -> None:
        rows = np.nonzero((cell(self.idle, 0, 4)[..., 3] > 0.5).any(axis=1))[0]
        self.assertTrue(rs.FEET_PX - 8 <= int(rows.min()) <= rs.FEET_PX, int(rows.min()))


class PropRenderTest(unittest.TestCase):
    """The fixture carrying the stick on its Hand bone."""

    @classmethod
    def setUpClass(cls) -> None:
        cls._tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls._tmp.name)
        cls.unit_dir = make_unit(cls.root, fixture_spec(IDLE, WALK, ATTACK, attach=True), {"idle": "idle", "walk": "walk"}, stick=True)
        cls.out, cls.sidecar, cls.printed = render(cls.root)
        cls.idle = rs.read_rgba(cls.out / "idle.png")
        cls.walk = rs.read_rgba(cls.out / "walk.png")
        cls.front = cell(cls.idle, 0, 4)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmp.cleanup()

    def copy_fixture(self, spec: str) -> Path:
        """A second art-src root with the same GLBs and the given unit spec."""
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        shutil.copytree(self.root / "art-src", root / "art-src", ignore=shutil.ignore_patterns("review"))
        (root / "art-src" / "units" / "fixture" / "spec.toml").write_text(spec, encoding="utf-8")
        return root

    def stage(self, root: Path, name: str) -> rs.Staged:
        spec = rs.load_spec(root / "art-src" / "units" / "fixture" / "spec.toml")
        entry = next(e for e in spec.animations if e.name == name)
        props = rs.resolve_props(spec, root / "art-src", root)
        return rs.stage_animation(spec, root / "art-src" / "units" / "fixture" / entry.file, entry, props, "WORKBENCH")

    def assert_stick_at(self, staged: rs.Staged, corners: np.ndarray) -> None:
        """The stick's world bounding box is the one its corners make, to 5 mm."""
        lo, hi = rs.mesh_bounds(staged.prop_meshes)
        for axis in range(3):
            self.assertAlmostEqual(lo[axis], float(corners[:, axis].min()), delta=0.005, msg=f"min {'xyz'[axis]}")
            self.assertAlmostEqual(hi[axis], float(corners[:, axis].max()), delta=0.005, msg=f"max {'xyz'[axis]}")

    def test_prop_is_on_the_hands_side(self) -> None:
        # Hand sticks out along +X, which direction 4 (facing the camera) shows on the right.
        blue = blue_mask(self.front)
        self.assertGreater(int(blue.sum()), 200)
        self.assertGreater(columns_of(blue)[0], columns_of(grey_mask(self.front))[1], "the stick is clear of the body, on the right")

    def test_prop_is_sized_by_its_recipe(self) -> None:
        # Its 0.9 m length, turned as its rotation says, gives this box in direction 4. The longest side is the stick's
        # own X, so sizing by its Z (or by world Z) would come out a third of the length.
        left, right, bottom, top = box_px(stick_corners(HAND_HEAD), 4)
        got = mask_box(blue_mask(self.front))
        self.assertAlmostEqual(got[1] - got[0], right - left, delta=1.5)
        self.assertAlmostEqual(got[3] - got[2], top - bottom, delta=1.5)

    def test_prop_sits_at_the_bone_head_plus_its_offset(self) -> None:
        # Centred at the head (not the tail, about 0.47 m further along), moved by the offset in Hand's axes.
        x, y = rs.project(np.array([tuple(Vector(HAND_HEAD) + HAND_AXES @ Vector(STICK_OFFSET))]), 4)
        blue = blue_mask(self.front)
        self.assertAlmostEqual(mean_x(blue) + 0.5, float(x[0]), delta=1.0)
        self.assertAlmostEqual(mean_y(blue) + 0.5, float(y[0]), delta=1.0)
        for got, want in zip(mask_box(blue), box_px(stick_corners(HAND_HEAD), 4)):
            self.assertAlmostEqual(got, want, delta=1.5)

    def test_fit_ignores_the_prop(self) -> None:
        low, high = body_rows_in_front_view()
        rows = rows_of(grey_mask(self.front))
        self.assertAlmostEqual(rows[0], low, delta=1.0)
        self.assertAlmostEqual(rows[1] + 1, high, delta=1.0)

    def test_prop_follows_the_bone(self) -> None:
        # By mid-walk Hand has dropped 0.3 m and turned 45 degrees about its own Z (the bob is back at zero).
        head = (HAND_HEAD[0], HAND_HEAD[1], HAND_HEAD[2] - HAND_DROP_M / 2)
        for got, want in zip(mask_box(blue_mask(cell(self.walk, 6, 4))), box_px(stick_corners(head, HAND_TURN_DEG / 2), 4)):
            self.assertAlmostEqual(got, want, delta=1.5)

    def test_prop_turns_with_the_bone(self) -> None:
        # In world metres: bound at the walk's first frame, and at its last, where Hand has dropped 0.6 m and turned 90 degrees.
        staged = self.stage(self.root, "walk")
        self.assert_stick_at(staged, stick_corners(HAND_HEAD))
        rs.pose_at(staged, staged.end)
        self.assert_stick_at(staged, stick_corners((HAND_HEAD[0], HAND_HEAD[1], HAND_HEAD[2] - HAND_DROP_M), HAND_TURN_DEG))

    def test_props_count_in_the_extents(self) -> None:
        corners = stick_corners(HAND_HEAD)
        reach = max(float(np.abs(rs.project(corners, d)[0] - rs.CELL / 2).max()) for d in range(rs.DIRECTIONS))
        self.assertAlmostEqual(extents(self.printed)["idle"][2], reach, delta=1.0)

    def test_prop_size_and_offset_ignore_the_fit_scale(self) -> None:
        # A 3.6 m spec doubles the body, Hand's head included, but the stick keeps its 0.9 m and its offset in metres.
        root = self.copy_fixture(fixture_spec(IDLE, height=3.6, attach=True))
        staged = self.stage(root, "idle")
        head = (2 * HAND_HEAD[0], 2 * HAND_HEAD[1], 2 * HAND_HEAD[2])
        armature = staged.armature.evaluated_get(bpy.context.evaluated_depsgraph_get())
        got = armature.matrix_world @ armature.pose.bones["Hand"].head
        self.assertLess((got - Vector(head)).length, 0.01, "the body did double")
        self.assert_stick_at(staged, stick_corners(head))

    def test_unknown_bone_lists_the_rigs_bones(self) -> None:
        root = self.copy_fixture(fixture_spec(IDLE, bone="Elbow", attach=True))
        with self.assertRaises(RuntimeError) as caught:
            rs.render_unit("fixture", root / "art-src", root / "assets" / "units", engine="WORKBENCH")
        self.assertIn("Elbow", str(caught.exception))
        self.assertIn("Hand", str(caught.exception))
        self.assertIn("Hips", str(caught.exception))
        self.assertFalse((root / "assets").exists(), "no empty output folder left behind")
        self.assertFalse((root / "art-src" / "units" / "fixture" / "review").exists(), "no empty review folder left behind")

    def test_missing_prop_model_says_how_to_buy_it(self) -> None:
        root = self.copy_fixture(fixture_spec(IDLE, attach=True))
        (root / "art-src" / "props" / "stick" / "model" / "textured.glb").unlink()
        with self.assertRaises(RuntimeError) as caught:
            rs.render_unit("fixture", root / "art-src", root / "assets" / "units", engine="WORKBENCH")
        self.assertIn("textured.glb", str(caught.exception))
        self.assertIn("meshy.py prop-build stick", str(caught.exception))
        self.assertFalse((root / "assets").exists(), "refused before anything was written")

    def test_attach_preview(self) -> None:
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            dest = rs.render_attach("fixture", self.root / "art-src", engine="WORKBENCH")
        self.assertEqual(dest, self.unit_dir / "review" / "attach.png")
        self.assertIn("Hand", printed.getvalue(), "prints the rig's bones")
        size = 2 * rs.CELL
        sheet = rs.read_rgba(dest)
        # Columns: directions 0, 2, 4, 6. Rows: idle, then attack.
        self.assertEqual(sheet.shape[:2], (2 * (size + 2 * rs.GUTTER), 4 * (size + 2 * rs.GUTTER)))
        expected = [2 * v for v in box_px(stick_corners(HAND_HEAD), 4)]
        for row in (0, 1):
            front = at(sheet, row, 2, size)
            for got, want in zip(mask_box(blue_mask(front)), expected):
                self.assertAlmostEqual(got, want, delta=2.5, msg="twice the px per metre")
            self.assertAlmostEqual(rows_of(grey_mask(front))[0], 2 * body_rows_in_front_view()[0], delta=2.0, msg="same pivot")


class InPlaceWalkTest(unittest.TestCase):
    """A walk (1 s) and a run (2 s) whose roots stay put: the stride comes
    from the feet. Both cover one 1.2 m stride per cycle, the run at half
    the speed, so the clip's length has to count."""

    @classmethod
    def setUpClass(cls) -> None:
        cls._tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls._tmp.name)
        cls.unit_dir = make_unit(cls.root, fixture_spec(WALK, RUN, IDLE), {"walk": "in_place", "run": "in_place_slow", "idle": "idle"})
        _, cls.sidecar, cls.printed = render(cls.root)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmp.cleanup()

    def test_stride_comes_from_the_feet(self) -> None:
        for name in ("walk", "run"):
            self.assertAlmostEqual(self.sidecar["animations"][name]["stride_m"], STRIDE_M, delta=0.15, msg=name)
            self.assertIn(f"stride {name}:", self.printed)

    def test_in_place_walk_without_feet_lists_the_bones(self) -> None:
        # The idle clip as a walk: it doesn't travel, and the rig has no foot bones.
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        shutil.copytree(self.root / "art-src", root / "art-src", ignore=shutil.ignore_patterns("review"))
        (root / "art-src" / "units" / "fixture" / "spec.toml").write_text(fixture_spec('\n[animations.walk]\nfile = "anims/idle.glb"\n'), encoding="utf-8")
        with self.assertRaises(RuntimeError) as caught:
            rs.render_unit("fixture", root / "art-src", root / "assets" / "units", engine="WORKBENCH")
        self.assertIn("foot", str(caught.exception))
        self.assertIn("Hips", str(caught.exception))
        self.assertIn("Hand", str(caught.exception))


class PropCandidatesTest(unittest.TestCase):
    def test_candidate_sheet(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            prop_dir = Path(tmp) / "art-src" / "props" / "stick"
            prop_dir.mkdir(parents=True)
            (prop_dir / "spec.toml").write_text(STICK_SPEC, encoding="utf-8")
            build_stick(prop_dir / "candidates" / "cand-1.glb")
            shutil.copy(prop_dir / "candidates" / "cand-1.glb", prop_dir / "candidates" / "cand-2.glb")
            dest = rs.render_prop_candidates("stick", Path(tmp) / "art-src")
            self.assertEqual(dest, prop_dir / "review" / "candidates.png")
            sheet = rs.read_rgba(dest)
            stride = rs.PROP_CELL + 2 * rs.GUTTER
            self.assertEqual(sheet.shape[:2], (2 * stride, 4 * stride))
            for row in (0, 1):
                for column in range(4):
                    px = at(sheet, row, column, rs.PROP_CELL)
                    self.assertTrue(bool((px[..., 3] > 0.99).all()), "a plain, opaque background")
                    self.assertGreater(float(px[2, 2, :3].min()), 0.8, "a light one")
                    shape = px[..., :3].mean(axis=2) < 0.75
                    self.assertGreater(int(shape.sum()), 500, (row, column))
                    columns, rows = columns_of(shape), rows_of(shape)
                    self.assertTrue(columns[0] > 0 and columns[1] < rs.PROP_CELL - 1 and rows[0] > 0 and rows[1] < rs.PROP_CELL - 1,
                                    "framed to the prop's bounds")


class ProjectionTest(unittest.TestCase):
    def test_projection_matches_blenders_camera(self) -> None:
        rs.reset_scene()
        rs.configure_render("WORKBENCH")
        camera = rs.make_camera()
        points = np.array([(0.0, 0.0, 0.0), (0.3, -0.2, 1.7), (-0.6, 0.4, -0.1), (1.0, 1.0, 2.0)])
        for d in range(rs.DIRECTIONS):
            rs.place_camera(camera, d)
            bpy.context.view_layer.update()
            xs, ys = rs.project(points, d)
            for (x, y), p in zip(zip(xs, ys), points):
                ndc = world_to_camera_view(bpy.context.scene, camera, Vector(p))
                self.assertAlmostEqual(x, ndc.x * rs.CELL, delta=0.01)
                self.assertAlmostEqual(y, ndc.y * rs.CELL, delta=0.01)
        self.assertAlmostEqual(xs[0], rs.CELL / 2, delta=1e-3, msg="the origin is the pivot")
        self.assertAlmostEqual(ys[0], rs.FEET_PX, delta=1e-3, msg="the origin is the pivot")


class PlantedSymlinkTest(unittest.TestCase):
    """A symlink planted where the renderer writes (or reads) is refused before anything is written."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.unit_dir = self.root / "art-src" / "units" / "fixture"
        (self.unit_dir / "anims").mkdir(parents=True)
        (self.unit_dir / "spec.toml").write_text(fixture_spec(IDLE), encoding="utf-8")
        self.elsewhere = self.root / "elsewhere"
        self.elsewhere.mkdir()

    def refused(self, call) -> str:
        with self.assertRaises(RuntimeError) as caught:
            call()
        self.assertEqual(list(self.elsewhere.iterdir()), [], "nothing written through the link")
        return str(caught.exception)

    def render_unit(self) -> None:
        rs.render_unit("fixture", self.root / "art-src", self.root / "assets" / "units", engine="WORKBENCH")

    def test_symlinked_review_is_refused(self) -> None:
        (self.unit_dir / "review").symlink_to(self.elsewhere, target_is_directory=True)
        self.assertIn("symlink", self.refused(self.render_unit))
        self.assertFalse((self.root / "assets").exists())
        self.assertIn("symlink", self.refused(lambda: rs.render_attach("fixture", self.root / "art-src", engine="WORKBENCH")))
        self.assertIn("symlink", self.refused(lambda: rs.render_candidates("fixture", self.root / "art-src", engine="WORKBENCH")))

    def test_dangling_symlinked_review_is_refused(self) -> None:
        (self.unit_dir / "review").symlink_to(self.elsewhere / "gone", target_is_directory=True)
        self.assertIn("symlink", self.refused(self.render_unit))

    def test_symlinked_file_in_the_output_folder_is_refused(self) -> None:
        out = self.root / "assets" / "units" / "fixture"
        out.mkdir(parents=True)
        (out / "idle.png.import").symlink_to(self.elsewhere / "victim")
        self.assertIn("idle.png.import", self.refused(self.render_unit))

    def test_symlinked_output_folder_is_refused(self) -> None:
        (self.root / "assets" / "units").mkdir(parents=True)
        (self.root / "assets" / "units" / "fixture").symlink_to(self.elsewhere, target_is_directory=True)
        self.assertIn("symlink", self.refused(self.render_unit))

    def test_folder_outside_the_repo_is_refused(self) -> None:
        repo = self.root / "repo"
        repo.mkdir()
        message = self.refused(lambda: rs.render_unit("fixture", self.root / "art-src", self.root / "assets" / "units", engine="WORKBENCH", repo=repo))
        self.assertIn("outside", message)

    def test_symlinked_unit_folder_is_refused(self) -> None:
        real = self.root / "real_fixture"
        self.unit_dir.rename(real)
        self.unit_dir.symlink_to(real, target_is_directory=True)
        self.assertIn("symlink", self.refused(self.render_unit))
        self.assertFalse((self.root / "assets").exists())
        self.assertFalse((real / "review").exists())

    def test_symlinked_animation_is_refused(self) -> None:
        (self.unit_dir / "anims" / "idle.glb").symlink_to(self.elsewhere / "victim.glb")
        self.assertIn("idle.glb", self.refused(self.render_unit))
        self.assertFalse((self.root / "assets").exists())

    def test_symlinked_prop_is_refused(self) -> None:
        # Read through render_unit's resolve_props: first a symlinked prop folder, then a symlinked model in a real one.
        (self.unit_dir / "spec.toml").write_text(fixture_spec(IDLE, attach=True), encoding="utf-8")
        real = self.root / "real_stick"
        (real / "model").mkdir(parents=True)
        (real / "spec.toml").write_text(STICK_SPEC, encoding="utf-8")
        (real / "model" / "textured.glb").write_bytes(b"glTF")
        prop_dir = self.root / "art-src" / "props" / "stick"
        prop_dir.parent.mkdir(parents=True)
        prop_dir.symlink_to(real, target_is_directory=True)
        self.assertIn("symlink", self.refused(self.render_unit))
        prop_dir.unlink()
        (prop_dir / "model").mkdir(parents=True)
        shutil.copy(real / "spec.toml", prop_dir / "spec.toml")
        (prop_dir / "model" / "textured.glb").symlink_to(real / "model" / "textured.glb")
        self.assertIn("textured.glb", self.refused(self.render_unit))
        self.assertFalse((self.root / "assets").exists())

    def test_symlink_between_the_repo_and_a_folder_is_refused(self) -> None:
        # art-src/units -> another folder inside the repo: it stays inside, but the unit isn't where its path says.
        units = self.root / "art-src" / "units"
        units.rename(self.root / "other_units")
        units.symlink_to(self.root / "other_units", target_is_directory=True)
        self.assertIn("symlink", self.refused(self.render_unit))
        self.assertFalse((self.root / "assets").exists())

    def test_symlinked_prop_review_is_refused(self) -> None:
        prop_dir = self.root / "art-src" / "props" / "stick"
        (prop_dir / "candidates").mkdir(parents=True)
        (prop_dir / "spec.toml").write_text(STICK_SPEC, encoding="utf-8")
        (prop_dir / "review").symlink_to(self.elsewhere, target_is_directory=True)
        self.assertIn("symlink", self.refused(lambda: rs.render_prop_candidates("stick", self.root / "art-src")))


if __name__ == "__main__":
    outcome = unittest.main(argv=["blender_test_render"], exit=False).result
    sys.exit(0 if outcome.wasSuccessful() else 1)
