"""Small Meshy API client: create tasks, wait for them, download results.

Standard library only. The transport and downloader are injected, so tests
run without the network; http_transport and http_downloader are the real
ones. Nothing here prints or stores the API key. Errors carry the HTTP
status and Meshy's message, never the key or a signed URL. Only a GET that
failed in passing is retried, and redirects can't carry the key. A POST with
no usable reply may have created a charged task, so its error says so
(may_have_created) and is never retried. That covers a dropped or garbled
reply (http.client's own exceptions included) and every status except a true
4xx other than 408. The one exception is a failed certificate check:
that is the TLS handshake, before any request goes out, so nothing was sent
and the error says so.

Endpoints and credit costs: https://docs.meshy.ai/en/api (checked 2026-10-01).
"""
from __future__ import annotations

import http.client
import json
import os
import re
import ssl
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
# Meshy refunds only FAILED. A CANCELED or EXPIRED task is not rebought without a human check.
UNREFUNDED_END_STATUSES = frozenset({"CANCELED", "EXPIRED"})
MAX_DOWNLOAD_BYTES = 512 * 1024 * 1024
DOWNLOAD_CHUNK_BYTES = 1024 * 1024
# Task ids go into URLs, and they can come from the committed manifest, which a public PR can edit.
TASK_ID = re.compile(r"[A-Za-z0-9-]{1,64}")
# A failed handshake means no request was sent, so nothing can have been created or charged.
CERT_FAILURE = "can't verify Meshy's HTTPS certificate, so nothing was sent. If you use python.org's Python, run its 'Install Certificates.command' once (in /Applications/Python 3.x/)"
POST_WARNING = "; the task may have been created and charged, so check your API tasks on meshy.ai before rerunning, or you may pay twice"
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
    connection, HTTP 408, 429 or 5xx). may_have_created is True when a POST may have
    created and charged a task on Meshy even though we got no usable reply."""

    def __init__(self, message: str, retryable: bool = False, may_have_created: bool = False) -> None:
        super().__init__(message)
        self.retryable = retryable
        self.may_have_created = may_have_created


class TaskFailed(MeshyError):
    """Meshy says the task itself FAILED. Meshy refunds those, so it is safe to
    buy the work again. Any other MeshyError from wait(), CANCELED and EXPIRED
    included, leaves the task alive and possibly charged: wait again or check
    meshy.ai, never re-buy automatically."""


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

    def create_preview(self, prompt: str, ai_model: str, polycount: int, pose_mode: str | None = "a-pose") -> str:
        """A unit is previewed in an A-pose so it rigs cleanly; a prop passes None and sends no pose at all."""
        body: dict[str, Any] = {"mode": "preview", "prompt": prompt, "ai_model": ai_model}
        if pose_mode is not None:
            body["pose_mode"] = pose_mode
        body.update({"should_remesh": True, "target_polycount": polycount, "target_formats": ["glb"]})
        return self._create("text-to-3d", body)

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
        if not _valid_task_id(task_id):
            raise MeshyError(f"refusing malformed task id for {kind}")
        task = self._transport("GET", f"{TASK_PATHS[kind]}/{task_id}", None)
        if not isinstance(task, dict):  # a garbled reply: retryable, like one that isn't JSON
            raise MeshyError(f"{kind} task reply isn't a JSON object", retryable=True)
        return task

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
            status = status if isinstance(status, str) else None  # a garbled status keeps polling, like a missing one
            if status == "SUCCEEDED":
                return task
            if status == "FAILED" or status in UNREFUNDED_END_STATUSES:
                reason = _task_error(task)
                if status == "FAILED":
                    raise TaskFailed(f"{kind} task {task_id} {status}: {reason}")
                raise MeshyError(f"{kind} task {task_id} {status}: {reason}; check this task on meshy.ai before deciding whether to rebuy")
            if self._clock() >= deadline:
                raise MeshyError(f"{kind} task {task_id} still {_safe(status, 40)} after {self._timeout:.0f} s; rerun to keep waiting")
            self._sleep(self._poll)

    def download(self, url: str, dest: Path) -> None:
        self._downloader(url, dest)

    def _create(self, kind: str, body: dict[str, Any]) -> str:
        reply = self._transport("POST", TASK_PATHS[kind], body)
        if not isinstance(reply, dict):
            raise MeshyError(f"{kind}: Meshy's reply isn't a JSON object" + POST_WARNING, may_have_created=True)
        task_id = reply.get("result")
        if not _valid_task_id(task_id):
            raise MeshyError(f"{kind}: Meshy returned no task id" + POST_WARNING, may_have_created=True)
        return task_id


def _safe(text: object, limit: int = 200) -> str:
    """Text that came from Meshy, cut to limit and escaped if it holds a control character, so it can't redraw the terminal."""
    text = str(text)[:limit]
    return text if text.isprintable() else ascii(text)


def _task_error(task: dict[str, Any]) -> str:
    """Meshy's reason for a failed task, whatever shape task_error arrives in."""
    error = task.get("task_error")
    message = error.get("message") if isinstance(error, dict) else error
    return _safe(message) if isinstance(message, str) and message else "no reason given"


def _valid_task_id(task_id: object) -> bool:
    return isinstance(task_id, str) and TASK_ID.fullmatch(task_id) is not None


def _allowed(url: str) -> bool:
    """Check if a URL is allowed for downloads. A URL that isn't a string, or won't parse, is not."""
    if not isinstance(url, str):
        return False
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError:  # e.g. an unclosed [ in the host
        return False
    return parts.scheme == "https" and parts.hostname in ALLOWED_DOWNLOAD_HOSTS


def _refusal(url: object) -> str:
    """Why a download URL was refused. The URL comes from Meshy's reply, so only its scheme and an escaped, short host are shown."""
    try:
        parts = urllib.parse.urlsplit(url) if isinstance(url, str) else None
    except ValueError:
        parts = None
    if parts is None:
        return "refusing download: malformed URL"
    return f"refusing download from {_safe(parts.scheme, 20)}://{_safe(parts.hostname or '', 80)}"


def _tls_context() -> ssl.SSLContext:
    """Certificates and hostname verified (the default), TLS 1.2 or newer, and no renegotiation."""
    context = ssl.create_default_context()
    context.options |= ssl.OP_NO_RENEGOTIATION
    return context


def http_transport(api_key: str, base_url: str = BASE_URL, timeout: float = 60.0) -> Transport:
    if not api_key or not api_key.isprintable() or any(c.isspace() for c in api_key):
        raise MeshyError("the API key is empty or holds spaces or control characters; check ~/.config/ashenmarch/secrets.env")

    opener = urllib.request.build_opener(_NoRedirects(), urllib.request.HTTPSHandler(context=_tls_context()))

    def call(method: str, path: str, body: dict[str, Any] | None) -> dict[str, Any]:
        if not path.startswith("/openapi/"):
            raise MeshyError(f"refusing unexpected API path {path!r}")
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(base_url + path, data=data, method=method)
        request.add_header("Authorization", f"Bearer {api_key}")
        request.add_header("Content-Type", "application/json")
        # Whenever a POST gets no usable reply, the task may exist on Meshy and be charged.
        posting = method == "POST"
        try:
            response = opener.open(request, timeout=timeout)
        except urllib.error.HTTPError as error:
            # Only a true 4xx other than 408 says Meshy refused the request. A 3xx is never followed here and a 408 can
            # come from in front of the app, so neither proves nothing was created.
            unsure = posting and not _definite_rejection(error.code)
            raise MeshyError(
                f"Meshy {method} {path} failed: HTTP {error.code} {_server_message(error, api_key)}".rstrip() + (POST_WARNING if unsure else ""),
                retryable=(method == "GET" and (error.code in (408, 429) or error.code >= 500)),
                may_have_created=unsure,
            ) from None
        except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException) as error:
            # Only a failed certificate check is known to precede the request; any other SSL error may come after it.
            # This leans on urllib's do_open: it wraps only h.request() (connect, handshake, send) in URLError, so a
            # handshake failure is always pre-send. Errors from getresponse() arrive unwrapped, so they never match
            # here and stay "may have created".
            if isinstance(error, urllib.error.URLError) and isinstance(error.reason, ssl.SSLCertVerificationError):
                raise MeshyError(CERT_FAILURE, retryable=False, may_have_created=False) from None
            raise MeshyError(_lost(method, path), retryable=(method == "GET"), may_have_created=posting) from None

        try:
            with response:
                body_bytes = response.read()
        except (OSError, ValueError, http.client.HTTPException):  # IncompleteRead: the server dropped the connection mid-reply
            raise MeshyError(_lost(method, path), retryable=(method == "GET"), may_have_created=posting) from None

        try:
            reply = json.loads(body_bytes.decode("utf-8") or "{}")
        except (ValueError, RecursionError):  # RecursionError: JSON nested deeper than the parser allows
            raise MeshyError(
                f"Meshy {method} {path} returned a reply that isn't JSON" + (POST_WARNING if posting else ""),
                retryable=(method == "GET"), may_have_created=posting,
            ) from None
        if not isinstance(reply, dict):  # every Meshy reply is an object; a list or a bare string is as unusable as non-JSON
            raise MeshyError(
                f"Meshy {method} {path} returned JSON that isn't an object" + (POST_WARNING if posting else ""),
                retryable=(method == "GET"), may_have_created=posting,
            )
        return reply

    return call


def http_downloader(url: str, dest: Path) -> None:
    if not _allowed(url):
        raise MeshyError(_refusal(url))
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    opener = urllib.request.build_opener(_AllowlistedRedirects(), urllib.request.HTTPSHandler(context=_tls_context()))
    try:
        response = opener.open(url, timeout=300)
    except urllib.error.HTTPError as error:
        part.unlink(missing_ok=True)
        hint = " (Meshy links expire after about 3 days; rerun the paid step)" if error.code in (403, 404) else ""
        raise MeshyError(f"download of {dest.name} failed: HTTP {error.code}{hint}") from None
    except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException):
        part.unlink(missing_ok=True)
        raise MeshyError(f"download of {dest.name} failed: no reply (timed out or the connection failed); rerun to retry") from None

    expected = _content_length(response)  # before the .part is opened, so nothing can be left behind by a bad header
    # O_NOFOLLOW: a symlink planted as the .part would otherwise redirect the write. It isn't ours, so it is left in place.
    try:
        out = os.fdopen(os.open(part, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644), "wb")
    except OSError:
        response.close()
        raise MeshyError(f"download of {dest.name} refused: {part.name} can't be created, or is a symlink; remove it and rerun") from None

    size = 0
    try:
        with response, out:
            while chunk := response.read(DOWNLOAD_CHUNK_BYTES):
                size += len(chunk)
                if size > MAX_DOWNLOAD_BYTES:
                    break
                out.write(chunk)
    except (OSError, ValueError, http.client.HTTPException):
        part.unlink(missing_ok=True)
        raise MeshyError(f"download of {dest.name} failed: no reply (timed out or the connection failed); rerun to retry") from None

    if size > MAX_DOWNLOAD_BYTES:
        part.unlink(missing_ok=True)
        raise MeshyError(f"download of {dest.name} exceeded {MAX_DOWNLOAD_BYTES // (1024 * 1024)} MB; refusing")
    # read(n) returns b"" at a premature end without raising, so a body the server cut short only shows against its length.
    if expected is not None and size < expected:
        part.unlink(missing_ok=True)
        raise MeshyError(f"download of {dest.name} was cut short ({size} of {expected} bytes); rerun to retry")
    part.replace(dest)


def _definite_rejection(status: int) -> bool:
    """A 4xx other than 408: Meshy refused the request, so nothing was created. A 429 is its rate limiter turning the request away."""
    return 400 <= status < 500 and status != 408


def _content_length(response: Any) -> int | None:
    """The body length the server promised, or None when there is no usable Content-Length header. Digits only, and short
    enough that int() can't hit Python's digit limit (15 digits is beyond any file we would accept)."""
    headers = getattr(response, "headers", None)
    raw = headers.get("Content-Length") if headers is not None else None
    return int(raw) if isinstance(raw, str) and len(raw) <= 15 and raw.isascii() and raw.isdigit() else None


def _lost(method: str, path: str) -> str:
    message = f"Meshy {method} {path}: no reply (timed out or the connection failed)"
    return (message + POST_WARNING) if method == "POST" else message


def _server_message(error: urllib.error.HTTPError, api_key: str) -> str:
    """Meshy's own message for an error, with the key scrubbed in case it is echoed back."""
    try:
        return _safe(str(json.loads(error.read().decode("utf-8")).get("message", "")).replace(api_key, "[redacted]")[:200])
    except (ValueError, RecursionError, AttributeError, OSError, http.client.HTTPException):  # no JSON, too deep, or cut off
        return ""
