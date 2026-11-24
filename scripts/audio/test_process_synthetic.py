"""Tests for process.py synthetic: the plan and sidecar (ffmpeg stubbed), plus one real render if ffmpeg exists."""
from __future__ import annotations

import os
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

    @unittest.skipIf(shutil.which("ffmpeg") is None, "needs ffmpeg")
    def test_a_real_loop_and_music_layer_render_as_ogg(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(process, "SYNTH_LOOP_S", 0.5), \
                mock.patch.object(process, "SYNTH_MUSIC_S", 0.5):
            for synth in (process._loop("bed_x"), process._music("layer_x")):
                process.render(synth, Path(tmp))
                data = (Path(tmp) / synth.name).read_bytes()
                self.assertGreater(len(data), 0, synth.name)
                self.assertEqual(data[:4], b"OggS", synth.name)


class SymlinkSafetyTest(unittest.TestCase):
    """M1: a PR can plant a symlink where synthetic writes; nothing may be written through one, and nothing runs once one is found."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "repo"
        (self.root / "assets" / "audio").mkdir(parents=True)
        (self.root / "audio-src" / "build").mkdir(parents=True)
        self.elsewhere = Path(self._tmp.name) / "elsewhere"
        self.elsewhere.mkdir()
        self.precious = self.elsewhere / "precious.txt"
        self.precious.write_text("keep me")
        self.out = self.root / "assets" / "audio" / "synthetic"
        self.side = self.root / "audio-src" / "build" / "bank.json"

    def run_synthetic(self) -> tuple[int, mock.MagicMock]:
        with mock.patch.object(process, "render") as render, mock.patch.object(shutil, "which", return_value="/x/ffmpeg"), \
                mock.patch("sys.stderr"):
            return process.synthetic(self.side, self.out, root=self.root), render

    def test_a_symlinked_output_folder_is_refused_before_any_work(self) -> None:
        os.symlink(self.elsewhere, self.out)
        code, render = self.run_synthetic()
        self.assertEqual(code, 1)
        render.assert_not_called()
        self.assertEqual(sorted(p.name for p in self.elsewhere.iterdir()), ["precious.txt"])

    def test_a_symlinked_file_inside_the_output_folder_is_refused(self) -> None:
        self.out.mkdir()
        os.symlink(self.precious, self.out / "arrow_flesh_1.wav.import")
        code, render = self.run_synthetic()
        self.assertEqual(code, 1)
        render.assert_not_called()
        self.assertEqual(self.precious.read_text(), "keep me")

    def test_a_symlinked_build_folder_or_assets_audio_is_refused(self) -> None:
        (self.root / "audio-src" / "build").rmdir()
        os.symlink(self.elsewhere, self.root / "audio-src" / "build")
        self.assertEqual(self.run_synthetic()[0], 1)
        self.assertFalse((self.elsewhere / "bank.json").exists())
        (self.root / "audio-src" / "build").unlink()
        (self.root / "audio-src" / "build").mkdir()
        (self.root / "assets" / "audio").rmdir()
        os.symlink(self.elsewhere, self.root / "assets" / "audio")
        self.assertEqual(self.run_synthetic()[0], 1)

    def test_a_symlinked_raw_folder_is_refused_too(self) -> None:
        os.symlink(self.elsewhere, self.root / "audio-src" / "raw")
        self.assertEqual(self.run_synthetic()[0], 1)

    def test_a_normal_tree_still_works(self) -> None:
        code, render = self.run_synthetic()
        self.assertEqual(code, 0)
        self.assertGreater(render.call_count, 0)
        self.assertTrue(self.side.is_file())

    def test_the_guard_runs_before_the_ffmpeg_check(self) -> None:
        os.symlink(self.elsewhere, self.out)
        with mock.patch.object(shutil, "which", return_value=None), mock.patch("sys.stderr") as err:
            self.assertEqual(process.synthetic(self.side, self.out, root=self.root), 1)
        self.assertIn("symlink", "".join(c.args[0] for c in err.write.call_args_list))

    @unittest.skipIf(shutil.which("ffmpeg") is None, "needs ffmpeg")
    def test_render_never_writes_through_a_link_even_if_one_appears_after_the_check(self) -> None:
        self.out.mkdir()
        with mock.patch.object(process, "SYNTH_ONESHOT_S", 0.6):
            synth = process._oneshot("cue", 1)
            os.symlink(self.precious, self.out / "cue_1.wav.import")  # replaced, not followed
            os.symlink(self.precious, self.out / "cue_1.wav")
            process.render(synth, self.out)
        self.assertEqual(self.precious.read_text(), "keep me")
        self.assertFalse((self.out / "cue_1.wav").is_symlink())
        self.assertFalse((self.out / "cue_1.wav.import").is_symlink())
        self.assertEqual((self.out / "cue_1.wav").read_bytes()[:4], b"RIFF")
        # a planted .part link is refused outright (O_NOFOLLOW), not written through
        os.symlink(self.precious, self.out / "cue_1.wav.part")
        with mock.patch.object(process, "SYNTH_ONESHOT_S", 0.6), self.assertRaises(OSError):
            process.render(synth, self.out)
        self.assertEqual(self.precious.read_text(), "keep me")

    @unittest.skipIf(shutil.which("ffmpeg") is None, "needs ffmpeg")
    def test_a_rendered_wav_is_a_seekable_file_with_a_real_length(self) -> None:
        self.out.mkdir()
        with mock.patch.object(process, "SYNTH_ONESHOT_S", 0.6):
            process.render(process._oneshot("cue", 2), self.out)
        data = (self.out / "cue_2.wav").read_bytes()
        self.assertEqual(int.from_bytes(data[4:8], "little") + 8, len(data))  # not a streamed header (Godot reads the size)


if __name__ == "__main__":
    unittest.main()
