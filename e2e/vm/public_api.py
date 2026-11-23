"""Exercise personal and service-account connections against the throwaway VM suite's local instance."""

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import json
import os
import re
import select
import subprocess
from html.parser import HTMLParser
from pathlib import Path
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import urlencode, urljoin, urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler
from uuid import uuid4


CLIENT = "foreman-cli"
GRANT = "urn:ietf:params:oauth:grant-type:device_code"


class RegistryPullLimited(Exception):
    """The VM harness may retry this failed create after backing off."""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def request(path, *, form=None, body=None, token=None, key=None, basic=None, status=200):
    url = urljoin(args.url, path)
    if urlsplit(url).netloc != urlsplit(args.url).netloc or urlsplit(url).scheme != urlsplit(args.url).scheme:
        raise ValueError("Foreman returned an endpoint on a different origin")
    headers = {"Accept": "application/json"}
    data = None
    if form is not None:
        data = urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if basic:
        headers["Authorization"] = "Basic " + base64.b64encode(basic.encode()).decode("ascii")
    if key:
        headers["Idempotency-Key"] = key

    try:
        response = build_opener(NoRedirect).open(Request(url, data=data, headers=headers), timeout=30)
    except HTTPError as error:
        response = error
    with response:
        raw = response.read()
        try:
            result = json.loads(raw) if raw else {}
        except ValueError:
            raise AssertionError(f"{path} returned HTTP {response.status} with a non-JSON body") from None
        # Print stable error codes, never the request or an issued credential.
        if response.status != status:
            raise AssertionError(f"{path} returned {response.status}, expected {status}: "
                                 f"{result.get('error') or result.get('code')}")
        return result, response.headers


def operation_log(path, token, *, require_complete=False):
    pages = []
    next_page = path
    while True:
        page, _ = request(next_page, token=token)
        if require_complete:
            assert not page["truncated"]
        if not page["text"]:
            return "".join(pages)
        pages.append(page["text"])
        next_page = path + "?" + urlencode({"cursor": page["next_cursor"]})


class ConsentForm(HTMLParser):
    in_consent = False

    def handle_endtag(self, tag):
        if tag == "form":
            self.in_consent = False

    def handle_starttag(self, tag, attrs):
        fields = dict(attrs)
        if tag == "form":
            self.in_consent = fields.get("id") == "device-consent"
        if not self.in_consent:
            return
        if tag == "input" and fields.get("name") == "_csrf_token":
            self.csrf = fields["value"]
        if tag == "input" and fields.get("name") == "user_code":
            self.code = fields.get("value")


def approve(verification, code):
    # Session authentication is the same fixture used for LiveView in run.sh.
    # Carry forward the updated CSRF cookie issued by the GET.
    browser = build_opener(NoRedirect)
    cookie = os.environ["E2E_COOKIE"]
    url = verification + "?" + urlencode({"user_code": code})
    page = Request(url, headers={"Cookie": cookie})
    with browser.open(page, timeout=30) as response:
        assert response.url == url
        for updated in response.headers.get_all("Set-Cookie", []):
            if updated.startswith(cookie.split("=", 1)[0] + "="):
                cookie = updated.split(";", 1)[0]
        form = ConsentForm()
        form.feed(response.read().decode())
    assert form.code == code
    decision = urlencode({"_csrf_token": form.csrf, "user_code": form.code,
                          "decision": "approve"}).encode()
    with browser.open(Request(verification, data=decision, headers={"Cookie": cookie}), timeout=30) as response:
        assert response.status == 200


def connect():
    metadata, _ = request("/.well-known/oauth-authorization-server")
    assert metadata["issuer"] == args.url
    device, _ = request(metadata["device_authorization_endpoint"], form={
        "client_id": CLIENT,
        "scope": " ".join(metadata["scopes_supported"]),
    })
    verification = device["verification_uri"]
    assert verification == args.url + "/oauth/device"

    approve(verification, device["user_code"])
    time.sleep(device["interval"])
    tokens, _ = request(metadata["token_endpoint"], form={
        "grant_type": GRANT, "client_id": CLIENT, "device_code": device["device_code"],
    })
    return {"refresh_token": tokens["refresh_token"]}


def cli_stop(state):
    """Use the shipping CLI and a separate personal grant on a real running guest."""
    cli = os.environ["FOREMAN_CLI"]
    with tempfile.TemporaryDirectory() as directory:
        env = {**os.environ, "XDG_STATE_HOME": directory}
        def command(*words):
            result = subprocess.run([cli, "--json", *words], env=env, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, text=True, check=True, timeout=210)
            return json.loads(result.stdout)
        with subprocess.Popen([cli, "--instance", args.url, "login"], env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as login:
            try:
                assert select.select([login.stderr], [], [], 20)[0], "No CLI device login prompt"
                prompt = re.fullmatch(r"Open (\S+) and enter ([A-Z2-9-]+)", login.stderr.readline().strip())
                assert prompt and prompt[1] == args.url + "/oauth/device", "Unexpected CLI login prompt"
                approve(prompt[1], prompt[2])
                assert login.wait(timeout=30) == 0, "Device login failed"
            finally:
                if login.poll() is None:
                    login.kill()
        try:
            identifier = state["environment_id"]
            assert command("env", "show", identifier)["readiness"] == "ready"
            page = command("op", "logs", state["operation_id"])
            assert "PROBE workspace-marker " in page["text"], "Expected a log line from the guest"
            receipt = command("env", "stop", identifier, "--timeout", "3m")
            assert receipt["environment_id"] == identifier
            assert receipt["operation"]["status"] == "succeeded"
            return receipt["operation_id"]
        finally:
            command("logout")


def save(state):
    with tempfile.NamedTemporaryFile(mode="w", dir=args.state.parent, delete=False) as temp:
        json.dump(state, temp)
    os.replace(temp.name, args.state)


def run():
    if args.action == "login":
        save(connect())
        return
    connection = json.loads(args.state.read_text())
    service = "client_secret" in connection
    client_id = connection["client_id"] if service else CLIENT
    basic = None
    if service:
        basic = f"{client_id}:{connection['client_secret']}"
        tokens, _ = request("/oauth/token", basic=basic, form={"grant_type": "client_credentials"})
        assert "refresh_token" not in tokens
    else:
        tokens, _ = request("/oauth/token", form={
            "grant_type": "refresh_token", "client_id": client_id,
            "refresh_token": connection["refresh_token"],
        })
        connection["refresh_token"] = tokens["refresh_token"]
        save(connection)
    workspaces = connection.setdefault("workspaces", {})
    state = workspaces.setdefault(args.workspace, {})
    token = tokens["access_token"]
    me, _ = request("/api/v1/me", token=token)
    assert me["kind"] == ("service_account" if service else "user") and me["client_id"] == client_id
    if args.hidden:
        hidden, _ = request("/api/v1/environments/" + args.hidden, token=token, status=404)
        assert hidden["code"] == "resource_not_found"
        visible, _ = request("/api/v1/environments", token=token)
        assert args.hidden not in [env["id"] for env in visible["items"]]
    if args.action == "logout":
        credential = token if service else connection["refresh_token"]
        revocation = {"token": credential}
        if not service:
            revocation["client_id"] = client_id
        request("/oauth/revoke", basic=basic, form=revocation)
        request("/api/v1/me", token=token, status=401)
        args.state.unlink()
        return
    if args.action == "create":
        before, _ = request("/api/v1/environments", token=token)
        repos, _ = request("/api/v1/repos", token=token)
        boxes, _ = request("/api/v1/boxes", token=token)
        assert any(box["online"] for box in boxes["items"])
        repo, = [r for r in repos["items"] if r["full_name"] == "acme/hello"]
        key = str(uuid4())
        body = {"repo_id": repo["id"]}
        if args.expiry:
            action, at = args.expiry
            body["expiry"] = {"action": action, "at": at}
        path = "/api/v1/environments"
        with ThreadPoolExecutor(max_workers=2) as clients:
            submissions = [clients.submit(request, path, token=token, key=key, body=body, status=202)
                           for _ in range(2)]
            (first, headers), (duplicate, _) = [submission.result() for submission in submissions]
        replay, _ = request(path, token=token, key=key, body=body, status=202)
        assert first == duplicate == replay
        after, _ = request(path, token=token)
        prior_ids = {env["id"] for env in before["items"]}
        assert {env["id"] for env in after["items"]} - prior_ids == {first["environment_id"]}
        assert urlsplit(headers["Location"]).path == "/api/v1/operations/" + first["operation_id"]
        state.update({**first, "create_operation_id": first["operation_id"], "key": key,
                      "body": body, "branch": repo["default_branch"]})
        save(connection)
        print(first["environment_id"])
        return

    path = "/api/v1/environments/" + state["environment_id"]
    if args.action == "cli-stop":
        state["operation_id"] = cli_stop(state)
        save(connection)
        return
    if args.action in ("stop", "start", "destroy"):
        action, headers = request(path + "/operations", token=token, key=str(uuid4()),
                                  body={"action": args.action}, status=202)
        assert action["environment_id"] == state["environment_id"]
        assert urlsplit(headers["Location"]).path == "/api/v1/operations/" + action["operation_id"]
        state["operation_id"] = action["operation_id"]
        save(connection)
        return

    if args.action == "pending-expiry":
        policy = state["body"]["expiry"]
        due = datetime.fromisoformat(policy["at"].replace("Z", "+00:00")).timestamp()
        env, _ = request(path, token=token)
        assert env["readiness"] == "unknown" and env["expiry"]["action"] == policy["action"]
        assert datetime.fromisoformat(env["expiry"]["at"].replace("Z", "+00:00")).timestamp() == due
        assert time.time() < due, "The restarted server must observe the offline box before the deadline"
        while time.time() < due + 90:
            history, _ = request(path + "/operations", token=token)
            matches = [op for op in history["items"] if op["trigger"] == "expiry"]
            if matches:
                assert time.time() >= due, "Expiry was queued before the deadline"
                op, = matches
                assert op["action"] == policy["action"] and op["status"] == "queued"
                state["operation_id"] = op["id"]
                save(connection)
                return
            time.sleep(2)
        raise AssertionError("No queued expiry operation appeared while the box was offline")

    if args.action == "marker":
        log_path = "/api/v1/operations/" + state["operation_id"] + "/logs"
        output = operation_log(log_path, token, require_complete=True)
        if service:
            assert "PROBE approved-secret present" in output
            assert "PROBE unapproved-secret absent" in output
        markers = re.findall(r"^PROBE workspace-marker ([0-9a-f-]{36})$", output, re.MULTILINE)
        assert markers, "The workspace did not report its disk marker"
        print(markers[-1])
        return

    if args.action == "destroyed":
        history, _ = request(path + "/operations", token=token)
        trigger = "expiry" if state["body"].get("expiry", {}).get("action") == "destroy" else "request"
        assert any(op["id"] == state["operation_id"] and op["action"] == "destroy"
                   and op["trigger"] == trigger and op["status"] == "succeeded"
                   for op in history["items"])
        logs, _ = request("/api/v1/operations/" + state["create_operation_id"] + "/logs", token=token)
        assert logs["text"], "Creation logs should still be readable after destroy"
        gone, _ = request("/api/v1/environments", token=token, key=state["key"],
                          body=state["body"], status=410)
        assert gone["code"] == "original_environment_gone"
        return

    # Inventory can arrive shortly after the agent confirms the operation.
    operation_id = state["operation_id"]
    retry_action = None
    if args.retry_operation:
        original, _ = request("/api/v1/operations/" + operation_id, token=token)
        assert original["environment_id"] == state["environment_id"] and original["status"] == "failed"
        retry_action = original["action"]
        assert args.action == "ready" and retry_action in ("create", "start")
        operation_id = args.retry_operation
    op_path = "/api/v1/operations/" + operation_id
    deadline = time.monotonic() + args.wait
    while time.monotonic() < deadline:
        env, _ = request(path, token=token)
        assert env["branch"] == state["branch"]
        op, _ = request(op_path, token=token)
        assert op["environment_id"] == state["environment_id"]
        if retry_action:
            assert op["action"] == retry_action, "Registry retry action differs from the failed operation"
        if args.action == "ready" and op["action"] == "create" and op["status"] == "failed":
            log = operation_log(op_path + "/logs", token)
            if re.search(r"toomanyrequests|too many requests|rate exceeded", log, re.IGNORECASE):
                raise RegistryPullLimited(operation_id)
        assert op["status"] not in ("cancelled", "failed"), f"{op['action']} {op['status']}"
        if env["readiness"] == args.action and op["status"] == "succeeded":
            break
        time.sleep(2)
    else:
        raise AssertionError(f"Workspace readiness was {env['readiness']}, expected {args.action}")

    if "expiry" not in state["body"]:
        assert "expiry" not in env, "The workspace acquired an expiry policy without a deadline"
        history, _ = request(path + "/operations", token=token)
        assert all(op["trigger"] != "expiry" for op in history["items"]), (
            "The workspace received expiry work without a deadline"
        )

    log, _ = request(op_path + "/logs", token=token)
    assert isinstance(log["text"], str) and isinstance(log["truncated"], bool)
    request(op_path + "/logs?" + urlencode({"cursor": log["next_cursor"]}), token=token)
    if args.retry_operation:
        state["operation_id"] = operation_id
        save(connection)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    parser.add_argument("state", type=Path)
    parser.add_argument("action", choices=["login", "create", "ready", "not_ready",
                                          "stop", "cli-stop", "start", "destroy", "destroyed",
                                          "pending-expiry", "marker", "logout"])
    parser.add_argument("--workspace", default="primary")
    parser.add_argument("--expiry", nargs=2, metavar=("ACTION", "AT"))
    parser.add_argument("--hidden", help="environment owned by the other test identity")
    parser.add_argument("--retry-operation", help="exact operation returned by the registry retry")
    parser.add_argument("--wait", type=int, default=100)
    args = parser.parse_args()
    try:
        run()
    except RegistryPullLimited as limited:
        print(limited)
        raise SystemExit(os.EX_TEMPFAIL)
