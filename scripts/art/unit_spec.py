"""A unit's art recipe: art-src/units/<id>/spec.toml plus art-src/style.toml.

meshy.py reads it to know what to buy, and render_sprites.py (inside Blender)
to know what to render. Each animation comes from one of:
- a Meshy library action (`action` id plus its library `clip` name),
- the free walk or run clip from the rig task (`rig`),
- a local GLB (`file`; used by the Blender test fixture).

Held gear is a separate recipe (spec §6.2a): a prop, art-src/props/<id>/spec.toml,
bought as its own textured, unrigged model. A unit lists what it carries as
`[[attach]]` tables (prop, bone, offset, rotation); the renderer fixes each
prop to that bone of the unit's rig. Both recipe kinds expose `pose_mode`,
which is what the Meshy preview is asked for: a unit's A-pose, or nothing for
a prop (an A-pose is meaningless for a sword). Standard library only, because
Blender's Python imports this file too.

A recipe is checked as it loads, because its values buy things or name files:
candidate counts and the polycount are whole numbers in range, animation names
are plain names, and an animation takes its clip from the rig or a library
action, never both. A recipe with no [candidates] table loads (the renderer
needs no candidates) but buys nothing; one that has the table lists at least
one candidate.
"""
from __future__ import annotations

import math
import re
import tomllib
from dataclasses import dataclass
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Any

PREVIEW_MODELS: dict[str, str] = {"lite": "meshy-6-lite", "full": "meshy-7.1"}
MAX_PROMPT = 800
MAX_CANDIDATES = 9999  # candidates are labelled cand-1 to cand-9999, the widest a model/PICK marker may hold
POLYCOUNT_RANGE = (100, 300000)  # what Meshy's target_polycount accepts
LOOPING = frozenset({"idle", "walk"})
RIG_CLIPS = frozenset({"walk", "run"})
# Unit and prop names become folder names under art-src, so they must not hold path pieces.
NAME = re.compile(r"[a-z][a-z0-9_]{0,31}")
FACTIONS = ("light", "dark")
# A bone name from a rig (Blender's own, or a Mixamo-style "mixamorig:LeftForeArm"): plain characters only.
BONE = re.compile(r"[A-Za-z0-9_.:\- ]{1,63}")


class SpecError(Exception):
    """A recipe is missing something or asks for something impossible."""


@dataclass(frozen=True)
class Style:
    suffix: str
    prop_suffix: str
    palettes: dict[str, str]


@dataclass(frozen=True)
class AnimEntry:
    name: str
    file: str
    clip: str | None
    action_id: int | None
    impact: float | None
    loop: bool


@dataclass(frozen=True)
class AttachEntry:
    """One prop a unit carries: fixed to `bone` of the unit's rig, nudged by offset (m) and rotation (degrees, XYZ Euler), both in the bone's space."""
    prop: str
    bone: str
    offset: tuple[float, float, float]
    rotation: tuple[float, float, float]


@dataclass(frozen=True)
class UnitSpec:
    id: str
    faction: str
    height_m: float
    prompt: str
    lite: int
    full: int
    polycount: int
    die_falls_forward: bool
    bursts_on_death: bool
    animations: tuple[AnimEntry, ...]
    attach: tuple[AttachEntry, ...] = ()

    @property
    def pose_mode(self) -> str | None:
        """The pose Meshy builds the preview in: an A-pose keeps the arms clear of the body for rigging."""
        return "a-pose"

    def action_ids(self) -> list[int]:
        return sorted({a.action_id for a in self.animations if a.action_id is not None})

    def full_prompt(self, style: Style) -> str:
        return _full_prompt(self.id, self.prompt, style.palettes[self.faction], style.suffix)


@dataclass(frozen=True)
class PropSpec:
    """A weapon or piece of gear bought as its own model (spec §6.2a). length_m is its length along its longest principal axis."""
    id: str
    faction: str
    length_m: float
    prompt: str
    lite: int
    full: int
    polycount: int

    @property
    def pose_mode(self) -> str | None:
        """None: a prop is previewed with no pose setting at all."""
        return None

    def full_prompt(self, style: Style) -> str:
        return _full_prompt(self.id, self.prompt, style.palettes[self.faction], style.prop_suffix)


def _full_prompt(recipe_id: str, prompt: str, palette: str, suffix: str) -> str:
    text = f"{prompt}. Palette: {palette}. {suffix}"
    if len(text) > MAX_PROMPT:
        raise SpecError(f"{recipe_id}: the prompt is {len(text)} characters; Meshy allows {MAX_PROMPT}")
    return text


def load_style(path: Path) -> Style:
    data = _read_toml(path)
    try:
        return Style(
            suffix=str(data["suffix"]),
            prop_suffix=str(data["prop_suffix"]),
            palettes={k: str(v) for k, v in data["palettes"].items()},
        )
    except KeyError as missing:
        raise SpecError(f"{path}: missing {missing}") from None


def load_spec(path: Path) -> UnitSpec:
    data = _read_toml(path)
    try:
        lite, full, polycount = _candidates(path, data, default_polycount=30000)
        spec = UnitSpec(
            id=str(data["id"]),
            faction=str(data["faction"]),
            height_m=_length(path, "height_m", data["height_m"]),
            prompt=str(data["prompt"]),
            lite=lite,
            full=full,
            polycount=polycount,
            die_falls_forward=bool(data.get("die_falls_forward", False)),
            bursts_on_death=bool(data.get("bursts_on_death", False)),
            animations=tuple(_anim(name, entry) for name, entry in data["animations"].items()),
            attach=_attachments(path, data.get("attach", [])),
        )
    except KeyError as missing:
        raise SpecError(f"{path}: missing {missing}") from None
    if spec.id != path.parent.name:
        raise SpecError(f"{path}: id {spec.id!r} does not match its folder {path.parent.name!r}")
    if spec.faction not in FACTIONS:
        raise SpecError(f"{path}: faction must be light or dark")
    return spec


def load_prop_spec(path: Path) -> PropSpec:
    data = _read_toml(path)
    try:
        lite, full, polycount = _candidates(path, data, default_polycount=6000)
        spec = PropSpec(
            id=str(data["id"]),
            faction=str(data["faction"]),
            length_m=_length(path, "length_m", data["length_m"]),
            prompt=str(data["prompt"]),
            lite=lite,
            full=full,
            polycount=polycount,
        )
    except KeyError as missing:
        raise SpecError(f"{path}: missing {missing}") from None
    if spec.id != path.parent.name:
        raise SpecError(f"{path}: id {spec.id!r} does not match its folder {path.parent.name!r}")
    if spec.faction not in FACTIONS:
        raise SpecError(f"{path}: faction must be light or dark")
    return spec


def _read_toml(path: Path) -> dict[str, Any]:
    """The parsed file, with a bad one turned into a SpecError. tomllib's message is a position or a repr'd character, so it
    is safe to show; the decoder's holds the offending bytes, so it is not."""
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as error:
        raise SpecError(f"{path}: {error}") from None
    except UnicodeDecodeError:
        raise SpecError(f"{path}: isn't UTF-8 text") from None


def _candidates(path: Path, data: dict[str, Any], default_polycount: int) -> tuple[int, int, int]:
    """lite, full and polycount from the optional [candidates] table. They decide what is bought and at what size, so they
    are checked here. No table means nothing to buy, which the renderer's recipes rely on; a table must list a candidate."""
    table = data.get("candidates", {})
    if not isinstance(table, dict):
        raise SpecError(f"{path}: candidates must be a [candidates] table")
    lite = _whole(path, "candidates.lite", table.get("lite", 0), 0, MAX_CANDIDATES)
    full = _whole(path, "candidates.full", table.get("full", 0), 0, MAX_CANDIDATES)
    polycount = _whole(path, "candidates.polycount", table.get("polycount", default_polycount), *POLYCOUNT_RANGE)
    if "candidates" in data:
        if lite + full < 1:
            raise SpecError(f"{path}: [candidates] needs at least one candidate (lite plus full)")
        if lite + full > MAX_CANDIDATES:  # cand-10000 would be bought and then refused as malformed by model/PICK
            raise SpecError(f"{path}: [candidates] lists {lite + full} candidates; at most {MAX_CANDIDATES}")
    return lite, full, polycount


def _whole(path: Path, key: str, value: Any, low: int, high: int) -> int:
    """A whole number from low to high. TOML `true` would pass as 1, and `2.0` or "2" would be quietly truncated or converted."""
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise SpecError(f"{path}: {key} must be a whole number from {low} to {high}, not {str(value)[:40]!r}")
    return value


def _length(path: Path, key: str, value: Any) -> float:
    """A size in metres: a finite number above zero. TOML `true` would otherwise pass as 1.0, and `nan` or `inf` would pass every comparison."""
    try:
        number = float(value) if not isinstance(value, bool) else None
    except (TypeError, ValueError, OverflowError):  # OverflowError: an integer too big for a float
        number = None
    if number is None or not math.isfinite(number) or number <= 0:
        raise SpecError(f"{path}: {key} must be positive and finite, not {str(value)[:40]!r}")
    return number


def _attachments(path: Path, entries: Any) -> tuple[AttachEntry, ...]:
    if not isinstance(entries, list):
        raise SpecError(f"{path}: attach must be a list of [[attach]] tables")
    return tuple(_attach(path, number, entry) for number, entry in enumerate(entries, start=1))


def _attach(path: Path, number: int, entry: Any) -> AttachEntry:
    # Errors name the entry by position and prop, since a unit can carry several.
    if not isinstance(entry, dict):
        raise SpecError(f"{path}: attach entry {number} must be a table with prop and bone")
    named = f" ({entry['prop']!r})" if isinstance(entry.get("prop"), str) else ""
    where = f"{path}: attach entry {number}{named}"
    unknown = sorted(set(entry) - {"prop", "bone", "offset", "rotation"})
    if unknown:  # a misspelt `rotaton` would otherwise silently stay at zero
        raise SpecError(f"{where}: unknown key {unknown[0]!r}")
    prop, bone = entry.get("prop"), entry.get("bone")
    if not isinstance(prop, str) or NAME.fullmatch(prop) is None:  # it becomes art-src/props/<prop>, so no path pieces
        raise SpecError(f"{where}: prop must be lowercase letters, digits and _ (it names a folder), not {prop!r}")
    if not isinstance(bone, str) or BONE.fullmatch(bone) is None or not bone.strip():
        raise SpecError(f"{where}: bone must be a bone name from the unit's rig: letters, digits and _ . : - space, up to 63 characters")
    return AttachEntry(prop=prop, bone=bone, offset=_triple(where, "offset", entry), rotation=_triple(where, "rotation", entry))


def _triple(where: str, key: str, entry: dict[str, Any]) -> tuple[float, float, float]:
    value = entry.get(key, [0.0, 0.0, 0.0])
    if not isinstance(value, list) or len(value) != 3 or not all(_is_number(v) for v in value):
        raise SpecError(f"{where}: {key} must be exactly 3 numbers")
    return (float(value[0]), float(value[1]), float(value[2]))


def _is_number(value: Any) -> bool:
    """A finite int or float. isfinite() raises OverflowError for an integer too big for a float, which is just as unusable."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _relative_file(name: str, file: Any) -> str:
    """An animation's GLB, relative to the unit's folder. The renderer opens unit_dir / file, so an absolute path or a `..`
    would let a recipe read any file on the machine."""
    ok = isinstance(file, str) and bool(file) and "\0" not in file and "\\" not in file
    if ok:
        posix, windows = PurePosixPath(file), PureWindowsPath(file)
        ok = not posix.is_absolute() and ".." not in posix.parts and not windows.drive
    if not ok:
        raise SpecError(f"animation {name}: file must be a relative path inside the unit's folder, with no '..', not {str(file)[:40]!r}")
    return file


def animation_file(unit_dir: Path, entry: AnimEntry) -> Path:
    """Where an animation's GLB is. The recipe's path is relative (checked on load), but a symlink inside the folder could
    still lead out of it, so the renderer opens only what resolves inside unit_dir."""
    path = unit_dir / entry.file
    if not path.resolve().is_relative_to(unit_dir.resolve()):
        raise SpecError(f"animation {entry.name}: file {entry.file[:40]!r} resolves outside {unit_dir.name}/ (a symlink?)")
    return path


def _anim(name: str, entry: dict[str, Any]) -> AnimEntry:
    # The name becomes output paths in render_sprites (a sheet, its .import and a review gif), so no path pieces.
    if NAME.fullmatch(name) is None:
        raise SpecError(f"animation name {name[:40]!r} must be lowercase letters, digits and _ (it names output files), "
                        "starting with a letter, at most 32 characters")
    rig = entry.get("rig")
    action = entry.get("action")
    file = entry.get("file")
    if file is not None:
        file = _relative_file(name, file)
    if rig is not None and action is not None:  # action_id would be bought for a clip no file uses
        raise SpecError(f"animation {name}: set rig or action, not both")
    if rig is not None:
        if rig not in RIG_CLIPS:
            raise SpecError(f"animation {name}: rig must be walk or run, not {rig!r}")
        file = file or f"anims/rig_{rig}.glb"
    elif action is not None:
        file = file or "anims/actions.glb"
        if not entry.get("clip"):
            raise SpecError(f"animation {name}: an action needs its clip name (the Meshy library name)")
    elif file is None:
        raise SpecError(f"animation {name}: needs action, rig or file")
    impact = entry.get("impact")
    if impact is not None and not 0.0 <= float(impact) <= 1.0:
        raise SpecError(f"animation {name}: impact is a fraction of the clip, 0..1")
    return AnimEntry(
        name=name,
        file=str(file),
        clip=entry.get("clip"),
        action_id=int(action) if action is not None else None,
        impact=float(impact) if impact is not None else None,
        loop=name in LOOPING,
    )
