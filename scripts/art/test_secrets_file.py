"""Tests for secrets_file.load_secret, on temporary files only."""
from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from secrets_file import SecretsError, load_secret


class LoadSecretTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.folder = Path(self._tmp.name) / "ashenmarch"
        self.folder.mkdir(mode=0o700)
        self.path = self.folder / "secrets.env"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write(self, text: str, mode: int = 0o600) -> None:
        self.path.write_bytes(text.encode("utf-8"))
        os.chmod(self.path, mode)

    def test_reads_the_named_key(self) -> None:
        self.write("# keys\nMESHY_API_KEY=not-a-real-key\nELEVENLABS_API_KEY=\n")
        self.assertEqual(load_secret("MESHY_API_KEY", self.path), "not-a-real-key")

    def test_tolerates_bom_quotes_spaces_crlf_and_equals(self) -> None:
        self.write('﻿MESHY_API_KEY = "abc=def"\r\nOTHER=1\r\n')
        self.assertEqual(load_secret("MESHY_API_KEY", self.path), "abc=def")

    def test_missing_file_is_refused(self) -> None:
        with self.assertRaisesRegex(SecretsError, "does not exist"):
            load_secret("MESHY_API_KEY", self.path)

    def test_a_file_others_can_read_is_refused(self) -> None:
        self.write("MESHY_API_KEY=not-a-real-key\n", mode=0o644)
        with self.assertRaisesRegex(SecretsError, "chmod 600"):
            load_secret("MESHY_API_KEY", self.path)

    def test_a_folder_others_can_enter_is_refused(self) -> None:
        self.write("MESHY_API_KEY=not-a-real-key\n")
        os.chmod(self.folder, 0o755)
        with self.assertRaisesRegex(SecretsError, "chmod 700"):
            load_secret("MESHY_API_KEY", self.path)

    def test_missing_or_empty_key_is_refused(self) -> None:
        self.write("ELEVENLABS_API_KEY=\n")
        with self.assertRaisesRegex(SecretsError, "is not set"):
            load_secret("MESHY_API_KEY", self.path)
        with self.assertRaisesRegex(SecretsError, "is empty"):
            load_secret("ELEVENLABS_API_KEY", self.path)

    def test_errors_never_contain_the_value(self) -> None:
        self.write("MESHY_API_KEY=super-secret-value\n", mode=0o644)
        with self.assertRaises(SecretsError) as caught:
            load_secret("MESHY_API_KEY", self.path)
        self.assertNotIn("super-secret-value", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
