"""The audio pipeline's free steps. `build` turns the cue book into a sidecar for the bank builder.

    python3 scripts/audio/process.py build [--sidecar PATH]

Writes audio-src/build/bank.json: one entry per cue, and one per music layer
(`music_<layer>`), each with the files it plays. Godot's builder
(build_sound_bank.gd) reads the sidecar and writes data/audio/sound_bank.tres.
Nothing here is paid, and nothing touches the network.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cuebook
from cuebook import CueError

ROOT: Path = Path(__file__).resolve().parents[2]
CUES: Path = ROOT / "audio-src" / "cues.toml"
LAYERS: Path = ROOT / "audio-src" / "music" / "prompts.toml"
SIDECAR: Path = ROOT / "audio-src" / "build" / "bank.json"

SFX_FILE: str = "res://assets/audio/sfx/{cue}_{pick}.wav"
LOOP_FILE: str = "res://assets/audio/loop/{cue}.ogg"
MUSIC_FILE: str = "res://assets/audio/music/{layer}.ogg"


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


def build_sidecar(cues_path: Path, layers_path: Path, root: Path = ROOT) -> dict[str, object]:
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
    return {"cues": entries, "lines": []}


def build(sidecar: Path, cues_path: Path = CUES, layers_path: Path = LAYERS, root: Path = ROOT) -> int:
    try:
        data = build_sidecar(cues_path, layers_path, root)
    except CueError as err:
        print(f"process.py build: {err}", file=sys.stderr)
        return 1
    sidecar.parent.mkdir(parents=True, exist_ok=True)
    sidecar.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {sidecar} ({len(data['cues'])} cues)")  # type: ignore[arg-type]
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build", help="write the bank sidecar from the cue book")
    b.add_argument("--sidecar", type=Path, default=SIDECAR)
    args = parser.parse_args(argv)
    return build(args.sidecar)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
