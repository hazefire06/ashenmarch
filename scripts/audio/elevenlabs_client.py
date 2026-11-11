"""Small ElevenLabs API client: sound effects, voice design, saving a voice, speech and music.

Standard library only. The transport is injected, so tests run without the
network; http_transport is the real one. Nothing here prints or stores the API
key. It travels only in the xi-api-key header, and errors carry the HTTP status
and ElevenLabs' own message (key scrubbed, cut to 200 characters), never the
key. Every call is a paid POST and is never retried. If the request went out
and no usable reply came back, the error says so (may_have_charged). The only
"nothing was sent" cases are a refusal before the socket opens, a failed
certificate check (the TLS handshake, before any request goes out), and a true
4xx other than 408. Redirects are refused, so the key can't follow one.

Fields checked 2026-11-10 against current ElevenLabs API reference pages via
Context7 (/websites/elevenlabs_io), pages under elevenlabs.io/docs/api-reference/:
- text-to-sound-effects/convert: POST /v1/sound-generation. Body text, loop,
  duration_seconds (0.5-30), prompt_influence (0-1), model_id
  (eleven_text_to_sound_v2 | _v3). output_format is a QUERY parameter
  (wav_32000 and mp3_44100_128 are listed). CONFIRMED, same as spec 5.1.
- text-to-voice/design: POST /v1/text-to-voice/design. Body voice_description,
  model_id (eleven_multilingual_ttv_v2 | eleven_ttv_v3; default is the v2, so
  we send eleven_ttv_v3 explicitly). Reply previews[].audio_base_64 and
  .generated_voice_id, plus text. CONFIRMED. DIFFERS FROM SPEC: the docs say
  `text` (100-1000 chars) is optional and auto_generate_text defaults to false,
  so we send auto_generate_text=true to get a preview line. Previews are mp3.
- text-to-voice/create: POST /v1/text-to-voice. Body voice_name,
  voice_description, generated_voice_id. CONFIRMED. UNVERIFIED: the reply's
  `voice_id`. The pages Context7 returned show no response schema; the spec and
  the SDK's Voice model name it voice_id. The probe (spec 11 step 5) settles it.
- text-to-speech/convert: POST /v1/text-to-speech/{voice_id}, body text and
  model_id, output_format a query parameter. CONFIRMED.
- music/compose: POST /v1/music, body prompt, music_length_ms (3000-600000),
  model_id (music_v1|v2|v2_5), force_instrumental. CONFIRMED from the stream and
  compose-detailed pages (same body); output_format as a query parameter on
  /v1/music itself is UNVERIFIED (shown for /v1/music/detailed, default "auto").
"""
from __future__ import annotations

import base64
import binascii
import http.client
import json
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from typing import Any

BASE_URL = "https://api.elevenlabs.io"
PATHS: tuple[re.Pattern[str], ...] = tuple(re.compile(p) for p in (
    r"/v1/sound-generation",
    r"/v1/text-to-voice/design",
    r"/v1/text-to-voice",
    r"/v1/text-to-speech/[A-Za-z0-9]{1,64}",
    r"/v1/music",
))
FORMATS = frozenset({"wav_32000", "mp3_44100_128"})
MAX_AUDIO_BYTES = 64 * 1024 * 1024
MAX_JSON_BYTES = 32 * 1024 * 1024
MAX_ERROR_BYTES = 64 * 1024
AUDIO_TYPES = frozenset({"audio/mpeg", "audio/wav", "audio/x-wav", "audio/wave"})
MAX_PREVIEWS = 10
# Voice ids go into URLs and come from a reply, so they are checked before they are used.
ID = re.compile(r"[A-Za-z0-9]{1,64}")
# A failed handshake means no request was sent, so nothing can have been charged.
CERT_FAILURE = "can't verify ElevenLabs' HTTPS certificate, so nothing was sent. If you use python.org's Python, run its 'Install Certificates.command' once (in /Applications/Python 3.x/)"
CHARGE_WARNING = "; the request may have been charged, so check the usage page on elevenlabs.io before rerunning, or you may pay twice"

Transport = Callable[[str, dict[str, str], dict[str, Any]], tuple[str, bytes]]


class ElevenLabsError(Exception):
    """An ElevenLabs call failed. The message never holds the key. may_have_charged is
    True when the request went out and we got no usable reply, so it may have cost credits."""

    def __init__(self, message: str, may_have_charged: bool = False) -> None:
        super().__init__(message)
        self.may_have_charged = may_have_charged


class _Secret:
    """The API key, wrapped so that nothing which prints a local (a traceback viewer, a debugger, a log of frame locals) shows it.
    It is unwrapped in one place, where the request header is added."""

    __slots__ = ("_value",)

    def __init__(self, value: str) -> None:
        self._value = value

    def __repr__(self) -> str:
        return "[redacted]"

    __str__ = __repr__

    def reveal(self) -> str:
        return self._value

    def scrub(self, text: str) -> str:
        """text with the key replaced, in case the server echoed it back."""
        return text.replace(self._value, "[redacted]")


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    """A redirect would carry the xi-api-key header to another host, so calls refuse
    them: the 3xx surfaces as an HTTPError."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        return None


class ElevenLabsClient:
    def __init__(self, transport: Transport, output_format: str) -> None:
        if output_format not in FORMATS:
            raise ElevenLabsError(f"refusing output format {_safe(output_format, 40)}")
        self._transport = transport
        self._format = output_format

    def sound(self, text: str, duration_s: float, prompt_influence: float, loop: bool, model_id: str) -> bytes:
        if not 0.5 <= duration_s <= 30:
            raise ElevenLabsError("a sound effect is 0.5 to 30 seconds")
        if not 0 <= prompt_influence <= 1:
            raise ElevenLabsError("prompt_influence is 0 to 1")
        body = {"text": text, "duration_seconds": duration_s, "prompt_influence": prompt_influence, "loop": loop, "model_id": model_id}
        return self._audio("/v1/sound-generation", {"output_format": self._format}, body)

    def design(self, description: str, model_id: str = "eleven_ttv_v3") -> list[tuple[str, bytes]]:
        body = {"voice_description": description, "model_id": model_id, "auto_generate_text": True}
        reply = self._json("/v1/text-to-voice/design", {}, body)
        previews = reply.get("previews")
        if not isinstance(previews, list) or not 0 < len(previews) <= MAX_PREVIEWS:
            raise ElevenLabsError("voice design returned no usable previews" + CHARGE_WARNING, may_have_charged=True)
        out: list[tuple[str, bytes]] = []
        for preview in previews:
            voice_id = preview.get("generated_voice_id") if isinstance(preview, dict) else None
            encoded = preview.get("audio_base_64") if isinstance(preview, dict) else None
            if not _valid_id(voice_id) or not isinstance(encoded, str):
                raise ElevenLabsError("voice design returned a preview with a bad id or no audio" + CHARGE_WARNING, may_have_charged=True)
            # base64 grows 4/3, so a string past this length can't decode within the audio cap.
            if len(encoded) > MAX_AUDIO_BYTES * 4 // 3 + 8:
                raise ElevenLabsError("a voice preview is over the size cap" + CHARGE_WARNING, may_have_charged=True)
            try:
                audio = base64.b64decode(encoded, validate=True)
            except (binascii.Error, ValueError):
                raise ElevenLabsError("a voice preview isn't valid base64" + CHARGE_WARNING, may_have_charged=True) from None
            if not _looks_like_audio(audio):
                raise ElevenLabsError("a voice preview isn't audio" + CHARGE_WARNING, may_have_charged=True)
            out.append((voice_id, audio))
        return out

    def save_voice(self, name: str, description: str, generated_voice_id: str) -> str:
        if not _valid_id(generated_voice_id):
            raise ElevenLabsError("refusing malformed generated_voice_id")
        body = {"voice_name": name, "voice_description": description, "generated_voice_id": generated_voice_id}
        voice_id = self._json("/v1/text-to-voice", {}, body).get("voice_id")
        if not _valid_id(voice_id):
            raise ElevenLabsError("saving the voice returned no usable voice_id; the voice may have been created, so check the voice library on elevenlabs.io (Voices) before rerunning, or a duplicate will use another voice slot", may_have_charged=True)
        return voice_id

    def speech(self, voice_id: str, text: str, model_id: str) -> bytes:
        if not _valid_id(voice_id):
            raise ElevenLabsError("refusing malformed voice id")
        return self._audio(f"/v1/text-to-speech/{voice_id}", {"output_format": self._format}, {"text": text, "model_id": model_id})

    def music(self, prompt: str, length_ms: int, model_id: str) -> bytes:
        if not 3000 <= length_ms <= 600000:
            raise ElevenLabsError("music is 3,000 to 600,000 ms")
        body = {"prompt": prompt, "music_length_ms": length_ms, "force_instrumental": True, "model_id": model_id}
        return self._audio("/v1/music", {"output_format": self._format}, body)

    def _audio(self, path: str, query: dict[str, str], body: dict[str, Any]) -> bytes:
        content_type, data = self._transport(path, query, body)
        if content_type not in AUDIO_TYPES:
            raise ElevenLabsError(f"{path}: the reply isn't audio (content type {_safe(content_type, 60)})" + CHARGE_WARNING, may_have_charged=True)
        if len(data) > MAX_AUDIO_BYTES or not _looks_like_audio(data):
            raise ElevenLabsError(f"{path}: the reply doesn't look like audio" + CHARGE_WARNING, may_have_charged=True)
        # A streaming encoder writes 0 or 0xFFFFFFFF in the RIFF size because it can't know the length yet; for those the Content-Length
        # or chunked guard above is the only check. Any other size must match.
        if data[:4] == b"RIFF" and int.from_bytes(data[4:8], "little") not in (0, 0xFFFFFFFF) and int.from_bytes(data[4:8], "little") + 8 != len(data):
            raise ElevenLabsError(f"{path}: the WAV's header length doesn't match the reply, so it was cut short" + CHARGE_WARNING, may_have_charged=True)
        # A reply in another format than the one requested means the format query was ignored or misread.
        if self._format.startswith("wav_") != (data[:4] == b"RIFF"):
            raise ElevenLabsError(f"{path}: the reply's format differs from the requested {self._format}" + CHARGE_WARNING, may_have_charged=True)
        return data

    def _json(self, path: str, query: dict[str, str], body: dict[str, Any]) -> dict[str, Any]:
        content_type, data = self._transport(path, query, body)
        try:
            reply = json.loads(data.decode("utf-8")) if content_type == "application/json" else None
        except (ValueError, RecursionError):  # RecursionError: JSON nested deeper than the parser allows
            reply = None
        if not isinstance(reply, dict):
            raise ElevenLabsError(f"{path}: the reply isn't a JSON object" + CHARGE_WARNING, may_have_charged=True)
        return reply


def _valid_id(value: object) -> bool:
    return isinstance(value, str) and ID.fullmatch(value) is not None


def _looks_like_audio(data: bytes) -> bool:
    """A WAV (RIFF....WAVE), an ID3 tag, or an MP3 frame sync: 0xFF then a byte whose top three bits are set."""
    if (data[:4] == b"RIFF" and data[8:12] == b"WAVE") or data[:3] == b"ID3":
        return True
    return len(data) >= 2 and data[0] == 0xFF and data[1] & 0xE0 == 0xE0


def _safe(text: object, limit: int = 200) -> str:
    """Text that came from the server, cut to limit and escaped if it holds a control character, so it can't redraw the terminal."""
    text = str(text)[:limit]
    return text if text.isprintable() else ascii(text)


def _tls_context() -> ssl.SSLContext:
    """Certificates and hostname verified (the default), TLS 1.2 or newer, and no renegotiation."""
    context = ssl.create_default_context()
    context.options |= ssl.OP_NO_RENEGOTIATION
    return context


def _definite_rejection(status: int) -> bool:
    """A 4xx other than 408: ElevenLabs refused the request, so nothing was charged. A 429 is its rate limiter turning the request away."""
    return 400 <= status < 500 and status != 408


def _lost(path: str) -> str:
    return f"ElevenLabs POST {path}: no reply (timed out or the connection failed)" + CHARGE_WARNING


def _server_message(error: urllib.error.HTTPError, secret: _Secret) -> str:
    """ElevenLabs' own message for an error (detail.message, or detail as a string), with the key scrubbed in case it is echoed back."""
    try:
        detail = json.loads(error.read(MAX_ERROR_BYTES).decode("utf-8")).get("detail", "")
        if isinstance(detail, list):  # a 422: [{"loc", "msg", "type", "input"}]; only msg is used, input can echo request values
            first = detail[0] if detail else None
            detail = {"message": first.get("msg", "")} if isinstance(first, dict) else ""
        message = detail.get("message", "") if isinstance(detail, dict) else detail if isinstance(detail, str) else ""
        return _safe(secret.scrub(str(message))[:200])
    except (ValueError, RecursionError, AttributeError, OSError, http.client.HTTPException):  # no JSON, too deep, or cut off
        return ""


def _content_length(response: Any) -> int | None:
    """The body length the server promised, or None without a usable Content-Length header (digits only, short enough for int())."""
    headers = getattr(response, "headers", None)
    raw = headers.get("Content-Length") if headers is not None else None
    return int(raw) if isinstance(raw, str) and len(raw) <= 15 and raw.isascii() and raw.isdigit() else None


def _content_type(response: Any) -> str:
    headers = getattr(response, "headers", None)
    raw = headers.get("Content-Type") if headers is not None else None
    return raw.split(";", 1)[0].strip().lower() if isinstance(raw, str) else ""


def http_transport(api_key: str, base_url: str = BASE_URL, timeout: float = 120.0) -> Transport:
    if not base_url.startswith("https://"):
        raise ElevenLabsError("refusing a base URL that isn't https")
    if not api_key or not api_key.isascii() or not api_key.isprintable() or any(c.isspace() for c in api_key):
        raise ElevenLabsError("the API key is empty or holds spaces or control characters; check ~/.config/ashenmarch/secrets.env")

    secret = _Secret(api_key)  # from here on only this wrapper is closed over, so no frame's locals hold the bare key
    del api_key
    opener = urllib.request.build_opener(_NoRedirects(), urllib.request.HTTPSHandler(context=_tls_context()))

    def call(path: str, query: dict[str, str], body: dict[str, Any]) -> tuple[str, bytes]:
        try:
            return send(path, query, body)
        except ElevenLabsError as error:
            # `from None` hides the original error from a traceback but it stays in __context__, and it can hold the key.
            error.__context__ = None
            raise error.with_traceback(None)  # drops send's frame (and its locals) from the error

    def send(path: str, query: dict[str, str], body: dict[str, Any]) -> tuple[str, bytes]:
        # Refused before any socket opens: nothing is sent, so nothing is charged.
        if not any(p.fullmatch(path) for p in PATHS):
            raise ElevenLabsError(f"refusing unexpected API path {_safe(path, 80)!r}")
        if set(query) - {"output_format"} or query.get("output_format", "wav_32000") not in FORMATS:
            raise ElevenLabsError("refusing unexpected query parameters or output format")
        url = base_url + path + ("?" + urllib.parse.urlencode(query) if query else "")
        request: urllib.request.Request | None = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), method="POST")
        request.add_header("xi-api-key", secret.reveal())
        request.add_header("Content-Type", "application/json")
        try:
            response = opener.open(request, timeout=timeout)
        except urllib.error.HTTPError as error:
            # Only a true 4xx other than 408 says ElevenLabs refused the request. A 3xx is never followed here and a 408
            # can come from in front of the app, so neither proves nothing was charged.
            unsure = not _definite_rejection(error.code)
            raise ElevenLabsError(
                f"ElevenLabs POST {path} failed: HTTP {error.code} {_server_message(error, secret)}".rstrip() + (CHARGE_WARNING if unsure else ""),
                may_have_charged=unsure,
            ) from None
        except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException) as error:
            # urllib wraps only connect, handshake and send in URLError, so a certificate failure is always pre-send.
            if isinstance(error, urllib.error.URLError) and isinstance(error.reason, ssl.SSLCertVerificationError):
                raise ElevenLabsError(CERT_FAILURE, may_have_charged=False) from None
            raise ElevenLabsError(_lost(path), may_have_charged=True) from None
        finally:
            request = None  # the request holds the key in its headers; an error that isn't ours must not carry it in this frame

        content_type = _content_type(response)
        cap = MAX_JSON_BYTES if content_type == "application/json" else MAX_AUDIO_BYTES
        try:
            with response:
                # Python's ssl reports a missing close_notify as a normal end of stream, so a reply with neither a length nor chunked
                # framing could be cut short and still look whole: a reply that can't show it is whole is a lost one.
                if getattr(response, "length", None) is None and not getattr(response, "chunked", False):
                    raise ElevenLabsError(_lost(path), may_have_charged=True)
                data = response.read(cap + 1)
        except (OSError, ValueError, http.client.HTTPException):  # IncompleteRead: the server dropped the connection mid-reply
            raise ElevenLabsError(_lost(path), may_have_charged=True) from None
        if len(data) > cap:
            raise ElevenLabsError(f"ElevenLabs POST {path}: the reply is over the {cap // (1024 * 1024)} MB cap; refusing" + CHARGE_WARNING, may_have_charged=True)
        # read(n) returns what arrived when the server closes early, without raising: only the length shows a cut-short body.
        expected = _content_length(response)
        if expected is not None and len(data) < expected:
            raise ElevenLabsError(_lost(path), may_have_charged=True)
        return content_type, data

    return call
