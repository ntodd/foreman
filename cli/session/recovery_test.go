package session

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
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
			if account, err := NewStore(root).Logout(context.Background(), "", ""); err == nil && account != "current" {
				t.Fatalf("retry revoked %q", account)
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
	if _, err = f.store.Logout(ctx, f.server.URL, "user"); err != nil || !slices.Equal(f.revoked, []string{"old"}) {
		t.Fatal(err, f.revoked)
	}
}
