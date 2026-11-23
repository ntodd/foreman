"""Regression tests for replacing a personal CLI connection in a real state directory."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import stat
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("foreman_cli", str(Path(__file__).resolve().parents[1] / "bin/foreman"))
cli = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(cli)


class ReplaceConnectionTest(unittest.TestCase):
    instance = "https://foreman.example"
    meta = {"device_authorization_endpoint": instance + "/device", "token_endpoint": instance + "/token",
            "revocation_endpoint": instance + "/revoke"}

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.path = cli.account_path(self.directory, "user")
        cli.save(self.path, {"account": "user", "refresh_token": "old", "access_token": "old-access",
                             "scope": "repos:list", "expires": 9999999999})
        self.revocations = []
        self.reject_revoke = set()
        for mock in (patch.object(cli, "request", side_effect=self.request), patch.object(cli.time, "sleep")):
            mock.start()
            self.addCleanup(mock.stop)

    def request(self, url, fields=None, token=None):
        if url.endswith("/device"):
            return {"verification_uri": self.instance + "/approve", "user_code": "TEST",
                    "device_code": "pending", "expires_in": 600, "interval": 1}
        if url.endswith("/token"):
            return {"access_token": "new-access", "refresh_token": "new", "expires_in": 900, "scope": "repos:list"}
        if url.endswith("/revoke"):
            credential = fields["token"]
            self.revocations.append((credential, json.loads(self.path.read_text())["refresh_token"]))
            if credential in self.reject_revoke:
                raise cli.OAuthError("offline")
            return {}
        if url.endswith("/me"):
            return {"kind": "user", "id": "user", "client_id": cli.CLIENT}
        self.fail("unexpected endpoint")

    def login(self):
        with contextlib.redirect_stdout(io.StringIO()):
            cli.login(self.instance, self.meta, self.directory, "repos:list", None)

    def test_saved_replacement_precedes_retirement(self):
        self.login()
        self.assertEqual([("old", "new")], self.revocations)

    def test_failed_retirement_retries_from_disk_after_restart(self):
        self.reject_revoke.add("old")
        with contextlib.suppress(cli.Failure):
            self.login()
        self.assertEqual("new", json.loads(self.path.read_text())["refresh_token"])
        self.reject_revoke.clear()
        with contextlib.redirect_stdout(io.StringIO()):
            cli.use_connection("me", self.instance, self.meta, self.directory, "user")
        self.assertEqual([("old", "new"), ("old", "new")], self.revocations)

    def test_failed_replace_keeps_old_connection_and_releases_new_grant(self):
        with patch.object(cli.os, "replace", side_effect=OSError("cannot persist")):
            with self.assertRaises((cli.Failure, OSError)):
                self.login()
        self.assertEqual("old", json.loads(self.path.read_text())["refresh_token"])
        self.assertEqual([("new", "old")], self.revocations)

    def test_failed_directory_sync_defers_retirement_until_state_is_durable(self):
        original = cli.os.fsync
        def fail_directory(fd):
            if stat.S_ISDIR(cli.os.fstat(fd).st_mode):
                raise OSError("directory sync failed")
            original(fd)
        with patch.object(cli.os, "fsync", side_effect=fail_directory):
            with self.assertRaisesRegex(cli.Failure, "sync"):
                self.login()
        self.assertEqual([], self.revocations)
        self.assertEqual("new", json.loads(self.path.read_text())["refresh_token"])
        with contextlib.redirect_stdout(io.StringIO()):
            cli.use_connection("me", self.instance, self.meta, self.directory, "user")
        self.assertEqual([("old", "new")], self.revocations)

    def test_failed_persistence_and_cleanup_identify_manual_recovery(self):
        self.reject_revoke.add("new")
        with patch.object(cli.os, "replace", side_effect=OSError("cannot persist")):
            with self.assertRaisesRegex(cli.Failure, "Connected apps"):
                self.login()
        self.assertEqual("old", json.loads(self.path.read_text())["refresh_token"])


if __name__ == "__main__":
    unittest.main()
