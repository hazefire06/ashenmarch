"""A unit's record of paid generation tasks, committed beside its source art.

Only allowlisted fields are kept. Any value holding a URL, and any nested
object, is dropped, so signed download links (which carry access tokens) and
raw API responses can never reach the public repo through this file. Reruns
read it to resume instead of buying a task twice.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

ALLOWED_FIELDS: frozenset[str] = frozenset({
    "task_id", "kind", "label", "ai_model", "prompt", "action_ids",
    "status", "credits", "created_at", "finished_at", "files",
})


class ManifestError(Exception):
    """manifest.json can't be read as a manifest. The message names the file and never holds any of its content."""


def credits_of(value: Any) -> int:
    """A credit count from a manifest or a Meshy reply: a plain non-negative integer, else 0. A garbled value must not
    crash a total or strand a finished task as PENDING."""
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


def clean(record: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in record.items() if k in ALLOWED_FIELDS and not _unsafe(v)}


def _unsafe(value: Any) -> bool:
    if isinstance(value, str):
        return "://" in value
    if isinstance(value, (list, tuple)):
        return any(_unsafe(v) for v in value)
    return isinstance(value, dict)


class Manifest:
    def __init__(self, path: Path, tasks: list[dict[str, Any]] | None = None) -> None:
        self.path = path
        self.tasks: list[dict[str, Any]] = [clean(t) for t in tasks] if tasks is not None else []

    @classmethod
    def load(cls, path: Path) -> "Manifest":
        if not path.exists():
            return cls(path)
        try:
            data = json.loads(path.read_text(encoding="utf-8"))  # JSONDecodeError and UnicodeDecodeError are both ValueErrors
        except (ValueError, RecursionError):
            data = None
        tasks = data.get("tasks", []) if isinstance(data, dict) else None
        if not isinstance(tasks, list) or not all(isinstance(t, dict) for t in tasks):
            # Not echoed (it is a committed file, so it could hold anything), and not "delete it": that would forget what was bought.
            raise ManifestError(f"{path} can't be read as a manifest (JSON: an object with a list of task records). "
                                "Restore it from git; deleting it would make the next run buy everything again.")
        return cls(path, [clean(t) for t in tasks])

    def find(self, kind: str, label: str) -> dict[str, Any] | None:
        return next((t for t in self.tasks if t.get("kind") == kind and t.get("label") == label), None)

    def upsert(self, record: dict[str, Any]) -> dict[str, Any]:
        kept = clean(record)
        for i, task in enumerate(self.tasks):
            if task.get("kind") == kept.get("kind") and task.get("label") == kept.get("label"):
                self.tasks[i] = kept
                return kept
        self.tasks.append(kept)
        return kept

    def credits_spent(self) -> int:
        return sum(credits_of(t.get("credits", 0)) for t in self.tasks)

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        text = json.dumps({"tasks": [clean(t) for t in self.tasks]}, indent=2, sort_keys=True) + "\n"
        part = self.path.with_name(self.path.name + ".part")
        # O_NOFOLLOW: the repo is public, so a PR could plant `manifest.json.part` as a symlink to a file of Tim's.
        fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(text)
        part.replace(self.path)
