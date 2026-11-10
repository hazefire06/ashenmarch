"""Loads and checks the cue book (audio-src/cues.toml) and the music layers (audio-src/music/prompts.toml).

The paid generator buys sounds from these prompts and the bank builder turns
every id into a file name, so this is the security boundary: an id must match
[a-z0-9_]+ in full, every table refuses keys it doesn't know, and every number
is range-checked before anything else sees it. Only CueError escapes. A
message names the table and the key, and never echoes more than 40 characters
of a value, so a hostile file can't flood a log or a terminal.
"""
from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass
from pathlib import Path

ID: re.Pattern[str] = re.compile(r"[a-z0-9_]+")
PLACEHOLDER: re.Pattern[str] = re.compile(r"res://assets/audio/sfx/[a-z0-9_]+\.wav")

CATEGORIES: tuple[str, ...] = ("melee", "projectile", "death", "groan", "ui", "march", "bed", "music")
LOOP_CATEGORIES: tuple[str, ...] = ("march", "bed", "music")
PLAYBACKS: tuple[str, ...] = ("sample", "stream")
BUSES: tuple[str, ...] = ("Effects", "Ambient", "Interface", "Music", "Voice")

SFX_SECONDS: tuple[float, float] = (0.5, 30.0)  # ElevenLabs SFX duration_seconds
MUSIC_SECONDS: tuple[float, float] = (3.0, 600.0)  # ElevenLabs music, 3,000 to 600,000 ms
MAX_SHOWN: int = 40

DEFAULT_KEYS: tuple[str, ...] = (
    "variants", "takes", "bus", "level_db", "max_voices", "pitch_spread", "model", "prompt_influence",
)
CUE_KEYS: frozenset[str] = frozenset(DEFAULT_KEYS) | {"category", "prompt", "duration_s", "loop", "placeholder", "picks"}
LAYER_KEYS: frozenset[str] = frozenset({"prompt", "length_s", "model", "takes", "picks"})


class CueError(Exception):
    """The cue book or the music prompts are malformed."""


@dataclass(frozen=True)
class Cue:
    id: str
    category: str
    prompt: str
    duration_s: float
    loop: bool
    variants: int
    takes: int
    bus: str
    level_db: float
    max_voices: int
    pitch_spread: float
    model: str
    prompt_influence: float
    placeholder: str | None
    picks: tuple[int, ...]


@dataclass(frozen=True)
class CueBook:
    style_suffix: str
    playback: dict[str, str]
    cues: dict[str, Cue]


@dataclass(frozen=True)
class Layer:
    id: str
    prompt: str
    length_s: float
    model: str
    takes: int
    picks: tuple[int, ...]


def _show(value: object) -> str:
    """A value for a message: its type for non-text, else at most 40 characters."""
    if not isinstance(value, str):
        return f"a {type(value).__name__}"
    text = value if len(value) <= MAX_SHOWN else value[:MAX_SHOWN] + "..."
    return repr(text)


def check_id(value: object, what: str) -> str:
    if not isinstance(value, str) or ID.fullmatch(value) is None:
        raise CueError(f"{what}: {_show(value)} isn't a safe id (lowercase letters, digits and _ only)")
    return value


def load_cues(path: Path) -> CueBook:
    root = _read(path)
    _only_keys(root, {"style", "defaults", "playback", "cue"}, "top level")
    style = _table(root, "style")
    _only_keys(style, {"suffix"}, "[style]")
    suffix = _text(style, "suffix", "[style]")
    defaults = _defaults(_table(root, "defaults"))
    playback = _playback(_table(root, "playback"))
    cues: dict[str, Cue] = {}
    for raw_id, body in _table(root, "cue").items():
        cue_id = check_id(raw_id, "[cue] table name")
        if not isinstance(body, dict):
            raise CueError(f"[cue.{cue_id}] isn't a table")
        cues[cue_id] = _cue(cue_id, body, defaults)
    if not cues:
        raise CueError("[cue] holds no cues")
    return CueBook(suffix, playback, cues)


def load_layers(path: Path) -> dict[str, Layer]:
    root = _read(path)
    _only_keys(root, {"layer"}, "top level")
    layers: dict[str, Layer] = {}
    for raw_id, body in _table(root, "layer").items():
        layer_id = check_id(raw_id, "[layer] table name")
        where = f"[layer.{layer_id}]"
        if not isinstance(body, dict):
            raise CueError(f"{where} isn't a table")
        _only_keys(body, LAYER_KEYS, where)
        takes = _int(body, "takes", where, low=1, high=20)
        layers[layer_id] = Layer(
            id=layer_id,
            prompt=_text(body, "prompt", where),
            length_s=_number(body, "length_s", where, *MUSIC_SECONDS),
            model=_text(body, "model", where),
            takes=takes,
            picks=_picks(body, takes, where),
        )
    if not layers:
        raise CueError("[layer] holds no layers")
    return layers


def _read(path: Path) -> dict[str, object]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):  # their messages can carry file bytes
        raise CueError(f"{path} can't be read as UTF-8 text") from None
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as err:  # a duplicate key or table is refused here too
        raise CueError(f"{path} isn't valid TOML: {str(err)[:MAX_SHOWN * 2]}") from None


def _only_keys(table: dict[str, object], allowed: set[str] | frozenset[str], where: str) -> None:
    for key in table:
        if key not in allowed:
            raise CueError(f"{where}: unknown key {_show(key)}")


def _table(parent: dict[str, object], key: str) -> dict[str, object]:
    value = parent.get(key)
    if not isinstance(value, dict):
        raise CueError(f"[{key}] is missing or isn't a table")
    return value


def _text(table: dict[str, object], key: str, where: str) -> str:
    value = table.get(key)
    if not isinstance(value, str) or not value.strip():
        raise CueError(f"{where}: {key} must be non-empty text")
    return value


def _int(table: dict[str, object], key: str, where: str, low: int, high: int) -> int:
    value = table.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise CueError(f"{where}: {key} must be a whole number from {low} to {high}")
    return value


def _number(table: dict[str, object], key: str, where: str, low: float, high: float) -> float:
    value = table.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not low <= value <= high:
        raise CueError(f"{where}: {key} must be a number from {low:g} to {high:g}")
    return float(value)


def _picks(table: dict[str, object], takes: int, where: str) -> tuple[int, ...]:
    value = table.get("picks", [])
    if not isinstance(value, list):
        raise CueError(f"{where}: picks must be a list of take numbers")
    picks: list[int] = []
    for item in value:
        if isinstance(item, bool) or not isinstance(item, int) or not 1 <= item <= takes:
            raise CueError(f"{where}: each pick must be a take number from 1 to {takes}")
        if item in picks:
            raise CueError(f"{where}: pick {item} is listed twice")
        picks.append(item)
    return tuple(picks)


def _defaults(table: dict[str, object]) -> dict[str, object]:
    _only_keys(table, set(DEFAULT_KEYS), "[defaults]")
    missing = [k for k in DEFAULT_KEYS if k not in table]
    if missing:
        raise CueError(f"[defaults] is missing {', '.join(missing)}")
    _check_shared(table, "[defaults]")
    return dict(table)


def _check_shared(table: dict[str, object], where: str) -> None:
    """Range-checks the keys a cue shares with [defaults], for whichever of them `table` holds."""
    if "variants" in table:
        _int(table, "variants", where, 1, 10)
    if "takes" in table:
        _int(table, "takes", where, 1, 20)
    if "max_voices" in table:
        _int(table, "max_voices", where, 1, 24)
    if "level_db" in table:
        _number(table, "level_db", where, -60.0, 12.0)
    if "pitch_spread" in table:
        _number(table, "pitch_spread", where, 0.0, 0.5)
    if "prompt_influence" in table:
        _number(table, "prompt_influence", where, 0.0, 1.0)
    if "model" in table:
        _text(table, "model", where)
    if "bus" in table and table["bus"] not in BUSES:
        raise CueError(f"{where}: bus must be one of {', '.join(BUSES)}")


def _playback(table: dict[str, object]) -> dict[str, str]:
    _only_keys(table, set(CATEGORIES), "[playback]")
    out: dict[str, str] = {}
    for category in CATEGORIES:
        value = table.get(category)
        if value not in PLAYBACKS:
            raise CueError(f"[playback]: {category} must be \"sample\" or \"stream\"")
        out[category] = str(value)
    return out


def _cue(cue_id: str, body: dict[str, object], defaults: dict[str, object]) -> Cue:
    where = f"[cue.{cue_id}]"
    _only_keys(body, CUE_KEYS, where)
    _check_shared(body, where)
    category = body.get("category")
    if category not in CATEGORIES:
        raise CueError(f"{where}: category must be one of {', '.join(CATEGORIES)}")
    loop = body.get("loop", False)
    if not isinstance(loop, bool):
        raise CueError(f"{where}: loop must be true or false")
    if loop != (category in LOOP_CATEGORIES):
        raise CueError(f"{where}: {category} cues {'must' if category in LOOP_CATEGORIES else 'must not'} loop")
    placeholder = body.get("placeholder")
    if placeholder is not None and (not isinstance(placeholder, str) or PLACEHOLDER.fullmatch(placeholder) is None):
        raise CueError(f"{where}: placeholder must be res://assets/audio/sfx/<name>.wav")
    merged = {**defaults, **{k: v for k, v in body.items() if k in DEFAULT_KEYS}}
    takes = int(merged["takes"])  # type: ignore[call-overload]  # range-checked above
    return Cue(
        id=cue_id,
        category=str(category),
        prompt=_text(body, "prompt", where),
        duration_s=_number(body, "duration_s", where, *SFX_SECONDS),
        loop=loop,
        variants=int(merged["variants"]),  # type: ignore[call-overload]
        takes=takes,
        bus=str(merged["bus"]),
        level_db=float(merged["level_db"]),  # type: ignore[arg-type]
        max_voices=int(merged["max_voices"]),  # type: ignore[call-overload]
        pitch_spread=float(merged["pitch_spread"]),  # type: ignore[arg-type]
        model=str(merged["model"]),
        prompt_influence=float(merged["prompt_influence"]),  # type: ignore[arg-type]
        placeholder=placeholder,
        picks=_picks(body, takes, where),
    )
