"""A unit's record of paid generation tasks, committed beside its source art.

Only allowlisted fields are kept. Any value holding a URL, and any nested
object, is dropped, so signed download links (which carry access tokens) and
raw API responses can never reach the public repo through this file. Reruns
read it to resume instead of buying a task twice.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

ALLOWED_FIELDS: frozenset[str] = frozenset({
    "task_id", "kind", "label", "ai_model", "prompt", "action_ids",
    "status", "credits", "created_at", "finished_at", "files",
})


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
        self.tasks: list[dict[str, Any]] = tasks if tasks is not None else []

    @classmethod
    def load(cls, path: Path) -> "Manifest":
        if not path.exists():
            return cls(path)
        data = json.loads(path.read_text(encoding="utf-8"))
        return cls(path, [clean(t) for t in data.get("tasks", [])])

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
        return sum(int(t.get("credits", 0)) for t in self.tasks)

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        text = json.dumps({"tasks": self.tasks}, indent=2, sort_keys=True) + "\n"
        part = self.path.with_name(self.path.name + ".part")
        part.write_text(text, encoding="utf-8")
        part.replace(self.path)
