"""Tests for meshy.py's flows with a fake client: resume, budget, layout, no URLs."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from typing import Any

import meshy
from manifest import Manifest
from meshy_client import MeshyError, TaskFailed
from unit_spec import load_spec, load_style

ART_SRC = Path(__file__).resolve().parent.parent.parent / "art-src"


class FakeClient:
    """Stands in for MeshyClient. Every finished task carries signed-looking URLs."""

    def __init__(self, fail_waits: int = 0, lost_waits: dict[str, str] | None = None) -> None:
        self.created: list[tuple[str, Any]] = []
        self.fail_waits = fail_waits
        self.lost_waits = lost_waits or {}
        self._n = 0

    def _new(self, what: str, arg: Any) -> str:
        self._n += 1
        self.created.append((what, arg))
        return f"{what}-{self._n}"

    def create_preview(self, prompt: str, ai_model: str, polycount: int) -> str:
        return self._new("preview", ai_model)

    def create_refine(self, preview_task_id: str) -> str:
        return self._new("refine", preview_task_id)

    def create_rig(self, input_task_id: str, height_meters: float) -> str:
        return self._new("rig", (input_task_id, height_meters))

    def create_animation(self, rig_task_id: str, action_ids: list[int]) -> str:
        return self._new("animate", (rig_task_id, tuple(action_ids)))

    def wait(self, kind: str, task_id: str) -> dict[str, Any]:
        if task_id in self.lost_waits:
            raise MeshyError(self.lost_waits[task_id])
        if self.fail_waits:
            self.fail_waits -= 1
            raise TaskFailed(f"{kind} task {task_id} FAILED: test")
        url = f"https://assets.meshy.ai/{task_id}/out.glb?Expires=1&Signature=SIG"
        return {
            "id": task_id, "status": "SUCCEEDED", "consumed_credits": 1, "finished_at": 1,
            "model_urls": {"glb": url},
            "result": {
                "rigged_character_glb_url": url, "animation_glb_url": url,
                "basic_animations": {"walking_glb_url": url, "running_glb_url": url},
            },
        }

    def download(self, url: str, dest: Path) -> None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"glb")


class FlowTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.unit_dir = Path(self._tmp.name) / "shieldman"
        self.unit_dir.mkdir()
        self.spec = load_spec(ART_SRC / "units" / "shieldman" / "spec.toml")
        self.style = load_style(ART_SRC / "style.toml")
        self.manifest = Manifest(self.unit_dir / "manifest.json")
        self.quiet: list[str] = []

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def candidates(self, client: FakeClient, max_credits: int = 100) -> list[Path]:
        return meshy.run_candidates(self.spec, self.style, self.manifest, client, self.unit_dir, max_credits, say=self.quiet.append)

    def test_costs_match_the_spec(self) -> None:
        self.assertEqual(meshy.candidates_cost(self.spec, self.manifest), 2 * 5 + 2 * 20)
        self.assertEqual(meshy.build_cost(self.spec, self.manifest, 3), 10 + 5 + 4 * 3)

    def test_candidates_are_bought_once_and_resumed(self) -> None:
        client = FakeClient()
        paths = self.candidates(client)
        self.assertEqual([p.name for p in paths], ["cand-1.glb", "cand-2.glb", "cand-3.glb", "cand-4.glb"])
        self.assertEqual([a for _, a in client.created], ["meshy-6-lite", "meshy-6-lite", "meshy-7.1", "meshy-7.1"])
        again = FakeClient()
        self.candidates(again)
        self.assertEqual(again.created, [])
        self.assertEqual(meshy.candidates_cost(self.spec, self.manifest), 0)

    def test_an_over_budget_run_buys_nothing(self) -> None:
        client = FakeClient()
        with self.assertRaisesRegex(meshy.BudgetError, "need 50 credits"):
            self.candidates(client, max_credits=49)
        self.assertEqual(client.created, [])

    def test_a_failed_task_is_recorded_and_bought_again_next_run(self) -> None:
        with self.assertRaises(TaskFailed):
            self.candidates(FakeClient(fail_waits=1))
        self.assertEqual(Manifest.load(self.manifest.path).find("preview", "cand-1")["status"], "FAILED")
        retry = FakeClient()
        self.candidates(retry)
        self.assertEqual(retry.created[0], ("preview", "meshy-6-lite"))

    def test_a_lost_wait_leaves_the_task_pending_and_reruns_wait_for_it(self) -> None:
        with self.assertRaises(MeshyError):
            self.candidates(FakeClient(lost_waits={"preview-1": "text-to-3d task preview-1 still IN_PROGRESS after 1800 s; rerun to keep waiting"}))
        record = Manifest.load(self.manifest.path).find("preview", "cand-1")
        self.assertEqual(record["status"], "PENDING")
        self.assertEqual(record["task_id"], "preview-1")
        again = FakeClient()
        paths = self.candidates(again)
        self.assertEqual([p.name for p in paths], ["cand-1.glb", "cand-2.glb", "cand-3.glb", "cand-4.glb"])
        self.assertEqual([a for _, a in again.created], ["meshy-6-lite", "meshy-7.1", "meshy-7.1"])

    def test_a_lost_wait_on_rig_leaves_it_pending_for_rerun(self) -> None:
        self.candidates(FakeClient())
        with self.assertRaises(MeshyError):
            meshy.run_build(self.spec, self.manifest, FakeClient(lost_waits={"refine-1": "text-to-3d task refine-1 still IN_PROGRESS after 1800 s; rerun to keep waiting"}), self.unit_dir, 3, 100, say=self.quiet.append)
        record = Manifest.load(self.manifest.path).find("refine", "cand-3")
        self.assertEqual(record["status"], "PENDING")
        self.assertEqual(record["task_id"], "refine-1")
        again = FakeClient()
        meshy.run_build(self.spec, self.manifest, again, self.unit_dir, 3, 17, say=self.quiet.append)
        self.assertEqual([w for w, _ in again.created], ["rig", "animate"])

    def test_build_needs_a_finished_candidate(self) -> None:
        with self.assertRaisesRegex(meshy.BuildError, "cand-3"):
            meshy.run_build(self.spec, self.manifest, FakeClient(), self.unit_dir, 3, 100, say=self.quiet.append)

    def test_build_downloads_the_rig_and_actions(self) -> None:
        self.candidates(FakeClient())
        client = FakeClient()
        meshy.run_build(self.spec, self.manifest, client, self.unit_dir, 3, 100, say=self.quiet.append)
        self.assertEqual([w for w, _ in client.created], ["refine", "rig", "animate"])
        self.assertEqual(client.created[2][1][1], (89, 97, 189, 219))
        for rel in ("model/textured.glb", "model/rigged.glb", "anims/rig_walk.glb", "anims/rig_run.glb", "anims/actions.glb"):
            self.assertTrue((self.unit_dir / rel).exists(), rel)
        again = FakeClient()
        meshy.run_build(self.spec, self.manifest, again, self.unit_dir, 3, 0, say=self.quiet.append)
        self.assertEqual(again.created, [])

    def test_the_manifest_never_holds_a_url(self) -> None:
        self.candidates(FakeClient())
        meshy.run_build(self.spec, self.manifest, FakeClient(), self.unit_dir, 1, 100, say=self.quiet.append)
        text = self.manifest.path.read_text(encoding="utf-8")
        self.assertNotIn("://", text)
        self.assertNotIn("Signature", text)

    def test_plan_text_totals(self) -> None:
        text = meshy.plan_text(self.spec, self.style, self.manifest)
        self.assertIn("50 credits", text)
        self.assertIn("27 credits", text)


if __name__ == "__main__":
    unittest.main()
