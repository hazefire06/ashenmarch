"""Tests for unit_spec (recipe parsing) and clips.pick_clip."""
from __future__ import annotations

import json
import math
import tempfile
import unittest
from pathlib import Path

from clips import pick_clip
from unit_spec import AttachEntry, PropSpec, SpecError, load_prop_spec, load_spec, load_style

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

    def test_the_shieldman_carries_a_sword_and_a_targe(self) -> None:
        # Offsets and rotations are tuned by eye with `make art-attach`, so only what carries what is pinned.
        spec = load_spec(ART_SRC / "units" / "shieldman" / "spec.toml")
        self.assertEqual([(a.prop, a.bone) for a in spec.attach], [("broadsword", "RightHand"), ("targe", "LeftForeArm")])
        for entry in spec.attach:
            self.assertTrue(all(math.isfinite(v) for v in entry.offset + entry.rotation), entry)

    def test_a_unit_is_previewed_in_an_a_pose(self) -> None:
        self.assertEqual(load_spec(ART_SRC / "units" / "shieldman" / "spec.toml").pose_mode, "a-pose")


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

    def test_the_height_must_be_a_finite_positive_number(self) -> None:
        for value in ("nan", "inf", "-inf", "-1", "0", "0.0", "true", "false", '"tall"', "1" + "0" * 400):
            with self.subTest(height_m=value):
                path = self.dir / "spec.toml"
                path.write_text(f'id = "unit_x"\nfaction = "light"\nheight_m = {value}\nprompt = "p"\n[animations.idle]\nfile = "a.glb"\n')
                with self.assertRaisesRegex(SpecError, "height_m must be"):
                    load_spec(path)

    def test_a_long_prompt_is_refused(self) -> None:
        spec = load_spec(self.spec('[animations.idle]\nfile = "a.glb"\n'))
        style = load_style(ART_SRC / "style.toml")
        long_spec = spec.__class__(**{**spec.__dict__, "prompt": "x" * 800})
        with self.assertRaisesRegex(SpecError, "800"):
            long_spec.full_prompt(style)


class AttachTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name) / "unit_x"
        self.dir.mkdir()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def spec(self, attach: str) -> Path:
        path = self.dir / "spec.toml"
        path.write_text('id = "unit_x"\nfaction = "light"\nheight_m = 1.8\nprompt = "p"\n' + attach + '[animations.idle]\nfile = "a.glb"\n')
        return path

    def test_attachments_parse_in_order_and_offsets_default_to_zero(self) -> None:
        spec = load_spec(self.spec(
            '[[attach]]\nprop = "broadsword"\nbone = "RightHand"\n'
            '[[attach]]\nprop = "targe"\nbone = "LeftForeArm"\noffset = [0.1, 0, -0.2]\nrotation = [90, 0.0, 180]\n'))
        self.assertEqual(spec.attach, (
            AttachEntry("broadsword", "RightHand", (0.0, 0.0, 0.0), (0.0, 0.0, 0.0)),
            AttachEntry("targe", "LeftForeArm", (0.1, 0.0, -0.2), (90.0, 0.0, 180.0)),
        ))

    def test_a_unit_with_no_attachments_has_an_empty_tuple(self) -> None:
        self.assertEqual(load_spec(self.spec("")).attach, ())

    def test_a_prop_name_that_could_leave_the_folder_is_refused(self) -> None:
        for name in ("../x", "/abs", "a/b", "Sword", "9x", "_x", "", "a" * 33, "x\n"):
            with self.subTest(prop=name):
                path = self.spec(f'[[attach]]\nprop = {json.dumps(name)}\nbone = "RightHand"\n')  # json's escapes are valid TOML
                with self.assertRaisesRegex(SpecError, "attach entry 1"):
                    load_spec(path)

    def test_a_missing_prop_or_bone_is_refused(self) -> None:
        with self.assertRaisesRegex(SpecError, "attach entry 1.*bone"):
            load_spec(self.spec('[[attach]]\nprop = "broadsword"\n'))
        with self.assertRaisesRegex(SpecError, "attach entry 1.*bone"):
            load_spec(self.spec('[[attach]]\nprop = "broadsword"\nbone = ""\n'))
        with self.assertRaisesRegex(SpecError, "attach entry 1.*prop"):
            load_spec(self.spec('[[attach]]\nbone = "RightHand"\n'))

    def test_a_huge_number_is_refused_not_an_overflow(self) -> None:
        huge = "1" + "0" * 400
        for key in ("offset", "rotation"):
            with self.subTest(key=key):
                path = self.spec(f'[[attach]]\nprop = "targe"\nbone = "LeftForeArm"\n{key} = [0, 0, {huge}]\n')
                with self.assertRaisesRegex(SpecError, f"{key} must be exactly 3 numbers"):
                    load_spec(path)

    def test_bone_names_are_plain_names(self) -> None:
        for bone in ("RightHand", "mixamorig:LeftForeArm", "Bone.001", "left-hand_2", "Left Hand", "a" * 63):
            with self.subTest(good=bone):
                self.assertEqual(load_spec(self.spec(f'[[attach]]\nprop = "targe"\nbone = "{bone}"\n')).attach[0].bone, bone)
        for bone in ("", " ", "   ", "a" * 64, "Right/Hand", "../x", "Hand\\n", "Hand\\tTab", "Hand;rm", "H\\u00e9", "[x]"):
            with self.subTest(bad=bone):
                with self.assertRaisesRegex(SpecError, "attach entry 1.*bone"):
                    load_spec(self.spec(f'[[attach]]\nprop = "targe"\nbone = "{bone}"\n'))

    def test_offset_and_rotation_are_exactly_three_numbers(self) -> None:
        for key in ("offset", "rotation"):
            for value in ("[0.0, 0.0]", "[0, 0, 0, 0]", '[0, 0, "x"]', "[0, 0, true]", "0.5", "[0, 0, inf]", "[0, 0, nan]"):
                with self.subTest(key=key, value=value):
                    path = self.spec(f'[[attach]]\nprop = "targe"\nbone = "LeftForeArm"\n{key} = {value}\n')
                    with self.assertRaisesRegex(SpecError, f"attach entry 1.*{key}"):
                        load_spec(path)

    def test_the_error_names_the_entry_that_is_wrong(self) -> None:
        path = self.spec('[[attach]]\nprop = "broadsword"\nbone = "RightHand"\n[[attach]]\nprop = "targe"\nbone = "LeftForeArm"\noffset = [1, 2]\n')
        with self.assertRaisesRegex(SpecError, r"attach entry 2 \('targe'\)") as caught:
            load_spec(path)
        self.assertIn(str(path), str(caught.exception))

    def test_a_misspelt_key_is_refused_instead_of_silently_zeroed(self) -> None:
        with self.assertRaisesRegex(SpecError, "attach entry 1.*rotaton"):
            load_spec(self.spec('[[attach]]\nprop = "targe"\nbone = "LeftForeArm"\nrotaton = [0, 90, 0]\n'))


class PropSpecTest(unittest.TestCase):
    GOOD = 'id = "prop_x"\nfaction = "light"\nlength_m = 0.95\nprompt = "a sword"\n[candidates]\nlite = 2\n'

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name) / "prop_x"
        self.dir.mkdir()
        self.style = load_style(ART_SRC / "style.toml")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def prop(self, text: str) -> Path:
        path = self.dir / "spec.toml"
        path.write_text(text)
        return path

    def test_a_good_recipe_loads_with_the_prop_defaults(self) -> None:
        spec = load_prop_spec(self.prop(self.GOOD))
        self.assertEqual(spec, PropSpec(id="prop_x", faction="light", length_m=0.95, prompt="a sword", lite=2, full=0, polycount=6000))

    def test_a_prop_is_previewed_without_a_pose(self) -> None:
        self.assertIsNone(load_prop_spec(self.prop(self.GOOD)).pose_mode)

    def test_the_candidates_table_is_optional(self) -> None:
        spec = load_prop_spec(self.prop('id = "prop_x"\nfaction = "dark"\nlength_m = 1\nprompt = "p"\n'))
        self.assertEqual((spec.lite, spec.full, spec.polycount, spec.length_m), (0, 0, 6000, 1.0))

    def test_the_id_must_match_the_folder(self) -> None:
        with self.assertRaisesRegex(SpecError, "folder"):
            load_prop_spec(self.prop(self.GOOD.replace('"prop_x"', '"other"', 1)))

    def test_the_length_must_be_positive(self) -> None:
        for length in ("0", "-0.5"):
            with self.subTest(length_m=length):
                path = self.prop(self.GOOD.replace("0.95", length))
                with self.assertRaisesRegex(SpecError, "length_m must be positive") as caught:
                    load_prop_spec(path)
                self.assertIn(str(path), str(caught.exception))

    def test_the_length_must_be_a_finite_number_not_a_bool(self) -> None:
        for value in ("nan", "inf", "-inf", "true", "false", '"long"', "1" + "0" * 400):
            with self.subTest(length_m=value):
                with self.assertRaisesRegex(SpecError, "length_m must be"):
                    load_prop_spec(self.prop(self.GOOD.replace("0.95", value)))

    def test_the_faction_is_light_or_dark(self) -> None:
        with self.assertRaisesRegex(SpecError, "faction must be light or dark"):
            load_prop_spec(self.prop(self.GOOD.replace('"light"', '"grey"')))

    def test_a_missing_key_is_reported_like_a_units(self) -> None:
        for key in ("id", "faction", "length_m", "prompt"):
            with self.subTest(missing=key):
                text = "".join(line + "\n" for line in self.GOOD.splitlines() if not line.startswith(key + " "))
                path = self.prop(text)
                with self.assertRaisesRegex(SpecError, f"missing '{key}'") as caught:
                    load_prop_spec(path)
                self.assertIn(str(path), str(caught.exception))

    def test_the_full_prompt_adds_the_palette_and_the_prop_suffix(self) -> None:
        spec = load_prop_spec(self.prop(self.GOOD))
        text = spec.full_prompt(self.style)
        self.assertEqual(text, f"a sword. Palette: {self.style.palettes['light']}. {self.style.prop_suffix}")
        self.assertNotIn(self.style.suffix, text)

    def test_a_long_prop_prompt_is_refused(self) -> None:
        spec = load_prop_spec(self.prop(self.GOOD))
        long_spec = spec.__class__(**{**spec.__dict__, "prompt": "x" * 800})
        with self.assertRaisesRegex(SpecError, "prop_x: the prompt is .* 800"):
            long_spec.full_prompt(self.style)

    def test_the_committed_prop_recipes_parse(self) -> None:
        sword = load_prop_spec(ART_SRC / "props" / "broadsword" / "spec.toml")
        targe = load_prop_spec(ART_SRC / "props" / "targe" / "spec.toml")
        self.assertEqual((sword.id, sword.faction, sword.length_m, sword.lite, sword.full, sword.polycount), ("broadsword", "light", 0.95, 2, 0, 6000))
        self.assertEqual((targe.id, targe.faction, targe.length_m, targe.lite, targe.full, targe.polycount), ("targe", "light", 0.55, 2, 0, 6000))
        for spec in (sword, targe):
            self.assertLessEqual(len(spec.full_prompt(self.style)), 800)
            self.assertIsNone(spec.pose_mode)


class StyleTest(unittest.TestCase):
    def test_the_committed_style_has_a_prop_suffix(self) -> None:
        style = load_style(ART_SRC / "style.toml")
        self.assertTrue(style.prop_suffix.startswith("Stylized fantasy strategy-game prop"))
        self.assertIn("no hands or figure", style.prop_suffix)
        self.assertNotIn("A-pose", style.prop_suffix)

    def test_a_style_without_a_prop_suffix_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "style.toml"
            path.write_text('suffix = "s"\n[palettes]\nlight = "l"\ndark = "d"\n')
            with self.assertRaisesRegex(SpecError, "missing 'prop_suffix'"):
                load_style(path)


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
