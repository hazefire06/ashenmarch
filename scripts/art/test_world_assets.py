"""Tests for world_assets.py on a temp tree. Nothing here touches the real art-src/world or assets, and nothing uses the network."""
from __future__ import annotations

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # so `python3 -m unittest scripts/art/test_world_assets.py` works from the repo root
import world_assets  # noqa: E402

HAS_FFMPEG: bool = shutil.which("ffmpeg") is not None
LAYERS: list[str] = ["grass", "brush", "forest", "sand", "rock", "mud"]
COLOURS: list[str] = ["red", "green", "blue", "yellow", "white", "black"]
LICENCES_TEXT: str = ("# Asset licenses\n\nOnly owned or CC0.\n\n| File | Source | Terms | Date | Made from |\n|---|---|---|---|---|\n"
                      "| `assets/a.png` | Hand | Ours | 2026-01-01 | x |\n\n<!-- audio:begin -->\n\naudio rows\n\n<!-- audio:end -->\n")
PREFIX: str = LICENCES_TEXT + "\n"
SUFFIX: str = "\nTrailing words.\n"
WORLD_MARKED: str = PREFIX + "<!-- world:begin -->\nold row\n<!-- world:end -->\n" + SUFFIX


def make_image(path: Path, colour: str, size: int = 64) -> None:
    """A two-tone PNG (left half `colour`, right half grey) so a resize is visible in the bytes."""
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"color=c={colour}:s={size}x{size}:d=1",
                    "-f", "lavfi", "-i", f"color=c=gray:s={size // 2}x{size}:d=1", "-filter_complex", "[0:v][1:v]overlay=x=W/2", "-frames:v", "1",
                    str(path)], check=True)


def raw_pixels(path: Path, extra: str = "") -> bytes:
    vf = ",".join(x for x in (extra, "format=rgb24") if x)
    return subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(path), "-vf", vf, "-f", "rawvideo", "-"],
                          check=True, capture_output=True).stdout


def toml_for(sources: str = "", ground_layers: list[str] | None = None, models: str = "") -> str:
    base = sources or '[source.acg]\nname = "Test Pack"\nurl = "https://example.invalid/p"\nlicence = "CC0"\nsite = "ambientcg"\n'
    text = base + "\n"
    for layer in LAYERS if ground_layers is None else ground_layers:
        text += f'[ground.{layer}]\nsource = "acg"\nalbedo = "tex/{layer}_a.png"\nnormal = "tex/{layer}_n.png"\n'
    return text + models


@unittest.skipUnless(HAS_FFMPEG, "ffmpeg not installed")
class WorldAssetsTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name).resolve()
        self.world = self.root / "art-src" / "world"
        self.world.mkdir(parents=True)
        (self.root / "assets").mkdir()
        self.licences = self.root / "assets" / "LICENSES.md"
        self.licences.write_text(WORLD_MARKED)
        for index, layer in enumerate(LAYERS):
            make_image(self.world / "tex" / f"{layer}_a.png", COLOURS[index])
            make_image(self.world / "tex" / f"{layer}_n.png", COLOURS[-1 - index])

    def write_toml(self, text: str) -> None:
        (self.world / "world.toml").write_text(text)

    def run_cmd(self, command: str = "import") -> tuple[int, str]:
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = world_assets.main([command], root=self.root)
        return code, err.getvalue()

    def assert_nothing_written(self) -> None:
        self.assertFalse((self.root / "assets" / "world").exists())
        self.assertEqual(self.licences.read_text(), WORLD_MARKED)

    def test_a_non_cc0_or_unknown_site_is_refused(self) -> None:
        for licence, site in (("CC-BY", "ambientcg"), ("CC0", "sketchfab")):
            with self.subTest(licence=licence, site=site):
                self.write_toml(toml_for(f'[source.acg]\nname = "P"\nurl = "https://x.invalid"\nlicence = "{licence}"\nsite = "{site}"\n'))
                code, err = self.run_cmd()
                self.assertEqual(code, 1)
                self.assertIn("acg", err)
                self.assert_nothing_written()

    def test_a_symlinked_source_is_refused(self) -> None:
        target = self.world / "tex" / "grass_a.png"
        real = self.world / "tex" / "real.png"
        target.rename(real)
        os.symlink(real, target)
        self.write_toml(toml_for())
        code, err = self.run_cmd()
        self.assertEqual(code, 1)
        self.assertIn("symlink", err)
        self.assert_nothing_written()

    def test_a_symlinked_directory_on_the_path_is_refused(self) -> None:
        shutil.move(str(self.world / "tex"), str(self.root / "elsewhere"))
        os.symlink(self.root / "elsewhere", self.world / "tex")
        self.write_toml(toml_for())
        code, err = self.run_cmd()
        self.assertEqual(code, 1)
        self.assertIn("symlink", err)
        self.assert_nothing_written()

    def test_a_path_outside_art_src_world_is_refused(self) -> None:
        outside = self.root / "x.png"
        make_image(outside, "red")
        for bad in ("../x.png", "../../x.png", str(outside)):
            with self.subTest(path=bad):
                self.write_toml(toml_for().replace("tex/grass_a.png", bad))
                code, err = self.run_cmd()
                self.assertEqual(code, 1)
                self.assertIn("art-src/world", err)
                self.assert_nothing_written()

    def test_ground_strips_are_six_layers_in_order(self) -> None:
        self.write_toml(toml_for())
        self.assertEqual(self.run_cmd()[0], 0)
        strip = self.root / "assets" / "world" / "textures" / "ground_albedo.png"
        probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=width,height", "-of", "csv=p=0", str(strip)],
                               check=True, capture_output=True, text=True).stdout.strip()
        self.assertEqual(probe, "1024,6144")
        whole = raw_pixels(strip)
        step = 1024 * 1024 * 3
        for n, layer in enumerate(LAYERS):
            expected = raw_pixels(self.world / "tex" / f"{layer}_a.png", "scale=1024:1024:flags=lanczos")
            self.assertEqual(whole[n * step:(n + 1) * step], expected, layer)
        normals = self.root / "assets" / "world" / "textures" / "ground_normal.png"
        self.assertEqual(raw_pixels(normals)[:step], raw_pixels(self.world / "tex" / "grass_n.png", "scale=1024:1024:flags=lanczos"))
        self.assertEqual(list((self.root / "assets" / "world" / "textures").glob("*.part")), [])

    def test_the_import_file_makes_a_texture_array(self) -> None:
        self.write_toml(toml_for())
        self.assertEqual(self.run_cmd()[0], 0)
        for name, normal in (("ground_albedo", "0"), ("ground_normal", "1")):
            text = (self.root / "assets" / "world" / "textures" / f"{name}.png.import").read_text()
            self.assertIn('importer="2d_array_texture"', text)
            self.assertIn("slices/vertical=6", text)
            self.assertIn("slices/horizontal=1", text)
            self.assertIn("compress/mode=2", text)
            self.assertIn("mipmaps/generate=true", text)
            self.assertIn(f"compress/normal_map={normal}", text)

    def test_licence_rows_are_written_between_the_world_markers_only(self) -> None:
        self.write_toml(toml_for(models='[models.house_a]\nsource = "acg"\nfile = "m/house.glb"\n'))
        (self.world / "m").mkdir()
        (self.world / "m" / "house.glb").write_bytes(b"glTF-fake")
        self.assertEqual(self.run_cmd()[0], 0)
        text = self.licences.read_text()
        begin, end = text.index(world_assets.BEGIN), text.index(world_assets.END)
        self.assertLess(begin, end)
        self.assertEqual(text[:begin], PREFIX)  # the audio section and everything before the markers, byte for byte
        self.assertEqual(text[end:], "<!-- world:end -->\n" + SUFFIX)
        self.assertNotIn("old row", text)
        block = text[begin:end]
        for shipped in ("ground_albedo.png", "ground_normal.png", "house_a.glb"):
            folder = "textures" if shipped.startswith("ground") else "models"
            self.assertIn(f"`assets/world/{folder}/{shipped}`", block)
        self.assertIn("CC0 1.0", block)
        self.assertIn("ambientCG", block)
        self.assertIn("audio rows", text)
        before = text
        self.assertEqual(self.run_cmd()[0], 0)  # idempotent
        self.assertEqual(self.licences.read_text(), before)

    def test_missing_markers_are_added_at_the_end(self) -> None:
        self.licences.write_text(LICENCES_TEXT)
        self.write_toml(toml_for())
        self.assertEqual(self.run_cmd()[0], 0)
        text = self.licences.read_text()
        self.assertTrue(text.startswith(LICENCES_TEXT))
        self.assertEqual(text.count(world_assets.BEGIN), 1)
        self.assertTrue(text.endswith(world_assets.END + "\n"))

    def test_the_allowed_sources_sentence_names_the_world_sites(self) -> None:
        self.licences.write_text("Intro: only sources we own or that are CC0 are allowed: Meshy (paid, customer owned),\nKenney (CC0), or made by hand.\n"
                                 + WORLD_MARKED)
        self.write_toml(toml_for())
        self.assertEqual(self.run_cmd()[0], 0)
        head = self.licences.read_text().split("<!-- world:begin -->")[0]
        for name in ("ambientCG", "Poly Haven", "Quaternius"):
            self.assertIn(name, head)

    def test_a_missing_layer_fails_with_its_name(self) -> None:
        self.write_toml(toml_for(ground_layers=[x for x in LAYERS if x != "forest"]))
        code, err = self.run_cmd()
        self.assertEqual(code, 1)
        self.assertIn("forest", err)
        self.assert_nothing_written()

    def test_a_missing_source_file_fails_with_its_path(self) -> None:
        self.write_toml(toml_for())
        (self.world / "tex" / "rock_n.png").unlink()
        code, err = self.run_cmd()
        self.assertEqual(code, 1)
        self.assertIn("rock_n.png", err)
        self.assert_nothing_written()

    def test_a_gltf_model_is_copied_with_its_files(self) -> None:
        (self.world / "m").mkdir()
        (self.world / "m" / "hut.gltf").write_text('{"buffers":[{"uri":"hut.bin","byteLength":1}],"images":[{"uri":"tex/hut.png"},{"uri":"data:image/png;base64,AA=="}]}')
        (self.world / "m" / "hut.bin").write_bytes(b"\0")
        make_image(self.world / "m" / "tex" / "hut.png", "red")
        self.write_toml(toml_for(models='[models.hut]\nsource = "acg"\nfile = "m/hut.gltf"\n'))
        self.assertEqual(self.run_cmd()[0], 0)
        out = self.root / "assets" / "world" / "models" / "hut"
        for rel in ("hut.gltf", "hut.bin", "tex/hut.png"):
            self.assertTrue((out / rel).is_file(), rel)

    def test_a_gltf_pointing_outside_the_world_folder_is_refused(self) -> None:
        (self.world / "m").mkdir()
        (self.world / "m" / "hut.gltf").write_text('{"buffers":[{"uri":"../../secret.bin","byteLength":1}]}')
        self.write_toml(toml_for(models='[models.hut]\nsource = "acg"\nfile = "m/hut.gltf"\n'))
        code, err = self.run_cmd()
        self.assertEqual(code, 1)
        self.assertIn("art-src/world", err)
        self.assert_nothing_written()

    def test_check_reports_missing_and_symlinked_sources(self) -> None:
        self.write_toml(toml_for())
        self.assertEqual(self.run_cmd("check")[0], 0)
        (self.world / "tex" / "mud_a.png").unlink()
        code, err = self.run_cmd("check")
        self.assertEqual(code, 1)
        self.assertIn("mud_a.png", err)
        self.assertFalse((self.root / "assets" / "world").exists())  # check never writes


if __name__ == "__main__":
    unittest.main()
