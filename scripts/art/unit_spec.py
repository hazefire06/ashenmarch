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
"""
from __future__ import annotations

import math
import re
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PREVIEW_MODELS: dict[str, str] = {"lite": "meshy-6-lite", "full": "meshy-7.1"}
MAX_PROMPT = 800
LOOPING = frozenset({"idle", "walk"})
RIG_CLIPS = frozenset({"walk", "run"})
# Unit and prop names become folder names under art-src, so they must not hold path pieces.
NAME = re.compile(r"[a-z][a-z0-9_]{0,31}")
FACTIONS = ("light", "dark")


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
    """A weapon or piece of gear bought as its own model (spec §6.2a). length_m is its longest axis."""
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
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    try:
        return Style(
            suffix=str(data["suffix"]),
            prop_suffix=str(data["prop_suffix"]),
            palettes={k: str(v) for k, v in data["palettes"].items()},
        )
    except KeyError as missing:
        raise SpecError(f"{path}: missing {missing}") from None


def load_spec(path: Path) -> UnitSpec:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    try:
        candidates = data.get("candidates", {})
        spec = UnitSpec(
            id=str(data["id"]),
            faction=str(data["faction"]),
            height_m=float(data["height_m"]),
            prompt=str(data["prompt"]),
            lite=int(candidates.get("lite", 0)),
            full=int(candidates.get("full", 0)),
            polycount=int(candidates.get("polycount", 30000)),
            die_falls_forward=bool(data.get("die_falls_forward", False)),
            bursts_on_death=bool(data.get("bursts_on_death", False)),
            animations=tuple(_anim(name, entry) for name, entry in data["animations"].items()),
            attach=_attachments(path, data.get("attach", [])),
        )
    except KeyError as missing:
        raise SpecError(f"{path}: missing {missing}") from None
    if spec.id != path.parent.name:
        raise SpecError(f"{path}: id {spec.id!r} does not match its folder {path.parent.name!r}")
    if spec.height_m <= 0:
        raise SpecError(f"{path}: height_m must be positive")
    if spec.faction not in FACTIONS:
        raise SpecError(f"{path}: faction must be light or dark")
    return spec


def load_prop_spec(path: Path) -> PropSpec:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    try:
        candidates = data.get("candidates", {})
        spec = PropSpec(
            id=str(data["id"]),
            faction=str(data["faction"]),
            length_m=float(data["length_m"]),
            prompt=str(data["prompt"]),
            lite=int(candidates.get("lite", 0)),
            full=int(candidates.get("full", 0)),
            polycount=int(candidates.get("polycount", 6000)),
        )
    except KeyError as missing:
        raise SpecError(f"{path}: missing {missing}") from None
    if spec.id != path.parent.name:
        raise SpecError(f"{path}: id {spec.id!r} does not match its folder {path.parent.name!r}")
    if spec.length_m <= 0:
        raise SpecError(f"{path}: length_m must be positive")
    if spec.faction not in FACTIONS:
        raise SpecError(f"{path}: faction must be light or dark")
    return spec


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
    if not isinstance(bone, str) or not bone:
        raise SpecError(f"{where}: bone must be the name of a bone in the unit's rig")
    return AttachEntry(prop=prop, bone=bone, offset=_triple(where, "offset", entry), rotation=_triple(where, "rotation", entry))


def _triple(where: str, key: str, entry: dict[str, Any]) -> tuple[float, float, float]:
    value = entry.get(key, [0.0, 0.0, 0.0])
    if (not isinstance(value, list) or len(value) != 3
            or not all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in value)):
        raise SpecError(f"{where}: {key} must be exactly 3 numbers")
    return (float(value[0]), float(value[1]), float(value[2]))


def _anim(name: str, entry: dict[str, Any]) -> AnimEntry:
    rig = entry.get("rig")
    action = entry.get("action")
    file = entry.get("file")
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
