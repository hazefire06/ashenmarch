"""Tests for meshy_client with fake transports; nothing touches the network."""
from __future__ import annotations

import io
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
        for code in (400, 401, 402, 429):
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


if __name__ == "__main__":
    unittest.main()
