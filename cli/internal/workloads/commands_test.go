package workloads

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/ntodd/foreman/cli/api"
)

const (
	repoID = "aaaaaaaa-0000-4000-8000-111111111111"
	boxID  = "bbbbbbbb-0000-4000-8000-111111111111"
	envID  = "eeeeeeee-0000-4000-8000-111111111111"
	opID   = "dddddddd-0000-4000-8000-111111111111"
)

func ptr[T any](v T) *T { return &v }
func response[T any](v T) (*api.Response[T], error) {
	return &api.Response[T]{Value: v, StatusCode: 200}, nil
}
func accepted() (*api.Response[api.Accepted], error) {
	return &api.Response[api.Accepted]{StatusCode: 202, Value: api.Accepted{EnvironmentID: envID, OperationID: opID}}, nil
}

// An unset method panics, so unexpected calls (including extra reads or a retry) fail the test.
type fake struct {
	API
	repos  func(context.Context, string) (*api.Response[api.RepositoryPage], error)
	boxes  func(context.Context, string) (*api.Response[api.BoxPage], error)
	envs   func(context.Context, string) (*api.Response[api.EnvironmentPage], error)
	env    func(context.Context, string) (*api.Response[api.Environment], error)
	op     func(context.Context, string) (*api.Response[api.Operation], error)
	ops    func(context.Context, string, string) (*api.Response[api.OperationPage], error)
	logs   func(context.Context, string, string) (*api.Response[api.LogPage], error)
	create func(context.Context, string, api.Create) (*api.Response[api.Accepted], error)
	act    func(context.Context, string, string, api.Action) (*api.Response[api.OperateEnvironmentResult], error)
}

func (f fake) ListRepos(c context.Context, s string) (*api.Response[api.RepositoryPage], error) {
	return f.repos(c, s)
}
func (f fake) ListBoxes(c context.Context, s string) (*api.Response[api.BoxPage], error) {
	return f.boxes(c, s)
}
func (f fake) ListEnvironments(c context.Context, s string) (*api.Response[api.EnvironmentPage], error) {
	return f.envs(c, s)
}
func (f fake) GetEnvironment(c context.Context, s string) (*api.Response[api.Environment], error) {
	return f.env(c, s)
}
func (f fake) GetOperation(c context.Context, s string) (*api.Response[api.Operation], error) {
	return f.op(c, s)
}
func (f fake) ListEnvironmentOperations(c context.Context, id, s string) (*api.Response[api.OperationPage], error) {
	return f.ops(c, id, s)
}
func (f fake) GetOperationLogs(c context.Context, id, s string) (*api.Response[api.LogPage], error) {
	return f.logs(c, id, s)
}
func (f fake) CreateEnvironment(c context.Context, s string, b api.Create) (*api.Response[api.Accepted], error) {
	return f.create(c, s, b)
}
func (f fake) OperateEnvironment(c context.Context, id, s string, b api.Action) (*api.Response[api.OperateEnvironmentResult], error) {
	return f.act(c, id, s, b)
}

type fixture struct {
	Options
	out, diag bytes.Buffer
}

func setup(t *testing.T, f fake) *fixture {
	h := &fixture{}
	h.Options = Options{API: f, StateDir: t.TempDir(), Instance: "https://foreman.example", Account: "user-id", ClientID: "foreman-cli", In: strings.NewReader(""), Out: &h.out, Err: &h.diag, JSON: true, PollInterval: time.Millisecond}
	return h
}
func (h *fixture) run(t *testing.T, args ...string) error {
	t.Helper()
	h.out.Reset()
	h.diag.Reset()
	return Run(context.Background(), args, h.Options)
}
func (h *fixture) success(t *testing.T, args ...string) {
	t.Helper()
	if err := h.run(t, args...); err != nil {
		t.Fatalf("%v: %v\n%s", args, err, h.diag.String())
	}
}
func (h *fixture) failure(t *testing.T, code string, args ...string) map[string]any {
	t.Helper()
	if err := h.run(t, args...); err == nil {
		t.Fatalf("expected failure for %v", args)
	}
	lines := strings.Split(strings.TrimSpace(h.diag.String()), "\n")
	var info map[string]any
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &info); err != nil || info["code"] != code {
		t.Fatalf("want %s: %s", code, h.diag.String())
	}
	return info
}
func (h *fixture) doc(t *testing.T) map[string]any {
	t.Helper()
	var info map[string]any
	if err := json.Unmarshal(h.out.Bytes(), &info); err != nil {
		t.Fatal(err, h.out.String())
	}
	return info
}

func TestResolveAllPagesAndOmitDefaults(t *testing.T) {
	for _, ambiguous := range []bool{false, true} {
		h := setup(t, fake{repos: func(_ context.Context, c string) (*api.Response[api.RepositoryPage], error) {
			switch c {
			case "":
				return response(api.RepositoryPage{NextCursor: ptr("second")})
			case "second":
				return response(api.RepositoryPage{Items: []api.Repository{{FullName: "org/pay", ID: repoID}}, NextCursor: ptr("third")})
			case "third":
				var items []api.Repository
				if ambiguous {
					items = []api.Repository{{FullName: "org/pay", ID: boxID}}
				}
				return response(api.RepositoryPage{Items: items})
			}
			t.Fatal(c)
			return nil, nil
		}, create: func(_ context.Context, key string, b api.Create) (*api.Response[api.Accepted], error) {
			if ambiguous || key == "" || b.RepoID != repoID || b.BoxID != nil || b.Branch != nil {
				t.Fatal(key, b)
			}
			return accepted()
		}})
		if ambiguous {
			h.failure(t, "ambiguous_name", "env", "create", "org/pay", "--no-wait")
		} else {
			h.success(t, "env", "create", "org/pay", "--no-wait")
			if h.doc(t)["operation_id"] != opID {
				t.Fatal(h.out.String())
			}
		}
	}
}

func TestUUIDExpiryAndBoxNames(t *testing.T) {
	body := func(_ context.Context, _ string, b api.Create) (*api.Response[api.Accepted], error) {
		if b.RepoID != repoID || *b.BoxID != boxID || *b.Branch != "my/branch" || b.Expiry.Action != "stop" || b.Expiry.At != "2035-01-01T00:00:00Z" {
			t.Fatal(b)
		}
		return accepted()
	}
	f := fake{create: body}
	h := setup(t, f)
	for _, box := range []string{boxID, "London"} {
		if box == "London" {
			f.boxes = func(_ context.Context, c string) (*api.Response[api.BoxPage], error) {
				if c == "" {
					return response(api.BoxPage{Items: []api.Box{{Name: "london", ID: envID}}, NextCursor: ptr("2")})
				}
				return response(api.BoxPage{Items: []api.Box{{Name: "London", ID: boxID}}})
			}
			h.API = f
		}
		h.success(t, "env", "create", "--no-wait", repoID, "--branch=my/branch", "--expires-at", "2034-12-31T19:00:00-05:00", "--on-expiry", "stop", "--box", box)
	}
	for _, flags := range [][]string{{"--expires-at", "2035-01-01T00:00:00Z"}, {"--on-expiry", "stop"}, {"--expires-at", "tomorrow", "--on-expiry", "stop"}, {"--expires-at", "2035-01-01T00:00:00Z", "--on-expiry", "delete"}, {"--resume", "key"}, {"--yes"}, {"--timeout", "0s"}, {"--box", ""}, {"--request-key", "a\rb"}} {
		h.failure(t, "invalid_invocation", append([]string{"env", "create", repoID}, flags...)...)
	}
}

func TestAcceptedWaitReportsIDsAndCurrentReadiness(t *testing.T) {
	var h *fixture
	calls := 0
	f := fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) { return accepted() },
		op: func(_ context.Context, id string) (*api.Response[api.Operation], error) {
			if id != opID || !strings.Contains(h.diag.String(), envID) || !strings.Contains(h.diag.String(), opID) {
				t.Fatal("accepted IDs missing before wait")
			}
			calls++
			status := "running"
			if calls == 2 {
				status = "succeeded"
			}
			return response(api.Operation{ID: id, EnvironmentID: envID, Status: status})
		},
		env: func(_ context.Context, id string) (*api.Response[api.Environment], error) {
			return response(api.Environment{ID: id, Readiness: "unknown"})
		},
	}
	h = setup(t, f)
	h.success(t, "env", "create", repoID)
	doc := h.doc(t)
	if doc["environment"].(map[string]any)["readiness"] != "unknown" || doc["operation"].(map[string]any)["status"] != "succeeded" {
		t.Fatal(doc)
	}
	f.op = func(context.Context, string) (*api.Response[api.Operation], error) {
		return nil, &api.HTTPError{StatusCode: 403, Code: "insufficient_scope", Message: "The connection does not have the required scope."}
	}
	h.API = f
	info := h.failure(t, "insufficient_scope", "env", "create", repoID)
	if msg := info["message"].(string); !strings.Contains(msg, "operations:read") || !strings.Contains(msg, "foreman op wait "+opID) {
		t.Fatal(info)
	}
	if info["environment_id"] != envID || info["operation_id"] != opID {
		t.Fatal(info)
	}
}

func TestOperationTimeoutFailureAndCancel(t *testing.T) {
	h := setup(t, fake{op: func(ctx context.Context, id string) (*api.Response[api.Operation], error) {
		d, ok := ctx.Deadline()
		if !ok || time.Until(d) > time.Second {
			t.Fatal("unbounded read")
		}
		<-ctx.Done()
		return nil, ctx.Err()
	}})
	info := h.failure(t, "wait_timeout", "op", "wait", opID, "--timeout", "5ms")
	if info["operation_id"] != opID {
		t.Fatal(info)
	}
	for _, status := range []string{"failed", "cancelled"} {
		h.API = fake{op: func(_ context.Context, id string) (*api.Response[api.Operation], error) {
			return response(api.Operation{ID: id, EnvironmentID: envID, Status: status, Error: &api.Error{Code: "server_" + status, Message: "server detail"}})
		}}
		h.failure(t, "server_"+status, "op", "wait", opID)
	}
}

func TestLifecycleLostResponsePointsToHistory(t *testing.T) {
	h := setup(t, fake{act: func(_ context.Context, id, key string, b api.Action) (*api.Response[api.OperateEnvironmentResult], error) {
		if id != envID || key == "" || b.Action != "stop" {
			t.Fatal(id, key, b)
		}
		return nil, errors.New("connection lost")
	}})
	info := h.failure(t, "outcome_unknown", "env", "stop", envID)
	if info["environment_id"] != envID || !strings.Contains(info["message"].(string), "op list") {
		t.Fatal(info)
	}
}

func TestAlreadyStartedShowsCurrentReadinessWithoutPolling(t *testing.T) {
	h := setup(t, fake{
		act: func(_ context.Context, id, _ string, _ api.Action) (*api.Response[api.OperateEnvironmentResult], error) {
			return response(api.OperateEnvironmentResult{EnvironmentID: id})
		},
		env: func(_ context.Context, id string) (*api.Response[api.Environment], error) {
			return response(api.Environment{ID: id, Readiness: "unknown"})
		},
	})
	h.Scopes = []string{"environments:start", "environments:read"}
	h.success(t, "env", "start", envID)
	doc := h.doc(t)
	if doc["already_reached"] != true || doc["environment"] == nil || doc["operation_id"] != nil {
		t.Fatal(doc)
	}
}

func TestWaitTimeoutStartsAfterLifecycleSubmission(t *testing.T) {
	for _, action := range []string{"create", "start"} {
		for _, noWait := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/noWait=%t", action, noWait), func(t *testing.T) {
				checkSubmit := func(ctx context.Context) {
					if _, ok := ctx.Deadline(); ok {
						t.Error("wait timeout was applied to submission")
					}
				}
				polls := 0
				h := setup(t, fake{
					create: func(ctx context.Context, _ string, _ api.Create) (*api.Response[api.Accepted], error) {
						checkSubmit(ctx)
						return accepted()
					},
					act: func(ctx context.Context, id, _ string, _ api.Action) (*api.Response[api.OperateEnvironmentResult], error) {
						checkSubmit(ctx)
						return &api.Response[api.OperateEnvironmentResult]{StatusCode: 202, Value: api.OperateEnvironmentResult{EnvironmentID: id, OperationID: ptr(opID)}}, nil
					},
					op: func(ctx context.Context, id string) (*api.Response[api.Operation], error) {
						polls++
						if d, ok := ctx.Deadline(); !ok || time.Until(d) > time.Second {
							t.Error("wait has no command deadline")
						}
						return response(api.Operation{ID: id, EnvironmentID: envID, Status: "succeeded"})
					},
				})
				h.Scopes = []string{"operations:read"}
				id := envID
				if action == "create" {
					id = repoID
				}
				args := []string{"env", action, id, "--timeout", "1s"}
				if noWait {
					args = append(args, "--no-wait")
				}
				h.success(t, args...)
				if noWait && polls != 0 || !noWait && polls != 1 {
					t.Fatal(polls)
				}
			})
		}
	}
}

func TestShowReportsTerminalFailureAfterPrintingOperation(t *testing.T) {
	for _, status := range []string{"queued", "running", "succeeded", "failed", "cancelled"} {
		t.Run(status, func(t *testing.T) {
			op := api.Operation{ID: opID, EnvironmentID: envID, Status: status}
			failed := status == "failed" || status == "cancelled"
			if failed {
				op.Error = &api.Error{Code: "server_" + status, Message: "operation detail"}
			}
			h := setup(t, fake{op: func(context.Context, string) (*api.Response[api.Operation], error) { return response(op) }})
			if failed {
				info := h.failure(t, "server_"+status, "op", "show", opID)
				if info["operation_id"] != opID || info["environment_id"] != envID {
					t.Fatal(info)
				}
			} else {
				h.success(t, "op", "show", opID)
			}
			if h.doc(t)["status"] != status {
				t.Fatal(h.out.String())
			}
		})
	}
}
