#!/usr/bin/env python3
"""Buys a unit's 3D model, rig and animations from Meshy (spec §6.1), and the
weapons and gear it carries as separate textured models (spec §6.2a).

    python3 scripts/art/meshy.py plan shieldman                        free: what it would buy
    python3 scripts/art/meshy.py candidates shieldman --max-credits 60 paid: preview candidates
    python3 scripts/art/meshy.py build shieldman --pick 3 --max-credits 30
                                                                       paid: texture, rig, animate

    python3 scripts/art/meshy.py prop-plan broadsword                  free: what it would buy
    python3 scripts/art/meshy.py prop-candidates broadsword --max-credits 10
                                                                       paid: preview candidates, no pose
    python3 scripts/art/meshy.py prop-build broadsword --pick 1 --max-credits 10
                                                                       paid: texture only, no rig

Tim runs the paid commands in Terminal.app. Every task is recorded in
art-src/units/<id>/manifest.json (art-src/props/<id>/manifest.json for a
prop) as soon as it is created, so an
interrupted run resumes by polling the same task instead of buying it
again. A failed task (Meshy refunds those) is bought again on the next run.
Results download immediately, because Meshy's links expire after about 3
days. The key is read from ~/.config/ashenmarch/secrets.env and nothing
else. An interrupted or timed-out wait leaves the task PENDING, and the
next run waits for the same task. A task Meshy cancels or expires stays
PENDING too, and is never bought again until you have checked it on
meshy.ai and deleted its entry from manifest.json. The same goes for a
task that can never be reached again (Meshy has dropped it, or its id no
longer resolves): every run would wait on it for ever, so check it on
meshy.ai, then delete its entry from manifest.json. plan and prop-plan
print a `pending:` line for each PENDING record, with its kind, label and
task id, so you can see which entry that is. A record is written as
CREATING before each create call. If the run stops with the create
unresolved, that task may exist and be charged, so the next run refuses to
continue until you delete the CREATING entry from manifest.json.
model/ and anims/ hold one candidate's files at fixed paths, so a build writes
model/PICK naming the candidate and refuses to build a different one over it.
Nothing is read or written through a symlink: art-src, a unit or prop
folder, style.toml, or anything under the folder (spec.toml, manifest.json,
.part files, downloads, folders) that is one is refused up front, before the
recipe or the manifest is read.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import time
import urllib.error
from collections.abc import Callable
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from manifest import Manifest  # noqa: E402
from meshy_client import (  # noqa: E402
    CREDITS_PER_ACTION, MAX_ACTIONS_PER_REQUEST, PREVIEW_CREDITS, REFINE_CREDITS, RIG_CREDITS,
    MeshyClient, MeshyError, TaskFailed, http_downloader, http_transport,
)
from secrets_file import SecretsError, load_secret  # noqa: E402
from unit_spec import (  # noqa: E402
    NAME, PREVIEW_MODELS, PropSpec, SpecError, Style, UnitSpec, load_prop_spec, load_spec, load_style,
)

ART_SRC = HERE.parent.parent / "art-src"
Say = Callable[[str], None]
OUTPUT_FOLDERS = ("candidates", "model", "anims", "review")  # what builds and renders write under a unit or prop folder
Recipe = UnitSpec | PropSpec  # both list candidates and are previewed; only a unit is rigged and animated
PICK_LABEL = re.compile(r"cand-\d{1,4}", re.ASCII)  # all a PICK marker may hold; anything else is never printed


class BudgetError(Exception):
    """The run would spend more than --max-credits; nothing was bought."""


class BuildError(Exception):
    """The build can't start, e.g. the picked candidate isn't finished."""


class InterruptedCreate(Exception):
    """A previous run stopped while creating a task, so it may exist and be charged."""


def candidate_jobs(spec: Recipe) -> list[tuple[str, str]]:
    jobs = [(f"cand-{i + 1}", PREVIEW_MODELS["lite"]) for i in range(spec.lite)]
    jobs += [(f"cand-{spec.lite + i + 1}", PREVIEW_MODELS["full"]) for i in range(spec.full)]
    return jobs


def _bought(record: dict[str, Any] | None) -> bool:
    """Only a FAILED task (refunded) can be bought again. A CREATING one may be charged, so it counts."""
    return record is not None and record.get("status") != "FAILED"


def _interrupted(manifest: Manifest) -> list[str]:
    """One message per task whose create was interrupted (status CREATING)."""
    # !r: the manifest is committed, so a kind or label could hold terminal escapes or a newline.
    return [
        f"a previous run stopped while creating {t.get('kind')!r} {t.get('label')!r}; it may have been created and charged. "
        "Check your API tasks on meshy.ai. If it exists, note its id; either way, delete that entry from manifest.json before rerunning."
        for t in manifest.tasks if t.get("status") == "CREATING"
    ]


def _pending(manifest: Manifest) -> list[str]:
    """One line per task that was created but never finished. A rerun waits for each; one that can never finish needs a human."""
    return [
        f"pending: {t.get('kind')!r} {t.get('label')!r} task {t.get('task_id')!r}; a rerun waits for it. "
        "If it can never finish, check it on meshy.ai, then delete this entry from manifest.json."
        for t in manifest.tasks if t.get("status") == "PENDING"
    ]


def _refuse_if_interrupted(manifest: Manifest) -> None:
    messages = _interrupted(manifest)
    if messages:
        raise InterruptedCreate(messages[0])


def candidates_cost(spec: Recipe, manifest: Manifest) -> int:
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


def _candidates_line(spec: Recipe, manifest: Manifest) -> str:
    jobs = ", ".join(f"{label} {model} ({PREVIEW_CREDITS[model]})" for label, model in candidate_jobs(spec))
    return f"candidates: {jobs} -> {candidates_cost(spec, manifest)} credits still to buy"


def plan_text(spec: UnitSpec, style: Style, manifest: Manifest) -> str:
    prompt = spec.full_prompt(style)
    actions = len(spec.action_ids())
    build = REFINE_CREDITS + RIG_CREDITS + CREDITS_PER_ACTION * actions
    return "\n".join([
        f"{spec.id}: prompt {len(prompt)}/800 characters",
        _candidates_line(spec, manifest),
        f"build (after you pick): refine {REFINE_CREDITS} + rig {RIG_CREDITS} + {actions} actions x {CREDITS_PER_ACTION} = {build} credits",
        f"spent on {spec.id} so far: {manifest.credits_spent()} credits",
        *_pending(manifest),
        *(f"blocked: {message}" for message in _interrupted(manifest)),
    ])


def prop_build_cost(manifest: Manifest, pick: int) -> int:
    """A prop is textured and nothing else: no rig, no animations."""
    return 0 if _bought(manifest.find("refine", f"cand-{pick}")) else REFINE_CREDITS


def prop_plan_text(spec: PropSpec, style: Style, manifest: Manifest) -> str:
    prompt = spec.full_prompt(style)
    return "\n".join([
        f"{spec.id}: prompt {len(prompt)}/800 characters",
        _candidates_line(spec, manifest),
        f"build (after you pick): refine {REFINE_CREDITS} credits",
        f"spent on {spec.id} so far: {manifest.credits_spent()} credits",
        *_pending(manifest),
        *(f"blocked: {message}" for message in _interrupted(manifest)),
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
    done = {**record, "status": "SUCCEEDED", "credits": int(task.get("consumed_credits", 0))}
    finished_at = task.get("finished_at")
    if isinstance(finished_at, int) and not isinstance(finished_at, bool):  # the manifest is public: keep only a plain integer timestamp
        done["finished_at"] = finished_at
    _store(manifest, done)
    return task


def _start(manifest: Manifest, kind: str, label: str, create: Callable[[], str], say: Say, note: str, **extra: Any) -> dict[str, Any]:
    record = manifest.find(kind, label)
    if _bought(record):
        return dict(record)
    say(f"{label}: creating {kind} task ({note})")
    # Written before the call: if the run dies mid-create, the task may exist and be charged.
    creating = {"kind": kind, "label": label, "status": "CREATING", "created_at": _now(), **extra}
    _store(manifest, creating)
    try:
        task_id = create()
    except MeshyError as error:
        if not error.may_have_created:  # a definite rejection (400, 401, 402...): nothing was bought
            _store(manifest, {**creating, "status": "FAILED", "credits": 0})
        raise
    say(f"{label}: {kind} task {task_id} created")  # before the store: if that fails, the paid id is still on screen
    return _store(manifest, {**creating, "task_id": task_id, "status": "PENDING"})


def _check_inside(work_dir: Path, dest: Path) -> None:
    """Refuse a write that a symlink would carry out of the work dir. The repo is public, so a PR could plant one."""
    if not dest.parent.resolve().is_relative_to(work_dir.resolve()):
        raise BuildError(f"{dest} would be written outside {work_dir.name}/ because a folder on its path is a symlink. Remove the symlink and rerun.")


def _fetch(manifest: Manifest, client: Any, api_kind: str, record: dict[str, Any], work_dir: Path,
           files: dict[str, Callable[[dict[str, Any]], str]]) -> None:
    if record.get("status") == "SUCCEEDED" and all((work_dir / rel).exists() for rel in files):
        return
    for rel in files:  # before waiting on the task: a refusal leaves it recorded, so a rerun downloads without rebuying
        _check_inside(work_dir, work_dir / rel)
    task = _finish(manifest, client, api_kind, record)
    for rel, url_of in files.items():
        client.download(url_of(task), work_dir / rel)
    _store(manifest, {**manifest.find(record["kind"], record["label"]), "files": sorted(files)})


def run_candidates(spec: Recipe, style: Style, manifest: Manifest, client: Any, work_dir: Path,
                   max_credits: int, say: Say = print) -> list[Path]:
    _refuse_if_interrupted(manifest)
    if not candidate_jobs(spec):  # a recipe with no [candidates] table loads for the renderer, but there is nothing to buy
        raise BuildError(f"{spec.id} lists no candidates; add a [candidates] table with lite or full to its spec.toml")
    cost = candidates_cost(spec, manifest)
    if cost > max_credits:
        raise BudgetError(f"candidates need {cost} credits; --max-credits is {max_credits}")
    prompt = spec.full_prompt(style)
    paths: list[Path] = []
    for label, model in candidate_jobs(spec):
        record = _start(manifest, "preview", label, lambda m=model: client.create_preview(prompt, m, spec.polycount, spec.pose_mode),
                        say, f"{model}, {PREVIEW_CREDITS[model]} credits", ai_model=model, prompt=prompt)
        rel = f"candidates/{label}.glb"
        _fetch(manifest, client, "text-to-3d", record, work_dir, {rel: lambda t: t["model_urls"]["glb"]})
        paths.append(work_dir / rel)
    return paths


def _finished_preview(manifest: Manifest, label: str, candidates_command: str) -> dict[str, Any]:
    candidate = manifest.find("preview", label)
    if candidate is None or candidate.get("status") != "SUCCEEDED":
        raise BuildError(f"{label} has no finished preview; run {candidates_command} first")
    return candidate


def _pick_marker(work_dir: Path) -> Path:
    return work_dir / "model" / "PICK"


def _check_pick(work_dir: Path, label: str) -> None:
    """model/ and anims/ are fixed paths, so a build of another candidate would skip files it finds and keep the old model."""
    marker = _pick_marker(work_dir)
    _check_inside(work_dir, marker)  # a symlinked model/ is refused here, before anything is bought
    try:
        # O_NOFOLLOW here too, so a planted symlink can't make us print some other file.
        with os.fdopen(os.open(marker, os.O_RDONLY | os.O_NOFOLLOW), encoding="utf-8", errors="replace") as handle:
            old = handle.read(64).strip()
    except FileNotFoundError:
        return  # no marker yet (a build from before markers existed): adopt the files that are there
    except OSError:
        raise BuildError(f"{marker} can't be read (is it a symlink?). Delete it, or move model/ and anims/ aside, and rerun.") from None
    if PICK_LABEL.fullmatch(old) is None:  # a committed file's bytes must not reach the terminal, escape sequences included
        raise BuildError("model/PICK is malformed; delete it and rerun")
    if old != label:
        raise BuildError(f"model/ holds {old}'s files; building {label} would mix two models. Move model/ and anims/ aside (or delete them) first.")


def _write_pick(work_dir: Path, label: str) -> None:
    marker = _pick_marker(work_dir)
    if marker.exists() or marker.is_symlink():
        return  # _check_pick already saw it holds this label
    _check_inside(work_dir, marker)
    marker.parent.mkdir(parents=True, exist_ok=True)
    with os.fdopen(os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644), "w", encoding="utf-8") as out:
        out.write(f"{label}\n")


def _texture(manifest: Manifest, client: Any, work_dir: Path, label: str, candidate: dict[str, Any], say: Say) -> dict[str, Any]:
    """The refine step, the same for a unit and a prop: texture the picked preview and download it."""
    refine = _start(manifest, "refine", label, lambda: client.create_refine(candidate["task_id"]), say, f"{REFINE_CREDITS} credits")
    _write_pick(work_dir, label)  # after the create: a rejected refine leaves no marker, so another pick stays open
    _fetch(manifest, client, "text-to-3d", refine, work_dir, {"model/textured.glb": lambda t: t["model_urls"]["glb"]})
    return refine


def run_prop_build(spec: PropSpec, manifest: Manifest, client: Any, prop_dir: Path, pick: int,
                   max_credits: int, say: Say = print) -> None:
    _refuse_if_interrupted(manifest)
    label = f"cand-{pick}"
    _check_pick(prop_dir, label)
    candidate = _finished_preview(manifest, label, "prop-candidates")
    cost = prop_build_cost(manifest, pick)
    if cost > max_credits:
        raise BudgetError(f"texturing {spec.id} needs {cost} credits; --max-credits is {max_credits}")
    _texture(manifest, client, prop_dir, label, candidate, say)  # refine only: a prop is fixed to a bone, never rigged


def run_build(spec: UnitSpec, manifest: Manifest, client: Any, unit_dir: Path, pick: int,
              max_credits: int, say: Say = print) -> None:
    _refuse_if_interrupted(manifest)
    actions = len(spec.action_ids())
    if actions > MAX_ACTIONS_PER_REQUEST:  # before any purchase: refine and rig would be paid for, then the animation request refused
        raise BuildError(f"{spec.id} lists {actions} animation actions; Meshy takes at most {MAX_ACTIONS_PER_REQUEST} per request. "
                         "Remove some from spec.toml first.")
    label = f"cand-{pick}"
    _check_pick(unit_dir, label)
    candidate = _finished_preview(manifest, label, "candidates")
    cost = build_cost(spec, manifest, pick)
    if cost > max_credits:
        raise BudgetError(f"the build needs {cost} credits; --max-credits is {max_credits}")

    refine = _texture(manifest, client, unit_dir, label, candidate, say)

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


def _local_error(error: OSError) -> str:
    """The OS's own wording and the local path, and nothing else an OSError was built with, so no URL or key can ride along.
    A URLError (HTTPError too) keeps its URL in .filename, which may be signed, so only its type is shown."""
    if isinstance(error, urllib.error.URLError):
        return type(error).__name__
    what = error.strerror or type(error).__name__
    return f"{what}: {error.filename}" if error.filename else what


def _unsafe_work_dir(work_dir: Path) -> str | None:
    """Why this unit or prop folder can't be used, or None. Symlinks under art-src could send our writes elsewhere
    and make us read a file that isn't ours."""
    try:
        parts = work_dir.relative_to(ART_SRC).parts
    except ValueError:
        return f"{work_dir} is outside art-src"
    if ART_SRC.is_symlink():  # a merged PR could turn art-src into a link and plant a spec.toml at its target
        return f"{ART_SRC} is a symlink; replace it with a real folder"
    here = ART_SRC
    for part in parts:  # only art-src's own last component is checked: the checkout may live under a symlinked path
        here = here / part
        if here.is_symlink():
            return f"{here} is a symlink; replace it with a real folder"
    for folder in OUTPUT_FOLDERS:  # refused up front, so nothing is bought before a write would be; _fetch re-checks as a second line
        if (work_dir / folder).is_symlink():  # is_symlink() is also true for a dangling one
            return f"{work_dir / folder} is a symlink; replace it with a real folder"
    link = _first_symlink(work_dir)  # reads go through links as well as writes: spec.toml -> secrets.env would be parsed
    if link is not None:
        return f"{_shown(link)} is a symlink; replace it with a real file or folder"
    style = ART_SRC / "style.toml"
    if style.is_symlink():
        return f"{style} is a symlink; replace it with a real file"
    if not work_dir.resolve().is_relative_to(ART_SRC.resolve()):  # belt and braces: nothing above should let this happen
        return f"{work_dir} resolves outside art-src"
    return None


def _first_symlink(work_dir: Path) -> Path | None:
    """The first symlink under work_dir, file or folder, dangling or not. os.walk lists a link to a folder with the
    folders but, with followlinks=False, never enters it."""
    for root, folders, files in os.walk(work_dir, followlinks=False):
        for entry in sorted(folders + files):
            if os.path.islink(os.path.join(root, entry)):
                return Path(root) / entry
    return None


def _shown(path: Path) -> str:
    """A path for the terminal. The repo is public, so a file name may hold escape sequences or a newline: show it escaped."""
    text = str(path)
    return text if text.isprintable() else ascii(text)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="meshy.py", description="Buy a unit's model, rig and animations, or a prop's model, from Meshy.")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("plan").add_argument("unit")
    candidates = sub.add_parser("candidates")
    candidates.add_argument("unit")
    candidates.add_argument("--max-credits", type=int, required=True)
    build = sub.add_parser("build")
    build.add_argument("unit")
    build.add_argument("--pick", type=int, required=True)
    build.add_argument("--max-credits", type=int, required=True)
    sub.add_parser("prop-plan").add_argument("prop")
    prop_candidates = sub.add_parser("prop-candidates")
    prop_candidates.add_argument("prop")
    prop_candidates.add_argument("--max-credits", type=int, required=True)
    prop_build = sub.add_parser("prop-build")
    prop_build.add_argument("prop")
    prop_build.add_argument("--pick", type=int, required=True)
    prop_build.add_argument("--max-credits", type=int, required=True)
    args = parser.parse_args(argv)

    is_prop = args.command.startswith("prop-")
    name = args.prop if is_prop else args.unit
    if not NAME.fullmatch(name):  # no path pieces: `../x` must not leave art-src
        print("meshy.py: unit names are lowercase letters, digits and _", file=sys.stderr)
        return 2
    work_dir = ART_SRC / ("props" if is_prop else "units") / name
    unsafe = _unsafe_work_dir(work_dir)
    if unsafe:
        print(f"meshy.py: {unsafe}", file=sys.stderr)
        return 2
    try:
        spec = (load_prop_spec if is_prop else load_spec)(work_dir / "spec.toml")
        style = load_style(ART_SRC / "style.toml")
    except (SpecError, OSError) as error:
        print(f"meshy.py: {error}", file=sys.stderr)
        return 2
    manifest = Manifest.load(work_dir / "manifest.json")
    if args.command == "plan":  # the free commands return before anything looks for the key
        print(plan_text(spec, style, manifest))
        return 0
    if args.command == "prop-plan":
        print(prop_plan_text(spec, style, manifest))
        return 0
    try:
        client = MeshyClient(http_transport(load_secret("MESHY_API_KEY")), http_downloader)
    except (SecretsError, MeshyError) as error:
        print(f"meshy.py: {error}", file=sys.stderr)
        return 2
    try:
        if args.command == "candidates":
            run_candidates(spec, style, manifest, client, work_dir, args.max_credits)
            print(f"Next (free): make art-candidates UNIT={spec.id}, look at art-src/units/{spec.id}/review/candidates.png, then build --pick N")
        elif args.command == "prop-candidates":
            run_candidates(spec, style, manifest, client, work_dir, args.max_credits)
            print(f"Next (free): make art-prop-candidates PROP={spec.id}, look at art-src/props/{spec.id}/review/candidates.png, then prop-build --pick N")
        elif args.command == "build":
            run_build(spec, manifest, client, work_dir, args.pick, args.max_credits)
            print(f"Next (free): make art-render UNIT={spec.id}")
        elif args.command == "prop-build":
            run_prop_build(spec, manifest, client, work_dir, args.pick, args.max_credits)
            print("Next (free): make art-attach UNIT=<unit that carries it>")
        else:
            raise AssertionError(args.command)
    except (MeshyError, BudgetError, BuildError, InterruptedCreate, SpecError) as error:
        print(f"meshy.py: {error}", file=sys.stderr)
        return 1
    except OSError as error:  # the transport and downloader turn network failures into MeshyError, so this is local file trouble
        print(f"meshy.py: {_local_error(error)}", file=sys.stderr)
        return 1
    print(f"credits spent on {spec.id} so far: {manifest.credits_spent()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
