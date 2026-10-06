"""Blender test for render_sprites.py, on a generated fixture character.

    make test-art     (or: $BLENDER -b --factory-startup --python-exit-code 1
                       --python scripts/art/blender_test_render.py)

The fixture is a grey 0.5 x 0.3 x 1.8 m block with a red "nose" on its
chest, facing -Y (glTF +Z, like Meshy's characters), skinned to one root
bone. Its walk clip carries it 1.2 m forward in one second with a small bob;
its idle clip holds still. It goes through the real glTF export and import,
then the renderer, with Workbench's flat lighting so the colours are exact.
"""
from __future__ import annotations

import math
import sys
import tempfile
import unittest
from pathlib import Path

import bmesh
import bpy
import numpy as np
from mathutils import Vector

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import render_sprites as rs  # noqa: E402

STRIDE_M = 1.2
FIXTURE_SPEC = """id = "fixture"
faction = "light"
height_m = 1.8
prompt = "test fixture"

[animations.idle]
file = "anims/idle.glb"

[animations.walk]
file = "anims/walk.glb"
"""


def make_material(name: str, rgba: tuple[float, float, float, float]) -> bpy.types.Material:
    mat = bpy.data.materials.new(name)
    if mat.node_tree is None:
        mat.use_nodes = True
    bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = rgba
    mat.diffuse_color = rgba
    return mat


def add_box(bm: bmesh.types.BMesh, center: tuple[float, float, float], size: tuple[float, float, float], material: int) -> None:
    verts = bmesh.ops.create_cube(bm, size=1.0)["verts"]
    for v in verts:
        v.co = Vector((v.co.x * size[0] + center[0], v.co.y * size[1] + center[1], v.co.z * size[2] + center[2]))
    for face in {f for v in verts for f in v.link_faces}:
        face.material_index = material


def build_fixture(path: Path, walk: bool) -> None:
    rs.reset_scene()
    scene = bpy.context.scene
    arm_data = bpy.data.armatures.new("Rig")
    arm = bpy.data.objects.new("Rig", arm_data)
    scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    bone = arm_data.edit_bones.new("Hips")
    bone.head = (0.0, 0.0, 0.9)
    bone.tail = (0.0, 0.0, 1.4)
    bpy.ops.object.mode_set(mode="OBJECT")

    mesh = bpy.data.meshes.new("Body")
    bm = bmesh.new()
    add_box(bm, (0.0, 0.0, 0.9), (0.5, 0.3, 1.8), 0)
    add_box(bm, (0.0, -0.25, 1.0), (0.2, 0.2, 0.2), 1)
    bm.to_mesh(mesh)
    bm.free()
    mesh.materials.append(make_material("Grey", (0.5, 0.5, 0.5, 1.0)))
    mesh.materials.append(make_material("Red", (1.0, 0.0, 0.0, 1.0)))
    body = bpy.data.objects.new("Body", mesh)
    scene.collection.objects.link(body)
    body.parent = arm
    body.vertex_groups.new(name="Hips").add(list(range(len(mesh.vertices))), 1.0, "REPLACE")
    body.modifiers.new("Armature", "ARMATURE").object = arm

    pose = arm.pose.bones["Hips"]
    to_local = arm_data.bones["Hips"].matrix_local.to_3x3().inverted()
    last = 25 if walk else 2
    for frame in range(1, last + 1):
        t = (frame - 1) / 24.0
        delta = Vector((0.0, -STRIDE_M * t, 0.05 * math.sin(4.0 * math.pi * t))) if walk else Vector()
        pose.location = to_local @ delta
        pose.keyframe_insert("location", frame=frame)
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB", export_animations=True)


def cell(sheet: np.ndarray, frame: int, direction: int) -> np.ndarray:
    """One cell of a sheet read by rs.read_rgba (row 0 is the bottom of the image)."""
    height = sheet.shape[0]
    top = height - direction * rs.STRIDE - rs.GUTTER
    left = frame * rs.STRIDE + rs.GUTTER
    return sheet[top - rs.CELL:top, left:left + rs.CELL]


def red_mask(px: np.ndarray) -> np.ndarray:
    return (px[..., 0] > 0.8) & (px[..., 1] < 0.3) & (px[..., 2] < 0.3) & (px[..., 3] > 0.5)


def grey_mask(px: np.ndarray) -> np.ndarray:
    return (np.abs(px[..., 0] - px[..., 1]) < 0.1) & (px[..., 0] > 0.2) & (px[..., 0] < 0.9) & (px[..., 3] > 0.5)


def mean_x(mask: np.ndarray) -> float:
    return float(np.nonzero(mask)[1].mean())


class RenderSpritesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._tmp = tempfile.TemporaryDirectory()
        root = Path(cls._tmp.name)
        cls.unit_dir = root / "art-src" / "units" / "fixture"
        (cls.unit_dir / "anims").mkdir(parents=True)
        (cls.unit_dir / "spec.toml").write_text(FIXTURE_SPEC, encoding="utf-8")
        build_fixture(cls.unit_dir / "anims" / "walk.glb", walk=True)
        build_fixture(cls.unit_dir / "anims" / "idle.glb", walk=False)
        cls.out = root / "assets" / "units" / "fixture"
        cls.sidecar = rs.render_unit("fixture", root / "art-src", root / "assets" / "units", engine="WORKBENCH")
        cls.walk = rs.read_rgba(cls.out / "walk.png")
        cls.idle = rs.read_rgba(cls.out / "idle.png")

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmp.cleanup()

    def test_walk_is_one_second_of_looping_frames(self) -> None:
        walk = self.sidecar["animations"]["walk"]
        self.assertEqual((walk["frames"], walk["fps"], walk["loop"]), (12, 12, True))
        self.assertEqual(self.sidecar["animations"]["idle"]["frames"], 1)

    def test_sheet_layout_and_import_settings(self) -> None:
        self.assertEqual(self.walk.shape[:2], (8 * rs.STRIDE, 12 * rs.STRIDE))
        settings = (self.out / "walk.png.import").read_text(encoding="utf-8")
        self.assertIn("mipmaps/generate=true", settings)

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
        self.assertEqual(len(self.sidecar["gib_color"]), 3)
        self.assertTrue(all(0.0 <= c <= 1.0 for c in self.sidecar["gib_color"]))


if __name__ == "__main__":
    outcome = unittest.main(argv=["blender_test_render"], exit=False).result
    sys.exit(0 if outcome.wasSuccessful() else 1)
