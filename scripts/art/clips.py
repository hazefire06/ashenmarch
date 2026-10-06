"""Finds the action holding a wanted clip among those a GLB import made.

Blender names imported actions like "Armature|<clip>". A Meshy multi-action
file holds one clip per library action, named after it, so the library name
picks the clip: an exact match after the "|" first, then a unique partial
match.
"""
from __future__ import annotations


def pick_clip(names: list[str], wanted: str | None) -> str | None:
    if wanted is None:
        if len(names) > 1:
            raise ValueError(f"the file has {len(names)} clips {names}; name one with clip = \"...\"")
        return names[0] if names else None
    key = wanted.lower()
    exact = [n for n in names if n.split("|")[-1].lower() == key]
    if len(exact) == 1:
        return exact[0]
    partial = [n for n in names if key in n.lower()]
    if len(partial) == 1:
        return partial[0]
    if not partial:
        raise ValueError(f"no clip named like {wanted!r} among {names}")
    raise ValueError(f"{len(partial)} clips match {wanted!r}: {partial}")
