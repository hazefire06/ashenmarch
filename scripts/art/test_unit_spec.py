"""Tests for unit_spec (recipe parsing) and clips.pick_clip."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from clips import pick_clip
from unit_spec import SpecError, load_spec, load_style

ART_SRC = Path(__file__).resolve().parent.parent.parent / "art-src"


class ShieldmanSpecTest(unittest.TestCase):
    def test_the_committed_recipe_parses(self) -> None:
        spec = load_spec(ART_SRC / "units" / "shieldman" / "spec.toml")
        self.assertEqual(spec.id, "shieldman")
        self.assertEqual(spec.action_ids(), [89, 97, 189, 219])
        names = [a.name for a in spec.animations]
        self.assertEqual(names, ["idle", "walk", "attack", "attack_alt", "die"])
        walk = spec.animations[1]
        self.assertEqual((walk.file, walk.action_id, walk.loop), ("anims/rig_walk.glb", None, True))
        attack = spec.animations[2]
        self.assertEqual((attack.file, attack.clip, attack.impact, attack.loop), ("anims/actions.glb", "Right_Hand_Sword_Slash", 0.45, False))

    def test_the_full_prompt_fits_meshy(self) -> None:
        spec = load_spec(ART_SRC / "units" / "shieldman" / "spec.toml")
        prompt = spec.full_prompt(load_style(ART_SRC / "style.toml"))
        self.assertLessEqual(len(prompt), 800)
        self.assertIn("warm tartan reds", prompt)


class SpecErrorsTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name) / "unit_x"
        self.dir.mkdir()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def spec(self, body: str) -> Path:
        path = self.dir / "spec.toml"
        path.write_text('id = "unit_x"\nfaction = "light"\nheight_m = 1.8\nprompt = "p"\n' + body)
        return path

    def test_an_action_needs_its_clip_name(self) -> None:
        with self.assertRaisesRegex(SpecError, "clip name"):
            load_spec(self.spec("[animations.attack]\naction = 4\n"))

    def test_an_animation_needs_a_source(self) -> None:
        with self.assertRaisesRegex(SpecError, "action, rig or file"):
            load_spec(self.spec("[animations.attack]\nimpact = 0.5\n"))

    def test_rig_clips_are_walk_or_run(self) -> None:
        with self.assertRaisesRegex(SpecError, "walk or run"):
            load_spec(self.spec('[animations.walk]\nrig = "crawl"\n'))

    def test_the_id_must_match_the_folder(self) -> None:
        path = self.dir / "spec.toml"
        path.write_text('id = "other"\nfaction = "light"\nheight_m = 1.8\nprompt = "p"\n[animations.idle]\nfile = "a.glb"\n')
        with self.assertRaisesRegex(SpecError, "folder"):
            load_spec(path)

    def test_a_long_prompt_is_refused(self) -> None:
        spec = load_spec(self.spec('[animations.idle]\nfile = "a.glb"\n'))
        style = load_style(ART_SRC / "style.toml")
        long_spec = spec.__class__(**{**spec.__dict__, "prompt": "x" * 800})
        with self.assertRaisesRegex(SpecError, "800"):
            long_spec.full_prompt(style)


class PickClipTest(unittest.TestCase):
    def test_exact_name_after_the_object_prefix_wins(self) -> None:
        names = ["Armature|Left_Slash_2", "Armature|Left_Slash"]
        self.assertEqual(pick_clip(names, "Left_Slash"), "Armature|Left_Slash")

    def test_a_unique_partial_match(self) -> None:
        self.assertEqual(pick_clip(["Armature|Animation_Combat_Stance_withSkin"], "Combat_Stance"), "Armature|Animation_Combat_Stance_withSkin")

    def test_no_or_many_matches_are_errors(self) -> None:
        with self.assertRaisesRegex(ValueError, "no clip"):
            pick_clip(["Armature|Idle"], "Left_Slash")
        with self.assertRaisesRegex(ValueError, "2 clips match"):
            pick_clip(["A|Idle_02", "A|Idle_03"], "Idle")

    def test_unnamed_means_the_only_clip(self) -> None:
        self.assertEqual(pick_clip(["A|Walk"], None), "A|Walk")
        self.assertIsNone(pick_clip([], None))
        with self.assertRaisesRegex(ValueError, "name one"):
            pick_clip(["A|Walk", "A|Run"], None)


if __name__ == "__main__":
    unittest.main()
