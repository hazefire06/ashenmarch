"""Tests for dsp.py: trim, level, loop crossfade and length matching, on synthesized 16-bit data (no ffmpeg)."""
from __future__ import annotations

import math
import unittest
from array import array

import dsp


def sine(freq: float, seconds: float, rate: int, amp: float = 0.5) -> array:
    return array("h", [int(32767 * amp * math.sin(2 * math.pi * freq * i / rate)) for i in range(int(seconds * rate))])


class TrimTest(unittest.TestCase):
    def test_trim_cuts_the_silence_and_fades_the_tail(self) -> None:
        rate = 8000
        loud = sine(440, 0.5, rate)
        frames = array("h", [0] * 4000) + loud + array("h", [0] * 2000)
        out = dsp.trim(frames, 1, rate, threshold_db=-50.0, tail_fade_ms=30.0)
        self.assertLess(abs(len(out) - len(loud)), 4)
        self.assertGreater(max(abs(x) for x in out[:200]), 0)  # the head starts on sound
        self.assertEqual(out[-1], 0)  # the tail fades to nothing
        fade = int(0.030 * rate)
        self.assertLess(max(abs(x) for x in out[-fade // 4:]), 0.3 * max(abs(x) for x in loud))
        self.assertEqual(max(abs(x) for x in out[:len(out) - fade]), max(abs(x) for x in loud[:len(out) - fade]))

    def test_trim_of_pure_silence_is_empty(self) -> None:
        self.assertEqual(len(dsp.trim(array("h", [0] * 100), 1, 8000)), 0)

    def test_trim_keeps_whole_stereo_frames(self) -> None:
        frames = array("h", [0, 0] * 50 + [9000, -9000] * 2000 + [0, 0] * 50)
        out = dsp.trim(frames, 2, 8000)
        self.assertEqual(len(out) % 2, 0)
        self.assertEqual(out[0], 9000)


class LevelTest(unittest.TestCase):
    def test_peak_normalise_hits_minus_one_dbfs(self) -> None:
        out = dsp.peak_normalise(sine(300, 0.2, 8000, amp=0.1), peak_db=-1.0)
        peak_db = 20 * math.log10(max(abs(x) for x in out) / 32768)
        self.assertAlmostEqual(peak_db, -1.0, delta=0.05)

    def test_peak_normalise_leaves_silence_alone(self) -> None:
        self.assertEqual(list(dsp.peak_normalise(array("h", [0] * 10))), [0] * 10)


class LoopTest(unittest.TestCase):
    def test_loop_crossfade_has_the_right_length_and_a_smooth_seam(self) -> None:
        rate = 8000
        src = sine(440, 3.3, rate)
        out = dsp.loop_crossfade(src, 1, rate, fade_s=1.0)
        self.assertEqual(len(out), len(src) - rate)  # 2.3 s
        step = max(abs(src[i + 1] - src[i]) for i in range(len(src) - 1))
        self.assertLessEqual(abs(out[0] - out[-1]), step)

    def test_loop_crossfade_stereo_keeps_frames_whole(self) -> None:
        rate = 1000
        src = array("h", [100, -100] * 3000)
        out = dsp.loop_crossfade(src, 2, rate, fade_s=1.0)
        self.assertEqual(len(out), len(src) - 2 * rate)

    def test_a_fade_longer_than_half_the_sound_is_shortened(self) -> None:
        out = dsp.loop_crossfade(sine(100, 1.0, 1000), 1, 1000, fade_s=5.0)
        self.assertEqual(len(out), 500)

    def test_match_length_cuts_both_to_the_shorter(self) -> None:
        a, b = dsp.match_length(array("h", range(10)), array("h", range(6)), 2)
        self.assertEqual((len(a), len(b)), (6, 6))
        a, b = dsp.match_length(array("h", range(9)), array("h", range(20)), 2)
        self.assertEqual((len(a), len(b)), (8, 8))


if __name__ == "__main__":
    unittest.main()
