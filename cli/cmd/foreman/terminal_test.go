package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/ntodd/foreman/cli/session"
)

const (
	boxOne = "bbbbbbbb-0000-4000-8000-111111111111"
	boxTwo = "bbbbbbbb-0000-4000-8000-222222222222"
)

// instance is a Foreman that grants whatever a login asks for.
func instance(t *testing.T, identity string) *httptest.Server {
	t.Helper()
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	t.Setenv("NO_COLOR", "")
	t.Setenv("TERM", "xterm-256color")
	mux := http.NewServeMux()
	s := httptest.NewServer(mux)
	t.Cleanup(s.Close)
	var scope string
	mux.HandleFunc("/.well-known/oauth-authorization-server", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]string{"issuer": s.URL, "token_endpoint": s.URL + "/token", "revocation_endpoint": s.URL + "/revoke", "device_authorization_endpoint": s.URL + "/device"})
	})
	mux.HandleFunc("/device", func(w http.ResponseWriter, r *http.Request) {
		scope = r.PostFormValue("scope")
		fmt.Fprintf(w, `{"verification_uri":%q,"device_code":"private","user_code":"SHOW","interval":1,"expires_in":600}`, s.URL+"/approve")
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"token_type": "Bearer", "access_token": "access", "refresh_token": "refresh", "scope": scope, "expires_in": 900})
	})
	mux.HandleFunc("/api/v1/me", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, identity) })
	mux.HandleFunc("/api/v1/boxes", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"items":[{"id":%q,"name":"one","online":true},{"id":%q,"name":"number-two","online":false}],"next_cursor":null}`, boxOne, boxTwo)
	})
	mux.HandleFunc("/api/v1/environments", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"items":[{"id":"e1","slug":"app-me-1"},{"id":"e2","slug":"app-me-2"},{"id":"e3","slug":"web-me-1"}],"next_cursor":null}`)
	})
	return s
}

func at(t *testing.T, terminal bool, args ...string) string {
	t.Helper()
	was := isTerminal
	isTerminal = func(any) bool { return terminal }
	defer func() { isTerminal = was }()
	var out, stderr bytes.Buffer
	if status := run(context.Background(), args, &out, &stderr); status != 0 {
		t.Fatalf("%v exited %d: %s", args, status, stderr.String())
	}
	return out.String()
}

func TestLoginAndIdentityReadLikeSentencesAtATerminal(t *testing.T) {
	s := instance(t, `{"client_id":"foreman-cli","id":"one","kind":"user","name":"octocat"}`)
	out := at(t, true, "--instance", s.URL, "--account", "one", "login")
	if out != "Connected to "+s.URL+" as octocat.\nPermissions: everything the CLI can do.\n" {
		t.Fatalf("%q", out)
	}
	out = at(t, true, "me")
	want := "octocat on " + s.URL + "\n" +
		"Account:      one\n" +
		"Client:       foreman-cli\n" +
		"Permissions:  everything the CLI can do\n"
	if out != want {
		t.Fatalf("%q\n%q", out, want)
	}

	// A narrowed connection lists what it may do.
	out = at(t, true, "login", "--scope", "repos:list boxes:list")
	if out != "Connected to "+s.URL+" as octocat.\nPermissions: repos:list boxes:list.\n" {
		t.Fatalf("%q", out)
	}
	if out = at(t, true, "me"); !strings.HasSuffix(out, "Permissions:  repos:list boxes:list\n") {
		t.Fatalf("%q", out)
	}

	// A script reading a pipe gets what it always got.
	if out = at(t, false, "me"); out != `{"client_id":"foreman-cli","id":"one","kind":"user","name":"octocat"}`+"\n" {
		t.Fatalf("%q", out)
	}
	if out = at(t, false, "login", "--scope", "repos:list"); out != "Connected one with permissions repos:list\n" {
		t.Fatalf("%q", out)
	}
	if out = at(t, true, "--json", "login", "--scope", "repos:list"); !strings.HasPrefix(out, "{") {
		t.Fatalf("%q", out)
	}
}

func TestAnOlderServerIdentifiesTheAccountByItsID(t *testing.T) {
	s := instance(t, `{"client_id":"foreman-cli","id":"one","kind":"user"}`)
	if out := at(t, true, "--instance", s.URL, "--account", "one", "login"); !strings.HasPrefix(out, "Connected to "+s.URL+" as one.\n") {
		t.Fatalf("%q", out)
	}
	if out := at(t, true, "me"); !strings.HasPrefix(out, "one on "+s.URL+"\n") {
		t.Fatalf("%q", out)
	}
}

func TestListsAreTablesAtATerminalAndTabsInAPipe(t *testing.T) {
	s := instance(t, `{"client_id":"foreman-cli","id":"one","kind":"user"}`)
	at(t, true, "--instance", s.URL, "--account", "one", "login")
	out := at(t, true, "box", "list")
	want := "\x1b[2mBOX         STATUS   ID\x1b[0m\n" +
		"one         \x1b[32monline\x1b[0m   \x1b[2m" + boxOne + "\x1b[0m\n" +
		"number-two  \x1b[31moffline\x1b[0m  \x1b[2m" + boxTwo + "\x1b[0m\n"
	if out != want {
		t.Fatalf("%q\n%q", out, want)
	}
	t.Setenv("NO_COLOR", "1")
	if out = at(t, true, "box", "list"); strings.Contains(out, "\x1b") || !strings.HasPrefix(out, "BOX         STATUS   ID\n") {
		t.Fatalf("%q", out)
	}
	if out = at(t, false, "box", "list"); out != "ID\tBOX\tONLINE\n"+boxOne+"\tone\ttrue\n"+boxTwo+"\tnumber-two\tfalse\n" {
		t.Fatalf("%q", out)
	}
	if out = at(t, true, "--json", "box", "list"); !strings.HasPrefix(out, `{"items":[`) {
		t.Fatalf("%q", out)
	}
}

func TestEverythingMeansEveryDefaultPermission(t *testing.T) {
	if permissions(session.DefaultScope) != "everything the CLI can do" {
		t.Fatal(permissions(session.DefaultScope))
	}
	narrowed := strings.Replace(session.DefaultScope, " secrets:write", "", 1)
	if permissions(narrowed) != narrowed {
		t.Fatal(permissions(narrowed))
	}
}

func TestCompletionScriptsAndCandidates(t *testing.T) {
	s := instance(t, `{"client_id":"foreman-cli","id":"one","kind":"user"}`)
	raw := func(args ...string) (int, string, string) {
		var out, stderr bytes.Buffer
		status := run(context.Background(), args, &out, &stderr)
		return status, out.String(), stderr.String()
	}
	for _, shell := range []string{"bash", "zsh", "fish"} {
		if status, out, _ := raw("completion", shell); status != 0 || !strings.Contains(out, "foreman __complete") {
			t.Fatalf("%s: %d %q", shell, status, out)
		}
	}
	if status, out, _ := raw("completion", "powershell", "--json"); status != 2 || out != "" {
		t.Fatalf("%d %q", status, out)
	}
	if status, out, _ := raw("help", "completion"); status != 0 || !strings.Contains(out, "foreman completion zsh") {
		t.Fatalf("%d %q", status, out)
	}
	if status, out, _ := raw("--help"); status != 0 || !strings.Contains(out, "completion bash|zsh|fish") {
		t.Fatalf("%d %q", status, out)
	}

	// The words to complete arrive on standard input, one per line, so that
	// nothing typed on the command line shows up in a process list.
	complete := func(words ...string) (int, string, string) {
		was := stdin
		stdin = strings.NewReader(strings.Join(words, "\n") + "\n")
		defer func() { stdin = was }()
		return raw("__complete")
	}
	// Before login there are no names to offer, and nothing is said about it.
	if status, out, stderr := complete("env", "sh"); status != 0 || out != "show\n" || stderr != "" {
		t.Fatalf("%d %q %q", status, out, stderr)
	}
	if status, out, stderr := complete("env", "show", ""); status != 0 || out != "" || stderr != "" {
		t.Fatalf("%d %q %q", status, out, stderr)
	}
	at(t, false, "--instance", s.URL, "--account", "one", "login")
	if status, out, stderr := complete("env", "show", "app"); status != 0 || out != "app-me-1\napp-me-2\n" || stderr != "" {
		t.Fatalf("%d %q %q", status, out, stderr)
	}
	if status, out, _ := complete("env", "create", "--box", ""); status != 0 || out != "number-two\none\n" {
		t.Fatalf("%d %q", status, out)
	}
	// A word that looks like a global option is still a word to complete.
	if status, out, _ := complete("--j"); status != 0 || out != "--json\n" {
		t.Fatalf("%d %q", status, out)
	}
	// Words given as arguments are ignored: the scripts never send them that way.
	if status, out, _ := complete(); status != 0 || !strings.Contains(out, "login\n") {
		t.Fatalf("%d %q", status, out)
	}
}
