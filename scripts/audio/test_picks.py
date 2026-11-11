"""Tests for picks.py: the picks lines are rewritten and nothing else in the file changes."""
from __future__ import annotations

import difflib
import unittest
from pathlib import Path

import picks

ROOT: Path = Path(__file__).resolve().parents[2]

CUES: str = '''# a comment
[cue.a]
category = "melee"
prompt = """
[cue.b] not a header
"""
picks = []  # none yet

[cue.b]
category = "melee"
picks = [2]
'''

LINES: str = '''[line.one]
trigger = "select"
picks = {}

[line.two]
trigger = "move"
picks = { v1 = 1 }
'''


class CuePicksTest(unittest.TestCase):
    def test_picks_change_only_the_picks_lines(self) -> None:
        before = (ROOT / "audio-src" / "cues.toml").read_text(encoding="utf-8")
        after = picks.apply_cue_picks(before, {"swing_blade": [1, 4, 5], "swing_heavy": [2]})
        changed = [d for d in difflib.unified_diff(before.splitlines(), after.splitlines(), lineterm="", n=0) if d[0] in "+-" and d[:3] not in ("+++", "---")]
        self.assertEqual(len(changed), 4, changed)
        self.assertIn("+picks = [1, 4, 5]", changed)
        self.assertIn("+picks = [2]", changed)
        self.assertTrue(all("picks" in d for d in changed))

    def test_a_header_inside_a_multiline_string_is_not_a_table(self) -> None:
        out = picks.apply_cue_picks(CUES, {"a": [1, 3]})
        self.assertIn('picks = [1, 3]  # none yet\n\n[cue.b]', out)  # the comment after the value survives
        self.assertIn("picks = [2]\n", out)  # b untouched

    def test_other_bytes_survive_including_crlf(self) -> None:
        text = CUES.replace("\n", "\r\n")
        out = picks.apply_cue_picks(text, {"b": [1]})
        self.assertEqual(out, text.replace("picks = [2]", "picks = [1]"))

    def test_indent_and_trailing_comment_are_kept(self) -> None:
        text = '[cue.a]\n    picks = [ 1 ]   # keep me\n[cue.b]\npicks = [2]\n'
        self.assertEqual(picks.apply_cue_picks(text, {"a": [4, 5]}), '[cue.a]\n    picks = [4, 5]   # keep me\n[cue.b]\npicks = [2]\n')
        lines = '[line.a]\n\tpicks = { v = 1 } # c\n'
        self.assertEqual(picks.apply_line_picks(lines, {"a": {"v": 2}}), '[line.a]\n\tpicks = { v = 2 } # c\n')

    def test_a_picks_line_that_runs_over_lines_is_refused(self) -> None:
        with self.assertRaisesRegex(picks.PicksError, "one line"):
            picks.apply_cue_picks('[cue.a]\npicks = [\n  1,\n]\n', {"a": [2]})

    def test_an_empty_list_is_written_as_empty(self) -> None:
        self.assertIn("picks = []\n", picks.apply_cue_picks(CUES, {"b": []}))

    def test_a_table_without_a_picks_line_is_refused(self) -> None:
        with self.assertRaisesRegex(picks.PicksError, "no picks line"):
            picks.apply_cue_picks('[cue.a]\ncategory = "melee"\n', {"a": [1]})

    def test_an_unknown_table_is_refused(self) -> None:
        with self.assertRaisesRegex(picks.PicksError, "nope"):
            picks.apply_cue_picks(CUES, {"nope": [1]})

    def test_layers_use_their_own_table_name(self) -> None:
        out = picks.apply_cue_picks('[layer.x]\npicks = []\n', {"x": [2]}, table="layer")
        self.assertEqual(out, '[layer.x]\npicks = [2]\n')


class LinePicksTest(unittest.TestCase):
    def test_line_picks_use_the_inline_table_style(self) -> None:
        out = picks.apply_line_picks(LINES, {"one": {"shieldman_young": 1, "shieldman_old": 2}})
        self.assertIn("picks = { shieldman_old = 2, shieldman_young = 1 }\n", out)
        self.assertIn("picks = { v1 = 1 }\n", out)

    def test_an_empty_table_is_written_as_braces(self) -> None:
        self.assertIn("picks = {}\n", picks.apply_line_picks(LINES, {"two": {}}))

    def test_a_line_without_a_picks_line_is_refused(self) -> None:
        with self.assertRaisesRegex(picks.PicksError, "no picks line"):
            picks.apply_line_picks('[line.a]\ntrigger = "move"\n', {"a": {"v": 1}})


if __name__ == "__main__":
    unittest.main()
