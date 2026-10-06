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

    def test_save_never_writes_a_url_however_tasks_got_in(self) -> None:
        m = Manifest(self.path, [{"kind": "rig", "label": "x", "url": "https://a/b?Signature=s"}])
        m.tasks.append({"kind": "preview", "label": "y", "url": "https://example.com?Expires=123"})
        m.save()
        written = self.path.read_text(encoding="utf-8")
        self.assertNotIn("://", written)
        self.assertNotIn("Signature", written)
        self.assertNotIn("Expires", written)

    def test_a_symlinked_part_file_is_refused_and_its_target_is_left_alone(self) -> None:
        # The repo is public: a PR could plant manifest.json.part -> some file of Tim's.
        target = Path(self._tmp.name) / "precious.txt"
        target.write_text("keep me")
        self.path.with_name("manifest.json.part").symlink_to(target)
        m = Manifest(self.path)
        m.upsert({"kind": "preview", "label": "cand-1", "status": "CREATING"})
        with self.assertRaises(OSError):
            m.save()
        self.assertEqual(target.read_text(), "keep me")
        self.assertFalse(self.path.exists())

    def test_a_stale_regular_part_file_is_just_overwritten(self) -> None:
        self.path.with_name("manifest.json.part").write_text("half a write")
        m = Manifest(self.path)
        m.upsert({"kind": "preview", "label": "cand-1", "task_id": "a"})
        m.save()
        self.assertEqual(Manifest.load(self.path).find("preview", "cand-1")["task_id"], "a")
        self.assertFalse(self.path.with_name("manifest.json.part").exists())


if __name__ == "__main__":
    unittest.main()
