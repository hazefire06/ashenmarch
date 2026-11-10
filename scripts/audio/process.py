"""The audio pipeline's free steps. `build` turns the cue book into a sidecar for the bank builder.

    python3 scripts/audio/process.py build [--sidecar PATH]

Writes audio-src/build/bank.json: one entry per cue, and one per music layer
(`music_<layer>`), each with the files it plays. Godot's builder
(build_sound_bank.gd) reads the sidecar and writes data/audio/sound_bank.tres.
Nothing here is paid, and nothing touches the network.

    python3 scripts/audio/process.py synthetic [--sidecar PATH]

For the Web measurement only. Writes ffmpeg tones and noise to
assets/audio/synthetic/ (git-ignored) and a sidecar that gives every cue
synthetic files, sized like the finished bank once decoded. See `make audio-synthetic`.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

import cuebook
from cuebook import CueError

ROOT: Path = Path(__file__).resolve().parents[2]
CUES: Path = ROOT / "audio-src" / "cues.toml"
LAYERS: Path = ROOT / "audio-src" / "music" / "prompts.toml"
VOICES: Path = ROOT / "audio-src" / "voices"
SIDECAR: Path = ROOT / "audio-src" / "build" / "bank.json"

SFX_FILE: str = "res://assets/audio/sfx/{cue}_{pick}.wav"
LOOP_FILE: str = "res://assets/audio/loop/{cue}.ogg"
MUSIC_FILE: str = "res://assets/audio/music/{layer}.ogg"
VOICE_FILE: str = "res://assets/audio/voice/{voice}/{line}.ogg"

SYNTH_DIR: Path = ROOT / "assets" / "audio" / "synthetic"
SYNTH_RES: str = "res://assets/audio/synthetic/"
SYNTH_VARIANTS: int = 3        # files per one-shot cue
SYNTH_ONESHOT_S: float = 3.2   # 54 cues x 3 x 3.2 s = 518 s, the finished bank's SFX plus barks
SYNTH_LOOP_S: float = 12.0
SYNTH_MUSIC_S: float = 110.0
SYNTH_RATE: int = 32000
# Homebrew's ffmpeg has no libvorbis, only the experimental native encoder (stereo, 44.1 kHz, fixed
# bitrate). Good enough for measurement-only files; real assets are encoded with oggenc (vorbis-tools).
OGG_CODEC: list[str] = ["-ac", "2", "-ar", "44100", "-c:a", "vorbis", "-strict", "-2", "-b:a", "96k"]


def _exists(root: Path, res_path: str, what: str) -> str:
    if not (root / res_path.removeprefix("res://")).is_file():
        raise CueError(f"{what}: picked file {res_path} doesn't exist")
    return res_path


def _cue_files(cue: cuebook.Cue, root: Path) -> list[str]:
    """Its picked assets once it has picks, else its placeholder, else nothing."""
    if cue.picks:
        if cue.loop:
            return [_exists(root, LOOP_FILE.format(cue=cue.id), cue.id)]
        return [_exists(root, SFX_FILE.format(cue=cue.id, pick=n), cue.id) for n in cue.picks]
    return [cue.placeholder] if cue.placeholder is not None else []


def _line_entries(voices_dir: Path | None, root: Path) -> list[dict[str, object]]:
    """One entry per bark line: its text, and for every voice that can say it the voiced file ("" if unbought)."""
    if voices_dir is None:
        return []
    files = cuebook.load_voices(voices_dir)
    light = [v for unit, f in files.items() if unit != cuebook.CLAN for v in f.voices]
    entries: list[dict[str, object]] = []
    for unit, voice_file in files.items():
        for line in voice_file.lines.values():
            speakers = light if unit == cuebook.CLAN else list(voice_file.voices)
            voiced = {
                v: _exists(root, VOICE_FILE.format(voice=v, line=line.id), f"{unit}/{line.id}") if v in line.picks else ""
                for v in speakers
            }
            entries.append({
                "id": line.id, "unit": unit, "trigger": line.trigger, "text": line.text,
                "clan": unit == cuebook.CLAN, "voices": voiced,
            })
    return entries


def build_sidecar(
    cues_path: Path, layers_path: Path, root: Path = ROOT, voices_dir: Path | None = None
) -> dict[str, object]:
    book = cuebook.load_cues(cues_path)
    entries: list[dict[str, object]] = []
    for cue in book.cues.values():
        entries.append({
            "id": cue.id, "category": cue.category, "bus": cue.bus, "level_db": cue.level_db,
            "pitch_spread": cue.pitch_spread, "max_voices": cue.max_voices, "loop": cue.loop,
            "playback": book.playback[cue.category], "files": _cue_files(cue, root),
        })
    for layer in cuebook.load_layers(layers_path).values():
        cue_id = f"music_{layer.id}"
        files = [_exists(root, MUSIC_FILE.format(layer=layer.id), cue_id)] if layer.picks else []
        entries.append({
            "id": cue_id, "category": "music", "bus": "Music", "level_db": 0.0,
            "pitch_spread": 0.0, "max_voices": 1, "loop": True,
            "playback": book.playback["music"], "files": files,
        })
    return {"cues": entries, "lines": _line_entries(voices_dir, root)}


def build(
    sidecar: Path, cues_path: Path = CUES, layers_path: Path = LAYERS, root: Path = ROOT, voices_dir: Path = VOICES
) -> int:
    try:
        data = build_sidecar(cues_path, layers_path, root, voices_dir)
    except CueError as err:
        print(f"process.py build: {err}", file=sys.stderr)
        return 1
    sidecar.parent.mkdir(parents=True, exist_ok=True)
    sidecar.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {sidecar} ({len(data['cues'])} cues, {len(data['lines'])} lines)")  # type: ignore[arg-type]
    return 0


class Synth:
    """One synthetic file to render: where, how long, and the ffmpeg input and options that make it."""

    def __init__(self, name: str, seconds: float, source: list[str], codec: list[str]) -> None:
        self.name = name
        self.seconds = seconds
        self.source = source
        self.codec = codec


def _oneshot(cue_id: str, n: int) -> Synth:
    """Variant 1 is a noise burst, 2 a low tone, 3 a high tone; pitch drifts with the cue's name."""
    seed = sum(map(ord, cue_id)) + n
    d = SYNTH_ONESHOT_S
    if n % 3 == 1:
        src = f"anoisesrc=d={d}:c=pink:r={SYNTH_RATE}:a=0.4:seed={seed}"
    else:
        freq = (180 if n % 3 == 2 else 700) + seed % 150
        src = f"sine=f={freq}:d={d}:r={SYNTH_RATE}"
    chain = f"{src},volume=0.5,afade=t=in:d=0.02,afade=t=out:st={d - 0.5}:d=0.5"
    return Synth(f"{cue_id}_{n}.wav", d, ["-f", "lavfi", "-i", chain],
                 ["-ac", "1", "-ar", str(SYNTH_RATE), "-c:a", "pcm_s16le"])


def _loop(cue_id: str) -> Synth:
    seed = sum(map(ord, cue_id))
    src = f"anoisesrc=d={SYNTH_LOOP_S}:c=brown:r=44100:a=0.3:seed={seed}"
    return Synth(f"{cue_id}.ogg", SYNTH_LOOP_S, ["-f", "lavfi", "-i", src, "-af", "pan=stereo|c0=c0|c1=c0"],
                 OGG_CODEC)


def _music(layer_id: str) -> Synth:
    base = 110.0 + (sum(map(ord, layer_id)) % 5) * 10
    d = SYNTH_MUSIC_S
    parts = [f"sine=f={base * r:.2f}:d={d}:r=44100" for r in (1.0, 1.5, 2.0, 2.52)]
    return Synth(f"{layer_id}.ogg", d, [arg for p in parts for arg in ("-f", "lavfi", "-i", p)]
                 + ["-filter_complex", "amix=inputs=4:normalize=1,volume=0.8,pan=stereo|c0=c0|c1=c0"],
                 OGG_CODEC)


def synthetic_plan(
    cues_path: Path = CUES, layers_path: Path = LAYERS, voices_dir: Path = VOICES
) -> tuple[list[Synth], dict[str, object]]:
    """Every file to render, and the sidecar that points each cue at its own."""
    book = cuebook.load_cues(cues_path)
    synths: list[Synth] = []
    entries: list[dict[str, object]] = []
    for cue in book.cues.values():
        made = [_loop(cue.id)] if cue.loop else [_oneshot(cue.id, n) for n in range(1, SYNTH_VARIANTS + 1)]
        synths += made
        entries.append({
            "id": cue.id, "category": cue.category, "bus": cue.bus, "level_db": cue.level_db,
            "pitch_spread": cue.pitch_spread, "max_voices": cue.max_voices, "loop": cue.loop,
            "playback": book.playback[cue.category], "files": [SYNTH_RES + m.name for m in made],
        })
    for layer in cuebook.load_layers(layers_path).values():
        made_m = _music(layer.id)
        synths.append(made_m)
        entries.append({
            "id": f"music_{layer.id}", "category": "music", "bus": "Music", "level_db": 0.0,
            "pitch_spread": 0.0, "max_voices": 1, "loop": True,
            "playback": book.playback["music"], "files": [SYNTH_RES + made_m.name],
        })
    # The lines stay unvoiced: the bark book the builder writes is the real one.
    return synths, {"cues": entries, "lines": _line_entries(voices_dir, ROOT)}


def _import_text(name: str) -> str:
    """The .import beside a synthetic file; Godot fills in uid and remap path on import."""
    if name.endswith(".wav"):
        return ("[remap]\n\nimporter=\"wav\"\ntype=\"AudioStreamWAV\"\n\n[params]\n\n"
                "force/8_bit=false\nforce/mono=false\nforce/max_rate=false\nforce/max_rate_hz=44100\n"
                "edit/trim=false\nedit/normalize=false\nedit/loop_mode=0\nedit/loop_begin=0\n"
                "edit/loop_end=-1\ncompress/mode=2\n")
    return ("[remap]\n\nimporter=\"oggvorbisstr\"\ntype=\"AudioStreamOggVorbis\"\n\n[params]\n\n"
            "loop=true\nloop_offset=0.0\nbpm=0.0\nbeat_count=0\nbar_beats=4\n")


def render(synth: Synth, out_dir: Path) -> None:
    dest = out_dir / synth.name  # synthetic() has already checked that ffmpeg exists
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *synth.source, *synth.codec, str(dest)], check=True)
    Path(str(dest) + ".import").write_text(_import_text(synth.name), encoding="utf-8")


def synthetic(sidecar: Path, out_dir: Path = SYNTH_DIR, cues_path: Path = CUES, layers_path: Path = LAYERS) -> int:
    if shutil.which("ffmpeg") is None:
        print("process.py synthetic: ffmpeg not found (brew install ffmpeg)", file=sys.stderr)
        return 1
    try:
        synths, data = synthetic_plan(cues_path, layers_path)
    except CueError as err:
        print(f"process.py synthetic: {err}", file=sys.stderr)
        return 1
    out_dir.mkdir(parents=True, exist_ok=True)
    for synth in synths:
        render(synth, out_dir)
    sidecar.parent.mkdir(parents=True, exist_ok=True)
    sidecar.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
    one_shot_s = sum(x.seconds for x in synths if x.name.endswith(".wav"))
    print(f"wrote {len(synths)} synthetic files ({one_shot_s:.0f} s of one-shots) and {sidecar} ({len(data['cues'])} cues)")  # type: ignore[arg-type]
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build", help="write the bank sidecar from the cue book")
    b.add_argument("--sidecar", type=Path, default=SIDECAR)
    y = sub.add_parser("synthetic", help="write synthetic test audio and a sidecar for it (Web measurement only)")
    y.add_argument("--sidecar", type=Path, default=SIDECAR)
    args = parser.parse_args(argv)
    if args.command == "synthetic":
        return synthetic(args.sidecar)
    return build(args.sidecar)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
