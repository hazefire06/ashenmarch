"""Writes picks into the cue book and the voice files, and changes nothing else.

Only the `picks = ...` line inside the right `[cue.<id>]` (or `[layer.<id>]`, `[line.<id>]`) table is replaced. Every other byte of
the file stays as it was, comments and line endings included. A table without a picks line is refused, never invented.
"""
from __future__ import annotations

import re

HEADER: re.Pattern[str] = re.compile(r"\s*\[([^\[\]]+)\]\s*(#.*)?")
PICKS_LINE: re.Pattern[str] = re.compile(r"picks\s*=")


class PicksError(Exception):
    """The picks can't be written: an unknown table, or one with no picks line."""


def _rewrite(text: str, table: str, prefix: str, value: dict[str, str]) -> str:
    lines = text.splitlines(keepends=True)
    index = {name: _find(lines, f"{prefix}.{name}") for name in value}
    for name, at in index.items():
        if at is None:
            raise PicksError(f"[{prefix}.{name}] isn't in the file")
        if at < 0:
            raise PicksError(f"[{prefix}.{name}] has no picks line")
    for name, at in index.items():
        assert at is not None
        old = lines[at]
        end = old[len(old.rstrip("\r\n")):]
        lines[at] = f"picks = {value[name]}{end}"
    return "".join(lines)


def _find(lines: list[str], header: str) -> int | None:
    """The index of the picks line in the table `header`, -1 if it has none, None if there is no such table."""
    in_string = ""
    in_table = False
    found: int | None = None
    for i, line in enumerate(lines):
        if in_string:
            if line.count(in_string) % 2 == 1:
                in_string = ""
            continue
        stripped = line.strip()
        match = HEADER.fullmatch(stripped) if stripped.startswith("[") else None
        if match is not None:
            if in_table:
                return found if found is not None else -1
            in_table = match.group(1).strip() == header
            if in_table:
                found = None
            continue
        if in_table and PICKS_LINE.match(stripped):
            if stripped.count("[") != stripped.count("]") or stripped.count("{") != stripped.count("}"):
                raise PicksError(f"[{header}]: the picks must sit on one line")
            found = i
        for quote in ('"""', "'''"):
            if line.count(quote) % 2 == 1:
                in_string = quote
    if in_table:
        return found if found is not None else -1
    return None


def apply_cue_picks(text: str, picks: dict[str, list[int]], table: str = "cue") -> str:
    """`picks = [1, 4, 5]` for each cue (or, with table="layer", each music layer)."""
    return _rewrite(text, table, table, {cue: "[" + ", ".join(str(n) for n in takes) + "]" for cue, takes in picks.items()})


def apply_line_picks(text: str, picks: dict[str, dict[str, int]]) -> str:
    """`picks = { shieldman_old = 2, shieldman_young = 1 }` for each line, voices in name order."""
    def inline(voices: dict[str, int]) -> str:
        return "{ " + ", ".join(f"{v} = {n}" for v, n in sorted(voices.items())) + " }" if voices else "{}"
    return _rewrite(text, "line", "line", {line: inline(voices) for line, voices in picks.items()})
