package session

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/ntodd/foreman/cli/api"
)

const (
	ownEnvironment = "eeeeeeee-0000-4000-8000-111111111111"
	ownIdentity    = `{"id":"user","kind":"user","client_id":"foreman-environment","name":"ada","environment":{"id":"` + ownEnvironment + `","name":"storefront-2"}}`
)

// inside is what an environment's own API socket looks like to the CLI:
// plain HTTP on a unix socket, answering as the environment.
type inside struct {
	mu       sync.Mutex
	requests []*http.Request
	identity string
	status   int
}

func (i *inside) seen() []*http.Request {
	i.mu.Lock()
	defer i.mu.Unlock()
	return append([]*http.Request(nil), i.requests...)
}

func environment(t *testing.T) *inside {
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
	i := &inside{identity: ownIdentity, status: http.StatusOK}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		i.mu.Lock()
		i.requests = append(i.requests, r)
		identity, status := i.identity, i.status
		i.mu.Unlock()
		if r.URL.Path != "/api/v1/me" {
			http.Error(w, `{"code":"invalid_relay_request","message":"The box won't relay this request."}`, http.StatusBadRequest)
			return
		}
		w.WriteHeader(status)
		fmt.Fprint(w, identity)
	})}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	t.Setenv("FOREMAN_API_SOCKET", path)
	return i
}

func TestInsideAnEnvironmentNoLoginIsNeeded(t *testing.T) {
	f := setup(t)
	env := environment(t)
	t.Setenv("HTTP_PROXY", "http://127.0.0.2:1")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.2:1")

	for name, open := range map[string]func(context.Context, string, string) (*Session, error){
		"an ordinary command": f.store.Open,
		"completion":          f.store.OpenReadOnly,
	} {
		s, err := open(context.Background(), "", "")
		if err != nil {
			t.Fatal(name, err)
		}
		if s.Environment == nil || s.Environment.ID != ownEnvironment || *s.Environment.Name != "storefront-2" {
			t.Fatal(name, s.Environment)
		}
		if s.Account != "user" || !strings.Contains(s.Instance, "storefront-2") {
			t.Fatal(name, s.Connection)
		}
		if _, err = s.Client.GetIdentity(context.Background()); err != nil {
			t.Fatal(name, err)
		}
	}

	// Everything went to the socket, as the API's own paths, with no token
	// to send and no login endpoints looked for.
	requests := env.seen()
	if len(requests) != 4 {
		t.Fatal(len(requests))
	}
	for _, r := range requests {
		if r.URL.Path != "/api/v1/me" || r.Header.Get("Authorization") != "" {
			t.Fatal(r.URL.Path, r.Header)
		}
	}
	if len(f.bearers) != 0 {
		t.Fatal("the instance was asked", f.bearers)
	}
}

func TestALoginMadeInsideAnEnvironmentIsUsedInstead(t *testing.T) {
	f := setup(t)
	env := environment(t)
	if _, err := f.login("user"); err != nil {
		t.Fatal(err)
	}
	s, err := f.store.Open(context.Background(), "", "")
	if err != nil {
		t.Fatal(err)
	}
	if s.Environment != nil || s.Instance != f.server.URL {
		t.Fatal(s.Connection, s.Environment)
	}
	if len(env.seen()) != 0 {
		t.Fatal("the environment's socket was asked")
	}

	// Logged out again, the environment's own connection is back.
	if _, err = f.store.Logout(context.Background(), "", ""); err != nil {
		t.Fatal(err)
	}
	if s, err = f.store.Open(context.Background(), "", ""); err != nil || s.Environment == nil {
		t.Fatal(err, s)
	}
}

func TestNamingAnInstanceOrAccountNeverUsesTheEnvironment(t *testing.T) {
	f := setup(t)
	env := environment(t)
	for _, selectors := range [][2]string{{f.server.URL, ""}, {"", "user"}, {f.server.URL, "user"}} {
		if s, err := f.store.Open(context.Background(), selectors[0], selectors[1]); err == nil {
			t.Fatal(selectors, s.Connection)
		}
	}
	if len(env.seen()) != 0 {
		t.Fatal("the environment's socket was asked")
	}
}

func TestOutsideAnEnvironmentNothingChanges(t *testing.T) {
	f := setup(t)

	// No socket at all.
	t.Setenv("FOREMAN_API_SOCKET", filepath.Join(t.TempDir(), "absent.sock"))
	if _, err := f.store.Open(context.Background(), "", ""); err == nil || !strings.Contains(err.Error(), "--instance") {
		t.Fatal(err)
	}

	// A file that isn't a socket is never dialled.
	plain := filepath.Join(t.TempDir(), "api.sock")
	if err := os.WriteFile(plain, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FOREMAN_API_SOCKET", plain)
	if _, err := f.store.Open(context.Background(), "", ""); err == nil || !strings.Contains(err.Error(), "--instance") {
		t.Fatal(err)
	}
}

func TestAnEnvironmentWhoseBoxCannotAnswerSaysSo(t *testing.T) {
	f := setup(t)
	env := environment(t)

	// The box, or the control plane behind it, refused or failed.
	env.mu.Lock()
	env.identity, env.status = `{"code":"relay_unavailable","message":"The box isn't connected to this environment yet."}`, http.StatusServiceUnavailable
	env.mu.Unlock()
	_, err := f.store.Open(context.Background(), "", "")
	if err == nil || !strings.Contains(err.Error(), "isn't connected to this environment yet") || !strings.Contains(err.Error(), "foreman --instance URL login") {
		t.Fatal(err)
	}

	// Something answered that isn't an environment's connection.
	env.mu.Lock()
	env.identity, env.status = `{"id":"user","kind":"user","client_id":"foreman-cli"}`, http.StatusOK
	env.mu.Unlock()
	if _, err = f.store.Open(context.Background(), "", ""); err == nil || !strings.Contains(err.Error(), "foreman --instance URL login") {
		t.Fatal(err)
	}
}

// A login that still works is never passed over for the environment's
// connection, even when it isn't the one currently selected: that would
// change who a command acts as without anyone having said so.
func TestALoginSavedForAnotherInstanceIsNotPassedOver(t *testing.T) {
	f := setup(t)
	env := environment(t)
	if _, err := f.login("user"); err != nil {
		t.Fatal(err)
	}
	// As after logging in to a second instance and out of it again: it is
	// the one selected, with nothing saved for it.
	selection := []byte(`{"instance":"https://other.example","accounts":{}}`)
	if err := os.WriteFile(filepath.Join(f.store.root, "selection.json"), selection, 0o600); err != nil {
		t.Fatal(err)
	}

	for name, open := range map[string]func(context.Context, string, string) (*Session, error){
		"an ordinary command": f.store.Open,
		"completion":          f.store.OpenReadOnly,
	} {
		s, err := open(context.Background(), "", "")
		if err == nil {
			t.Fatal(name, s.Connection, s.Environment)
		}
		if !strings.Contains(err.Error(), "--instance") {
			t.Fatal(name, err)
		}
	}
	if len(env.seen()) != 0 {
		t.Fatal("the environment's socket was asked")
	}

	// The login is still there to be chosen.
	if s, err := f.store.Open(context.Background(), f.server.URL, ""); err != nil || s.Environment != nil {
		t.Fatal(err, s)
	}
}

// Nothing that authenticates goes over the socket: there is nobody at the
// other end to authenticate to, and a token sent there would be handed to
// whatever is listening.
func TestTheSocketNeverCarriesACredential(t *testing.T) {
	setup(t)
	env := environment(t)
	client := api.NewSocketClient(os.Getenv("FOREMAN_API_SOCKET")).
		WithBearer(func(context.Context) (string, error) { return "secret-token", nil }).
		WithBasicAuth("id", "secret")

	if _, err := client.GetIdentity(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, r := range env.seen() {
		if r.Header.Get("Authorization") != "" {
			t.Fatal(r.Header)
		}
	}
	before := len(env.seen())
	if _, err := client.RevokeToken(context.Background(), api.RevokeTokenBody{Token: "secret-token"}); err == nil {
		t.Fatal("a token was offered to the socket")
	}
	if _, err := client.GetOAuthMetadata(context.Background()); !errors.Is(err, api.ErrNoCredentials) {
		t.Fatal("login endpoints were looked for on the socket", err)
	}
	if len(env.seen()) != before {
		t.Fatal("a token request reached the socket")
	}
}
