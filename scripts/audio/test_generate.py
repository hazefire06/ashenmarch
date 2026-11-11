"""Tests for generate.py. Nothing here touches the network or the real secrets file: load_secret, the transport and urllib
are patched to raise, except where a fake transport is injected on purpose. Raw files and the manifest go to a temp dir."""
from __future__ import annotations

import base64
import contextlib
import io
import json
import tempfile
import unittest
import urllib.request
from pathlib import Path
from typing import Any
from unittest import mock

import generate
from elevenlabs_client import ElevenLabsError

WAV = b"RIFF\x24\x00\x00\x00WAVEfmt " + b"\x00" * 8
MP3 = b"\xff\xfb\x90\x00" + b"\x00" * 16

CUES = """
[style]
suffix = "close foley"
vocal_suffix = "close wordless cry"

[defaults]
variants = 1
takes = 2
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

[cue.hit_flesh]
category = "melee"
prompt = "A blade hits flesh."
duration_s = 1.0

[cue.hit_dry]
category = "melee"
prompt = "A blade hits dry bone."
duration_s = 0.5
takes = 1

[cue.bed_fire]
category = "bed"
prompt = "A crackling fire."
duration_s = 10.0
loop = true
model = "eleven_text_to_sound_v3"
"""

MUSIC = """
[layer.calm]
prompt = "Sparse drone."
length_s = 60
model = "music_v2"
takes = 2
"""

AB_IDS = ("attack_1", "attack_2", "kill_1", "kill_2", "hurt_1", "victory_1")


def voice_file() -> str:
    parts = ['unit = "shieldman"', "", "[voice.shieldman_old]", 'description = "a gruff old man"', 'model = "eleven_v4"', "",
             "[voice.shieldman_young]", 'description = "a keen young man"', 'model = "eleven_v4_turbo"', ""]
    for line_id in ("select_1", *AB_IDS):
        trigger = line_id.rsplit("_", 1)[0]
        parts += [f"[line.{line_id}]", f'trigger = "{trigger}"', f'text = "Text of {line_id}."', ""]
    parts += ["[line.select_2]", 'trigger = "select"', 'text = "Hello."', 'tag = "[whispers]"', ""]
    return "\n".join(parts)


CLAN = """
unit = "_clan"

[line.clan_1]
text = "Crivens!"
"""


class Fake:
    """A transport that hands back queued replies, or raises an exception queued in their place."""

    def __init__(self, replies: list[Any] | None = None, default: Any = ("audio/wav", WAV)) -> None:
        self.replies = list(replies or [])
        self.default = default
        self.calls: list[tuple[str, dict[str, str], dict[str, Any]]] = []

    def __call__(self, path: str, query: dict[str, str], body: dict[str, Any]) -> tuple[str, bytes]:
        self.calls.append((path, query, body))
        reply = self.replies.pop(0) if self.replies else self.default
        if isinstance(reply, Exception):
            raise reply
        return reply


def preview_reply(count: int = 2) -> tuple[str, bytes]:
    previews = [{"audio_base_64": base64.b64encode(MP3 + bytes([i])).decode(), "generated_voice_id": f"gen{i}", "media_type": "audio/mpeg",
                 "duration_secs": 5.0, "language": "en"} for i in range(1, count + 1)]
    return "application/json", json.dumps({"previews": previews, "text": "Sample text, sample text."}).encode()


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.src = Path(self._tmp.name) / "audio-src"
        (self.src / "voices").mkdir(parents=True)
        (self.src / "music").mkdir()
        (self.src / "cues.toml").write_text(CUES)
        (self.src / "music" / "prompts.toml").write_text(MUSIC)
        (self.src / "voices" / "shieldman.toml").write_text(voice_file())
        (self.src / "voices" / "_clan.toml").write_text(CLAN)
        self.raw = self.src / "raw"
        self.manifest_path = self.src / "manifest.json"
        self.fake = Fake()
        # Anything that could reach the key or the network raises, unless a test swaps in the fake on purpose.
        self.secret = mock.patch.object(generate, "load_secret", side_effect=AssertionError("the key was read"))
        self.net = mock.patch.object(generate, "http_transport", side_effect=AssertionError("a transport was built"))
        self.urlopen = mock.patch.object(urllib.request, "urlopen", side_effect=AssertionError("urllib was used"))
        self.opener = mock.patch.object(urllib.request.OpenerDirector, "open", side_effect=AssertionError("urllib was used"))
        self.root = mock.patch.object(generate, "AUDIO_SRC", self.src)
        self.mocks = [m.start() for m in (self.secret, self.net, self.urlopen, self.opener, self.root)]
        self.addCleanup(mock.patch.stopall)
        self.addCleanup(self._tmp.cleanup)

    def allow_network(self, fake: Fake | None = None) -> Fake:
        """Lets paid commands run against a fake transport. The key is a dummy."""
        self.fake = fake or self.fake
        self.mocks[0].side_effect = None
        self.mocks[0].return_value = "DUMMYKEY"
        self.mocks[1].side_effect = None
        self.mocks[1].return_value = self.fake
        return self.fake

    def assert_untouched(self) -> None:
        """The key was never read, no transport was built and urllib was never used."""
        for m in self.mocks[:4]:
            m.assert_not_called()

    def run_main(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = generate.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def manifest(self) -> generate.Manifest:
        return generate.Manifest.load(self.manifest_path, allowed=generate.AUDIO_FIELDS)

    def seed(self, *records: dict[str, Any]) -> None:
        generate.Manifest(self.manifest_path, list(records), generate.AUDIO_FIELDS).save()

    def save_voice_record(self, voice: str = "shieldman_old", voice_id: str = "VoiceOld1") -> dict[str, Any]:
        record = {"kind": "voice", "label": f"voice/{voice}", "status": "DONE", "credits": 0, "voice_id": voice_id}
        self.seed(*self.manifest().tasks, record)
        return record


class PlanTest(Base):
    def test_plan_costs_each_batch_and_needs_no_key_or_network(self) -> None:
        code, out, _ = self.run_main("plan")
        self.assertEqual(code, 0)
        self.mocks[0].assert_not_called()
        self.mocks[1].assert_not_called()
        self.assertIn("probe", out)
        self.assertIn("40 credits", out)
        # 3 melee/bed cues: hit_flesh 2 takes x 40, hit_dry 1 x 20; the loop bed_fire 2 takes x 400
        self.assertIn("sfx", out)
        self.assertIn("100 credits", out)
        self.assertIn("800 credits", out)
        self.assertIn("assumed", out)
        self.assertFalse(self.raw.exists())
        self.assertFalse(self.manifest_path.exists())

    def test_plan_shows_what_is_bought_and_what_blocks(self) -> None:
        self.seed({"kind": "sfx", "label": "sfx/hit_flesh/1", "status": "DONE", "credits": 40},
                  {"kind": "sfx", "label": "sfx/hit_flesh/2", "status": "PENDING"},
                  {"kind": "voices", "label": "voices/shieldman_old/select_1/1", "status": "INTERRUPTED"})
        code, out, _ = self.run_main("plan", "--batch", "sfx")
        self.assertEqual(code, 0)
        self.assertIn("1 of 3 bought", out)
        self.assertIn("pending:", out)
        self.assertIn("interrupted:", out)
        self.assertIn("blocked", out)

    def test_plan_batch_shows_one_batch(self) -> None:
        code, out, _ = self.run_main("plan", "--batch", "music")
        self.assertEqual(code, 0)
        self.assertIn("music", out)
        self.assertNotIn("probe", out)
        self.assertIn("1800 credits", out)  # 2 takes x 60 s at 900 per minute

    def test_plan_counts_lines_in_each_voice_with_the_clan_lines(self) -> None:
        _, out, _ = self.run_main("plan", "--batch", "lines")
        # (8 unit lines + clan_1) x 2 voices x 3 takes: chars of tagged text
        self.assertIn("54 recordings", out)

    def test_a_bad_format_file_is_an_error(self) -> None:
        (self.src / "format.txt").write_text("flac_44100\n")
        code, _, err = self.run_main("plan")
        self.assertEqual(code, 2)
        self.assertIn("format.txt", err)


class BudgetAndResumeTest(Base):
    def test_a_run_over_max_credits_buys_nothing(self) -> None:
        fake = self.fake
        code, _, err = self.run_main("sfx", "--cue", "hit_flesh", "--max-credits", "79")
        self.assertEqual(code, 1)
        self.assertIn("80", err)
        self.assertEqual(fake.calls, [])
        self.assertFalse(self.manifest_path.exists())
        self.assertFalse(self.raw.exists())
        self.assert_untouched()

    def test_a_rerun_skips_what_is_bought(self) -> None:
        fake = self.allow_network()
        code, _, _ = self.run_main("sfx", "--cue", "hit_flesh", "--max-credits", "80")
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 2)
        self.assertEqual((self.raw / "sfx" / "hit_flesh" / "1.wav").read_bytes(), WAV)
        self.assertEqual(self.manifest().find("sfx", "sfx/hit_flesh/2")["status"], "DONE")
        self.assertEqual(self.manifest().credits_spent(), 80)
        # The second run needs nothing, so even --max-credits 0 passes, and nothing is posted.
        code, out, _ = self.run_main("sfx", "--cue", "hit_flesh", "--max-credits", "0")
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 2)
        self.assertIn("nothing to buy", out)

    def test_the_request_uses_the_cue_books_prompt_and_settings(self) -> None:
        fake = self.allow_network()
        self.run_main("sfx", "--cue", "bed_fire", "--max-credits", "800")
        path, query, body = fake.calls[0]
        self.assertEqual(path, "/v1/sound-generation")
        self.assertEqual(query, {"output_format": "wav_32000"})
        self.assertEqual(body["text"], "A crackling fire. close foley")
        self.assertEqual(body["duration_seconds"], 10.0)
        self.assertTrue(body["loop"])
        self.assertEqual(body["model_id"], "eleven_text_to_sound_v3")

    def test_a_category_buys_every_cue_in_it(self) -> None:
        fake = self.allow_network()
        code, _, _ = self.run_main("sfx", "--category", "melee", "--max-credits", "100")
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 3)
        self.assertTrue((self.raw / "sfx" / "hit_dry" / "1.wav").exists())

    def test_the_format_file_picks_mp3(self) -> None:
        (self.src / "format.txt").write_text("mp3_44100_128\n")
        fake = self.allow_network(Fake(default=("audio/mpeg", MP3)))
        code, _, _ = self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        self.assertEqual(code, 0)
        self.assertEqual(fake.calls[0][1], {"output_format": "mp3_44100_128"})
        self.assertTrue((self.raw / "sfx" / "hit_dry" / "1.mp3").exists())
        self.assertEqual(self.manifest().find("sfx", "sfx/hit_dry/1")["format"], "mp3_44100_128")

    def test_ids_from_the_command_line_are_checked(self) -> None:
        fake = self.fake
        for argv in (("sfx", "--cue", "../etc", "--max-credits", "9999"), ("sfx", "--cue", "nope", "--max-credits", "9999"),
                     ("sfx", "--category", "x/y", "--max-credits", "9999"), ("sfx", "--category", "weird", "--max-credits", "9999"),
                     ("music", "..", "--max-credits", "9999"), ("voices", "lines", "bad.unit", "--max-credits", "9999"),
                     ("voices", "design", "shieldman", "--voice", "../x", "--max-credits", "9999")):
            with self.subTest(argv=argv):
                code, _, _ = self.run_main(*argv)
                self.assertEqual(code, 2)
        self.assertEqual(fake.calls, [])
        self.assert_untouched()

    def test_max_credits_is_required_and_not_negative(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            generate.main(["sfx", "--cue", "hit_dry"])
        code, _, _ = self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "-5")
        self.assertEqual(code, 2)
        self.assert_untouched()


class InterruptionTest(Base):
    def test_an_interrupted_entry_stops_every_paid_run(self) -> None:
        for status in ("INTERRUPTED", "PENDING"):
            self.seed({"kind": "sfx", "label": "sfx/hit_flesh/1", "status": status})
            fake = self.fake
            for argv in (("sfx", "--cue", "hit_dry", "--max-credits", "999"), ("probe", "--max-credits", "999"),
                         ("music", "calm", "--max-credits", "9999"), ("voices", "design", "shieldman", "--voice", "shieldman_old", "--max-credits", "9999"),
                         ("voices", "lines", "shieldman", "--max-credits", "99999"), ("voices", "ab", "--max-credits", "9999"),
                         ("voices", "save", "shieldman", "--voice", "shieldman_old", "--pick", "1")):
                with self.subTest(status=status, argv=argv):
                    code, _, err = self.run_main(*argv)
                    self.assertEqual(code, 1)
                    self.assertIn("manifest", err)
            self.assertEqual(fake.calls, [])
            self.assert_untouched()

    def test_a_charge_that_may_have_happened_records_interrupted_and_stops(self) -> None:
        fake = self.allow_network(Fake([ElevenLabsError("no reply", may_have_charged=True)]))
        code, _, err = self.run_main("sfx", "--category", "melee", "--max-credits", "100")
        self.assertEqual(code, 1)
        self.assertEqual(len(fake.calls), 1)
        self.assertIn("usage page", err)
        self.assertIn("by hand", err)
        record = self.manifest().find("sfx", "sfx/hit_dry/1")  # categories run in id order
        self.assertEqual(record["status"], "INTERRUPTED")
        # and the next run refuses
        code, _, _ = self.run_main("sfx", "--cue", "hit_flesh", "--max-credits", "100")
        self.assertEqual(code, 1)
        self.assertEqual(len(fake.calls), 1)

    def test_a_definite_rejection_records_failed_and_does_not_block_a_rerun(self) -> None:
        fake = self.allow_network(Fake([ElevenLabsError("HTTP 402 out of credits", may_have_charged=False)]))
        code, _, err = self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        self.assertEqual(code, 1)
        self.assertIn("402", err)
        record = self.manifest().find("sfx", "sfx/hit_dry/1")
        self.assertEqual((record["status"], record["credits"]), ("FAILED", 0))
        code, _, _ = self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 2)
        self.assertEqual(self.manifest().find("sfx", "sfx/hit_dry/1")["status"], "DONE")

    def test_pending_is_on_disk_before_the_post(self) -> None:
        seen: list[str] = []

        def transport(path: str, query: dict[str, str], body: dict[str, Any]) -> tuple[str, bytes]:
            seen.append(self.manifest().find("sfx", "sfx/hit_dry/1")["status"])
            return "audio/wav", WAV

        self.allow_network(transport)  # type: ignore[arg-type]
        self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        self.assertEqual(seen, ["PENDING"])


class ManifestFieldsTest(Base):
    def test_the_manifest_keeps_only_audio_fields(self) -> None:
        self.seed()
        self.manifest_path.write_text(json.dumps({"tasks": [
            {"kind": "sfx", "label": "sfx/hit_flesh/1", "status": "DONE", "credits": 40, "url": "https://x/y?sig=1", "files": ["sfx/hit_flesh/1.wav"],
             "response": {"nested": 1}, "prompt": "see https://leak.example/a", "task_id": "t"}]}))
        self.allow_network()
        self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        written = self.manifest_path.read_text()
        for leaked in ("https://", "leak.example", "response", "nested", "task_id", "sig=1"):
            self.assertNotIn(leaked, written)
        keys = {k for task in json.loads(written)["tasks"] for k in task}
        self.assertLessEqual(keys, generate.AUDIO_FIELDS)
        self.assertIn("hit_flesh/1", written)

    def test_a_reply_cannot_put_anything_in_the_manifest(self) -> None:
        # The client returns bytes only, so a hostile reply body can't reach a record. The record holds our own request text.
        self.allow_network(Fake(default=("audio/wav", WAV + b"https://evil.example/{\"x\": 1}")))
        self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        self.assertNotIn("evil", self.manifest_path.read_text())


class PurchaseProofTest(Base):
    def test_a_done_record_keeps_the_hash_and_size_of_its_file(self) -> None:
        import hashlib
        self.allow_network()
        self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        record = self.manifest().find("sfx", "sfx/hit_dry/1")
        self.assertEqual(record["sha256"], hashlib.sha256(WAV).hexdigest())
        self.assertEqual(record["bytes"], len(WAV))
        self.assertTrue({"sha256", "bytes"} <= generate.AUDIO_FIELDS)

    def test_each_design_preview_keeps_its_own_hash(self) -> None:
        import hashlib
        self.allow_network(Fake([preview_reply(2)]))
        self.run_main("voices", "design", "shieldman", "--voice", "shieldman_old", "--max-credits", "1000")
        for n in (1, 2):
            record = self.manifest().find("design", f"design/shieldman/shieldman_old/{n}")
            self.assertEqual(record["sha256"], hashlib.sha256(MP3 + bytes([n])).hexdigest())
            self.assertEqual(record["bytes"], len(MP3) + 1)


class DesignTest(Base):
    def test_design_saves_the_previews_and_never_the_json(self) -> None:
        fake = self.allow_network(Fake([preview_reply(2)]))
        code, out, _ = self.run_main("voices", "design", "shieldman", "--voice", "shieldman_old", "--max-credits", "1000")
        self.assertEqual(code, 0)
        self.assertEqual(fake.calls[0][0], "/v1/text-to-voice/design")
        self.assertEqual(fake.calls[0][2]["voice_description"], "a gruff old man")
        base = self.raw / "design" / "shieldman" / "shieldman_old"
        self.assertEqual((base / "1.mp3").read_bytes(), MP3 + b"\x01")
        self.assertEqual((base / "2.mp3").read_bytes(), MP3 + b"\x02")
        found = sorted(p.name for p in self.raw.rglob("*") if p.is_file())
        self.assertEqual(found, ["1.mp3", "2.mp3"])  # no JSON, no .part
        manifest = self.manifest()
        first = manifest.find("design", "design/shieldman/shieldman_old/1")
        self.assertEqual((first["status"], first["generated_voice_id"]), ("DONE", "gen1"))
        text = self.manifest_path.read_text()
        self.assertNotIn("audio_base_64", text)
        self.assertNotIn("Sample text", text)
        self.assertEqual(manifest.credits_spent(), 1000)
        self.assertIn("assumed", out)

    def test_design_over_the_budget_buys_nothing_and_a_rerun_does_not_rebuy(self) -> None:
        code, _, _ = self.run_main("voices", "design", "shieldman", "--voice", "shieldman_old", "--max-credits", "999")
        self.assertEqual(code, 1)
        self.assertEqual(self.fake.calls, [])
        self.assert_untouched()
        fake = self.allow_network(Fake([preview_reply(1)]))
        self.run_main("voices", "design", "shieldman", "--voice", "shieldman_old", "--max-credits", "1000")
        code, out, _ = self.run_main("voices", "design", "shieldman", "--voice", "shieldman_old", "--max-credits", "0")
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 1)
        self.assertIn("nothing to buy", out)

    def test_a_voice_that_is_not_in_the_unit_file_is_refused(self) -> None:
        code, _, err = self.run_main("voices", "design", "shieldman", "--voice", "nobody", "--max-credits", "1000")
        self.assertEqual(code, 2)
        self.assertIn("nobody", err)
        self.assert_untouched()

    def test_save_reads_the_generated_id_from_the_manifest(self) -> None:
        fake = self.allow_network(Fake([preview_reply(2), ("application/json", b'{"voice_id": "VoiceNew9"}')]))
        self.run_main("voices", "design", "shieldman", "--voice", "shieldman_old", "--max-credits", "1000")
        code, _, _ = self.run_main("voices", "save", "shieldman", "--voice", "shieldman_old", "--pick", "2")
        self.assertEqual(code, 0)
        path, _, body = fake.calls[1]
        self.assertEqual(path, "/v1/text-to-voice")
        self.assertEqual(body["generated_voice_id"], "gen2")
        self.assertEqual(body["voice_description"], "a gruff old man")
        record = self.manifest().find("voice", "voice/shieldman_old")
        self.assertEqual((record["status"], record["voice_id"]), ("DONE", "VoiceNew9"))
        # saved once: a second save posts nothing
        code, out, _ = self.run_main("voices", "save", "shieldman", "--voice", "shieldman_old", "--pick", "1")
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 2)
        self.assertIn("already saved", out)

    def test_save_refuses_a_preview_that_was_never_made(self) -> None:
        fake = self.fake
        code, _, err = self.run_main("voices", "save", "shieldman", "--voice", "shieldman_old", "--pick", "3")
        self.assertEqual(code, 1)
        self.assertIn("preview 3", err)
        self.assertEqual(fake.calls, [])
        self.assert_untouched()

    def test_a_save_that_may_have_charged_is_interrupted(self) -> None:
        fake = self.allow_network(Fake([preview_reply(1), ("application/json", b'{"nope": 1}')]))
        self.run_main("voices", "design", "shieldman", "--voice", "shieldman_old", "--max-credits", "1000")
        code, _, err = self.run_main("voices", "save", "shieldman", "--voice", "shieldman_old", "--pick", "1")
        self.assertEqual(code, 1)
        self.assertEqual(self.manifest().find("voice", "voice/shieldman_old")["status"], "INTERRUPTED")
        self.assertIn("by hand", err)
        self.assertEqual(len(fake.calls), 2)


class LinesTest(Base):
    def test_lines_cover_the_units_lines_and_the_clan_lines_in_each_voice(self) -> None:
        self.save_voice_record("shieldman_old", "VoiceOld1")
        self.save_voice_record("shieldman_young", "VoiceYoung2")
        fake = self.allow_network()
        code, _, _ = self.run_main("voices", "lines", "shieldman", "--line", "clan_1", "--max-credits", "100")
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 6)  # 1 line x 2 voices x 3 takes
        paths = {c[0] for c in fake.calls}
        self.assertEqual(paths, {"/v1/text-to-speech/VoiceOld1", "/v1/text-to-speech/VoiceYoung2"})
        self.assertTrue((self.raw / "voices" / "shieldman_young" / "clan_1" / "3.wav").exists())
        models = {(c[0].rsplit("/", 1)[1], c[2]["model_id"]) for c in fake.calls}
        self.assertEqual(models, {("VoiceOld1", "eleven_v4"), ("VoiceYoung2", "eleven_v4_turbo")})

    def test_a_tag_goes_in_front_of_the_text_and_takes_can_be_overridden(self) -> None:
        self.save_voice_record("shieldman_old", "VoiceOld1")
        fake = self.allow_network()
        code, _, _ = self.run_main("voices", "lines", "shieldman", "--voice", "shieldman_old", "--line", "select_2", "--takes", "1", "--max-credits", "100")
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 1)
        self.assertEqual(fake.calls[0][2]["text"], "[whispers] Hello.")
        self.assertEqual(self.manifest().find("voices", "voices/shieldman_old/select_2/1")["text"], "[whispers] Hello.")

    def test_a_voice_that_is_not_saved_stops_the_run_before_buying(self) -> None:
        self.save_voice_record("shieldman_old", "VoiceOld1")
        fake = self.fake
        code, _, err = self.run_main("voices", "lines", "shieldman", "--max-credits", "999999")
        self.assertEqual(code, 1)
        self.assertIn("shieldman_young", err)
        self.assertEqual(fake.calls, [])
        self.assert_untouched()

    def test_lines_budget_counts_characters(self) -> None:
        self.save_voice_record("shieldman_old", "VoiceOld1")
        fake = self.fake
        # "[whispers] Hello." is 17 characters, x 3 takes = 51
        code, _, err = self.run_main("voices", "lines", "shieldman", "--voice", "shieldman_old", "--line", "select_2", "--max-credits", "50")
        self.assertEqual(code, 1)
        self.assertIn("51", err)
        self.assertEqual(fake.calls, [])
        self.assert_untouched()

    def test_an_unknown_line_is_refused(self) -> None:
        code, _, _ = self.run_main("voices", "lines", "shieldman", "--line", "nope_1", "--max-credits", "9")
        self.assertEqual(code, 2)
        self.assert_untouched()


class AbTest(Base):
    def test_ab_refuses_until_shieldman_old_is_saved(self) -> None:
        fake = self.fake
        code, _, err = self.run_main("voices", "ab", "--max-credits", "99999")
        self.assertEqual(code, 1)
        self.assertIn("shieldman_old", err)
        self.assertEqual(fake.calls, [])
        self.assert_untouched()

    def test_ab_buys_two_takes_of_each_line_in_each_model(self) -> None:
        self.save_voice_record("shieldman_old", "VoiceOld1")
        fake = self.allow_network()
        code, _, _ = self.run_main("voices", "ab", "--max-credits", "99999")
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 24)  # 6 lines x 2 models x 2 takes
        self.assertEqual({c[2]["model_id"] for c in fake.calls}, {"eleven_v4", "eleven_v4_turbo"})
        self.assertTrue(all(c[0] == "/v1/text-to-speech/VoiceOld1" for c in fake.calls))
        self.assertTrue(all(c[2]["text"].startswith(("[shouting]", "[laughs]")) for c in fake.calls))
        self.assertTrue((self.raw / "ab" / "eleven_v4_turbo" / "attack_1" / "2.wav").exists())
        self.assertIsNotNone(self.manifest().find("ab", "ab/eleven_v4/kill_1/1"))


class MusicTest(Base):
    def test_music_buys_the_layers_takes(self) -> None:
        fake = self.allow_network()
        code, _, _ = self.run_main("music", "calm", "--max-credits", "1800")
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 2)
        path, query, body = fake.calls[0]
        self.assertEqual(path, "/v1/music")
        self.assertEqual(body["music_length_ms"], 60000)
        self.assertEqual(body["prompt"], "Sparse drone.")
        self.assertTrue((self.raw / "music" / "calm" / "2.wav").exists())

    def test_music_over_the_budget_buys_nothing(self) -> None:
        fake = self.fake
        code, _, _ = self.run_main("music", "calm", "--max-credits", "1799")
        self.assertEqual(code, 1)
        self.assertEqual(fake.calls, [])
        self.assert_untouched()


class ProbeTest(Base):
    def test_probe_accepts_wav_32000_even_when_format_txt_says_mp3(self) -> None:
        (self.src / "format.txt").write_text("mp3_44100_128\n")
        fake = self.allow_network()
        code, out, _ = self.run_main("probe", "--max-credits", "40")
        self.assertEqual(code, 0)
        self.assertEqual(fake.calls[0][1], {"output_format": "wav_32000"})
        self.assertEqual(fake.calls[0][2]["duration_seconds"], 1.0)
        self.assertIn("accepted", out)
        self.assertIn(str(len(WAV)), out)
        self.assertEqual((self.src / "format.txt").read_text(), "mp3_44100_128\n")  # never rewritten
        self.assertFalse(self.raw.exists())

    def test_probe_reports_a_refused_format(self) -> None:
        self.allow_network(Fake([ElevenLabsError("ElevenLabs POST /v1/sound-generation failed: HTTP 403 output_format wav_32000 needs a higher tier")]))
        code, out, err = self.run_main("probe", "--max-credits", "40")
        self.assertEqual(code, 1)
        self.assertIn("refused", out + err)
        self.assertIn("mp3_44100_128", out + err)
        self.assertFalse((self.src / "format.txt").exists())
        self.assertEqual(self.manifest().find("probe", "probe/wav_32000")["status"], "FAILED")

    def test_probe_is_not_bought_twice(self) -> None:
        fake = self.allow_network()
        self.run_main("probe", "--max-credits", "40")
        code, out, _ = self.run_main("probe", "--max-credits", "40")
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 1)
        self.assertIn("already", out)

    def test_probe_over_the_budget_buys_nothing(self) -> None:
        fake = self.fake
        code, _, _ = self.run_main("probe", "--max-credits", "39")
        self.assertEqual(code, 1)
        self.assertEqual(fake.calls, [])
        self.assert_untouched()


class SymlinkTest(Base):
    def test_a_planted_symlink_stops_a_download(self) -> None:
        outside = Path(self._tmp.name) / "outside"
        outside.mkdir()
        (self.raw / "sfx").mkdir(parents=True)
        (self.raw / "sfx" / "hit_dry").symlink_to(outside)
        fake = self.fake
        code, _, err = self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        self.assertEqual(code, 2)
        self.assertIn("symlink", err)
        self.assertEqual(fake.calls, [])  # refused before anything was bought
        self.assertEqual(list(outside.iterdir()), [])
        self.assert_untouched()

    def test_a_symlinked_raw_folder_is_refused_up_front(self) -> None:
        outside = Path(self._tmp.name) / "outside"
        outside.mkdir()
        self.raw.symlink_to(outside)
        fake = self.fake
        code, _, err = self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        self.assertNotEqual(code, 0)
        self.assertIn("symlink", err)
        self.assertEqual(fake.calls, [])
        self.assertEqual(list(outside.iterdir()), [])
        self.assert_untouched()

    def test_a_symlinked_part_file_is_refused_before_buying(self) -> None:
        target = Path(self._tmp.name) / "precious.txt"
        target.write_text("keep me")
        folder = self.raw / "sfx" / "hit_dry"
        folder.mkdir(parents=True)
        (folder / "1.wav.part").symlink_to(target)
        fake = self.fake
        code, _, err = self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        self.assertEqual(code, 2)  # the up-front scan of raw/ finds it
        self.assertIn("symlink", err)
        self.assertEqual(fake.calls, [])
        self.assertEqual(target.read_text(), "keep me")
        self.assert_untouched()

    def test_write_file_never_follows_a_part_symlink_planted_after_the_checks(self) -> None:
        target = Path(self._tmp.name) / "precious.txt"
        target.write_text("keep me")
        folder = self.raw / "sfx" / "x"
        folder.mkdir(parents=True)
        (folder / "1.wav.part").symlink_to(target)
        with mock.patch.object(generate, "_check_chain"):  # as if the link appeared between the check and the open
            with self.assertRaises(OSError):
                generate.write_file(self.raw, "sfx/x/1", WAV)
        self.assertEqual(target.read_text(), "keep me")

    def test_write_file_refuses_a_symlinked_folder(self) -> None:
        outside = Path(self._tmp.name) / "outside"
        outside.mkdir()
        self.raw.mkdir()
        (self.raw / "sfx").symlink_to(outside)
        with self.assertRaises(generate.UnsafePath):
            generate.write_file(self.raw, "sfx/x/1", WAV)
        self.assertEqual(list(outside.iterdir()), [])

    def test_a_symlinked_manifest_or_cue_book_is_refused(self) -> None:
        secret = Path(self._tmp.name) / "secret.json"
        secret.write_text("{}")
        self.manifest_path.symlink_to(secret)
        code, _, err = self.run_main("plan")
        self.assertEqual(code, 2)
        self.assertIn("symlink", err)

    def test_the_extension_comes_from_the_bytes(self) -> None:
        self.assertEqual(generate.extension(WAV), ".wav")
        self.assertEqual(generate.extension(MP3), ".mp3")
        self.assertEqual(generate.extension(b"ID3\x03"), ".mp3")


class SecretTest(Base):
    def test_a_missing_key_stops_a_paid_run_with_a_message(self) -> None:
        self.mocks[0].side_effect = generate.SecretsError("ELEVENLABS_API_KEY is not set in the file")
        code, _, err = self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        self.assertEqual(code, 2)
        self.assertIn("ELEVENLABS_API_KEY", err)


class DesignRoundsTest(Base):
    ARGS = ("voices", "design", "shieldman", "--voice", "shieldman_old", "--max-credits", "1000")

    def test_a_second_round_keeps_round_one_and_continues_the_numbering(self) -> None:
        fake = self.allow_network(Fake([preview_reply(2), preview_reply(2)]))
        self.run_main(*self.ARGS)
        code, _, _ = self.run_main(*self.ARGS, "--again")
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 2)
        base = self.raw / "design" / "shieldman" / "shieldman_old"
        self.assertEqual(sorted(p.name for p in base.iterdir()), ["1.mp3", "2.mp3", "3.mp3", "4.mp3"])
        self.assertEqual((base / "1.mp3").read_bytes(), MP3 + b"\x01")  # round one untouched
        m = self.manifest()
        self.assertEqual(m.find("design", "design/shieldman/shieldman_old/1")["generated_voice_id"], "gen1")
        self.assertEqual(m.find("design", "design/shieldman/shieldman_old/3")["generated_voice_id"], "gen1")
        self.assertEqual(m.find("design", "design/shieldman/shieldman_old/4")["generated_voice_id"], "gen2")
        self.assertEqual(m.find("design", "design/shieldman/shieldman_old/call2")["status"], "DONE")
        self.assertEqual(m.credits_spent(), 2000)

    def test_save_works_for_a_preview_from_either_round(self) -> None:
        fake = self.allow_network(Fake([preview_reply(2), preview_reply(2), ("application/json", b'{"voice_id": "VoiceNew9"}')]))
        self.run_main(*self.ARGS)
        self.run_main(*self.ARGS, "--again")
        code, _, _ = self.run_main("voices", "save", "shieldman", "--voice", "shieldman_old", "--pick", "4")
        self.assertEqual(code, 0)
        self.assertEqual(fake.calls[2][2]["generated_voice_id"], "gen2")

    def test_without_again_nothing_is_bought_once_a_round_exists(self) -> None:
        fake = self.allow_network(Fake([preview_reply(1)]))
        self.run_main(*self.ARGS)
        code, out, _ = self.run_main(*self.ARGS)
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 1)
        self.assertIn("--again", out)

    def test_a_fourth_round_is_refused(self) -> None:
        fake = self.allow_network(Fake([preview_reply(1)] * 3))
        self.run_main(*self.ARGS)
        self.run_main(*self.ARGS, "--again")
        self.run_main(*self.ARGS, "--again")
        code, _, err = self.run_main(*self.ARGS, "--again")
        self.assertEqual(code, 1)
        self.assertIn("3 rounds", err)
        self.assertEqual(len(fake.calls), 3)
        self.assertEqual(self.manifest().find("design", "design/shieldman/shieldman_old/call3")["status"], "DONE")

    def test_each_round_needs_its_own_budget(self) -> None:
        self.allow_network(Fake([preview_reply(1)]))
        self.run_main(*self.ARGS)
        code, _, _ = self.run_main("voices", "design", "shieldman", "--voice", "shieldman_old", "--again", "--max-credits", "999")
        self.assertEqual(code, 1)
        self.assertEqual(len(self.fake.calls), 1)

    def test_plan_reports_the_rounds(self) -> None:
        self.allow_network(Fake([preview_reply(1)]))
        self.run_main(*self.ARGS)
        _, out, _ = self.run_main("plan", "--batch", "design")
        self.assertIn("shieldman_old 1", out)
        self.assertIn("shieldman_young 0", out)


class WriteFailureTest(Base):
    def test_a_failed_write_after_a_paid_reply_is_interrupted(self) -> None:
        fake = self.allow_network()
        with mock.patch.object(generate, "write_file", side_effect=PermissionError(13, "Permission denied", "/x/y")):
            code, _, err = self.run_main("sfx", "--category", "melee", "--max-credits", "100")
        self.assertEqual(code, 1)
        self.assertEqual(len(fake.calls), 1)
        self.assertIn("paid", err)
        self.assertIn("couldn't be saved", err)
        self.assertIn("Permission denied", err)
        self.assertIn("by hand", err)
        self.assertEqual(self.manifest().find("sfx", "sfx/hit_dry/1")["status"], "INTERRUPTED")

    def test_an_unsafe_path_found_at_write_time_is_interrupted_too(self) -> None:
        self.allow_network()
        with mock.patch.object(generate, "write_file", side_effect=generate.UnsafePath("x is a symlink")):
            code, _, err = self.run_main("music", "calm", "--max-credits", "1800")
        self.assertEqual(code, 1)
        self.assertIn("symlink", err)
        self.assertEqual(self.manifest().find("music", "music/calm/1")["status"], "INTERRUPTED")

    def test_a_failed_preview_write_interrupts_the_design_call(self) -> None:
        self.allow_network(Fake([preview_reply(2)]))
        with mock.patch.object(generate, "write_file", side_effect=OSError(28, "No space left on device")):
            code, _, err = self.run_main("voices", "design", "shieldman", "--voice", "shieldman_old", "--max-credits", "1000")
        self.assertEqual(code, 1)
        self.assertIn("No space", err)
        self.assertEqual(self.manifest().find("design", "design/shieldman/shieldman_old/call")["status"], "INTERRUPTED")
        code, _, _ = self.run_main("voices", "design", "shieldman", "--voice", "shieldman_old", "--max-credits", "1000", "--again")
        self.assertEqual(code, 1)  # blocked until resolved by hand


class OddStatusTest(Base):
    def test_any_status_but_done_or_failed_blocks_and_is_never_rebought(self) -> None:
        for status in ("done", "Done", "SUCCEEDED", "", "wat", None):
            record = {"kind": "sfx", "label": "sfx/hit_dry/1", "credits": 20}
            if status is not None:
                record["status"] = status
            self.seed(record)
            with self.subTest(status=status):
                code, _, err = self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "999")
                self.assertEqual(code, 1)
                self.assertIn("unknown status", err)
                self.assertEqual(self.fake.calls, [])
                _, out, _ = self.run_main("plan", "--batch", "sfx")
                self.assertIn("blocked", out)
        self.assert_untouched()


class LockTest(Base):
    LOCK = "manifest.json.lock"

    def test_a_paid_run_holds_the_lock_and_removes_it_after(self) -> None:
        seen: list[bool] = []

        def transport(path: str, query: dict[str, str], body: dict[str, Any]) -> tuple[str, bytes]:
            seen.append((self.src / self.LOCK).exists())
            return "audio/wav", WAV

        self.allow_network(transport)  # type: ignore[arg-type]
        self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        self.assertEqual(seen, [True])
        self.assertFalse((self.src / self.LOCK).exists())

    def test_the_lock_is_removed_after_an_error(self) -> None:
        self.allow_network(Fake([ElevenLabsError("no reply", may_have_charged=True)]))
        code, _, _ = self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        self.assertEqual(code, 1)
        self.assertFalse((self.src / self.LOCK).exists())
        code, _, _ = self.run_main("sfx", "--cue", "nope", "--max-credits", "20")
        self.assertFalse((self.src / self.LOCK).exists())

    def test_an_existing_lock_refuses_every_paid_run_and_is_left_alone(self) -> None:
        (self.src / self.LOCK).write_text("")
        for argv in (("sfx", "--cue", "hit_dry", "--max-credits", "20"), ("probe", "--max-credits", "40"), ("music", "calm", "--max-credits", "9999"),
                     ("voices", "save", "shieldman", "--voice", "shieldman_old", "--pick", "1")):
            with self.subTest(argv=argv):
                code, _, err = self.run_main(*argv)
                self.assertEqual(code, 1)
                self.assertIn("another run may be going", err)
                self.assertIn("delete", err)
        self.assertTrue((self.src / self.LOCK).exists())
        self.assert_untouched()

    def test_plan_takes_no_lock_and_works_while_one_is_held(self) -> None:
        (self.src / self.LOCK).write_text("")
        code, _, _ = self.run_main("plan")
        self.assertEqual(code, 0)
        self.assertTrue((self.src / self.LOCK).exists())
        (self.src / self.LOCK).unlink()
        self.run_main("plan")
        self.assertFalse((self.src / self.LOCK).exists())

    def test_a_symlink_in_the_locks_place_is_not_followed(self) -> None:
        target = Path(self._tmp.name) / "precious.txt"
        target.write_text("keep me")
        (self.src / self.LOCK).symlink_to(target)
        code, _, _ = self.run_main("sfx", "--cue", "hit_dry", "--max-credits", "20")
        self.assertEqual(code, 1)
        self.assertEqual(target.read_text(), "keep me")
        self.assertTrue((self.src / self.LOCK).is_symlink())


class MissingFileTest(Base):
    def test_plan_flags_a_done_record_whose_file_is_gone(self) -> None:
        (self.raw / "sfx" / "hit_flesh").mkdir(parents=True)
        (self.raw / "sfx" / "hit_flesh" / "1.wav").write_bytes(WAV)
        self.seed({"kind": "sfx", "label": "sfx/hit_flesh/1", "status": "DONE", "credits": 40, "files": ["sfx/hit_flesh/1.wav"]},
                  {"kind": "sfx", "label": "sfx/hit_flesh/2", "status": "DONE", "credits": 40, "files": ["sfx/hit_flesh/2.wav"]})
        _, out, _ = self.run_main("plan", "--batch", "sfx")
        self.assertIn("bought but the file is gone", out)
        self.assertIn("sfx/hit_flesh/2.wav", out)
        self.assertNotIn("1.wav'", out)
        self.assertNotIn("blocked", out)  # it is a warning, and nothing is re-bought


if __name__ == "__main__":
    unittest.main()
