package workloads

import (
	"context"
	"strings"
	"testing"

	"github.com/ntodd/foreman/cli/api"
)

// Inside an environment, a command that takes one means that one when
// none is named.
func TestInsideAnEnvironmentTheEnvironmentIsItself(t *testing.T) {
	var shown, listed, acted, action string
	h := setup(t, fake{
		env: func(_ context.Context, id string) (*api.Response[api.Environment], error) {
			shown = id
			return response(api.Environment{ID: id, Slug: "app-me-1"})
		},
		ops: func(_ context.Context, id, _ string) (*api.Response[api.OperationPage], error) {
			listed = id
			return response(api.OperationPage{Items: []api.Operation{}})
		},
		act: func(_ context.Context, id, _ string, a api.Action) (*api.Response[api.OperateEnvironmentResult], error) {
			acted, action = id, a.Action
			return &api.Response[api.OperateEnvironmentResult]{StatusCode: 202, Value: api.OperateEnvironmentResult{EnvironmentID: id, OperationID: ptr(opID)}}, nil
		},
	})
	h.Environment = envID

	h.success(t, "env", "show")
	h.success(t, "op", "list")
	if shown != envID || listed != envID {
		t.Fatal(shown, listed)
	}
	for command, want := range map[string]string{"start": "start", "stop": "stop", "restart": "restart_affected"} {
		acted = ""
		h.success(t, "env", command, "--no-wait")
		if acted != envID || action != want {
			t.Fatal(command, acted, action)
		}
	}
	acted = ""
	h.success(t, "env", "restart", "--all", "--no-wait")
	if acted != envID || action != "restart_all" {
		t.Fatal(acted, action)
	}

	// Naming one still works, and is sent as named: what it may reach is
	// the control plane's to say.
	h.success(t, "env", "show", otherEnvID)
	if shown != otherEnvID {
		t.Fatal(shown)
	}
}

// Destroying is never something left unsaid, and it isn't the
// environment's to do to itself in any case.
func TestDestroyAlwaysNamesWhatItDestroys(t *testing.T) {
	h := setup(t, fake{})
	h.Environment = envID
	f := h.failure(t, "invalid_invocation", "env", "destroy", "--yes")
	if !strings.Contains(f["message"].(string), "positional") {
		t.Fatal(f)
	}
}

func TestOutsideAnEnvironmentOneMustBeNamed(t *testing.T) {
	h := setup(t, fake{})
	for _, args := range [][]string{{"env", "show"}, {"env", "restart"}, {"env", "stop"}, {"op", "list"}} {
		h.failure(t, "invalid_invocation", args...)
	}
}

// What the environment's connection can't do says where to go for it.
func TestInsideAnEnvironmentARefusalSaysHowToActAsYourself(t *testing.T) {
	h := setup(t, fake{
		repos: func(context.Context, string) (*api.Response[api.RepositoryPage], error) {
			return nil, &api.HTTPError{StatusCode: 403, Code: "insufficient_scope", Message: "The connection does not have the required scope."}
		},
	})
	h.Environment = envID

	// Nothing is saved or sent for a create.
	if f := h.failure(t, "forbidden", "env", "create", "acme/app"); !strings.Contains(f["message"].(string), "can't create environments") {
		t.Fatal(f)
	}

	h.JSON = false
	h.diag.Reset()
	if err := Run(context.Background(), []string{"repo", "list"}, h.Options); err == nil || !strings.Contains(h.diag.String(), "foreman --instance URL login") {
		t.Fatal(err, h.diag.String())
	}

	h.Environment = ""
	h.diag.Reset()
	if err := Run(context.Background(), []string{"repo", "list"}, h.Options); err == nil || strings.Contains(h.diag.String(), "Inside an environment") {
		t.Fatal(err, h.diag.String())
	}
}
