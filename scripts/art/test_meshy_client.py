"""Tests for meshy_client with fake transports; nothing touches the network."""
from __future__ import annotations

import http.client
import io
import ssl
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from unittest import mock

import meshy_client
from meshy_client import MeshyClient, MeshyError, TaskFailed, http_downloader, http_transport


class FakeTransport:
    def __init__(self, replies: list[Any]) -> None:
        self.replies = list(replies)
        self.calls: list[tuple[str, str, dict[str, Any] | None]] = []

    def __call__(self, method: str, path: str, body: dict[str, Any] | None) -> dict[str, Any]:
        self.calls.append((method, path, body))
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply


def client(transport: FakeTransport, sleeps: list[float] | None = None, now: list[float] | None = None) -> MeshyClient:
    clock = now if now is not None else [0.0]
    slept = sleeps if sleeps is not None else []

    def sleep(seconds: float) -> None:
        slept.append(seconds)
        clock[0] += seconds

    return MeshyClient(transport, lambda url, dest: None, sleep=sleep, clock=lambda: clock[0], poll_seconds=5.0, timeout_seconds=60.0)


def http_error(code: int, body: bytes = b"") -> urllib.error.HTTPError:
    return urllib.error.HTTPError("https://api.meshy.ai/x", code, "Error", {}, io.BytesIO(body))


class FakeResponse(io.BytesIO):
    """What opener.open returns for a download: a readable body, with a Content-Length header when one is given."""

    def __init__(self, data: bytes, content_length: int | str | None = None) -> None:
        super().__init__(data)
        self.headers: dict[str, str] = {} if content_length is None else {"Content-Length": str(content_length)}


class DroppedResponse(io.BytesIO):
    """A body that yields its bytes and then fails the way http.client does when the server drops the connection."""

    def __init__(self, data: bytes, error: BaseException) -> None:
        super().__init__(data)
        self.error = error

    def read(self, size: int | None = -1) -> bytes:
        chunk = super().read(size)
        if chunk:
            return chunk
        raise self.error


def opener_that(*, returns: Any = None, raises: BaseException | None = None) -> mock.MagicMock:
    """A stand-in for the OpenerDirector that build_opener returns."""
    opener = mock.MagicMock()
    if raises is not None:
        opener.open.side_effect = raises
    else:
        opener.open.return_value = returns
    return opener


def reply_with_body(body: bytes) -> mock.MagicMock:
    response = mock.MagicMock()
    response.read.return_value = body
    response.__enter__ = mock.MagicMock(return_value=response)
    response.__exit__ = mock.MagicMock(return_value=None)
    return response


def reply_that_drops(error: BaseException) -> mock.MagicMock:
    response = reply_with_body(b"")
    response.read.side_effect = error
    return response


HTTP_EXCEPTIONS = (
    http.client.IncompleteRead(b"partial", 100),
    http.client.BadStatusLine("garbage"),
    http.client.LineTooLong("status line"),
)


class CreateTest(unittest.TestCase):
    def test_preview_request_and_task_id(self) -> None:
        t = FakeTransport([{"result": "task-1"}])
        self.assertEqual(client(t).create_preview("a clansman", "meshy-6-lite", 30000), "task-1")
        method, path, body = t.calls[0]
        self.assertEqual((method, path), ("POST", "/openapi/v2/text-to-3d"))
        self.assertEqual(body, {
            "mode": "preview", "prompt": "a clansman", "ai_model": "meshy-6-lite",
            "pose_mode": "a-pose", "should_remesh": True, "target_polycount": 30000, "target_formats": ["glb"],
        })

    def test_a_prop_preview_sends_no_pose_mode(self) -> None:
        t = FakeTransport([{"result": "task-1"}])
        client(t).create_preview("a sword", "meshy-6-lite", 6000, pose_mode=None)
        body = t.calls[0][2]
        self.assertNotIn("pose_mode", body)
        self.assertEqual(body, {
            "mode": "preview", "prompt": "a sword", "ai_model": "meshy-6-lite",
            "should_remesh": True, "target_polycount": 6000, "target_formats": ["glb"],
        })

    def test_a_preview_still_defaults_to_an_a_pose(self) -> None:
        t = FakeTransport([{"result": "task-1"}, {"result": "task-2"}])
        c = client(t)
        c.create_preview("a clansman", "meshy-6-lite", 30000)
        c.create_preview("a clansman", "meshy-6-lite", 30000, pose_mode="t-pose")
        self.assertEqual(t.calls[0][2]["pose_mode"], "a-pose")
        self.assertEqual(t.calls[1][2]["pose_mode"], "t-pose")

    def test_rig_and_animation_paths(self) -> None:
        t = FakeTransport([{"result": "r"}, {"result": "a"}])
        c = client(t)
        c.create_rig("refine-1", 1.8)
        c.create_animation("r", [89, 219])
        self.assertEqual(t.calls[0], ("POST", "/openapi/v1/rigging", {"input_task_id": "refine-1", "height_meters": 1.8}))
        self.assertEqual(t.calls[1], ("POST", "/openapi/v1/animations", {"rig_task_id": "r", "action_ids": [89, 219]}))

    def test_animation_needs_one_to_ten_actions(self) -> None:
        c = client(FakeTransport([]))
        with self.assertRaisesRegex(MeshyError, "1 to 10"):
            c.create_animation("r", [])
        with self.assertRaisesRegex(MeshyError, "1 to 10"):
            c.create_animation("r", list(range(11)))

    def test_a_reply_without_an_id_is_an_error(self) -> None:
        with self.assertRaisesRegex(MeshyError, "no task id"):
            client(FakeTransport([{}])).create_refine("p")

    def test_a_reply_without_a_usable_id_warns_that_a_task_may_exist(self) -> None:
        for reply in ({}, {"result": ""}, {"result": 123}, {"result": "x?y"}, {"result": "a/../b"}, {"result": "a" * 65}):
            with self.subTest(reply=reply):
                with self.assertRaises(MeshyError) as caught:
                    client(FakeTransport([reply])).create_refine("p")
                self.assertIn("pay twice", str(caught.exception))
                self.assertTrue(caught.exception.may_have_created)

    def test_a_clean_create_reply_is_accepted(self) -> None:
        self.assertEqual(client(FakeTransport([{"result": "0192-AbC-9"}])).create_refine("p"), "0192-AbC-9")


class TaskIdTest(unittest.TestCase):
    def test_a_malformed_task_id_never_reaches_a_url(self) -> None:
        for bad in ("a/../b", "x?y", "", "a" * 65, "a b", "../x", 7):
            with self.subTest(task_id=bad):
                t = FakeTransport([])
                with self.assertRaisesRegex(MeshyError, "refusing malformed task id for text-to-3d"):
                    client(t).get("text-to-3d", bad)  # type: ignore[arg-type]
                self.assertEqual(t.calls, [])

    def test_wait_refuses_a_malformed_task_id_too(self) -> None:
        t = FakeTransport([])
        with self.assertRaisesRegex(MeshyError, "malformed task id"):
            client(t).wait("rigging", "a/../b")
        self.assertEqual(t.calls, [])


class WaitTest(unittest.TestCase):
    def test_polls_until_it_succeeds(self) -> None:
        sleeps: list[float] = []
        t = FakeTransport([{"status": "PENDING"}, {"status": "IN_PROGRESS"}, {"status": "SUCCEEDED", "consumed_credits": 5}])
        task = client(t, sleeps).wait("text-to-3d", "task-1")
        self.assertEqual(task["consumed_credits"], 5)
        self.assertEqual(sleeps, [5.0, 5.0])
        self.assertEqual(t.calls[0], ("GET", "/openapi/v2/text-to-3d/task-1", None))

    def test_a_failed_task_raises_with_its_reason(self) -> None:
        t = FakeTransport([{"status": "FAILED", "task_error": {"message": "model too complex"}}])
        with self.assertRaisesRegex(TaskFailed, "FAILED: model too complex"):
            client(t).wait("rigging", "r1")

    def test_only_failed_is_refunded_so_only_failed_is_task_failed(self) -> None:
        with self.assertRaises(TaskFailed):
            client(FakeTransport([{"status": "FAILED"}])).wait("rigging", "r1")
        for status in ("CANCELED", "EXPIRED"):
            with self.subTest(status=status):
                t = FakeTransport([{"status": status, "task_error": {"message": "stopped"}}])
                with self.assertRaises(MeshyError) as caught:
                    client(t).wait("rigging", "r1")
                self.assertNotIsInstance(caught.exception, TaskFailed)
                self.assertIn(f"rigging task r1 {status}: stopped", str(caught.exception))
                self.assertIn("check this task on meshy.ai before deciding whether to rebuy", str(caught.exception))
                self.assertEqual(len(t.calls), 1)

    def test_gives_up_after_the_timeout(self) -> None:
        t = FakeTransport([{"status": "IN_PROGRESS"}] * 20)
        with self.assertRaisesRegex(MeshyError, "still IN_PROGRESS") as caught:
            client(t).wait("animations", "a1")
        self.assertNotIsInstance(caught.exception, TaskFailed)


class HttpTest(unittest.TestCase):
    def test_http_errors_carry_status_and_message_but_never_the_key(self) -> None:
        error = urllib.error.HTTPError("https://api.meshy.ai/x", 402, "Payment Required", {}, io.BytesIO(b'{"message": "Insufficient credits"}'))
        with mock.patch.object(meshy_client.urllib.request.OpenerDirector, "open", side_effect=error):
            call = http_transport("not-a-real-key")
            with self.assertRaises(MeshyError) as caught:
                call("POST", "/openapi/v2/text-to-3d", {"mode": "preview"})
        message = str(caught.exception)
        self.assertIn("HTTP 402", message)
        self.assertIn("Insufficient credits", message)
        self.assertNotIn("not-a-real-key", message)
        self.assertIsNone(caught.exception.__cause__)
        self.assertTrue(caught.exception.__suppress_context__)

    def test_the_transport_only_calls_the_api_paths(self) -> None:
        with self.assertRaisesRegex(MeshyError, "unexpected API path"):
            http_transport("k")("GET", "https://elsewhere.example/x", None)

    def test_downloads_only_come_from_meshy_assets(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(MeshyError, "refusing download"):
                http_downloader("https://evil.example/model.glb", Path(tmp) / "m.glb")

    def test_an_expired_link_says_what_to_do_without_the_url(self) -> None:
        url = "https://assets.meshy.ai/t/model.glb?Expires=1&Signature=SECRETSIG"
        error = urllib.error.HTTPError(url, 403, "Forbidden", {}, io.BytesIO(b""))
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(meshy_client.urllib.request.OpenerDirector, "open", side_effect=error):
            with self.assertRaises(MeshyError) as caught:
                http_downloader(url, Path(tmp) / "m.glb")
            self.assertFalse((Path(tmp) / "m.glb.part").exists())
        self.assertIn("expire", str(caught.exception))
        self.assertNotIn("SECRETSIG", str(caught.exception))

    def test_a_malformed_key_is_refused_without_echoing_it(self) -> None:
        with self.assertRaisesRegex(MeshyError, "empty|spaces|control"):
            http_transport("FAKEKEY123\n")
        with self.assertRaisesRegex(MeshyError, "empty|spaces|control"):
            http_transport("bad key")

    def test_a_lost_create_warns_about_paying_twice(self) -> None:
        mock_open = mock.MagicMock()
        mock_open.open.side_effect = TimeoutError("timed out")
        with mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=mock_open):
            call = http_transport("k")
            with self.assertRaises(MeshyError) as caught:
                call("POST", "/openapi/v2/text-to-3d", {"mode": "preview"})
            self.assertIn("pay twice", str(caught.exception))
            self.assertFalse(caught.exception.retryable)
            with self.assertRaises(MeshyError) as caught:
                call("GET", "/openapi/v2/text-to-3d/t1", None)
            self.assertTrue(caught.exception.retryable)
            self.assertNotIn("pay twice", str(caught.exception))

    def test_a_reply_that_is_not_json_is_a_meshy_error(self) -> None:
        mock_response = mock.MagicMock()
        mock_response.read.return_value = b"<html>"
        mock_response.__enter__ = mock.MagicMock(return_value=mock_response)
        mock_response.__exit__ = mock.MagicMock(return_value=None)
        mock_opener = mock.MagicMock()
        mock_opener.open.return_value = mock_response
        with mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=mock_opener):
            call = http_transport("k")
            with self.assertRaises(MeshyError) as caught:
                call("GET", "/openapi/v2/text-to-3d/t1", None)
            self.assertIn("isn't JSON", str(caught.exception))

    def test_a_post_that_got_a_5xx_may_have_created_a_task(self) -> None:
        errors = [http_error(503), http_error(503)]
        with mock.patch.object(meshy_client.urllib.request.OpenerDirector, "open", side_effect=errors):
            call = http_transport("not-a-real-key")
            with self.assertRaises(MeshyError) as caught:
                call("POST", "/openapi/v2/text-to-3d", {"mode": "preview"})
            self.assertIn("pay twice", str(caught.exception))
            self.assertIn("HTTP 503", str(caught.exception))
            self.assertTrue(caught.exception.may_have_created)
            self.assertFalse(caught.exception.retryable)
            with self.assertRaises(MeshyError) as caught:
                call("GET", "/openapi/v2/text-to-3d/t1", None)
            self.assertTrue(caught.exception.retryable)
            self.assertFalse(caught.exception.may_have_created)
            self.assertNotIn("pay twice", str(caught.exception))

    def test_a_rejected_post_did_not_create_a_task(self) -> None:
        # Only a true 4xx other than 408 and 429 says Meshy refused the request outright (see StatusTest).
        for code in (400, 401, 402, 403, 404, 422):
            with self.subTest(code=code):
                with mock.patch.object(meshy_client.urllib.request.OpenerDirector, "open", side_effect=http_error(code)):
                    with self.assertRaises(MeshyError) as caught:
                        http_transport("not-a-real-key")("POST", "/openapi/v2/text-to-3d", {})
                self.assertFalse(caught.exception.may_have_created)
                self.assertNotIn("pay twice", str(caught.exception))

    def test_a_lost_post_may_have_created_a_task(self) -> None:
        mock_opener = mock.MagicMock()
        mock_opener.open.side_effect = TimeoutError("timed out")
        with mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=mock_opener):
            with self.assertRaises(MeshyError) as caught:
                http_transport("k")("POST", "/openapi/v2/text-to-3d", {})
        self.assertIn("pay twice", str(caught.exception))
        self.assertTrue(caught.exception.may_have_created)

    def test_a_certificate_failure_on_a_post_sent_nothing(self) -> None:
        # Seen for real on 2026-10-06 with python.org's Python: the handshake failed, so no request left the machine.
        cert = urllib.error.URLError(ssl.SSLCertVerificationError(1, "certificate verify failed: unable to get local issuer certificate"))
        with mock.patch.object(meshy_client.urllib.request.OpenerDirector, "open", side_effect=cert):
            with self.assertRaises(MeshyError) as caught:
                http_transport("not-a-real-key")("POST", "/openapi/v2/text-to-3d", {"mode": "preview"})
        self.assertFalse(caught.exception.may_have_created)
        self.assertFalse(caught.exception.retryable)
        self.assertIn("nothing was sent", str(caught.exception))
        self.assertIn("Install Certificates", str(caught.exception))
        self.assertNotIn("pay twice", str(caught.exception))
        self.assertNotIn("not-a-real-key", str(caught.exception))

    def test_a_certificate_failure_is_not_retried_on_a_get(self) -> None:
        # Retrying can't fix a missing local certificate, so wait() should give up at once.
        cert = urllib.error.URLError(ssl.SSLCertVerificationError(1, "certificate verify failed"))
        with mock.patch.object(meshy_client.urllib.request.OpenerDirector, "open", side_effect=cert):
            with self.assertRaises(MeshyError) as caught:
                http_transport("k")("GET", "/openapi/v2/text-to-3d/t1", None)
        self.assertFalse(caught.exception.retryable)
        self.assertFalse(caught.exception.may_have_created)
        self.assertIn("Install Certificates", str(caught.exception))

    def test_other_ssl_errors_on_a_post_may_have_created_a_task(self) -> None:
        # Only a failed certificate check is known to happen before the request goes out.
        for reason in (ssl.SSLError("EOF occurred in violation of protocol"), ssl.SSLZeroReturnError("closed")):
            with self.subTest(reason=type(reason).__name__):
                with mock.patch.object(meshy_client.urllib.request.OpenerDirector, "open", side_effect=urllib.error.URLError(reason)):
                    with self.assertRaises(MeshyError) as caught:
                        http_transport("k")("POST", "/openapi/v2/text-to-3d", {})
                self.assertTrue(caught.exception.may_have_created)
                self.assertIn("pay twice", str(caught.exception))

    def test_a_plain_url_error_on_a_post_may_have_created_a_task(self) -> None:
        with mock.patch.object(meshy_client.urllib.request.OpenerDirector, "open", side_effect=urllib.error.URLError("down")):
            with self.assertRaises(MeshyError) as caught:
                http_transport("k")("POST", "/openapi/v2/text-to-3d", {})
        self.assertTrue(caught.exception.may_have_created)
        self.assertIn("pay twice", str(caught.exception))

    def test_a_post_reply_that_is_not_json_may_have_created_a_task(self) -> None:
        mock_response = mock.MagicMock()
        mock_response.read.return_value = b"<html>"
        mock_response.__enter__ = mock.MagicMock(return_value=mock_response)
        mock_response.__exit__ = mock.MagicMock(return_value=None)
        mock_opener = mock.MagicMock()
        mock_opener.open.return_value = mock_response
        with mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=mock_opener):
            call = http_transport("k")
            with self.assertRaises(MeshyError) as caught:
                call("POST", "/openapi/v2/text-to-3d", {})
            self.assertIn("isn't JSON", str(caught.exception))
            self.assertIn("pay twice", str(caught.exception))
            self.assertTrue(caught.exception.may_have_created)
            self.assertFalse(caught.exception.retryable)
            with self.assertRaises(MeshyError) as caught:
                call("GET", "/openapi/v2/text-to-3d/t1", None)
            self.assertTrue(caught.exception.retryable)
            self.assertFalse(caught.exception.may_have_created)
            self.assertNotIn("pay twice", str(caught.exception))

    def test_a_server_message_echoing_the_key_is_scrubbed(self) -> None:
        with mock.patch.object(meshy_client.urllib.request.OpenerDirector, "open",
                               side_effect=http_error(401, b'{"message": "Invalid API key FAKEKEY123 for this account"}')):
            with self.assertRaises(MeshyError) as caught:
                http_transport("FAKEKEY123")("GET", "/openapi/v2/text-to-3d/t1", None)
        self.assertIn("HTTP 401 Invalid API key [redacted] for this account", str(caught.exception))
        self.assertNotIn("FAKEKEY123", str(caught.exception))

    def test_the_key_is_scrubbed_before_the_message_is_cut_short(self) -> None:
        body = ('{"message": "' + "x" * 195 + 'FAKEKEY123"}').encode()
        with mock.patch.object(meshy_client.urllib.request.OpenerDirector, "open", side_effect=http_error(401, body)):
            with self.assertRaises(MeshyError) as caught:
                http_transport("FAKEKEY123")("GET", "/openapi/v2/text-to-3d/t1", None)
        self.assertNotIn("FAKE", str(caught.exception))

    def test_a_download_over_the_cap_is_refused_and_leaves_no_partial_file(self) -> None:
        url = "https://assets.meshy.ai/t/model.glb?Expires=1&Signature=SECRETSIG"
        mock_opener = mock.MagicMock()
        mock_opener.open.return_value = io.BytesIO(b"x" * 25)
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(meshy_client, "MAX_DOWNLOAD_BYTES", 10), \
                mock.patch.object(meshy_client, "DOWNLOAD_CHUNK_BYTES", 4), \
                mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=mock_opener):
            dest = Path(tmp) / "m.glb"
            with self.assertRaisesRegex(MeshyError, "download of m.glb exceeded .* MB; refusing") as caught:
                http_downloader(url, dest)
            self.assertFalse(dest.exists())
            self.assertFalse((Path(tmp) / "m.glb.part").exists())
        self.assertNotIn("SECRETSIG", str(caught.exception))

    def test_a_download_at_the_cap_is_kept(self) -> None:
        url = "https://assets.meshy.ai/t/model.glb"
        mock_opener = mock.MagicMock()
        mock_opener.open.return_value = io.BytesIO(b"x" * 10)
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(meshy_client, "MAX_DOWNLOAD_BYTES", 10), \
                mock.patch.object(meshy_client, "DOWNLOAD_CHUNK_BYTES", 4), \
                mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=mock_opener):
            dest = Path(tmp) / "m.glb"
            http_downloader(url, dest)
            self.assertEqual(dest.read_bytes(), b"x" * 10)
            self.assertFalse((Path(tmp) / "m.glb.part").exists())

    def test_a_symlinked_part_file_is_refused_and_its_target_is_left_alone(self) -> None:
        url = "https://assets.meshy.ai/t/model.glb?Expires=1&Signature=SECRETSIG"
        mock_opener = mock.MagicMock()
        mock_opener.open.return_value = io.BytesIO(b"model bytes")
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=mock_opener):
            target = Path(tmp) / "precious.txt"
            target.write_text("keep me")
            dest = Path(tmp) / "work" / "m.glb"
            dest.parent.mkdir()
            (dest.parent / "m.glb.part").symlink_to(target)
            with self.assertRaisesRegex(MeshyError, "download of m.glb refused") as caught:
                http_downloader(url, dest)
            self.assertEqual(target.read_text(), "keep me")
            self.assertFalse(dest.exists())
            self.assertTrue((dest.parent / "m.glb.part").is_symlink())  # not ours to delete
        self.assertNotIn("SECRETSIG", str(caught.exception))

    def test_a_stale_regular_part_file_is_overwritten_by_a_download(self) -> None:
        mock_opener = mock.MagicMock()
        mock_opener.open.return_value = io.BytesIO(b"fresh")
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=mock_opener):
            dest = Path(tmp) / "m.glb"
            (Path(tmp) / "m.glb.part").write_bytes(b"stale and longer than the new bytes")
            http_downloader("https://assets.meshy.ai/t/model.glb", dest)
            self.assertEqual(dest.read_bytes(), b"fresh")

    def test_the_download_cap_is_512_mib(self) -> None:
        self.assertEqual(meshy_client.MAX_DOWNLOAD_BYTES, 512 * 1024 * 1024)

    def test_api_calls_refuse_redirects(self) -> None:
        req = urllib.request.Request("https://api.meshy.ai/x")
        result = meshy_client._NoRedirects().redirect_request(req, None, 302, "Found", {}, "https://evil.example/")
        self.assertIsNone(result)

    def test_downloads_follow_redirects_only_to_allowed_hosts(self) -> None:
        req = urllib.request.Request("https://assets.meshy.ai/m.glb")
        result = meshy_client._AllowlistedRedirects().redirect_request(req, None, 302, "Found", {}, "https://evil.example/m.glb")
        self.assertIsNone(result)
        result = meshy_client._AllowlistedRedirects().redirect_request(req, None, 302, "Found", {}, "https://assets.meshy.ai/other.glb")
        self.assertIsNotNone(result)


class TlsTest(unittest.TestCase):
    """The TLS context is built explicitly: certificates verified, no renegotiation, TLS 1.2 or newer."""

    def https_handlers(self, build_opener: mock.MagicMock) -> list[urllib.request.HTTPSHandler]:
        return [a for call in build_opener.call_args_list for a in call.args if isinstance(a, urllib.request.HTTPSHandler)]

    def test_the_context_verifies_certificates_and_refuses_renegotiation(self) -> None:
        ctx = meshy_client._tls_context()
        self.assertTrue(ctx.options & ssl.OP_NO_RENEGOTIATION)
        self.assertEqual(ctx.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(ctx.check_hostname)
        self.assertGreaterEqual(ctx.minimum_version, ssl.TLSVersion.TLSv1_2)

    def test_a_context_is_never_shared_between_calls(self) -> None:
        self.assertIsNot(meshy_client._tls_context(), meshy_client._tls_context())

    def test_the_transport_uses_that_context(self) -> None:
        with mock.patch.object(meshy_client.urllib.request, "build_opener", wraps=urllib.request.build_opener) as build_opener:
            http_transport("k")
        handlers = self.https_handlers(build_opener)
        self.assertEqual(len(handlers), 1)
        self.assertTrue(handlers[0]._context.options & ssl.OP_NO_RENEGOTIATION)
        self.assertEqual(handlers[0]._context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(any(isinstance(a, meshy_client._NoRedirects) for a in build_opener.call_args.args))

    def test_the_downloader_uses_that_context(self) -> None:
        url = "https://assets.meshy.ai/t/model.glb"
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(meshy_client.urllib.request, "build_opener", wraps=urllib.request.build_opener) as build_opener, \
                mock.patch.object(meshy_client.urllib.request.OpenerDirector, "open", side_effect=http_error(404)):
            with self.assertRaises(MeshyError):
                http_downloader(url, Path(tmp) / "m.glb")
        handlers = self.https_handlers(build_opener)
        self.assertEqual(len(handlers), 1)
        self.assertTrue(handlers[0]._context.options & ssl.OP_NO_RENEGOTIATION)
        self.assertTrue(any(isinstance(a, meshy_client._AllowlistedRedirects) for a in build_opener.call_args.args))

    def test_only_an_error_from_connecting_is_called_a_certificate_failure(self) -> None:
        # urllib wraps only connect, handshake and send in URLError, so an error from reading
        # the reply arrives unwrapped and must stay "may have created".
        mock_opener = mock.MagicMock()
        mock_opener.open.side_effect = ssl.SSLCertVerificationError(1, "certificate verify failed")
        with mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=mock_opener):
            with self.assertRaises(MeshyError) as caught:
                http_transport("k")("POST", "/openapi/v2/text-to-3d", {})
        self.assertTrue(caught.exception.may_have_created)


class WaitRetryTest(unittest.TestCase):
    def test_wait_retries_a_blip(self) -> None:
        sleeps: list[float] = []
        t = FakeTransport([MeshyError("blip", retryable=True), {"status": "SUCCEEDED"}])
        task = client(t, sleeps).wait("text-to-3d", "task-1")
        self.assertEqual(task["status"], "SUCCEEDED")
        self.assertEqual(sleeps, [5.0])

    def test_wait_gives_up_after_repeated_blips(self) -> None:
        t = FakeTransport([
            MeshyError("blip1", retryable=True),
            MeshyError("blip2", retryable=True),
            MeshyError("blip3", retryable=True),
            MeshyError("blip4", retryable=True),
        ])
        with self.assertRaises(MeshyError) as caught:
            client(t).wait("text-to-3d", "task-1")
        self.assertIn("blip4", str(caught.exception))

    def test_wait_does_not_retry_a_real_error(self) -> None:
        sleeps: list[float] = []
        t = FakeTransport([MeshyError("HTTP 401", retryable=False)])
        with self.assertRaises(MeshyError) as caught:
            client(t, sleeps).wait("text-to-3d", "task-1")
        self.assertEqual(sleeps, [])
        self.assertIn("HTTP 401", str(caught.exception))


class DroppedReplyTest(unittest.TestCase):
    """http.client's own exceptions (IncompleteRead, BadStatusLine, LineTooLong) are a lost reply like any other."""

    def call(self, opener: mock.MagicMock, method: str) -> MeshyError:
        with mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=opener):
            path = "/openapi/v2/text-to-3d" + ("" if method == "POST" else "/t1")
            with self.assertRaises(MeshyError) as caught:
                http_transport("not-a-real-key")(method, path, {} if method == "POST" else None)
        return caught.exception

    def test_a_post_whose_reply_dropped_may_have_created_a_task(self) -> None:
        for error in HTTP_EXCEPTIONS:
            for stage, opener in (("opening", opener_that(raises=error)), ("reading", opener_that(returns=reply_that_drops(error)))):
                with self.subTest(error=type(error).__name__, stage=stage):
                    caught = self.call(opener, "POST")
                    self.assertTrue(caught.may_have_created)
                    self.assertFalse(caught.retryable)
                    self.assertIn("pay twice", str(caught))
                    self.assertIsNone(caught.__cause__)
                    self.assertTrue(caught.__suppress_context__)

    def test_a_get_whose_reply_dropped_is_retryable(self) -> None:
        for error in HTTP_EXCEPTIONS:
            for stage, opener in (("opening", opener_that(raises=error)), ("reading", opener_that(returns=reply_that_drops(error)))):
                with self.subTest(error=type(error).__name__, stage=stage):
                    caught = self.call(opener, "GET")
                    self.assertTrue(caught.retryable)
                    self.assertFalse(caught.may_have_created)
                    self.assertNotIn("pay twice", str(caught))

    def test_an_error_body_that_drops_mid_read_still_gives_the_status(self) -> None:
        # The server answered 503 and then dropped the connection while the body was read for Meshy's message.
        for error in (*HTTP_EXCEPTIONS, TimeoutError("timed out"), ConnectionResetError("reset")):
            for method in ("POST", "GET"):
                with self.subTest(error=type(error).__name__, method=method):
                    body = mock.MagicMock()
                    body.read.side_effect = error
                    refusal = urllib.error.HTTPError("https://api.meshy.ai/x", 503, "Unavailable", {}, body)
                    caught = self.call(opener_that(raises=refusal), method)
                    self.assertIn("HTTP 503", str(caught))
                    self.assertEqual(caught.may_have_created, method == "POST")
                    self.assertEqual(caught.retryable, method == "GET")

    def test_the_error_text_never_carries_what_the_exception_held(self) -> None:
        caught = self.call(opener_that(raises=http.client.BadStatusLine("Bearer not-a-real-key")), "GET")
        self.assertNotIn("not-a-real-key", str(caught))

    def test_wait_carries_on_past_one_dropped_reply(self) -> None:
        # A single IncompleteRead used to end a long wait with a traceback.
        opener = mock.MagicMock()
        opener.open.side_effect = [
            reply_that_drops(http.client.IncompleteRead(b"{", 50)),
            reply_with_body(b'{"status": "SUCCEEDED", "consumed_credits": 5}'),
        ]
        slept: list[float] = []
        with mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=opener):
            waiting = MeshyClient(http_transport("k"), lambda url, dest: None, sleep=slept.append, clock=lambda: 0.0, poll_seconds=5.0)
            task = waiting.wait("text-to-3d", "task-1")
        self.assertEqual(task["consumed_credits"], 5)
        self.assertEqual(slept, [5.0])


class DownloadDropTest(unittest.TestCase):
    URL = "https://assets.meshy.ai/t/model.glb?Expires=1&Signature=SECRETSIG"

    def download(self, tmp: str, opener: mock.MagicMock) -> MeshyError:
        with mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=opener):
            with self.assertRaises(MeshyError) as caught:
                http_downloader(self.URL, Path(tmp) / "m.glb")
        return caught.exception

    def assert_nothing_left(self, tmp: str, caught: MeshyError) -> None:
        self.assertFalse((Path(tmp) / "m.glb").exists())
        self.assertFalse((Path(tmp) / "m.glb.part").exists())
        self.assertIn("m.glb", str(caught))
        for leaked in ("SECRETSIG", "assets.meshy.ai", "https://"):
            self.assertNotIn(leaked, str(caught))

    def test_a_connection_dropped_before_the_body_names_the_file_only(self) -> None:
        for error in HTTP_EXCEPTIONS:
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as tmp:
                (Path(tmp) / "m.glb.part").write_bytes(b"half")  # a stale part from an earlier try
                caught = self.download(tmp, opener_that(raises=error))
                self.assert_nothing_left(tmp, caught)

    def test_a_connection_dropped_mid_body_deletes_the_part(self) -> None:
        for error in HTTP_EXCEPTIONS:
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as tmp:
                caught = self.download(tmp, opener_that(returns=DroppedResponse(b"some of the model", error)))
                self.assert_nothing_left(tmp, caught)
                self.assertIn("rerun", str(caught))

    def test_a_body_shorter_than_its_content_length_is_cut_short(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            caught = self.download(tmp, opener_that(returns=FakeResponse(b"x" * 10, content_length=25)))
            self.assert_nothing_left(tmp, caught)
            self.assertIn("download of m.glb was cut short", str(caught))

    def test_a_body_that_matches_its_content_length_is_kept(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=opener_that(returns=FakeResponse(b"x" * 10, content_length=10))):
            http_downloader(self.URL, Path(tmp) / "m.glb")
            self.assertEqual((Path(tmp) / "m.glb").read_bytes(), b"x" * 10)
            self.assertFalse((Path(tmp) / "m.glb.part").exists())

    def test_a_missing_or_unreadable_content_length_is_not_a_reason_to_refuse(self) -> None:
        for header in (None, "", "abc", "-5", "1e3"):
            with self.subTest(content_length=header), tempfile.TemporaryDirectory() as tmp, \
                    mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=opener_that(returns=FakeResponse(b"x" * 10, header))):
                http_downloader(self.URL, Path(tmp) / "m.glb")
                self.assertEqual((Path(tmp) / "m.glb").read_bytes(), b"x" * 10)


class StatusAndShapeTest(unittest.TestCase):
    """Task 9's deferred items: which HTTP statuses prove a POST created nothing, and replies that aren't JSON objects."""

    def post(self, code: int) -> MeshyError:
        with mock.patch.object(meshy_client.urllib.request.OpenerDirector, "open", side_effect=http_error(code)):
            with self.assertRaises(MeshyError) as caught:
                http_transport("not-a-real-key")("POST", "/openapi/v2/text-to-3d", {})
        return caught.exception

    def test_a_3xx_408_or_429_reply_to_a_post_may_have_created_a_task(self) -> None:
        # No redirect is followed and 408 and 429 come from in front of the app, so none of them proves the task wasn't made.
        for code in (301, 302, 303, 307, 308, 408, 429, 500, 502, 503, 504):
            with self.subTest(code=code):
                caught = self.post(code)
                self.assertTrue(caught.may_have_created)
                self.assertIn("pay twice", str(caught))
                self.assertFalse(caught.retryable)

    def test_only_a_true_4xx_other_than_408_and_429_is_a_definite_rejection(self) -> None:
        for code in (400, 401, 402, 403, 404, 405, 409, 413, 422, 451, 499):
            with self.subTest(code=code):
                caught = self.post(code)
                self.assertFalse(caught.may_have_created)
                self.assertNotIn("pay twice", str(caught))

    def test_a_get_with_those_statuses_never_claims_a_task_was_created(self) -> None:
        for code in (302, 408, 429, 503):
            with self.subTest(code=code), mock.patch.object(meshy_client.urllib.request.OpenerDirector, "open", side_effect=http_error(code)):
                with self.assertRaises(MeshyError) as caught:
                    http_transport("k")("GET", "/openapi/v2/text-to-3d/t1", None)
                self.assertFalse(caught.exception.may_have_created)
                self.assertNotIn("pay twice", str(caught.exception))
                self.assertEqual(caught.exception.retryable, code in (429, 503))

    NOT_OBJECTS = (b"[]", b'"x"', b"3", b"null", b"true", b'[{"result": "task-1"}]')

    def test_the_transport_refuses_a_reply_that_is_not_a_json_object(self) -> None:
        for body in self.NOT_OBJECTS:
            opener = opener_that(returns=reply_with_body(body))
            with self.subTest(body=body), mock.patch.object(meshy_client.urllib.request, "build_opener", return_value=opener):
                call = http_transport("k")
                with self.assertRaises(MeshyError) as caught:
                    call("POST", "/openapi/v2/text-to-3d", {})
                self.assertTrue(caught.exception.may_have_created)
                self.assertIn("pay twice", str(caught.exception))
                with self.assertRaises(MeshyError) as caught:
                    call("GET", "/openapi/v2/text-to-3d/t1", None)
                self.assertTrue(caught.exception.retryable)
                self.assertFalse(caught.exception.may_have_created)

    def test_a_create_whose_reply_is_not_an_object_may_have_made_a_task(self) -> None:
        # Whatever the transport is, the client doesn't trust its reply's shape: this raised AttributeError.
        for reply in ([], "x", 3, None, ["result"]):
            with self.subTest(reply=reply):
                with self.assertRaises(MeshyError) as caught:
                    client(FakeTransport([reply])).create_refine("p")
                self.assertTrue(caught.exception.may_have_created)
                self.assertIn("pay twice", str(caught.exception))

    def test_a_wait_whose_reply_is_not_an_object_is_a_meshy_error(self) -> None:
        for reply in ([], "x", 3, None):
            with self.subTest(reply=reply):
                with self.assertRaises(MeshyError) as caught:
                    client(FakeTransport([reply] * 5)).wait("text-to-3d", "task-1")
                self.assertFalse(caught.exception.may_have_created)

    def test_a_wait_carries_on_past_one_reply_that_is_not_an_object(self) -> None:
        task = client(FakeTransport([[], {"status": "SUCCEEDED"}])).wait("text-to-3d", "task-1")
        self.assertEqual(task["status"], "SUCCEEDED")


if __name__ == "__main__":
    unittest.main()
