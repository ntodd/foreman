package session

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestLogoutRetryKeepsTargetAfterUnlink(t *testing.T) {
	for _, stage := range []string{"directory sync", "process restart"} {
		t.Run(stage, func(t *testing.T) {
			f := setup(t)
			f.seed("other")
			f.identity = "current"
			if _, err := f.login("current"); err != nil {
				t.Fatal(err)
			}
			root := f.store.root
			if stage == "process restart" {
				// State on disk after the server revoked the current grant and
				// the process stopped immediately after unlink.
				if err := os.Remove(f.path("current")); err != nil {
					t.Fatal(err)
				}
			} else {
				f.store.syncDir = func(dir string) error {
					if dir == filepath.Dir(f.path("current")) {
						return errors.New("sync failure")
					}
					return syncDirectory(dir)
				}
				if _, err := f.store.Logout(context.Background(), "", ""); err == nil {
					t.Fatal("expected injected failure")
				}
			}
			account, retryErr := NewStore(root).Logout(context.Background(), "", "")
			if account != "current" || retryErr == nil || !strings.Contains(retryErr.Error(), "select --account from other") {
				t.Fatalf("retry chose %q: %v", account, retryErr)
			}
			if _, err := f.read("other"); err != nil || slices.Contains(f.revoked, "old") {
				t.Fatal("lost unrelated connection", err, f.revoked)
			}
			if _, err := NewStore(root).Logout(context.Background(), f.server.URL, "other"); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestRetirementAdviceSelectsReplacement(t *testing.T) {
	f := setup(t)
	f.seed("replacement")
	f.identity = "other"
	if _, err := f.login("other"); err != nil {
		t.Fatal(err)
	}
	f.identity = "replacement"
	f.rejected = "old"
	_, err := f.login("replacement")
	if err == nil {
		t.Fatal("expected revocation error")
	}
	for _, want := range []string{"--instance", f.server.URL, "--account", "replacement", " me"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("recovery guidance lacks %q: %v", want, err)
		}
	}
	f.rejected = ""
	s, err := f.store.Open(context.Background(), f.server.URL, "replacement")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Client.GetIdentity(context.Background()); err != nil {
		t.Fatal(err)
	}
	c, err := f.read("replacement")
	if err != nil || len(c.PendingRevocations) != 0 {
		t.Fatal("failed to retire replacement", err)
	}
}

func TestRecoveredRotationAfterRenameFailure(t *testing.T) {
	f := setup(t)
	f.seed("user")
	ctx := context.Background()
	s, err := f.store.Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	rename := f.store.rename
	f.store.rename = func(a, b string) error {
		if b == f.path("user") && len(f.rotations) > 0 {
			return errors.New("temporary account rename failure")
		}
		return rename(a, b)
	}
	if _, err = s.Client.GetIdentity(ctx); err == nil {
		t.Fatal("expected local publish failure")
	}
	s, err = NewStore(f.store.root).Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Client.GetIdentity(ctx); err != nil {
		t.Fatalf("restart lost the received replacement: %v", err)
	}
	c, err := f.read("user")
	if err != nil || c.RefreshToken != "old-rotated" || !slices.Equal(f.rotations, []string{"old"}) {
		t.Fatal(err, f.rotations)
	}
	if _, err = f.store.Logout(ctx, f.server.URL, "user"); err != nil || !slices.Equal(f.revoked, []string{"old-rotated"}) {
		t.Fatal(err, f.revoked)
	}
}

func TestRotationSyncMustSucceedBeforeUsingReplacement(t *testing.T) {
	f := setup(t)
	f.seed("user")
	ctx := context.Background()
	s, err := f.store.Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	fail := func(dir string) error {
		c, _ := f.read("user")
		if dir == filepath.Dir(f.path("user")) && c.RefreshToken == "old-rotated" {
			return errors.New("directory sync interrupted")
		}
		return syncDirectory(dir)
	}
	f.store.syncDir = fail
	if _, err = s.Client.GetIdentity(ctx); err == nil {
		t.Fatal("expected post-rename sync failure")
	}
	restarted := NewStore(f.store.root)
	restarted.syncDir = fail
	s, err = restarted.Open(ctx, f.server.URL, "user")
	if err == nil {
		_, err = s.Client.GetIdentity(ctx)
	}
	if err == nil || len(f.bearers) != 0 {
		t.Fatal("accepted a rotation without a successful retry of the sync", f.bearers)
	}
	restarted.syncDir = syncDirectory
	s, err = restarted.Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Client.GetIdentity(ctx); err != nil || len(f.rotations) != 1 {
		t.Fatal(err, f.rotations)
	}
}

func TestLostRotationStopsAutomaticReplay(t *testing.T) {
	f := setup(t)
	f.seed("user")
	ctx := context.Background()
	s, err := f.store.Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	rename := f.store.rename
	f.store.rename = func(a, b string) error {
		if len(f.rotations) > 0 {
			return errors.New("volume full")
		}
		return rename(a, b)
	}
	_, err = s.Client.GetIdentity(ctx)
	if err == nil || !strings.Contains(err.Error(), "login") {
		t.Fatalf("missing recovery advice when all writes fail: %v", err)
	}
	f.store.rename = rename
	s, err = NewStore(f.store.root).Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Client.GetIdentity(ctx)
	if err == nil || strings.Contains(err.Error(), "invalid_grant") {
		t.Fatal("resent the spent credential", err)
	}
	if _, err = f.store.Logout(ctx, f.server.URL, "user"); err != nil || !slices.Equal(f.revoked, []string{"old-rotated", "old"}) {
		t.Fatal(err, f.revoked)
	}
}

func TestRefusedDialPreservesRefreshForRestart(t *testing.T) {
	f := setup(t)
	f.seed("user")
	ctx := context.Background()
	s, err := f.store.Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}

	// Discovery succeeded, but the instance is offline when the session
	// next needs to refresh. The POST cannot reach the closed listener.
	addr := f.server.Listener.Addr().String()
	f.server.Close()
	if _, err = s.Client.GetIdentity(ctx); !errors.Is(err, syscall.ECONNREFUSED) {
		t.Fatalf("expected the dial to be refused: %v", err)
	}

	listener, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(f.serve)}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })

	s, err = NewStore(f.store.root).Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Client.GetIdentity(ctx); err != nil {
		t.Fatalf("instance is back but refresh failed: %v", err)
	}
	if f.refreshAttempts != 1 || !slices.Equal(f.rotations, []string{"old"}) {
		t.Fatalf("got %d refresh attempts and rotations %v", f.refreshAttempts, f.rotations)
	}
}

func TestLostResponseBlocksReplayByBothClients(t *testing.T) {
	f := setup(t)
	f.seed("user")
	f.dropRefresh = true
	ctx := context.Background()
	s, err := f.store.Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Client.GetIdentity(ctx)
	if err == nil || !strings.Contains(err.Error(), "--account") || !strings.Contains(err.Error(), "login") {
		t.Fatal(err)
	}
	s, err = NewStore(f.store.root).Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Client.GetIdentity(ctx); err == nil {
		t.Fatal("accepted an ambiguous refresh")
	}
	// The checkout executable only knows its own expiry field; even after
	// restart it must not spend the predecessor. The fixture still accepts
	// the old access token for the remainder of its independent lifetime.
	if out, err := f.python("me", "user").CombinedOutput(); err != nil {
		t.Fatalf("legacy read: %v %s", err, out)
	}
	if f.refreshAttempts != 1 {
		t.Fatalf("clients sent %d refreshes", f.refreshAttempts)
	}
	if _, err = f.login("user"); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(f.revoked, []string{"old"}) {
		t.Fatal("reapproval failed to retire the original grant", f.revoked)
	}
}

func TestFailedStageCanPublishDirectlyAndResync(t *testing.T) {
	f := setup(t)
	f.seed("user")
	ctx := context.Background()
	s, err := f.store.Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	rename := f.store.rename
	f.store.rename = func(a, b string) error {
		if strings.HasSuffix(b, ".rotation") {
			return errors.New("stage rename failed")
		}
		return rename(a, b)
	}
	f.store.syncDir = func(dir string) error {
		c, _ := f.read("user")
		if c.RefreshToken == "old-rotated" {
			return errors.New("primary sync failed")
		}
		return syncDirectory(dir)
	}
	if _, err = s.Client.GetIdentity(ctx); err == nil || !strings.Contains(err.Error(), " me") {
		t.Fatal(err)
	}
	f.store.syncDir = syncDirectory
	if _, err = s.Client.GetIdentity(ctx); err != nil || f.refreshAttempts != 1 {
		t.Fatal(err, f.refreshAttempts)
	}
}

func TestStagedRotationCannotReplaceIndependentLogin(t *testing.T) {
	f := setup(t)
	f.seed("user")
	ctx := context.Background()
	s, err := f.store.Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	rename := f.store.rename
	f.store.rename = func(a, b string) error {
		if b == f.path("user") && len(f.rotations) > 0 {
			return errors.New("publish failed")
		}
		return rename(a, b)
	}
	if _, err = s.Client.GetIdentity(ctx); err == nil {
		t.Fatal("expected staging")
	}
	f.store.rename = rename
	// Independently installed state uses the exact checkout credential format
	// and knows nothing about the Go recovery file.
	next := credential{Account: "user", Scope: "repos:list", AccessToken: "independent-access", RefreshToken: "independent", Expires: unixSeconds(f.store.now()) + 900}
	if err = f.store.save(f.path("user"), next); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Client.GetIdentity(ctx); err != nil {
		t.Fatal(err)
	}
	c, err := f.read("user")
	if err != nil || c.RefreshToken != "independent" || f.bearers[len(f.bearers)-1] != "Bearer independent-access" {
		t.Fatal("resurrected replaced grant", err)
	}
	if _, err = os.Stat(f.path("user") + ".rotation"); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("stale stage", err)
	}
}

func TestUnsavedRotationRevokeFailureGivesManualRecovery(t *testing.T) {
	f := setup(t)
	f.seed("user")
	f.rejected = "old-rotated"
	ctx := context.Background()
	s, err := f.store.Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	rename := f.store.rename
	f.store.rename = func(a, b string) error {
		if len(f.rotations) > 0 {
			return errors.New("cannot save credentials")
		}
		return rename(a, b)
	}
	_, err = s.Client.GetIdentity(ctx)
	if err == nil || !strings.Contains(err.Error(), "Connected apps") || !strings.Contains(err.Error(), "--account") || !slices.Equal(f.revoked, []string{"old-rotated"}) {
		t.Fatal("expected one bounded revocation and actionable recovery", err, f.revoked)
	}
}

func TestReplacementLoginRetiresStagedSuccessor(t *testing.T) {
	f := setup(t)
	f.seed("user")
	ctx := context.Background()
	s, err := f.store.Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	rename := f.store.rename
	f.store.rename = func(a, b string) error {
		if b == f.path("user") && f.refreshAttempts > 0 {
			return errors.New("temporary rename failure")
		}
		return rename(a, b)
	}
	if _, err = s.Client.GetIdentity(ctx); err == nil {
		t.Fatal("expected publish failure")
	}
	f.store.rename = rename
	if _, err = f.login("user"); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(f.revoked, []string{"old-rotated"}) {
		t.Fatal("did not retire known successor", f.revoked)
	}
	state, err := f.read("user")
	if err != nil || state.RefreshToken != "new" {
		t.Fatal("lost the replacement login", err)
	}
}

func TestProcessDeathAfterStagingRotation(t *testing.T) {
	const originKey = "FOREMAN_TEST_STAGED_ROTATION_ORIGIN"
	if origin := os.Getenv(originKey); origin != "" {
		// setup() gave this child the parent's isolated state root. Stop with the
		// account lock held after the durable stage and before the primary rename.
		store, err := DefaultStore()
		if err != nil {
			t.Fatal(err)
		}
		path := accountPath(store.directory(origin), "user")
		store.rename = func(a, b string) error {
			if b == path {
				if _, err := os.Stat(path + ".rotation"); err == nil {
					os.Exit(79)
				}
			}
			return os.Rename(a, b)
		}
		ctx := context.Background()
		s, err := store.Open(ctx, origin, "user")
		if err != nil {
			t.Fatal(err)
		}
		_, err = s.Client.GetIdentity(ctx)
		t.Fatalf("child passed the crash point: %v", err)
	}
	f := setup(t)
	f.seed("user")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestProcessDeathAfterStagingRotation$")
	cmd.Env = append(os.Environ(), originKey+"="+f.server.URL)
	output, err := cmd.CombinedOutput()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 79 {
		t.Fatalf("exit: %v, %s", err, output)
	}
	st, err := os.Stat(f.path("user") + ".rotation")
	if err != nil || st.Mode().Perm() != 0600 {
		t.Fatal("private stage missing", err)
	}
	s, err := f.store.Open(ctx, f.server.URL, "user")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Client.GetIdentity(ctx); err != nil || f.refreshAttempts != 1 {
		t.Fatal(err, f.refreshAttempts)
	}
	if got := f.bearers[len(f.bearers)-1]; got != "Bearer old-rotated-access" {
		t.Fatal(got)
	}
}

func TestImplicitLogoutRequiresDurableLegacyAccountPin(t *testing.T) {
	f := setup(t)
	f.seed("user")
	ctx := context.Background()
	f.store.syncDir = func(dir string) error {
		if dir == f.store.root {
			return errors.New("selection directory sync failed")
		}
		return syncDirectory(dir)
	}
	// First call replaces the pin and fails to sync it. The retry encounters
	// the already visible pin and must confirm it before revoking anything.
	for range 2 {
		if _, err := f.store.Logout(ctx, f.server.URL, ""); err == nil || len(f.revoked) != 0 {
			t.Fatal(err, f.revoked)
		}
	}
	f.store.syncDir = syncDirectory
	if _, err := f.store.Logout(ctx, f.server.URL, ""); err != nil {
		t.Fatal(err)
	}
	f.seed("other") // A legacy login creates a credential without changing the selection.
	if _, err := f.store.Logout(ctx, f.server.URL, ""); err == nil || len(f.revoked) != 1 {
		t.Fatal(err, f.revoked)
	}
}
