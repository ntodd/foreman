"""Exercise a personal app connection against the throwaway VM suite's local instance."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
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


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def request(path, *, form=None, body=None, token=None, key=None, status=200):
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


def connect():
    metadata, _ = request("/.well-known/oauth-authorization-server")
    assert metadata["issuer"] == args.url
    device, _ = request(metadata["device_authorization_endpoint"], form={
        "client_id": CLIENT,
        "scope": " ".join(metadata["scopes_supported"]),
    })
    verification = device["verification_uri"]
    assert verification == args.url + "/oauth/device"

    # Session authentication is the same fixture used for LiveView in run.sh.
    # Carry forward the updated CSRF cookie issued by the GET.
    browser = build_opener(NoRedirect)
    cookie = os.environ["E2E_COOKIE"]
    url = verification + "?" + urlencode({"user_code": device["user_code"]})
    page = Request(url, headers={"Cookie": cookie})
    with browser.open(page, timeout=30) as response:
        assert response.url == url
        for updated in response.headers.get_all("Set-Cookie", []):
            if updated.startswith(cookie.split("=", 1)[0] + "="):
                cookie = updated.split(";", 1)[0]
        form = ConsentForm()
        form.feed(response.read().decode())
    assert form.code == device["user_code"]
    decision = urlencode({"_csrf_token": form.csrf, "user_code": form.code,
                          "decision": "approve"}).encode()
    with browser.open(Request(verification, data=decision, headers={"Cookie": cookie}), timeout=30) as response:
        assert response.status == 200
    time.sleep(device["interval"])
    tokens, _ = request(metadata["token_endpoint"], form={
        "grant_type": GRANT, "client_id": CLIENT, "device_code": device["device_code"],
    })
    return {"refresh_token": tokens["refresh_token"]}


def save(state):
    with tempfile.NamedTemporaryFile(mode="w", dir=args.state.parent, delete=False) as temp:
        json.dump(state, temp)
    os.replace(temp.name, args.state)


def run():
    if args.action == "login":
        save(connect())
        return
    state = json.loads(args.state.read_text())
    tokens, _ = request("/oauth/token", form={
        "grant_type": "refresh_token", "client_id": CLIENT, "refresh_token": state["refresh_token"],
    })
    state["refresh_token"] = tokens["refresh_token"]
    save(state)
    token = tokens["access_token"]
    me, _ = request("/api/v1/me", token=token)
    assert me["kind"] == "user" and me["client_id"] == CLIENT
    if args.action == "create":
        before, _ = request("/api/v1/environments", token=token)
        repos, _ = request("/api/v1/repos", token=token)
        boxes, _ = request("/api/v1/boxes", token=token)
        assert any(box["online"] for box in boxes["items"])
        repo, = [r for r in repos["items"] if r["full_name"] == "acme/hello"]
        key = str(uuid4())
        body = {"repo_id": repo["id"]}
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
        save({**state, **first, "create_operation_id": first["operation_id"], "key": key,
              "body": body, "branch": repo["default_branch"]})
        print(first["environment_id"])
        return

    path = "/api/v1/environments/" + state["environment_id"]
    if args.action in ("stop", "start", "destroy"):
        action, headers = request(path + "/operations", token=token, key=str(uuid4()),
                                  body={"action": args.action}, status=202)
        assert action["environment_id"] == state["environment_id"]
        assert urlsplit(headers["Location"]).path == "/api/v1/operations/" + action["operation_id"]
        save({**state, "operation_id": action["operation_id"]})
        return

    if args.action == "destroyed":
        history, _ = request(path + "/operations", token=token)
        assert any(op["id"] == state["operation_id"] and op["action"] == "destroy"
                   and op["trigger"] == "request" and op["status"] == "succeeded"
                   for op in history["items"])
        logs, _ = request("/api/v1/operations/" + state["create_operation_id"] + "/logs", token=token)
        assert logs["text"], "Creation logs should still be readable after destroy"
        gone, _ = request("/api/v1/environments", token=token, key=state["key"],
                          body=state["body"], status=410)
        assert gone["code"] == "original_environment_gone"
        request("/oauth/revoke", form={"client_id": CLIENT, "token": tokens["refresh_token"]})
        request("/api/v1/me", token=token, status=401)
        args.state.unlink()
        return

    # Inventory can arrive shortly after the agent confirms the operation.
    deadline = time.monotonic() + 100
    while time.monotonic() < deadline:
        env, _ = request(path, token=token)
        assert env["branch"] == state["branch"]
        if env["readiness"] == args.action:
            break
        time.sleep(2)
    else:
        raise AssertionError(f"Workspace readiness was {env['readiness']}, expected {args.action}")

    op_path = "/api/v1/operations/" + state["operation_id"]
    op, _ = request(op_path, token=token)
    assert op["status"] == "succeeded" and op["environment_id"] == state["environment_id"]
    log, _ = request(op_path + "/logs", token=token)
    assert isinstance(log["text"], str) and isinstance(log["truncated"], bool)
    request(op_path + "/logs?" + urlencode({"cursor": log["next_cursor"]}), token=token)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    parser.add_argument("state", type=Path)
    parser.add_argument("action", choices=["login", "create", "ready", "not_ready",
                                          "stop", "start", "destroy", "destroyed"])
    args = parser.parse_args()
    run()
