"""Exercise a checkout CLI connection with both executables during an upgrade."""
import argparse
import contextlib
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs

from oauth_cli_test import cli as legacy


def check_upgrade(binary):
    account = "eb95d8be-bf18-4ac3-a4d4-31f19b99d99a"
    identity = {"id": account, "kind": "user", "client_id": legacy.CLIENT}
    refresh_started = threading.Event()
    release_refresh = threading.Event()
    discovery = threading.Event()
    refresh_forms = []
    revoked = []

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/.well-known/oauth-authorization-server":
                if refresh_started.is_set():
                    discovery.set()
                self.reply(200, {
                    "issuer": origin,
                    "token_endpoint": origin + "/oauth/token",
                    "device_authorization_endpoint": origin + "/oauth/device/code",
                    "revocation_endpoint": origin + "/oauth/revoke",
                    "scopes_supported": ["repos:list"],
                    "response_types_supported": [],
                    "grant_types_supported": [legacy.DEVICE, "refresh_token"],
                    "token_endpoint_auth_methods_supported": ["none"],
                })
            elif self.path == "/api/v1/me" and self.headers.get("Authorization") == "Bearer rotated-access":
                self.reply(200, identity)
            else:
                self.reply(401, {"code": "unauthorized", "message": "Unknown bearer."})

        def do_POST(self):
            fields = parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
            if self.path == "/oauth/token":
                refresh_forms.append(fields)
                if len(refresh_forms) > 1:
                    self.reply(400, {"error": "invalid_grant"})
                    return
                refresh_started.set()
                release_refresh.wait(10)
                self.reply(200, {"access_token": "rotated-access", "token_type": "Bearer",
                                 "refresh_token": "rotated-refresh", "expires_in": 900, "scope": "repos:list"})
            elif self.path == "/oauth/revoke":
                revoked.append(fields.get("token"))
                self.reply(200, {})
            else:
                self.reply(404, {})

    with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
        env = {**os.environ, "XDG_STATE_HOME": directory}
        server = stack.enter_context(http.server.ThreadingHTTPServer(("127.0.0.1", 0), Endpoint))
        origin = "http://127.0.0.1:" + str(server.server_port)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        stack.callback(thread.join)
        stack.callback(server.shutdown)
        with patch.dict(os.environ, env):
            path = legacy.account_path(legacy.state_dir(origin), account)
            legacy.save(path, {"account": account, "access_token": "expired", "refresh_token": "initial",
                               "expires": 0.0, "scope": "repos:list"})
        args = ["--instance", origin, "--account", account]
        old = stack.enter_context(subprocess.Popen(
            [sys.executable, "-B", legacy.__file__, *args, "me"], env=env, stdout=subprocess.PIPE))
        stack.callback(release_refresh.set)
        assert refresh_started.wait(5), "the checkout client did not start rotating its token"
        new = stack.enter_context(subprocess.Popen([binary, *args, "me"], env=env, stdout=subprocess.PIPE))
        try:
            # Discovery can happen before or after acquiring the account lock.
            discovery.wait(1)
        finally:
            release_refresh.set()
        for process in (old, new):
            stdout, _ = process.communicate(timeout=10)
            assert process.returncode == 0 and json.loads(stdout) == identity
        assert refresh_forms == [{"client_id": [legacy.CLIENT], "grant_type": ["refresh_token"],
                                  "refresh_token": ["initial"]}]
        subprocess.run([binary, *args, "logout"], check=True, timeout=10, env=env)
        assert revoked == [["rotated-refresh"]] and not path.exists()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    check_upgrade(parser.parse_args().binary.resolve())
    print("PASS mixed Python and Go CLI processes shared one refresh and revoked the rotated grant")
