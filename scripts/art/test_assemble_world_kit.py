"""Tests for assemble_world_kit.py on a synthetic one-triangle kit piece in a temp folder. No network, no ffmpeg."""
from __future__ import annotations

import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import assemble_world_kit as kit  # noqa: E402


def write_piece(folder: Path, name: str, uv_set: int = 0, alpha: str = "OPAQUE") -> None:
    """One triangle at x 0..1, y 0..1, facing +z, with two UV sets (UV0 all 0, UV1 all 1)."""
    positions = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]
    blob = b"".join(struct.pack("<3f", *p) for p in positions) + struct.pack("<9f", *([0.0, 0.0, 1.0] * 3))
    blob += struct.pack("<6f", *([0.0] * 6)) + struct.pack("<6f", *([1.0] * 6)) + struct.pack("<3H", 0, 1, 2) + b"\0\0"
    views = [(0, 36), (36, 36), (72, 24), (96, 24), (120, 6)]
    doc = {
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0, "name": name}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2, "TEXCOORD_1": 3}, "indices": 4, "material": 0}]}],
        "materials": [{"name": "MI_Test", "alphaMode": alpha, "doubleSided": True,
                       "pbrMetallicRoughness": {"baseColorTexture": {"index": 0, "texCoord": uv_set}}}],
        "textures": [{"source": 0}], "images": [{"uri": "T_Test_BaseColor.png"}],
        "bufferViews": [{"buffer": 0, "byteOffset": o, "byteLength": n} for o, n in views],
        "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
                      {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"},
                      {"bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC2"},
                      {"bufferView": 3, "componentType": 5126, "count": 3, "type": "VEC2"},
                      {"bufferView": 4, "componentType": 5123, "count": 3, "type": "SCALAR"}],
        "buffers": [{"uri": f"{name}.bin", "byteLength": len(blob)}],
    }
    (folder / f"{name}.bin").write_bytes(blob)
    (folder / f"{name}.gltf").write_text(json.dumps(doc), encoding="utf-8")


class AssembleTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_placements_transform_positions_and_normals(self) -> None:
        write_piece(self.root, "Tri")
        groups: dict[str, kit.Group] = {}
        kit.assemble(self.root, [("Tri", kit.chain(kit.move(5.0, 0.0, 0.0), kit.yaw(90))), ("Tri", kit.scale(2.0, 3.0, 1.0))], groups)
        g = groups["MI_Test"]
        self.assertEqual(len(g.positions), 6)
        self.assertEqual(g.indices, [0, 1, 2, 3, 4, 5])
        # yaw(90) takes +x to -z and the outside (+z) to +x.
        self.assertAlmostEqual(g.positions[1][0], 5.0)
        self.assertAlmostEqual(g.positions[1][2], -1.0)
        self.assertAlmostEqual(g.normals[0][0], 1.0)
        self.assertEqual(g.positions[5], (0.0, 3.0, 0.0))
        self.assertAlmostEqual(g.normals[3][2], 1.0)

    def test_the_uv_set_the_colour_texture_reads_becomes_uv0(self) -> None:
        write_piece(self.root, "Tri", uv_set=1)
        groups: dict[str, kit.Group] = {}
        kit.assemble(self.root, [("Tri", kit.IDENTITY)], groups)
        self.assertEqual(groups["MI_Test"].uvs, [(1.0, 1.0)] * 3)

    def test_refuses_a_transparent_material_and_a_mirror(self) -> None:
        write_piece(self.root, "Glass", alpha="BLEND")
        with self.assertRaises(kit.KitError):
            kit.assemble(self.root, [("Glass", kit.IDENTITY)], {})
        write_piece(self.root, "Tri")
        with self.assertRaises(kit.KitError):
            kit.assemble(self.root, [("Tri", kit.scale(-1.0, 1.0, 1.0))], {})

    def test_refuses_a_buffer_outside_the_kit(self) -> None:
        write_piece(self.root, "Tri")
        doc = json.loads((self.root / "Tri.gltf").read_text())
        doc["buffers"][0]["uri"] = "../escape.bin"
        (self.root / "Tri.gltf").write_text(json.dumps(doc))
        with self.assertRaises(kit.KitError):
            kit.assemble(self.root, [("Tri", kit.IDENTITY)], {})

    def test_written_gltf_keeps_only_the_colour_texture(self) -> None:
        write_piece(self.root, "Tri")
        groups: dict[str, kit.Group] = {}
        kit.assemble(self.root, [("Tri", kit.IDENTITY)], groups)
        kit.write_gltf("thing", groups, self.root)
        doc = json.loads((self.root / "thing.gltf").read_text())
        self.assertEqual([i["uri"] for i in doc["images"]], ["T_Test_BaseColor.jpg"])
        self.assertEqual(doc["materials"][0]["name"], "MI_Test")
        self.assertNotIn("doubleSided", doc["materials"][0])
        self.assertEqual(doc["accessors"][0]["max"], [1.0, 1.0, 0.0])
        self.assertEqual((self.root / "thing.bin").stat().st_size, doc["buffers"][0]["byteLength"])

    def test_every_recipe_is_a_proper_placement_list(self) -> None:
        for name, placements in kit.RECIPES.items():
            for piece, m in placements:
                kit._normal_matrix(m)  # raises on a mirror
                self.assertTrue(piece.replace("_", "").isalnum(), f"{name}: {piece}")


if __name__ == "__main__":
    unittest.main()
