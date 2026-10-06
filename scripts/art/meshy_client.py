"""Small Meshy API client: create tasks, wait for them, download results.

Standard library only. The transport and downloader are injected, so tests
run without the network; http_transport and http_downloader are the real
ones. Nothing here prints or stores the API key. Errors carry the HTTP
status and Meshy's message, and tracebacks are cut (``from None``) so the
request, headers included, never appears in one. Downloads are refused
from anywhere but Meshy's asset host, and their errors never repeat the
signed URL.

Endpoints and credit costs: https://docs.meshy.ai/en/api (checked 2026-10-01).
"""
from __future__ import annotations

import json
import shutil
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from pathlib import Path
from typing import Any

BASE_URL = "https://api.meshy.ai"
ALLOWED_DOWNLOAD_HOSTS = frozenset({"assets.meshy.ai"})
PREVIEW_CREDITS: dict[str, int] = {"meshy-6-lite": 5, "meshy-6": 20, "meshy-7.1": 20}
REFINE_CREDITS = 10
RIG_CREDITS = 5
CREDITS_PER_ACTION = 3
MAX_ACTIONS_PER_REQUEST = 10
FAILED_STATUSES = frozenset({"FAILED", "CANCELED", "EXPIRED"})
TASK_PATHS: dict[str, str] = {
    "text-to-3d": "/openapi/v2/text-to-3d",
    "rigging": "/openapi/v1/rigging",
    "animations": "/openapi/v1/animations",
}

Transport = Callable[[str, str, "dict[str, Any] | None"], "dict[str, Any]"]
Downloader = Callable[[str, Path], None]


class MeshyError(Exception):
    """A Meshy call or task failed. The message never holds the key or a signed URL."""


class MeshyClient:
    def __init__(
        self,
        transport: Transport,
        downloader: Downloader,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
        poll_seconds: float = 5.0,
        timeout_seconds: float = 1800.0,
    ) -> None:
        self._transport = transport
        self._downloader = downloader
        self._sleep = sleep
        self._clock = clock
        self._poll = poll_seconds
        self._timeout = timeout_seconds

    def create_preview(self, prompt: str, ai_model: str, polycount: int) -> str:
        return self._create("text-to-3d", {
            "mode": "preview", "prompt": prompt, "ai_model": ai_model, "pose_mode": "a-pose",
            "should_remesh": True, "target_polycount": polycount, "target_formats": ["glb"],
        })

    def create_refine(self, preview_task_id: str) -> str:
        return self._create("text-to-3d", {
            "mode": "refine", "preview_task_id": preview_task_id,
            "texture_resolution": "2k", "target_formats": ["glb"],
        })

    def create_rig(self, input_task_id: str, height_meters: float) -> str:
        return self._create("rigging", {"input_task_id": input_task_id, "height_meters": height_meters})

    def create_animation(self, rig_task_id: str, action_ids: list[int]) -> str:
        if not 1 <= len(action_ids) <= MAX_ACTIONS_PER_REQUEST:
            raise MeshyError(f"an animation request takes 1 to {MAX_ACTIONS_PER_REQUEST} actions, not {len(action_ids)}")
        return self._create("animations", {"rig_task_id": rig_task_id, "action_ids": list(action_ids)})

    def get(self, kind: str, task_id: str) -> dict[str, Any]:
        return self._transport("GET", f"{TASK_PATHS[kind]}/{task_id}", None)

    def wait(self, kind: str, task_id: str) -> dict[str, Any]:
        deadline = self._clock() + self._timeout
        while True:
            task = self.get(kind, task_id)
            status = task.get("status")
            if status == "SUCCEEDED":
                return task
            if status in FAILED_STATUSES:
                reason = (task.get("task_error") or {}).get("message") or "no reason given"
                raise MeshyError(f"{kind} task {task_id} {status}: {reason}")
            if self._clock() >= deadline:
                raise MeshyError(f"{kind} task {task_id} still {status} after {self._timeout:.0f} s; rerun to keep waiting")
            self._sleep(self._poll)

    def download(self, url: str, dest: Path) -> None:
        self._downloader(url, dest)

    def _create(self, kind: str, body: dict[str, Any]) -> str:
        task_id = self._transport("POST", TASK_PATHS[kind], body).get("result")
        if not isinstance(task_id, str) or not task_id:
            raise MeshyError(f"{kind}: Meshy returned no task id")
        return task_id


def http_transport(api_key: str, base_url: str = BASE_URL, timeout: float = 60.0) -> Transport:
    def call(method: str, path: str, body: dict[str, Any] | None) -> dict[str, Any]:
        if not path.startswith("/openapi/"):
            raise MeshyError(f"refusing unexpected API path {path!r}")
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(base_url + path, data=data, method=method)
        request.add_header("Authorization", f"Bearer {api_key}")
        request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as error:
            raise MeshyError(f"Meshy {method} {path} failed: HTTP {error.code} {_server_message(error)}") from None
        except urllib.error.URLError as error:
            raise MeshyError(f"Meshy {method} {path} failed: {error.reason}") from None

    return call


def http_downloader(url: str, dest: Path) -> None:
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or parts.hostname not in ALLOWED_DOWNLOAD_HOSTS:
        raise MeshyError(f"refusing download from {parts.scheme}://{parts.hostname}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    try:
        with urllib.request.urlopen(url, timeout=300) as response, open(part, "wb") as out:
            shutil.copyfileobj(response, out)
    except urllib.error.HTTPError as error:
        part.unlink(missing_ok=True)
        hint = " (Meshy links expire after about 3 days; rerun the paid step)" if error.code in (403, 404) else ""
        raise MeshyError(f"download of {dest.name} failed: HTTP {error.code}{hint}") from None
    except urllib.error.URLError as error:
        part.unlink(missing_ok=True)
        raise MeshyError(f"download of {dest.name} failed: {error.reason}") from None
    part.replace(dest)


def _server_message(error: urllib.error.HTTPError) -> str:
    try:
        return str(json.loads(error.read().decode("utf-8")).get("message", ""))[:200]
    except (ValueError, AttributeError):
        return ""
