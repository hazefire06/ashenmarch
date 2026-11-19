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
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import cuebook
import dsp
import ffmpeg_io
import ledger
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
# Every voice line plays this many times as fast, at the same pitch (Tim, 2026-11-18).
BARK_TEMPO: float = 1.5
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
                raise UnsafePath(f"{cuebook.printable(str(here.relative_to(root)))} is a symlink; replace it with a real folder or file")
        else:
            for folder, names, files in os.walk(here, followlinks=False):
                for entry in sorted(names + files):
                    if stat.S_ISLNK(os.lstat(os.path.join(folder, entry)).st_mode):
                        raise UnsafePath(f"{cuebook.printable(str(Path(folder, entry).relative_to(root)))} is a symlink; replace it with a real folder or file")


MANIFEST: str = "audio-src/manifest.json"


def check_inputs(root: Path, cues_path: Path, layers_path: Path, voices_dir: Path) -> None:
    """Refuses a symlink anywhere on the way to the files that are read: the cue book, the layer file, each voice file and the manifest.
    Every part of each path counts (a symlinked audio-src/music would redirect the layer file), up to but not above the project root.
    The repo is public, so a PR could plant a link to a file of Tim's, and its text would be parsed and echoed in a message."""
    paths = [cues_path, layers_path, voices_dir, root / MANIFEST]
    if voices_dir.is_dir() and not voices_dir.is_symlink():
        paths += sorted(voices_dir.glob("*.toml"))
    for path in paths:
        try:
            parts = path.relative_to(root).parts
        except ValueError:
            parts = ()
            if path.is_symlink():
                raise UnsafePath(f"{path.name} is a symlink; replace it with a real file or folder")
        here = root
        for part in parts:
            here = here / part
            try:
                linked = stat.S_ISLNK(os.lstat(here).st_mode)
            except FileNotFoundError:
                break
            if linked:
                raise UnsafePath(f"{cuebook.printable(str(here.relative_to(root)))} is a symlink; replace it with a real file or folder")


def load_records(manifest: Path) -> dict[tuple[str, str], dict[str, object]]:
    """The manifest's records by (kind, label). A missing file is no records. A file that can't be read as a list of records, or that
    holds two records for one kind and label (a bad merge), is refused: either could make a file look bought, or unbought."""
    try:
        text = manifest.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    except OSError:
        raise CueError(f"{manifest.name} can't be read") from None
    try:
        data = json.loads(text)
        tasks = data.get("tasks", []) if isinstance(data, dict) else None
    except (ValueError, RecursionError):
        tasks = None
    if not isinstance(tasks, list) or not all(isinstance(t, dict) for t in tasks):
        raise CueError(f"{manifest.name} can't be read as a manifest (an object with a list of task records)")
    records: dict[tuple[str, str], dict[str, object]] = {}
    for task in tasks:
        key = (str(task.get("kind")), str(task.get("label")))
        if key in records:
            raise CueError(f"{manifest.name} has two records for one kind and label; merge them into one per label")
        records[key] = task
    return records


def verify_raw(path: Path, root: Path, records: dict[tuple[str, str], dict[str, object]],
               ledger_lines: Callable[[], list[dict[str, Any]]]) -> None:
    """A raw file is used only if generate.py bought it: a DONE record lists it, with the file's own hash and size. The raw folder is
    committed through LFS and the repo is public, so a PR could plant or swap a file; without this its licence row would claim a purchase.
    The manifest is committed too, so a forged record could match a planted file: the ledger outside the repo must also have a line for
    this label, hash and size (ledger_lines loads it on first use, and refuses if it is missing)."""
    rel = path.relative_to(root / "audio-src" / "raw").as_posix()
    label = rel.rsplit(".", 1)[0]
    record = records.get((label.split("/", 1)[0], label))
    if record is None or record.get("status") != "DONE" or not isinstance(record.get("files"), list) or rel not in record["files"]:
        raise CueError(f"raw/{rel}: no DONE purchase record lists this file in {MANIFEST}, so it isn't used (generate.py writes the record when it buys a take)")
    digest, size = hashlib.sha256(), 0
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
            size += len(chunk)
    if record.get("sha256") != digest.hexdigest() or record.get("bytes") != size:
        raise CueError(f"raw/{rel}: its hash differs from the purchase record's (or the record has none), so it isn't the file that was bought")
    if not ledger.has_file(ledger_lines(), label.split("/", 1)[0], label, digest.hexdigest(), size):
        raise CueError(f"raw/{rel}: the purchase ledger ({cuebook.printable(str(ledger.LEDGER))}) has no line for it, so this Mac didn't buy this file")


def write_bytes_nofollow(path: Path, data: bytes) -> None:
    """Writes data through <path>.part, opened with O_NOFOLLOW, then renames it over path. A rename replaces a symlink at path instead
    of following it, so nothing is ever written through a link the repo's PRs could plant."""
    part = path.with_name(path.name + ".part")
    fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        os.replace(part, path)
    except BaseException:
        part.unlink(missing_ok=True)
        raise


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
        if kind == "bark":
            frames = ffmpeg_io.tempo(frames, rate, channels, BARK_TEMPO)
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
    records = load_records(root / MANIFEST)
    ledger_lines = ledger.lazy()

    def add(kind: str, res: str, folder: str, take: int, what: str, ident: str, record_kind: str) -> None:
        source = find_raw(raw / folder, take)
        if source is None:
            raise CueError(f"{what}: picked take {take} has no file under audio-src/raw/{folder}/")
        verify_raw(source, root, records, ledger_lines)
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
        "bark_lufs": BARK_LUFS, "bark_tempo": BARK_TEMPO, "bed_lufs": BED_LUFS, "loop_fade_s": LOOP_FADE_S, "ogg_quality": OGG_QUALITY, "wav": WAV_PARAMS,
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
        cuebook.emit(f"wrote {asset.dest} ({len(frames) // channels / rate:.2f} s)")
    for (asset, _, rate, channels), frames in zip(layers, looped):
        write_asset(frames, rate, channels, asset, root)
        _write_stamp(asset, root, stamps)
        cuebook.emit(f"wrote {asset.dest} ({len(frames) // channels / rate:.2f} s)")


def _render(asset: Asset) -> tuple[array, int, int]:
    try:
        return render_take(asset.source, asset.kind)
    except AudioError as err:
        raise AudioError(f"{asset.what}: {err}") from None


def orphans(root: Path, plan: list[Asset]) -> list[str]:
    """Audio files under assets/audio/ that no current pick makes. Reported, never deleted."""
    made = {a.dest for a in plan}
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
