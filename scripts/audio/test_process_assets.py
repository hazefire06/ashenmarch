"""Tests for process.py batch, picks and build, on a temp tree. Nothing here touches the real cues, raw takes or assets."""
from __future__ import annotations

import contextlib
import datetime
import hashlib
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

import assets
import ffmpeg_io
import ledger
import licences
import process
from ffmpeg_io import AudioError
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
        self.records: dict[tuple[str, str], dict[str, object]] = {}  # the DONE record generate.py would have written for each raw file
        self.cues = src / "cues.toml"
        self.layers = src / "music" / "prompts.toml"
        self.voices = src / "voices"
        self.cues.write_text(BOOK, encoding="utf-8")
        self.layers.write_text(MUSIC, encoding="utf-8")
        (self.voices / "reaver.toml").write_text(VOICE, encoding="utf-8")
        (self.voices / "_clan.toml").write_text(CLAN, encoding="utf-8")
        self.licences = self.root / "assets" / "LICENSES.md"
        self.licences.write_text(LICENSES, encoding="utf-8")
        # The purchase ledger lives in the temp tree: no test may create or touch the real ~/.local/share/ashenmarch.
        self.ledger_path = self.root / "share" / "ashenmarch" / "purchases.jsonl"
        self._ledger_patch = mock.patch.object(ledger, "LEDGER", self.ledger_path)
        self._ledger_patch.start()

    def raw(self, rel: str, frames: array | None = None, channels: int = 1) -> Path:
        path = self.root / "audio-src" / "raw" / rel
        ffmpeg_io.write_wav(frames if frames is not None else tone(0.5), RATE, channels, path)
        label = rel.rsplit(".", 1)[0]
        data = path.read_bytes()
        self.records[(label.split("/", 1)[0], label)] = {
            "kind": label.split("/", 1)[0], "label": label, "model": "eleven_text_to_sound_v2", "status": "DONE", "files": [rel],
            "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
        self.manifest([])
        ledger.append({"kind": label.split("/", 1)[0], "label": label, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
        return path

    def manifest(self, tasks: list[dict[str, object]]) -> None:
        """Writes the manifest: a record for every raw file made so far, with these records laid over them."""
        for task in tasks:
            key = (str(task["kind"]), str(task["label"]))
            self.records[key] = {**self.records.get(key, {}), **task}
        (self.root / "audio-src" / "manifest.json").write_text(json.dumps({"tasks": list(self.records.values())}), encoding="utf-8")

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
        self._ledger_patch.stop()
        self._tmp.cleanup()


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

    def test_a_symlinked_licences_file_or_build_folder_stops_the_build(self) -> None:
        (self.tree.root / "elsewhere.md").write_text("x", encoding="utf-8")
        self.tree.licences.unlink()
        os.symlink(self.tree.root / "elsewhere.md", self.tree.licences)
        code, _, err = self.tree.build()
        self.assertEqual((code, "symlink" in err), (1, True))
        self.tree.licences.unlink()
        self.tree.licences.write_text(LICENSES, encoding="utf-8")
        (self.tree.root / "real").mkdir()
        os.symlink(self.tree.root / "real", self.tree.root / "audio-src" / "build")
        code, _, err = self.tree.build()
        self.assertEqual((code, "symlink" in err), (1, True))
        self.assertEqual(list((self.tree.root / "real").iterdir()), [])

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


class PurchaseProofTest(unittest.TestCase):
    """M3: a raw file is used only if a DONE record lists it with a matching hash, so a planted or swapped file buys nothing."""

    def setUp(self) -> None:
        self.tree = Tree()
        self.addCleanup(self.tree.close)
        self.tree.raw("sfx/hit_a/1.wav")
        self.tree.set_picks({"hit_a": "[1]"})

    def test_a_file_with_no_record_is_refused_by_build_and_batch(self) -> None:
        (self.tree.root / "audio-src" / "manifest.json").unlink()
        before = self.tree.snapshot()
        code, _, err = self.tree.build()
        self.assertEqual(code, 1)
        self.assertIn("no DONE purchase record", err)
        self.assertEqual(self.tree.snapshot(), before)
        code, _, err = self.tree.run("batch", "melee")
        self.assertEqual(code, 1)
        self.assertIn("no DONE purchase record", err)
        self.assertFalse((self.tree.root / "audio-src" / "audition").exists())

    def test_a_swapped_file_is_refused_by_build_and_batch(self) -> None:
        ffmpeg_io.write_wav(tone(0.7, freq=900), RATE, 1, self.tree.root / "audio-src" / "raw" / "sfx" / "hit_a" / "1.wav")  # not what was bought
        for code, _, err in (self.tree.build(), self.tree.run("batch", "melee")):
            self.assertEqual(code, 1)
            self.assertIn("hash differs", err)
        self.assertFalse((self.tree.root / "assets" / "audio").exists())

    def test_a_record_that_is_not_done_or_does_not_list_the_file_is_refused(self) -> None:
        for change in ({"status": "INTERRUPTED"}, {"files": ["sfx/hit_a/2.wav"]}, {"sha256": None}, {"bytes": 1}):
            with self.subTest(change=change):
                self.tree.manifest([{"kind": "sfx", "label": "sfx/hit_a/1", **change}])
                code, _, err = self.tree.build()
                self.assertEqual(code, 1)
                self.assertIn("raw/sfx/hit_a/1.wav", err)
                self.tree.raw("sfx/hit_a/1.wav")  # puts the true record back

    def test_a_manifest_with_two_records_for_one_label_is_refused(self) -> None:
        record = self.tree.records[("sfx", "sfx/hit_a/1")]
        (self.tree.root / "audio-src" / "manifest.json").write_text(json.dumps({"tasks": [{**record, "status": "FAILED"}, record]}), encoding="utf-8")
        code, _, err = self.tree.build()
        self.assertEqual(code, 1)
        self.assertIn("two records", err)

    def test_a_forged_record_with_a_matching_hash_but_no_ledger_line_is_refused(self) -> None:
        # Low-3: manifest.json is committed, so a PR can forge a DONE record for a planted file. The ledger is outside the repo.
        self.tree.ledger_path.write_text("")
        before = self.tree.snapshot()
        code, _, err = self.tree.build()
        self.assertEqual(code, 1)
        self.assertIn("purchase ledger", err)
        self.assertIn("no line for it", err)
        self.assertEqual(self.tree.snapshot(), before)
        code, _, err = self.tree.run("batch", "melee")
        self.assertEqual(code, 1)
        self.assertIn("no line for it", err)

    def test_a_ledger_line_for_another_hash_or_size_does_not_count(self) -> None:
        line = json.loads(self.tree.ledger_path.read_text().splitlines()[0])
        for change in ({"sha256": "0" * 64}, {"bytes": line["bytes"] + 1}, {"label": "sfx/hit_a/2"}, {"kind": "music"}):
            with self.subTest(change=change):
                self.tree.ledger_path.write_text(json.dumps({**line, **change}) + "\n")
                self.assertEqual(self.tree.build()[0], 1)

    def test_a_missing_ledger_is_a_clear_refusal(self) -> None:
        self.tree.ledger_path.unlink()
        for code, _, err in (self.tree.build(), self.tree.run("batch", "melee")):
            self.assertEqual(code, 1)
            self.assertIn("no purchase ledger at", err)
            self.assertIn("on this Mac", err)

    def test_a_ledger_line_that_does_not_parse_is_an_error(self) -> None:
        self.tree.ledger_path.write_text(self.tree.ledger_path.read_text() + "garbage\n")
        code, _, err = self.tree.build()
        self.assertEqual(code, 1)
        self.assertIn("line 2 of the purchase ledger", err)

    def test_a_tree_with_nothing_to_verify_needs_no_ledger(self) -> None:
        empty = Tree()  # a raw file exists but nothing is picked, so nothing is verified
        self.addCleanup(empty.close)
        empty.raw("sfx/hit_a/1.wav")
        empty.ledger_path.unlink()
        self.assertEqual(empty.build()[0], 0)

    def test_a_symlinked_ledger_folder_is_refused(self) -> None:
        elsewhere = self.tree.root / "elsewhere"
        elsewhere.mkdir()
        shutil.copy(self.tree.ledger_path, elsewhere / "purchases.jsonl")
        shutil.rmtree(self.tree.ledger_path.parent)
        os.symlink(elsewhere, self.tree.ledger_path.parent)
        code, _, err = self.tree.build()
        self.assertEqual(code, 1)
        self.assertIn("symlink", err)

    def test_a_symlinked_ledger_file_is_refused(self) -> None:
        real = self.tree.root / "real.jsonl"
        shutil.move(str(self.tree.ledger_path), str(real))
        os.symlink(real, self.tree.ledger_path)
        self.assertEqual(self.tree.build()[0], 1)

    def test_the_licence_row_needs_the_record(self) -> None:
        asset = assets.plan_assets(self.tree.cues, self.tree.layers, self.tree.voices, self.tree.root)[0]
        with self.assertRaisesRegex(Exception, "no DONE purchase record with a model"):
            licences.licence_rows([asset], self.tree.root / "nowhere.json")


class PlantedNamesTest(unittest.TestCase):
    """Low-2: a file name from a public repo reaches messages, so no raw control byte may."""

    def setUp(self) -> None:
        self.tree = Tree()
        self.addCleanup(self.tree.close)

    def assert_clean(self, *texts: str) -> None:
        for text in texts:
            for c in text:
                self.assertTrue(c.isprintable() or c == "\n", repr(c))

    def test_an_orphan_with_escape_bytes_in_its_name_is_listed_escaped(self) -> None:
        orphan = self.tree.root / "assets" / "audio" / "sfx" / "\x1b[2J\x07old.wav"
        orphan.parent.mkdir(parents=True)
        orphan.write_bytes(b"x")
        code, out, err = self.tree.build()
        self.assertEqual(code, 0)
        self.assertIn("orphaned:", out)
        self.assertIn("\\x1b", out)
        self.assert_clean(out, err)

    def test_an_orphan_name_cannot_fake_a_line_of_output(self) -> None:
        orphan = self.tree.root / "assets" / "audio" / "sfx" / "x\nwrote LICENSES.md (0 audio rows).wav"
        orphan.parent.mkdir(parents=True)
        orphan.write_bytes(b"x")
        code, out, err = self.tree.build()
        self.assertEqual(code, 0)
        self.assertIn("sfx/x\\nwrote LICENSES.md", out)
        self.assertFalse([line for line in out.splitlines() if line.startswith("wrote LICENSES.md")])

    def test_a_bug_in_main_is_reported_through_emit_and_ctrl_c_is_not_swallowed(self) -> None:
        err = io.StringIO()
        with mock.patch.object(process, "build", side_effect=RuntimeError("boom\x1b[2J\nfake")), contextlib.redirect_stderr(err):
            self.assertEqual(process.main(["build"]), 1)
        self.assertIn("process.py build: unexpected RuntimeError: boom", err.getvalue())
        self.assertNotIn("Traceback", err.getvalue())
        self.assertNotIn("\x1b", err.getvalue())
        self.assertEqual(err.getvalue().count("\n"), 1)
        with mock.patch.object(process, "build", side_effect=KeyboardInterrupt), self.assertRaises(KeyboardInterrupt):
            process.main(["build"])

    def test_a_symlink_with_escape_bytes_in_its_name_is_reported_escaped(self) -> None:
        folder = self.tree.root / "assets" / "audio" / "sfx"
        folder.mkdir(parents=True)
        os.symlink(self.tree.root, folder / "\x1b[31mtrap")
        code, out, err = self.tree.build()
        self.assertEqual(code, 1)
        self.assertIn("symlink", err)
        self.assert_clean(out, err)

    def test_a_voice_file_with_escape_bytes_in_its_name_stops_build_batch_and_picks(self) -> None:
        (self.tree.voices / "\x1b[2Jevil.toml").write_text('unit = "x"\n', encoding="utf-8")
        picks = self.tree.write_picks({"batch": "melee", "cues": {"hit_a": [1]}})
        for code, out, err in (self.tree.build(), self.tree.run("batch", "melee"), self.tree.run("picks_file", picks)):
            self.assertEqual(code, 1)
            self.assert_clean(out, err)


@unittest.skipUnless(HAS_TOOLS, "ffmpeg and oggenc needed")
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

    def test_a_missing_or_hostile_picks_file_gets_its_own_message(self) -> None:
        code, _, err = self.tree.run("picks_file", self.tree.root / "nope.json")
        self.assertEqual(code, 1)
        self.assertIn("doesn't exist", err)
        deep = self.tree.root / "deep.json"
        deep.write_text("[" * 200000, encoding="utf-8")
        code, _, err = self.tree.run("picks_file", deep)
        self.assertEqual(code, 1)
        self.assertIn("JSON", err)

    def test_a_symlinked_toml_file_stops_picks(self) -> None:
        real = self.tree.root / "real_cues.toml"
        real.write_text(self.tree.cues.read_text(), encoding="utf-8")
        self.tree.cues.unlink()
        os.symlink(real, self.tree.cues)
        code, _, err = self.picks({"batch": "melee", "cues": {"hit_a": [1]}})
        self.assertEqual((code, "symlink" in err), (1, True))
        self.assertNotIn("picks = [1]", real.read_text())

    def test_a_huge_design_pick_is_refused_before_any_path_lookup(self) -> None:
        for n in (0, 31, 10**30):
            with mock.patch.object(process.picks_mod, "find_raw", side_effect=AssertionError("looked up")):
                self.assertEqual(self.picks({"batch": "design-reaver", "design": {"reaver": n}})[0], 1)

    def test_a_design_pick_can_be_as_high_as_three_rounds_of_ten_previews(self) -> None:
        self.tree.raw("design/reaver/reaver/30.wav", tone(1.0))
        code, out, _ = self.picks({"batch": "design-reaver", "design": {"reaver": 30}})
        self.assertEqual(code, 0)
        self.assertIn("--pick 30", out)
        self.assertEqual(self.picks({"batch": "design-reaver", "design": {"reaver": 31}})[0], 1)

    def test_picks_are_staged_before_any_target_is_replaced(self) -> None:
        # L8: two files change together. If the second can't be staged, the first must not have been replaced.
        part = self.tree.layers.with_name(self.tree.layers.name + ".part")
        victim = self.tree.root / "victim.txt"
        victim.write_text("keep me")
        os.symlink(victim, part)  # O_NOFOLLOW refuses it
        cues_before, layers_before = self.tree.cues.read_bytes(), self.tree.layers.read_bytes()
        code, _, err = self.picks({"batch": "x", "cues": {"hit_a": [1], "calm": [2]}})
        self.assertEqual(code, 1)
        self.assertIn("nothing written", err)
        self.assertEqual((self.tree.cues.read_bytes(), self.tree.layers.read_bytes()), (cues_before, layers_before))
        self.assertEqual(victim.read_text(), "keep me")
        self.assertFalse(self.tree.cues.with_name("cues.toml.part").exists())

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
        self.assertAlmostEqual(calm / 2 / RATE, 2.0, delta=0.15)  # cut to the 3 s layer, then 1 s lost to the loop crossfade
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

    def mtimes(self) -> dict[str, int]:
        return {str(p.relative_to(self.tree.root)): p.stat().st_mtime_ns for p in (self.tree.root / "assets" / "audio").rglob("*") if p.suffix in (".ogg", ".wav")}

    def pick_layer(self, layer: str, take: int) -> None:
        file = self.tree.layers
        head, _, rest = file.read_text().partition(f"[layer.{layer}]")
        before, _, after = rest.partition("picks = ")
        _, _, tail = after.partition("\n")
        file.write_text(head + f"[layer.{layer}]" + before + f"picks = [{take}]\n" + tail)

    def test_a_second_build_rewrites_no_audio_and_force_does(self) -> None:
        self.assertEqual(self.tree.build()[0], 0)
        first = self.mtimes()
        self.assertEqual(self.tree.build()[0], 0)
        self.assertEqual(self.mtimes(), first)
        self.assertEqual(self.tree.build(force=True)[0], 0)
        again = self.mtimes()
        self.assertTrue(all(again[k] > first[k] for k in first), (first, again))

    def test_repicking_a_loop_a_bark_or_music_rerenders_it(self) -> None:
        t = self.tree
        self.assertEqual(t.build()[0], 0)
        first = self.mtimes()
        t.raw("sfx/bed_x/3.wav", tone(3.5, freq=220, channels=2, lead_s=0), channels=2)
        cues = t.cues.read_text().replace("picks = [2]", "picks = [3]")
        t.cues.write_text(cues)
        t.raw("voices/reaver/attack_1/1.wav", tone(1.5, freq=200, amp=0.05))
        (t.voices / "reaver.toml").write_text(VOICE.replace("picks = {}", "picks = { reaver = 1 }"), encoding="utf-8")
        t.raw("music/calm/2.wav", tone(4.0, freq=300, lead_s=0, channels=2), channels=2)
        self.pick_layer("calm", 2)
        self.assertEqual(t.build()[0], 0)
        now = self.mtimes()
        for rel in ("assets/audio/loop/bed_x.ogg", "assets/audio/voice/reaver/attack_1.ogg", "assets/audio/music/calm.ogg", "assets/audio/music/war.ogg"):
            self.assertGreater(now[rel], first[rel], rel)  # music goes together
        for rel in ("assets/audio/sfx/hit_a_1.wav", "assets/audio/sfx/hit_a_3.wav"):
            self.assertEqual(now[rel], first[rel], rel)

    def test_changing_a_processing_constant_rerenders(self) -> None:
        self.assertEqual(self.tree.build()[0], 0)
        first = self.mtimes()
        with mock.patch.object(assets, "BARK_LUFS", -20.0):
            self.assertEqual(self.tree.build()[0], 0)
        now = self.mtimes()
        self.assertGreater(now["assets/audio/voice/reaver/attack_1.ogg"], first["assets/audio/voice/reaver/attack_1.ogg"])

    def test_a_killed_encode_leaves_no_finished_looking_file(self) -> None:
        real = ffmpeg_io.write_ogg
        def die(frames: array, rate: int, channels: int, path: Path, quality: int = 5) -> None:
            Path(str(path) + ".part").write_bytes(b"half")
            raise AudioError("killed")
        with mock.patch.object(ffmpeg_io, "write_ogg", die):
            code, _, err = self.tree.build()
        self.assertEqual(code, 1)
        self.assertFalse((self.tree.root / "assets" / "audio" / "loop" / "bed_x.ogg").exists())
        self.assertEqual(self.tree.build()[0], 0)  # the next run builds it
        self.assertTrue((self.tree.root / "assets" / "audio" / "loop" / "bed_x.ogg").is_file())
        self.assertIs(ffmpeg_io.write_ogg, real)

    def test_music_layers_are_one_length_and_loop_seamlessly(self) -> None:
        written: dict[str, array] = {}
        def capture(frames: array, rate: int, channels: int, path: Path, quality: int = 5) -> None:
            written[path.name] = frames
        todo = [a for a in assets.plan_assets(self.tree.cues, self.tree.layers, self.tree.voices, self.tree.root) if a.kind == "music"]
        with mock.patch.object(ffmpeg_io, "write_ogg", capture):
            assets.render_assets(todo, self.tree.root, {})
        calm, war = written["calm.ogg"], written["war.ogg"]
        self.assertEqual(len(calm), len(war))
        self.assertAlmostEqual(len(calm) / 2 / RATE, 2.0, delta=0.05)
        for frames in (calm, war):
            step = max(abs(frames[i + 2] - frames[i]) for i in range(0, len(frames) - 2, 2))
            self.assertLessEqual(abs(frames[0] - frames[-2]), step + 1)

    def test_mismatched_music_layers_are_refused_before_any_write(self) -> None:
        t = self.tree
        t.root.joinpath("audio-src", "raw", "music", "war", "2.wav").unlink()
        t.raw("music/war/2.wav", tone(3.0, lead_s=0))  # mono, calm is stereo
        before = t.snapshot()
        code, _, err = t.build()
        self.assertEqual(code, 1)
        self.assertIn("music layers", err)
        self.assertFalse((t.root / "assets" / "audio").exists())
        self.assertEqual(t.snapshot(), before)

    def test_orphaned_files_are_reported_not_deleted(self) -> None:
        stray = self.tree.root / "assets" / "audio" / "sfx" / "old_9.wav"
        stray.parent.mkdir(parents=True)
        stray.write_bytes(b"x")
        code, out, _ = self.tree.build()
        self.assertEqual(code, 0)
        self.assertIn("orphaned: assets/audio/sfx/old_9.wav", out)
        self.assertNotIn("orphaned: assets/audio/loop", out)
        self.assertTrue(stray.exists())

    def test_an_import_file_without_a_final_newline_is_fixed_cleanly(self) -> None:
        wav = self.tree.root / "x.wav"
        wav.write_bytes(b"")
        imp = self.tree.root / "x.wav.import"
        imp.write_text("[remap]\n\n[params]\n\ncompress/mode=1", encoding="utf-8")
        self.assertTrue(assets.ensure_import(wav, assets.WAV_PARAMS))
        self.assertEqual(imp.read_text(), "[remap]\n\n[params]\n\ncompress/mode=2\nedit/loop_mode=0\n")

    def test_build_writes_the_licence_rows_and_the_sidecar(self) -> None:
        self.assertEqual(self.tree.build()[0], 0)
        text = self.tree.licences.read_text()
        self.assertTrue(text.startswith(LICENSES))
        block = text[text.index("<!-- audio:begin -->"):text.index("<!-- audio:end -->")]
        self.assertEqual(block.count("| `assets/audio/"), 7)  # six files and the note on their .import files
        self.assertIn("`assets/audio/**/*.import`", block)
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
        self.assertEqual(empty.licences.read_text(), licences.update_licences(LICENSES, []))
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

    def test_loop_and_music_pages_allow_one_take_and_music_says_it_is_not_looped(self) -> None:
        for name, single in (("loops", "true"), ("music", "true"), ("melee", "false")):
            self.assertEqual(self.tree.run("batch", name)[0], 0, name)
            self.assertIn(f'data-single="{single}"', self.page(name), name)
        self.assertIn("aren&#x27;t looped yet", self.page("music"))
        self.assertNotIn("looped yet", self.page("melee"))

    def test_a_single_loop_category_is_a_batch_too(self) -> None:
        self.assertEqual(self.tree.run("batch", "bed")[0], 0)
        self.assertEqual(self.tree.run("batch", "march")[0], 1)  # no takes of it

    def test_an_unknown_batch_or_one_with_no_takes_is_refused(self) -> None:
        for name in ("nope", "voices-nobody", "design-../x", "groan"):
            self.assertEqual(self.tree.run("batch", name)[0], 1, name)


if __name__ == "__main__":
    unittest.main()
