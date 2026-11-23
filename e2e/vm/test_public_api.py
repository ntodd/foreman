"""Exercise the VM acceptance client's timing and operation selection without a VM."""

from contextlib import ExitStack
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import public_api


class PublicAPIClientTest(unittest.TestCase):
    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "client.json"
        self.args = SimpleNamespace(state=self.path, workspace="primary", hidden=None,
                                    action="pending-expiry", wait=30, retry_operation=None)
        self.state = {"branch": "main", "environment_id": "env", "operation_id": "original",
                      "create_operation_id": "original", "body": {}}
        self.env = {"id": "env", "branch": "main", "readiness": "unknown"}
        self.now = 100
        self.history = []
        self.operations = {}
        stack = ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.object(public_api, "args", self.args, create=True))
        stack.enter_context(patch.object(public_api, "request", self.request))
        stack.enter_context(patch.object(public_api.time, "time", lambda: self.now))
        stack.enter_context(patch.object(public_api.time, "sleep", self.advance))

    def advance(self, seconds):
        self.now += seconds

    def request(self, path, **_):
        if path == "/oauth/token":
            return {"access_token": "access", "refresh_token": "refresh"}, {}
        if path == "/api/v1/me":
            return {"kind": "user", "client_id": public_api.CLIENT}, {}
        if path == "/api/v1/environments/env":
            return self.env, {}
        if path == "/api/v1/environments/env/operations":
            return {"items": self.history}, {}
        if "/logs" in path:
            return {"text": "", "next_cursor": "cursor", "truncated": False}, {}
        return self.operations[path.removeprefix("/api/v1/operations/")], {}

    def run_client(self):
        self.path.write_text(json.dumps({"refresh_token": "refresh",
                                         "workspaces": {"primary": self.state}}))
        public_api.run()
        return json.loads(self.path.read_text())["workspaces"]["primary"]

    def policy(self, action):
        self.env["expiry"] = self.state["body"]["expiry"] = {
            "at": "1970-01-01T00:02:00Z", "action": action}
        return {"id": "cleanup", "action": action, "trigger": "expiry", "status": "queued"}

    def test_expiry_must_not_be_queued_early_for_either_policy(self):
        for action in ("stop", "destroy"):
            with self.subTest(action=action):
                self.history = [self.policy(action)]
                with self.assertRaisesRegex(AssertionError, "before the deadline"):
                    self.run_client()

    def test_outage_must_be_observed_before_the_deadline(self):
        self.now = 125
        self.history = [self.policy("destroy")]
        with self.assertRaisesRegex(AssertionError, "before the deadline"):
            self.run_client()

    def test_queue_appearing_at_the_deadline_is_accepted(self):
        operation = self.policy("stop")
        def tick(seconds):
            self.advance(seconds)
            if self.now >= 120:
                self.history = [operation]
        with patch.object(public_api.time, "sleep", tick):
            self.assertEqual(self.run_client()["operation_id"], "cleanup")

    def retry(self, action, retry_action):
        self.env["readiness"] = "ready"
        self.args.action = "ready"
        self.args.retry_operation = "retry"
        self.operations["original"] = {"id": "original", "action": action,
                                       "environment_id": "env", "status": "failed"}
        self.operations["retry"] = {"id": "retry", "action": retry_action,
                                    "environment_id": "env", "status": "succeeded"}

    def test_registry_retry_tracks_the_exact_operation_and_preserves_create_receipt(self):
        for action in ("create", "start"):
            with self.subTest(action=action):
                self.retry(action, action)
                saved = self.run_client()
                self.assertEqual(saved["operation_id"], "retry")
                self.assertEqual(saved["create_operation_id"], "original")

    def test_unrelated_success_cannot_substitute_for_the_failed_operation(self):
        self.retry("create", "start")
        with self.assertRaisesRegex(AssertionError, "retry action"):
            self.run_client()

    def test_workspace_without_deadline_cannot_accumulate_expiry_work(self):
        self.env["readiness"] = "not_ready"
        self.args.action = "not_ready"
        self.operations["original"] = {"id": "original", "action": "stop",
                                       "environment_id": "env", "status": "succeeded"}
        self.history = [{"id": "unsolicited", "action": "stop", "trigger": "expiry"}]
        with self.assertRaisesRegex(AssertionError, "without a deadline"):
            self.run_client()
