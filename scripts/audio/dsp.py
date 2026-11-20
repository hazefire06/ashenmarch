"""Sample-level audio work on interleaved 16-bit frames (`array('h')`). Pure Python, no ffmpeg, so it can be tested alone.

A `frames` array holds `channels` samples per frame, interleaved. Every function returns a new array and leaves its input alone.
"""
from __future__ import annotations

import math
from array import array

PEAK: int = 32767


def _db(db: float) -> float:
    return 10.0 ** (db / 20.0)


def trim(frames: array, channels: int, rate: int, threshold_db: float = -50.0, tail_fade_ms: float = 30.0) -> array:
    """Cuts leading and trailing frames quieter than `threshold_db` (re full scale), then fades the last `tail_fade_ms` to zero.
    A take that never gets above the threshold comes back empty."""
    limit = 32768 * _db(threshold_db)
    total = len(frames) // channels
    first = next((i for i in range(total) if _loud(frames, i, channels, limit)), None)
    if first is None:
        return array("h")
    last = next(i for i in range(total - 1, -1, -1) if _loud(frames, i, channels, limit))
    out = array("h", frames[first * channels:(last + 1) * channels])
    count = len(out) // channels
    fade = min(count, max(1, round(rate * tail_fade_ms / 1000.0)))
    for k in range(fade):  # k = 0 is the first faded frame; the last frame lands on zero
        gain = (fade - 1 - k) / fade
        base = (count - fade + k) * channels
        for c in range(channels):
            out[base + c] = int(out[base + c] * gain)
    return out


def _loud(frames: array, index: int, channels: int, limit: float) -> bool:
    base = index * channels
    return any(abs(frames[base + c]) > limit for c in range(channels))


def peak_normalise(frames: array, peak_db: float = -1.0) -> array:
    """Scales the whole sound so its loudest sample sits at `peak_db`. Silence is returned as it is."""
    top = max((abs(x) for x in frames), default=0)
    if top == 0:
        return array("h", frames)
    gain = min(32768 * _db(peak_db), PEAK) / top
    return array("h", [max(-PEAK, min(PEAK, round(x * gain))) for x in frames])


def loop_crossfade(frames: array, channels: int, rate: int, fade_s: float = 1.0) -> array:
    """Folds the last `fade_s` seconds into the start with an equal-power crossfade. The result is `fade_s` shorter, and its
    last frame is followed by its first as if the source had kept playing. A fade over half the sound is shortened to half."""
    total = len(frames) // channels
    fade = min(round(fade_s * rate), total // 2)
    if fade <= 0:
        return array("h", frames[:total * channels])
    out = array("h", frames[fade * channels:(total - fade) * channels])  # the middle, untouched
    head = array("h")
    tail_at = (total - fade) * channels
    for i in range(fade):
        angle = (i / fade) * (math.pi / 2)
        fade_in, fade_out = math.sin(angle), math.cos(angle)
        for c in range(channels):
            mixed = frames[i * channels + c] * fade_in + frames[tail_at + i * channels + c] * fade_out
            head.append(max(-PEAK, min(PEAK, round(mixed))))
    return head + out


def match_length(a: array, b: array, channels: int) -> tuple[array, array]:
    """Both cut to the shorter, in whole frames."""
    keep = min(len(a), len(b)) // channels * channels
    return array("h", a[:keep]), array("h", b[:keep])
