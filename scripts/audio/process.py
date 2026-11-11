"""The audio pipeline's free steps: audition pages, picks, the finished assets and the bank sidecar.

    python3 scripts/audio/process.py batch NAME        NAME: a cue category, loops, music, voices-<unit>, design-<unit> or ab
    python3 scripts/audio/process.py picks FILE        FILE: picks-<batch>.json, saved from an audition page
    python3 scripts/audio/process.py build [--sidecar PATH] [--force]

`batch` trims and levels every raw take of a batch (audio-src/raw/, bought by generate.py) into audio-src/audition/NAME/ and writes
audio-src/audition/NAME.html. `picks` checks a picks file against the cue book and the voice files, then writes it into their
`picks = ...` lines (a design file only prints the generate.py commands to run). `build` writes each picked take to assets/audio/
(one-shots as mono WAV, barks as mono Ogg, loops and music as Ogg that loops), the Godot .import files and the rows between the
audio markers in assets/LICENSES.md, then the sidecar audio-src/build/bank.json: one entry per cue, and one per music layer
(`music_<layer>`), each with the files it plays. Godot's builder (build_sound_bank.gd) reads the sidecar and writes
data/audio/sound_bank.tres. Ogg is encoded by oggenc, ffmpeg decodes and measures loudness. Nothing here is paid, and nothing
touches the network.

    python3 scripts/audio/process.py synthetic [--sidecar PATH]

For the Web measurement only. Writes ffmpeg tones and noise to
assets/audio/synthetic/ (git-ignored) and a sidecar that gives every cue
synthetic files, sized like the finished bank once decoded. See `make audio-synthetic`.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tomllib
from array import array
from dataclasses import dataclass
from pathlib import Path

import audition
import cuebook
import dsp
import ffmpeg_io
import picks as picks_io
from audition import Take
from cuebook import CueError
from ffmpeg_io import AudioError, ToolMissing

ROOT: Path = Path(__file__).resolve().parents[2]
CUES: Path = ROOT / "audio-src" / "cues.toml"
LAYERS: Path = ROOT / "audio-src" / "music" / "prompts.toml"
VOICES: Path = ROOT / "audio-src" / "voices"
SIDECAR: Path = ROOT / "audio-src" / "build" / "bank.json"
LICENSES: Path = ROOT / "assets" / "LICENSES.md"

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


def _line_entries(voices_dir: Path, root: Path) -> list[dict[str, object]]:
    """One entry per bark line: its text, and for every voice that can say it the voiced file ("" if unbought)."""
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
    cues_path: Path, layers_path: Path, root: Path = ROOT, voices_dir: Path = VOICES
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


def write_sidecar(
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
    # Lines come from the real voice files, so the bark book the builder writes matches a real build
    # (a line is voiced once it has picks; synthetic audio never stands in for a voice).
    return synths, {"cues": entries, "lines": _line_entries(voices_dir, ROOT)}


WAV_PARAMS: dict[str, str] = {"compress/mode": "2", "edit/loop_mode": "0"}  # QOA; no loop


def _import_text(name: str, loop: bool = True) -> str:
    """A new .import beside an audio file; Godot fills in uid and remap path on import."""
    if name.endswith(".wav"):
        return ("[remap]\n\nimporter=\"wav\"\ntype=\"AudioStreamWAV\"\n\n[params]\n\n"
                "force/8_bit=false\nforce/mono=false\nforce/max_rate=false\nforce/max_rate_hz=44100\n"
                "edit/trim=false\nedit/normalize=false\nedit/loop_mode=0\nedit/loop_begin=0\n"
                "edit/loop_end=-1\ncompress/mode=2\n")
    return ("[remap]\n\nimporter=\"oggvorbisstr\"\ntype=\"AudioStreamOggVorbis\"\n\n[params]\n\n"
            f"loop={'true' if loop else 'false'}\nloop_offset=0.0\nbpm=0.0\nbeat_count=0\nbar_beats=4\n")


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


# ---- the finished assets --------------------------------------------------------------------------------------------

AUDITION_DIR: str = "audio-src/audition"
GUARDED: tuple[str, ...] = ("assets/audio", "audio-src/raw")  # nothing under these may be a symlink
BARK_LUFS: float = -18.0
BED_LUFS: float = -23.0  # beds, marching loops and music; both targets are set by ear
LOOP_FADE_S: float = 1.0
OGG_QUALITY: dict[str, int] = {"bark": 4, "loop": 4, "music": 5}
TERMS: str = "ElevenLabs paid plan: commercial use, no attribution"
ENDPOINTS: dict[str, str] = {"sfx": "sound-generation", "voices": "text-to-speech", "music": "music"}
BEGIN: str = "<!-- audio:begin -->"
END: str = "<!-- audio:end -->"
MAX_PICKS_BYTES: int = 1_000_000
SAFE_TEXT: re.Pattern[str] = re.compile(r"[^A-Za-z0-9_.\-]")


class UnsafePath(Exception):
    """A symlink under assets/audio/ or audio-src/raw/."""


def check_no_symlinks(root: Path, rels: tuple[str, ...] = GUARDED) -> None:
    """Stops before any write if a folder on the way to, or anything under, a guarded folder is a symlink. The repo is public,
    so a PR could plant one."""
    for rel in rels:
        here = root
        for part in rel.split("/"):
            here = here / part
            try:
                is_link = stat.S_ISLNK(os.lstat(here).st_mode)
            except FileNotFoundError:
                break  # nothing below a missing folder can be a link
            if is_link:
                raise UnsafePath(f"{here.relative_to(root)} is a symlink; replace it with a real folder or file")
        else:
            for folder, names, files in os.walk(here, followlinks=False):
                for entry in sorted(names + files):
                    if stat.S_ISLNK(os.lstat(os.path.join(folder, entry)).st_mode):
                        raise UnsafePath(f"{Path(folder, entry).relative_to(root)} is a symlink; replace it with a real folder or file")


def find_raw(folder: Path, take: int) -> Path | None:
    """audio-src/raw/.../<take>.wav or .mp3, whichever generate.py wrote."""
    for ext in (".wav", ".mp3"):
        path = folder / f"{take}{ext}"
        if path.is_file():
            return path
    return None


def _raw_takes(folder: Path) -> dict[int, Path]:
    found: dict[int, Path] = {}
    if folder.is_dir():
        for path in sorted(folder.iterdir()):
            if path.suffix in (".wav", ".mp3") and path.stem.isdigit() and path.is_file():
                found.setdefault(int(path.stem), path)
    return found


def render_take(path: Path, kind: str) -> tuple[array, int, int]:
    """One raw take, trimmed and levelled for its kind. Returns frames, rate and channels. The rate is the file's own, and loops
    and music keep its channel count (two at most); one-shots and barks are mono."""
    rate, source_channels = ffmpeg_io.probe(path)
    channels = 1 if kind in ("oneshot", "bark") else min(source_channels, 2)
    frames = ffmpeg_io.decode(path, rate, channels)
    if kind in ("oneshot", "bark"):
        frames = dsp.trim(frames, channels, rate)
        if not frames:
            raise AudioError("the take is silent")
        frames = dsp.peak_normalise(frames) if kind == "oneshot" else ffmpeg_io.loudness_normalise(frames, rate, channels, BARK_LUFS)
    else:
        frames = ffmpeg_io.loudness_normalise(frames, rate, channels, BED_LUFS)
        if kind == "loop":
            frames = dsp.loop_crossfade(frames, channels, rate, LOOP_FADE_S)
    return frames, rate, channels


@dataclass(frozen=True)
class Asset:
    """One finished file: what it is made from and where it goes."""
    kind: str  # oneshot, bark, loop or music
    dest: str  # relative to the project root
    source: Path
    what: str  # "cue hit_flesh take 2", for messages and the licence row
    ident: str  # the cue or line id
    record: tuple[str, str]  # the manifest record's kind and label


def plan_assets(cues_path: Path, layers_path: Path, voices_dir: Path, root: Path) -> list[Asset]:
    """Every picked take, with the raw file it comes from. A pick with no raw file is an error."""
    raw = root / "audio-src" / "raw"
    plan: list[Asset] = []

    def add(kind: str, res: str, folder: str, take: int, what: str, ident: str, record_kind: str) -> None:
        source = find_raw(raw / folder, take)
        if source is None:
            raise CueError(f"{what}: picked take {take} has no file under audio-src/raw/{folder}/")
        plan.append(Asset(kind, res.removeprefix("res://"), source, f"{what} take {take}", ident, (record_kind, f"{folder}/{take}")))

    for cue in cuebook.load_cues(cues_path).cues.values():
        if cue.loop and cue.picks:
            add("loop", LOOP_FILE.format(cue=cue.id), f"sfx/{cue.id}", cue.picks[0], f"cue {cue.id}", cue.id, "sfx")
        elif cue.picks:
            for n in cue.picks:
                add("oneshot", SFX_FILE.format(cue=cue.id, pick=n), f"sfx/{cue.id}", n, f"cue {cue.id}", cue.id, "sfx")
    for layer in cuebook.load_layers(layers_path).values():
        if layer.picks:
            add("music", MUSIC_FILE.format(layer=layer.id), f"music/{layer.id}", layer.picks[0], f"layer {layer.id}", layer.id, "music")
    for voice_file in cuebook.load_voices(voices_dir).values():
        for line in voice_file.lines.values():
            for voice, take in line.picks.items():
                add("bark", VOICE_FILE.format(voice=voice, line=line.id), f"voices/{voice}/{line.id}", take,
                    f"line {line.id} ({voice})", line.id, "voices")
    return plan


def _newer(dest: Path, sources: list[Path]) -> bool:
    return dest.is_file() and all(dest.stat().st_mtime >= s.stat().st_mtime for s in sources)


def write_asset(frames: array, rate: int, channels: int, asset: Asset, root: Path) -> None:
    dest = root / asset.dest
    if asset.kind == "oneshot":
        ffmpeg_io.write_wav(frames, rate, channels, dest)
    else:
        ffmpeg_io.write_ogg(frames, rate, channels, dest, OGG_QUALITY[asset.kind])


def render_assets(todo: list[Asset], root: Path) -> None:
    """Renders and writes the assets. The music layers are cut to one length, so they go together."""
    layers: list[tuple[Asset, array, int, int]] = []
    for asset in todo:
        try:
            frames, rate, channels = render_take(asset.source, asset.kind)
        except AudioError as err:
            raise AudioError(f"{asset.what}: {err}") from None
        if asset.kind == "music":
            layers.append((asset, frames, rate, channels))
            continue
        write_asset(frames, rate, channels, asset, root)
        print(f"wrote {asset.dest} ({len(frames) // channels / rate:.2f} s)")
    if layers:
        if len({(rate, ch) for _, _, rate, ch in layers}) > 1:
            raise AudioError("the music layers differ in sample rate or channels, so they can't be cut to one length; buy them in one format")
        shortest = min((f for _, f, _, _ in layers), key=len)
        for asset, frames, rate, channels in layers:
            cut = dsp.match_length(frames, shortest, channels)[0]
            write_asset(cut, rate, channels, asset, root)
            print(f"wrote {asset.dest} ({len(cut) // channels / rate:.2f} s)")


# ---- Godot import files ---------------------------------------------------------------------------------------------

def ensure_import(dest: Path, required: dict[str, str]) -> bool:
    """Writes dest.import if it's missing, or fixes the params in `required` in place if they differ, so Godot's uid and path lines
    survive. Returns True if it wrote anything."""
    path = dest.with_name(dest.name + ".import")
    if not path.is_file():
        text = _import_text(dest.name, required.get("loop", "true") == "true")
        path.write_text(text, encoding="utf-8")
        return True
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    start = next((i for i, x in enumerate(lines) if x.strip() == "[params]"), None)
    if start is None:
        raise CueError(f"{path.name} has no [params] section; delete it and Godot will make a new one")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith("[")), len(lines))
    changed = False
    for key, value in required.items():
        want = f"{key}={value}\n"
        at = next((i for i in range(start + 1, end) if lines[i].split("=", 1)[0].strip() == key), None)
        if at is None:
            lines.insert(end, want)
            end += 1
            changed = True
        elif lines[at].split("=", 1)[1].strip() != value:
            lines[at] = want
            changed = True
    if changed:
        path.write_text("".join(lines), encoding="utf-8")
    return changed


def import_params(asset: Asset) -> dict[str, str]:
    if asset.kind == "oneshot":
        return WAV_PARAMS
    return {"loop": "false" if asset.kind == "bark" else "true"}


# ---- LICENSES.md ----------------------------------------------------------------------------------------------------

def _clean(value: object) -> str:
    return SAFE_TEXT.sub("", str(value))


def _date(record: dict[str, object] | None, source: Path) -> str:
    stamp = record.get("finished_at") if record else None
    if isinstance(stamp, int) and not isinstance(stamp, bool) and 0 < stamp < 10**11:
        when = datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc)
    else:
        when = datetime.datetime.fromtimestamp(source.stat().st_mtime, datetime.timezone.utc)
    return when.strftime("%Y-%m-%d")


def _manifest_records(path: Path) -> dict[tuple[str, str], dict[str, object]]:
    try:
        tasks = json.loads(path.read_text(encoding="utf-8")).get("tasks", [])
    except (OSError, ValueError, AttributeError):
        return {}
    return {(str(t.get("kind")), str(t.get("label"))): t for t in tasks if isinstance(t, dict)}


def licence_rows(plan: list[Asset], manifest: Path) -> list[str]:
    records = _manifest_records(manifest)
    rows: list[str] = []
    for asset in sorted(plan, key=lambda a: a.dest):
        record = records.get(asset.record)
        model = _clean(record.get("model", "")) if record else ""
        source = f"ElevenLabs {ENDPOINTS[asset.record[0]]}" + (f" ({model})" if model else "")
        parts = asset.record[1].split("/")
        noun = {"sfx": "cue", "music": "layer", "voices": "line"}[asset.record[0]]
        voice = f" ({parts[1]})" if asset.record[0] == "voices" else ""
        rows.append(f"| `{asset.dest}` | {source} | {TERMS} | {_date(record, asset.source)} | "
                    f"{noun} `{asset.ident}`{voice}, take {parts[-1]}; trimmed and levelled by scripts/audio/process.py |")
    return rows


def update_licences(text: str, rows: list[str]) -> str:
    """Replaces what lies between the audio markers, and adds the markers after the existing rows if they are missing."""
    block = ""
    if rows:
        block = ("\nGenerated by `scripts/audio/process.py build`; edit nothing between these markers.\n\n"
                 "| File | Source | Terms | Date | Made from |\n|---|---|---|---|---|\n" + "\n".join(rows) + "\n\n")
    if BEGIN not in text and END not in text:
        return text + "\n" + BEGIN + "\n" + (block.lstrip("\n") if block else "") + END + "\n"
    first, last = text.find(BEGIN), text.find(END)
    if first < 0 or last < first or text.count(BEGIN) != 1 or text.count(END) != 1:
        raise CueError(f"LICENSES.md: the audio markers {BEGIN} and {END} must each appear once, begin first")
    return text[:first + len(BEGIN)] + "\n" + block.lstrip("\n") + text[last:] if block else text[:first + len(BEGIN)] + "\n" + text[last:]


# ---- build ----------------------------------------------------------------------------------------------------------

def build(
    sidecar: Path, cues_path: Path = CUES, layers_path: Path = LAYERS, root: Path = ROOT, voices_dir: Path = VOICES,
    force: bool = False,
) -> int:
    licences = root / "assets" / "LICENSES.md"
    try:
        check_no_symlinks(root)
        plan = plan_assets(cues_path, layers_path, voices_dir, root)
        # Everything that can refuse does so before the first write.
        todo = [a for a in plan if force or not _fresh(a, plan, root)]
        if todo:
            ffmpeg_io.require_ffmpeg()
            if any(a.kind != "oneshot" for a in todo):
                ffmpeg_io.require_oggenc()
        text = licences.read_text(encoding="utf-8") if licences.is_file() else ""
        if not text:
            raise CueError(f"{licences.relative_to(root)} is missing")
        new_text = update_licences(text, licence_rows(plan, root / "audio-src" / "manifest.json"))
        render_assets(todo, root)
        for asset in plan:
            if ensure_import(root / asset.dest, import_params(asset)):
                print(f"wrote {asset.dest}.import")
    except (CueError, UnsafePath, ToolMissing, AudioError, OSError) as err:
        print(f"process.py build: {err}", file=sys.stderr)
        return 1
    if new_text != text:
        licences.write_text(new_text, encoding="utf-8")
        print(f"wrote {licences.relative_to(root)} ({len(plan)} audio rows)")
    return write_sidecar(sidecar, cues_path, layers_path, root, voices_dir)


def _fresh(asset: Asset, plan: list[Asset], root: Path) -> bool:
    """True if the finished file is at least as new as its raw take (for music, as every layer's, since they are cut together)."""
    group = [a for a in plan if a.kind == "music"] if asset.kind == "music" else [asset]
    return all(_newer(root / a.dest, [a.source]) for a in group)


# ---- picks ----------------------------------------------------------------------------------------------------------

def _take_error(what: str, value: object, takes: int, folder: Path, seen: list[int]) -> str | None:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= takes:
        return f"{what}: each pick must be a take number from 1 to {takes}"
    if value in seen:
        return f"{what}: take {value} is listed twice"
    if find_raw(folder, value) is None:
        return f"{what}: take {value} has no downloaded file"
    return None


def picks_file(
    path: Path, cues_path: Path = CUES, layers_path: Path = LAYERS, voices_dir: Path = VOICES, root: Path = ROOT
) -> int:
    """Checks a picks file against the cue book and the voice files, then writes it. Any error and nothing is written."""
    raw = root / "audio-src" / "raw"
    try:
        check_no_symlinks(root)
        if path.stat().st_size > MAX_PICKS_BYTES:
            raise CueError("the picks file is too big")
        data = json.loads(path.read_text(encoding="utf-8"))
        book = cuebook.load_cues(cues_path)
        layers = cuebook.load_layers(layers_path)
        files = cuebook.load_voices(voices_dir)
    except (CueError, UnsafePath, OSError, ValueError) as err:
        print(f"process.py picks: {err if isinstance(err, (CueError, UnsafePath)) else 'the picks file can not be read as JSON'}", file=sys.stderr)
        return 1
    kinds = [k for k in ("cues", "lines", "design") if isinstance(data, dict) and k in data]
    if len(kinds) != 1 or not isinstance(data[kinds[0]], dict) or not data[kinds[0]]:
        print("process.py picks: the file must hold one of cues, lines or design, as a non-empty object", file=sys.stderr)
        return 1
    batch = data.get("batch")
    errors: list[str] = []
    if kinds[0] == "design":
        return _design_picks(data["design"], batch, files, raw)
    cue_picks: dict[str, list[int]] = {}
    layer_picks: dict[str, list[int]] = {}
    line_picks: dict[str, dict[str, int]] = {}
    unit_of: dict[str, str] = {}
    for key, value in data[kinds[0]].items():
        try:
            ident = cuebook.check_id(key, kinds[0])
        except CueError as err:
            errors.append(str(err))
            continue
        if kinds[0] == "cues":
            _check_cue_pick(ident, value, book, layers, raw, cue_picks, layer_picks, errors)
        else:
            _check_line_pick(ident, value, files, raw, line_picks, unit_of, errors)
    if errors:
        print("process.py picks: nothing written:\n  " + "\n  ".join(errors), file=sys.stderr)
        return 1
    try:
        writes = _picks_text(cues_path, layers_path, voices_dir, cue_picks, layer_picks, line_picks, unit_of, files)
    except (picks_io.PicksError, OSError, UnicodeDecodeError) as err:
        print(f"process.py picks: nothing written: {err}", file=sys.stderr)
        return 1
    for target, text in writes.items():
        target.write_text(text, encoding="utf-8", newline="")
        print(f"wrote picks to {target.name}")
    return 0


def _check_cue_pick(ident: str, value: object, book: cuebook.CueBook, layers: dict[str, cuebook.Layer], raw: Path,
                    cue_picks: dict[str, list[int]], layer_picks: dict[str, list[int]], errors: list[str]) -> None:
    if ident in book.cues:
        takes, folder, loop, out = book.cues[ident].takes, raw / "sfx" / ident, book.cues[ident].loop, cue_picks
    elif ident in layers:
        takes, folder, loop, out = layers[ident].takes, raw / "music" / ident, True, layer_picks
    else:
        errors.append(f"{ident}: no such cue or music layer")
        return
    if not isinstance(value, list):
        errors.append(f"{ident}: picks must be a list of take numbers")
        return
    if loop and len(value) > 1:
        errors.append(f"{ident}: a loop keeps one take")
        return
    seen: list[int] = []
    for n in value:
        problem = _take_error(ident, n, takes, folder, seen)
        if problem:
            errors.append(problem)
            return
        seen.append(n)
    out[ident] = seen


def _check_line_pick(ident: str, value: object, files: dict[str, cuebook.VoiceFile], raw: Path,
                     line_picks: dict[str, dict[str, int]], unit_of: dict[str, str], errors: list[str]) -> None:
    unit = next((u for u, f in files.items() if ident in f.lines), None)
    if unit is None:
        errors.append(f"{ident}: no such line")
        return
    allowed = {v for u, f in files.items() if u != cuebook.CLAN for v in f.voices} if unit == cuebook.CLAN else set(files[unit].voices)
    if not isinstance(value, dict) or not value:
        errors.append(f"{ident}: picks must be a non-empty object of voice: take")
        return
    chosen: dict[str, int] = {}
    for voice, take in value.items():
        try:
            voice_id = cuebook.check_id(voice, f"{ident} voice")
        except CueError as err:
            errors.append(str(err))
            continue
        if voice_id not in allowed:
            errors.append(f"{ident}: {voice_id} isn't a voice of {unit}")
            continue
        problem = _take_error(f"{ident} ({voice_id})", take, cuebook.MAX_TAKE, raw / "voices" / voice_id / ident, [])
        if problem:
            errors.append(problem)
        else:
            chosen[voice_id] = take
    if len(chosen) == len(value):
        line_picks[ident] = {**files[unit].lines[ident].picks, **chosen}  # a voice not named keeps its pick
        unit_of[ident] = unit


def _picks_text(cues_path: Path, layers_path: Path, voices_dir: Path, cue_picks: dict[str, list[int]],
                layer_picks: dict[str, list[int]], line_picks: dict[str, dict[str, int]], unit_of: dict[str, str],
                files: dict[str, cuebook.VoiceFile]) -> dict[Path, str]:
    """The new text of every file that changes, each checked to still parse with the picks it should have."""
    writes: dict[Path, str] = {}
    if cue_picks:
        writes[cues_path] = _checked(cues_path, picks_io.apply_cue_picks(_read(cues_path), cue_picks), "cue", {k: v for k, v in cue_picks.items()})
    if layer_picks:
        writes[layers_path] = _checked(layers_path, picks_io.apply_cue_picks(_read(layers_path), layer_picks, table="layer"), "layer", layer_picks)
    for unit in sorted(set(unit_of.values())):
        mine = {line: p for line, p in line_picks.items() if unit_of[line] == unit}
        target = voices_dir / f"{unit}.toml"
        writes[target] = _checked(target, picks_io.apply_line_picks(_read(target), mine), "line", mine)
    return writes


def _read(path: Path) -> str:
    return path.read_bytes().decode("utf-8")


def _checked(path: Path, text: str, table: str, expected: dict[str, object]) -> str:
    try:
        parsed = tomllib.loads(text)[table]
    except (tomllib.TOMLDecodeError, KeyError):
        raise picks_io.PicksError(f"{path.name} would no longer parse") from None
    for ident, want in expected.items():
        got = parsed[ident]["picks"]
        if got != (list(want) if isinstance(want, list) else want):  # type: ignore[call-overload]
            raise picks_io.PicksError(f"{path.name}: the picks for {ident} didn't come out as asked")
    return text


def _design_picks(design: object, batch: object, files: dict[str, cuebook.VoiceFile], raw: Path) -> int:
    """A design file changes nothing: it prints the generate.py commands that save each chosen voice."""
    errors: list[str] = []
    unit = batch[len("design-"):] if isinstance(batch, str) and batch.startswith("design-") else ""
    if not unit or unit not in files or unit == cuebook.CLAN:
        errors.append("the batch must be design-<unit> for a unit with voices")
    commands: list[str] = []
    if isinstance(design, dict) and not errors:
        for voice, n in design.items():
            try:
                voice_id = cuebook.check_id(voice, "design voice")
            except CueError as err:
                errors.append(str(err))
                continue
            if voice_id not in files[unit].voices:
                errors.append(f"{voice_id} isn't a voice of {unit}")
            elif isinstance(n, bool) or not isinstance(n, int) or n < 1 or find_raw(raw / "design" / unit / voice_id, n) is None:
                errors.append(f"{voice_id}: preview {n if isinstance(n, int) else 'that'} has no downloaded file")
            else:
                commands.append(f"python3 scripts/audio/generate.py voices save {unit} --voice {voice_id} --pick {n}")
    if errors:
        print("process.py picks: nothing to run:\n  " + "\n  ".join(errors), file=sys.stderr)
        return 1
    print("Nothing was written. To save these voices, run in Terminal.app:")
    for command in commands:
        print(f"  {command}")
    return 0


# ---- audition -------------------------------------------------------------------------------------------------------

def _batch_work(name: str, cues_path: Path, layers_path: Path, voices_dir: Path, root: Path) -> list[tuple[Take, Path, str]]:
    """The raw takes of a batch: the page entry, the raw file and the processing kind of each."""
    raw = root / "audio-src" / "raw"
    book = cuebook.load_cues(cues_path)
    work: list[tuple[Take, Path, str]] = []

    def cue_work(ident: str, text: str, folder: Path, kind: str) -> None:
        for n, path in _raw_takes(folder).items():
            work.append((Take(ident, n, text, f"{name}/{ident}_{n}.wav", None), path, kind))

    if name in ("loops", "bed", "march"):
        wanted = [c for c in book.cues.values() if c.loop and (name == "loops" or c.category == name)]
        for cue in wanted:
            cue_work(cue.id, cue.prompt, raw / "sfx" / cue.id, "loop")
    elif name == "music":
        for layer in cuebook.load_layers(layers_path).values():
            cue_work(layer.id, layer.prompt, raw / "music" / layer.id, "music")
    elif name == "ab":
        files = cuebook.load_voices(voices_dir)
        texts = {l.id: l.text for f in files.values() for l in f.lines.values()}
        for model_dir in sorted((raw / "ab").iterdir() if (raw / "ab").is_dir() else []):
            for line_dir in sorted(model_dir.iterdir() if model_dir.is_dir() else []):
                for n, path in _raw_takes(line_dir).items():
                    ident = cuebook.check_id(line_dir.name, "ab line")
                    work.append((Take(ident, n, texts.get(ident, ""), f"{name}/{ident}_{model_dir.name}_{n}.wav", cuebook.check_id(model_dir.name, "ab model")), path, "bark"))
    elif name.startswith("voices-") or name.startswith("design-"):
        unit = cuebook.check_id(name.split("-", 1)[1], "batch unit")
        files = cuebook.load_voices(voices_dir)
        if unit not in files:
            raise CueError(f"batch {name}: no voice file for {unit}")
        if name.startswith("design-"):
            if unit == cuebook.CLAN:
                raise CueError("the clan has no voices to design")
            for voice in files[unit].voices.values():
                for n, path in _raw_takes(raw / "design" / unit / voice.id).items():
                    work.append((Take(voice.id, n, voice.description, f"{name}/{voice.id}_{n}.wav", voice.id), path, "bark"))
        else:
            light = [v for u, f in files.items() if u != cuebook.CLAN for v in f.voices]
            speakers = light if unit == cuebook.CLAN else list(files[unit].voices)
            for line in files[unit].lines.values():
                for voice in speakers:
                    for n, path in _raw_takes(raw / "voices" / voice / line.id).items():
                        work.append((Take(line.id, n, line.text, f"{name}/{line.id}_{voice}_{n}.wav", voice), path, "bark"))
    elif name in cuebook.CATEGORIES and name not in cuebook.LOOP_CATEGORIES:
        for cue in book.cues.values():
            if cue.category == name:
                cue_work(cue.id, cue.prompt, raw / "sfx" / cue.id, "oneshot")
    else:
        raise CueError(f"batch {name!r}: use a category ({', '.join(c for c in cuebook.CATEGORIES if c not in cuebook.LOOP_CATEGORIES)}), "
                       "loops, music, voices-<unit>, design-<unit> or ab")
    return work


def batch(name: str, cues_path: Path = CUES, layers_path: Path = LAYERS, voices_dir: Path = VOICES, root: Path = ROOT) -> int:
    out = root / AUDITION_DIR
    try:
        check_no_symlinks(root, (*GUARDED, AUDITION_DIR))
        work = _batch_work(name, cues_path, layers_path, voices_dir, root)
        if not work:
            raise CueError(f"batch {name}: no downloaded takes under audio-src/raw/ for it")
        ffmpeg_io.require_ffmpeg()
        done: list[Take] = []
        for take, source, kind in work:
            try:
                frames, rate, channels = render_take(source, kind)
            except AudioError as err:
                print(f"skipped {take.id} take {take.take}: {err}", file=sys.stderr)
                continue
            ffmpeg_io.write_wav(frames, rate, channels, out / take.file)
            done.append(take)
        (out / f"{name}.html").write_text(audition.page(name, done), encoding="utf-8")
    except (CueError, UnsafePath, ToolMissing, AudioError, OSError) as err:
        print(f"process.py batch: {err}", file=sys.stderr)
        return 1
    print(f"wrote {len(done)} previews and {out / (name + '.html')}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build", help="write the bank sidecar from the cue book")
    b.add_argument("--sidecar", type=Path, default=SIDECAR)
    b.add_argument("--force", action="store_true", help="re-render every picked file, not only the stale ones")
    a = sub.add_parser("batch", help="trim and level a batch's raw takes and write its audition page")
    a.add_argument("name")
    k = sub.add_parser("picks", help="write the picks saved from an audition page")
    k.add_argument("file", type=Path)
    y = sub.add_parser("synthetic", help="write synthetic test audio and a sidecar for it (Web measurement only)")
    y.add_argument("--sidecar", type=Path, default=SIDECAR)
    args = parser.parse_args(argv)
    if args.command == "synthetic":
        return synthetic(args.sidecar)
    if args.command == "batch":
        return batch(args.name)
    if args.command == "picks":
        return picks_file(args.file)
    return build(args.sidecar, force=args.force)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
