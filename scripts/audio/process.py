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
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import assets
import audition
import cuebook
import ffmpeg_io
import ledger
import licences
import picks as picks_mod
from assets import AUDITION_DIR, GUARDED, LOOP_FILE, MUSIC_FILE, SFX_FILE, VOICE_FILE, UnsafePath, _import_text
from audition import Take
from cuebook import CueError
from ffmpeg_io import AudioError, ToolMissing

ROOT: Path = Path(__file__).resolve().parents[2]
CUES: Path = ROOT / "audio-src" / "cues.toml"
LAYERS: Path = ROOT / "audio-src" / "music" / "prompts.toml"
VOICES: Path = ROOT / "audio-src" / "voices"
SIDECAR: Path = ROOT / "audio-src" / "build" / "bank.json"
LICENSES: Path = ROOT / "assets" / "LICENSES.md"


LOOP_BATCHES: tuple[str, ...] = ("loops", *(c for c in cuebook.LOOP_CATEGORIES if c != "music"))  # the cue categories that loop, bought as sfx
NOTES: dict[str, str] = {"music": "These previews aren't looped yet: build cuts the layers to one length and adds the loop crossfade."}

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
        cuebook.emit(f"process.py build: {err}", file=sys.stderr)
        return 1
    sidecar.parent.mkdir(parents=True, exist_ok=True)
    sidecar.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
    cuebook.emit(f"wrote {sidecar} ({len(data['cues'])} cues, {len(data['lines'])} lines)")  # type: ignore[arg-type]
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




def render(synth: Synth, out_dir: Path) -> None:
    """ffmpeg renders into a private temp folder (so it never opens a path the repo controls), and the bytes are written to out_dir
    through O_NOFOLLOW .part files."""
    with tempfile.TemporaryDirectory() as tmp:  # synthetic() has already checked that ffmpeg exists
        made = Path(tmp) / synth.name
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *synth.source, *synth.codec, str(made)], check=True)
        assets.write_bytes_nofollow(out_dir / synth.name, made.read_bytes())
    assets.write_bytes_nofollow(out_dir / (synth.name + ".import"), _import_text(synth.name).encode("utf-8"))


def synthetic(sidecar: Path, out_dir: Path = SYNTH_DIR, cues_path: Path = CUES, layers_path: Path = LAYERS, root: Path = ROOT) -> int:
    try:
        # First: the repo is public, so assets/audio/synthetic, audio-src/build or a file in them could be a planted symlink.
        assets.check_no_symlinks(root, (*GUARDED, "audio-src/build"))
        assets.check_inputs(root, cues_path, layers_path, VOICES)
    except UnsafePath as err:
        cuebook.emit(f"process.py synthetic: {err}", file=sys.stderr)
        return 1
    if shutil.which("ffmpeg") is None:
        cuebook.emit("process.py synthetic: ffmpeg not found (brew install ffmpeg)", file=sys.stderr)
        return 1
    try:
        synths, data = synthetic_plan(cues_path, layers_path)
    except CueError as err:
        cuebook.emit(f"process.py synthetic: {err}", file=sys.stderr)
        return 1
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
        for synth in synths:
            render(synth, out_dir)
        sidecar.parent.mkdir(parents=True, exist_ok=True)
        assets.write_bytes_nofollow(sidecar, (json.dumps(data, indent=1) + "\n").encode("utf-8"))
    except (OSError, subprocess.CalledProcessError) as err:
        cuebook.emit(f"process.py synthetic: {err.strerror if isinstance(err, OSError) and err.strerror else 'a render failed'}"
              f"{': ' + str(err.filename) if isinstance(err, OSError) and err.filename else ''}", file=sys.stderr)
        return 1
    one_shot_s = sum(x.seconds for x in synths if x.name.endswith(".wav"))
    cuebook.emit(f"wrote {len(synths)} synthetic files ({one_shot_s:.0f} s of one-shots) and {sidecar} ({len(data['cues'])} cues)")  # type: ignore[arg-type]
    return 0


# ---- build ----------------------------------------------------------------------------------------------------------

def build(
    sidecar: Path, cues_path: Path = CUES, layers_path: Path = LAYERS, root: Path = ROOT, voices_dir: Path = VOICES,
    force: bool = False,
) -> int:
    licence_path = root / "assets" / "LICENSES.md"
    try:
        assets.check_no_symlinks(root, assets.BUILD_GUARDED)
        assets.check_inputs(root, cues_path, layers_path, voices_dir)
        plan = assets.plan_assets(cues_path, layers_path, voices_dir, root)
        stamps = assets.load_stamps(root)
        # Everything that can refuse does so before the first write.
        todo = [a for a in plan if force or not assets.is_fresh(a, plan, root, stamps)]
        if todo:
            ffmpeg_io.require_ffmpeg()
            if any(a.kind != "oneshot" for a in todo):
                ffmpeg_io.require_oggenc()
        text = licence_path.read_text(encoding="utf-8") if licence_path.is_file() else ""
        if not text:
            raise CueError(f"{licence_path.relative_to(root)} is missing")
        new_text = licences.update_licences(text, licences.licence_rows(plan, root / "audio-src" / "manifest.json"))
        assets.render_assets(todo, root, stamps)
        for asset in plan:
            if assets.ensure_import(root / asset.dest, assets.import_params(asset)):
                cuebook.emit(f"wrote {asset.dest}.import")
        placeholders = {c.placeholder for c in cuebook.load_cues(cues_path).cues.values() if c.placeholder}
        for orphan in assets.orphans(root, plan, placeholders):
            cuebook.emit(f"orphaned: {cuebook.printable(orphan)} (no current pick makes it; delete it if it is stale)")
    except (CueError, UnsafePath, ToolMissing, AudioError, OSError) as err:
        cuebook.emit(f"process.py build: {err}", file=sys.stderr)
        return 1
    if new_text != text:
        licence_path.write_text(new_text, encoding="utf-8")
        cuebook.emit(f"wrote {licence_path.relative_to(root)} ({len(plan)} audio rows)")
    return write_sidecar(sidecar, cues_path, layers_path, root, voices_dir)


def picks_file(
    path: Path, cues_path: Path = CUES, layers_path: Path = LAYERS, voices_dir: Path = VOICES, root: Path = ROOT
) -> int:
    return picks_mod.picks_file(path, cues_path, layers_path, voices_dir, root)


# ---- audition -------------------------------------------------------------------------------------------------------

def _batch_work(name: str, cues_path: Path, layers_path: Path, voices_dir: Path, root: Path) -> list[tuple[Take, Path, str]]:
    """The raw takes of a batch: the page entry, the raw file and the processing kind of each."""
    raw = root / "audio-src" / "raw"
    book = cuebook.load_cues(cues_path)
    work: list[tuple[Take, Path, str]] = []

    def cue_work(ident: str, text: str, folder: Path, kind: str) -> None:
        for n, path in assets.raw_takes(folder).items():
            work.append((Take(ident, n, text, f"{name}/{ident}_{n}.wav", None), path, kind))

    if name in LOOP_BATCHES:
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
                for n, path in assets.raw_takes(line_dir).items():
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
                for n, path in assets.raw_takes(raw / "design" / unit / voice.id).items():
                    work.append((Take(voice.id, n, voice.description, f"{name}/{voice.id}_{n}.wav", voice.id), path, "bark"))
        else:
            light = [v for u, f in files.items() if u != cuebook.CLAN for v in f.voices]
            speakers = light if unit == cuebook.CLAN else list(files[unit].voices)
            for line in files[unit].lines.values():
                for voice in speakers:
                    for n, path in assets.raw_takes(raw / "voices" / voice / line.id).items():
                        work.append((Take(line.id, n, line.text, f"{name}/{line.id}_{voice}_{n}.wav", voice), path, "bark"))
    elif name in cuebook.CATEGORIES and name not in cuebook.LOOP_CATEGORIES:
        for cue in book.cues.values():
            if cue.category == name:
                cue_work(cue.id, cue.prompt, raw / "sfx" / cue.id, "oneshot")
    else:
        raise CueError(f"batch {name!r}: use a category ({', '.join(c for c in cuebook.CATEGORIES if c not in cuebook.LOOP_CATEGORIES)}), "
                       "loops, music, voices-<unit>, design-<unit> or ab")
    records = assets.load_records(root / assets.MANIFEST)
    ledger_lines = ledger.lazy()
    for _, path, _ in work:
        assets.verify_raw(path, root, records, ledger_lines)  # a file nobody bought is never decoded
    return work


def batch(name: str, cues_path: Path = CUES, layers_path: Path = LAYERS, voices_dir: Path = VOICES, root: Path = ROOT) -> int:
    out = root / AUDITION_DIR
    try:
        assets.check_no_symlinks(root, (*GUARDED, AUDITION_DIR))
        assets.check_inputs(root, cues_path, layers_path, voices_dir)
        work = _batch_work(name, cues_path, layers_path, voices_dir, root)
        if not work:
            raise CueError(f"batch {name}: no downloaded takes under audio-src/raw/ for it")
        ffmpeg_io.require_ffmpeg()
        done: list[Take] = []
        for take, source, kind in work:
            try:
                frames, rate, channels = assets.render_take(source, kind)
            except AudioError as err:
                cuebook.emit(f"skipped {take.id} take {take.take}: {err}", file=sys.stderr)
                continue
            ffmpeg_io.write_wav(frames, rate, channels, out / take.file)
            done.append(take)
        (out / f"{name}.html").write_text(audition.page(name, done, NOTES.get(name, "")), encoding="utf-8")
    except (CueError, UnsafePath, ToolMissing, AudioError, OSError) as err:
        cuebook.emit(f"process.py batch: {err}", file=sys.stderr)
        return 1
    cuebook.emit(f"wrote {len(done)} previews and {out / (name + '.html')}")
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
    try:
        if args.command == "synthetic":
            return synthetic(args.sidecar)
        if args.command == "batch":
            return batch(args.name)
        if args.command == "picks":
            return picks_file(args.file)
        return build(args.sidecar, force=args.force)
    except Exception as error:  # a bug: reported through emit, with no traceback. KeyboardInterrupt still propagates.
        cuebook.emit(f"process.py {args.command}: unexpected {type(error).__name__}: {cuebook.printable(str(error))[:200]}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
