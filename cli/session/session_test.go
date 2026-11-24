package session

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// A real HTTP server advertises non-default paths. It rotates single-use
// refresh tokens and can fail retirement after a replacement has been saved.
type fixture struct {
	t                                                *testing.T
	store                                            *Store
	server                                           *httptest.Server
	now                                              atomic.Int64
	mu                                               sync.Mutex
	identity, requested, grantScope                  string
	deviceExpiry, interval                           int
	polls                                            []string
	sleeps                                           []time.Duration
	rejected                                         string
	dropRefresh                                      bool
	refreshAttempts                                  int
	revoked, rotations, bearers                      []string
	revokeObserved                                   []string
	endpointOverride, verifyOverride, issuerOverride string
}

func setup(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	t.Setenv("XDG_STATE_HOME", root)
	f := &fixture{t: t, store: NewStore(filepath.Join(root, "foreman")), identity: "user", grantScope: "repos:list", deviceExpiry: 600, interval: 1}
	f.now.Store(time.Now().Unix())
	f.store.now = func() time.Time { return time.Unix(f.now.Load(), 0) }
	f.store.sleep = func(ctx context.Context, d time.Duration) error {
		f.sleeps = append(f.sleeps, d)
		f.now.Add(int64(d / time.Second))
		return ctx.Err()
	}
	f.server = httptest.NewUnstartedServer(http.HandlerFunc(f.serve))
	f.server.Start()
	t.Cleanup(f.server.Close)
	return f
}
func (f *fixture) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	write := func(v any) { json.NewEncoder(w).Encode(v) }
	reject := func(reason string) { w.WriteHeader(400); write(map[string]string{"error": reason}) }
	u := f.server.URL
	form := r.PostFormValue
	if strings.HasPrefix(r.URL.Path, "/custom/") && (r.Method != "POST" || r.Header.Get("Content-Type") != "application/x-www-form-urlencoded" || form("client_id") != ClientID || r.Header.Get("Authorization") != "") {
		f.t.Errorf("incorrect OAuth transport at %s", r.URL.Path)
	}
	switch r.URL.Path {
	case "/.well-known/oauth-authorization-server":
		issuer := u
		if f.issuerOverride != "" {
			issuer = f.issuerOverride
		}
		token := u + "/custom/token?route=token"
		if f.endpointOverride != "" {
			token = f.endpointOverride
		}
		write(map[string]string{"issuer": issuer, "device_authorization_endpoint": u + "/custom/device", "token_endpoint": token, "revocation_endpoint": u + "/custom/revoke"})
	case "/custom/device":
		f.requested = form("scope")
		verify := u + "/approve"
		if f.verifyOverride != "" {
			verify = f.verifyOverride
		}
		write(map[string]any{"device_code": "secret-device", "verification_uri": verify, "user_code": "ABCD", "expires_in": f.deviceExpiry, "interval": f.interval})
	case "/custom/token":
		if r.URL.Query().Get("route") != "token" {
			f.t.Error("lost discovered query")
		}
		refresh := "new"
		switch form("grant_type") {
		case "urn:ietf:params:oauth:grant-type:device_code":
			if form("device_code") != "secret-device" {
				f.t.Error("wrong device code")
			}
			if len(f.polls) > 0 {
				reason := f.polls[0]
				f.polls = f.polls[1:]
				reject(reason)
				return
			}
		case "refresh_token":
			f.refreshAttempts++
			prev := form("refresh_token")
			if slices.Contains(f.rotations, prev) {
				reject("invalid_grant")
				return
			}
			f.rotations = append(f.rotations, prev)
			if f.dropRefresh {
				panic(http.ErrAbortHandler)
			}
			refresh = prev + "-rotated"
		default:
			f.t.Errorf("unknown grant %q", form("grant_type"))
		}
		write(map[string]any{"access_token": refresh + "-access", "refresh_token": refresh, "expires_in": 900, "scope": f.grantScope, "token_type": "Bearer"})
	case "/custom/revoke":
		token := form("token")
		f.revoked = append(f.revoked, token)
		state, _ := f.read(f.identity)
		f.revokeObserved = append(f.revokeObserved, state.RefreshToken)
		if token == f.rejected {
			reject("temporarily_unavailable")
		}
	case "/api/v1/me":
		f.bearers = append(f.bearers, r.Header.Get("Authorization"))
		write(map[string]any{"kind": "user", "id": f.identity, "client_id": ClientID, "extra": "preserved"})
	default:
		f.t.Errorf("unexpected request %s", r.URL.Path)
		http.NotFound(w, r)
	}
}
func (f *fixture) path(account string) string {
	return filepath.Join(f.store.root, fmt.Sprintf("%x", sha256.Sum256([]byte(f.server.URL))), fmt.Sprintf("%x.json", sha256.Sum256([]byte(account))))
}
func (f *fixture) read(account string) (credential, error) {
	b, e := os.ReadFile(f.path(account))
	var c credential
	if e == nil {
		e = json.Unmarshal(b, &c)
	}
	return c, e
}
func (f *fixture) python(args ...string) *exec.Cmd {
	f.t.Helper()
	script := `import runpy,sys,os
os.umask(0o077)
m=runpy.run_path("../../bin/foreman")
origin,action,account=sys.argv[1:4]
d=m["state_dir"](origin)
if action=="seed":
    state=dict(account=account,scope="repos:list",access_token="old-access",refresh_token="old",expires=0.5)
    if sys.argv[4:]:
        state["pending_revocations"]=sys.argv[4:]
    m["save"](m["account_path"](d,account),state)
else:
    m["use_connection"](action,origin,m["discover"](origin),d,account)
`
	return exec.Command("python3", append([]string{"-c", script, f.server.URL}, args...)...)
}
func (f *fixture) seed(account string) {
	f.t.Helper()
	if out, e := f.python("seed", account).CombinedOutput(); e != nil {
		f.t.Fatalf("Python credential writer: %v %s", e, out)
	}
}
func (f *fixture) login(account string) (Connection, error) {
	return f.store.Login(context.Background(), f.server.URL, account, "", func(p DevicePrompt) error {
		if p.VerificationURI != f.server.URL+"/approve" || p.UserCode != "ABCD" {
			f.t.Errorf("unexpected prompt: %+v", p)
		}
		return nil
	})
}

func TestPythonUpgradeConcurrentRotationAndLongSession(t *testing.T) {
	f := setup(t)
	f.seed("user")
	ctx := context.Background()
	s, e := f.store.Open(ctx, f.server.URL, "")
	if e != nil {
		t.Fatal(e)
	}
	if s.Instance != f.server.URL || s.Account != "user" || s.StateDir != f.store.root {
		t.Fatal(s)
	}
	// Race the Python checkout CLI and independent Go sessions on the same grant.
	const n = 8
	errs := make(chan error, n+1)
	go func() {
		out, e := f.python("me", "user").CombinedOutput()
		if e != nil {
			e = fmt.Errorf("%w %s", e, out)
		}
		errs <- e
	}()
	for range n {
		go func() {
			another, e := f.store.Open(ctx, f.server.URL, "user")
			if e == nil {
				_, e = another.Client.GetIdentity(ctx)
			}
			errs <- e
		}()
	}
	for range n + 1 {
		if e := <-errs; e != nil {
			t.Fatal(e)
		}
	}
	if !reflect.DeepEqual(f.rotations, []string{"old"}) {
		t.Fatal(f.rotations)
	}
	f.now.Add(890)
	reply, e := s.Client.GetIdentity(ctx)
	if e != nil || !bytes.Contains(reply.Body, []byte("preserved")) || reply.Value.ID != "user" {
		t.Fatalf("identity %v %v", reply, e)
	}
	if !reflect.DeepEqual(f.rotations, []string{"old", "old-rotated"}) || f.bearers[len(f.bearers)-1] != "Bearer old-rotated-rotated-access" {
		t.Fatal(f.rotations, f.bearers)
	}
	if _, e = f.store.Logout(ctx, f.server.URL, "user"); e != nil {
		t.Fatal(e)
	}
	if !reflect.DeepEqual(f.revoked, []string{"old-rotated-rotated"}) {
		t.Fatal(f.revoked)
	}
	if _, e = f.read("user"); !os.IsNotExist(e) {
		t.Fatal(e)
	}
}

func TestDevicePollingAndSavedSelection(t *testing.T) {
	f := setup(t)
	f.polls = []string{"authorization_pending", "slow_down"}
	c, e := f.login("")
	if e != nil || c.Account != "user" || c.Scope != "repos:list" {
		t.Fatal(c, e)
	}
	if !reflect.DeepEqual(f.sleeps, []time.Duration{time.Second, time.Second, 6 * time.Second}) {
		t.Fatal(f.sleeps)
	}
	// A plain login asks for everything the CLI can do; --scope narrows it.
	for _, scope := range strings.Fields("repos:list boxes:list environments:list environments:read operations:list operations:read logs:read environments:create environments:start environments:stop environments:destroy secrets:list secrets:write") {
		if !slices.Contains(strings.Fields(f.requested), scope) {
			t.Error("missing scope", scope)
		}
	}
	st, e := os.Stat(f.path("user"))
	if e != nil || st.Mode().Perm() != 0600 {
		t.Fatal(st, e)
	}
	f.identity = "two"
	if _, e = f.login("two"); e != nil {
		t.Fatal(e)
	}
	s, e := Open(context.Background(), "", "")
	if e != nil || s.Account != "two" {
		t.Fatal(s, e)
	}
	s, e = Open(context.Background(), "", "user")
	if e != nil || s.Account != "user" {
		t.Fatal(s, e)
	}
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { json.NewEncoder(w).Encode(map[string]string{}) }))
	defer other.Close()
	if _, e = Open(context.Background(), other.URL, "user"); e == nil {
		t.Fatal("borrowed connection across origins")
	}
}

func TestAmbiguousLegacyAccounts(t *testing.T) {
	f := setup(t)
	f.seed("zed")
	f.seed("alice")
	_, e := f.store.Open(context.Background(), f.server.URL, "")
	if e == nil || !strings.Contains(e.Error(), "alice, zed") {
		t.Fatal(e)
	}
}
func TestExpiryAndEndpointValidation(t *testing.T) {
	for _, test := range []struct {
		name string
		set  func(*fixture)
	}{
		{"issuer", func(f *fixture) { f.issuerOverride = "https://other.invalid" }},
		{"token endpoint", func(f *fixture) { f.endpointOverride = "https://other.invalid/token" }},
		{"verification", func(f *fixture) { f.verifyOverride = "https://other.invalid/approve" }},
		{"expired", func(f *fixture) { f.deviceExpiry = 2; f.polls = []string{"slow_down"} }},
		{"denied", func(f *fixture) { f.polls = []string{"access_denied"} }},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := setup(t)
			test.set(f)
			if _, e := f.login(""); e == nil {
				t.Fatal("accepted", test.name)
			}
			if _, e := f.read("user"); !os.IsNotExist(e) {
				t.Fatal(e)
			}
			if test.name == "expired" && len(f.sleeps) != 1 {
				t.Fatal(f.sleeps)
			}
		})
	}
}
func TestReplacementDurabilityAndRevocationRecovery(t *testing.T) {
	for _, stage := range []string{"success", "rename", "sync", "pending", "cleanup", "mismatch"} {
		t.Run(stage, func(t *testing.T) {
			f := setup(t)
			f.seed("user")
			ctx := context.Background()
			rename, syncDir := f.store.rename, f.store.syncDir
			account := "user"
			switch stage {
			case "rename", "cleanup":
				f.store.rename = func(a, b string) error {
					if b == f.path("user") {
						return errors.New("replace failure")
					}
					return rename(a, b)
				}
				if stage == "cleanup" {
					f.rejected = "new"
				}
			case "sync":
				f.store.syncDir = func(path string) error {
					if path == filepath.Dir(f.path("user")) {
						return errors.New("sync failure")
					}
					return syncDir(path)
				}
			case "pending":
				f.rejected = "old"
			case "mismatch":
				account = "other"
			}
			_, e := f.login(account)
			if (e != nil) != (stage != "success") {
				t.Fatalf("unexpected error %v", e)
			}
			c, readErr := f.read("user")
			if readErr != nil {
				t.Fatal(readErr)
			}
			switch stage {
			case "rename", "cleanup", "mismatch":
				if c.RefreshToken != "old" || !reflect.DeepEqual(f.revoked, []string{"new"}) {
					t.Fatal(c, f.revoked)
				}
				if stage == "cleanup" && !strings.Contains(e.Error(), "Connected apps") {
					t.Fatal(e)
				}
			case "sync", "pending", "success":
				if c.RefreshToken != "new" {
					t.Fatal(c)
				}
				if stage == "sync" && len(f.revoked) != 0 {
					t.Fatal(f.revoked)
				}
				if stage != "success" && !reflect.DeepEqual(c.PendingRevocations, []string{"old"}) {
					t.Fatal(c)
				}
				f.rejected = ""
				f.store.rename, f.store.syncDir = rename, syncDir
				s, e := Open(ctx, f.server.URL, account)
				if e != nil {
					t.Fatal(e)
				}
				if _, e = s.Client.GetIdentity(ctx); e != nil {
					t.Fatal(e)
				}
				c, e = f.read("user")
				if e != nil || len(c.PendingRevocations) != 0 {
					t.Fatal(c, e)
				}
				want := []string{"old"}
				if stage == "pending" {
					want = append(want, "old")
				}
				if !reflect.DeepEqual(f.revoked, want) {
					t.Fatal(f.revoked)
				}
				for _, r := range f.revokeObserved {
					if r != "new" {
						t.Fatal(f.revokeObserved)
					}
				}
			}
		})
	}
}

func TestPythonLockBlocksGoRefresh(t *testing.T) {
	f := setup(t)
	f.seed("user")
	s, err := f.store.Open(context.Background(), f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("python3", "-c", `import runpy,sys
from pathlib import Path
with runpy.run_path("../../bin/foreman")["locked"](Path(sys.argv[1])):
    print("locked",flush=True)
    sys.stdin.read(1)
`, f.path("user"))
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		in.Close()
		if err := cmd.Wait(); err != nil {
			t.Error(err)
		}
	}()
	line, err := bufio.NewReader(out).ReadString('\n')
	if err != nil || line != "locked\n" {
		t.Fatal(line, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if _, err = s.Client.GetIdentity(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("did not respect legacy lock", err)
	}
	if len(f.rotations) != 0 {
		t.Fatal("spent refresh token while locked")
	}
}

func TestLogoutRetriesPendingAndThenCurrent(t *testing.T) {
	f := setup(t)
	if out, err := f.python("seed", "user", "oldest", "previous").CombinedOutput(); err != nil {
		t.Fatalf("Python credential writer: %v %s", err, out)
	}
	state, err := f.read("user")
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	f.rejected = "previous"
	if _, err = f.store.Logout(ctx, f.server.URL, "user"); err == nil {
		t.Fatal("logout succeeded during pending failure")
	}
	saved, err := f.read("user")
	if err != nil || !reflect.DeepEqual(saved, state) {
		t.Fatal(err, "lost pending entries")
	}
	f.rejected = "old"
	if _, err = f.store.Logout(ctx, f.server.URL, "user"); err == nil {
		t.Fatal("logout succeeded during current revocation failure")
	}
	saved, err = f.read("user")
	if err != nil || len(saved.PendingRevocations) > 0 || saved.RefreshToken != "old" {
		t.Fatal(err, "lost current grant")
	}
	f.rejected = ""
	if _, err = f.store.Logout(ctx, f.server.URL, "user"); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(f.revoked, []string{"oldest", "previous", "oldest", "previous", "old", "old"}) {
		t.Error(f.revoked)
	}
}

func TestSavedAccountIsPerOrigin(t *testing.T) {
	first := setup(t)
	first.seed("other")
	if _, err := first.login("user"); err != nil {
		t.Fatal(err)
	}
	second := setup(t)
	second.store = first.store
	second.identity = "second-account"
	if _, err := second.login("second-account"); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct{ instance, account, wantOrigin, wantAccount string }{
		{"", "", second.server.URL, "second-account"},
		{first.server.URL, "", first.server.URL, "user"},
		{first.server.URL, "other", first.server.URL, "other"},
	} {
		s, err := first.store.Open(context.Background(), tc.instance, tc.account)
		if err != nil || s.Instance != tc.wantOrigin || s.Account != tc.wantAccount {
			t.Fatalf("selected wrong connection for %q, %q: %v, %v", tc.instance, tc.account, s, err)
		}
	}
	if _, err := first.store.Open(context.Background(), "", "user"); err == nil {
		t.Error("borrowed user from another instance")
	}
}

func TestInvalidGrantRequestsNewApproval(t *testing.T) {
	f := setup(t)
	f.seed("user")
	f.rotations = []string{"old"}
	ctx := context.Background()
	s, err := f.store.Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Client.GetIdentity(ctx)
	if err == nil || !strings.Contains(err.Error(), "invalid_grant") || !strings.Contains(err.Error(), "run login") {
		t.Fatal(err)
	}
	if len(f.bearers) != 0 {
		t.Fatal("sent expired access token")
	}
}

func TestReadOnlyUseNeverRefreshesOrWrites(t *testing.T) {
	f := setup(t)
	if _, e := f.login("user"); e != nil {
		t.Fatal(e)
	}
	before, _ := os.ReadFile(f.path("user"))
	sent := len(f.bearers) // Login reads the identity once itself.
	s, e := f.store.OpenReadOnly(context.Background(), "", "")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Client.GetIdentity(context.Background()); e != nil || len(f.bearers) != sent+1 {
		t.Fatal(e, f.bearers)
	}

	// Once the access token is due for a refresh, a read-only caller goes
	// without. It sends nothing and leaves the saved connection as it was.
	f.now.Add(900)
	if _, e = s.Client.GetIdentity(context.Background()); !errors.Is(e, ErrRefreshDue) {
		t.Fatal(e)
	}
	after, _ := os.ReadFile(f.path("user"))
	if f.refreshAttempts != 0 || len(f.rotations) != 0 || len(f.bearers) != sent+1 || !bytes.Equal(before, after) {
		t.Fatal(f.refreshAttempts, f.rotations, f.bearers)
	}

	// The next ordinary command refreshes, and read-only use works again.
	full, e := f.store.Open(context.Background(), "", "")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = full.Client.GetIdentity(context.Background()); e != nil {
		t.Fatal(e)
	}
	if _, e = s.Client.GetIdentity(context.Background()); e != nil || len(f.bearers) != sent+3 {
		t.Fatal(e, f.bearers)
	}
}
