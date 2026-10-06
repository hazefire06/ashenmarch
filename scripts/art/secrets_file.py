"""Reads one API key from ~/.config/ashenmarch/secrets.env.

The file lives outside every repo and must be private, like ~/.ssh: the
folder 700 and the file 600. A looser mode, a missing file, or a missing or
empty key stops the caller. There is no fallback, on purpose. Messages name
the file and the key, never the value.
"""
from __future__ import annotations

import os
import stat
from pathlib import Path

DEFAULT_PATH: Path = Path.home() / ".config" / "ashenmarch" / "secrets.env"


class SecretsError(Exception):
    """The secrets file is missing, too open, or lacks the key."""


def load_secret(name: str, path: Path = DEFAULT_PATH) -> str:
    if not path.is_file():
        raise SecretsError(f"{path} does not exist (see docs/specs/2026-10-01-art-audio-design.md §4)")
    _require_private(path.parent, 0o700)
    _require_private(path, 0o600)
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key.strip() != name:
            continue
        value = value.strip().strip('"').strip("'")
        if not value:
            raise SecretsError(f"{name} is empty in {path}")
        return value
    raise SecretsError(f"{name} is not set in {path}")


def _require_private(path: Path, allowed: int) -> None:
    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode & ~allowed:
        raise SecretsError(f"{path} is mode {mode:o}; make it private: chmod {allowed:o} {path}")
