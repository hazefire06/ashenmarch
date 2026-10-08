"""Tests for manifest.Manifest: allowlisted, URL-free task records."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from manifest import Manifest, ManifestError, clean, credits_of


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

    def test_credits_of_counts_only_a_plain_non_negative_integer(self) -> None:
        for good in (0, 5, 20, 10**6):
            self.assertEqual(credits_of(good), good)
        for bad in ("5", "abc", None, [], {}, True, False, 2.5, 5.0, -3, float("nan")):
            with self.subTest(value=bad):
                self.assertEqual(credits_of(bad), 0)

    def test_a_garbled_credits_value_does_not_crash_the_total(self) -> None:
        m = Manifest(self.path, [{"kind": "preview", "label": "a", "credits": "abc"}, {"kind": "preview", "label": "b", "credits": [5]},
                                 {"kind": "preview", "label": "c", "credits": 7}, {"kind": "preview", "label": "d", "credits": -50}])
        self.assertEqual(m.credits_spent(), 7)


class CorruptManifestTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name) / "manifest.json"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_a_manifest_that_is_not_usable_raises_manifest_error_without_its_content(self) -> None:
        for data in (b'{"tasks": [ SECRETLOOKING', b"\xff\xfe\x00", b"[]", b'"x"', b"null", b'{"tasks": 3}', b'{"tasks": [1]}',
                     b'{"tasks": ["SECRETLOOKING"]}', b"[" * 200000):
            with self.subTest(data=data[:20]):
                self.path.write_bytes(data)
                with self.assertRaises(ManifestError) as caught:
                    Manifest.load(self.path)
                for leaked in ("SECRETLOOKING", "0xff", "codec", "Expecting"):
                    self.assertNotIn(leaked, str(caught.exception))
                self.assertIn(str(self.path), str(caught.exception))
                self.assertIn("git", str(caught.exception))  # deleting it would forget what was bought
                self.assertIsNone(caught.exception.__cause__)

    def test_a_good_manifest_and_an_empty_object_still_load(self) -> None:
        self.path.write_text('{"tasks": [{"kind": "rig", "label": "x"}]}')
        self.assertEqual(Manifest.load(self.path).tasks, [{"kind": "rig", "label": "x"}])
        self.path.write_text("{}")
        self.assertEqual(Manifest.load(self.path).tasks, [])


if __name__ == "__main__":
    unittest.main()
