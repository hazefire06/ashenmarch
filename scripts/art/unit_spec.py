"""A unit's art recipe: art-src/units/<id>/spec.toml plus art-src/style.toml.

meshy.py reads it to know what to buy, and render_sprites.py (inside Blender)
to know what to render. Each animation comes from one of:
- a Meshy library action (`action` id plus its library `clip` name),
- the free walk or run clip from the rig task (`rig`),
- a local GLB (`file`; used by the Blender test fixture).
"""
from __future__ import annotations

import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PREVIEW_MODELS: dict[str, str] = {"lite": "meshy-6-lite", "full": "meshy-7.1"}
MAX_PROMPT = 800
LOOPING = frozenset({"idle", "walk"})
RIG_CLIPS = frozenset({"walk", "run"})


class SpecError(Exception):
    """A recipe is missing something or asks for something impossible."""


@dataclass(frozen=True)
class Style:
    suffix: str
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

    def action_ids(self) -> list[int]:
        return sorted({a.action_id for a in self.animations if a.action_id is not None})

    def full_prompt(self, style: Style) -> str:
        text = f"{self.prompt}. Palette: {style.palettes[self.faction]}. {style.suffix}"
        if len(text) > MAX_PROMPT:
            raise SpecError(f"{self.id}: the prompt is {len(text)} characters; Meshy allows {MAX_PROMPT}")
        return text


def load_style(path: Path) -> Style:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    return Style(suffix=str(data["suffix"]), palettes={k: str(v) for k, v in data["palettes"].items()})


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
        )
    except KeyError as missing:
        raise SpecError(f"{path}: missing {missing}") from None
    if spec.id != path.parent.name:
        raise SpecError(f"{path}: id {spec.id!r} does not match its folder {path.parent.name!r}")
    if spec.height_m <= 0:
        raise SpecError(f"{path}: height_m must be positive")
    if spec.faction not in ("light", "dark"):
        raise SpecError(f"{path}: faction must be light or dark")
    return spec


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
