"""Loads and checks the cue book (audio-src/cues.toml), the music layers (audio-src/music/prompts.toml)
and the voice files (audio-src/voices/*.toml).

The paid generator buys sounds from these prompts and the bank builder turns
every id into a file name, so this is the security boundary: an id must match
[a-z0-9_]+ in full and at most 48 characters, every table refuses keys it
doesn't know, and every number is
range-checked before anything else sees it. Only CueError escapes. A
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
MAX_ID: int = 48

SFX_MODELS: tuple[str, ...] = ("eleven_text_to_sound_v2", "eleven_text_to_sound_v3")
MUSIC_MODELS: tuple[str, ...] = ("music_v1", "music_v2", "music_v2_5")
LOOP_MODEL: str = "eleven_text_to_sound_v3"  # loops need the v3 model
VOCAL_CATEGORIES: tuple[str, ...] = ("death", "groan")  # these take the vocal suffix

DEFAULT_KEYS: tuple[str, ...] = (
    "variants", "takes", "bus", "level_db", "max_voices", "pitch_spread", "model", "prompt_influence",
)
CUE_KEYS: frozenset[str] = frozenset(DEFAULT_KEYS) | {"category", "prompt", "duration_s", "loop", "placeholder", "picks"}
LAYER_KEYS: frozenset[str] = frozenset({"prompt", "length_s", "model", "takes", "picks"})

FORMATION_NAMES: tuple[str, ...] = (  # Formations.Kind, lowercased
    "short_line", "long_line", "loose_line", "staggered_line", "box", "rabble",
    "shallow_encirclement", "deep_encirclement", "wedge", "circle",
)
TRIGGERS: frozenset[str] = frozenset({
    "select", "move", "attack", "special", "retreat", "kill", "hurt", "death", "annoyed", "victory",
    "status_burning", "status_paralyzed", "status_confused", "fizzle", "heal_undead",
    *(f"formation_{name}" for name in FORMATION_NAMES),
})
REQUIRED_TRIGGERS: tuple[str, ...] = ("select", "move", "attack", "kill", "hurt", "death", "annoyed")
CLAN: str = "_clan"  # the voice file whose lines any clan unit may say on any trigger
CLAN_PREFIX: str = "clan_"
VOICE_MODELS: tuple[str, ...] = ("eleven_v4",)  # until the A/B test
VOICE_KEYS: frozenset[str] = frozenset({"description", "model"})
LINE_KEYS: frozenset[str] = frozenset({"trigger", "text", "tag", "picks"})
# A delivery tag goes to a paid TTS, so it is bracketed lowercase words and nothing else.
TAG: re.Pattern[str] = re.compile(r"(\[[a-z ]{1,24}\] ?)+")
MAX_TAG: int = 40
MAX_LINE_TEXT: int = 300
MAX_DESCRIPTION: int = 600
MAX_TAKE: int = 20


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
    vocal_suffix: str
    playback: dict[str, str]
    cues: dict[str, Cue]

    def prompt_for(self, cue_id: str) -> str:
        """The prompt to send for a cue: its own text plus the style suffix for its category."""
        cue = self.cues[cue_id]
        suffix = self.vocal_suffix if cue.category in VOCAL_CATEGORIES else self.style_suffix
        return f"{cue.prompt.strip()} {suffix}"


@dataclass(frozen=True)
class Layer:
    id: str
    prompt: str
    length_s: float
    model: str
    takes: int
    picks: tuple[int, ...]


@dataclass(frozen=True)
class Voice:
    id: str
    description: str
    model: str


@dataclass(frozen=True)
class Line:
    id: str
    trigger: str  # "" for a clan line, which can replace any trigger
    text: str
    tag: str | None
    picks: dict[str, int]  # voice id -> the kept take


@dataclass(frozen=True)
class VoiceFile:
    unit: str  # a unit type id, or "_clan"
    voices: dict[str, Voice]
    lines: dict[str, Line]


def _show(value: object) -> str:
    """A value for a message: its type for non-text, else at most 40 characters."""
    if not isinstance(value, str):
        return f"a {type(value).__name__}"
    text = value if len(value) <= MAX_SHOWN else value[:MAX_SHOWN] + "..."
    return repr(text)


def check_id(value: object, what: str) -> str:
    if not isinstance(value, str) or len(value) > MAX_ID or ID.fullmatch(value) is None:
        raise CueError(f"{what}: {_show(value)} isn't a safe id (lowercase letters, digits and _, at most {MAX_ID})")
    return value


def _clip(text: str) -> str:
    """At most 40 characters of a checked id, for a message's table name."""
    return text if len(text) <= MAX_SHOWN else text[:MAX_SHOWN] + "..."


def load_cues(path: Path) -> CueBook:
    root = _read(path)
    _only_keys(root, {"style", "defaults", "playback", "cue"}, "top level")
    style = _table(root, "style")
    _only_keys(style, {"suffix", "vocal_suffix"}, "[style]")
    suffix = _text(style, "suffix", "[style]")
    vocal_suffix = _text(style, "vocal_suffix", "[style]")
    defaults = _defaults(_table(root, "defaults"))
    playback = _playback(_table(root, "playback"))
    cues: dict[str, Cue] = {}
    for raw_id, body in _table(root, "cue").items():
        cue_id = check_id(raw_id, "[cue] table name")
        if not isinstance(body, dict):
            raise CueError(f"[cue.{_clip(cue_id)}] isn't a table")
        cues[cue_id] = _cue(cue_id, body, defaults)
    if not cues:
        raise CueError("[cue] holds no cues")
    return CueBook(suffix, vocal_suffix, playback, cues)


def load_layers(path: Path) -> dict[str, Layer]:
    root = _read(path)
    _only_keys(root, {"layer"}, "top level")
    layers: dict[str, Layer] = {}
    for raw_id, body in _table(root, "layer").items():
        layer_id = check_id(raw_id, "[layer] table name")
        where = f"[layer.{_clip(layer_id)}]"
        if not isinstance(body, dict):
            raise CueError(f"{where} isn't a table")
        _only_keys(body, LAYER_KEYS, where)
        takes = _int(body, "takes", where, low=1, high=20)
        model = _text(body, "model", where)
        if model not in MUSIC_MODELS:
            raise CueError(f"{where}: model must be one of {', '.join(MUSIC_MODELS)}")
        layers[layer_id] = Layer(
            id=layer_id,
            prompt=_text(body, "prompt", where),
            length_s=_number(body, "length_s", where, *MUSIC_SECONDS),
            model=model,
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
    _check_variants(table, "[defaults]")
    return dict(table)


def _check_variants(table: dict[str, object], where: str) -> None:
    if _int(table, "variants", where, 1, 10) > _int(table, "takes", where, 1, 20):
        raise CueError(f"{where}: variants can't exceed takes")


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
    if "model" in table and table["model"] not in SFX_MODELS:
        raise CueError(f"{where}: model must be one of {', '.join(SFX_MODELS)}")
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
    where = f"[cue.{_clip(cue_id)}]"
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
    _check_variants(merged, where)
    model = _text(merged, "model", where)
    if loop and model != LOOP_MODEL:
        raise CueError(f"{where}: a loop must use {LOOP_MODEL}")
    takes = _int(merged, "takes", where, 1, 20)
    return Cue(
        id=cue_id,
        category=str(category),
        prompt=_text(body, "prompt", where),
        duration_s=_number(body, "duration_s", where, *SFX_SECONDS),
        loop=loop,
        variants=_int(merged, "variants", where, 1, 10),
        takes=takes,
        bus=_text(merged, "bus", where),  # in BUSES: _check_shared ran on the defaults and on the cue
        level_db=_number(merged, "level_db", where, -60.0, 12.0),
        max_voices=_int(merged, "max_voices", where, 1, 24),
        pitch_spread=_number(merged, "pitch_spread", where, 0.0, 0.5),
        model=model,
        prompt_influence=_number(merged, "prompt_influence", where, 0.0, 1.0),
        placeholder=placeholder,
        picks=_picks(body, takes, where),
    )


def load_voices(folder: Path) -> dict[str, VoiceFile]:
    """Every audio-src/voices/*.toml, keyed by unit ("_clan" for the clan-wide lines)."""
    paths = sorted(folder.glob("*.toml")) if folder.is_dir() else []
    if not paths:
        raise CueError(f"{_clip(folder.name)}: no voice files")
    files: dict[str, VoiceFile] = {}
    raw: dict[str, tuple[dict[str, object], dict[str, object]]] = {}
    for path in paths:
        root = _read(path)
        where = f"[voice file {_clip(path.stem)}]"
        _only_keys(root, {"unit", "voice", "line"}, where)
        unit = check_id(root.get("unit"), f"{where} unit")
        if unit != path.stem:
            raise CueError(f"{where}: unit {_show(unit)} must match the file name")
        voices = _voices(root, unit, where)
        raw[unit] = (root, voices)  # type: ignore[assignment]
        files[unit] = VoiceFile(unit, voices, {})  # type: ignore[arg-type]
    light = {v for f in files.values() for v in f.voices}
    for unit, (root, _) in raw.items():
        known = light if unit == CLAN else set(files[unit].voices)
        files[unit] = VoiceFile(unit, files[unit].voices, _lines(root, unit, known))
    return files


def _voices(root: dict[str, object], unit: str, where: str) -> dict[str, Voice]:
    table = root.get("voice", {})
    if not isinstance(table, dict):
        raise CueError(f"{where}: [voice] isn't a table")
    if unit == CLAN:
        if table:
            raise CueError(f"{where}: the clan file has no voices; each speaker uses its own")
        return {}
    if not table:
        raise CueError(f"{where}: [voice] holds no voices")
    voices: dict[str, Voice] = {}
    for raw_id, body in table.items():
        voice_id = check_id(raw_id, f"{where} [voice] table name")
        here = f"[voice.{_clip(voice_id)}]"
        if not isinstance(body, dict):
            raise CueError(f"{here} isn't a table")
        _only_keys(body, VOICE_KEYS, here)
        description = _text(body, "description", here)
        if len(description) > MAX_DESCRIPTION:
            raise CueError(f"{here}: description is longer than {MAX_DESCRIPTION} characters")
        model = _text(body, "model", here)
        if model not in VOICE_MODELS:
            raise CueError(f"{here}: model must be one of {', '.join(VOICE_MODELS)}")
        voices[voice_id] = Voice(voice_id, description, model)
    return voices


def _lines(root: dict[str, object], unit: str, known_voices: set[str]) -> dict[str, Line]:
    table = root.get("line")
    if not isinstance(table, dict) or not table:
        raise CueError(f"[voice file {_clip(unit)}]: [line] holds no lines")
    lines: dict[str, Line] = {}
    for raw_id, body in table.items():
        line_id = check_id(raw_id, "[line] table name")
        where = f"[line.{_clip(line_id)}]"
        if not isinstance(body, dict):
            raise CueError(f"{where} isn't a table")
        _only_keys(body, LINE_KEYS, where)
        if unit == CLAN:
            if not line_id.startswith(CLAN_PREFIX):
                raise CueError(f"{where}: a clan line's id must start with {CLAN_PREFIX}")
            if "trigger" in body:
                raise CueError(f"{where}: a clan line has no trigger")
            trigger = ""
        else:
            trigger = _text(body, "trigger", where)
            if trigger not in TRIGGERS:
                raise CueError(f"{where}: unknown trigger {_show(trigger)}")
        text = _text(body, "text", where)
        if len(text) > MAX_LINE_TEXT:
            raise CueError(f"{where}: text is longer than {MAX_LINE_TEXT} characters")
        lines[line_id] = Line(line_id, trigger, text, _tag(body, where), _line_picks(body, known_voices, where))
    return lines


def _tag(body: dict[str, object], where: str) -> str | None:
    if "tag" not in body:
        return None
    tag = body["tag"]
    if not isinstance(tag, str) or len(tag) > MAX_TAG or TAG.fullmatch(tag) is None:
        raise CueError(f"{where}: tag must be bracketed lowercase words, at most {MAX_TAG} characters")
    return tag


def _line_picks(body: dict[str, object], known_voices: set[str], where: str) -> dict[str, int]:
    value = body.get("picks", {})
    if not isinstance(value, dict):
        raise CueError(f"{where}: picks must be a table of voice = take")
    picks: dict[str, int] = {}
    for voice, take in value.items():
        voice_id = check_id(voice, f"{where} pick")
        if voice_id not in known_voices:
            raise CueError(f"{where}: pick for {_show(voice_id)}, which isn't one of its voices")
        if isinstance(take, bool) or not isinstance(take, int) or not 1 <= take <= MAX_TAKE:
            raise CueError(f"{where}: each pick must be a take number from 1 to {MAX_TAKE}")
        picks[voice_id] = take
    return picks
