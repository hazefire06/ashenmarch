"""The finished assets: which raw take becomes which file, how it is rendered, and the Godot .import beside it.

A stamp (audio-src/build/stamps.json, git-ignored) records what each finished file was made from: the raw take's path, size and
modification time, the file's own size, and a hash of the processing constants. A file is rebuilt unless its stamp still matches,
so repicking a take or changing a level re-renders it, and an unchanged rebuild writes nothing (oggenc's serial numbers are random,
so rewriting would churn the LFS files).
"""
from __future__ import annotations

import hashlib
import json
import os
import stat
from array import array
from dataclasses import dataclass
from pathlib import Path

import cuebook
import dsp
import ffmpeg_io
from cuebook import CueError
from ffmpeg_io import AudioError

STAMPS: str = "audio-src/build/stamps.json"
AUDITION_DIR: str = "audio-src/audition"
SFX_FILE: str = "res://assets/audio/sfx/{cue}_{pick}.wav"
LOOP_FILE: str = "res://assets/audio/loop/{cue}.ogg"
MUSIC_FILE: str = "res://assets/audio/music/{layer}.ogg"
VOICE_FILE: str = "res://assets/audio/voice/{voice}/{line}.ogg"

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


GUARDED: tuple[str, ...] = ("assets/audio", "audio-src/raw")  # nothing under these may be a symlink
BUILD_GUARDED: tuple[str, ...] = (*GUARDED, "assets/LICENSES.md", "audio-src/build")
BARK_LUFS: float = -18.0
BED_LUFS: float = -23.0  # beds, marching loops and music; both targets are set by ear
LOOP_FADE_S: float = 1.0
OGG_QUALITY: dict[str, int] = {"bark": 4, "loop": 4, "music": 5}


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


def raw_takes(folder: Path) -> dict[int, Path]:
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


def write_asset(frames: array, rate: int, channels: int, asset: Asset, root: Path) -> None:
    dest = root / asset.dest
    if asset.kind == "oneshot":
        ffmpeg_io.write_wav(frames, rate, channels, dest)
    else:
        ffmpeg_io.write_ogg(frames, rate, channels, dest, OGG_QUALITY[asset.kind])


def constants_hash() -> str:
    """A hash of everything that shapes a finished file besides the take itself. Read at call time, so a changed constant changes it."""
    knobs = {
        "version": 1, "trim_db": -50.0, "tail_fade_ms": 30.0, "peak_db": -1.0, "true_peak_db": -1.5, "lra": 11,
        "bark_lufs": BARK_LUFS, "bed_lufs": BED_LUFS, "loop_fade_s": LOOP_FADE_S, "ogg_quality": OGG_QUALITY, "wav": WAV_PARAMS,
    }
    return hashlib.sha256(json.dumps(knobs, sort_keys=True).encode()).hexdigest()[:16]


def load_stamps(root: Path) -> dict[str, dict[str, object]]:
    try:
        data = json.loads((root / STAMPS).read_text(encoding="utf-8"))
    except (OSError, ValueError, RecursionError):
        return {}
    return {k: v for k, v in data.items() if isinstance(k, str) and isinstance(v, dict)} if isinstance(data, dict) else {}


def save_stamps(root: Path, stamps: dict[str, dict[str, object]]) -> None:
    path = root / STAMPS
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(stamps, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(part, path)


def stamp_of(asset: Asset, root: Path) -> dict[str, object] | None:
    """What the finished file is made from now, or None if either file is missing."""
    dest = root / asset.dest
    try:
        src = asset.source.stat()
        return {"source": str(asset.source.relative_to(root)), "source_size": src.st_size, "source_mtime_ns": src.st_mtime_ns,
                "dest_size": dest.stat().st_size, "constants": constants_hash()}
    except OSError:
        return None


def is_fresh(asset: Asset, plan: list[Asset], root: Path, stamps: dict[str, dict[str, object]]) -> bool:
    """True if the finished file's stamp matches its raw take and the constants (for music, every layer's, since they are cut together)."""
    group = [a for a in plan if a.kind == "music"] if asset.kind == "music" else [asset]
    return all(stamp_of(a, root) is not None and stamps.get(a.dest) == stamp_of(a, root) for a in group)


def _write_stamp(asset: Asset, root: Path, stamps: dict[str, dict[str, object]]) -> None:
    stamp = stamp_of(asset, root)
    if stamp is not None:
        stamps[asset.dest] = stamp
        save_stamps(root, stamps)


def render_assets(todo: list[Asset], root: Path, stamps: dict[str, dict[str, object]] | None = None) -> None:
    """Renders and writes the assets, stamping each after its file is in place. The music layers go together: each is levelled, all are
    cut to one length, then each gets the loop crossfade (the generator has no loop option). They are checked before anything is written."""
    stamps = stamps if stamps is not None else load_stamps(root)
    layers: list[tuple[Asset, array, int, int]] = []
    for asset in (a for a in todo if a.kind == "music"):
        layers.append((asset, *_render(asset)))
    looped: list[array] = []
    if layers:
        if len({(rate, ch) for _, _, rate, ch in layers}) > 1:
            raise AudioError("the music layers differ in sample rate or channels, so they can't be cut to one length; buy them in one format")
        shortest = min((f for _, f, _, _ in layers), key=len)
        looped = [dsp.loop_crossfade(dsp.match_length(f, shortest, ch)[0], ch, rate, LOOP_FADE_S) for _, f, rate, ch in layers]
    for asset in (a for a in todo if a.kind != "music"):
        frames, rate, channels = _render(asset)
        write_asset(frames, rate, channels, asset, root)
        _write_stamp(asset, root, stamps)
        print(f"wrote {asset.dest} ({len(frames) // channels / rate:.2f} s)")
    for (asset, _, rate, channels), frames in zip(layers, looped):
        write_asset(frames, rate, channels, asset, root)
        _write_stamp(asset, root, stamps)
        print(f"wrote {asset.dest} ({len(frames) // channels / rate:.2f} s)")


def _render(asset: Asset) -> tuple[array, int, int]:
    try:
        return render_take(asset.source, asset.kind)
    except AudioError as err:
        raise AudioError(f"{asset.what}: {err}") from None


def orphans(root: Path, plan: list[Asset], placeholders: set[str]) -> list[str]:
    """Audio files under assets/audio/ that no current pick makes and no cue names as its placeholder. Reported, never deleted."""
    made = {a.dest for a in plan} | {p.removeprefix("res://") for p in placeholders}
    folder = root / "assets" / "audio"
    found: list[str] = []
    if folder.is_dir():
        for path in sorted(folder.rglob("*")):
            rel = str(path.relative_to(root))
            if path.suffix in (".wav", ".ogg", ".mp3") and path.is_file() and "synthetic" not in path.relative_to(folder).parts and rel not in made:
                found.append(rel)
    return found


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
            if not lines[end - 1].endswith("\n"):  # the file ends without a newline
                lines[end - 1] += "\n"
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
