"""Small Meshy API client: create tasks, wait for them, download results.

Standard library only. The transport and downloader are injected, so tests
run without the network; http_transport and http_downloader are the real
ones. Nothing here prints or stores the API key. Errors carry the HTTP
status and Meshy's message, never the key or a signed URL. Only a GET that
failed in passing is retried, and redirects can't carry the key.

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
MAX_POLL_RETRIES = 3
FAILED_STATUSES = frozenset({"FAILED", "CANCELED", "EXPIRED"})
TASK_PATHS: dict[str, str] = {
    "text-to-3d": "/openapi/v2/text-to-3d",
    "rigging": "/openapi/v1/rigging",
    "animations": "/openapi/v1/animations",
}

Transport = Callable[[str, str, "dict[str, Any] | None"], "dict[str, Any]"]
Downloader = Callable[[str, Path], None]


class MeshyError(Exception):
    """A Meshy call or task failed. The message never holds the key or a signed URL.
    retryable marks a failed GET that is safe to repeat (a timeout, a dropped
    connection, HTTP 429 or 5xx)."""

    def __init__(self, message: str, retryable: bool = False) -> None:
        super().__init__(message)
        self.retryable = retryable


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    """A redirect would carry the Authorization header to another host, so the
    API calls refuse them: the 3xx surfaces as an HTTPError."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        return None


class _AllowlistedRedirects(urllib.request.HTTPRedirectHandler):
    """Downloads may follow a redirect only to another allowed asset host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        return super().redirect_request(req, fp, code, msg, headers, newurl) if _allowed(newurl) else None


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
        failures = 0
        while True:
            try:
                task = self.get(kind, task_id)
            except MeshyError as error:
                failures += 1
                if not error.retryable or failures > MAX_POLL_RETRIES or self._clock() >= deadline:
                    raise
                self._sleep(self._poll)
                continue
            failures = 0
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


def _allowed(url: str) -> bool:
    """Check if a URL is allowed for downloads."""
    parts = urllib.parse.urlsplit(url)
    return parts.scheme == "https" and parts.hostname in ALLOWED_DOWNLOAD_HOSTS


def http_transport(api_key: str, base_url: str = BASE_URL, timeout: float = 60.0) -> Transport:
    if not api_key or not api_key.isprintable() or any(c.isspace() for c in api_key):
        raise MeshyError("the API key is empty or holds spaces or control characters; check ~/.config/ashenmarch/secrets.env")

    opener = urllib.request.build_opener(_NoRedirects())

    def call(method: str, path: str, body: dict[str, Any] | None) -> dict[str, Any]:
        if not path.startswith("/openapi/"):
            raise MeshyError(f"refusing unexpected API path {path!r}")
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(base_url + path, data=data, method=method)
        request.add_header("Authorization", f"Bearer {api_key}")
        request.add_header("Content-Type", "application/json")
        try:
            response = opener.open(request, timeout=timeout)
        except urllib.error.HTTPError as error:
            raise MeshyError(
                f"Meshy {method} {path} failed: HTTP {error.code} {_server_message(error)}",
                retryable=(method == "GET" and (error.code == 429 or error.code >= 500))
            ) from None
        except (urllib.error.URLError, OSError, ValueError):
            raise MeshyError(_lost(method, path), retryable=(method == "GET")) from None

        try:
            with response:
                body_bytes = response.read()
        except (OSError, ValueError):
            raise MeshyError(_lost(method, path), retryable=(method == "GET")) from None

        try:
            return json.loads(body_bytes.decode("utf-8") or "{}")
        except ValueError:
            raise MeshyError(f"Meshy {method} {path} returned a reply that isn't JSON", retryable=(method == "GET")) from None

    return call


def http_downloader(url: str, dest: Path) -> None:
    if not _allowed(url):
        parts = urllib.parse.urlsplit(url)
        raise MeshyError(f"refusing download from {parts.scheme}://{parts.hostname}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    opener = urllib.request.build_opener(_AllowlistedRedirects())
    try:
        response = opener.open(url, timeout=300)
    except urllib.error.HTTPError as error:
        part.unlink(missing_ok=True)
        hint = " (Meshy links expire after about 3 days; rerun the paid step)" if error.code in (403, 404) else ""
        raise MeshyError(f"download of {dest.name} failed: HTTP {error.code}{hint}") from None
    except (urllib.error.URLError, OSError, ValueError):
        part.unlink(missing_ok=True)
        raise MeshyError(f"download of {dest.name} failed: no reply (timed out or the connection failed); rerun to retry") from None

    try:
        with response, open(part, "wb") as out:
            shutil.copyfileobj(response, out)
    except (OSError, ValueError):
        part.unlink(missing_ok=True)
        raise MeshyError(f"download of {dest.name} failed: no reply (timed out or the connection failed); rerun to retry") from None

    part.replace(dest)


def _lost(method: str, path: str) -> str:
    message = f"Meshy {method} {path}: no reply (timed out or the connection failed)"
    if method == "POST":
        message += "; the task may have been created and charged, so check your API tasks on meshy.ai before rerunning, or you may pay twice"
    return message


def _server_message(error: urllib.error.HTTPError) -> str:
    try:
        return str(json.loads(error.read().decode("utf-8")).get("message", ""))[:200]
    except (ValueError, AttributeError):
        return ""
