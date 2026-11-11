"""ffmpeg and oggenc, as the audio pipeline uses them.

ffmpeg decodes anything to 16-bit PCM and measures loudness (`loudnorm`). Ogg Vorbis is encoded by `oggenc` (vorbis-tools):
Homebrew's ffmpeg has no libvorbis, so ffmpeg never encodes Ogg here. WAV is written with the stdlib. Nothing here uses the network.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import wave
from array import array
from pathlib import Path


class ToolMissing(Exception):
    """ffmpeg or oggenc isn't installed."""


class AudioError(Exception):
    """A tool failed on a file, or a file isn't usable audio."""


def require_ffmpeg() -> None:
    if shutil.which("ffmpeg") is None:
        raise ToolMissing("ffmpeg not found (brew install ffmpeg)")


def require_oggenc() -> None:
    if shutil.which("oggenc") is None:
        raise ToolMissing("oggenc not found (brew install vorbis-tools)")


def _to_array(raw: bytes) -> array:
    frames = array("h")
    frames.frombytes(raw[:len(raw) // 2 * 2])
    if sys.byteorder == "big":
        frames.byteswap()
    return frames


def _to_bytes(frames: array) -> bytes:
    if sys.byteorder == "big":
        frames = array("h", frames)
        frames.byteswap()
    return frames.tobytes()


def _run(cmd: list[str], data: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    try:
        done = subprocess.run(cmd, input=data, capture_output=True, check=False)
    except OSError as err:
        raise AudioError(f"{cmd[0]} couldn't run: {err.strerror}") from None
    if done.returncode != 0:
        tail = done.stderr.decode("utf-8", "replace").strip().splitlines()[-1:]  # last line only: it can echo a file
        raise AudioError(f"{cmd[0]} failed: {tail[0][:120] if tail else 'no message'}")
    return done


def probe(path: Path) -> tuple[int, int]:
    """(sample rate, channels) of a file. WAV is read directly; anything else is asked of ffmpeg."""
    try:
        with wave.open(str(path), "rb") as wav:
            return wav.getframerate(), wav.getnchannels()
    except (wave.Error, EOFError):
        pass
    except OSError as err:
        raise AudioError(f"{path.name} can't be read: {err.strerror}") from None
    text = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(path)], capture_output=True, check=False).stderr.decode("utf-8", "replace")
    match = re.search(r"Audio: .*?, (\d+) Hz, ([^,\n]+)", text)
    if match is None:
        raise AudioError(f"{path.name} has no audio stream ffmpeg can read")
    layout = match.group(2).strip()
    count = re.match(r"(\d+) channels", layout)
    channels = 1 if layout == "mono" else int(count.group(1)) if count else 2
    return int(match.group(1)), channels


def decode(path: Path, rate: int, channels: int) -> array:
    """The whole file as 16-bit frames at `rate` and `channels` (ffmpeg mixes down or up to fit)."""
    done = _run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(path), "-f", "s16le", "-acodec", "pcm_s16le",
                 "-ac", str(channels), "-ar", str(rate), "-"])
    return _to_array(done.stdout)


def _part(path: Path) -> Path:
    return path.with_name(path.name + ".part")


def _publish(part: Path, path: Path) -> None:
    os.replace(part, path)


def write_wav(frames: array, rate: int, channels: int, path: Path) -> None:
    """Written to <path>.part and renamed, so a killed write never leaves a file that looks finished."""
    path.parent.mkdir(parents=True, exist_ok=True)
    part = _part(path)
    try:
        with wave.open(str(part), "wb") as out:
            out.setnchannels(channels)
            out.setsampwidth(2)
            out.setframerate(rate)
            out.writeframes(_to_bytes(frames))
        _publish(part, path)
    except BaseException:
        part.unlink(missing_ok=True)
        raise


def write_ogg(frames: array, rate: int, channels: int, path: Path, quality: int = 5) -> None:
    """Ogg Vorbis through oggenc, at its quality scale (4 for loops and barks, 5 for music)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    part = _part(path)  # written there and renamed, so a killed encode never leaves a file that looks finished
    try:
        _run(["oggenc", "--quiet", "--raw", "--raw-bits=16", f"--raw-chan={channels}", f"--raw-rate={rate}", "--raw-endianness=0",
              "-q", str(quality), "-o", str(part), "-"], _to_bytes(frames))
        _publish(part, path)
    except BaseException:
        part.unlink(missing_ok=True)
        raise


def loudness_normalise(frames: array, rate: int, channels: int, lufs: float) -> array:
    """Two-pass ffmpeg `loudnorm` to an integrated loudness of `lufs`, with a -1.5 dB true-peak ceiling. Silence is returned as it is."""
    if not any(frames):
        return array("h", frames)
    raw = _to_bytes(frames)
    source = ["ffmpeg", "-hide_banner", "-f", "s16le", "-ar", str(rate), "-ac", str(channels), "-i", "-"]
    target = f"I={lufs}:TP=-1.5:LRA=11"
    first = _run([*source, "-af", f"loudnorm={target}:print_format=json", "-f", "null", "-"], raw)
    text = first.stderr.decode("utf-8", "replace")
    start = text.rfind("{")
    try:
        seen = json.loads(text[start:text.rfind("}") + 1])
        measured = (float(seen["input_i"]), float(seen["input_tp"]), float(seen["input_lra"]), float(seen["input_thresh"]), float(seen["target_offset"]))
    except (ValueError, KeyError):
        raise AudioError("ffmpeg loudnorm gave no measurement") from None
    if not all(abs(x) < 1000 for x in measured):  # -inf for a take too quiet to measure
        return array("h", frames)
    i, tp, lra, thresh, offset = measured
    second = f"loudnorm={target}:measured_I={i}:measured_TP={tp}:measured_LRA={lra}:measured_thresh={thresh}:offset={offset}:linear=true"
    done = _run([*source, "-af", second, "-f", "s16le", "-acodec", "pcm_s16le", "-ar", str(rate), "-ac", str(channels), "-"], raw)
    return _to_array(done.stdout)
