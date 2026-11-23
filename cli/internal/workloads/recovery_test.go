package workloads

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/ntodd/foreman/cli/api"
)

func TestKilledCreateRecoversGeneratedKeyAndBody(t *testing.T) {
	const dirVar = "FOREMAN_TEST_KILL_CREATE_DIR"
	if dir := os.Getenv(dirVar); dir != "" {
		client := fake{create: func(_ context.Context, key string, b api.Create) (*api.Response[api.Accepted], error) {
			fmt.Fprintln(os.Stdout, "waiting for response")
			select {} // Parent terminates this process after it reaches the server.
		}}
		err := Run(context.Background(), []string{"env", "create", repoID, "--box", boxID, "--branch", "topic", "--no-wait"}, Options{
			API: client, Instance: "https://foreman.example", Account: "user-id", ClientID: "foreman-cli", StateDir: dir, In: strings.NewReader(""), Out: io.Discard, Err: os.Stderr, JSON: true,
		})
		t.Fatalf("unexpected return: %v", err)
	}
	h := setup(t, fake{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	child := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestKilledCreateRecoversGeneratedKeyAndBody$")
	child.Env = append(os.Environ(), dirVar+"="+h.StateDir)
	out, err := child.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var diagnostic bytes.Buffer
	child.Stderr = &diagnostic
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	line, err := bufio.NewReader(out).ReadString('\n')
	if err != nil {
		_ = child.Process.Kill()
		_ = child.Wait()
		t.Fatal(err, diagnostic.String())
	}
	if err := child.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	if err := child.Wait(); err == nil || line != "waiting for response\n" {
		t.Fatal(err, line)
	}
	var progress struct {
		Event      string
		RequestKey string `json:"request_key"`
	}
	if err := json.Unmarshal(diagnostic.Bytes(), &progress); err != nil || progress.Event != "request_saved" || progress.RequestKey == "" {
		t.Fatal(err, diagnostic.String())
	}
	files, err := filepath.Glob(filepath.Join(h.StateDir, "create-requests", "*.json"))
	if err != nil || len(files) != 1 {
		t.Fatal(err, files)
	}
	dir, err := os.Stat(filepath.Dir(files[0]))
	if err != nil || dir.Mode().Perm() != 0700 {
		t.Fatal(err, dir)
	}
	recordInfo, err := os.Stat(files[0])
	if err != nil || recordInfo.Mode().Perm() != 0600 {
		t.Fatal(err, recordInfo)
	}
	// Even a later explicit rejection cannot establish what happened to the killed send.
	h.API = fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) {
		return nil, &api.HTTPError{StatusCode: 409, Code: "capacity_confirmation_required", Message: "Capacity warning."}
	}}
	h.failure(t, "capacity_confirmation_required", "env", "create", "--resume", progress.RequestKey)
	h.API = fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) {
		t.Fatal("changed a killed submission")
		return nil, nil
	}}
	h.failure(t, "idempotency_conflict", "env", "create", "--resume", progress.RequestKey, "--confirm-capacity-warning")
	h.API = fake{create: func(_ context.Context, key string, b api.Create) (*api.Response[api.Accepted], error) {
		if key != progress.RequestKey || b.RepoID != repoID || b.Branch == nil || *b.Branch != "topic" || b.BoxID == nil || *b.BoxID != boxID {
			t.Fatal(key, b)
		}
		return accepted()
	}}
	h.success(t, "env", "create", "--resume", progress.RequestKey, "--no-wait")
	if h.doc(t)["operation_id"] != opID {
		t.Fatal(h.out.String())
	}
}

func TestResumeBindingAndConflict(t *testing.T) {
	h := setup(t, fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) {
		return nil, errors.New("dropped response")
	}})
	key := "../opaque/key"
	args := []string{"env", "create", repoID, "--request-key", key, "--no-wait"}
	info := h.failure(t, "outcome_unknown", args...)
	if info["request_key"] != key || !strings.Contains(info["message"].(string), "--resume") {
		t.Fatal(info)
	}
	h.API = fake{} // Any unexpected submission fails.
	h.failure(t, "idempotency_conflict", append(args, "--branch", "different")...)
	h.failure(t, "idempotency_conflict", "env", "create", "--resume", key, "--confirm-capacity-warning")
	h.failure(t, "request_not_found", "env", "create", "--resume", "missing")
	for _, value := range []*string{&h.Instance, &h.Account, &h.ClientID} {
		saved := *value
		*value = "other"
		h.failure(t, "request_identity_mismatch", "env", "create", "--resume", key)
		*value = saved
	}
	h.API = fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) {
		return nil, &api.HTTPError{StatusCode: 410, Code: "original_environment_gone", Message: "Original environment gone."}
	}}
	info = h.failure(t, "original_environment_gone", "env", "create", "--resume", key)
	if !strings.Contains(info["message"].(string), "destroyed") {
		t.Fatal(info)
	}
}

func TestConcurrentSameKeyDoesNotOverwriteSavedRequest(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	h := setup(t, fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) {
		close(entered)
		<-release
		return nil, errors.New("dropped")
	}})
	first := make(chan error, 1)
	go func() {
		first <- Run(context.Background(), []string{"env", "create", repoID, "--branch", "first", "--request-key", "k", "--no-wait"}, h.Options)
	}()
	<-entered
	other := setup(t, fake{})
	other.StateDir = h.StateDir
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	err := Run(ctx, []string{"env", "create", repoID, "--branch", "second", "--request-key", "k", "--no-wait"}, other.Options)
	cancel()
	close(release)
	if <-first == nil || err == nil || failure(err).Code != "request_timeout" {
		t.Fatal(err)
	}
	other.failure(t, "idempotency_conflict", "env", "create", repoID, "--branch", "second", "--request-key", "k", "--no-wait")
	other.API = fake{create: func(_ context.Context, key string, b api.Create) (*api.Response[api.Accepted], error) {
		if key != "k" || *b.Branch != "first" {
			t.Fatal(key, b)
		}
		return accepted()
	}}
	other.success(t, "env", "create", "--resume", "k", "--no-wait")
}

func TestExpiredReplayReadsEnvironmentOnlyWhenPermitted(t *testing.T) {
	calls := 0
	h := setup(t, fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) {
		r, _ := accepted()
		r.Value.OperationHistoryExpired = ptr(true)
		return r, nil
	}, env: func(_ context.Context, id string) (*api.Response[api.Environment], error) {
		calls++
		return response(api.Environment{ID: id, Readiness: "unknown"})
	}})
	h.success(t, "env", "create", repoID, "--request-key", "expired")
	if h.doc(t)["environment"].(map[string]any)["readiness"] != "unknown" || h.doc(t)["operation_history_expired"] != true {
		t.Fatal(h.out.String())
	}
	h.Scopes = []string{"environments:create"}
	h.success(t, "env", "create", "--resume", "expired", "--no-wait")
	doc := h.doc(t)
	if doc["environment_id"] != envID || doc["operation_id"] != opID || doc["environment"] != nil || calls != 1 {
		t.Fatal(doc, calls)
	}
}

func TestFreshIntentHasFreshKey(t *testing.T) {
	var keys []string
	h := setup(t, fake{create: func(_ context.Context, k string, _ api.Create) (*api.Response[api.Accepted], error) {
		keys = append(keys, k)
		return accepted()
	}})
	h.success(t, "env", "create", repoID, "--no-wait")
	h.success(t, "env", "create", repoID, "--no-wait")
	if len(keys) != 2 || keys[0] == keys[1] {
		t.Fatal(keys)
	}
}

func TestCapacityConfirmationPersistsBeforeRetry(t *testing.T) {
	h := setup(t, fake{})
	h.JSON = false
	h.Interactive = true
	h.In = strings.NewReader("yes\n")
	var keys []string
	h.API = fake{create: func(_ context.Context, key string, b api.Create) (*api.Response[api.Accepted], error) {
		keys = append(keys, key)
		if b.ConfirmCapacityWarning == nil {
			return nil, &api.HTTPError{StatusCode: 409, Code: "capacity_confirmation_required", Message: "Only 1 GiB remains."}
		}
		if !strings.Contains(h.diag.String(), "Only 1 GiB remains.") {
			t.Fatal("no warning before confirmation")
		}
		return nil, errors.New("lost")
	}}
	if err := h.run(t, "env", "create", repoID, "--request-key", "same", "--no-wait"); err == nil || !reflect.DeepEqual(keys, []string{"same", "same"}) {
		t.Fatal(err, keys)
	}
	h.API = fake{create: func(_ context.Context, key string, b api.Create) (*api.Response[api.Accepted], error) {
		if key != "same" || b.ConfirmCapacityWarning == nil || !*b.ConfirmCapacityWarning {
			t.Fatal(key, b)
		}
		return accepted()
	}}
	h.JSON = true
	h.success(t, "env", "create", "--resume", "same", "--no-wait")
}

func TestDeclinedCapacityAndHardLimitDoNotPromptScripts(t *testing.T) {
	h := setup(t, fake{})
	h.Interactive = true
	h.In = strings.NewReader("yes\n") // --json remains noninteractive.
	keys := 0
	h.API = fake{create: func(_ context.Context, key string, b api.Create) (*api.Response[api.Accepted], error) {
		keys++
		if b.ConfirmCapacityWarning == nil {
			return nil, &api.HTTPError{StatusCode: 409, Code: "capacity_confirmation_required", Message: "Warning"}
		}
		return nil, &api.HTTPError{StatusCode: 409, Code: "capacity_exceeded", Message: "Hard limit"}
	}}
	h.failure(t, "capacity_confirmation_required", "env", "create", repoID, "--request-key", "warning")
	h.failure(t, "capacity_exceeded", "env", "create", "--resume", "warning", "--confirm-capacity-warning")
	if keys != 2 {
		t.Fatal(keys)
	}
}

func TestDestroyAndStartConfirmDifferentActions(t *testing.T) {
	h := setup(t, fake{})
	h.Interactive = true
	h.In = strings.NewReader("yes\n")
	h.failure(t, "confirmation_required", "env", "destroy", envID)
	h.failure(t, "invalid_invocation", "env", "start", envID, "--yes")
	h.failure(t, "invalid_invocation", "env", "destroy", envID, "--confirm-capacity-warning")
	h.API = fake{act: func(_ context.Context, id, key string, b api.Action) (*api.Response[api.OperateEnvironmentResult], error) {
		if b.Action != "destroy" || b.ConfirmCapacityWarning != nil || id != envID || key == "" {
			t.Fatal(b)
		}
		return response(api.OperateEnvironmentResult{EnvironmentID: id})
	}}
	h.success(t, "env", "destroy", envID, "--yes")
	h.JSON = false
	h.success(t, "env", "destroy", envID)
	if !strings.Contains(h.out.String(), "already") || !strings.Contains(h.diag.String(), envID) {
		t.Fatal(h.out.String(), h.diag.String())
	}
	h.In = strings.NewReader("yes\n")
	var keys []string
	h.API = fake{act: func(_ context.Context, id, key string, b api.Action) (*api.Response[api.OperateEnvironmentResult], error) {
		keys = append(keys, key)
		if b.ConfirmCapacityWarning == nil {
			return nil, &api.HTTPError{StatusCode: 409, Code: "capacity_confirmation_required", Message: "Capacity is low."}
		}
		return &api.Response[api.OperateEnvironmentResult]{StatusCode: 202, Value: api.OperateEnvironmentResult{EnvironmentID: id, OperationID: ptr(opID)}}, nil
	}}
	h.success(t, "env", "start", envID, "--no-wait")
	if len(keys) != 2 || keys[0] != keys[1] || !strings.Contains(h.diag.String(), "Capacity is low.") {
		t.Fatal(keys, h.diag.String())
	}
}

func TestAmbiguousResponseCannotChangeSavedBody(t *testing.T) {
	h := setup(t, fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) {
		return nil, &api.HTTPError{StatusCode: 503, Code: "capacity_confirmation_required", Message: "Uncertain response from gateway"}
	}})
	f := h.failure(t, "outcome_unknown", "env", "create", repoID, "--request-key", "ambiguous")
	if f["remote_code"] != "capacity_confirmation_required" || f["http_status"] != float64(503) {
		t.Fatal(f)
	}
	h.API = fake{}
	h.failure(t, "idempotency_conflict", "env", "create", "--resume", "ambiguous", "--confirm-capacity-warning")
}

func TestStateFailurePreventsSubmission(t *testing.T) {
	h := setup(t, fake{})
	// A misplaced symlink must not redirect private request bodies elsewhere.
	if err := os.Symlink(t.TempDir(), filepath.Join(h.StateDir, "create-requests")); err != nil {
		t.Fatal(err)
	}
	h.failure(t, "state_error", "env", "create", repoID, "--no-wait")
}

func TestSecondClientCanResumeWhileOriginalWaits(t *testing.T) {
	waiting := make(chan struct{})
	h := setup(t, fake{
		create: func(_ context.Context, k string, _ api.Create) (*api.Response[api.Accepted], error) {
			if k != "replay" {
				t.Errorf("key %q", k)
			}
			return accepted()
		},
		op: func(ctx context.Context, id string) (*api.Response[api.Operation], error) {
			close(waiting)
			<-ctx.Done()
			return nil, ctx.Err()
		},
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	first := make(chan error, 1)
	go func() { first <- Run(ctx, []string{"env", "create", repoID, "--request-key", "replay"}, h.Options) }()
	<-waiting
	other := setup(t, fake{create: func(_ context.Context, k string, b api.Create) (*api.Response[api.Accepted], error) {
		if k != "replay" || b.RepoID != repoID {
			t.Fatal(k, b)
		}
		return accepted()
	}})
	other.StateDir = h.StateDir
	other.success(t, "env", "create", "--resume", "replay", "--no-wait", "--timeout", "2s")
	cancel()
	err := <-first
	if err == nil {
		t.Fatal("wait ignored interrupt")
	}
	f := failure(err)
	if f.Code != "interrupted" || f.OperationID != opID || f.EnvironmentID != envID || !strings.Contains(h.diag.String(), "op wait") {
		t.Fatal(f)
	}
}

func TestCancelledDestroyPromptDoesNotSubmit(t *testing.T) {
	input, writer := io.Pipe()
	defer input.Close()
	defer writer.Close()
	h := setup(t, fake{})
	h.JSON = false
	h.Interactive = true
	h.In = input
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- Run(ctx, []string{"env", "destroy", envID}, h.Options) }()
	select {
	case err := <-done:
		if err == nil || failure(err).Code != "request_timeout" {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		writer.Close()
		<-done
		t.Fatal("confirmation ignored context cancellation")
	}
}

func TestCallerKeyScopedByInstanceAccountAndClient(t *testing.T) {
	h := setup(t, fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) { return accepted() }})
	args := []string{"env", "create", repoID, "--request-key", "job-42", "--no-wait"}
	h.success(t, append(args, "--branch", "base")...)
	unexpected := fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) {
		t.Fatal("foreign resume submitted a create")
		return nil, nil
	}}
	for _, field := range []*string{&h.Instance, &h.Account, &h.ClientID} {
		original := *field
		*field = original + "-other"
		h.API = unexpected
		h.failure(t, "request_identity_mismatch", "env", "create", "--resume", "job-42")
		*field = original
		j, err := h.openJournal(context.Background(), "job-42")
		if err != nil {
			t.Fatal(err)
		}
		*field = original + "-other"
		h.API = fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) { return accepted() }}
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		err = Run(ctx, append(args, "--branch", "other"), h.Options)
		j.lock.Close()
		cancel()
		if err != nil {
			t.Fatalf("independent create: %v", err)
		}
		h.API = fake{create: func(_ context.Context, k string, b api.Create) (*api.Response[api.Accepted], error) {
			if k != "job-42" || b.Branch == nil || *b.Branch != "other" {
				t.Fatal(k, b)
			}
			return accepted()
		}}
		h.success(t, "env", "create", "--resume", "job-42", "--no-wait")
		*field = original
	}
}

func TestExistingUnscopedJournalResumesOnlyItsIdentity(t *testing.T) {
	h := setup(t, fake{})
	dir := filepath.Join(h.StateDir, "create-requests")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	key := "legacy"
	raw := fmt.Sprintf(`{"request_key":%q,"instance":%q,"account":%q,"client_id":%q,"body":{"repo_id":%q,"branch":"saved"}}`, key, h.Instance, h.Account, h.ClientID, repoID)
	if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("%x.json", sha256.Sum256([]byte(key)))), []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}
	account := h.Account
	h.Account = "another"
	h.failure(t, "request_identity_mismatch", "env", "create", "--resume", key)
	h.API = fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) { return accepted() }}
	h.success(t, "env", "create", repoID, "--request-key", key, "--no-wait")
	h.Account = account
	h.API = fake{create: func(_ context.Context, k string, b api.Create) (*api.Response[api.Accepted], error) {
		if b.Branch == nil || *b.Branch != "saved" || k != key {
			t.Fatal(b, k)
		}
		return accepted()
	}}
	h.success(t, "env", "create", "--resume", key, "--no-wait")
	h.failure(t, "idempotency_conflict", "env", "create", repoID, "--branch", "changed", "--request-key", key)
}

func TestOnlyDefinitiveRejectionsAllowCorrectedInputs(t *testing.T) {
	for _, tc := range []struct {
		status      int
		code        string
		correctable bool
	}{
		{422, "invalid_request", true}, {409, "capacity_exceeded", true}, {409, "capacity_confirmation_required", true},
		{409, "idempotency_conflict", false}, {410, "original_environment_gone", false}, {403, "insufficient_scope", false},
	} {
		t.Run(tc.code, func(t *testing.T) {
			h := setup(t, fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) {
				return nil, &api.HTTPError{StatusCode: tc.status, Code: tc.code}
			}})
			args := []string{"env", "create", repoID, "--request-key", "k", "--no-wait"}
			h.failure(t, tc.code, append(args, "--branch", "first")...)
			calls := 0
			h.API = fake{create: func(_ context.Context, k string, b api.Create) (*api.Response[api.Accepted], error) {
				calls++
				if b.Branch == nil || *b.Branch != "corrected" || k != "k" {
					t.Fatal(k, b)
				}
				return accepted()
			}}
			if tc.correctable {
				h.success(t, append(args, "--branch", "corrected")...)
				h.success(t, "env", "create", "--resume", "k", "--no-wait")
				h.failure(t, "idempotency_conflict", append(args, "--branch", "different")...)
				if calls != 2 {
					t.Fatal(calls)
				}
			} else {
				h.failure(t, "idempotency_conflict", append(args, "--branch", "corrected")...)
				if calls != 0 {
					t.Fatal(calls)
				}
			}
		})
	}
}

func TestLostResponseKeepsInputLockedAfterRejection(t *testing.T) {
	h := setup(t, fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) {
		return nil, io.ErrUnexpectedEOF
	}})
	h.failure(t, "outcome_unknown", "env", "create", repoID, "--request-key", "uncertain")
	for _, tc := range []struct {
		status int
		code   string
	}{{422, "invalid_request"}, {409, "capacity_confirmation_required"}} {
		h.API = fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) {
			return nil, &api.HTTPError{StatusCode: tc.status, Code: tc.code}
		}}
		h.failure(t, tc.code, "env", "create", "--resume", "uncertain")
		h.API = fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) {
			t.Fatal("changed an uncertain submission")
			return nil, nil
		}}
		h.failure(t, "idempotency_conflict", "env", "create", repoID, "--branch", "changed", "--request-key", "uncertain")
		h.failure(t, "idempotency_conflict", "env", "create", "--resume", "uncertain", "--confirm-capacity-warning")
	}
}
