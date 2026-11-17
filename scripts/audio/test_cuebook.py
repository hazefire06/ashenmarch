"""Tests for cuebook.py: the committed book against the spec, and every refusal."""
from __future__ import annotations

import json
import re
import tempfile
import unittest
from pathlib import Path

import cuebook
from cuebook import CueError

ROOT: Path = Path(__file__).resolve().parents[2]

SPEC_CUES: frozenset[str] = frozenset(
    # melee (10)
    "swing_blade swing_heavy swing_staff swing_claw swing_stomp hit_flesh hit_dry block_shield heal heal_sear "
    # projectile (22)
    "bow_release bow_release_fire throw_bottle throw_herb throw_heavy lightning_charge arrow_thunk arrow_splash "
    "arrow_flesh thud_flesh bottle_clink explosion_small explosion_large explosion_water gas_burst fizzle_hiss "
    "fizzle_water satchel_thud fire_whoomp grab thunder gas_release "
    # death (11)
    "death_shieldman death_reaver death_longbow death_sapper death_warden death_villager death_husk death_ripper "
    "death_blightbag death_drifter death_stormcaller "
    # groan (5)
    "groan_husk groan_ripper groan_blightbag groan_drifter groan_stormcaller "
    # ui (6)
    "ui_click ui_select ui_formation ui_group ui_deny order_ack "
    # march (4 loops) and bed (6 loops)
    "march_grass march_sand march_rock march_water "
    "bed_outdoor bed_rain bed_snow bed_fire bed_water bed_gas".split()
)

HEAD: str = """
[style]
suffix = "close foley"
vocal_suffix = "close wordless cry"

[defaults]
variants = 3
takes = 6
bus = "Effects"
level_db = 0.0
max_voices = 3
pitch_spread = 0.06
model = "eleven_text_to_sound_v2"
prompt_influence = 0.5

[playback]
melee = "sample"
projectile = "sample"
death = "sample"
groan = "sample"
ui = "sample"
march = "stream"
bed = "stream"
music = "stream"
"""

GOOD_CUE: str = """
[cue.swing_blade]
category = "melee"
prompt = "a steel blade cuts the air"
duration_s = 1.0
"""


def book_from(text: str) -> cuebook.CueBook:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "cues.toml"
        path.write_text(text, encoding="utf-8")
        return cuebook.load_cues(path)


def layers_from(text: str) -> dict[str, cuebook.Layer]:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "prompts.toml"
        path.write_text(text, encoding="utf-8")
        return cuebook.load_layers(path)


def cue_with(extra: str, name: str = "swing_blade") -> str:
    return HEAD + f'\n[cue.{name}]\ncategory = "melee"\nprompt = "a blade"\nduration_s = 1.0\n{extra}\n'


class CommittedBookTest(unittest.TestCase):
    def test_the_committed_book_has_every_cue_in_the_spec(self) -> None:
        book = cuebook.load_cues(ROOT / "audio-src" / "cues.toml")
        self.assertEqual(set(book.cues.keys()), set(SPEC_CUES))
        self.assertEqual(len(SPEC_CUES), 64)
        self.assertEqual(sum(1 for c in book.cues.values() if not c.loop), 54)
        self.assertEqual(sum(1 for c in book.cues.values() if c.loop), 10)

    def test_loop_categories_stream_and_one_shots_sample(self) -> None:
        book = cuebook.load_cues(ROOT / "audio-src" / "cues.toml")
        for category in cuebook.CATEGORIES:
            want = "stream" if category in cuebook.LOOP_CATEGORIES else "sample"
            self.assertEqual(book.playback[category], want, category)
        for cue in book.cues.values():
            self.assertEqual(cue.loop, cue.category in cuebook.LOOP_CATEGORIES, cue.id)

    def test_the_loops_all_share_one_shape(self) -> None:
        book = cuebook.load_cues(ROOT / "audio-src" / "cues.toml")
        loops = [c for c in book.cues.values() if c.loop]
        self.assertEqual(len(loops), 10)
        for c in loops:
            self.assertEqual(
                (c.model, c.duration_s, c.bus, c.variants, c.takes),
                ("eleven_text_to_sound_v3", 12.0, "Ambient", 1, 2), c.id)

    def test_blasts_cap_their_voices_and_ui_sits_on_interface(self) -> None:
        book = cuebook.load_cues(ROOT / "audio-src" / "cues.toml")
        for cue_id in ("explosion_large", "thunder", "gas_burst"):
            self.assertEqual(book.cues[cue_id].max_voices, 2, cue_id)
        for c in book.cues.values():
            if c.category == "ui" or c.id == "order_ack":
                self.assertEqual(c.bus, "Interface", c.id)
        for cue_id in ("ui_click", "ui_select", "ui_formation", "ui_group"):
            self.assertEqual(book.cues[cue_id].level_db, -10.0, cue_id)

    def test_every_prompt_is_non_empty_and_says_what_to_play(self) -> None:
        book = cuebook.load_cues(ROOT / "audio-src" / "cues.toml")
        layers = cuebook.load_layers(ROOT / "audio-src" / "music" / "prompts.toml")
        negation = re.compile(r"\b(no|not|without|nothing|never|neither|nor)\b", re.IGNORECASE)
        texts = [(c.id, c.prompt) for c in book.cues.values()] + [(i, l.prompt) for i, l in layers.items()]
        texts += [("suffix", book.style_suffix), ("vocal_suffix", book.vocal_suffix)]
        for name, text in texts:
            self.assertTrue(text.strip(), name)
            self.assertIsNone(negation.search(text), f"{name} names what to leave out")

    def test_the_committed_suffixes_are_applied_by_category(self) -> None:
        book = cuebook.load_cues(ROOT / "audio-src" / "cues.toml")
        for cue_id in ("swing_blade", "ui_click", "bed_rain", "explosion_large"):
            self.assertTrue(book.prompt_for(cue_id).endswith(book.style_suffix), cue_id)
        for cue_id in ("death_husk", "groan_drifter"):
            self.assertTrue(book.prompt_for(cue_id).endswith(book.vocal_suffix), cue_id)

    def test_the_committed_layers_share_a_key_and_tempo_line(self) -> None:
        layers = cuebook.load_layers(ROOT / "audio-src" / "music" / "prompts.toml")
        self.assertEqual(set(layers), {"riverside_calm", "riverside_combat"})
        last = {layer.prompt.strip().splitlines()[-1] for layer in layers.values()}
        self.assertEqual(len(last), 1)
        for layer in layers.values():
            self.assertEqual((layer.length_s, layer.model, layer.takes), (110.0, "music_v2", 3))


class RefusalTest(unittest.TestCase):
    def test_ids_that_are_not_safe_file_names_are_refused(self) -> None:
        for bad in ("../x", "Hit", "a b", "x/y", "", "a\n"):
            with self.subTest(bad=bad):
                with self.assertRaises(CueError):
                    cuebook.check_id(bad, "id")
                quoted = json.dumps(bad)  # a JSON string is a valid TOML basic string
                with self.assertRaises(CueError):
                    book_from(HEAD + f'\n[cue.{quoted}]\ncategory = "melee"\nprompt = "p"\nduration_s = 1.0\n')
                with self.assertRaises(CueError):
                    layers_from(f'[layer.{quoted}]\nprompt = "p"\nlength_s = 110\nmodel = "music_v2"\ntakes = 3\npicks = []\n')
        for not_a_string in (None, 3, ["a"]):
            with self.assertRaises(CueError):
                cuebook.check_id(not_a_string, "id")

    def test_a_pick_is_a_number_not_a_name(self) -> None:
        for bad in ('"../x"', '"a"', "true", "1.5"):
            with self.subTest(bad=bad):
                with self.assertRaises(CueError):
                    book_from(cue_with(f"picks = [{bad}]"))

    def test_an_id_longer_than_48_characters_is_refused(self) -> None:
        cuebook.check_id("a" * 48, "id")
        for size in (49, 300):
            with self.assertRaises(CueError) as ctx:
                cuebook.check_id("a" * size, "cue id")
            self.assertNotIn("a" * 41, str(ctx.exception))
            with self.assertRaises(CueError) as ctx:
                book_from(HEAD + f'\n[cue.{"a" * size}]\ncategory = "melee"\nprompt = "p"\nduration_s = 1.0\n')
            self.assertNotIn("a" * 41, str(ctx.exception))

    def test_a_message_that_names_a_long_valid_id_clips_it(self) -> None:
        name = "b" * 48
        with self.assertRaises(CueError) as ctx:
            book_from(HEAD + f'\n[cue.{name}]\ncategory = "melee"\npromt = "p"\nduration_s = 1.0\n')
        self.assertNotIn("b" * 41, str(ctx.exception))
        with self.assertRaises(CueError) as ctx:
            layers_from(f'[layer.{name}]\nprompt = "p"\nlength_s = 2\nmodel = "music_v2"\ntakes = 3\n')
        self.assertNotIn("b" * 41, str(ctx.exception))

    def test_text_that_goes_to_the_paid_api_is_capped(self) -> None:
        # M5: a prompt, a voice description or a line is sent as written, so each has a length cap.
        long_prompt = "p" * (cuebook.MAX_PROMPT + 1)
        book_from(HEAD + f'\n[cue.hit_ok]\ncategory = "melee"\nprompt = "{"p" * cuebook.MAX_PROMPT}"\nduration_s = 1.0\n')
        with self.assertRaisesRegex(CueError, "prompt is longer than 500"):
            book_from(HEAD + f'\n[cue.hit_long]\ncategory = "melee"\nprompt = "{long_prompt}"\nduration_s = 1.0\n')
        with self.assertRaisesRegex(CueError, "prompt is longer than 500"):
            layers_from(f'[layer.calm]\nprompt = "{long_prompt}"\nlength_s = 20\nmodel = "music_v2"\ntakes = 3\n')
        self.assertEqual((cuebook.MAX_DESCRIPTION, cuebook.MAX_LINE_TEXT), (600, 300))

    def test_a_long_style_suffix_is_refused_at_load(self) -> None:
        # Low-1: the suffixes go to the paid API with every prompt, so they are capped like the prompts.
        ok = "s" * cuebook.MAX_SUFFIX
        long = "s" * (cuebook.MAX_SUFFIX + 1)
        head = HEAD.replace('suffix = "close foley"', f'suffix = "{ok}"')
        book_from(head + GOOD_CUE)
        for key, old in (("suffix", 'suffix = "close foley"'), ("vocal_suffix", 'vocal_suffix = "close wordless cry"')):
            with self.assertRaisesRegex(CueError, f"{key} is longer than 120"):
                book_from(HEAD.replace(old, f'{key} = "{long}"') + GOOD_CUE)
        self.assertEqual(cuebook.MAX_SUFFIX, 120)

    def test_a_voice_file_name_is_checked_like_an_id(self) -> None:
        # Low-2: the stem went into messages before anything checked it; ESC and BEL must not reach the terminal.
        for name in ("\x1b[2Jevil.toml", "a\x07b.toml", "Upper.toml", "a b.toml", "a-b.toml"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                folder = Path(tmp)
                (folder / name).write_text('unit = "x"\n', encoding="utf-8")
                with self.assertRaises(CueError) as caught:
                    cuebook.load_voices(folder)
                self.assertTrue(all(c.isprintable() for c in str(caught.exception)), repr(str(caught.exception)))
        with tempfile.TemporaryDirectory() as tmp:  # _clan still passes
            (Path(tmp) / "_clan.toml").write_text('unit = "_clan"\n[line.clan_1]\ntext = "Hi"\n', encoding="utf-8")
            self.assertIn("_clan", cuebook.load_voices(Path(tmp)))

    def test_printable_escapes_control_characters_and_newlines_in_values(self) -> None:
        # A value (a file name, a prompt) must not be able to fake a line of output.
        self.assertEqual(cuebook.printable("a\x1b[2Jb\x07"), "a\\x1b[2Jb\\x07")
        self.assertEqual(cuebook.printable("a\nb\rc"), "a\\nb\\rc")
        self.assertEqual(cuebook.printable("a\nb", keep_newlines=True), "a\nb")
        self.assertEqual(cuebook.printable("a\rb", keep_newlines=True), "a\\rb")

    def test_emit_keeps_a_messages_own_lines_but_not_control_characters(self) -> None:
        import contextlib
        import io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            cuebook.emit("one\ntwo \x1b[2J\r")
        self.assertEqual(out.getvalue(), "one\ntwo \\x1b[2J\\r\n")

    def test_a_bad_toml_path_with_a_control_character_is_escaped_in_the_message(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "\x1b[31mcues.toml"
            path.write_bytes(b"\xff\xfe")
            with self.assertRaises(CueError) as caught:
                cuebook.load_cues(path)
            self.assertNotIn("\x1b", str(caught.exception))
            path.write_text("a = = 1", encoding="utf-8")
            with self.assertRaises(CueError) as caught:
                cuebook.load_cues(path)
            self.assertNotIn("\x1b", str(caught.exception))

    def test_variants_cannot_exceed_takes(self) -> None:
        with self.assertRaises(CueError):
            book_from(cue_with("variants = 4\ntakes = 3"))
        with self.assertRaises(CueError):
            book_from(HEAD.replace("takes = 6", "takes = 2") + GOOD_CUE)
        book_from(cue_with("variants = 3\ntakes = 3"))

    def test_models_come_from_an_allowlist(self) -> None:
        for bad in ("eleven_text_to_sound_v22", "eleven_text_to_sound_v1", "music_v2", "x"):
            with self.subTest(bad=bad):
                with self.assertRaises(CueError):
                    book_from(cue_with(f'model = "{bad}"'))
        book_from(cue_with('model = "eleven_text_to_sound_v3"'))
        for bad in ("music_v22", "eleven_text_to_sound_v2", ""):
            with self.subTest(layer=bad):
                with self.assertRaises(CueError):
                    layers_from(LayersTest.GOOD.replace("music_v2", bad))
        layers_from(LayersTest.GOOD.replace("music_v2", "music_v2_5"))
        with self.assertRaises(CueError):
            book_from(HEAD.replace("eleven_text_to_sound_v2", "eleven_text_to_sound_v22") + GOOD_CUE)

    def test_a_loop_must_use_the_v3_model(self) -> None:
        loop = '\n[cue.march_x]\ncategory = "march"\nprompt = "x"\nduration_s = 12\nloop = true\nbus = "Ambient"\n'
        with self.assertRaises(CueError):
            book_from(HEAD + loop)
        book_from(HEAD + loop + 'model = "eleven_text_to_sound_v3"\n')

    def test_both_suffixes_are_required(self) -> None:
        with self.assertRaises(CueError):
            book_from((HEAD.replace('vocal_suffix = "close wordless cry"\n', "")) + GOOD_CUE)

    def test_an_error_never_echoes_more_than_40_characters(self) -> None:
        long = "A" * 200
        with self.assertRaises(CueError) as ctx:
            cuebook.check_id(long, "cue id")
        self.assertNotIn("A" * 41, str(ctx.exception))
        self.assertIn("cue id", str(ctx.exception))
        with self.assertRaises(CueError) as ctx:
            book_from(cue_with(f'{"B" * 200} = 1'))
        self.assertNotIn("B" * 41, str(ctx.exception))

    def test_unknown_keys_and_categories_are_refused(self) -> None:
        with self.assertRaises(CueError):
            book_from(HEAD + '\n[cue.swing_blade]\ncategory = "melee"\npromt = "x"\nduration_s = 1.0\n')
        with self.assertRaises(CueError):
            book_from(HEAD + '\n[cue.swing_blade]\ncategory = "boom"\nprompt = "x"\nduration_s = 1.0\n')
        with self.assertRaises(CueError):
            book_from(HEAD + GOOD_CUE + '\n[extra]\nx = 1\n')
        with self.assertRaises(CueError):
            book_from(HEAD.replace("level_db = 0.0", "level = 0.0") + GOOD_CUE)
        with self.assertRaises(CueError):
            book_from(HEAD.replace('music = "stream"', 'music = "stream"\nboom = "sample"') + GOOD_CUE)

    def test_a_missing_required_key_is_refused(self) -> None:
        with self.assertRaises(CueError):
            book_from(HEAD + '\n[cue.swing_blade]\ncategory = "melee"\nduration_s = 1.0\n')

    def test_a_duration_outside_half_a_second_to_thirty_is_refused(self) -> None:
        for bad in ("0.4", "30.5", "-1", "true"):
            with self.subTest(bad=bad):
                with self.assertRaises(CueError):
                    book_from(HEAD + f'\n[cue.swing_blade]\ncategory = "melee"\nprompt = "x"\nduration_s = {bad}\n')
        book_from(HEAD + '\n[cue.swing_blade]\ncategory = "melee"\nprompt = "x"\nduration_s = 0.5\n')
        book_from(HEAD + '\n[cue.swing_blade]\ncategory = "melee"\nprompt = "x"\nduration_s = 30\n')

    def test_a_pick_outside_the_takes_is_refused(self) -> None:
        for bad in ("[7]", "[0]", "[1, 1]", "[-1]"):
            with self.subTest(bad=bad):
                with self.assertRaises(CueError):
                    book_from(cue_with(f"picks = {bad}"))
        self.assertEqual(book_from(cue_with("picks = [1, 6]")).cues["swing_blade"].picks, (1, 6))

    def test_the_retired_placeholder_key_is_refused_like_any_unknown_key(self) -> None:
        with self.assertRaisesRegex(CueError, "placeholder"):
            book_from(cue_with('placeholder = "res://assets/audio/sfx/sword_hit.wav"'))

    def test_loop_and_category_must_agree(self) -> None:
        with self.assertRaises(CueError):
            book_from(cue_with("loop = true"))
        with self.assertRaises(CueError):
            book_from(HEAD + '\n[cue.march_x]\ncategory = "march"\nprompt = "x"\nduration_s = 12\n')

    def test_bad_values_are_refused(self) -> None:
        for extra in ("variants = 0", "takes = 0", 'bus = "Nope"', "max_voices = 0", "pitch_spread = -0.1",
                      "prompt_influence = 1.5", 'model = ""', "variants = true"):
            with self.subTest(extra=extra):
                with self.assertRaises(CueError):
                    book_from(cue_with(extra))

    def test_a_missing_or_unreadable_file_is_a_cue_error(self) -> None:
        with self.assertRaises(CueError):
            cuebook.load_cues(Path("/nonexistent/cues.toml"))
        with self.assertRaises(CueError):
            book_from("[style\n")

    def test_a_missing_playback_category_is_refused(self) -> None:
        with self.assertRaises(CueError):
            book_from(HEAD.replace('music = "stream"\n', "") + GOOD_CUE)
        with self.assertRaises(CueError):
            book_from(HEAD.replace('music = "stream"', 'music = "loud"') + GOOD_CUE)


class PromptForTest(unittest.TestCase):
    def test_a_melee_cue_gets_the_suffix_and_vocal_cues_get_the_vocal_suffix(self) -> None:
        text = HEAD + GOOD_CUE
        for name, category in (("death_husk", "death"), ("groan_husk", "groan")):
            text += f'\n[cue.{name}]\ncategory = "{category}"\nprompt = "a moan"\nduration_s = 2.0\n'
        book = book_from(text)
        self.assertEqual(book.prompt_for("swing_blade"), "a steel blade cuts the air close foley")
        self.assertEqual(book.prompt_for("death_husk"), "a moan close wordless cry")
        self.assertEqual(book.prompt_for("groan_husk"), "a moan close wordless cry")
        with self.assertRaises(KeyError):
            book.prompt_for("nope")


class DefaultsTest(unittest.TestCase):
    def test_defaults_fill_what_a_cue_leaves_out(self) -> None:
        cue = book_from(HEAD + GOOD_CUE).cues["swing_blade"]
        self.assertEqual((cue.variants, cue.takes, cue.bus), (3, 6, "Effects"))
        self.assertEqual((cue.level_db, cue.max_voices, cue.pitch_spread), (0.0, 3, 0.06))
        self.assertEqual((cue.model, cue.prompt_influence), ("eleven_text_to_sound_v2", 0.5))
        self.assertEqual((cue.loop, cue.picks), (False, ()))

    def test_a_cue_overrides_a_default(self) -> None:
        cue = book_from(cue_with("takes = 4\nlevel_db = -6")).cues["swing_blade"]
        self.assertEqual((cue.takes, cue.level_db), (4, -6.0))


class LayersTest(unittest.TestCase):
    GOOD = '[layer.a]\nprompt = "p"\nlength_s = 110\nmodel = "music_v2"\ntakes = 3\npicks = [2]\n'

    def test_a_good_layer_loads(self) -> None:
        layer = layers_from(self.GOOD)["a"]
        self.assertEqual((layer.length_s, layer.takes, layer.picks), (110.0, 3, (2,)))

    def test_bad_layers_are_refused(self) -> None:
        for bad in (self.GOOD.replace("110", "2"), self.GOOD.replace("110", "601"),
                    self.GOOD.replace("[2]", "[4]"), self.GOOD.replace("prompt", "promt"),
                    self.GOOD + "[other]\nx = 1\n", ""):
            with self.subTest(bad=bad):
                with self.assertRaises(CueError):
                    layers_from(bad)


def voices_from(files: dict[str, str]) -> dict[str, cuebook.VoiceFile]:
    with tempfile.TemporaryDirectory() as tmp:
        for name, text in files.items():
            (Path(tmp) / name).write_text(text, encoding="utf-8")
        return cuebook.load_voices(Path(tmp))


UNIT: str = """unit = "reaver"

[voice.reaver]
description = "a hoarse young Highland Scots man"
model = "eleven_v4"

[line.attack_1]
trigger = "attack"
text = "Raaargh!"
tag = "[roaring]"
picks = {}
"""

CLAN: str = """unit = "_clan"

[line.clan_1]
text = "Crivens!"
picks = {}
"""


class VoicesTest(unittest.TestCase):
    def test_voice_files_load_with_their_lines_and_voices(self) -> None:
        files = cuebook.load_voices(ROOT / "audio-src" / "voices")
        self.assertEqual(set(files), {"shieldman", "reaver", "longbow", "sapper", "warden", "_clan"})
        shield = files["shieldman"]
        self.assertEqual(set(shield.voices), {"shieldman_old", "shieldman_young"})
        self.assertEqual(shield.voices["shieldman_old"].model, "eleven_v4")
        self.assertEqual(len(shield.lines), 37)
        self.assertEqual(shield.lines["select_1"].text, "Aye? Whit is it?")
        self.assertEqual(files["reaver"].lines["attack_3"].tag, "[roaring]")
        self.assertEqual(len(files["_clan"].lines), 5)
        self.assertEqual(files["_clan"].voices, {})
        for line in files["_clan"].lines.values():
            self.assertTrue(line.id.startswith("clan_"))
            self.assertEqual(line.trigger, "")

    def test_every_light_unit_covers_the_required_triggers_its_specials_and_victory(self) -> None:
        files = cuebook.load_voices(ROOT / "audio-src" / "voices")
        specials = {"longbow": ("special", "fizzle"), "sapper": ("special", "fizzle"), "warden": ("special", "heal_undead")}
        for unit in ("shieldman", "reaver", "longbow", "sapper", "warden"):
            triggers = {line.trigger for line in files[unit].lines.values()}
            for trigger in (*cuebook.REQUIRED_TRIGGERS, "victory", *specials.get(unit, ())):
                self.assertIn(trigger, triggers, f"{unit} has no {trigger} line")
            if unit != "shieldman":
                self.assertTrue(20 <= len(files[unit].lines) <= 25, f"{unit} has {len(files[unit].lines)} lines")
        self.assertEqual(len(cuebook.TRIGGERS), 15 + 10)
        self.assertIn("formation_short_line", cuebook.TRIGGERS)
        self.assertIn("formation_circle", cuebook.TRIGGERS)

    def test_an_unknown_trigger_is_refused(self) -> None:
        with self.assertRaisesRegex(CueError, "trigger"):
            voices_from({"reaver.toml": UNIT.replace('"attack"', '"dance"')})

    def test_a_line_pick_for_a_voice_the_unit_lacks_is_refused(self) -> None:
        voices_from({"reaver.toml": UNIT.replace("picks = {}", "picks = {reaver = 2}")})
        with self.assertRaisesRegex(CueError, "pick"):
            voices_from({"reaver.toml": UNIT.replace("picks = {}", "picks = {warden = 2}")})
        for bad in ("picks = {reaver = 0}", "picks = {reaver = true}", 'picks = {reaver = "1"}', "picks = []"):
            with self.subTest(bad=bad), self.assertRaises(CueError):
                voices_from({"reaver.toml": UNIT.replace("picks = {}", bad)})

    def test_a_clan_pick_may_name_any_light_voice(self) -> None:
        files = voices_from({
            "reaver.toml": UNIT, "_clan.toml": CLAN.replace("picks = {}", "picks = {reaver = 1}")})
        self.assertEqual(files["_clan"].lines["clan_1"].picks, {"reaver": 1})
        with self.assertRaisesRegex(CueError, "pick"):
            voices_from({"reaver.toml": UNIT, "_clan.toml": CLAN.replace("picks = {}", "picks = {husk = 1}")})

    def test_clan_lines_have_clan_ids_and_no_trigger_or_voices(self) -> None:
        for bad in (CLAN.replace("clan_1", "crivens"), CLAN.replace("text =", 'trigger = "select"\ntext ='),
                    CLAN + '\n[voice.x]\ndescription = "d"\nmodel = "eleven_v4"\n'):
            with self.subTest(bad=bad), self.assertRaises(CueError):
                voices_from({"_clan.toml": bad})

    def test_a_unit_line_needs_a_trigger_and_the_unit_a_voice(self) -> None:
        with self.assertRaises(CueError):
            voices_from({"reaver.toml": UNIT.replace('trigger = "attack"\n', "")})
        with self.assertRaises(CueError):
            voices_from({"reaver.toml": UNIT.split("[voice.reaver]")[0] + '[line.attack_1]\ntrigger = "attack"\ntext = "x"\n'})

    def test_a_tag_is_bracketed_lowercase_words_only(self) -> None:
        for good in ("[shouting]", "[roaring] [angry]", "[whispers softly]", "[" + "a" * 38 + "]"):
            voices_from({"reaver.toml": UNIT.replace("[roaring]", good)})
        for bad in ("shouting", "[SHOUT]", "[a][b]x", "[ ]", "[]", "[a ]", "[ok] ", "[ok]  [no]", "[" + "a" * 39 + "]", "[ok] " * 9, "[x]; rm", ""):
            with self.subTest(bad=bad), self.assertRaises(CueError):
                voices_from({"reaver.toml": UNIT.replace("[roaring]", bad)})

    def test_ids_unknown_keys_and_the_unit_name_are_checked(self) -> None:
        for bad in (UNIT.replace("[line.attack_1]", "[line.Attack_1]"), UNIT.replace("[line.attack_1]", "[line.a/b]"),
                    UNIT.replace("[voice.reaver]", "[voice.X-y]"),
                    UNIT.replace("text =", "txt ="), UNIT.replace('unit = "reaver"', 'unit = "sapper"'),
                    UNIT.replace('text = "Raaargh!"', 'text = ""'), UNIT + "extra = 1\n",
                    UNIT.replace('model = "eleven_v4"', 'model = "other"')):
            with self.subTest(bad=bad), self.assertRaises(CueError):
                voices_from({"reaver.toml": bad})

    def test_a_long_value_is_clipped_in_the_message(self) -> None:
        long = "x" * 500
        with self.assertRaises(CueError) as ctx:
            voices_from({"reaver.toml": UNIT.replace('"attack"', f'"{long}"')})
        self.assertNotIn(long, str(ctx.exception))

    def test_the_turbo_model_loads_and_an_unknown_one_is_refused(self) -> None:
        files = voices_from({"reaver.toml": UNIT.replace('"eleven_v4"', '"eleven_v4_turbo"')})
        self.assertEqual(files["reaver"].voices["reaver"].model, "eleven_v4_turbo")
        with self.assertRaisesRegex(CueError, "model"):
            voices_from({"reaver.toml": UNIT.replace('"eleven_v4"', '"eleven_v5"')})

    def test_a_voice_defined_in_two_files_is_refused(self) -> None:
        other = UNIT.replace('unit = "reaver"', 'unit = "sapper"')
        with self.assertRaisesRegex(CueError, "already defined"):
            voices_from({"reaver.toml": UNIT, "sapper.toml": other})

    def test_a_clan_prefixed_line_outside_the_clan_file_is_refused(self) -> None:
        with self.assertRaisesRegex(CueError, "clan_"):
            voices_from({"reaver.toml": UNIT.replace("attack_1", "clan_9")})

    def test_an_empty_folder_is_refused(self) -> None:
        with self.assertRaises(CueError):
            voices_from({})


if __name__ == "__main__":
    unittest.main()
