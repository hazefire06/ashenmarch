"""Tests for process.py build: the sidecar the bank builder reads."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import process
from test_cuebook import HEAD

MUSIC: str = """
[layer.riverside_calm]
prompt = "a drone"
length_s = 110
model = "music_v2"
takes = 3
picks = []
"""


def cue(name: str, category: str, extra: str = "") -> str:
    loop = 'loop = true\nmodel = "eleven_text_to_sound_v3"\n' if category in ("bed", "march") else ""
    return f'\n[cue.{name}]\ncategory = "{category}"\nprompt = "p"\nduration_s = 1.0\n{loop}{extra}\n'


def sidecar_of(book: str, music: str = MUSIC, files: tuple[str, ...] = ()) -> dict[str, dict[str, object]]:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for rel in files:
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_bytes(b"x")
        (root / "cues.toml").write_text(HEAD + book, encoding="utf-8")
        (root / "prompts.toml").write_text(music, encoding="utf-8")
        built = process.build_sidecar(root / "cues.toml", root / "prompts.toml", root)
        return {str(c["id"]): c for c in built["cues"]}  # type: ignore[union-attr]


class BuildTest(unittest.TestCase):
    def test_build_uses_picks_else_the_placeholder_else_nothing(self) -> None:
        book = (
            cue("hit_a", "melee", 'placeholder = "res://assets/audio/sfx/sword_hit.wav"')
            + cue("hit_b", "melee")
            + cue("hit_c", "melee", "takes = 6\npicks = [2, 5]")
        )
        cues = sidecar_of(book, files=("assets/audio/sfx/hit_c_2.wav", "assets/audio/sfx/hit_c_5.wav"))
        self.assertEqual(cues["hit_a"]["files"], ["res://assets/audio/sfx/sword_hit.wav"])
        self.assertEqual(cues["hit_b"]["files"], [])
        self.assertEqual(cues["hit_c"]["files"], [
            "res://assets/audio/sfx/hit_c_2.wav", "res://assets/audio/sfx/hit_c_5.wav"])

    def test_a_picked_loop_is_one_ogg(self) -> None:
        cues = sidecar_of(cue("bed_x", "bed", "variants = 1\ntakes = 2\npicks = [1]"), files=("assets/audio/loop/bed_x.ogg",))
        self.assertEqual(cues["bed_x"]["files"], ["res://assets/audio/loop/bed_x.ogg"])

    def test_a_missing_picked_file_is_refused_by_name(self) -> None:
        with self.assertRaisesRegex(Exception, "hit_c"):
            sidecar_of(cue("hit_c", "melee", "picks = [1]"))

    def test_the_sidecar_carries_each_cues_playback_by_category(self) -> None:
        cues = sidecar_of(cue("bed_rain", "bed") + cue("hit_flesh", "melee"))
        self.assertEqual(cues["bed_rain"]["playback"], "stream")
        self.assertEqual(cues["hit_flesh"]["playback"], "sample")
        self.assertEqual(cues["hit_flesh"]["bus"], "Effects")
        self.assertEqual(cues["hit_flesh"]["loop"], False)

    def test_music_layers_become_music_cues(self) -> None:
        cues = sidecar_of(cue("hit_a", "melee"))
        music = cues["music_riverside_calm"]
        self.assertEqual((music["category"], music["bus"], music["loop"], music["playback"]),
                         ("music", "Music", True, "stream"))
        self.assertEqual(music["files"], [])

    def test_the_committed_book_builds_with_a_file_for_every_placeholder(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "bank.json"
            self.assertEqual(process.build(out), 0)
            data = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(len(data["cues"]), 66)
        self.assertEqual(data["lines"], [])


if __name__ == "__main__":
    unittest.main()
