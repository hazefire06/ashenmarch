"""Tests for licences.py: the audio block of LICENSES.md."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import licences
from assets import Asset
from cuebook import CueError

LICENSES_TEXT: str = "# Licenses\n\n| File | Source |\n|---|---|\n| `a` | b |\n"


class LicenceBlockTest(unittest.TestCase):
    def test_the_licence_block_is_replaced_and_the_rest_kept(self) -> None:
        before = "# L\n\n| a |\n\n<!-- audio:begin -->\nold rows\n<!-- audio:end -->\n\ntail text\n"
        out = licences.update_licences(before, ["| `x.wav` | s | t | d | m |"])
        self.assertTrue(out.startswith("# L\n\n| a |\n\n<!-- audio:begin -->\n"))
        self.assertTrue(out.endswith("<!-- audio:end -->\n\ntail text\n"))
        self.assertIn("| `x.wav` | s | t | d | m |", out)
        self.assertNotIn("old rows", out)
        self.assertEqual(licences.update_licences(out, ["| `x.wav` | s | t | d | m |"]), out)  # stable

    def test_markers_are_added_after_the_existing_rows(self) -> None:
        out = licences.update_licences(LICENSES_TEXT, [])
        self.assertTrue(out.startswith(LICENSES_TEXT))
        self.assertEqual(out[len(LICENSES_TEXT):], "\n<!-- audio:begin -->\n<!-- audio:end -->\n")

    def test_a_lone_marker_is_refused(self) -> None:
        with self.assertRaisesRegex(CueError, "markers"):
            licences.update_licences("x\n<!-- audio:end -->\n<!-- audio:begin -->\n", [])


class UnreadableManifestTest(unittest.TestCase):
    def test_a_garbled_deep_or_oddly_shaped_manifest_is_refused_with_a_message(self) -> None:
        # L8: RecursionError and a tasks value that isn't a list used to escape as a traceback, or read as no records.
        asset = Asset("oneshot", "assets/audio/sfx/hit_1.wav", Path(__file__), "cue hit take 1", "hit", ("sfx", "sfx/hit/1"))
        for text in ("[" * 200000, '{"tasks": 3}', '{"tasks": {"a": 1}}', "[]", "null", '{"tasks": [1]}', "{", '{"tasks": [' + '{"a": ' * 5000,
                     '{"tasks": [{"kind": "sfx", "label": "sfx/hit/1", "status": "DONE", "model": "m"}, '
                     '{"kind": "sfx", "label": "sfx/hit/1", "status": "FAILED"}]}'):
            with self.subTest(text=text[:20]), tempfile.TemporaryDirectory() as tmp:
                manifest = Path(tmp) / "manifest.json"
                manifest.write_text(text)
                with self.assertRaises(CueError) as caught:
                    licences.licence_rows([asset], manifest)
                self.assertIn("manifest.json", str(caught.exception))
                self.assertNotIn(tmp, str(caught.exception))


class RowsTest(unittest.TestCase):
    def test_rows_name_the_model_and_end_with_the_import_note(self) -> None:
        asset = Asset("oneshot", "assets/audio/sfx/hit_1.wav", Path(__file__), "cue hit take 1", "hit", ("sfx", "sfx/hit/1"))
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / "manifest.json"
            manifest.write_text(json.dumps({"tasks": [{"kind": "sfx", "label": "sfx/hit/1", "status": "DONE", "model": "eleven_text_to_sound_v2"}]}))
            rows = licences.licence_rows([asset], manifest)
        self.assertEqual(len(rows), 2)
        self.assertIn("ElevenLabs sound-generation (eleven_text_to_sound_v2)", rows[0])
        self.assertIn("`assets/audio/**/*.import`", rows[1])
        self.assertEqual(licences.licence_rows([], Path("/nonexistent")), [])

    def test_no_row_without_a_done_record_with_a_model(self) -> None:
        asset = Asset("oneshot", "assets/audio/sfx/hit_1.wav", Path(__file__), "cue hit take 1", "hit", ("sfx", "sfx/hit/1"))
        bad = ({}, {"tasks": []}, {"tasks": [{"kind": "sfx", "label": "sfx/hit/1", "status": "DONE"}]},
               {"tasks": [{"kind": "sfx", "label": "sfx/hit/1", "status": "FAILED", "model": "m"}]})
        for data in bad:
            with self.subTest(data=data), tempfile.TemporaryDirectory() as tmp:
                manifest = Path(tmp) / "manifest.json"
                manifest.write_text(json.dumps(data))
                with self.assertRaisesRegex(CueError, "no DONE purchase record"):
                    licences.licence_rows([asset], manifest)
        with self.assertRaisesRegex(CueError, "no DONE purchase record"):
            licences.licence_rows([asset], Path("/nonexistent/manifest.json"))


if __name__ == "__main__":
    unittest.main()
