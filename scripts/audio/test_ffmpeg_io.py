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
