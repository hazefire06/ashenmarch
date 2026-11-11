"""A purchase ledger outside the repo: one JSON line per file or voice generate.py has paid for, on this Mac.

audio-src/manifest.json and audio-src/raw/ are committed, so a PR can forge a DONE record with a matching hash for a planted file. The
ledger is not in the repo (~/.local/share/ashenmarch/purchases.jsonl), so process.py uses a raw file only if a line here matches its
label, hash and size, and generate.py uses a voice id only if a line here saved it. Lines are {"kind", "label", "sha256", "bytes"}, or
{"kind": "voice", "label", "voice_id"}. A line that doesn't parse is an error, never skipped.
"""
from __future__ import annotations

import json
import os
from collections.abc import Callable
from pathlib import Path
from typing import Any

from cuebook import CueError, printable

LEDGER: Path = Path.home() / ".local" / "share" / "ashenmarch" / "purchases.jsonl"  # tests patch this; it is read at call time


class LedgerError(CueError):
    """The ledger is missing, a link, or can't be read."""


def _folder(create: bool) -> None:
    folder = LEDGER.parent
    if folder.is_symlink():
        raise LedgerError(f"{printable(str(folder))} is a symlink; replace it with a real folder (or remove it)")
    if create:
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        if folder.is_symlink() or not folder.is_dir():  # also catches a swap between the first look and the mkdir
            raise LedgerError(f"{printable(str(folder))} isn't a real folder")


def prepare() -> None:
    """Before a purchase: the folder exists at 0700 and neither it nor the ledger is a link, so a failed append can't lose a paid take."""
    _folder(True)
    if LEDGER.is_symlink():
        raise LedgerError(f"{printable(str(LEDGER))} is a symlink; replace it with a real file (or remove it)")


def append(entry: dict[str, Any]) -> None:
    prepare()
    data = (json.dumps(entry, sort_keys=True) + "\n").encode("utf-8")
    try:
        fd = os.open(LEDGER, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError as err:
        raise LedgerError(f"{printable(str(LEDGER))} can't be opened for writing ({err.strerror})") from None
    try:
        os.write(fd, data)  # one write: a line is never split
    finally:
        os.close(fd)


def load(missing_ok: bool = False) -> list[dict[str, Any]]:
    """Every line. A missing ledger is no lines if missing_ok, else an error; so is anything that can't be read or parsed."""
    _folder(False)
    try:
        fd = os.open(LEDGER, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        if missing_ok:
            return []
        raise LedgerError(f"no purchase ledger at {printable(str(LEDGER))}; generate.py writes it when it buys, on this Mac, "
                          "so assets can only be built from takes bought here") from None
    except OSError as err:
        raise LedgerError(f"{printable(str(LEDGER))} can't be opened ({err.strerror}); is it a symlink?") from None
    with os.fdopen(fd, "rb") as handle:
        raw = handle.read()
    entries: list[dict[str, Any]] = []
    for number, line in enumerate(raw.splitlines(), 1):
        if not line.strip():
            continue
        try:
            entry = json.loads(line.decode("utf-8"))
        except (ValueError, RecursionError):
            entry = None
        if not isinstance(entry, dict) or not isinstance(entry.get("kind"), str) or not isinstance(entry.get("label"), str):
            raise LedgerError(f"line {number} of the purchase ledger {printable(str(LEDGER))} can't be read; fix or remove that line by hand")
        entries.append(entry)
    return entries


def lazy() -> Callable[[], list[dict[str, Any]]]:
    """load(), run on first use and kept: a build with nothing to verify never needs the ledger."""
    cache: list[list[dict[str, Any]]] = []

    def entries() -> list[dict[str, Any]]:
        if not cache:
            cache.append(load())
        return cache[0]

    return entries


def has_file(entries: list[dict[str, Any]], kind: str, label: str, sha256: str, size: int) -> bool:
    return any(e.get("kind") == kind and e.get("label") == label and e.get("sha256") == sha256 and e.get("bytes") == size for e in entries)


def has_voice(entries: list[dict[str, Any]], voice: str, voice_id: str) -> bool:
    return any(e.get("kind") == "voice" and e.get("label") == f"voice/{voice}" and e.get("voice_id") == voice_id for e in entries)
