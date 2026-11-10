"""Tests for process.py synthetic: the plan and sidecar (ffmpeg stubbed), plus one real render if ffmpeg exists."""
from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import cuebook
import process


class PlanTest(unittest.TestCase):
    def test_every_cue_and_layer_gets_the_right_files(self) -> None:
        synths, data = process.synthetic_plan()
        book = cuebook.load_cues(process.CUES)
        layers = cuebook.load_layers(process.LAYERS)
        entries = {str(c["id"]): c for c in data["cues"]}  # type: ignore[union-attr]
        self.assertEqual(len(entries), len(book.cues) + len(layers))
        for cue in book.cues.values():
            files = entries[cue.id]["files"]
            if cue.loop:
                self.assertEqual(len(files), 1, cue.id)  # type: ignore[arg-type]
                self.assertTrue(files[0].endswith(".ogg"), cue.id)  # type: ignore[index]
            else:
                self.assertEqual(len(files), 3, cue.id)  # type: ignore[arg-type]
                self.assertTrue(all(f.endswith(".wav") for f in files), cue.id)  # type: ignore[union-attr]
        for layer_id in layers:
            files = entries[f"music_{layer_id}"]["files"]
            self.assertEqual(len(files), 1)  # type: ignore[arg-type]
            self.assertTrue(files[0].endswith(".ogg"))  # type: ignore[index]
        names = [s.name for s in synths]
        self.assertEqual(len(names), len(set(names)))

    def test_one_shots_total_520_seconds_within_2_percent(self) -> None:
        synths, _ = process.synthetic_plan()
        total = sum(s.seconds for s in synths if s.name.endswith(".wav"))
        self.assertAlmostEqual(total, 520.0, delta=520.0 * 0.02)

    def test_loops_are_12_s_and_music_110_s(self) -> None:
        synths, _ = process.synthetic_plan()
        oggs = [s for s in synths if s.name.endswith(".ogg")]
        self.assertEqual(sorted({s.seconds for s in oggs}), [12.0, 110.0])

    def test_synthetic_writes_files_and_imports_with_ffmpeg_stubbed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "synthetic"
            side = Path(tmp) / "bank.json"
            with mock.patch.object(process, "render") as render, mock.patch.object(shutil, "which", return_value="/x/ffmpeg"):
                self.assertEqual(process.synthetic(side, out), 0)
            self.assertEqual(render.call_count, len(process.synthetic_plan()[0]))
            self.assertTrue(side.is_file())

    def test_a_missing_ffmpeg_is_refused_before_any_work(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(shutil, "which", return_value=None):
            self.assertEqual(process.synthetic(Path(tmp) / "bank.json", Path(tmp) / "s"), 1)
            self.assertFalse((Path(tmp) / "s").exists())

    def test_import_settings(self) -> None:
        self.assertIn("compress/mode=2", process._import_text("a_1.wav"))
        self.assertIn("edit/loop_mode=0", process._import_text("a_1.wav"))
        self.assertIn("loop=true", process._import_text("a.ogg"))

    @unittest.skipIf(shutil.which("ffmpeg") is None, "needs ffmpeg")
    def test_a_real_one_shot_renders(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            process.render(process._oneshot("cue", 1), Path(tmp))
            self.assertGreater((Path(tmp) / "cue_1.wav").stat().st_size, 100000)
            self.assertTrue((Path(tmp) / "cue_1.wav.import").is_file())


if __name__ == "__main__":
    unittest.main()
