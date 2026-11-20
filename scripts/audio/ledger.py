"""A purchase ledger outside the repo: one JSON line per file or voice generate.py has paid for, on this Mac.

audio-src/manifest.json and audio-src/raw/ are committed, so a PR can forge a DONE record with a matching hash for a planted file. The
ledger is not in the repo (~/.local/share/ashenmarch/purchases.jsonl), so process.py uses a raw file only if a line here matches its
label, hash and size, and generate.py uses a voice id only if a line here saved it. Lines are {"kind", "label", "sha256", "bytes"}, or
{"kind": "voice", "label", "voice_id"}; a design line also carries "generated_voice_id". A line that doesn't parse is an error, never skipped.
"""
from __future__ import annotations

import contextlib
import json
import os
import stat
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
        try:
            fd = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)  # not a link, and the one we then chmod
        except OSError:
            raise LedgerError(f"{printable(str(folder))} isn't a real folder") from None
        try:
            os.fchmod(fd, 0o700)
        except OSError as err:
            raise LedgerError(f"{printable(str(folder))} can't be made private ({err.strerror})") from None
        finally:
            os.close(fd)


_open: tuple[Path, int, tuple[int, int]] | None = None  # the ledger path, its append fd, and the file's (device, inode)


def close() -> None:
    """Closes the append fd (the end of a run)."""
    global _open
    if _open is not None:
        fd = _open[1]
        _open = None  # first: a failing close must not leave a dead fd cached
        with contextlib.suppress(OSError):  # as an ExitStack callback an error here would replace the error already on its way out
            os.close(fd)


def _check(fd: int, name: str) -> tuple[int, int]:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        raise LedgerError(f"{name} isn't a regular file (a folder or a pipe?); move it away")
    if info.st_uid != os.getuid():
        raise LedgerError(f"{name} isn't owned by you; replace it with your own file")
    if info.st_nlink != 1:
        raise LedgerError(f"{name} has other hard links; replace it with a plain file")
    if info.st_mode & 0o777 != 0o600:  # both owner bits: a write-only file would take appends and then fail to load
        raise LedgerError(f"{name} must be mode 600 (chmod 600 it); it is {info.st_mode & 0o777:o}")
    return info.st_dev, info.st_ino


def prepare() -> None:
    """Before a purchase, and again before every append: the folder exists at 0700 and neither it nor the ledger is a link, and the
    ledger is open for appending (kept open for the run) and is a regular file of ours, mode 600, with no other links. So a ledger
    that cannot be appended to is found before the paid call, not after it."""
    global _open
    _folder(True)
    name = f"the purchase ledger {printable(str(LEDGER))}"
    if LEDGER.is_symlink():
        raise LedgerError(f"{name} is a symlink; replace it with a real file (or remove it)")
    if _open is not None:
        try:
            same = _open[0] == LEDGER and os.lstat(LEDGER).st_ino == _open[2][1] and os.fstat(_open[1]).st_nlink == 1
        except OSError:
            same = False
        if same:
            _check(_open[1], name)
            return
        close()  # the file was replaced or moved under us
    try:
        # O_NONBLOCK: opening a FIFO for writing with no reader would hang; fstat then refuses it.
        fd = os.open(LEDGER, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    except OSError as err:
        raise LedgerError(f"{name} can't be opened for appending ({err.strerror})") from None
    try:
        ids = _check(fd, name)
    except BaseException:
        os.close(fd)
        raise
    _open = (LEDGER, fd, ids)


def append(entry: dict[str, Any]) -> None:
    """One line, written whole to the open fd and fsynced. A short write is an error (the ledger may then end in a partial line)."""
    prepare()
    assert _open is not None
    data = (json.dumps(entry, sort_keys=True) + "\n").encode("utf-8")
    try:
        written = os.write(_open[1], data)  # one write: a line is never split
        if written != len(data):
            raise LedgerError(f"only {written} of {len(data)} bytes reached {printable(str(LEDGER))}; delete its last (partial) line by hand")
        os.fsync(_open[1])
    except OSError as err:
        raise LedgerError(f"{printable(str(LEDGER))} can't be written ({err.strerror})") from None


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


def has_design(entries: list[dict[str, Any]], label: str, generated_voice_id: str) -> bool:
    return any(e.get("kind") == "design" and e.get("label") == label and e.get("generated_voice_id") == generated_voice_id for e in entries)


def has_voice(entries: list[dict[str, Any]], voice: str, voice_id: str) -> bool:
    return any(e.get("kind") == "voice" and e.get("label") == f"voice/{voice}" and e.get("voice_id") == voice_id for e in entries)
