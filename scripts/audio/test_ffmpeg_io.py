"""Tests for ffmpeg_io.py. The ones that run a tool are skipped when it is missing."""
from __future__ import annotations

import math
import shutil
import tempfile
import unittest
from array import array
from pathlib import Path
from unittest import mock

import ffmpeg_io

HAS_FFMPEG: bool = shutil.which("ffmpeg") is not None
HAS_OGGENC: bool = shutil.which("oggenc") is not None


def tone(seconds: float, rate: int, amp: float = 0.3) -> array:
    return array("h", [int(32767 * amp * math.sin(2 * math.pi * 440 * i / rate)) for i in range(int(seconds * rate))])


class RequireTest(unittest.TestCase):
    def test_a_missing_tool_is_an_error_that_names_it(self) -> None:
        with mock.patch.object(shutil, "which", return_value=None):
            with self.assertRaisesRegex(ffmpeg_io.ToolMissing, "ffmpeg"):
                ffmpeg_io.require_ffmpeg()
            with self.assertRaisesRegex(ffmpeg_io.ToolMissing, "oggenc"):
                ffmpeg_io.require_oggenc()


class WavTest(unittest.TestCase):
    def test_write_wav_round_trips_through_probe_without_ffmpeg(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "a.wav"
            ffmpeg_io.write_wav(tone(0.1, 32000), 32000, 1, path)
            self.assertEqual(ffmpeg_io.probe(path), (32000, 1))


class PlantedFileTest(unittest.TestCase):
    """L4: a raw take is a committed file a PR can plant, so ffmpeg is told what it is and what it may open."""

    def test_the_demuxer_comes_from_the_extension_and_only_the_file_protocol_is_allowed(self) -> None:
        seen: list[list[str]] = []

        def fake_run(cmd: list[str], data: bytes | None = None) -> object:
            seen.append(cmd)
            return mock.Mock(stdout=b"", stderr=b"")

        with mock.patch.object(ffmpeg_io, "_run", fake_run):
            ffmpeg_io.decode(Path("/x/1.wav"), 32000, 1)
            ffmpeg_io.decode(Path("/x/2.mp3"), 32000, 1)
        for cmd, demuxer in zip(seen, ("wav", "mp3")):
            before_input = cmd[:cmd.index("-i")]
            self.assertEqual(before_input[before_input.index("-f") + 1], demuxer)
            self.assertEqual(before_input[before_input.index("-protocol_whitelist") + 1], "file")

    def test_an_unknown_extension_is_refused_without_running_anything(self) -> None:
        with mock.patch.object(ffmpeg_io, "_run", side_effect=AssertionError("ran")):
            for name in ("1.concat", "1.txt", "1", "1.wav.part"):
                with self.subTest(name=name):
                    with self.assertRaises(ffmpeg_io.AudioError):
                        ffmpeg_io.decode(Path("/x") / name, 32000, 1)

    def test_probe_reads_ffprobes_json_not_text_a_tag_could_fake(self) -> None:
        reply = mock.Mock(stdout=b'{"streams": [{"sample_rate": "44100", "channels": 2, "tags": {"comment": "Audio: x, 99999 Hz, mono"}}]}',
                          stderr=b"Stream #0:0: Audio: mp3, 99999 Hz, mono, fltp")
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(ffmpeg_io, "_run", return_value=reply) as run:
            path = Path(tmp) / "1.mp3"
            path.write_bytes(b"not a wav")
            self.assertEqual(ffmpeg_io.probe(path), (44100, 2))
        self.assertEqual(run.call_args.args[0][0], "ffprobe")
        self.assertIn("json", run.call_args.args[0])

    def test_a_probe_reply_that_is_not_a_sane_stream_is_refused(self) -> None:
        for out in (b"{}", b'{"streams": []}', b"not json", b'{"streams": [{"sample_rate": "0", "channels": 1}]}',
                    b'{"streams": [{"sample_rate": "44100", "channels": 99}]}', b'{"streams": [{"sample_rate": "x", "channels": 1}]}'):
            with self.subTest(out=out), tempfile.TemporaryDirectory() as tmp, mock.patch.object(ffmpeg_io, "_run", return_value=mock.Mock(stdout=out, stderr=b"")):
                path = Path(tmp) / "1.mp3"
                path.write_bytes(b"x")
                with self.assertRaises(ffmpeg_io.AudioError):
                    ffmpeg_io.probe(path)

    @unittest.skipUnless(HAS_FFMPEG and shutil.which("ffprobe"), "ffmpeg and ffprobe not installed")
    def test_an_ffconcat_list_named_wav_is_not_opened_as_a_list(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            real = Path(tmp) / "real.wav"
            ffmpeg_io.write_wav(tone(0.5, 32000), 32000, 1, real)
            planted = Path(tmp) / "1.wav"
            planted.write_text(f"ffconcat version 1.0\nfile '{real}'\n")
            with self.assertRaises(ffmpeg_io.AudioError):
                ffmpeg_io.decode(planted, 32000, 1)
            with self.assertRaises(ffmpeg_io.AudioError):
                ffmpeg_io.probe(planted)

    @unittest.skipUnless(HAS_FFMPEG, "ffmpeg not installed")
    def test_a_take_decoding_to_more_than_the_limit_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(ffmpeg_io, "MAX_DECODED_S", 1):
            path = Path(tmp) / "long.wav"
            ffmpeg_io.write_wav(tone(3.0, 8000), 8000, 1, path)
            with self.assertRaisesRegex(ffmpeg_io.AudioError, "longer than"):
                ffmpeg_io.decode(path, 8000, 1)
            short = Path(tmp) / "short.wav"
            ffmpeg_io.write_wav(tone(0.5, 8000), 8000, 1, short)
            self.assertAlmostEqual(len(ffmpeg_io.decode(short, 8000, 1)), 4000, delta=40)

    def test_the_default_limit_is_11_minutes(self) -> None:
        self.assertEqual(ffmpeg_io.MAX_DECODED_S, 660)


class AtomicTest(unittest.TestCase):
    def test_a_wav_write_that_fails_partway_leaves_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "a.wav"
            with mock.patch.object(ffmpeg_io, "_to_bytes", side_effect=RuntimeError("killed")):
                with self.assertRaises(RuntimeError):
                    ffmpeg_io.write_wav(tone(0.1, 8000), 8000, 1, path)
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_a_failed_wav_write_keeps_the_old_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "a.wav"
            ffmpeg_io.write_wav(tone(0.1, 8000), 8000, 1, path)
            old = path.read_bytes()
            with mock.patch.object(ffmpeg_io, "_publish", side_effect=OSError("killed")):
                with self.assertRaises(OSError):
                    ffmpeg_io.write_wav(tone(0.2, 8000), 8000, 1, path)
            self.assertEqual(path.read_bytes(), old)
            self.assertEqual([p.name for p in Path(tmp).iterdir()], ["a.wav"])

    def test_an_ogg_encode_that_dies_partway_leaves_no_file(self) -> None:
        def die(cmd: list[str], data: bytes | None = None) -> None:
            Path(cmd[cmd.index("-o") + 1]).write_bytes(b"half")
            raise ffmpeg_io.AudioError("oggenc failed")
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(ffmpeg_io, "_run", die):
                with self.assertRaises(ffmpeg_io.AudioError):
                    ffmpeg_io.write_ogg(tone(0.1, 8000), 8000, 1, Path(tmp) / "a.ogg")
            self.assertEqual(list(Path(tmp).iterdir()), [])


@unittest.skipUnless(HAS_FFMPEG, "ffmpeg not installed")
class FfmpegTest(unittest.TestCase):
    def test_decode_gives_the_asked_rate_and_channels(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "a.wav"
            ffmpeg_io.write_wav(tone(0.5, 32000), 32000, 1, path)
            out = ffmpeg_io.decode(path, 16000, 1)
            self.assertAlmostEqual(len(out), 8000, delta=40)
            stereo = ffmpeg_io.decode(path, 32000, 2)
            self.assertAlmostEqual(len(stereo), 32000, delta=40)

    def test_loudness_normalise_moves_the_level_toward_the_target(self) -> None:
        quiet = tone(3.0, 32000, amp=0.02)
        out = ffmpeg_io.loudness_normalise(quiet, 32000, 1, -18.0)
        self.assertGreater(max(abs(x) for x in out), 2 * max(abs(x) for x in quiet))

    def test_loudness_normalise_leaves_silence_alone(self) -> None:
        silent = array("h", [0] * 32000)
        self.assertEqual(len(ffmpeg_io.loudness_normalise(silent, 32000, 1, -18.0)), len(silent))


@unittest.skipUnless(HAS_FFMPEG and HAS_OGGENC, "ffmpeg or oggenc not installed")
class OggTest(unittest.TestCase):
    def test_write_ogg_makes_a_vorbis_file_that_decodes_back(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "a.ogg"
            ffmpeg_io.write_ogg(tone(1.0, 32000) , 32000, 1, path, quality=4)
            self.assertEqual(path.read_bytes()[:4], b"OggS")
            self.assertEqual(ffmpeg_io.probe(path), (32000, 1))
            self.assertAlmostEqual(len(ffmpeg_io.decode(path, 32000, 1)), 32000, delta=2000)


if __name__ == "__main__":
    unittest.main()
