"""Writes picks into the cue book and the voice files, and changes nothing else.

Only the value of the `picks = ...` line inside the right `[cue.<id>]` (or `[layer.<id>]`, `[line.<id>]`) table is replaced. Every
other byte of the file stays as it was: the line's indent, a comment after the value, line endings. A table without a picks line is
refused, never invented.

`picks_file` is the `process.py picks` command: it checks a picks file against the cue book and the voice files, then writes it.
"""
from __future__ import annotations

import json
import os
import re
import sys
import tomllib
from pathlib import Path

import assets
import cuebook
from assets import UnsafePath, find_raw
from cuebook import CueError

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
        body = old.rstrip("\r\n")
        eol = old[len(body):]
        head = re.match(r"(\s*)picks\s*=\s*([\[{])", body)
        if head is None:
            raise PicksError(f"[{prefix}.{name}]: the picks must be a list or a table")
        close = body.find("]" if head.group(2) == "[" else "}", head.end())
        if close < 0:
            raise PicksError(f"[{prefix}.{name}]: the picks must sit on one line")
        lines[at] = f"{head.group(1)}picks = {value[name]}{body[close + 1:]}{eol}"  # indent and trailing comment kept
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


# ---- the picks command ----------------------------------------------------------------------------------------------

MAX_PICKS_BYTES: int = 1_000_000


def _take_error(what: str, value: object, takes: int, folder: Path, seen: list[int]) -> str | None:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= takes:
        return f"{what}: each pick must be a take number from 1 to {takes}"
    if value in seen:
        return f"{what}: take {value} is listed twice"
    if find_raw(folder, value) is None:
        return f"{what}: take {value} has no downloaded file"
    return None


def picks_file(path: Path, cues_path: Path, layers_path: Path, voices_dir: Path, root: Path) -> int:
    """Checks a picks file against the cue book and the voice files, then writes it. Any error and nothing is written."""
    raw = root / "audio-src" / "raw"
    try:
        assets.check_no_symlinks(root)
        assets.check_inputs(root, cues_path, layers_path, voices_dir)  # picks writes these, so no part of their paths may be a symlink
        if not path.is_file():
            raise CueError(f"the picks file {path.name[:40]} doesn't exist")
        if path.stat().st_size > MAX_PICKS_BYTES:
            raise CueError("the picks file is too big")
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (ValueError, RecursionError):  # UnicodeDecodeError is a ValueError
            raise CueError("the picks file can't be read as JSON") from None
        book = cuebook.load_cues(cues_path)
        layers = cuebook.load_layers(layers_path)
        files = cuebook.load_voices(voices_dir)
    except (CueError, UnsafePath, OSError) as err:
        cuebook.emit(f"process.py picks: {err if isinstance(err, (CueError, UnsafePath)) else 'a file can not be read'}", file=sys.stderr)
        return 1
    kinds = [k for k in ("cues", "lines", "design") if isinstance(data, dict) and k in data]
    if len(kinds) != 1 or not isinstance(data[kinds[0]], dict) or not data[kinds[0]]:
        cuebook.emit("process.py picks: the file must hold one of cues, lines or design, as a non-empty object", file=sys.stderr)
        return 1
    batch = data.get("batch")
    errors: list[str] = []
    if kinds[0] == "design":
        return _design_picks(data["design"], batch, files, raw)
    cue_picks: dict[str, list[int]] = {}
    layer_picks: dict[str, list[int]] = {}
    line_picks: dict[str, dict[str, int]] = {}
    unit_of: dict[str, str] = {}
    for key, value in data[kinds[0]].items():
        try:
            ident = cuebook.check_id(key, kinds[0])
        except CueError as err:
            errors.append(str(err))
            continue
        if kinds[0] == "cues":
            _check_cue_pick(ident, value, book, layers, raw, cue_picks, layer_picks, errors)
        else:
            _check_line_pick(ident, value, files, raw, line_picks, unit_of, errors)
    if errors:
        cuebook.emit("process.py picks: nothing written:\n  " + "\n  ".join(errors), file=sys.stderr)
        return 1
    try:
        writes = _picks_text(cues_path, layers_path, voices_dir, cue_picks, layer_picks, line_picks, unit_of, files)
    except (PicksError, OSError, UnicodeDecodeError) as err:
        cuebook.emit(f"process.py picks: nothing written: {err}", file=sys.stderr)
        return 1
    try:
        _write_all(writes)
    except OSError as err:
        cuebook.emit(f"process.py picks: nothing written: {err.strerror or 'a file can not be written'}", file=sys.stderr)
        return 1
    for target in writes:
        cuebook.emit(f"wrote picks to {target.name}")
    return 0


def _write_all(writes: dict[Path, str]) -> None:
    """Every target is written to its .part file (opened with O_NOFOLLOW) first, and only when all of those are in place are they renamed
    over their targets. A failure while staging leaves every target as it was."""
    staged: list[tuple[Path, Path]] = []
    try:
        for target, text in writes.items():
            part = target.with_name(target.name + ".part")
            fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
            staged.append((part, target))
            with os.fdopen(fd, "wb") as out:
                out.write(text.encode("utf-8"))  # as the text is: no newline translation
    except BaseException:
        for part, _ in staged:
            part.unlink(missing_ok=True)
        raise
    for part, target in staged:
        os.replace(part, target)


def _check_cue_pick(ident: str, value: object, book: cuebook.CueBook, layers: dict[str, cuebook.Layer], raw: Path,
                    cue_picks: dict[str, list[int]], layer_picks: dict[str, list[int]], errors: list[str]) -> None:
    if ident in book.cues:
        takes, folder, loop, out = book.cues[ident].takes, raw / "sfx" / ident, book.cues[ident].loop, cue_picks
    elif ident in layers:
        takes, folder, loop, out = layers[ident].takes, raw / "music" / ident, True, layer_picks
    else:
        errors.append(f"{ident}: no such cue or music layer")
        return
    if not isinstance(value, list):
        errors.append(f"{ident}: picks must be a list of take numbers")
        return
    if loop and len(value) > 1:
        errors.append(f"{ident}: a loop keeps one take")
        return
    seen: list[int] = []
    for n in value:
        problem = _take_error(ident, n, takes, folder, seen)
        if problem:
            errors.append(problem)
            return
        seen.append(n)
    out[ident] = seen


def _check_line_pick(ident: str, value: object, files: dict[str, cuebook.VoiceFile], raw: Path,
                     line_picks: dict[str, dict[str, int]], unit_of: dict[str, str], errors: list[str]) -> None:
    unit = next((u for u, f in files.items() if ident in f.lines), None)
    if unit is None:
        errors.append(f"{ident}: no such line")
        return
    allowed = {v for u, f in files.items() if u != cuebook.CLAN for v in f.voices} if unit == cuebook.CLAN else set(files[unit].voices)
    if not isinstance(value, dict) or not value:
        errors.append(f"{ident}: picks must be a non-empty object of voice: take")
        return
    chosen: dict[str, int] = {}
    for voice, take in value.items():
        try:
            voice_id = cuebook.check_id(voice, f"{ident} voice")
        except CueError as err:
            errors.append(str(err))
            continue
        if voice_id not in allowed:
            errors.append(f"{ident}: {voice_id} isn't a voice of {unit}")
            continue
        problem = _take_error(f"{ident} ({voice_id})", take, cuebook.MAX_TAKE, raw / "voices" / voice_id / ident, [])
        if problem:
            errors.append(problem)
        else:
            chosen[voice_id] = take
    if len(chosen) == len(value):
        line_picks[ident] = {**files[unit].lines[ident].picks, **chosen}  # a voice not named keeps its pick
        unit_of[ident] = unit


def _picks_text(cues_path: Path, layers_path: Path, voices_dir: Path, cue_picks: dict[str, list[int]],
                layer_picks: dict[str, list[int]], line_picks: dict[str, dict[str, int]], unit_of: dict[str, str],
                files: dict[str, cuebook.VoiceFile]) -> dict[Path, str]:
    """The new text of every file that changes, each checked to still parse with the picks it should have."""
    writes: dict[Path, str] = {}
    if cue_picks:
        writes[cues_path] = _checked(cues_path, apply_cue_picks(_read(cues_path), cue_picks), "cue", {k: v for k, v in cue_picks.items()})
    if layer_picks:
        writes[layers_path] = _checked(layers_path, apply_cue_picks(_read(layers_path), layer_picks, table="layer"), "layer", layer_picks)
    for unit in sorted(set(unit_of.values())):
        mine = {line: p for line, p in line_picks.items() if unit_of[line] == unit}
        target = voices_dir / f"{unit}.toml"
        writes[target] = _checked(target, apply_line_picks(_read(target), mine), "line", mine)
    return writes


def _read(path: Path) -> str:
    return path.read_bytes().decode("utf-8")


def _checked(path: Path, text: str, table: str, expected: dict[str, object]) -> str:
    try:
        parsed = tomllib.loads(text)[table]
    except (tomllib.TOMLDecodeError, KeyError):
        raise PicksError(f"{path.name} would no longer parse") from None
    for ident, want in expected.items():
        got = parsed[ident]["picks"]
        if got != (list(want) if isinstance(want, list) else want):  # type: ignore[call-overload]
            raise PicksError(f"{path.name}: the picks for {ident} didn't come out as asked")
    return text


def _design_picks(design: object, batch: object, files: dict[str, cuebook.VoiceFile], raw: Path) -> int:
    """A design file changes nothing: it prints the generate.py commands that save each chosen voice."""
    errors: list[str] = []
    unit = batch[len("design-"):] if isinstance(batch, str) and batch.startswith("design-") else ""
    if not unit or unit not in files or unit == cuebook.CLAN:
        errors.append("the batch must be design-<unit> for a unit with voices")
    commands: list[str] = []
    if isinstance(design, dict) and not errors:
        for voice, n in design.items():
            try:
                voice_id = cuebook.check_id(voice, "design voice")
            except CueError as err:
                errors.append(str(err))
                continue
            if voice_id not in files[unit].voices:
                errors.append(f"{voice_id} isn't a voice of {unit}")
            elif isinstance(n, bool) or not isinstance(n, int) or not 1 <= n <= cuebook.MAX_DESIGN_PICK or find_raw(raw / "design" / unit / voice_id, n) is None:
                errors.append(f"{voice_id}: preview {n if isinstance(n, int) else 'that'} has no downloaded file")
            else:
                commands.append(f"python3 scripts/audio/generate.py voices save {unit} --voice {voice_id} --pick {n}")
    if errors:
        cuebook.emit("process.py picks: nothing to run:\n  " + "\n  ".join(errors), file=sys.stderr)
        return 1
    cuebook.emit("Nothing was written. To save these voices, run in Terminal.app:")
    for command in commands:
        cuebook.emit(f"  {command}")
    return 0
