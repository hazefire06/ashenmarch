"""Tests for meshy_client with fake transports; nothing touches the network."""
from __future__ import annotations

import io
import tempfile
import unittest
import urllib.error
from pathlib import Path
from typing import Any
from unittest import mock

import meshy_client
from meshy_client import MeshyClient, MeshyError, http_downloader, http_transport


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
        with self.assertRaisesRegex(MeshyError, "FAILED: model too complex"):
            client(t).wait("rigging", "r1")

    def test_gives_up_after_the_timeout(self) -> None:
        t = FakeTransport([{"status": "IN_PROGRESS"}] * 20)
        with self.assertRaisesRegex(MeshyError, "still IN_PROGRESS"):
            client(t).wait("animations", "a1")


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
