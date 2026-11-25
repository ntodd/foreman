package main

import (
	"bytes"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const ownIdentity = `{"id":"user","kind":"user","client_id":"foreman-environment","environment":{"id":"eeeeeeee-0000-4000-8000-111111111111","name":"storefront-2"}}`

// identity is what the test's API socket says of whoever asks.
var identity = ownIdentity

// fakeGH is a gh that says what it was run with and exits 4.
func fakeGH(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "gh")
	script := "#!/bin/sh\necho \"args: $*\"\necho \"proxy: ${HTTPS_PROXY:-none}\"\nexit 4\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// insideEnvironment gives the test an environment's own API socket.
func insideEnvironment(t *testing.T) {
	t.Helper()
	// Unix socket paths are short on macOS; t.TempDir() is long there.
	dir, err := os.MkdirTemp("/tmp", "fmcli")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "api.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, identity)
	})}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	t.Setenv("FOREMAN_API_SOCKET", path)
}

func ghAttach(t *testing.T, args ...string) (int, string, string) {
	t.Helper()
	var out, stderr bytes.Buffer
	status := run(args, &out, &stderr)
	return status, out.String(), stderr.String()
}

func TestGHAttachRunsGHBehindTheProxyInsideAnEnvironment(t *testing.T) {
	t.Setenv("HTTPS_PROXY", "")
	insideEnvironment(t)

	// Everything after the gh to run is gh's: this command has no options.
	status, out, stderr := ghAttach(t, fakeGH(t), "pr", "edit", "7", "--attach", "a.png", "--json", "--help", "--version")

	if status != 4 {
		t.Errorf("status = %d, want gh's own 4 (%s)", status, stderr)
	}
	if !strings.Contains(out, "args: pr edit 7 --attach a.png --json --help --version\n") {
		t.Errorf("gh ran with: %q", out)
	}
	if !strings.Contains(out, "proxy: http://foreman:") || !strings.Contains(out, "@127.0.0.1:") {
		t.Errorf("gh wasn't pointed at the proxy: %q", out)
	}
	if stderr != "" {
		t.Errorf("stderr = %q", stderr)
	}
}

func TestGHAttachRunsGHAsItIsWhereForemanCannotBeReached(t *testing.T) {
	t.Setenv("HTTPS_PROXY", "")
	t.Setenv("FOREMAN_API_SOCKET", filepath.Join(t.TempDir(), "none.sock"))

	status, out, stderr := ghAttach(t, fakeGH(t), "pr", "edit", "--attach", "a.png")

	if status != 4 || !strings.Contains(out, "args: pr edit --attach a.png\n") || !strings.Contains(out, "proxy: none") {
		t.Errorf("status %d, out %q", status, out)
	}
	if !strings.HasPrefix(stderr, "foreman: ") || !strings.Contains(stderr, "gh is uploading on its own") {
		t.Errorf("stderr = %q", stderr)
	}
}

func TestGHAttachNeedsAGHToRun(t *testing.T) {
	if status, out, stderr := ghAttach(t); status != 2 || out != "" || !strings.Contains(stderr, "Usage: foreman-gh-attach GH") {
		t.Errorf("status %d, out %q, stderr %q", status, out, stderr)
	}
	missing := filepath.Join(t.TempDir(), "gh")
	if status, _, stderr := ghAttach(t, missing, "pr", "edit"); status != 127 || !strings.Contains(stderr, missing) {
		t.Errorf("status %d, stderr %q", status, stderr)
	}
}

func TestAnEnvironmentThatDoesNotSayWhichItIsRunsGHAsItIs(t *testing.T) {
	t.Setenv("HTTPS_PROXY", "")
	insideEnvironment(t)
	identity = `{"id":"user","kind":"user","client_id":"foreman-cli"}`
	t.Cleanup(func() { identity = ownIdentity })

	status, out, stderr := ghAttach(t, fakeGH(t), "pr", "edit", "--attach", "a.png")

	if status != 4 || !strings.Contains(out, "proxy: none") || !strings.Contains(stderr, "gh is uploading on its own") {
		t.Errorf("status %d, out %q, stderr %q", status, out, stderr)
	}
}
