"""Tests for manifest.Manifest: allowlisted, URL-free task records."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from manifest import Manifest, clean


class CleanTest(unittest.TestCase):
    def test_keeps_allowlisted_fields_only(self) -> None:
        kept = clean({"task_id": "t1", "kind": "preview", "label": "cand-1", "secret": "x", "thumbnail_url": "y"})
        self.assertEqual(kept, {"task_id": "t1", "kind": "preview", "label": "cand-1"})

    def test_drops_anything_holding_a_url_or_a_nested_object(self) -> None:
        kept = clean({
            "task_id": "t1",
            "prompt": "see https://example.com/x?Signature=abc",
            "files": ["candidates/cand-1.glb", "https://assets.meshy.ai/a.glb?Expires=1"],
            "label": {"raw": "api data"},
        })
        self.assertEqual(kept, {"task_id": "t1"})


class ManifestTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name) / "manifest.json"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_upsert_replaces_the_same_kind_and_label(self) -> None:
        m = Manifest(self.path)
        m.upsert({"kind": "preview", "label": "cand-1", "task_id": "a", "status": "PENDING"})
        m.upsert({"kind": "preview", "label": "cand-1", "task_id": "a", "status": "SUCCEEDED", "credits": 5})
        m.upsert({"kind": "preview", "label": "cand-2", "task_id": "b", "status": "SUCCEEDED", "credits": 20})
        self.assertEqual(len(m.tasks), 2)
        self.assertEqual(m.find("preview", "cand-1")["status"], "SUCCEEDED")
        self.assertIsNone(m.find("rig", "cand-1"))
        self.assertEqual(m.credits_spent(), 25)

    def test_save_and_load_round_trip_deterministically(self) -> None:
        m = Manifest(self.path)
        m.upsert({"kind": "preview", "label": "cand-1", "task_id": "a", "credits": 5})
        m.save()
        first = self.path.read_text(encoding="utf-8")
        Manifest.load(self.path).save()
        self.assertEqual(self.path.read_text(encoding="utf-8"), first)
        self.assertTrue(first.endswith("\n"))

    def test_load_cleans_a_hand_edited_file(self) -> None:
        self.path.write_text(json.dumps({"tasks": [{"kind": "rig", "label": "x", "url": "https://a"}]}))
        self.assertEqual(Manifest.load(self.path).tasks, [{"kind": "rig", "label": "x"}])

    def test_loading_a_missing_file_gives_an_empty_manifest(self) -> None:
        self.assertEqual(Manifest.load(self.path).tasks, [])


if __name__ == "__main__":
    unittest.main()
