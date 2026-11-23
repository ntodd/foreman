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
)

func TestInformationAndErrorsWithoutInstance(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	for _, tc := range []struct {
		args []string
		out  string
		code int
	}{
		{[]string{"--help"}, "--account", 0}, {[]string{"--version"}, "foreman " + version, 0},
		{[]string{"login", "--help"}, "--scope", 0}, {[]string{"--json", "me"}, "", 1},
		{[]string{"--json", "me", "surprise"}, "", 2}, {[]string{"bad", "--json"}, "", 2},
		{[]string{"--json", "login", "--scope="}, "", 2},
		{[]string{"--help"}, "secrets set NAME=value", 0}, {[]string{"secrets", "--help"}, "NAME=@file", 0},
		{[]string{"help", "secret"}, "secrets:write", 0},
	} {
		var out, stderr bytes.Buffer
		status := run(context.Background(), tc.args, &out, &stderr)
		if status != tc.code || !strings.Contains(out.String(), tc.out) {
			t.Fatalf("%v: %d %q %q", tc.args, status, out.String(), stderr.String())
		}
		if tc.code != 0 {
			var p struct{ Code, Message string }
			if out.Len() != 0 || json.Unmarshal(stderr.Bytes(), &p) != nil || p.Code == "" || p.Message == "" {
				t.Fatalf("unclean failure %v: %q %q", tc.args, out.String(), stderr.String())
			}
		}
	}
}

func TestHeadlessCommands(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	var revoked bool
	mux := http.NewServeMux()
	s := httptest.NewServer(mux)
	defer s.Close()
	mux.HandleFunc("/.well-known/oauth-authorization-server", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]string{"issuer": s.URL, "token_endpoint": s.URL + "/token", "revocation_endpoint": s.URL + "/revoke", "device_authorization_endpoint": s.URL + "/device"})
	})
	mux.HandleFunc("/device", func(w http.ResponseWriter, r *http.Request) {
		if r.PostFormValue("scope") != "environments:create" {
			t.Error("changed explicit login scope")
		}
		fmt.Fprintf(w, `{"verification_uri":%q,"device_code":"private","user_code":"SHOW","interval":1,"expires_in":600}`, s.URL+"/approve")
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"token_type":"Bearer","access_token":"access","refresh_token":"refresh","scope":"environments:create","expires_in":900}`)
	})
	mux.HandleFunc("/api/v1/me", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer access" {
			t.Error("missing personal bearer")
		}
		fmt.Fprint(w, `{"client_id":"foreman-cli","id":"one","kind":"user","extra":[1,2]}`)
	})
	mux.HandleFunc("/revoke", func(w http.ResponseWriter, r *http.Request) {
		revoked = r.PostFormValue("token") == "refresh" && r.PostFormValue("client_id") == "foreman-cli"
	})
	command := func(args ...string) (string, string) {
		t.Helper()
		var out, stderr bytes.Buffer
		if status := run(context.Background(), args, &out, &stderr); status != 0 {
			t.Fatalf("%v exited %d: %s", args, status, stderr.String())
		}
		return out.String(), stderr.String()
	}
	out, prompt := command("--instance", s.URL, "--account", "one", "login", "--scope", "environments:create", "--json")
	if prompt != "Open "+s.URL+"/approve and enter SHOW\n" {
		t.Fatalf("incorrect prompt %q", prompt)
	}
	var conn map[string]string
	if json.Unmarshal([]byte(out), &conn) != nil || conn["account"] != "one" || conn["scope"] != "environments:create" || strings.Contains(out, "refresh") {
		t.Fatalf("login output %q", out)
	}
	for _, args := range [][]string{{"me"}, {"--json", "me"}} {
		out, stderr := command(args...)
		var identity struct {
			ID    string
			Extra []int
		}
		if err := json.Unmarshal([]byte(out), &identity); err != nil || identity.ID != "one" || len(identity.Extra) != 2 || stderr != "" {
			t.Fatalf("me %q %q", out, stderr)
		}
	}
	var patched []string
	mux.HandleFunc("PATCH /api/v1/secrets/user/me", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Secrets []struct{ Name, Value string }
		}
		if r.Header.Get("Authorization") != "Bearer access" || json.NewDecoder(r.Body).Decode(&body) != nil || len(body.Secrets) != 1 {
			t.Error("unexpected secrets request")
			return
		}
		patched = append(patched, body.Secrets[0].Name+"="+body.Secrets[0].Value)
		fmt.Fprintf(w, `{"set":[%q],"unset":[],"affected":[],"others_affected":0}`, body.Secrets[0].Name)
	})
	// Both spellings of the command reach the same handler.
	for _, name := range []string{"secrets", "secret"} {
		out, stderr := command(name, "set", "TOKEN="+name)
		if out != "Set TOKEN on your own secrets.\n" || stderr != "" {
			t.Fatalf("%s set: %q %q", name, out, stderr)
		}
	}
	if strings.Join(patched, " ") != "TOKEN=secrets TOKEN=secret" {
		t.Fatalf("secrets requests %v", patched)
	}
	out, stderr := command("logout")
	if !revoked || out != "Disconnected one\n" || stderr != "" {
		t.Fatalf("logout: %q %q %v", out, stderr, revoked)
	}
}
