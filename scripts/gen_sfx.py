#!/usr/bin/env python3
"""Synthesizes Ashenmarch's placeholder sound effects as WAV files.

Everything here is original and procedural: filtered noise, sine/triangle/
square oscillators, pitch sweeps, simple FM, Karplus-Strong plucks and
exponential decay envelopes, layered. No samples, no recordings, no assets
from any existing game. The style target is a dark, low-fi, late-90s
battlefield; nothing is meant to be piercing, so the top end is rolled off
around 6-7 kHz.

Output is deterministic: every sound uses its own fixed-seed
random.Random, there is no wall-clock input, and only the standard library
is used (no numpy). Running the script twice produces byte-identical files
on the same Python and platform. (libm sin/exp/tanh can differ in the last
bit between platforms, which can flip an occasional 16-bit sample by one
LSB; that is inaudible and the files are not part of the sim.)

Format: mono, 16-bit PCM, 22050 Hz. One-shots are peak-normalized to
-1 dBFS (0.89) with a few ms of fade-in and fade-out. The two loops
(rain_loop, fire_loop) have no fades and loop seamlessly: the bed is
generated a crossfade-length longer than the final loop, the extra tail is
equal-power crossfaded into the head, and the transient layers (rain
droplets, fire pops) are added with modulo wrap-around so their tails flow
across the loop point.

Run it with:

    python3 scripts/gen_sfx.py [--out DIR]

The default output directory is assets/audio/sfx, resolved relative to the
repo root (this script's parent directory). Integration (a `make sfx`
target, Godot import, audio buses) lives elsewhere.
"""

from __future__ import annotations

import argparse
import math
import random
import struct
import wave
from pathlib import Path
from typing import Callable

Samples = list[float]

SAMPLE_RATE: int = 22050
PEAK: float = 0.89  # about -1 dBFS
TAU: float = 2.0 * math.pi


# ---------------------------------------------------------------------------
# Basics
# ---------------------------------------------------------------------------


def nsamp(seconds: float) -> int:
    """Number of samples in the given duration."""
    return int(round(seconds * SAMPLE_RATE))


def white(rng: random.Random, n: int) -> Samples:
    """Uniform white noise in [-1, 1]."""
    return [rng.uniform(-1.0, 1.0) for _ in range(n)]


def peak_of(x: Samples) -> float:
    return max((abs(s) for s in x), default=0.0)


def unit(x: Samples) -> Samples:
    """Scale so the peak magnitude is 1.0 (layers are balanced with explicit gains)."""
    p = peak_of(x)
    if p <= 0.0:
        return list(x)
    return [s / p for s in x]


def level(x: Samples, rms: float = 0.3) -> Samples:
    """Scale to a target RMS. Noise layers are balanced with this, since unit() peak-matching undersells noise."""
    if not x:
        return []
    cur = math.sqrt(sum(s * s for s in x) / len(x))
    if cur <= 0.0:
        return list(x)
    g = rms / cur
    return [s * g for s in x]


def scale(x: Samples, gain: float) -> Samples:
    return [s * gain for s in x]


def mul(a: Samples, b: Samples) -> Samples:
    """Sample-wise product (e.g. oscillator times envelope)."""
    return [p * q for p, q in zip(a, b)]


def mix(layers: list[tuple[Samples, float]], n: int | None = None) -> Samples:
    """Sum (samples, gain) layers; shorter layers are zero-padded."""
    length = n if n is not None else max(len(s) for s, _ in layers)
    out = [0.0] * length
    for samples, gain in layers:
        for i in range(min(length, len(samples))):
            out[i] += samples[i] * gain
    return out


def place(dst: Samples, src: Samples, start: int, gain: float = 1.0, wrap: bool = False) -> None:
    """Add src into dst at `start`. With wrap=True it wraps modulo len(dst) (for loops)."""
    n = len(dst)
    if n == 0:
        return
    for k, s in enumerate(src):
        i = start + k
        if wrap:
            i %= n
        elif i < 0 or i >= n:
            continue
        dst[i] += s * gain


def softclip(x: Samples, drive: float) -> Samples:
    """tanh saturation; adds low harmonics so sub-bass reads on small speakers."""
    norm = math.tanh(drive)
    return [math.tanh(s * drive) / norm for s in x]


# ---------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------


def lowpass(x: Samples, fc: float) -> Samples:
    """One-pole low-pass."""
    a = 1.0 - math.exp(-TAU * fc / SAMPLE_RATE)
    y = 0.0
    out: Samples = []
    for s in x:
        y += a * (s - y)
        out.append(y)
    return out


def lowpass2(x: Samples, fc: float) -> Samples:
    """Two cascaded one-poles (12 dB/oct)."""
    return lowpass(lowpass(x, fc), fc)


def highpass(x: Samples, fc: float) -> Samples:
    """One-pole high-pass (input minus its low-passed copy)."""
    lp = lowpass(x, fc)
    return [s - l for s, l in zip(x, lp)]


def bandpass(x: Samples, lo: float, hi: float) -> Samples:
    """Broad band-pass: high-pass at lo, two-pole low-pass at hi."""
    return highpass(lowpass2(x, hi), lo)


def lowpass_var(x: Samples, fcs: Samples) -> Samples:
    """One-pole low-pass with a per-sample cutoff (Hz)."""
    y = 0.0
    out: Samples = []
    for s, fc in zip(x, fcs):
        a = 1.0 - math.exp(-TAU * fc / SAMPLE_RATE)
        y += a * (s - y)
        out.append(y)
    return out


def resonator(x: Samples, fc: float, q: float) -> Samples:
    """RBJ biquad band-pass (constant peak gain). Used for formant-ish and wooden resonances."""
    w0 = TAU * fc / SAMPLE_RATE
    alpha = math.sin(w0) / (2.0 * q)
    a0 = 1.0 + alpha
    b0 = alpha / a0
    b2 = -alpha / a0
    a1 = -2.0 * math.cos(w0) / a0
    a2 = (1.0 - alpha) / a0
    x1 = x2 = y1 = y2 = 0.0
    out: Samples = []
    for s in x:
        y = b0 * s + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, s
        y2, y1 = y1, y
        out.append(y)
    return out


def svf_bandpass_var(x: Samples, fcs: Samples, q: float) -> Samples:
    """Chamberlin state-variable band-pass with a per-sample centre frequency.

    Keep fc below ~3 kHz at this sample rate so the filter stays stable.
    """
    low = 0.0
    band = 0.0
    damp = 1.0 / q
    out: Samples = []
    for s, fc in zip(x, fcs):
        f = 2.0 * math.sin(math.pi * fc / SAMPLE_RATE)
        low += f * band
        high = s - low - damp * band
        band += f * high
        out.append(band)
    return out


def smooth_noise(rng: random.Random, n: int, fc: float) -> Samples:
    """Unit-peak low-passed noise, for slow random modulation."""
    return unit(lowpass2(white(rng, n), fc))


# ---------------------------------------------------------------------------
# Oscillators and envelopes
# ---------------------------------------------------------------------------


def wave_at(phase: float, shape: str) -> float:
    """One sample of a waveform at `phase` (in cycles). All shapes start near zero."""
    if shape == "sine":
        return math.sin(TAU * phase)
    if shape == "tri":
        return 1.0 - 4.0 * abs(((phase + 0.25) % 1.0) - 0.5)
    if shape == "square":
        return 1.0 if (phase % 1.0) < 0.5 else -1.0
    if shape == "saw":
        return 2.0 * (phase % 1.0) - 1.0
    raise ValueError(f"unknown shape {shape!r}")


def osc(freqs: Samples, shape: str = "sine", phase0: float = 0.0) -> Samples:
    """Oscillator following a per-sample frequency curve (Hz); phase is accumulated."""
    out: Samples = []
    phase = phase0
    for f in freqs:
        out.append(wave_at(phase, shape))
        phase += f / SAMPLE_RATE
    return out


def const(value: float, n: int) -> Samples:
    return [value] * n


def exp_sweep(f0: float, f1: float, n: int) -> Samples:
    """Exponential pitch sweep from f0 to f1 across n samples."""
    if n <= 1:
        return [f0] * n
    ratio = f1 / f0
    return [f0 * ratio ** (i / (n - 1)) for i in range(n)]


def decay_sweep(f_end: float, f_start: float, tau: float, n: int) -> Samples:
    """Frequency that falls from f_start toward f_end with time constant tau (seconds)."""
    return [f_end + (f_start - f_end) * math.exp(-(i / SAMPLE_RATE) / tau) for i in range(n)]


def env_exp(n: int, tau: float, attack: float = 0.0) -> Samples:
    """Linear attack (seconds) into an exponential decay with time constant tau (seconds)."""
    out: Samples = []
    for i in range(n):
        t = i / SAMPLE_RATE
        a = min(1.0, t / attack) if attack > 0.0 else 1.0
        out.append(a * math.exp(-t / tau))
    return out


def damped_sine(freq: float, tau: float, n: int, phase0: float = 0.0) -> Samples:
    """A decaying sinusoid (one resonant mode)."""
    return [
        math.sin(TAU * (freq * i / SAMPLE_RATE + phase0)) * math.exp(-(i / SAMPLE_RATE) / tau)
        for i in range(n)
    ]


def modes(freqs: list[float], taus: list[float], gains: list[float], n: int) -> Samples:
    """Sum of damped sines: a struck-object model (inharmonic freqs sound metallic)."""
    return mix([(damped_sine(f, t, n), g) for f, t, g in zip(freqs, taus, gains)], n)


def fm_decay(carrier: float, ratio: float, index: float, tau: float, n: int) -> Samples:
    """Simple 2-operator FM with the modulation index decaying with the amplitude."""
    out: Samples = []
    for i in range(n):
        t = i / SAMPLE_RATE
        e = math.exp(-t / tau)
        mod = math.sin(TAU * carrier * ratio * t)
        out.append(math.sin(TAU * carrier * t + index * e * mod) * e)
    return out


def karplus_strong(rng: random.Random, freq: float, n: int, decay: float, burst_lp: float) -> Samples:
    """Karplus-Strong plucked string. The period is rounded to whole samples (pitch is approximate)."""
    period = max(2, int(round(SAMPLE_RATE / freq)))
    buf = unit(lowpass(white(rng, period), burst_lp))
    out: Samples = []
    prev = 0.0
    for i in range(n):
        idx = i % period
        cur = buf[idx]
        out.append(cur)
        buf[idx] = decay * 0.5 * (cur + prev)
        prev = cur
    return out


# ---------------------------------------------------------------------------
# Finishing and I/O
# ---------------------------------------------------------------------------


def fade(x: Samples, fade_in_ms: float, fade_out_ms: float) -> Samples:
    """Raised-cosine fade-in and fade-out to avoid clicks."""
    n = len(x)
    out = list(x)
    fi = min(n, nsamp(fade_in_ms / 1000.0))
    fo = min(n, nsamp(fade_out_ms / 1000.0))
    for i in range(fi):
        out[i] *= 0.5 - 0.5 * math.cos(math.pi * (i + 0.5) / fi)
    for i in range(fo):
        out[n - 1 - i] *= 0.5 - 0.5 * math.cos(math.pi * (i + 0.5) / fo)
    return out


def remove_dc(x: Samples) -> Samples:
    mean = sum(x) / len(x)
    return [s - mean for s in x]


def normalize(x: Samples, peak: float = PEAK) -> Samples:
    """Scale so the largest magnitude equals `peak`."""
    p = peak_of(x)
    if p <= 0.0:
        return list(x)
    g = peak / p
    return [s * g for s in x]


def finish(x: Samples, fade_in_ms: float = 2.0, fade_out_ms: float = 6.0) -> Samples:
    """Standard one-shot finish: remove DC, fade, then peak-normalize."""
    return normalize(fade(remove_dc(x), fade_in_ms, fade_out_ms))


def make_loop(x: Samples, crossfade: int) -> Samples:
    """Turn a continuous signal into a seamless loop of len(x) - crossfade samples.

    The last `crossfade` samples (the tail beyond the loop end) are blended
    into the first `crossfade` samples with an equal-power crossfade. Output
    sample N-1 is the original x[N-1] and output sample 0 is (almost exactly)
    the original x[N], which is the sample that followed x[N-1] in the
    continuous signal, so the loop point has no discontinuity.
    """
    n = len(x) - crossfade
    if n <= crossfade:
        raise ValueError("loop too short for its crossfade")
    out = x[:n]
    for i in range(crossfade):
        t = (i + 0.5) / crossfade
        w_in = math.sin(0.5 * math.pi * t)
        w_out = math.cos(0.5 * math.pi * t)
        out[i] = x[i] * w_in + x[n + i] * w_out
    return out


def quiet_join(loop: Samples) -> Samples:
    """Rotate a seamless loop so its join sits at the flattest point of the waveform.

    A loop is circular, so rotating it keeps it seamless. Doing so places the
    wrap between two neighbouring samples whose difference is as small as
    possible, which also keeps the loop's first and last samples close in
    value (and avoids a crackle pop landing right on the join).
    """
    n = len(loop)
    best_k = 0
    best_cost = float("inf")
    for k in range(n):
        cost = (
            abs(loop[k] - loop[k - 1])
            + abs(loop[(k + 1) % n] - loop[k])
            + abs(loop[k - 1] - loop[k - 2])
        )
        if cost < best_cost:
            best_cost = cost
            best_k = k
    return loop[best_k:] + loop[:best_k]


def write_wav(path: Path, x: Samples) -> None:
    """Write mono 16-bit PCM at SAMPLE_RATE."""
    ints = [max(-32768, min(32767, int(round(s * 32767.0)))) for s in x]
    frames = struct.pack(f"<{len(ints)}h", *ints)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(frames)


# ---------------------------------------------------------------------------
# Sounds (one function each; all return finished, normalized samples)
# ---------------------------------------------------------------------------


def ui_click() -> Samples:
    """Soft wooden tick for menu buttons."""
    rng = random.Random(1001)
    n = nsamp(0.040)
    wood = modes([1150.0, 2380.0], [0.006, 0.004], [1.0, 0.45], n)
    tick = mul(bandpass(white(rng, n), 900.0, 4000.0), env_exp(n, 0.0012))
    thud = mul(osc(decay_sweep(420.0, 700.0, 0.006, n)), env_exp(n, 0.007))
    x = mix([(wood, 1.0), (unit(tick), 0.5), (thud, 0.35)], n)
    return finish(lowpass(x, 5000.0), fade_in_ms=0.6, fade_out_ms=8.0)


def order_ack() -> Samples:
    """Low, muted two-note blip: first note falls, second note rises."""
    n = nsamp(0.120)
    n1 = nsamp(0.062)
    n2 = n - nsamp(0.052)

    def note(f0: float, f1: float, count: int, tau: float) -> Samples:
        freqs = exp_sweep(f0, f1, count)
        body = mix([(osc(freqs, "tri"), 0.8), (osc(freqs, "sine"), 0.5)], count)
        return mul(body, env_exp(count, tau, attack=0.004))

    x = [0.0] * n
    place(x, note(300.0, 235.0, n1, 0.030), 0)
    place(x, note(235.0, 350.0, n2, 0.035), nsamp(0.052), gain=1.0)
    return finish(lowpass2(x, 1400.0), fade_in_ms=2.0, fade_out_ms=14.0)


def order_deny() -> Samples:
    """Dull low buzz and thud meaning 'can't'."""
    n = nsamp(0.180)
    freqs = decay_sweep(104.0, 150.0, 0.05, n)
    buzz = osc(freqs, "square")
    # Amplitude buzz around 38 Hz so it reads as a rattle rather than a tone.
    am = [0.65 + 0.35 * math.sin(TAU * 38.0 * i / SAMPLE_RATE) for i in range(n)]
    buzz = mul(lowpass2(mul(buzz, am), 900.0), env_exp(n, 0.075, attack=0.003))
    thud = mul(osc(decay_sweep(80.0, 160.0, 0.025, n)), env_exp(n, 0.045, attack=0.002))
    x = mix([(unit(buzz), 0.9), (thud, 0.6)], n)
    return finish(softclip(x, 1.4), fade_in_ms=2.0, fade_out_ms=20.0)


def sword_hit() -> Samples:
    """Blade strike: inharmonic metallic partials, a noise transient and a body thud."""
    rng = random.Random(1004)
    n = nsamp(0.180)
    clang = modes(
        [1240.0, 1976.0, 2704.0, 3589.0, 4710.0],
        [0.050, 0.038, 0.026, 0.016, 0.010],
        [1.0, 0.8, 0.6, 0.4, 0.25],
        n,
    )
    ring = fm_decay(1530.0, 2.17, 2.2, 0.030, n)
    snap = mul(bandpass(white(rng, n), 1500.0, 6000.0), env_exp(n, 0.0035))
    thud = mul(osc(decay_sweep(95.0, 200.0, 0.012, n)), env_exp(n, 0.030, attack=0.001))
    x = mix([(unit(clang), 0.8), (unit(ring), 0.4), (unit(snap), 0.55), (thud, 0.4)], n)
    return finish(lowpass2(x, 6500.0), fade_in_ms=0.8, fade_out_ms=12.0)


def shield_block() -> Samples:
    """Duller wood-and-metal knock, lower than sword_hit."""
    rng = random.Random(1005)
    n = nsamp(0.200)
    knock = modes(
        [430.0, 716.0, 1130.0, 1654.0],
        [0.040, 0.028, 0.018, 0.010],
        [1.0, 0.7, 0.45, 0.25],
        n,
    )
    rim = modes([1010.0, 1830.0], [0.060, 0.030], [0.6, 0.3], n)
    snap = mul(lowpass2(white(rng, n), 1800.0), env_exp(n, 0.004))
    thud = mul(osc(decay_sweep(85.0, 160.0, 0.015, n)), env_exp(n, 0.050, attack=0.001))
    x = mix([(unit(knock), 1.0), (unit(rim), 0.3), (unit(snap), 0.5), (thud, 0.45)], n)
    return finish(lowpass2(x, 3200.0), fade_in_ms=0.8, fade_out_ms=14.0)


def death() -> Samples:
    """Muffled grunt-like thump: pitched-down buzzy source through formant resonators, plus body falls."""
    rng = random.Random(1006)
    n = nsamp(0.450)
    jitter = smooth_noise(rng, n, 14.0)
    base = decay_sweep(68.0, 150.0, 0.20, n)
    freqs = [f * (1.0 + 0.04 * j) for f, j in zip(base, jitter)]
    glottal = lowpass(osc(freqs, "saw"), 900.0)
    breath = lowpass2(white(rng, n), 1600.0)
    source = mix([(unit(glottal), 1.0), (unit(breath), 0.35)], n)
    voiced = mix([(resonator(source, 480.0, 4.0), 1.0), (resonator(source, 860.0, 5.0), 0.7)], n)
    voiced = unit(mul(voiced, env_exp(n, 0.17, attack=0.030)))
    hit = mul(osc(decay_sweep(55.0, 120.0, 0.040, n)), env_exp(n, 0.070, attack=0.002))
    late = [0.0] * n
    fall = unit(mul(lowpass2(white(rng, n), 260.0), env_exp(n, 0.045, attack=0.002)))
    fall_tone = mul(osc(decay_sweep(50.0, 90.0, 0.030, n)), env_exp(n, 0.060, attack=0.002))
    place(late, mix([(fall, 0.7), (fall_tone, 0.8)], n), nsamp(0.230))
    x = mix([(voiced, 1.0), (hit, 0.45), (late, 0.5)], n)
    return finish(lowpass2(x, 1800.0), fade_in_ms=3.0, fade_out_ms=35.0)


def bow_release() -> Samples:
    """String twang (Karplus-Strong) with a limb thump and an air whoosh."""
    rng = random.Random(1007)
    n = nsamp(0.250)
    string = karplus_strong(rng, 150.0, n, decay=0.986, burst_lp=2200.0)
    string = mul(lowpass2(string, 3600.0), env_exp(n, 0.110, attack=0.001))
    # A second, octave-up string adds the metallic brightness of a taut bowstring.
    string2 = karplus_strong(rng, 301.0, n, decay=0.980, burst_lp=2600.0)
    string2 = mul(lowpass2(string2, 3600.0), env_exp(n, 0.070, attack=0.001))
    limb = mul(osc(decay_sweep(80.0, 160.0, 0.012, n)), env_exp(n, 0.022, attack=0.001))
    fcs = decay_sweep(700.0, 2100.0, 0.060, n)
    air = svf_bandpass_var(white(rng, n), fcs, 1.2)
    air = mul(air, env_exp(n, 0.070, attack=0.012))
    x = mix([(unit(string), 0.85), (unit(string2), 0.25), (limb, 0.6), (unit(air), 0.55)], n)
    return finish(lowpass2(x, 5500.0), fade_in_ms=1.0, fade_out_ms=30.0)


def arrow_impact() -> Samples:
    """Short thock of an arrow biting into earth or wood."""
    rng = random.Random(1008)
    n = nsamp(0.120)
    body = mul(osc(decay_sweep(110.0, 230.0, 0.015, n)), env_exp(n, 0.030, attack=0.001))
    wood = modes([560.0, 930.0], [0.014, 0.010], [1.0, 0.5], n)
    dirt = mul(lowpass2(white(rng, n), 1100.0), env_exp(n, 0.010))
    x = mix([(body, 0.5), (unit(wood), 0.7), (level(dirt, 0.25), 1.0)], n)
    return finish(lowpass2(x, 2800.0), fade_in_ms=0.6, fade_out_ms=15.0)


def grenade_bounce() -> Samples:
    """Small clink of a clay bottle on the ground."""
    rng = random.Random(1009)
    n = nsamp(0.090)
    clay = modes([1350.0, 2210.0, 3420.0], [0.012, 0.008, 0.005], [1.0, 0.6, 0.3], n)
    tick = mul(bandpass(white(rng, n), 1800.0, 4500.0), env_exp(n, 0.0018))
    thump = mul(osc(decay_sweep(200.0, 300.0, 0.006, n)), env_exp(n, 0.010, attack=0.0008))
    x = mix([(unit(clay), 1.0), (unit(tick), 0.45), (thump, 0.25)], n)
    return finish(lowpass2(x, 5000.0), fade_in_ms=0.5, fade_out_ms=12.0)


def explosion() -> Samples:
    """Deep boom: sub sine drop, low-passed noise burst with long decay, rumble and a crackle tail."""
    rng = random.Random(1010)
    n = nsamp(1.4)
    boom = mul(osc(decay_sweep(30.0, 115.0, 0.14, n)), env_exp(n, 0.30, attack=0.004))
    boom = softclip(boom, 2.2)
    fcs = [140.0 + 3300.0 * math.exp(-(i / SAMPLE_RATE) / 0.10) for i in range(n)]
    body = lowpass_var(lowpass_var(white(rng, n), fcs), fcs)
    body = mul(level(body, 0.5), env_exp(n, 0.26, attack=0.002))
    rumble = mul(level(lowpass2(white(rng, n), 130.0), 0.5), env_exp(n, 0.50, attack=0.020))
    crack = mul(bandpass(white(rng, n), 700.0, 5000.0), env_exp(n, 0.007))
    tail = [0.0] * n
    t = 0.40
    while t < 1.30:
        length = nsamp(rng.uniform(0.002, 0.009))
        pop = mul(lowpass2(white(rng, length), rng.uniform(900.0, 2800.0)), env_exp(length, length / SAMPLE_RATE / 3.0))
        amp = rng.uniform(0.3, 1.0) * math.exp(-(t - 0.40) / 0.60)
        place(tail, pop, nsamp(t), gain=amp * 4.0)
        t += rng.uniform(0.012, 0.075)
    x = mix([(boom, 0.7), (body, 1.5), (rumble, 0.6), (level(crack, 0.5), 0.4), (tail, 0.55)], n)
    return finish(x, fade_in_ms=1.0, fade_out_ms=120.0)


def lightning() -> Samples:
    """Sharp crack (with a couple of re-strikes) then a rolling rumble."""
    rng = random.Random(1011)
    n = nsamp(1.0)
    crack = [0.0] * n
    for start_s, amp, tau in ((0.0, 1.0, 0.016), (0.028, 0.6, 0.012), (0.071, 0.4, 0.010)):
        length = nsamp(0.12)
        burst = mul(bandpass(white(rng, length), 1100.0, 6500.0), env_exp(length, tau, attack=0.0004))
        place(crack, unit(burst), nsamp(start_s), gain=amp)
    zap_n = nsamp(0.060)
    zap = mul(osc(exp_sweep(1700.0, 380.0, zap_n), "square"), env_exp(zap_n, 0.018, attack=0.001))
    zap = lowpass2(zap, 4500.0)
    zap_full = [0.0] * n
    place(zap_full, zap, 0)
    fcs = [150.0 + 700.0 * math.exp(-(i / SAMPLE_RATE) / 0.22) for i in range(n)]
    rumble = lowpass_var(lowpass_var(white(rng, n), fcs), fcs)
    wobble = smooth_noise(rng, n, 5.0)
    swell = []
    for i in range(n):
        t = i / SAMPLE_RATE
        m = max(0.08, 1.0 + 0.75 * wobble[i])
        swell.append((1.0 - math.exp(-t / 0.07)) * math.exp(-t / 0.42) * m)
    rumble = unit(mul(rumble, swell))
    x = mix([(unit(crack), 1.0), (zap_full, 0.22), (rumble, 1.0)], n)
    return finish(x, fade_in_ms=0.5, fade_out_ms=80.0)


def fire_ignite() -> Samples:
    """Whoosh of flames catching: rising band-passed noise, low fwoomp, a few crackles."""
    rng = random.Random(1012)
    n = nsamp(0.600)
    peak_t = 0.22
    fcs = []
    env = []
    for i in range(n):
        t = i / SAMPLE_RATE
        fcs.append(240.0 + 1500.0 * min(1.0, t / 0.45) ** 1.4)
        if t < peak_t:
            env.append(math.sin(0.5 * math.pi * t / peak_t) ** 2)
        else:
            env.append(math.exp(-(t - peak_t) / 0.13))
    whoosh = unit(mul(svf_bandpass_var(white(rng, n), fcs, 1.0), env))
    rumble = unit(mul(lowpass2(white(rng, n), 220.0), env))
    fwoomp = mul(osc(exp_sweep(48.0, 85.0, n)), env_exp(n, 0.12, attack=0.050))
    pops = [0.0] * n
    for _ in range(7):
        length = nsamp(rng.uniform(0.002, 0.006))
        pop = mul(lowpass2(white(rng, length), rng.uniform(1200.0, 3200.0)), env_exp(length, length / SAMPLE_RATE / 3.0))
        place(pops, pop, nsamp(rng.uniform(0.14, 0.52)), gain=rng.uniform(1.5, 4.0))
    x = mix([(whoosh, 1.0), (rumble, 0.5), (fwoomp, 0.45), (pops, 0.12)], n)
    return finish(lowpass2(x, 3600.0), fade_in_ms=6.0, fade_out_ms=60.0)


def heal() -> Samples:
    """Soft warm chime: a staggered C-E-G triad of sines with gentle decay."""
    n = nsamp(0.500)
    x = [0.0] * n
    notes = ((523.25, 0.000, 0.150, 1.0), (659.25, 0.040, 0.140, 0.8), (784.00, 0.085, 0.130, 0.6))
    for freq, onset, tau, gain in notes:
        count = n - nsamp(onset)
        vibrato = [freq * (1.0 + 0.003 * math.sin(TAU * 5.5 * i / SAMPLE_RATE)) for i in range(count)]
        tone = mix([(osc(vibrato, "sine"), 1.0), (osc([f * 2.0 for f in vibrato], "sine"), 0.18)], count)
        place(x, mul(tone, env_exp(count, tau, attack=0.008)), nsamp(onset), gain=gain)
    return finish(lowpass2(x, 4200.0), fade_in_ms=3.0, fade_out_ms=60.0)


def gas_hiss() -> Samples:
    """Hissing burst that fades."""
    rng = random.Random(1014)
    n = nsamp(0.800)
    hiss = bandpass(white(rng, n), 1000.0, 3600.0)
    flutter = smooth_noise(rng, n, 22.0)
    am = [max(0.2, 1.0 + 0.35 * f) for f in flutter]
    env = env_exp(n, 0.280, attack=0.045)
    body = unit(lowpass2(white(rng, n), 600.0))
    x = mix([(unit(mul(mul(hiss, am), env)), 1.0), (mul(body, env), 0.25)], n)
    return finish(lowpass2(x, 4800.0), fade_in_ms=6.0, fade_out_ms=80.0)


def rain_loop() -> Samples:
    """Steady rain: filtered noise bed plus sparse droplet ticks. Seamless loop, no fades."""
    rng = random.Random(1015)
    n = nsamp(4.0)
    xfade = nsamp(0.30)
    preroll = nsamp(0.10)  # generated then discarded so filter start-up never reaches the loop
    total = preroll + n + xfade

    patter = lowpass(bandpass(white(rng, total), 450.0, 2800.0), 4500.0)
    wash = lowpass2(white(rng, total), 320.0)
    gust = smooth_noise(rng, total, 0.7)
    patter = [p * (1.0 + 0.12 * g) for p, g in zip(patter, gust)]
    bed = mix([(level(patter, 0.3), 1.0), (level(wash, 0.3), 0.45)], total)
    loop = make_loop(bed[preroll:], xfade)
    loop = scale(unit(loop), 0.6)

    # Droplets: damped sine plinks with a small upward chirp. They are added with modulo
    # wrap-around, so a droplet near the end rings on into the start of the loop.
    t = rng.expovariate(38.0)
    while t < n / SAMPLE_RATE:
        length = nsamp(rng.uniform(0.006, 0.018))
        f0 = rng.uniform(1500.0, 3400.0)
        freqs = [f0 * (1.0 + 0.5 * min(1.0, (i / SAMPLE_RATE) / 0.006)) for i in range(length)]
        plink = mul(osc(freqs, "sine"), env_exp(length, rng.uniform(0.002, 0.005)))
        place(loop, plink, nsamp(t), gain=rng.uniform(0.04, 0.20), wrap=True)
        t += rng.expovariate(38.0)
    # No filters or fades after this point: they would not be circular and would break the join.
    return normalize(remove_dc(quiet_join(loop)))


def fire_loop() -> Samples:
    """Crackling fire bed: low rumble, soft roar and random pops. Seamless loop, no fades."""
    rng = random.Random(1016)
    n = nsamp(3.0)
    xfade = nsamp(0.30)
    preroll = nsamp(0.10)
    total = preroll + n + xfade

    rumble = unit(lowpass2(white(rng, total), 230.0))
    roar = unit(lowpass(bandpass(white(rng, total), 350.0, 2400.0), 4000.0))
    flicker = smooth_noise(rng, total, 3.5)
    flicker2 = smooth_noise(rng, total, 9.0)
    bed = []
    for i in range(total):
        r_amp = 1.0 + 0.30 * flicker[i]
        h_amp = max(0.05, 0.55 + 0.45 * flicker2[i])
        bed.append(rumble[i] * r_amp * 0.9 + roar[i] * h_amp * 0.50)
    loop = make_loop(bed[preroll:], xfade)
    loop = scale(unit(loop), 0.55)

    # Crackle pops, added with modulo wrap-around so their tails cross the loop point.
    t = rng.expovariate(22.0)
    while t < n / SAMPLE_RATE:
        big = rng.random() < 0.12
        length = nsamp(rng.uniform(0.004, 0.014) if big else rng.uniform(0.0015, 0.006))
        cutoff = rng.uniform(900.0, 3400.0)
        pop = mul(lowpass2(white(rng, length), cutoff), env_exp(length, length / SAMPLE_RATE / 3.0))
        gain = rng.uniform(0.55, 1.0) * 2.4 if big else rng.uniform(0.15, 0.6) * 2.4
        place(loop, pop, nsamp(t), gain=gain, wrap=True)
        t += rng.expovariate(22.0)
    return normalize(remove_dc(quiet_join(loop)))


SOUNDS: dict[str, Callable[[], Samples]] = {
    "ui_click.wav": ui_click,
    "order_ack.wav": order_ack,
    "order_deny.wav": order_deny,
    "sword_hit.wav": sword_hit,
    "shield_block.wav": shield_block,
    "death.wav": death,
    "bow_release.wav": bow_release,
    "arrow_impact.wav": arrow_impact,
    "grenade_bounce.wav": grenade_bounce,
    "explosion.wav": explosion,
    "lightning.wav": lightning,
    "fire_ignite.wav": fire_ignite,
    "heal.wav": heal,
    "gas_hiss.wav": gas_hiss,
    "rain_loop.wav": rain_loop,
    "fire_loop.wav": fire_loop,
}


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Generate Ashenmarch placeholder sound effects.")
    parser.add_argument(
        "--out",
        type=Path,
        default=repo_root / "assets" / "audio" / "sfx",
        help="output directory (default: assets/audio/sfx under the repo root)",
    )
    args = parser.parse_args()
    out_dir: Path = args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    total_bytes = 0
    for name, fn in SOUNDS.items():
        samples = fn()
        path = out_dir / name
        write_wav(path, samples)
        size = path.stat().st_size
        total_bytes += size
        print(f"{name:20s} {len(samples) / SAMPLE_RATE:6.3f} s {size:9,d} bytes")
    print(f"{'total':20s} {'':>8s} {total_bytes:9,d} bytes ({len(SOUNDS)} files) -> {out_dir}")


if __name__ == "__main__":
    main()
