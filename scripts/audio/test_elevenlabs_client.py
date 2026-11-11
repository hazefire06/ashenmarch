"""Tests for elevenlabs_client with fake transports and a mocked urllib; nothing touches the network."""
from __future__ import annotations

import base64
import http.client
import io
import json
import ssl
import unittest
import urllib.error
import urllib.request
from typing import Any
from unittest import mock

import elevenlabs_client
from elevenlabs_client import ElevenLabsClient, ElevenLabsError, http_transport

KEY = "FAKEKEY123"
WAV = b"RIFF\x08\x00\x00\x00WAVEfmt "  # the RIFF size field is the file length less 8
MP3 = b"\xff\xfb\x90\x00" + b"\x00" * 16
ID3 = b"ID3\x03\x00\x00\x00\x00\x00\x00"


class FakeTransport:
    def __init__(self, replies: list[Any]) -> None:
        self.replies = list(replies)
        self.calls: list[tuple[str, dict[str, str], dict[str, Any]]] = []

    def __call__(self, path: str, query: dict[str, str], body: dict[str, Any]) -> tuple[str, bytes]:
        self.calls.append((path, query, body))
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply


def json_reply(obj: Any) -> tuple[str, bytes]:
    return "application/json", json.dumps(obj).encode()


class FakeResponse:
    def __init__(self, data: bytes, content_type: str = "audio/wav", content_length: int | str | None = "auto", chunked: bool = False) -> None:  # type: ignore[assignment]
        self._io = io.BytesIO(data)  # read(n) hands back what is there at an early close, like HTTPResponse.read(amt)
        self.headers = {"Content-Type": content_type}
        if content_length == "auto":
            content_length = len(data)
        if content_length is not None:
            self.headers["Content-Length"] = str(content_length)
        # What http.client.HTTPResponse sets: length is the promised body length (None if none or unusable), chunked is truthy for chunked encoding.
        self.length = int(content_length) if isinstance(content_length, int) else None
        self.chunked = chunked

    def read(self, size: int = -1) -> bytes:
        return self._io.read(size)

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None


def http_error(code: int, body: bytes = b"") -> urllib.error.HTTPError:
    return urllib.error.HTTPError("https://api.elevenlabs.io/x", code, "Error", {}, io.BytesIO(body))  # type: ignore[arg-type]


def opener_that(*, returns: Any = None, raises: BaseException | None = None) -> mock.MagicMock:
    opener = mock.MagicMock()
    if raises is not None:
        opener.open.side_effect = raises
    else:
        opener.open.return_value = returns
    return opener


def call_with(opener: mock.MagicMock, path: str = "/v1/sound-generation", query: dict[str, str] | None = None) -> Any:
    with mock.patch.object(elevenlabs_client.urllib.request, "build_opener", return_value=opener):
        return http_transport(KEY)(path, {"output_format": "wav_32000"} if query is None else query, {"text": "x"})


def failure(opener: mock.MagicMock, **kw: Any) -> ElevenLabsError:
    with mock.patch.object(elevenlabs_client.urllib.request, "build_opener", return_value=opener):
        with unittest.TestCase().assertRaises(ElevenLabsError) as caught:
            http_transport(KEY)("/v1/sound-generation", {"output_format": "wav_32000"}, {"text": "x"})
    return caught.exception


class RequestBodyTest(unittest.TestCase):
    def test_sound_body_and_query(self) -> None:
        t = FakeTransport([("audio/wav", WAV)])
        out = ElevenLabsClient(t, "wav_32000").sound("a clang", 2.0, 0.6, False, "eleven_text_to_sound_v2")
        self.assertEqual(out, WAV)
        self.assertEqual(t.calls[0], ("/v1/sound-generation", {"output_format": "wav_32000"}, {
            "text": "a clang", "duration_seconds": 2.0, "prompt_influence": 0.6, "loop": False, "model_id": "eleven_text_to_sound_v2"}))

    def test_speech_and_music(self) -> None:
        t = FakeTransport([("audio/mpeg", MP3), ("audio/mpeg", ID3)])
        c = ElevenLabsClient(t, "mp3_44100_128")
        c.speech("abc123", "Hold!", "eleven_v4")
        c.music("dark drums", 60000, "music_v2")
        self.assertEqual(t.calls[0], ("/v1/text-to-speech/abc123", {"output_format": "mp3_44100_128"}, {"text": "Hold!", "model_id": "eleven_v4"}))
        self.assertEqual(t.calls[1][2], {"prompt": "dark drums", "music_length_ms": 60000, "force_instrumental": True, "model_id": "music_v2"})

    def test_out_of_range_values_never_reach_the_transport(self) -> None:
        t = FakeTransport([])
        c = ElevenLabsClient(t, "wav_32000")
        for fn in (lambda: c.sound("x", 0.4, 0.3, False, "m"), lambda: c.sound("x", 31, 0.3, False, "m"),
                   lambda: c.sound("x", 1, 1.5, False, "m"), lambda: c.music("x", 2999, "m"), lambda: c.music("x", 600001, "m"),
                   lambda: c.speech("../x", "t", "m"), lambda: c.save_voice("n", "d", "../x")):
            with self.assertRaises(ElevenLabsError):
                fn()
        with self.assertRaises(ElevenLabsError):
            ElevenLabsClient(t, "pcm_44100")
        self.assertEqual(t.calls, [])

    def test_save_voice(self) -> None:
        t = FakeTransport([json_reply({"voice_id": "VoiceAbc1"})])
        self.assertEqual(ElevenLabsClient(t, "wav_32000").save_voice("Clan", "gruff", "gen1"), "VoiceAbc1")
        self.assertEqual(t.calls[0], ("/v1/text-to-voice", {}, {"voice_name": "Clan", "voice_description": "gruff", "generated_voice_id": "gen1"}))
        for reply in ({}, {"voice_id": "../x"}, {"voice_id": 5}):
            with self.assertRaises(ElevenLabsError) as caught:
                ElevenLabsClient(FakeTransport([json_reply(reply)]), "wav_32000").save_voice("n", "d", "gen1")
            self.assertTrue(caught.exception.may_have_charged)


class DesignTest(unittest.TestCase):
    def test_design_previews_are_decoded_and_their_ids_checked(self) -> None:
        good = {"previews": [{"generated_voice_id": "gen1", "audio_base_64": base64.b64encode(MP3).decode()},
                             {"generated_voice_id": "gen2", "audio_base_64": base64.b64encode(WAV).decode()}], "text": "hi"}
        t = FakeTransport([json_reply(good)])
        self.assertEqual(ElevenLabsClient(t, "wav_32000").design("a gruff veteran"), [("gen1", MP3), ("gen2", WAV)])
        self.assertEqual(t.calls[0][2]["model_id"], "eleven_ttv_v3")
        self.assertEqual(t.calls[0][2]["voice_description"], "a gruff veteran")
        enc = base64.b64encode(MP3).decode()
        bad = [{"generated_voice_id": "../x", "audio_base_64": enc}, {"generated_voice_id": "", "audio_base_64": enc},
               {"generated_voice_id": 3, "audio_base_64": enc}, {"generated_voice_id": "gen1", "audio_base_64": "!!notbase64"},
               {"generated_voice_id": "gen1", "audio_base_64": base64.b64encode(b"<html>").decode()},
               {"generated_voice_id": "gen1"}, "x"]
        for preview in bad:
            with self.subTest(preview=preview):
                with self.assertRaises(ElevenLabsError) as caught:
                    ElevenLabsClient(FakeTransport([json_reply({"previews": [preview]})]), "wav_32000").design("d")
                self.assertTrue(caught.exception.may_have_charged)
        for previews in ([], None, "x", [good["previews"][0]] * 11):
            with self.assertRaises(ElevenLabsError):
                ElevenLabsClient(FakeTransport([json_reply({"previews": previews})]), "wav_32000").design("d")

    def test_a_design_reply_that_isnt_json_is_refused(self) -> None:
        for reply in (("text/html", b"<html>"), ("application/json", b"[1]"), ("application/json", b"[" * 200000)):
            with self.assertRaises(ElevenLabsError):
                ElevenLabsClient(FakeTransport([reply]), "wav_32000").design("d")


class AudioCheckTest(unittest.TestCase):
    def test_a_reply_that_isnt_audio_is_refused(self) -> None:
        c = lambda r: ElevenLabsClient(FakeTransport([r]), "mp3_44100_128" if r[1][:1] != b"R" else "wav_32000").sound("x", 1, 0.3, False, "m")  # noqa: E731
        for reply in (("application/json", b'{"detail": "oops"}'), ("audio/wav", b'{"detail": "oops"}'),
                      ("audio/wav", b""), ("audio/wav", b"\xff"), ("audio/wav", b"\xff\x1f"), ("audio/wav", b"RIFF\x00\x00\x00\x00AVI "), ("text/html", WAV), ("audio/ogg", WAV)):
            with self.subTest(reply=reply[0], head=reply[1][:6]):
                with self.assertRaises(ElevenLabsError) as caught:
                    c(reply)
                self.assertTrue(caught.exception.may_have_charged)
        for reply in (("audio/wav", WAV), ("audio/x-wav", WAV), ("audio/wave", WAV), ("audio/mpeg", MP3), ("audio/mpeg", ID3)):
            self.assertEqual(c(reply), reply[1])


class TransportTest(unittest.TestCase):
    def test_the_key_goes_in_the_header_and_nowhere_else(self) -> None:
        opener = opener_that(returns=FakeResponse(WAV))
        ctype, data = call_with(opener)
        self.assertEqual((ctype, data), ("audio/wav", WAV))
        request = opener.open.call_args.args[0]
        self.assertEqual(request.get_header("Xi-api-key"), KEY)
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.full_url, "https://api.elevenlabs.io/v1/sound-generation?output_format=wav_32000")
        self.assertNotIn(KEY, request.full_url)
        self.assertNotIn(KEY.encode(), request.data)
        self.assertEqual([k for k, v in request.header_items() if KEY in v], ["Xi-api-key"])

    def test_an_unknown_path_or_format_is_refused_before_sending(self) -> None:
        paths = ("/v1/voices", "/v1/sound-generation/", "/v1/sound-generation?x=1", "/v2/music", "https://evil.example/v1/music",
                 "/v1/text-to-speech/", "/v1/text-to-speech/../x", "/v1/text-to-speech/" + "a" * 65, "/v1/music/detailed", "x/v1/music")
        for path in paths:
            with self.subTest(path=path):
                opener = opener_that(returns=FakeResponse(WAV))
                with self.assertRaisesRegex(ElevenLabsError, "unexpected API path"):
                    call_with(opener, path)
                opener.open.assert_not_called()
        for query in ({"output_format": "pcm_44100"}, {"output_format": "mp3_44100_192"}, {"output_format": "wav_32000&x=1"},
                      {"output_format": "wav_32000", "xi-api-key": "k"}, {"model": "x"}):
            with self.subTest(query=query):
                opener = opener_that(returns=FakeResponse(WAV))
                with self.assertRaisesRegex(ElevenLabsError, "unexpected query"):
                    call_with(opener, query=query)
                opener.open.assert_not_called()
        self.assertEqual(call_with(opener_that(returns=FakeResponse(WAV)), "/v1/text-to-speech/Voice1")[1], WAV)
        self.assertEqual(call_with(opener_that(returns=FakeResponse(b"{}", "application/json")), "/v1/text-to-voice", {})[1], b"{}")

    def test_a_redirect_is_not_followed(self) -> None:
        req = urllib.request.Request("https://api.elevenlabs.io/x")
        self.assertIsNone(elevenlabs_client._NoRedirects().redirect_request(req, None, 302, "Found", {}, "https://evil.example/"))
        opener = urllib.request.build_opener(elevenlabs_client._NoRedirects())
        self.assertTrue(any(isinstance(h, elevenlabs_client._NoRedirects) for h in opener.handlers))
        with mock.patch.object(urllib.request.OpenerDirector, "open", side_effect=http_error(302)):
            with self.assertRaises(ElevenLabsError) as caught:
                http_transport(KEY)("/v1/music", {"output_format": "wav_32000"}, {})
        self.assertTrue(caught.exception.may_have_charged)  # a 3xx isn't proof nothing was charged
        self.assertTrue(any(isinstance(a, elevenlabs_client._NoRedirects) for a in self._build_args()))

    def _build_args(self) -> list[Any]:
        with mock.patch.object(elevenlabs_client.urllib.request, "build_opener", wraps=urllib.request.build_opener) as build:
            http_transport(KEY)
        return list(build.call_args.args)

    def test_a_reply_over_the_cap_is_refused(self) -> None:
        with mock.patch.object(elevenlabs_client, "MAX_AUDIO_BYTES", 10):
            self.assertEqual(call_with(opener_that(returns=FakeResponse(WAV[:10])))[1], WAV[:10])
            response = FakeResponse(WAV + b"x" * 100)
            caught = failure(opener_that(returns=response))
            self.assertLessEqual(response._io.tell(), 11)  # stopped reading at cap + 1
        self.assertTrue(caught.may_have_charged)
        self.assertIn("cap", str(caught))
        with mock.patch.object(elevenlabs_client, "MAX_JSON_BYTES", 10):
            caught = failure(opener_that(returns=FakeResponse(b"{" + b" " * 50 + b"}", "application/json")))
        self.assertIn("cap", str(caught))

    def test_the_caps(self) -> None:
        self.assertEqual(elevenlabs_client.MAX_AUDIO_BYTES, 64 * 1024 * 1024)
        self.assertEqual(elevenlabs_client.MAX_JSON_BYTES, 32 * 1024 * 1024)

    def test_a_definite_rejection_is_not_charged_and_a_lost_reply_may_be(self) -> None:
        for code in (400, 401, 402, 403, 404, 422, 429, 499):
            with self.subTest(code=code):
                caught = failure(opener_that(raises=http_error(code)))
                self.assertFalse(caught.may_have_charged)
                self.assertIn(f"HTTP {code}", str(caught))
                self.assertNotIn("pay twice", str(caught))
        for code in (301, 302, 307, 408, 500, 502, 503):
            with self.subTest(code=code):
                caught = failure(opener_that(raises=http_error(code)))
                self.assertTrue(caught.may_have_charged)
                self.assertIn("pay twice", str(caught))
        lost = (TimeoutError("t"), urllib.error.URLError("down"), urllib.error.URLError(ssl.SSLError("EOF")),
                http.client.IncompleteRead(b"p", 9), http.client.BadStatusLine("x"), ConnectionResetError("r"))
        for error in lost:
            with self.subTest(error=type(error).__name__):
                caught = failure(opener_that(raises=error))
                self.assertTrue(caught.may_have_charged)
                self.assertIsNone(caught.__cause__)
        response = FakeResponse(WAV)
        response.read = mock.MagicMock(side_effect=http.client.IncompleteRead(b"p", 9))  # type: ignore[method-assign]
        self.assertTrue(failure(opener_that(returns=response)).may_have_charged)

    def test_a_certificate_failure_sent_nothing(self) -> None:
        cert = urllib.error.URLError(ssl.SSLCertVerificationError(1, "certificate verify failed"))
        caught = failure(opener_that(raises=cert))
        self.assertFalse(caught.may_have_charged)
        self.assertIn("nothing was sent", str(caught))
        # an unwrapped cert error comes from reading the reply, so it stays "may have charged"
        self.assertTrue(failure(opener_that(raises=ssl.SSLCertVerificationError(1, "x"))).may_have_charged)

    def test_error_messages_never_hold_the_key(self) -> None:
        bodies = (json.dumps({"detail": {"status": "invalid_api_key", "message": f"Bad key {KEY} here"}}).encode(),
                  json.dumps({"detail": f"Bad key {KEY}"}).encode(),
                  json.dumps({"detail": {"message": "x" * 195 + KEY}}).encode())
        for body in bodies:
            with self.subTest(body=body[:30]):
                caught = failure(opener_that(raises=http_error(401, body)))
                self.assertNotIn(KEY, str(caught))
                self.assertNotIn("FAKE", str(caught))
                self.assertLess(len(str(caught)), 300)
                self.assertIsNone(caught.__cause__)
                self.assertTrue(caught.__suppress_context__)
        self.assertIn("HTTP 401 Bad key [redacted] here", str(failure(opener_that(raises=http_error(401, bodies[0])))))
        for error in (http.client.BadStatusLine(f"Bearer {KEY}"), TimeoutError(KEY), urllib.error.URLError(KEY)):
            self.assertNotIn(KEY, str(failure(opener_that(raises=error))))
        with self.assertRaises(ElevenLabsError) as caught:
            http_transport("bad key\n")
        self.assertNotIn("bad key", str(caught.exception))
        with self.assertRaises(ElevenLabsError):
            http_transport("")

    def test_an_error_body_is_cut_and_escaped(self) -> None:
        body = json.dumps({"detail": {"message": "\x1b[31mred\nline" + "y" * 5000}}).encode()
        text = str(failure(opener_that(raises=http_error(402, body))))
        self.assertNotIn("\x1b", text)
        self.assertNotIn("\n", text)
        self.assertLess(len(text), 300)
        for hostile in (b"[" * 200000, b"not json", b'{"detail": 5}', b'{"detail": [{"msg": "x"}]}'):
            caught = failure(opener_that(raises=http_error(402, hostile)))
            self.assertIn("HTTP 402", str(caught))
            self.assertFalse(caught.may_have_charged)

    def test_the_tls_context_verifies_and_is_used(self) -> None:
        ctx = elevenlabs_client._tls_context()
        self.assertTrue(ctx.options & ssl.OP_NO_RENEGOTIATION)
        self.assertEqual(ctx.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(ctx.check_hostname)
        self.assertGreaterEqual(ctx.minimum_version, ssl.TLSVersion.TLSv1_2)
        self.assertIsNot(elevenlabs_client._tls_context(), elevenlabs_client._tls_context())
        handlers = [a for a in self._build_args() if isinstance(a, urllib.request.HTTPSHandler)]
        self.assertEqual(len(handlers), 1)
        self.assertEqual(handlers[0]._context.verify_mode, ssl.CERT_REQUIRED)

    def test_content_type_parameters_are_ignored(self) -> None:
        self.assertEqual(call_with(opener_that(returns=FakeResponse(WAV, "Audio/WAV; charset=binary")))[0], "audio/wav")


class FixRoundTest(unittest.TestCase):
    def test_a_body_shorter_than_its_content_length_is_a_lost_reply(self) -> None:
        caught = failure(opener_that(returns=FakeResponse(WAV, content_length=1000)))
        self.assertTrue(caught.may_have_charged)
        self.assertIn("no reply", str(caught))
        self.assertEqual(call_with(opener_that(returns=FakeResponse(WAV, content_length=len(WAV))))[1], WAV)

    def test_a_reply_with_no_length_and_no_chunking_may_be_cut_short(self) -> None:
        # L2: ssl treats a missing close_notify as a normal end of stream, so only a length or chunked framing shows a cut.
        for header in (None, "abc", "-5", "9" * 5000):
            with self.subTest(header=str(header)[:12]):
                caught = failure(opener_that(returns=FakeResponse(WAV, content_length=header)))
                self.assertTrue(caught.may_have_charged)
                self.assertIn("no reply", str(caught))
        self.assertEqual(call_with(opener_that(returns=FakeResponse(WAV, content_length=None, chunked=True)))[1], WAV)

    def test_a_wav_whose_riff_size_disagrees_with_its_length_is_refused(self) -> None:
        for data in (WAV + b"x", WAV[:-1], b"RIFF\xff\xff\xff\xffWAVEfmt "):
            with self.subTest(length=len(data)):
                with self.assertRaisesRegex(ElevenLabsError, "cut short") as caught:
                    ElevenLabsClient(FakeTransport([("audio/wav", data)]), "wav_32000").music("x", 5000, "m")
                self.assertTrue(caught.exception.may_have_charged)

    def test_the_reply_must_match_the_requested_format(self) -> None:
        for fmt, wrong in (("wav_32000", MP3), ("wav_32000", ID3), ("mp3_44100_128", WAV)):
            with self.subTest(fmt=fmt):
                with self.assertRaisesRegex(ElevenLabsError, "differs from the requested") as caught:
                    ElevenLabsClient(FakeTransport([("audio/mpeg", wrong)]), fmt).music("x", 5000, "m")
                self.assertTrue(caught.exception.may_have_charged)

    def test_a_422_detail_list_gives_its_first_msg_and_never_the_input(self) -> None:
        body = json.dumps({"detail": [{"loc": ["body", "x"], "msg": f"bad {KEY} value", "type": "t", "input": "SECRETINPUT"}]}).encode()
        text = str(failure(opener_that(raises=http_error(422, body))))
        self.assertIn("HTTP 422 bad [redacted] value", text)
        self.assertNotIn("SECRETINPUT", text)
        self.assertNotIn(KEY, text)
        long = json.dumps({"detail": [{"msg": "\x1b" + "m" * 500}]}).encode()
        out = str(failure(opener_that(raises=http_error(422, long))))
        self.assertNotIn("\x1b", out)
        self.assertLess(len(out), 300)
        for odd in ([], ["x"], [{"msg": 5}]):
            self.assertIn("HTTP 422", str(failure(opener_that(raises=http_error(422, json.dumps({"detail": odd}).encode())))))

    def test_a_non_ascii_key_is_refused_up_front(self) -> None:
        with self.assertRaises(ElevenLabsError) as caught:
            http_transport("key\u00e9\u4e2d")
        self.assertNotIn("key\u00e9", str(caught.exception))

    def test_leaks_via_context_are_closed(self) -> None:
        for error in (urllib.error.URLError(KEY), TimeoutError(KEY), http_error(401, b"{}")):
            caught = failure(opener_that(raises=error))
            self.assertIsNone(caught.__context__)

    def test_the_key_is_in_no_traceback_local_of_any_error(self) -> None:
        # L1: a traceback (and so a debugger, or a log that prints locals) can reach every frame's locals, and anything chained to it.
        def reachable(error: BaseException | None) -> list[str]:
            seen: list[str] = []
            while error is not None:
                tb = error.__traceback__
                while tb is not None:
                    seen += [repr(v) for v in tb.tb_frame.f_locals.values()]
                    tb = tb.tb_next
                error = error.__context__ or error.__cause__
            return seen

        cases = [opener_that(raises=urllib.error.URLError(KEY)), opener_that(raises=http_error(401, b"{}")), opener_that(raises=http_error(500, b"{}")),
                 opener_that(returns=FakeResponse(WAV, content_length=1000)), opener_that(returns=FakeResponse(WAV, content_length=None))]
        for opener in cases:
            with self.subTest(opener=opener):
                self.assertFalse([r for r in reachable(failure(opener)) if KEY in r])
        # An error that isn't ours escapes `call` with its traceback, and send's locals must still not hold the key.
        with mock.patch.object(elevenlabs_client.urllib.request, "build_opener", return_value=opener_that(raises=RuntimeError("boom"))):
            with self.assertRaises(RuntimeError) as caught:
                http_transport(KEY)("/v1/sound-generation", {"output_format": "wav_32000"}, {"text": "x"})
        self.assertFalse([r for r in reachable(caught.exception) if KEY in r])

    def test_the_secret_wrapper_never_prints_the_key(self) -> None:
        secret = elevenlabs_client._Secret(KEY)
        for text in (repr(secret), str(secret), f"{secret}", repr([secret]), repr({"k": secret})):
            self.assertNotIn(KEY, text)
        self.assertEqual(secret.reveal(), KEY)
        self.assertEqual(secret.scrub(f"bad {KEY} here"), "bad [redacted] here")

    def test_only_https_base_urls(self) -> None:
        for url in ("http://api.elevenlabs.io", "ftp://x", "api.elevenlabs.io", ""):
            with self.assertRaisesRegex(ElevenLabsError, "https"):
                http_transport(KEY, base_url=url)
        http_transport(KEY, base_url="https://api.elevenlabs.io")

    def test_a_save_without_a_voice_id_says_to_check_the_library(self) -> None:
        with self.assertRaisesRegex(ElevenLabsError, "voice library") as caught:
            ElevenLabsClient(FakeTransport([json_reply({})]), "wav_32000").save_voice("n", "d", "gen1")
        self.assertTrue(caught.exception.may_have_charged)


if __name__ == "__main__":
    unittest.main()
