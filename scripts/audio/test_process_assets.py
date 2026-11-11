"""Tests for process.py batch, picks and build, on a temp tree. Nothing here touches the real cues, raw takes or assets."""
from __future__ import annotations

import contextlib
import datetime
import io
import json
import math
import os
import shutil
import tempfile
import unittest
from array import array
from pathlib import Path
from unittest import mock

import ffmpeg_io
import process
from test_cuebook import HEAD

HAS_TOOLS: bool = shutil.which("ffmpeg") is not None and shutil.which("oggenc") is not None
RATE: int = 32000

BOOK: str = HEAD + '''
[cue.hit_a]
category = "melee"
prompt = "a blade <b>hit</b>"
duration_s = 1.0
level_db = -3.0
takes = 4
picks = []

[cue.bed_x]
category = "bed"
prompt = "wind"
duration_s = 4.0
loop = true
model = "eleven_text_to_sound_v3"
takes = 3
variants = 1
picks = []
'''
MUSIC: str = '''
[layer.calm]
prompt = "a drone"
length_s = 110
model = "music_v2"
takes = 2
picks = []

[layer.war]
prompt = "drums"
length_s = 110
model = "music_v2"
takes = 2
picks = []
'''
VOICE: str = (
    'unit = "reaver"\n\n[voice.reaver]\ndescription = "a rough voice"\nmodel = "eleven_v4"\n\n'
    '[line.attack_1]\ntrigger = "attack"\ntext = "Hi"\npicks = {}\n'
)
CLAN: str = 'unit = "_clan"\n\n[line.clan_1]\ntext = "Crivens!"\npicks = {}\n'
LICENSES: str = "# Licenses\n\n| File | Source |\n|---|---|\n| `a` | b |\n"


def tone(seconds: float, freq: float = 440.0, lead_s: float = 0.2, amp: float = 0.4, channels: int = 1) -> array:
    lead = array("h", [0] * int(lead_s * RATE) * channels)
    body = array("h")
    for i in range(int(seconds * RATE)):
        v = int(32767 * amp * math.sin(2 * math.pi * freq * i / RATE))
        body.extend([v] * channels)
    return lead + body


class Tree:
    """A temp project tree with a cue book, a layer file, two voice files and LICENSES.md."""

    def __init__(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        src = self.root / "audio-src"
        (src / "voices").mkdir(parents=True)
        (src / "music").mkdir()
        (self.root / "assets").mkdir()
        self.cues = src / "cues.toml"
        self.layers = src / "music" / "prompts.toml"
        self.voices = src / "voices"
        self.cues.write_text(BOOK, encoding="utf-8")
        self.layers.write_text(MUSIC, encoding="utf-8")
        (self.voices / "reaver.toml").write_text(VOICE, encoding="utf-8")
        (self.voices / "_clan.toml").write_text(CLAN, encoding="utf-8")
        self.licences = self.root / "assets" / "LICENSES.md"
        self.licences.write_text(LICENSES, encoding="utf-8")

    def raw(self, rel: str, frames: array | None = None, channels: int = 1) -> Path:
        path = self.root / "audio-src" / "raw" / rel
        ffmpeg_io.write_wav(frames if frames is not None else tone(0.5), RATE, channels, path)
        return path

    def manifest(self, tasks: list[dict[str, object]]) -> None:
        (self.root / "audio-src" / "manifest.json").write_text(json.dumps({"tasks": tasks}), encoding="utf-8")

    def set_picks(self, cue_picks: dict[str, str]) -> None:
        text = self.cues.read_text(encoding="utf-8")
        for cue_id, value in cue_picks.items():
            head, _, rest = text.partition(f"[cue.{cue_id}]")
            before, _, after = rest.partition("picks = []")
            text = head + f"[cue.{cue_id}]" + before + f"picks = {value}" + after
        self.cues.write_text(text, encoding="utf-8")

    def run(self, fn: str, *args: object, **kwargs: object) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = getattr(process, fn)(*args, root=self.root, cues_path=self.cues, layers_path=self.layers, voices_dir=self.voices, **kwargs)
        return code, out.getvalue(), err.getvalue()

    def build(self, **kwargs: object) -> tuple[int, str, str]:
        return self.run("build", self.root / "audio-src" / "build" / "bank.json", **kwargs)

    def snapshot(self) -> dict[str, bytes]:
        return {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}

    def write_picks(self, data: dict[str, object], name: str = "picks.json") -> Path:
        path = self.root / name
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def close(self) -> None:
        self._tmp.cleanup()


class LicenceBlockTest(unittest.TestCase):
    def test_the_licence_block_is_replaced_and_the_rest_kept(self) -> None:
        before = "# L\n\n| a |\n\n<!-- audio:begin -->\nold rows\n<!-- audio:end -->\n\ntail text\n"
        out = process.update_licences(before, ["| `x.wav` | s | t | d | m |"])
        self.assertTrue(out.startswith("# L\n\n| a |\n\n<!-- audio:begin -->\n"))
        self.assertTrue(out.endswith("<!-- audio:end -->\n\ntail text\n"))
        self.assertIn("| `x.wav` | s | t | d | m |", out)
        self.assertNotIn("old rows", out)
        self.assertEqual(process.update_licences(out, ["| `x.wav` | s | t | d | m |"]), out)  # stable

    def test_markers_are_added_after_the_existing_rows(self) -> None:
        out = process.update_licences(LICENSES, [])
        self.assertTrue(out.startswith(LICENSES))
        self.assertEqual(out[len(LICENSES):], "\n<!-- audio:begin -->\n<!-- audio:end -->\n")

    def test_a_lone_marker_is_refused(self) -> None:
        with self.assertRaisesRegex(process.CueError, "markers"):
            process.update_licences("x\n<!-- audio:end -->\n<!-- audio:begin -->\n", [])


class SafetyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tree = Tree()
        self.addCleanup(self.tree.close)

    def test_a_planted_symlink_stops_the_build(self) -> None:
        self.tree.set_picks({"hit_a": "[1]"})
        self.tree.raw("sfx/hit_a/1.wav")
        target = self.tree.root / "elsewhere"
        target.mkdir()
        (self.tree.root / "assets" / "audio" / "sfx").mkdir(parents=True)
        os.symlink(target, self.tree.root / "assets" / "audio" / "sfx" / "linked")
        before = self.tree.snapshot()
        code, _, err = self.tree.build()
        self.assertEqual(code, 1)
        self.assertIn("symlink", err)
        self.assertEqual(self.tree.snapshot(), before)

    def test_a_symlink_in_raw_stops_batch(self) -> None:
        self.tree.raw("sfx/hit_a/1.wav")
        os.symlink(self.tree.root / "assets", self.tree.root / "audio-src" / "raw" / "sfx" / "trap")
        code, _, err = self.tree.run("batch", "melee")
        self.assertEqual(code, 1)
        self.assertIn("symlink", err)
        self.assertFalse((self.tree.root / "audio-src" / "audition").exists())

    def test_a_symlinked_assets_audio_stops_the_build(self) -> None:
        (self.tree.root / "real").mkdir()
        os.symlink(self.tree.root / "real", self.tree.root / "assets" / "audio")
        code, _, err = self.tree.build()
        self.assertEqual((code, "symlink" in err), (1, True))

    def test_ffmpeg_is_checked_before_any_work(self) -> None:
        self.tree.set_picks({"hit_a": "[1]"})
        self.tree.raw("sfx/hit_a/1.wav")
        before = self.tree.snapshot()
        with mock.patch.object(shutil, "which", return_value=None):
            code, _, err = self.tree.build()
            code_b, _, err_b = self.tree.run("batch", "melee")
        self.assertEqual((code, code_b), (1, 1))
        self.assertIn("ffmpeg", err)
        self.assertIn("ffmpeg", err_b)
        self.assertEqual(self.tree.snapshot(), before)

    def test_oggenc_is_checked_before_any_work(self) -> None:
        self.tree.set_picks({"bed_x": "[1]"})
        self.tree.raw("sfx/bed_x/1.wav")
        before = self.tree.snapshot()
        real = shutil.which
        with mock.patch.object(shutil, "which", side_effect=lambda n: None if n == "oggenc" else real(n)):
            code, _, err = self.tree.build()
        self.assertEqual(code, 1)
        self.assertIn("oggenc", err)
        self.assertEqual(self.tree.snapshot(), before)

    def test_a_picked_take_with_no_raw_file_is_refused_before_any_work(self) -> None:
        self.tree.set_picks({"hit_a": "[2]"})
        before = self.tree.snapshot()
        code, _, err = self.tree.build()
        self.assertEqual(code, 1)
        self.assertIn("hit_a", err)
        self.assertEqual(self.tree.snapshot(), before)


class PicksCommandTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tree = Tree()
        self.addCleanup(self.tree.close)
        for n in (1, 2, 3):
            self.tree.raw(f"sfx/hit_a/{n}.wav")
        self.tree.raw("music/calm/2.wav")
        self.tree.raw("voices/reaver/attack_1/1.wav")
        self.tree.raw("voices/reaver/attack_1/2.wav")
        self.tree.raw("voices/shieldman_old/clan_1/1.wav")  # a voice the clan file may use only if some unit defines it
        for n in (1, 2):
            self.tree.raw(f"design/reaver/reaver/{n}.wav")

    def picks(self, data: dict[str, object]) -> tuple[int, str, str]:
        return self.tree.run("picks_file", self.tree.write_picks(data))

    def test_cue_and_layer_picks_are_written_and_nothing_else_changes(self) -> None:
        before = self.tree.snapshot()
        code, _, err = self.picks({"batch": "melee", "cues": {"hit_a": [3, 1], "calm": [2]}})
        self.assertEqual(code, 0, err)
        after = self.tree.snapshot()
        changed = {k for k in after if after[k] != before.get(k)} - {"picks.json"}
        self.assertEqual(changed, {"audio-src/cues.toml", "audio-src/music/prompts.toml"})
        self.assertIn("picks = [3, 1]", after["audio-src/cues.toml"].decode())
        self.assertIn("picks = [2]", after["audio-src/music/prompts.toml"].decode())

    def test_picks_with_an_unknown_id_or_take_change_nothing(self) -> None:
        for bad in (
            {"cues": {"hit_a": [1], "nope": [1]}},
            {"cues": {"hit_a": [1, 9]}},          # past takes
            {"cues": {"hit_a": [4]}},             # in range, but no raw file
            {"cues": {"hit_a": [0]}},
            {"cues": {"hit_a": [1, 1]}},
            {"cues": {"hit_a": "1"}},
            {"cues": {"../x": [1]}},
            {"cues": {"bed_x": [1, 2]}},          # a loop keeps one take
            {"lines": {"attack_1": {"nobody": 1}}},
            {"lines": {"attack_1": {"reaver": 3}}},
            {"lines": {"nope": {"reaver": 1}}},
            {"lines": {"clan_1": {"reaver": 1}}},  # no raw take for it
            {"cues": {}, "lines": {}},
            {},
        ):
            before = self.tree.snapshot()
            code, _, err = self.picks({"batch": "x", **bad})
            self.assertEqual(code, 1, bad)
            self.assertTrue(err, bad)
            self.assertEqual(self.tree.snapshot()["audio-src/cues.toml"], before["audio-src/cues.toml"], bad)
            self.assertEqual({k: v for k, v in self.tree.snapshot().items() if k != "picks.json"},
                             {k: v for k, v in before.items() if k != "picks.json"}, bad)

    def test_one_bad_entry_blocks_the_good_ones(self) -> None:
        before = self.tree.snapshot()
        code, _, _ = self.picks({"batch": "x", "cues": {"hit_a": [1], "calm": [1]}})  # calm 1 has no raw take
        self.assertEqual(code, 1)
        self.assertEqual({k: v for k, v in self.tree.snapshot().items() if k != "picks.json"}, before)

    def test_line_picks_merge_with_the_ones_already_there(self) -> None:
        self.tree.raw("voices/reaver/attack_1/1.wav")
        code, _, err = self.picks({"batch": "voices-reaver", "lines": {"attack_1": {"reaver": 2}}})
        self.assertEqual(code, 0, err)
        self.assertIn("picks = { reaver = 2 }", (self.tree.voices / "reaver.toml").read_text())

    def test_a_design_file_prints_the_save_commands_and_writes_nothing(self) -> None:
        before = self.tree.snapshot()
        code, out, err = self.picks({"batch": "design-reaver", "design": {"reaver": 2}})
        self.assertEqual((code, err), (0, ""))
        self.assertIn("python3 scripts/audio/generate.py voices save reaver --voice reaver --pick 2", out)
        self.assertEqual({k: v for k, v in self.tree.snapshot().items() if k != "picks.json"},
                         {k: v for k, v in before.items() if k != "picks.json"})

    def test_a_design_pick_for_another_units_voice_or_a_missing_preview_is_refused(self) -> None:
        self.assertEqual(self.picks({"batch": "design-reaver", "design": {"shieldman_old": 1}})[0], 1)
        self.assertEqual(self.picks({"batch": "design-reaver", "design": {"reaver": 7}})[0], 1)
        self.assertEqual(self.picks({"batch": "reaver", "design": {"reaver": 1}})[0], 1)  # the unit comes from the batch name


@unittest.skipUnless(HAS_TOOLS, "ffmpeg and oggenc needed")
class BuildTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tree = Tree()
        self.addCleanup(self.tree.close)
        t = self.tree
        t.raw("sfx/hit_a/1.wav", tone(0.5, amp=0.1))
        t.raw("sfx/hit_a/3.wav", tone(0.4, freq=300))
        t.raw("sfx/bed_x/2.wav", tone(3.5, channels=2, lead_s=0), channels=2)
        t.raw("voices/reaver/attack_1/2.wav", tone(1.5, amp=0.05))
        t.raw("music/calm/1.wav", tone(4.0, lead_s=0, channels=2), channels=2)
        t.raw("music/war/2.wav", tone(3.0, lead_s=0, channels=2), channels=2)
        t.set_picks({"hit_a": "[1, 3]", "bed_x": "[2]"})
        for path, picks_ in (("music/prompts.toml", ("calm", "[1]")), ("music/prompts.toml", ("war", "[2]"))):
            file = t.root / "audio-src" / path
            head, _, rest = file.read_text().partition(f"[layer.{picks_[0]}]")
            before, _, after = rest.partition("picks = []")
            file.write_text(head + f"[layer.{picks_[0]}]" + before + f"picks = {picks_[1]}" + after)
        (t.voices / "reaver.toml").write_text(VOICE.replace("picks = {}", "picks = { reaver = 2 }"), encoding="utf-8")
        t.manifest([
            {"kind": "sfx", "label": "sfx/hit_a/1", "model": "eleven_text_to_sound_v2", "status": "DONE", "finished_at": 1796000000},
            {"kind": "voices", "label": "voices/reaver/attack_1/2", "model": "eleven_v4", "status": "DONE", "finished_at": 1796000000},
        ])

    def test_build_writes_each_kind_of_asset_with_its_import(self) -> None:
        code, out, err = self.tree.build()
        self.assertEqual(code, 0, err)
        a = self.tree.root / "assets" / "audio"
        for rel in ("sfx/hit_a_1.wav", "sfx/hit_a_3.wav", "loop/bed_x.ogg", "voice/reaver/attack_1.ogg", "music/calm.ogg", "music/war.ogg"):
            self.assertGreater((a / rel).stat().st_size, 100, rel)
        self.assertFalse((a / "sfx" / "hit_a_2.wav").exists())
        # One-shots: mono 16-bit, trimmed and peaked at -1 dBFS.
        self.assertEqual(ffmpeg_io.probe(a / "sfx" / "hit_a_1.wav"), (RATE, 1))
        shot = ffmpeg_io.decode(a / "sfx" / "hit_a_1.wav", RATE, 1)
        self.assertAlmostEqual(len(shot) / RATE, 0.5, delta=0.02)
        self.assertAlmostEqual(20 * math.log10(max(abs(x) for x in shot) / 32768), -1.0, delta=0.1)
        # Loops keep their stereo and lose the crossfade; barks are mono; music layers match in length.
        self.assertEqual(ffmpeg_io.probe(a / "loop" / "bed_x.ogg"), (RATE, 2))
        self.assertAlmostEqual(len(ffmpeg_io.decode(a / "loop" / "bed_x.ogg", RATE, 2)) / 2 / RATE, 2.5, delta=0.15)
        self.assertEqual(ffmpeg_io.probe(a / "voice" / "reaver" / "attack_1.ogg"), (RATE, 1))
        calm, war = (len(ffmpeg_io.decode(a / "music" / f"{n}.ogg", RATE, 2)) for n in ("calm", "war"))
        self.assertAlmostEqual(calm, war, delta=2 * 2048)
        self.assertAlmostEqual(calm / 2 / RATE, 3.0, delta=0.15)
        # Imports.
        wav = (a / "sfx" / "hit_a_1.wav.import").read_text()
        self.assertIn("compress/mode=2", wav)
        self.assertIn("edit/loop_mode=0", wav)
        self.assertIn("loop=true", (a / "loop" / "bed_x.ogg.import").read_text())
        self.assertIn("loop=true", (a / "music" / "calm.ogg.import").read_text())
        self.assertIn("loop=false", (a / "voice" / "reaver" / "attack_1.ogg.import").read_text())

    def test_an_existing_import_keeps_its_uid_and_a_wrong_param_is_fixed_in_place(self) -> None:
        self.assertEqual(self.tree.build()[0], 0)
        a = self.tree.root / "assets" / "audio"
        loop_import = a / "loop" / "bed_x.ogg.import"
        godot = loop_import.read_text().replace("[remap]\n", '[remap]\n\nuid="uid://abc123"').replace("loop=true", "loop=false")
        loop_import.write_text(godot, encoding="utf-8")
        wav_import = a / "sfx" / "hit_a_1.wav.import"
        keep = wav_import.read_text().replace("[remap]\n", '[remap]\n\nuid="uid://keep"')
        wav_import.write_text(keep, encoding="utf-8")
        self.assertEqual(self.tree.build()[0], 0)
        self.assertEqual(wav_import.read_text(), keep)  # params right: untouched
        fixed = loop_import.read_text()
        self.assertIn("loop=true", fixed)
        self.assertIn('uid="uid://abc123"', fixed)

    def test_a_second_build_rewrites_no_audio_and_force_does(self) -> None:
        self.assertEqual(self.tree.build()[0], 0)
        ogg = self.tree.root / "assets" / "audio" / "loop" / "bed_x.ogg"
        ogg.write_bytes(ogg.read_bytes() + b"x")
        marked = ogg.read_bytes()
        os.utime(ogg, (4102444800, 4102444800))
        self.assertEqual(self.tree.build()[0], 0)
        self.assertEqual(ogg.read_bytes(), marked)
        self.assertEqual(self.tree.build(force=True)[0], 0)
        self.assertNotEqual(ogg.read_bytes(), marked)

    def test_build_writes_the_licence_rows_and_the_sidecar(self) -> None:
        self.assertEqual(self.tree.build()[0], 0)
        text = self.tree.licences.read_text()
        self.assertTrue(text.startswith(LICENSES))
        block = text[text.index("<!-- audio:begin -->"):text.index("<!-- audio:end -->")]
        self.assertEqual(block.count("| `assets/audio/"), 6)
        self.assertIn("ElevenLabs paid plan: commercial use, no attribution", block)
        self.assertIn("ElevenLabs sound-generation (eleven_text_to_sound_v2)", block)
        self.assertIn("ElevenLabs text-to-speech (eleven_v4)", block)
        self.assertIn(f"{datetime.datetime.fromtimestamp(1796000000, datetime.timezone.utc):%Y-%m-%d}", block)
        self.assertIn("`hit_a`", block)
        self.assertIn("`attack_1`", block)
        side = json.loads((self.tree.root / "audio-src" / "build" / "bank.json").read_text())
        files = {c["id"]: c["files"] for c in side["cues"]}
        self.assertEqual(files["hit_a"], ["res://assets/audio/sfx/hit_a_1.wav", "res://assets/audio/sfx/hit_a_3.wav"])
        self.assertEqual(files["music_calm"], ["res://assets/audio/music/calm.ogg"])
        # Rebuilding leaves the file as it was.
        self.assertEqual(self.tree.build()[0], 0)
        self.assertEqual(self.tree.licences.read_text(), text)

    def test_with_no_picks_nothing_is_written_but_the_markers_and_the_sidecar(self) -> None:
        empty = Tree()
        self.addCleanup(empty.close)
        code, _, err = empty.build()
        self.assertEqual(code, 0, err)
        self.assertFalse((empty.root / "assets" / "audio").exists())
        self.assertEqual(empty.licences.read_text(), process.update_licences(LICENSES, []))
        self.assertTrue((empty.root / "audio-src" / "build" / "bank.json").is_file())

    def test_a_silent_take_is_refused_by_name(self) -> None:
        self.tree.raw("sfx/hit_a/1.wav", array("h", [0] * 8000))
        code, _, err = self.tree.build(force=True)
        self.assertEqual(code, 1)
        self.assertIn("hit_a", err)


@unittest.skipUnless(HAS_TOOLS, "ffmpeg and oggenc needed")
class BatchTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tree = Tree()
        self.addCleanup(self.tree.close)
        self.tree.raw("sfx/hit_a/1.wav")
        self.tree.raw("sfx/hit_a/2.wav", tone(0.3))
        self.tree.raw("voices/reaver/attack_1/1.wav", tone(1.0))
        self.tree.raw("design/reaver/reaver/1.wav", tone(1.0))
        self.tree.raw("ab/eleven_v4/attack_1/1.wav", tone(1.0))
        self.tree.raw("sfx/bed_x/1.wav", tone(3.0, channels=2), channels=2)
        self.tree.raw("music/calm/1.wav", tone(2.0, channels=2), channels=2)

    def page(self, name: str) -> str:
        return (self.tree.root / "audio-src" / "audition" / f"{name}.html").read_text()

    def test_a_category_batch_makes_previews_and_a_page(self) -> None:
        code, _, err = self.tree.run("batch", "melee")
        self.assertEqual(code, 0, err)
        folder = self.tree.root / "audio-src" / "audition" / "melee"
        self.assertEqual(sorted(p.name for p in folder.iterdir()), ["hit_a_1.wav", "hit_a_2.wav"])
        page = self.page("melee")
        self.assertIn("melee/hit_a_1.wav", page)
        self.assertIn("a blade &lt;b&gt;hit&lt;/b&gt;", page)
        self.assertIn('data-kind="cues"', page)

    def test_loops_music_voices_design_and_ab_batches(self) -> None:
        for name, expect in (("loops", "bed_x_1.wav"), ("music", "calm_1.wav"), ("voices-reaver", "attack_1_reaver_1.wav"),
                             ("design-reaver", "reaver_1.wav"), ("ab", "attack_1_eleven_v4_1.wav")):
            code, _, err = self.tree.run("batch", name)
            self.assertEqual(code, 0, f"{name}: {err}")
            self.assertTrue((self.tree.root / "audio-src" / "audition" / name / expect).is_file(), name)
        self.assertIn('data-kind="lines"', self.page("voices-reaver"))
        self.assertIn("Hi", self.page("voices-reaver"))
        self.assertIn('data-kind="design"', self.page("design-reaver"))
        self.assertNotIn("Save picks", self.page("ab"))

    def test_an_unknown_batch_or_one_with_no_takes_is_refused(self) -> None:
        for name in ("nope", "voices-nobody", "design-../x", "groan"):
            self.assertEqual(self.tree.run("batch", name)[0], 1, name)


if __name__ == "__main__":
    unittest.main()
