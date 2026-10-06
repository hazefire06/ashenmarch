#!/usr/bin/env python3
"""Buys a unit's 3D model, rig and animations from Meshy (spec §6.1).

    python3 scripts/art/meshy.py plan shieldman                        free: what it would buy
    python3 scripts/art/meshy.py candidates shieldman --max-credits 60 paid: preview candidates
    python3 scripts/art/meshy.py build shieldman --pick 3 --max-credits 30
                                                                       paid: texture, rig, animate

Tim runs the paid commands in Terminal.app. Every task is recorded in
art-src/units/<id>/manifest.json as soon as it is created, so an
interrupted run resumes by polling the same task instead of buying it
again. A failed task (Meshy refunds those) is bought again on the next run.
Results download immediately, because Meshy's links expire after about 3
days. The key is read from ~/.config/ashenmarch/secrets.env and nothing
else. An interrupted or timed-out wait leaves the task PENDING, and the
next run waits for the same task.
"""
from __future__ import annotations

import argparse
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from manifest import Manifest  # noqa: E402
from meshy_client import (  # noqa: E402
    CREDITS_PER_ACTION, PREVIEW_CREDITS, REFINE_CREDITS, RIG_CREDITS,
    MeshyClient, MeshyError, TaskFailed, http_downloader, http_transport,
)
from secrets_file import SecretsError, load_secret  # noqa: E402
from unit_spec import PREVIEW_MODELS, SpecError, Style, UnitSpec, load_spec, load_style  # noqa: E402

ART_SRC = HERE.parent.parent / "art-src"
Say = Callable[[str], None]


class BudgetError(Exception):
    """The run would spend more than --max-credits; nothing was bought."""


class BuildError(Exception):
    """The build can't start, e.g. the picked candidate isn't finished."""


def candidate_jobs(spec: UnitSpec) -> list[tuple[str, str]]:
    jobs = [(f"cand-{i + 1}", PREVIEW_MODELS["lite"]) for i in range(spec.lite)]
    jobs += [(f"cand-{spec.lite + i + 1}", PREVIEW_MODELS["full"]) for i in range(spec.full)]
    return jobs


def _bought(record: dict[str, Any] | None) -> bool:
    return record is not None and record.get("status") != "FAILED"


def candidates_cost(spec: UnitSpec, manifest: Manifest) -> int:
    return sum(PREVIEW_CREDITS[model] for label, model in candidate_jobs(spec) if not _bought(manifest.find("preview", label)))


def _animate_label(spec: UnitSpec, pick: int) -> str:
    return f"cand-{pick}:" + ",".join(str(i) for i in spec.action_ids())


def build_cost(spec: UnitSpec, manifest: Manifest, pick: int) -> int:
    label = f"cand-{pick}"
    cost = 0 if _bought(manifest.find("refine", label)) else REFINE_CREDITS
    cost += 0 if _bought(manifest.find("rig", label)) else RIG_CREDITS
    if spec.action_ids() and not _bought(manifest.find("animate", _animate_label(spec, pick))):
        cost += CREDITS_PER_ACTION * len(spec.action_ids())
    return cost


def plan_text(spec: UnitSpec, style: Style, manifest: Manifest) -> str:
    prompt = spec.full_prompt(style)
    jobs = ", ".join(f"{label} {model} ({PREVIEW_CREDITS[model]})" for label, model in candidate_jobs(spec))
    actions = len(spec.action_ids())
    build = REFINE_CREDITS + RIG_CREDITS + CREDITS_PER_ACTION * actions
    return "\n".join([
        f"{spec.id}: prompt {len(prompt)}/800 characters",
        f"candidates: {jobs} -> {candidates_cost(spec, manifest)} credits still to buy",
        f"build (after you pick): refine {REFINE_CREDITS} + rig {RIG_CREDITS} + {actions} actions x {CREDITS_PER_ACTION} = {build} credits",
        f"spent on {spec.id} so far: {manifest.credits_spent()} credits",
    ])


def _now() -> int:
    return int(time.time())


def _store(manifest: Manifest, record: dict[str, Any]) -> dict[str, Any]:
    kept = manifest.upsert(record)
    manifest.save()
    return dict(kept)


def _finish(manifest: Manifest, client: Any, api_kind: str, record: dict[str, Any]) -> dict[str, Any]:
    try:
        task = client.wait(api_kind, record["task_id"])
    except TaskFailed:
        _store(manifest, {**record, "status": "FAILED", "credits": 0})
        raise
    _store(manifest, {**record, "status": "SUCCEEDED", "credits": int(task.get("consumed_credits", 0)), "finished_at": task.get("finished_at")})
    return task


def _start(manifest: Manifest, kind: str, label: str, create: Callable[[], str], say: Say, note: str, **extra: Any) -> dict[str, Any]:
    record = manifest.find(kind, label)
    if _bought(record):
        return dict(record)
    say(f"{label}: creating {kind} task ({note})")
    return _store(manifest, {"kind": kind, "label": label, "task_id": create(), "status": "PENDING", "created_at": _now(), **extra})


def _fetch(manifest: Manifest, client: Any, api_kind: str, record: dict[str, Any], unit_dir: Path,
           files: dict[str, Callable[[dict[str, Any]], str]]) -> None:
    if record.get("status") == "SUCCEEDED" and all((unit_dir / rel).exists() for rel in files):
        return
    task = _finish(manifest, client, api_kind, record)
    for rel, url_of in files.items():
        client.download(url_of(task), unit_dir / rel)
    _store(manifest, {**manifest.find(record["kind"], record["label"]), "files": sorted(files)})


def run_candidates(spec: UnitSpec, style: Style, manifest: Manifest, client: Any, unit_dir: Path,
                   max_credits: int, say: Say = print) -> list[Path]:
    cost = candidates_cost(spec, manifest)
    if cost > max_credits:
        raise BudgetError(f"candidates need {cost} credits; --max-credits is {max_credits}")
    prompt = spec.full_prompt(style)
    paths: list[Path] = []
    for label, model in candidate_jobs(spec):
        record = _start(manifest, "preview", label, lambda m=model: client.create_preview(prompt, m, spec.polycount),
                        say, f"{model}, {PREVIEW_CREDITS[model]} credits", ai_model=model, prompt=prompt)
        rel = f"candidates/{label}.glb"
        _fetch(manifest, client, "text-to-3d", record, unit_dir, {rel: lambda t: t["model_urls"]["glb"]})
        paths.append(unit_dir / rel)
    return paths


def run_build(spec: UnitSpec, manifest: Manifest, client: Any, unit_dir: Path, pick: int,
              max_credits: int, say: Say = print) -> None:
    label = f"cand-{pick}"
    candidate = manifest.find("preview", label)
    if candidate is None or candidate.get("status") != "SUCCEEDED":
        raise BuildError(f"{label} has no finished preview; run candidates first")
    cost = build_cost(spec, manifest, pick)
    if cost > max_credits:
        raise BudgetError(f"the build needs {cost} credits; --max-credits is {max_credits}")

    refine = _start(manifest, "refine", label, lambda: client.create_refine(candidate["task_id"]), say, f"{REFINE_CREDITS} credits")
    _fetch(manifest, client, "text-to-3d", refine, unit_dir, {"model/textured.glb": lambda t: t["model_urls"]["glb"]})

    rig = _start(manifest, "rig", label, lambda: client.create_rig(refine["task_id"], spec.height_m), say, f"{RIG_CREDITS} credits")
    _fetch(manifest, client, "rigging", rig, unit_dir, {
        "model/rigged.glb": lambda t: t["result"]["rigged_character_glb_url"],
        "anims/rig_walk.glb": lambda t: t["result"]["basic_animations"]["walking_glb_url"],
        "anims/rig_run.glb": lambda t: t["result"]["basic_animations"]["running_glb_url"],
    })

    ids = spec.action_ids()
    if ids:
        animate = _start(manifest, "animate", _animate_label(spec, pick), lambda: client.create_animation(rig["task_id"], ids),
                         say, f"{len(ids)} actions, {CREDITS_PER_ACTION * len(ids)} credits", action_ids=ids)
        _fetch(manifest, client, "animations", animate, unit_dir, {"anims/actions.glb": lambda t: t["result"]["animation_glb_url"]})


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="meshy.py", description="Buy a unit's model, rig and animations from Meshy.")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("plan").add_argument("unit")
    candidates = sub.add_parser("candidates")
    candidates.add_argument("unit")
    candidates.add_argument("--max-credits", type=int, required=True)
    build = sub.add_parser("build")
    build.add_argument("unit")
    build.add_argument("--pick", type=int, required=True)
    build.add_argument("--max-credits", type=int, required=True)
    args = parser.parse_args(argv)

    unit_dir = ART_SRC / "units" / args.unit
    try:
        spec = load_spec(unit_dir / "spec.toml")
        style = load_style(ART_SRC / "style.toml")
    except (SpecError, OSError) as error:
        print(f"meshy.py: {error}", file=sys.stderr)
        return 2
    manifest = Manifest.load(unit_dir / "manifest.json")
    if args.command == "plan":
        print(plan_text(spec, style, manifest))
        return 0
    try:
        client = MeshyClient(http_transport(load_secret("MESHY_API_KEY")), http_downloader)
    except (SecretsError, MeshyError) as error:
        print(f"meshy.py: {error}", file=sys.stderr)
        return 2
    try:
        if args.command == "candidates":
            run_candidates(spec, style, manifest, client, unit_dir, args.max_credits)
            print(f"Next (free): make art-candidates UNIT={spec.id}, look at art-src/units/{spec.id}/review/candidates.png, then build --pick N")
        else:
            run_build(spec, manifest, client, unit_dir, args.pick, args.max_credits)
            print(f"Next (free): make art-render UNIT={spec.id}")
    except (MeshyError, BudgetError, BuildError, SpecError) as error:
        print(f"meshy.py: {error}", file=sys.stderr)
        return 1
    print(f"credits spent on {spec.id} so far: {manifest.credits_spent()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
