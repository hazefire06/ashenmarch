"""Tests for meshy.py's flows with a fake client: resume, budget, layout, no URLs."""
from __future__ import annotations

import contextlib
import io
import shutil
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

import meshy
import meshy_client
from manifest import Manifest
from meshy_client import MeshyError, TaskFailed
from unit_spec import load_prop_spec, load_spec, load_style

ART_SRC = Path(__file__).resolve().parent.parent.parent / "art-src"


class FakeClient:
    """Stands in for MeshyClient. Every finished task carries signed-looking URLs."""

    def __init__(self, fail_waits: int = 0, lost_waits: dict[str, str] | None = None,
                 create_error: BaseException | None = None, finished_at: Any = 1) -> None:
        self.created: list[tuple[str, Any]] = []
        self.pose_modes: list[str | None] = []  # one per preview, as asked for
        self.prompts: list[str] = []
        self.fail_waits = fail_waits
        self.lost_waits = lost_waits or {}
        self.create_error = create_error
        self.finished_at = finished_at
        self._n = 0

    def _new(self, what: str, arg: Any) -> str:
        if self.create_error is not None:
            raise self.create_error
        self._n += 1
        self.created.append((what, arg))
        return f"{what}-{self._n}"

    def create_preview(self, prompt: str, ai_model: str, polycount: int, pose_mode: str | None) -> str:
        # No default on pose_mode (the real client has one): the flow must pass it, or this fake fails.
        task_id = self._new("preview", ai_model)
        self.pose_modes.append(pose_mode)
        self.prompts.append(prompt)
        return task_id

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
            "id": task_id, "status": "SUCCEEDED", "consumed_credits": 1, "finished_at": self.finished_at,
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

    def test_unit_previews_are_still_requested_in_an_a_pose(self) -> None:
        client = FakeClient()
        self.candidates(client)
        self.assertEqual(client.pose_modes, ["a-pose"] * 4)
        self.assertTrue(all(self.style.suffix in prompt for prompt in client.prompts))

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

    def test_a_non_integer_finish_time_is_not_stored(self) -> None:
        for value in ("not-a-number", 1.5, None, True, ["x"]):
            with self.subTest(finished_at=value):
                self.manifest = Manifest(self.unit_dir / "manifest.json")
                self.candidates(FakeClient(finished_at=value))
                self.assertNotIn("finished_at", Manifest.load(self.manifest.path).find("preview", "cand-1"))
        self.manifest = Manifest(self.unit_dir / "manifest.json")
        self.candidates(FakeClient(finished_at=1_760_000_000))
        self.assertEqual(Manifest.load(self.manifest.path).find("preview", "cand-1")["finished_at"], 1_760_000_000)

    def test_a_canceled_task_stays_pending_and_is_not_bought_again(self) -> None:
        canceled = {"preview-1": "text-to-3d task preview-1 CANCELED: nobody knows; check this task on meshy.ai before deciding whether to rebuy"}
        with self.assertRaises(MeshyError) as caught:
            self.candidates(FakeClient(lost_waits=canceled))
        self.assertNotIsInstance(caught.exception, TaskFailed)
        record = Manifest.load(self.manifest.path).find("preview", "cand-1")
        self.assertEqual((record["status"], record["task_id"]), ("PENDING", "preview-1"))

    def test_an_interrupted_create_stays_creating_and_blocks_the_next_run(self) -> None:
        with self.assertRaises(KeyboardInterrupt):
            self.candidates(FakeClient(create_error=KeyboardInterrupt()))
        record = Manifest.load(self.manifest.path).find("preview", "cand-1")
        self.assertEqual(record["status"], "CREATING")
        self.assertNotIn("task_id", record)
        before = self.manifest.path.read_text(encoding="utf-8")

        self.manifest = Manifest.load(self.manifest.path)
        again = FakeClient()
        with self.assertRaises(meshy.InterruptedCreate) as caught:
            self.candidates(again, max_credits=0)  # the guard comes before the budget check
        self.assertEqual(
            str(caught.exception),
            "a previous run stopped while creating preview cand-1; it may have been created and charged. "
            "Check your API tasks on meshy.ai. If it exists, note its id; either way, delete that entry "
            "from manifest.json before rerunning.")
        self.assertEqual(again.created, [])
        self.assertEqual(self.manifest.path.read_text(encoding="utf-8"), before)

    def test_a_create_that_may_have_made_a_task_stays_creating(self) -> None:
        lost = MeshyError("Meshy POST /openapi/v2/text-to-3d: no reply" + meshy_client.POST_WARNING, may_have_created=True)
        with self.assertRaises(MeshyError):
            self.candidates(FakeClient(create_error=lost))
        self.assertEqual(Manifest.load(self.manifest.path).find("preview", "cand-1")["status"], "CREATING")
        with self.assertRaises(meshy.InterruptedCreate):
            self.candidates(FakeClient())

    def test_an_unexpected_error_in_create_stays_creating(self) -> None:
        with self.assertRaises(RuntimeError):
            self.candidates(FakeClient(create_error=RuntimeError("boom")))
        self.assertEqual(Manifest.load(self.manifest.path).find("preview", "cand-1")["status"], "CREATING")

    def test_a_definite_rejection_is_marked_failed_and_bought_again(self) -> None:
        with self.assertRaisesRegex(MeshyError, "HTTP 402"):
            self.candidates(FakeClient(create_error=MeshyError("Meshy POST /openapi/v2/text-to-3d failed: HTTP 402 Insufficient credits")))
        record = Manifest.load(self.manifest.path).find("preview", "cand-1")
        self.assertEqual((record["status"], record["credits"]), ("FAILED", 0))
        self.assertNotIn("task_id", record)
        self.manifest = Manifest.load(self.manifest.path)
        retry = FakeClient()
        self.candidates(retry)
        self.assertEqual(retry.created[0], ("preview", "meshy-6-lite"))
        self.assertEqual(Manifest.load(self.manifest.path).find("preview", "cand-1")["status"], "SUCCEEDED")

    def test_the_certificate_failure_of_2026_10_06_leaves_nothing_to_clean_up(self) -> None:
        # The handshake failed before anything was sent: the task is FAILED (not CREATING) and is simply bought again.
        cert = MeshyError(meshy_client.CERT_FAILURE, may_have_created=False)
        with self.assertRaisesRegex(MeshyError, "Install Certificates"):
            self.candidates(FakeClient(create_error=cert))
        record = Manifest.load(self.manifest.path).find("preview", "cand-1")
        self.assertEqual((record["status"], record["credits"]), ("FAILED", 0))
        self.assertEqual(meshy._interrupted(Manifest.load(self.manifest.path)), [])
        self.manifest = Manifest.load(self.manifest.path)
        retry = FakeClient()
        self.candidates(retry)
        self.assertEqual(retry.created[0], ("preview", "meshy-6-lite"))
        self.assertEqual(Manifest.load(self.manifest.path).find("preview", "cand-1")["status"], "SUCCEEDED")

    def test_a_build_writes_which_candidate_model_holds(self) -> None:
        self.candidates(FakeClient())
        meshy.run_build(self.spec, self.manifest, FakeClient(), self.unit_dir, 3, 100, say=self.quiet.append)
        self.assertEqual((self.unit_dir / "model" / "PICK").read_text(), "cand-3\n")

    def test_building_another_pick_would_mix_two_models_and_buys_nothing(self) -> None:
        self.candidates(FakeClient())
        meshy.run_build(self.spec, self.manifest, FakeClient(), self.unit_dir, 3, 100, say=self.quiet.append)
        again = FakeClient()
        with self.assertRaisesRegex(meshy.BuildError, r"model/ holds cand-3's files; building cand-1 would mix two models\. "
                                    r"Move model/ and anims/ aside \(or delete them\) first\."):
            meshy.run_build(self.spec, self.manifest, again, self.unit_dir, 1, 0, say=self.quiet.append)  # the guard comes before the budget check
        self.assertEqual(again.created, [])
        self.assertEqual((self.unit_dir / "model" / "PICK").read_text(), "cand-3\n")
        self.assertIsNone(self.manifest.find("refine", "cand-1"))

    def test_rebuilding_the_same_pick_is_fine_and_buys_nothing(self) -> None:
        self.candidates(FakeClient())
        meshy.run_build(self.spec, self.manifest, FakeClient(), self.unit_dir, 3, 100, say=self.quiet.append)
        again = FakeClient()
        meshy.run_build(self.spec, self.manifest, again, self.unit_dir, 3, 0, say=self.quiet.append)
        self.assertEqual(again.created, [])

    def test_a_model_folder_with_no_marker_is_adopted_not_refused(self) -> None:
        # The real Shieldman's model/ and anims/ predate the marker.
        self.candidates(FakeClient())
        meshy.run_build(self.spec, self.manifest, FakeClient(), self.unit_dir, 3, 100, say=self.quiet.append)
        (self.unit_dir / "model" / "PICK").unlink()
        again = FakeClient()
        meshy.run_build(self.spec, self.manifest, again, self.unit_dir, 3, 0, say=self.quiet.append)
        self.assertEqual(again.created, [])
        self.assertEqual((self.unit_dir / "model" / "PICK").read_text(), "cand-3\n")

    def test_the_pick_guard_comes_after_the_interrupted_create_guard(self) -> None:
        self.candidates(FakeClient())
        meshy.run_build(self.spec, self.manifest, FakeClient(), self.unit_dir, 3, 100, say=self.quiet.append)
        self.manifest.upsert({"kind": "refine", "label": "cand-1", "status": "CREATING", "created_at": 1})
        with self.assertRaises(meshy.InterruptedCreate):
            meshy.run_build(self.spec, self.manifest, FakeClient(), self.unit_dir, 1, 0, say=self.quiet.append)

    def test_a_failed_refine_leaves_no_marker_so_another_pick_is_still_open(self) -> None:
        self.candidates(FakeClient())
        with self.assertRaises(MeshyError):
            meshy.run_build(self.spec, self.manifest, FakeClient(create_error=MeshyError("HTTP 402")), self.unit_dir, 3, 100, say=self.quiet.append)
        self.assertFalse((self.unit_dir / "model" / "PICK").exists())
        meshy.run_build(self.spec, self.manifest, FakeClient(), self.unit_dir, 1, 100, say=self.quiet.append)
        self.assertEqual((self.unit_dir / "model" / "PICK").read_text(), "cand-1\n")

    def test_a_symlinked_marker_is_not_followed(self) -> None:
        self.candidates(FakeClient())
        (self.unit_dir / "model").mkdir()
        target = self.unit_dir.parent / "precious.txt"
        target.write_text("keep me")
        (self.unit_dir / "model" / "PICK").symlink_to(target)
        with self.assertRaisesRegex(meshy.BuildError, "PICK"):
            meshy.run_build(self.spec, self.manifest, FakeClient(), self.unit_dir, 3, 100, say=self.quiet.append)
        self.assertEqual(target.read_text(), "keep me")

    def elsewhere(self) -> Path:
        outside = self.unit_dir.parent / "elsewhere"
        outside.mkdir()
        return outside

    def test_fetch_refuses_a_candidates_folder_that_is_a_symlink_out_of_the_work_dir(self) -> None:
        outside = self.elsewhere()
        (self.unit_dir / "candidates").symlink_to(outside, target_is_directory=True)
        client = FakeClient()
        record = {"kind": "preview", "label": "cand-1", "task_id": "preview-1", "status": "PENDING"}
        with self.assertRaisesRegex(meshy.BuildError, "candidates") as caught:
            meshy._fetch(self.manifest, client, "text-to-3d", record, self.unit_dir, {"candidates/cand-1.glb": lambda t: t["model_urls"]["glb"]})
        self.assertIn(str(self.unit_dir / "candidates" / "cand-1.glb"), str(caught.exception))
        self.assertEqual(list(outside.iterdir()), [])

    def test_a_refused_fetch_does_not_rebuy_once_the_symlink_is_gone(self) -> None:
        outside = self.elsewhere()
        (self.unit_dir / "candidates").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(meshy.BuildError):
            self.candidates(FakeClient())
        self.assertEqual(list(outside.iterdir()), [])
        (self.unit_dir / "candidates").unlink()
        self.manifest = Manifest.load(self.manifest.path)
        again = FakeClient()
        self.candidates(again)
        self.assertEqual([a for _, a in again.created], ["meshy-6-lite", "meshy-7.1", "meshy-7.1"])  # cand-1 is only waited on
        self.assertTrue((self.unit_dir / "candidates" / "cand-1.glb").exists())

    def test_a_model_folder_that_is_a_symlink_is_refused_before_anything_is_bought(self) -> None:
        self.candidates(FakeClient())
        outside = self.elsewhere()
        (self.unit_dir / "model").symlink_to(outside, target_is_directory=True)
        client = FakeClient()
        with self.assertRaisesRegex(meshy.BuildError, "model"):
            meshy.run_build(self.spec, self.manifest, client, self.unit_dir, 3, 100, say=self.quiet.append)
        self.assertEqual(client.created, [])
        self.assertEqual(list(outside.iterdir()), [])


    def test_a_folder_symlinked_inside_the_work_dir_is_fine(self) -> None:
        (self.unit_dir / "real").mkdir()
        (self.unit_dir / "candidates").symlink_to(self.unit_dir / "real", target_is_directory=True)
        paths = self.candidates(FakeClient())
        self.assertTrue(all(p.exists() for p in paths))

    def test_a_build_refuses_to_continue_after_an_interrupted_create(self) -> None:
        self.candidates(FakeClient())
        with self.assertRaises(KeyboardInterrupt):
            meshy.run_build(self.spec, self.manifest, FakeClient(create_error=KeyboardInterrupt()), self.unit_dir, 3, 100, say=self.quiet.append)
        self.manifest = Manifest.load(self.manifest.path)
        self.assertEqual(self.manifest.find("refine", "cand-3")["status"], "CREATING")
        again = FakeClient()
        with self.assertRaisesRegex(meshy.InterruptedCreate, "creating refine cand-3"):
            meshy.run_build(self.spec, self.manifest, again, self.unit_dir, 3, 0, say=self.quiet.append)
        self.assertEqual(again.created, [])

    def test_a_creating_record_counts_as_bought_in_the_estimates(self) -> None:
        self.manifest.upsert({"kind": "preview", "label": "cand-1", "status": "CREATING", "created_at": 1})
        self.assertEqual(meshy.candidates_cost(self.spec, self.manifest), 2 * 5 + 2 * 20 - 5)

    def test_plan_text_shows_a_creating_record(self) -> None:
        self.assertNotIn("stopped while creating", meshy.plan_text(self.spec, self.style, self.manifest))
        self.manifest.upsert({"kind": "preview", "label": "cand-1", "status": "CREATING", "created_at": 1})
        self.assertIn("a previous run stopped while creating preview cand-1", meshy.plan_text(self.spec, self.style, self.manifest))


class PropFlowTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.prop_dir = Path(self._tmp.name) / "broadsword"
        self.prop_dir.mkdir()
        self.spec = load_prop_spec(ART_SRC / "props" / "broadsword" / "spec.toml")
        self.style = load_style(ART_SRC / "style.toml")
        self.manifest = Manifest(self.prop_dir / "manifest.json")
        self.quiet: list[str] = []

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def candidates(self, client: FakeClient, max_credits: int = 100) -> list[Path]:
        return meshy.run_candidates(self.spec, self.style, self.manifest, client, self.prop_dir, max_credits, say=self.quiet.append)

    def build(self, client: FakeClient, pick: int = 1, max_credits: int = 100) -> None:
        meshy.run_prop_build(self.spec, self.manifest, client, self.prop_dir, pick, max_credits, say=self.quiet.append)

    def test_candidates_are_bought_once_resumed_and_have_no_pose(self) -> None:
        client = FakeClient()
        paths = self.candidates(client)
        self.assertEqual([p.name for p in paths], ["cand-1.glb", "cand-2.glb"])
        self.assertTrue(all(p.parent == self.prop_dir / "candidates" and p.exists() for p in paths))
        self.assertEqual(client.created, [("preview", "meshy-6-lite"), ("preview", "meshy-6-lite")])
        self.assertEqual(client.pose_modes, [None, None])
        self.assertTrue(all(prompt.endswith(self.style.prop_suffix) for prompt in client.prompts))
        again = FakeClient()
        self.candidates(again)
        self.assertEqual(again.created, [])
        self.assertEqual(meshy.candidates_cost(self.spec, self.manifest), 0)

    def test_an_interrupted_candidates_run_resumes_the_same_task(self) -> None:
        lost = {"preview-1": "text-to-3d task preview-1 still IN_PROGRESS after 1800 s; rerun to keep waiting"}
        with self.assertRaises(MeshyError):
            self.candidates(FakeClient(lost_waits=lost))
        again = FakeClient()
        self.candidates(again)
        self.assertEqual(again.created, [("preview", "meshy-6-lite")])  # cand-1 is waited on, only cand-2 is bought

    def test_candidates_over_budget_buy_nothing(self) -> None:
        client = FakeClient()
        with self.assertRaisesRegex(meshy.BudgetError, "need 10 credits"):
            self.candidates(client, max_credits=9)
        self.assertEqual(client.created, [])

    def test_a_build_buys_the_refine_only_and_downloads_the_texture(self) -> None:
        self.candidates(FakeClient())
        client = FakeClient()
        self.build(client, pick=2)
        self.assertEqual(client.created, [("refine", "preview-2")])  # no rig, no animate
        self.assertTrue((self.prop_dir / "model" / "textured.glb").exists())
        self.assertEqual({p.name for p in (self.prop_dir / "model").iterdir()}, {"textured.glb", "PICK"})  # the marker says which candidate this is
        self.assertFalse((self.prop_dir / "anims").exists())
        record = Manifest.load(self.manifest.path).find("refine", "cand-2")
        self.assertEqual(record["status"], "SUCCEEDED")
        self.assertIsNone(self.manifest.find("rig", "cand-2"))
        again = FakeClient()
        self.build(again, pick=2, max_credits=0)
        self.assertEqual(again.created, [])

    def test_the_build_cost_is_the_refine_until_it_is_bought(self) -> None:
        self.assertEqual(meshy.prop_build_cost(self.manifest, 1), 10)
        self.candidates(FakeClient())
        self.build(FakeClient())
        self.assertEqual(meshy.prop_build_cost(self.manifest, 1), 0)
        self.assertEqual(meshy.prop_build_cost(self.manifest, 2), 10)

    def test_an_over_budget_build_buys_nothing(self) -> None:
        self.candidates(FakeClient())
        client = FakeClient()
        with self.assertRaisesRegex(meshy.BudgetError, "needs 10 credits; --max-credits is 9"):
            self.build(client, max_credits=9)
        self.assertEqual(client.created, [])
        self.assertIsNone(self.manifest.find("refine", "cand-1"))

    def test_a_build_needs_a_finished_candidate(self) -> None:
        client = FakeClient()
        with self.assertRaisesRegex(meshy.BuildError, "cand-1 has no finished preview; run prop-candidates first"):
            self.build(client)
        self.assertEqual(client.created, [])

    def test_a_creating_record_blocks_prop_candidates_and_prop_build(self) -> None:
        self.manifest.upsert({"kind": "preview", "label": "cand-1", "status": "CREATING", "created_at": 1})
        for run in (lambda c: self.candidates(c, max_credits=0), lambda c: self.build(c, max_credits=0)):
            client = FakeClient()
            with self.assertRaisesRegex(meshy.InterruptedCreate, "creating preview cand-1"):
                run(client)
            self.assertEqual(client.created, [])

    def test_a_build_refuses_to_continue_after_an_interrupted_refine(self) -> None:
        self.candidates(FakeClient())
        with self.assertRaises(KeyboardInterrupt):
            self.build(FakeClient(create_error=KeyboardInterrupt()))
        self.manifest = Manifest.load(self.manifest.path)
        self.assertEqual(self.manifest.find("refine", "cand-1")["status"], "CREATING")
        with self.assertRaisesRegex(meshy.InterruptedCreate, "creating refine cand-1"):
            self.build(FakeClient(), max_credits=0)

    def test_a_prop_build_writes_the_marker_and_refuses_another_pick(self) -> None:
        self.candidates(FakeClient())
        self.build(FakeClient(), pick=2)
        self.assertEqual((self.prop_dir / "model" / "PICK").read_text(), "cand-2\n")
        again = FakeClient()
        with self.assertRaisesRegex(meshy.BuildError, r"model/ holds cand-2's files; building cand-1 would mix two models"):
            self.build(again, pick=1, max_credits=0)
        self.assertEqual(again.created, [])
        self.build(again, pick=2, max_credits=0)  # the same pick again is fine
        self.assertEqual(again.created, [])

    def test_a_prop_model_with_no_marker_is_adopted(self) -> None:
        self.candidates(FakeClient())
        self.build(FakeClient(), pick=1)
        (self.prop_dir / "model" / "PICK").unlink()
        again = FakeClient()
        self.build(again, pick=1, max_credits=0)
        self.assertEqual(again.created, [])
        self.assertEqual((self.prop_dir / "model" / "PICK").read_text(), "cand-1\n")

    def test_prop_plan_text_lists_what_it_would_buy_in_order(self) -> None:
        lines = meshy.prop_plan_text(self.spec, self.style, self.manifest).splitlines()
        prompt = self.spec.full_prompt(self.style)
        self.assertEqual(lines, [
            f"broadsword: prompt {len(prompt)}/800 characters",
            "candidates: cand-1 meshy-6-lite (5), cand-2 meshy-6-lite (5) -> 10 credits still to buy",
            "build (after you pick): refine 10 credits",
            "spent on broadsword so far: 0 credits",
        ])

    def test_prop_plan_text_tracks_spending_and_shows_a_creating_record(self) -> None:
        self.candidates(FakeClient())
        text = meshy.prop_plan_text(self.spec, self.style, self.manifest)
        self.assertIn("-> 0 credits still to buy", text)
        self.assertIn("spent on broadsword so far: 2 credits", text)
        self.assertNotIn("blocked:", text)
        self.manifest.upsert({"kind": "refine", "label": "cand-1", "status": "CREATING", "created_at": 1})
        lines = meshy.prop_plan_text(self.spec, self.style, self.manifest).splitlines()
        self.assertTrue(lines[-1].startswith("blocked: a previous run stopped while creating refine cand-1"))

    def test_the_manifest_never_holds_a_url(self) -> None:
        self.candidates(FakeClient())
        self.build(FakeClient())
        text = self.manifest.path.read_text(encoding="utf-8")
        self.assertNotIn("://", text)
        self.assertNotIn("Signature", text)


class MainTest(unittest.TestCase):
    def run_main(self, argv: list[str]) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = meshy.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_a_unit_name_that_could_leave_the_repo_is_refused_before_any_path_is_built(self) -> None:
        for name in ("../evil", "/abs", "..", "a/b", "Shieldman", "9lives", "_x", "", "a" * 33, "x\n"):
            with self.subTest(unit=name), mock.patch.object(meshy, "load_spec", side_effect=AssertionError("built a path")):
                code, _, err = self.run_main(["plan", name])
            self.assertEqual(code, 2)
            self.assertIn("meshy.py: unit names are lowercase letters, digits and _", err)

    def test_a_clean_unit_name_still_plans(self) -> None:
        code, out, _ = self.run_main(["plan", "shieldman"])
        self.assertEqual(code, 0)
        self.assertIn("shieldman: prompt", out)

    def test_a_prop_name_that_could_leave_the_repo_is_refused_before_any_path_is_built(self) -> None:
        for command in (["prop-plan"], ["prop-candidates", "--max-credits", "100"], ["prop-build", "--pick", "1", "--max-credits", "100"]):
            for name in ("../evil", "/abs", "..", "a/b", "Broadsword", "9lives", "_x", "", "a" * 33, "x\n"):
                argv = [command[0], name, *command[1:]]
                with self.subTest(argv=argv), mock.patch.object(meshy, "load_prop_spec", side_effect=AssertionError("built a path")):
                    code, _, err = self.run_main(argv)
                self.assertEqual(code, 2)
                self.assertIn("meshy.py: unit names are lowercase letters, digits and _", err)

    def test_prop_plan_reads_the_real_recipe(self) -> None:
        for prop, length_line in (("broadsword", "broadsword: prompt"), ("targe", "targe: prompt")):
            with self.subTest(prop=prop):
                code, out, err = self.run_main(["prop-plan", prop])
                self.assertEqual((code, err), (0, ""))
                lines = out.splitlines()
                self.assertTrue(lines[0].startswith(length_line) and lines[0].endswith("/800 characters"))
                self.assertTrue(lines[1].startswith("candidates: cand-1 meshy-6-lite (5), cand-2 meshy-6-lite (5)"))
                self.assertEqual(lines[2], "build (after you pick): refine 10 credits")
                self.assertTrue(lines[3].startswith(f"spent on {prop} so far: "))

    def test_a_prop_that_has_no_recipe_is_reported(self) -> None:
        code, _, err = self.run_main(["prop-plan", "no_such_prop"])
        self.assertEqual(code, 2)
        self.assertIn("meshy.py:", err)

    def test_a_unit_plan_is_not_affected_by_the_prop_commands(self) -> None:
        code, out, _ = self.run_main(["plan", "shieldman"])
        self.assertEqual(code, 0)
        self.assertIn("refine 10 + rig 5 + 4 actions x 3 = 27 credits", out)

    def stage_in(self, root: Path, prop_dir: Path) -> Path:
        """A throwaway art-src (style.toml at root) with the real broadsword recipe in prop_dir."""
        root.mkdir(parents=True, exist_ok=True)
        shutil.copy(ART_SRC / "style.toml", root / "style.toml")
        prop_dir.mkdir(parents=True)
        shutil.copy(ART_SRC / "props" / "broadsword" / "spec.toml", prop_dir / "spec.toml")
        return prop_dir

    def stage(self, root: Path) -> Path:
        """A throwaway art-src with the real broadsword recipe, so the paid commands never touch the repo's."""
        return self.stage_in(root, root / "props" / "broadsword")

    def run_paid(self, root: Path, fake: FakeClient, argv: list[str]) -> tuple[int, str, str]:
        # The key file, the network and the real client are all patched out.
        with mock.patch.object(meshy, "ART_SRC", root), \
                mock.patch.object(meshy, "load_secret", return_value="not-a-real-key"), \
                mock.patch.object(meshy, "http_transport"), \
                mock.patch.object(meshy, "MeshyClient", return_value=fake):
            return self.run_main(argv)

    def test_prop_candidates_and_prop_build_run_end_to_end_with_a_fake_client(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prop_dir = self.stage(root)
            fake = FakeClient()
            code, out, err = self.run_paid(root, fake, ["prop-candidates", "broadsword", "--max-credits", "10"])
            self.assertEqual((code, err), (0, ""))
            self.assertEqual(fake.pose_modes, [None, None])
            self.assertIn("Next (free): make art-prop-candidates PROP=broadsword, look at "
                          "art-src/props/broadsword/review/candidates.png, then prop-build --pick N", out)
            self.assertIn("credits spent on broadsword so far: 2", out)
            self.assertTrue((prop_dir / "candidates" / "cand-2.glb").exists())

            fake = FakeClient()
            code, out, err = self.run_paid(root, fake, ["prop-build", "broadsword", "--pick", "1", "--max-credits", "10"])
            self.assertEqual((code, err), (0, ""))
            self.assertEqual(fake.created, [("refine", "preview-1")])
            self.assertIn("Next (free): make art-attach UNIT=<unit that carries it>", out)
            self.assertTrue((prop_dir / "model" / "textured.glb").exists())

    def test_the_paid_prop_commands_stop_at_a_creating_record(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prop_dir = self.stage(root)
            manifest = Manifest(prop_dir / "manifest.json")
            manifest.upsert({"kind": "preview", "label": "cand-1", "status": "CREATING", "created_at": 1})
            manifest.save()
            for argv in (["prop-candidates", "broadsword", "--max-credits", "10"],
                         ["prop-build", "broadsword", "--pick", "1", "--max-credits", "10"]):
                fake = FakeClient()
                with self.subTest(argv=argv[0]):
                    code, out, err = self.run_paid(root, fake, argv)
                    self.assertEqual(code, 1)
                    self.assertIn("a previous run stopped while creating preview cand-1", err)
                    self.assertNotIn("credits spent", out)
                    self.assertEqual(fake.created, [])

    def test_the_free_commands_never_read_the_key(self) -> None:
        for argv in (["prop-plan", "broadsword"], ["plan", "shieldman"]):
            with self.subTest(argv=argv), \
                    mock.patch.object(meshy, "load_secret", side_effect=AssertionError("read the key")), \
                    mock.patch.object(meshy, "http_transport", side_effect=AssertionError("built a transport")), \
                    mock.patch.object(meshy, "MeshyClient", side_effect=AssertionError("built a client")):
                code, out, err = self.run_main(argv)
            self.assertEqual((code, err), (0, ""))
            self.assertIn("credits", out)

    def test_each_paid_command_runs_only_its_own_flow(self) -> None:
        calls = {"run_candidates": ["candidates", "prop-candidates"], "run_build": ["build"], "run_prop_build": ["prop-build"]}
        argv = {
            "candidates": ["candidates", "shieldman", "--max-credits", "1"],
            "prop-candidates": ["prop-candidates", "broadsword", "--max-credits", "1"],
            "build": ["build", "shieldman", "--pick", "1", "--max-credits", "1"],
            "prop-build": ["prop-build", "broadsword", "--pick", "1", "--max-credits", "1"],
        }
        for flow, commands in calls.items():
            for command in commands:
                with self.subTest(command=command), \
                        mock.patch.object(meshy, "load_secret", return_value="not-a-real-key"), \
                        mock.patch.object(meshy, "http_transport"), \
                        mock.patch.object(meshy, "MeshyClient"), \
                        mock.patch.object(meshy, "run_candidates") as run_candidates, \
                        mock.patch.object(meshy, "run_build") as run_build, \
                        mock.patch.object(meshy, "run_prop_build") as run_prop_build:
                    code, _, _ = self.run_main(argv[command])
                    ran = {"run_candidates": run_candidates, "run_build": run_build, "run_prop_build": run_prop_build}
                self.assertEqual(code, 0)
                for name, mocked in ran.items():
                    self.assertEqual(mocked.call_count, 1 if name == flow else 0, f"{command}: {name}")

    def test_a_work_dir_that_is_a_symlink_is_refused(self) -> None:
        # The repo is public, so a PR could plant a symlink under art-src to send writes elsewhere.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "art-src"
            real = Path(tmp) / "real_broadsword"
            self.stage_in(root, real)
            (root / "props").mkdir()
            (root / "props" / "broadsword").symlink_to(real, target_is_directory=True)
            for argv in (["prop-plan", "broadsword"], ["prop-candidates", "broadsword", "--max-credits", "10"],
                         ["prop-build", "broadsword", "--pick", "1", "--max-credits", "10"]):
                with self.subTest(argv=argv[0]):
                    fake = FakeClient()
                    code, out, err = self.run_paid(root, fake, argv)
                    self.assertEqual((code, out, fake.created), (2, "", []))
                    self.assertIn("symlink", err)
                    self.assertIn(str(root / "props" / "broadsword"), err)
            self.assertEqual(sorted(p.name for p in real.iterdir()), ["spec.toml"])  # nothing was written through it

    def test_a_parent_folder_that_is_a_symlink_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "art-src"
            real_props = Path(tmp) / "real_props"
            self.stage_in(root, real_props / "broadsword")
            (root / "props").symlink_to(real_props, target_is_directory=True)
            code, _, err = self.run_paid(root, FakeClient(), ["prop-plan", "broadsword"])
            self.assertEqual(code, 2)
            self.assertIn(str(root / "props"), err)
            self.assertIn("symlink", err)

    def stage_unit(self, root: Path) -> Path:
        """A throwaway art-src with the real Shieldman recipe (its manifest is left out: it is not ours to copy)."""
        shutil.copy(ART_SRC / "style.toml", root / "style.toml")
        unit_dir = root / "units" / "shieldman"
        unit_dir.mkdir(parents=True)
        shutil.copy(ART_SRC / "units" / "shieldman" / "spec.toml", unit_dir / "spec.toml")
        return unit_dir

    def test_a_symlinked_output_folder_is_refused_before_anything_is_bought(self) -> None:
        for folder in ("candidates", "model", "anims", "review"):
            for command, stage in (("prop-candidates", "prop"), ("prop-build", "prop"), ("candidates", "unit"), ("build", "unit")):
                with self.subTest(folder=folder, command=command), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp) / "art-src"
                    root.mkdir()
                    work_dir = self.stage(root) if stage == "prop" else self.stage_unit(root)
                    outside = Path(tmp) / "elsewhere"
                    outside.mkdir()
                    (work_dir / folder).symlink_to(outside, target_is_directory=True)
                    name = work_dir.name
                    argv = {"prop-candidates": ["prop-candidates", name, "--max-credits", "100"],
                            "prop-build": ["prop-build", name, "--pick", "1", "--max-credits", "100"],
                            "candidates": ["candidates", name, "--max-credits", "100"],
                            "build": ["build", name, "--pick", "1", "--max-credits", "100"]}[command]
                    fake = FakeClient()
                    code, out, err = self.run_paid(root, fake, argv)
                    self.assertEqual((code, out, fake.created), (2, "", []))
                    self.assertIn(f"meshy.py: {work_dir / folder} is a symlink", err)
                    self.assertEqual(list(outside.iterdir()), [])
                    self.assertFalse((work_dir / "manifest.json").exists())  # not even a CREATING record

    def test_any_symlinked_output_folder_is_refused_even_one_that_stays_inside(self) -> None:
        # _fetch lets a symlink that stays inside the work dir through (second line of defence); main is stricter.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "art-src"
            root.mkdir()
            work_dir = self.stage(root)
            (work_dir / "real").mkdir()
            (work_dir / "candidates").symlink_to(work_dir / "real", target_is_directory=True)
            fake = FakeClient()
            code, _, err = self.run_paid(root, fake, ["prop-candidates", "broadsword", "--max-credits", "10"])
            self.assertEqual((code, fake.created), (2, []))
            self.assertIn("candidates is a symlink", err)

    def test_a_dangling_symlinked_output_folder_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "art-src"
            root.mkdir()
            work_dir = self.stage(root)
            (work_dir / "anims").symlink_to(Path(tmp) / "does_not_exist", target_is_directory=True)
            code, _, err = self.run_paid(root, FakeClient(), ["prop-plan", "broadsword"])
            self.assertEqual(code, 2)
            self.assertIn("anims is a symlink", err)

    def test_real_output_folders_and_missing_ones_are_fine(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "art-src"
            root.mkdir()
            work_dir = self.stage(root)
            (work_dir / "candidates").mkdir()
            (work_dir / "model").mkdir()
            with mock.patch.object(meshy, "ART_SRC", root):
                self.assertIsNone(meshy._unsafe_work_dir(work_dir))

    def test_a_local_file_error_in_a_paid_command_is_reported_and_returns_1(self) -> None:
        # A planted manifest.json.part symlink: save() refuses it with an OSError. That is local file trouble, not a traceback.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "art-src"
            root.mkdir()
            work_dir = self.stage(root)
            target = Path(tmp) / "precious.txt"
            target.write_text("keep me")
            (work_dir / "manifest.json.part").symlink_to(target)
            for argv in (["prop-candidates", "broadsword", "--max-credits", "10"],
                         ["prop-build", "broadsword", "--pick", "1", "--max-credits", "10"]):
                with self.subTest(argv=argv[0]):
                    fake = FakeClient()
                    if argv[0] == "prop-build":  # needs a finished candidate; put one in a manifest saved the safe way
                        (work_dir / "manifest.json.part").unlink()
                        manifest = Manifest(work_dir / "manifest.json")
                        manifest.upsert({"kind": "preview", "label": "cand-1", "task_id": "preview-1", "status": "SUCCEEDED", "credits": 5})
                        manifest.save()
                        (work_dir / "manifest.json.part").symlink_to(target)
                    code, out, err = self.run_paid(root, fake, argv)
                    self.assertEqual(code, 1)
                    self.assertNotIn("credits spent", out)  # the "creating..." line is printed before the record is saved
                    self.assertTrue(err.startswith("meshy.py: "), err)
                    self.assertEqual(err.count("\n"), 1)  # one line, no traceback
                    self.assertIn("manifest.json.part", err)
                    self.assertNotIn("://", err)
                    self.assertNotIn("not-a-real-key", err)
                    self.assertEqual(fake.created, [])
                    self.assertEqual(target.read_text(), "keep me")

    def test_a_local_file_error_shows_only_the_oss_words_and_the_path(self) -> None:
        # Whatever else an OSError was built with (say, text from somewhere else) is not printed.
        sneaky = OSError("GET https://assets.meshy.ai/x.glb?Signature=SECRETSIG failed with key not-a-real-key")
        self.assertEqual(meshy._local_error(sneaky), "OSError")
        self.assertEqual(meshy._local_error(PermissionError(13, "Permission denied", "/art/model/PICK")), "Permission denied: /art/model/PICK")
        with mock.patch.object(meshy, "load_secret", return_value="not-a-real-key"), mock.patch.object(meshy, "http_transport"), \
                mock.patch.object(meshy, "MeshyClient"), mock.patch.object(meshy, "run_candidates", side_effect=sneaky):
            code, _, err = self.run_main(["prop-candidates", "broadsword", "--max-credits", "10"])
        self.assertEqual(code, 1)
        self.assertEqual(err, "meshy.py: OSError\n")

    def test_a_work_dir_that_resolves_outside_art_src_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "art-src"
            root.mkdir()
            with mock.patch.object(meshy, "ART_SRC", root):
                self.assertIn("outside art-src", meshy._unsafe_work_dir(Path(tmp) / "elsewhere" / "broadsword"))
                self.assertIsNone(meshy._unsafe_work_dir(root / "props" / "broadsword"))  # doesn't exist yet: fine

    def test_an_art_src_that_is_itself_reached_through_a_symlink_still_works(self) -> None:
        # Only components below art-src are checked; the checkout may live under a symlinked path.
        with tempfile.TemporaryDirectory() as tmp:
            real_root = Path(tmp) / "real"
            link_root = Path(tmp) / "link"
            self.stage_in(real_root, real_root / "props" / "broadsword")
            link_root.symlink_to(real_root, target_is_directory=True)
            code, out, _ = self.run_paid(link_root, FakeClient(), ["prop-plan", "broadsword"])
            self.assertEqual(code, 0)
            self.assertIn("broadsword: prompt", out)

    def test_an_interrupted_create_is_reported_and_returns_1(self) -> None:
        # Everything that could reach the key file, the network or a paid call is patched out.
        with mock.patch.object(meshy, "load_secret", return_value="not-a-real-key"), \
                mock.patch.object(meshy, "http_transport"), \
                mock.patch.object(meshy, "run_candidates", side_effect=meshy.InterruptedCreate("a previous run stopped while creating preview cand-1")):
            code, out, err = self.run_main(["candidates", "shieldman", "--max-credits", "100"])
        self.assertEqual(code, 1)
        self.assertIn("a previous run stopped while creating preview cand-1", err)
        self.assertNotIn("credits spent", out)


if __name__ == "__main__":
    unittest.main()
