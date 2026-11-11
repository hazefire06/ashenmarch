#!/usr/bin/env python3
"""Buys the game's sound from ElevenLabs (spec §9.3): sound effects, designed voices, spoken lines and music.

    python3 scripts/audio/generate.py plan [--batch B] [--show]        free: what each batch would buy (--show: the text sent, and each voice id)
    python3 scripts/audio/generate.py probe --max-credits 40           paid: one 1 s sound at wav_32000
    python3 scripts/audio/generate.py probe --music --max-credits 45   paid: one 3 s music clip at wav_32000
    python3 scripts/audio/generate.py sfx --cue hit_flesh --max-credits 100
    python3 scripts/audio/generate.py sfx --category melee --max-credits 2000
    python3 scripts/audio/generate.py voices design shieldman --voice shieldman_old --max-credits 1000
    python3 scripts/audio/generate.py voices save shieldman --voice shieldman_old --pick 2
    python3 scripts/audio/generate.py voices lines shieldman [--voice V] [--line L] [--takes 3] --max-credits N
    python3 scripts/audio/generate.py voices ab --max-credits 2000
    python3 scripts/audio/generate.py music riverside_calm --max-credits 3000

Tim runs the paid commands in Terminal.app, from one worktree only (the manifest is per checkout; a global lock stops two runs at once). plan returns before anything looks for the key and makes no network call.
Every paid command prices what isn't bought yet and refuses, before buying anything, if that is over --max-credits. The prices
are assumed rates, so --max-credits caps the estimate and the key's quota on elevenlabs.io is the real cap. Each command prints the
prompt or text it sends, and the voice id, before its "buying" line.

Every purchase is recorded in audio-src/manifest.json: PENDING before the request, DONE (with the file and credits) after
the file is written. A request that may have charged (it went out and no usable reply came back) is INTERRUPTED and stops
the run. A definite rejection is FAILED with 0 credits and is bought again by the next run. A PENDING or INTERRUPTED entry
blocks every paid command until you check the usage page on elevenlabs.io and fix that entry by hand.

Audio is written only under audio-src/raw/, as sfx/<cue>/<take>, design/<unit>/<voice>/<n>, voices/<voice>/<line>/<take>,
ab/<model>/<line>/<take> and music/<layer>/<take>, with the extension the bytes say (.wav or .mp3). Nothing is read or
written through a symlink. The format is wav_32000, unless audio-src/format.txt says mp3_44100_128; the probe tells which.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import math
import os
import stat
import sys
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "art"))  # secrets_file and manifest live with the art scripts
sys.path.insert(0, str(HERE))

import cuebook  # noqa: E402
from cuebook import CLAN, CueBook, CueError, Layer, VoiceFile, check_id  # noqa: E402
from elevenlabs_client import ID as VOICE_ID  # noqa: E402
from elevenlabs_client import FORMATS, ElevenLabsClient, ElevenLabsError, http_transport  # noqa: E402
from manifest import Manifest, ManifestError  # noqa: E402
from secrets_file import SecretsError, load_secret  # noqa: E402

AUDIO_SRC = HERE.parent.parent / "audio-src"
AUDIO_FIELDS: frozenset[str] = frozenset({
    "kind", "label", "model", "status", "credits", "created_at", "finished_at", "files",
    "voice_id", "generated_voice_id", "prompt", "text", "format",
    "sha256", "bytes",  # of each saved file: process.py uses a raw file only if its hash matches a DONE record
})

# Assumed rates (spec §5.2). The plan output flags the ones nobody has confirmed.
SFX_CREDITS_PER_S = 40
MUSIC_CREDITS_PER_MIN = 900
SPEECH_CREDITS_PER_CHAR = 1
DESIGN_CREDITS_ASSUMED = 1000  # per design call; the real cost is unknown and the key's quota caps it
PROBE_CREDITS = 40
PROBE_MUSIC_MS = 3000
PROBE_MUSIC_CREDITS = math.ceil(PROBE_MUSIC_MS / 1000 * MUSIC_CREDITS_PER_MIN / 60)  # 45
PROBE_MUSIC_MODEL = "music_v2"
DEFAULT_FORMAT = "wav_32000"
PROBE_FORMAT = "wav_32000"
LINE_TAKES = 3
AB_TAKES = 2
AB_UNIT = "shieldman"
AB_VOICE = "shieldman_old"
AB_LINES: tuple[tuple[str, str], ...] = (
    ("attack_1", "[shouting]"), ("attack_2", "[shouting]"), ("hurt_1", "[shouting]"),
    ("kill_1", "[laughs]"), ("kill_2", "[laughs]"), ("victory_1", "[laughs]"),
)
MAX_DESIGN_ROUNDS = 3
LOCK_NAME = "manifest.json.lock"
# A second lock outside the checkout: two worktrees each have their own manifest and lock, so only this one sees both.
GLOBAL_LOCK = Path.home() / ".cache" / "ashenmarch" / "elevenlabs.lock"
BATCHES: tuple[str, ...] = ("probe", "sfx", "loops", "design", "lines", "ab", "music")

Say = Callable[[str], None]
GetClient = Callable[[str], ElevenLabsClient]  # the output format -> a client; the key is read only when this is called


class BudgetError(Exception):
    """The run would spend more than --max-credits; nothing was bought."""


class BlockedError(Exception):
    """A PENDING or INTERRUPTED manifest entry, an unsaved voice, a missing preview: nothing was bought."""


class InterruptedRun(Exception):
    """A request may have charged. The entry is INTERRUPTED and the run has stopped."""


class UnsafePath(Exception):
    """A symlink, or a file that can't be read as the plain file it should be."""


@dataclass
class Job:
    """One recording to buy. The label is also its path under audio-src/raw/, without the extension."""
    kind: str
    label: str
    credits: int
    model: str
    call: Callable[[ElevenLabsClient], bytes]
    fields: dict[str, Any] = field(default_factory=dict)  # prompt or text, for the manifest
    voice: str | None = None  # a saved voice this recording needs


def _say(line: str) -> None:
    print(line, flush=True)


def _now() -> int:
    return int(time.time())


def fingerprint(data: bytes) -> dict[str, Any]:
    """What a DONE record keeps of the audio it paid for, so a swapped or planted raw file is noticed later."""
    return {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


def extension(data: bytes) -> str:
    return ".wav" if data[:4] == b"RIFF" else ".mp3"


# ---- the manifest ---------------------------------------------------------------------------------------------------

def _bought(record: dict[str, Any] | None) -> bool:
    """Only DONE is bought. FAILED was a definite rejection (nothing charged); PENDING and INTERRUPTED block the run."""
    return record is not None and record.get("status") == "DONE"


def _with_status(manifest: Manifest, status: str) -> list[dict[str, Any]]:
    return [t for t in manifest.tasks if t.get("status") == status]


def _odd(manifest: Manifest) -> list[dict[str, Any]]:
    """Records whose status is anything but exactly DONE, FAILED, PENDING or INTERRUPTED: a hand-edited "done", a typo, none at all.
    They are never read as unbought, so nothing is bought twice."""
    return [t for t in manifest.tasks if t.get("status") not in ("DONE", "FAILED", "PENDING", "INTERRUPTED")]


def _pending(manifest: Manifest) -> list[str]:
    # !r: the manifest is committed, so a kind or label could hold terminal escapes or a newline.
    return [f"pending: {t.get('kind')!r} {t.get('label')!r}; a request was sent and the run never saw it finish" for t in _with_status(manifest, "PENDING")]


def _interrupted(manifest: Manifest) -> list[str]:
    return [f"interrupted: {t.get('kind')!r} {t.get('label')!r}; the request may have been charged" for t in _with_status(manifest, "INTERRUPTED")]


def _unknown(manifest: Manifest) -> list[str]:
    return [f"unknown status {t.get('status')!r}: {t.get('kind')!r} {t.get('label')!r}; only DONE, FAILED, PENDING and INTERRUPTED are understood" for t in _odd(manifest)]


HOW_TO_RESOLVE = ("Check the usage page on elevenlabs.io, then fix that entry in audio-src/manifest.json by hand: delete it if nothing was charged "
                  "(it is bought again), or set it to DONE with its credits if it was (the audio is gone; delete it to buy it again).")


def _refuse_if_blocked(manifest: Manifest) -> None:
    messages = [*_pending(manifest), *_interrupted(manifest), *_unknown(manifest)]
    if messages:
        extra = f" (and {len(messages) - 1} more)" if len(messages) > 1 else ""
        raise BlockedError(f"{messages[0]}{extra}. {HOW_TO_RESOLVE}")


def _store(manifest: Manifest, record: dict[str, Any]) -> dict[str, Any]:
    kept = manifest.upsert(record)
    manifest.save()
    return dict(kept)


def _buy(manifest: Manifest, record: dict[str, Any], call: Callable[[], Any]) -> Any:
    """PENDING on disk before the request. A definite rejection is FAILED and re-raised; a charge that may have happened is INTERRUPTED."""
    started = {**record, "status": "PENDING", "created_at": _now()}
    _store(manifest, started)
    try:
        return call()
    except ElevenLabsError as error:
        if not error.may_have_charged:
            _store(manifest, {**started, "status": "FAILED", "credits": 0})
            raise
        _store(manifest, {**started, "status": "INTERRUPTED"})
        reason = f"{record['label']!r}: {error}. {HOW_TO_RESOLVE}"
    # Raised outside the except block, so the new error has no __context__ and the original's traceback can't be reached through it.
    raise InterruptedRun(reason)


def _save_audio(manifest: Manifest, started: dict[str, Any], raw: Path, label: str, data: bytes) -> str:
    """Writes a paid reply. If that fails the call was paid and the audio is lost: INTERRUPTED, and the run stops."""
    try:
        return write_file(raw, label, data)
    except (OSError, UnsafePath) as error:
        _store(manifest, {**started, "status": "INTERRUPTED"})
        why = _local_error(error)
        raise InterruptedRun(f"{label!r}: the call was paid but the audio couldn't be saved ({why}). {HOW_TO_RESOLVE}") from None


def _text_shown(text: object, limit: int = 600) -> str:
    """Text for the terminal: as it will be sent, but escaped if it holds a control character, so a planted prompt can't redraw the screen."""
    text = str(text)[:limit]
    return text if text.isprintable() else ascii(text)


def _sends(manifest: Manifest, job: Job) -> list[str]:
    """What the paid API receives for a job: its prompt or text and, for speech, the voice id."""
    lines = [f"  sends: {_text_shown(job.fields.get('prompt', job.fields.get('text', '')))}"]
    if job.voice is not None:
        lines.append(f"  voice {job.voice}: voice_id {_voice_id(manifest, job.voice) or '(not saved)'}")
    return lines


def _local_error(error: Exception) -> str:
    if isinstance(error, OSError):
        what = error.strerror or type(error).__name__
        return f"{what}: {_shown(Path(str(error.filename)))}" if error.filename else what
    return str(error)


def _done(manifest: Manifest, record: dict[str, Any], credits: int, files: list[str], **extra: Any) -> None:
    _store(manifest, {**record, "status": "DONE", "credits": credits, "finished_at": _now(), "files": files, **extra})


# ---- files ----------------------------------------------------------------------------------------------------------

def _check_chain(raw: Path, rel: str) -> None:
    """Refuse a path under raw/ that crosses a symlink (raw/ itself too). The repo is public, so a PR could plant one."""
    here = raw
    for part in ("", *rel.split("/")):
        here = here / part if part else here
        try:
            if stat.S_ISLNK(os.lstat(here).st_mode):
                raise UnsafePath(f"{_shown(here)} is a symlink; replace it with a real folder or file and rerun")
        except FileNotFoundError:
            return  # nothing below a missing folder can be a link


def _check_dest(raw: Path, label: str) -> None:
    """Before anything is bought: the folder chain, and the final and .part names in either extension. Every part that exists must be
    a folder, and the file's own name must not be a folder: a PR could commit a file or a folder in the way, and a purchase would be
    lost at the write."""
    for ext in (".wav", ".mp3"):
        for rel in (label + ext, label + ext + ".part"):
            _check_obstacles(raw, rel)  # first: lstat through a file raises NotADirectoryError
            _check_chain(raw, rel)


def _check_obstacles(raw: Path, rel: str) -> None:
    here = raw
    parts = rel.split("/")
    for i, part in enumerate(("", *parts)):
        here = here / part if part else here
        try:
            mode = os.lstat(here).st_mode
        except FileNotFoundError:
            return  # nothing below a missing folder can be in the way
        last = i == len(parts)
        if last and stat.S_ISDIR(mode):
            raise UnsafePath(f"{_shown(here)} is a folder where the file {_shown(Path(part))} goes; remove it and rerun")
        if not last and not stat.S_ISDIR(mode):
            raise UnsafePath(f"{_shown(here)} is a file where a folder is needed; remove it and rerun")


def write_file(raw: Path, label: str, data: bytes) -> str:
    """Writes data to raw/<label>.<ext> through an O_NOFOLLOW .part file, then renames it. Returns the path relative to raw/."""
    rel = label + extension(data)
    _check_chain(raw, rel)
    dest = raw / rel
    part = dest.with_name(dest.name + ".part")
    _check_chain(raw, rel + ".part")
    dest.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "wb") as out:
        out.write(data)
    part.replace(dest)
    return rel


@contextlib.contextmanager
def _locked(path: Path) -> Iterator[None]:
    """One paid run at a time: two would each see a voice or take as unbought and buy it twice. Created exclusively, removed at exit."""
    try:
        os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644))
    except FileExistsError:
        raise BlockedError(f"{_shown(path)} exists, so another run may be going (it may be from another worktree). If none is (a run was killed), delete that file and rerun.") from None
    try:
        yield
    finally:
        with contextlib.suppress(OSError):
            os.unlink(path)


def _global_lock_path() -> Path:
    """GLOBAL_LOCK, in a folder made at mode 700 if it is missing. A symlink in its place is refused, as a symlinked lock file is."""
    folder = GLOBAL_LOCK.parent
    if folder.is_symlink():
        raise UnsafePath(f"{_shown(folder)} is a symlink; replace it with a real folder (or remove it)")
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    if folder.is_symlink() or not folder.is_dir():  # also catches a swap between the first look and the mkdir
        raise UnsafePath(f"{_shown(folder)} isn't a real folder")
    return GLOBAL_LOCK


def _shown(path: Path) -> str:
    text = str(path)
    return text if text.isprintable() else ascii(text)


def _first_symlink(folder: Path) -> Path | None:
    for root, folders, files in os.walk(folder, followlinks=False, onerror=_unlistable):
        for entry in sorted(folders + files):
            try:
                if stat.S_ISLNK(os.lstat(os.path.join(root, entry)).st_mode):
                    return Path(root) / entry
            except FileNotFoundError:
                continue
    return None


def _unlistable(error: OSError) -> None:
    if not isinstance(error, (FileNotFoundError, NotADirectoryError)):
        raise error


def _unsafe_audio_src() -> str | None:
    """Why audio-src can't be used, or None. Reads follow links as well as writes: a cues.toml -> secrets.env would be parsed."""
    src = AUDIO_SRC
    if src.is_symlink():
        return f"{_shown(src)} is a symlink; replace it with a real folder"
    for name in ("cues.toml", "manifest.json", "format.txt", "raw", "voices", "music"):
        if (src / name).is_symlink():
            return f"{_shown(src / name)} is a symlink; replace it with a real file or folder"
    try:
        for folder in ("raw", "voices", "music"):
            link = _first_symlink(src / folder)
            if link is not None:
                return f"{_shown(link)} is a symlink; replace it with a real file or folder"
    except OSError as error:
        return f"{_shown(Path(error.filename or src))} can't be checked; fix its permissions"
    return None


def read_format(src: Path) -> str:
    path = src / "format.txt"
    if not path.exists() and not path.is_symlink():
        return DEFAULT_FORMAT
    try:
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), encoding="utf-8", errors="replace") as handle:
            text = handle.read(64).strip()
    except OSError:
        raise UnsafePath(f"{_shown(path)} can't be read (is it a symlink?)") from None
    if text not in FORMATS:
        raise UnsafePath(f"{_shown(path)} must hold {' or '.join(sorted(FORMATS))} and nothing else")
    return text


# ---- jobs -----------------------------------------------------------------------------------------------------------

def _voice_id(manifest: Manifest, voice: str) -> str | None:
    record = manifest.find("voice", f"voice/{voice}")
    value = record.get("voice_id") if record is not None and _bought(record) else None
    return value if isinstance(value, str) and VOICE_ID.fullmatch(value) else None


def sfx_jobs(book: CueBook, cue_ids: list[str]) -> list[Job]:
    jobs: list[Job] = []
    for cue_id in cue_ids:
        cue = book.cues[cue_id]
        prompt = book.prompt_for(cue_id)
        for take in range(1, cue.takes + 1):
            jobs.append(Job(
                "sfx", f"sfx/{cue_id}/{take}", math.ceil(cue.duration_s * SFX_CREDITS_PER_S), cue.model,
                lambda c, cue=cue, prompt=prompt: c.sound(prompt, cue.duration_s, cue.prompt_influence, cue.loop, cue.model),
                {"prompt": prompt}))
    return jobs


def music_jobs(layer: Layer) -> list[Job]:
    prompt = layer.prompt.strip()
    length_ms = int(round(layer.length_s * 1000))
    credits = math.ceil(layer.length_s * MUSIC_CREDITS_PER_MIN / 60)
    return [Job("music", f"music/{layer.id}/{take}", credits, layer.model,
                lambda c: c.music(prompt, length_ms, layer.model), {"prompt": prompt})
            for take in range(1, layer.takes + 1)]


def spoken(text: str, tag: str | None) -> str:
    """What is sent to the TTS: ElevenLabs v4 takes audio tags inline, in front of the words."""
    return f"{tag} {text}" if tag else text


def _speech_job(manifest: Manifest, kind: str, label: str, voice: str, voice_model: str, text: str) -> Job:
    return Job(kind, label, len(text) * SPEECH_CREDITS_PER_CHAR, voice_model,
               lambda c: c.speech(_voice_id(manifest, voice) or "", text, voice_model), {"text": text}, voice=voice)


def line_jobs(manifest: Manifest, files: dict[str, VoiceFile], unit: str, voice: str | None, line: str | None, takes: int) -> list[Job]:
    unit_file = files[unit]
    lines = {**files[CLAN].lines, **unit_file.lines} if CLAN in files else dict(unit_file.lines)
    voices = [unit_file.voices[voice]] if voice else list(unit_file.voices.values())
    jobs: list[Job] = []
    for v in voices:
        for line_id in sorted(lines) if line is None else [line]:
            for take in range(1, takes + 1):
                spec = lines[line_id]
                jobs.append(_speech_job(manifest, "voices", f"voices/{v.id}/{line_id}/{take}", v.id, v.model, spoken(spec.text, spec.tag)))
    return jobs


def ab_jobs(manifest: Manifest, files: dict[str, VoiceFile]) -> list[Job]:
    lines = files[AB_UNIT].lines if AB_UNIT in files else {}
    missing = [line_id for line_id, _ in AB_LINES if line_id not in lines]
    if missing:
        raise CueError(f"the model test uses {AB_UNIT} lines that aren't in its voice file: {', '.join(missing)}")
    jobs: list[Job] = []
    for model in cuebook.VOICE_MODELS:
        for line_id, tag in AB_LINES:
            line = lines[line_id]
            text = spoken(line.text, f"{tag} {line.tag}" if line.tag else tag)
            for take in range(1, AB_TAKES + 1):
                jobs.append(_speech_job(manifest, "ab", f"ab/{model}/{line_id}/{take}", AB_VOICE, model, text))
    return jobs


def design_label(unit: str, voice: str, round_no: int = 1) -> str:
    """The marker for one design call: call for round 1, then call2, call3."""
    return f"design/{unit}/{voice}/call" + ("" if round_no == 1 else str(round_no))


def design_rounds(manifest: Manifest, unit: str, voice: str) -> int:
    return sum(1 for r in range(1, MAX_DESIGN_ROUNDS + 1) if _bought(manifest.find("design", design_label(unit, voice, r))))


def _last_preview(manifest: Manifest, unit: str, voice: str) -> int:
    prefix = f"design/{unit}/{voice}/"
    labels = [str(t.get("label")) for t in manifest.tasks if t.get("kind") == "design"]
    return max((int(x[len(prefix):]) for x in labels if x.startswith(prefix) and x[len(prefix):].isdigit()), default=0)


# ---- running --------------------------------------------------------------------------------------------------------

def _cost(manifest: Manifest, jobs: list[Job]) -> tuple[list[Job], int]:
    todo = [j for j in jobs if not _bought(manifest.find(j.kind, j.label))]
    return todo, sum(j.credits for j in todo)


def _check_budget(what: str, cost: int, max_credits: int) -> None:
    if cost > max_credits:
        raise BudgetError(f"{what} need {cost} credits; --max-credits is {max_credits}")


def _check_voices(manifest: Manifest, jobs: list[Job]) -> None:
    missing = sorted({j.voice for j in jobs if j.voice is not None and _voice_id(manifest, j.voice) is None})
    if missing:
        raise BlockedError(f"these voices aren't saved yet: {', '.join(missing)}. Run voices design, listen, then voices save --pick N for each.")


def run_jobs(manifest: Manifest, get_client: GetClient, raw: Path, fmt: str, jobs: list[Job], max_credits: int, say: Say = _say) -> int:
    """Buys what isn't bought. Everything that can refuse does so first: a blocked manifest, the budget, an unsaved voice, a symlink."""
    _refuse_if_blocked(manifest)
    todo, cost = _cost(manifest, jobs)
    if not todo:
        say("nothing to buy: everything here is already bought")
        return 0
    _check_budget(f"{len(todo)} recordings", cost, max_credits)
    _check_voices(manifest, todo)
    for job in todo:
        _check_dest(raw, job.label)
    client = get_client(fmt)
    for job in todo:
        for line in _sends(manifest, job):
            say(line)
        say(f"{job.label}: buying ({job.credits} credits)")
        record = {"kind": job.kind, "label": job.label, "model": job.model, "format": fmt, **job.fields}
        data = _buy(manifest, record, lambda job=job: job.call(client))
        rel = _save_audio(manifest, record, raw, job.label, data)
        _done(manifest, record, job.credits, [rel], **fingerprint(data))
        say(f"{job.label}: saved raw/{rel}")
    return len(todo)


def run_design(manifest: Manifest, get_client: GetClient, raw: Path, fmt: str, unit: str, voice: str, description: str,
               max_credits: int, again: bool = False, say: Say = _say) -> int:
    _refuse_if_blocked(manifest)
    rounds = design_rounds(manifest, unit, voice)
    if rounds and not again:
        say(f"nothing to buy: {unit}/{voice} already has its previews (--again buys another round)")
        return 0
    if rounds >= MAX_DESIGN_ROUNDS:
        raise BlockedError(f"{unit}/{voice} has had {MAX_DESIGN_ROUNDS} rounds of previews, the most this script buys; pick one of them")
    label = design_label(unit, voice, rounds + 1)
    _check_budget(f"designing {voice}", DESIGN_CREDITS_ASSUMED, max_credits)
    first = _last_preview(manifest, unit, voice) + 1  # numbers continue, so --pick N stays unique across rounds
    for n in range(first, first + 10):  # the client takes at most 10 previews
        _check_dest(raw, f"design/{unit}/{voice}/{n}")
    client = get_client(fmt)
    say(f"  sends: {_text_shown(description)}")
    say(f"{label}: designing ({DESIGN_CREDITS_ASSUMED} credits, assumed)")
    call = {"kind": "design", "label": label, "model": "eleven_ttv_v3", "text": description}
    previews = _buy(manifest, call, lambda: client.design(description))
    started = {**call, "status": "PENDING"}
    files: list[str] = []
    for n, (generated_id, audio) in enumerate(previews, first):
        preview_label = f"design/{unit}/{voice}/{n}"
        rel = _save_audio(manifest, started, raw, preview_label, audio)  # the audio only: the JSON the previews came in is never kept
        files.append(rel)
        _done(manifest, {"kind": "design", "label": preview_label, "model": "eleven_ttv_v3", "generated_voice_id": generated_id}, 0, [rel],
              **fingerprint(audio))
        say(f"{preview_label}: saved raw/{rel}")
    _done(manifest, call, DESIGN_CREDITS_ASSUMED, files)
    return len(files)


def run_save(manifest: Manifest, get_client: GetClient, fmt: str, unit: str, voice: str, description: str, pick: int, say: Say = _say) -> bool:
    _refuse_if_blocked(manifest)
    label = f"voice/{voice}"
    if _bought(manifest.find("voice", label)):
        say(f"nothing to do: {voice} is already saved")
        return False
    preview = manifest.find("design", f"design/{unit}/{voice}/{pick}")
    generated = preview.get("generated_voice_id") if preview is not None and _bought(preview) else None
    if not isinstance(generated, str):
        raise BlockedError(f"preview {pick} of {voice} was never made; run voices design {unit} --voice {voice} first")
    client = get_client(fmt)
    say(f"  sends: voice name {voice}, {_text_shown(description)}")
    say(f"{label}: saving preview {pick}")
    record = {"kind": "voice", "label": label, "generated_voice_id": generated}
    voice_id = _buy(manifest, record, lambda: client.save_voice(voice, description, generated))
    _done(manifest, record, 0, [], voice_id=voice_id)
    say(f"{label}: saved as {voice_id}")
    return True


def run_probe(manifest: Manifest, get_client: GetClient, max_credits: int, say: Say = _say) -> bool:
    """One 1 s sound at wav_32000, whatever format.txt says. Returns True if the format was accepted. Writes no audio and no format.txt."""
    _refuse_if_blocked(manifest)
    label = f"probe/{PROBE_FORMAT}"
    if _bought(manifest.find("probe", label)):
        say(f"nothing to buy: the probe already ran; {PROBE_FORMAT} was accepted")
        return True
    _check_budget("the probe needs", PROBE_CREDITS, max_credits)
    client = get_client(PROBE_FORMAT)
    record = {"kind": "probe", "label": label, "model": "eleven_text_to_sound_v2", "format": PROBE_FORMAT}
    try:
        data = _buy(manifest, record, lambda: client.sound("a short dry wooden knock", 1.0, 0.5, False, "eleven_text_to_sound_v2"))
    except ElevenLabsError as error:  # only a definite rejection gets here
        text = str(error).lower()
        if any(word in text for word in ("format", "wav", "32000")):
            say(f"{PROBE_FORMAT} was refused on this plan ({error}).")
            say("Put mp3_44100_128 in audio-src/format.txt (Task 19 does this) and every purchase will use it.")
            return False
        raise
    _done(manifest, record, PROBE_CREDITS, [])
    say(f"{PROBE_FORMAT} was accepted: the reply is {len(data)} bytes of {'WAV' if data[:4] == b'RIFF' else 'MP3'}.")
    say("Now check the usage page on elevenlabs.io: did the probe draw on your credits, or bill in dollars?")
    return True


def run_probe_music(manifest: Manifest, get_client: GetClient, max_credits: int, say: Say = _say) -> bool:
    """One 3 s music clip at wav_32000, whatever format.txt says: /v1/music's output_format is unverified, and a music batch is dear.
    Returns True if the format was accepted. Writes no audio and no format.txt."""
    _refuse_if_blocked(manifest)
    label = f"probe/music/{PROBE_FORMAT}"
    if _bought(manifest.find("probe", label)):
        say(f"nothing to buy: the music probe already ran; {PROBE_FORMAT} was accepted")
        return True
    _check_budget("the music probe needs", PROBE_MUSIC_CREDITS, max_credits)
    client = get_client(PROBE_FORMAT)
    prompt = "a single soft low drone"
    record = {"kind": "probe", "label": label, "model": PROBE_MUSIC_MODEL, "format": PROBE_FORMAT, "prompt": prompt}
    say(f"  sends: {prompt}")
    say(f"{label}: buying ({PROBE_MUSIC_CREDITS} credits, {PROBE_MUSIC_MS} ms)")
    try:
        data = _buy(manifest, record, lambda: client.music(prompt, PROBE_MUSIC_MS, PROBE_MUSIC_MODEL))
    except ElevenLabsError as error:  # only a definite rejection gets here
        if any(word in str(error).lower() for word in ("format", "wav", "32000")):
            say(f"{PROBE_FORMAT} was refused for music ({error}).")
            say("Put mp3_44100_128 in audio-src/format.txt and every purchase will use it.")
            return False
        raise
    _done(manifest, record, PROBE_MUSIC_CREDITS, [])
    say(f"{PROBE_FORMAT} was accepted for music: the reply is {len(data)} bytes of {'WAV' if data[:4] == b'RIFF' else 'MP3'}.")
    say("Now check the usage page on elevenlabs.io: did the clip draw on your credits, as about 45?")
    return True


def _missing_files(manifest: Manifest, raw: Path) -> list[str]:
    out: list[str] = []
    for t in manifest.tasks:
        if t.get("status") != "DONE" or not isinstance(t.get("files"), list):
            continue
        for rel in t["files"]:
            if isinstance(rel, str) and ".." not in rel.split("/") and not rel.startswith("/") and not os.path.lexists(raw / rel):
                out.append(f"bought but the file is gone: {t.get('label')!r} ({rel!r}); it is not bought again, so restore the file or fix the entry by hand")
    return out


# ---- the plan -------------------------------------------------------------------------------------------------------

def _line(name: str, jobs: list[Job], manifest: Manifest, note: str = "") -> str:
    todo, cost = _cost(manifest, jobs)
    bought = len(jobs) - len(todo)
    return f"{name}: {len(jobs)} recordings, {bought} of {len(jobs)} bought, {cost} credits still to buy{note}"


def batch_lines(name: str, book: CueBook, layers: dict[str, Layer], files: dict[str, VoiceFile], manifest: Manifest) -> list[str]:
    if name == "probe":
        done = _bought(manifest.find("probe", f"probe/{PROBE_FORMAT}"))
        music = _bought(manifest.find("probe", f"probe/music/{PROBE_FORMAT}"))
        return [f"probe: 1 sound of 1 s, {'1 of 1 bought' if done else '0 of 1 bought'}, {0 if done else PROBE_CREDITS} credits still to buy",
                f"probe --music: 1 clip of {PROBE_MUSIC_MS // 1000} s, {'1 of 1 bought' if music else '0 of 1 bought'}, "
                f"{0 if music else PROBE_MUSIC_CREDITS} credits still to buy"]
    if name in ("sfx", "loops"):
        ids = sorted(i for i, c in book.cues.items() if c.loop == (name == "loops"))
        return [_line(name, sfx_jobs(book, ids), manifest, f" ({SFX_CREDITS_PER_S}/s, assumed)")]
    if name == "music":
        jobs = [j for layer in layers.values() for j in music_jobs(layer)]
        return [_line(name, jobs, manifest, f" ({MUSIC_CREDITS_PER_MIN}/min, assumed)")]
    units = sorted(u for u, f in files.items() if u != CLAN and f.voices)
    if name == "design":
        pairs = [(u, v) for u in units for v in files[u].voices]
        todo = [p for p in pairs if not _bought(manifest.find("design", design_label(*p)))]
        cost = len(todo) * DESIGN_CREDITS_ASSUMED
        rounds = ", ".join(f"{v} {design_rounds(manifest, u, v)}" for u, v in pairs)
        return [f"design: {len(pairs)} voices, {len(pairs) - len(todo)} of {len(pairs)} bought, {cost} credits still to buy "
                f"({DESIGN_CREDITS_ASSUMED} per design call, assumed; the real cost is unknown)",
                f"  rounds of previews so far (at most {MAX_DESIGN_ROUNDS}; --again buys another): {rounds}"]
    jobs = _speech_jobs(name, manifest, files)
    unsaved = sorted({j.voice for j in jobs if j.voice and _voice_id(manifest, j.voice) is None})
    out = [_line(name, jobs, manifest, f" ({SPEECH_CREDITS_PER_CHAR}/character, assumed; v4 may cost more)")]
    if unsaved:
        out.append(f"  voices not saved yet: {', '.join(unsaved)}")
    return out


def _speech_jobs(name: str, manifest: Manifest, files: dict[str, VoiceFile]) -> list[Job]:
    units = sorted(u for u, f in files.items() if u != CLAN and f.voices)
    return ab_jobs(manifest, files) if name == "ab" else [j for u in units for j in line_jobs(manifest, files, u, None, None, LINE_TAKES)]


def show_lines(name: str, book: CueBook, layers: dict[str, Layer], files: dict[str, VoiceFile], manifest: Manifest) -> list[str]:
    """Every prompt, line or description still to buy in a batch, as the paid API will receive it, and the voice id each voice uses.
    The cue book, the voice files and manifest.json are committed, so a PR can change any of them: Tim reads this before buying."""
    if name == "probe":
        return []
    out: list[str] = []
    units = sorted(u for u, f in files.items() if u != CLAN and f.voices)
    if name == "design":
        for u in units:
            for v, voice in files[u].voices.items():
                if not _bought(manifest.find("design", design_label(u, v))):
                    out.append(f"  design/{u}/{v}: {_text_shown(voice.description)}")
        return out
    if name in ("sfx", "loops"):
        jobs = sfx_jobs(book, sorted(i for i, c in book.cues.items() if c.loop == (name == "loops")))
    elif name == "music":
        jobs = [j for layer in layers.values() for j in music_jobs(layer)]
    else:
        jobs = _speech_jobs(name, manifest, files)
    todo, _ = _cost(manifest, jobs)
    for job in todo:
        out.append(f"  {job.label}: {_text_shown(job.fields.get('prompt', job.fields.get('text', '')))}")
    for voice in sorted({j.voice for j in jobs if j.voice is not None}):
        out.append(f"  voice {voice}: voice_id {_voice_id(manifest, voice) or '(not saved)'}")
    return out


def plan_text(book: CueBook, layers: dict[str, Layer], files: dict[str, VoiceFile], manifest: Manifest, fmt: str, batch: str | None,
              show: bool = False) -> str:
    names = [batch] if batch else list(BATCHES)
    lines = [f"format: {fmt}",
             "These estimates use assumed rates. The key's quota on elevenlabs.io is the real cap on spending, so set it before buying."]
    for name in names:
        lines += batch_lines(name, book, layers, files, manifest)
        if show:
            lines += show_lines(name, book, layers, files, manifest)
    lines.append(f"spent so far: {manifest.credits_spent()} credits")
    lines += [*_pending(manifest), *_interrupted(manifest), *_unknown(manifest)]
    lines += _missing_files(manifest, AUDIO_SRC / "raw")
    if _pending(manifest) or _interrupted(manifest) or _unknown(manifest):
        lines.append(f"blocked: no paid command will run. {HOW_TO_RESOLVE}")
    return "\n".join(lines)


# ---- the command line -----------------------------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="generate.py", description="Buy the game's sound from ElevenLabs. Only plan is free.")
    sub = parser.add_subparsers(dest="command", required=True)

    def paid(p: argparse.ArgumentParser) -> argparse.ArgumentParser:
        p.add_argument("--max-credits", type=int, required=True)
        return p

    plan = sub.add_parser("plan")
    plan.add_argument("--batch", choices=BATCHES)
    plan.add_argument("--show", action="store_true", help="also list each prompt, line and description still to buy, and each voice id")
    probe = paid(sub.add_parser("probe"))
    probe.add_argument("--music", action="store_true", help="probe /v1/music instead: one 3 s clip at wav_32000 (about 45 credits)")
    sfx = paid(sub.add_parser("sfx"))
    which = sfx.add_mutually_exclusive_group(required=True)
    which.add_argument("--cue")
    which.add_argument("--category")
    music = paid(sub.add_parser("music"))
    music.add_argument("layer")

    voices = sub.add_parser("voices")
    vsub = voices.add_subparsers(dest="action", required=True)
    design = paid(vsub.add_parser("design"))
    design.add_argument("unit")
    design.add_argument("--voice", required=True)
    design.add_argument("--again", action="store_true", help="buy another round of previews (at most 3)")
    save = vsub.add_parser("save")
    save.add_argument("unit")
    save.add_argument("--voice", required=True)
    save.add_argument("--pick", type=int, required=True)
    lines = paid(vsub.add_parser("lines"))
    lines.add_argument("unit")
    lines.add_argument("--voice")
    lines.add_argument("--line")
    lines.add_argument("--takes", type=int, default=LINE_TAKES)
    paid(vsub.add_parser("ab"))
    return parser


def _voice_of(files: dict[str, VoiceFile], unit: str, voice: str | None) -> None:
    check_id(unit, "unit")
    if unit == CLAN or unit not in files:
        raise CueError(f"unit {unit[:40]!r} has no voices")
    if voice is not None and (check_id(voice, "--voice") not in files[unit].voices):
        raise CueError(f"{unit} has no voice {voice[:40]!r}")


def _dispatch(args: argparse.Namespace, book: CueBook, layers: dict[str, Layer], files: dict[str, VoiceFile], manifest: Manifest,
              get_client: GetClient, raw: Path, fmt: str) -> None:
    command = args.command
    if command == "probe":
        if not (run_probe_music if args.music else run_probe)(manifest, get_client, args.max_credits):
            raise SystemExit(1)
    elif command == "sfx":
        if args.cue is not None:
            ids = [check_id(args.cue, "--cue")]
            if ids[0] not in book.cues:
                raise CueError(f"no cue {ids[0]!r} in the cue book")
        else:
            category = check_id(args.category, "--category")
            ids = sorted(i for i, c in book.cues.items() if c.category == category)
            if category not in cuebook.CATEGORIES or not ids:
                raise CueError(f"no cues in category {category!r}")
        run_jobs(manifest, get_client, raw, fmt, sfx_jobs(book, ids), args.max_credits)
    elif command == "music":
        layer = check_id(args.layer, "layer")
        if layer not in layers:
            raise CueError(f"no music layer {layer!r}")
        run_jobs(manifest, get_client, raw, fmt, music_jobs(layers[layer]), args.max_credits)
    else:
        _voices(args, files, manifest, get_client, raw, fmt)


def _voices(args: argparse.Namespace, files: dict[str, VoiceFile], manifest: Manifest, get_client: GetClient, raw: Path, fmt: str) -> None:
    if args.action == "ab":
        run_jobs(manifest, get_client, raw, fmt, ab_jobs(manifest, files), args.max_credits)
        return
    _voice_of(files, args.unit, args.voice)
    if args.action == "design":
        run_design(manifest, get_client, raw, fmt, args.unit, args.voice, files[args.unit].voices[args.voice].description, args.max_credits, args.again)
    elif args.action == "save":
        run_save(manifest, get_client, fmt, args.unit, args.voice, files[args.unit].voices[args.voice].description, args.pick)
    else:
        known = {**files.get(CLAN, VoiceFile(CLAN, {}, {})).lines, **files[args.unit].lines}
        if args.line is not None and check_id(args.line, "--line") not in known:
            raise CueError(f"{args.unit} has no line {args.line[:40]!r}")
        if not 1 <= args.takes <= cuebook.MAX_TAKE:
            raise CueError(f"--takes is 1 to {cuebook.MAX_TAKE}")
        run_jobs(manifest, get_client, raw, fmt, line_jobs(manifest, files, args.unit, args.voice, args.line, args.takes), args.max_credits)


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if getattr(args, "max_credits", 0) < 0:
        print("generate.py: --max-credits can't be negative", file=sys.stderr)
        return 2
    unsafe = _unsafe_audio_src()
    if unsafe:
        print(f"generate.py: {unsafe}", file=sys.stderr)
        return 2
    try:
        with contextlib.ExitStack() as stack:
            if args.command != "plan":  # plan is free and takes no lock
                stack.enter_context(_locked(_global_lock_path()))  # first: it is the one that sees other checkouts
                stack.enter_context(_locked(AUDIO_SRC / LOCK_NAME))
            return _run(args)
    except (ElevenLabsError, BudgetError, BlockedError, InterruptedRun) as error:
        print(f"generate.py: {error}", file=sys.stderr)
        return 1
    except (CueError, ManifestError, SecretsError, UnsafePath) as error:
        print(f"generate.py: {error}", file=sys.stderr)
        return 2
    except OSError as error:  # the client turns network failures into ElevenLabsError, so this is local file trouble
        print(f"generate.py: {_local_error(error)}", file=sys.stderr)
        return 2 if args.command == "plan" else 1


def _run(args: argparse.Namespace) -> int:
    book = cuebook.load_cues(AUDIO_SRC / "cues.toml")
    layers = cuebook.load_layers(AUDIO_SRC / "music" / "prompts.toml")
    files = cuebook.load_voices(AUDIO_SRC / "voices")
    manifest = Manifest.load(AUDIO_SRC / "manifest.json", allowed=AUDIO_FIELDS)
    fmt = read_format(AUDIO_SRC)
    if args.command == "plan":  # the free command returns before anything looks for the key
        print(plan_text(book, layers, files, manifest, fmt, args.batch, args.show))
        return 0

    def get_client(output_format: str) -> ElevenLabsClient:
        return ElevenLabsClient(http_transport(load_secret("ELEVENLABS_API_KEY")), output_format)

    try:
        _dispatch(args, book, layers, files, manifest, get_client, AUDIO_SRC / "raw", fmt)
    except SystemExit as stop:  # the probe was refused: it has said why
        return int(stop.code or 0) if isinstance(stop.code, int) else 1
    print(f"credits spent so far: {manifest.credits_spent()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
