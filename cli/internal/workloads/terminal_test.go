package workloads

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/ntodd/foreman/cli/api"
)

const (
	otherEnvID = "eeeeeeee-0000-4000-8000-222222222222"
	otherBoxID = "bbbbbbbb-0000-4000-8000-222222222222"
)

var noon = time.Date(2026, 11, 24, 12, 0, 0, 0, time.UTC)

// terminal is what a person sees: standard output is a terminal and --json is off.
func terminal(t *testing.T, f fake) *fixture {
	h := setup(t, f)
	h.JSON = false
	h.Pretty = true
	h.Now = func() time.Time { return noon }
	return h
}

func repos(rows ...api.Repository) func(context.Context, string) (*api.Response[api.RepositoryPage], error) {
	return func(context.Context, string) (*api.Response[api.RepositoryPage], error) {
		return response(api.RepositoryPage{Items: rows})
	}
}

func boxes(rows ...api.Box) func(context.Context, string) (*api.Response[api.BoxPage], error) {
	return func(context.Context, string) (*api.Response[api.BoxPage], error) {
		return response(api.BoxPage{Items: rows})
	}
}

func envs(rows ...api.Environment) func(context.Context, string) (*api.Response[api.EnvironmentPage], error) {
	return func(context.Context, string) (*api.Response[api.EnvironmentPage], error) {
		return response(api.EnvironmentPage{Items: rows})
	}
}

func TestATerminalGetsAlignedListsWithTheNameFirst(t *testing.T) {
	h := terminal(t, fake{
		repos: repos(api.Repository{ID: repoID, FullName: "acme/app", DefaultBranch: "main"}),
		boxes: boxes(api.Box{ID: boxID, Name: "one", Online: true}, api.Box{ID: otherBoxID, Name: "number-two", Online: false}),
	})
	h.success(t, "box", "list")
	want := "BOX         STATUS   ID\n" +
		"one         online   " + boxID + "\n" +
		"number-two  offline  " + otherBoxID + "\n"
	if h.out.String() != want {
		t.Fatalf("%q\n%q", h.out.String(), want)
	}
	h.success(t, "repo", "list")
	want = "REPOSITORY  DEFAULT BRANCH  ID\n" +
		"acme/app    main            " + repoID + "\n"
	if h.out.String() != want {
		t.Fatalf("%q\n%q", h.out.String(), want)
	}
}

func TestColourMarksWhatNeedsAttention(t *testing.T) {
	h := terminal(t, fake{boxes: boxes(api.Box{ID: boxID, Name: "one", Online: true}, api.Box{ID: otherBoxID, Name: "two", Online: false})})
	h.Colour = true
	h.success(t, "box", "list")
	want := "\x1b[2mBOX  STATUS   ID\x1b[0m\n" +
		"one  \x1b[32monline\x1b[0m   \x1b[2m" + boxID + "\x1b[0m\n" +
		"two  \x1b[31moffline\x1b[0m  \x1b[2m" + otherBoxID + "\x1b[0m\n"
	if h.out.String() != want {
		t.Fatalf("%q\n%q", h.out.String(), want)
	}
}

func TestAPipeKeepsTheTabSeparatedColumnsScriptsRead(t *testing.T) {
	h := setup(t, fake{
		boxes: boxes(api.Box{ID: boxID, Name: "one", Online: true}),
		envs:  envs(api.Environment{ID: envID, Slug: "app-me-1", RepoID: repoID, BoxID: boxID, Branch: "main", DesiredState: "running", ObservedState: "stopped", Readiness: "not_ready", CreatedAt: ptr("2026-11-21T12:00:00Z")}),
	})
	h.JSON = false
	h.success(t, "box", "list")
	if h.out.String() != "ID\tBOX\tONLINE\n"+boxID+"\tone\ttrue\n" {
		t.Fatalf("%q", h.out.String())
	}
	// No lookups of repository or box names either: the fake has no repos.
	h.success(t, "env", "list")
	if h.out.String() != "ID\tENVIRONMENT\tBRANCH\tDESIRED\tOBSERVED\tREADINESS\n"+envID+"\tapp-me-1\tmain\trunning\tstopped\tnot_ready\n" {
		t.Fatalf("%q", h.out.String())
	}
}

func TestEnvironmentsShowOneStatusWithRepositoryBoxAndAge(t *testing.T) {
	h := terminal(t, fake{
		repos: repos(api.Repository{ID: repoID, FullName: "acme/app", DefaultBranch: "main"}),
		boxes: boxes(api.Box{ID: boxID, Name: "one", Online: true}),
		envs: envs(
			api.Environment{ID: envID, Slug: "app-me-1", RepoID: repoID, BoxID: boxID, Branch: "main", DesiredState: "running", ObservedState: "running", Readiness: "ready", CreatedAt: ptr("2026-11-21T11:00:00Z")},
			api.Environment{ID: otherEnvID, Slug: "app-me-2", RepoID: repoID, BoxID: otherBoxID, Branch: "fix/thing", DesiredState: "running", ObservedState: "stopped", Readiness: "not_ready", CreatedAt: ptr("2026-11-24T07:00:00Z")},
		),
	})
	h.success(t, "env", "list")
	// A box the caller can't see by name is shown by its ID.
	want := "ENVIRONMENT  STATUS             REPOSITORY  BRANCH     BOX                                   AGE  ID\n" +
		"app-me-1     running            acme/app    main       one                                   3d   " + envID + "\n" +
		"app-me-2     stopped → running  acme/app    fix/thing  " + otherBoxID + "  5h   " + otherEnvID + "\n"
	if h.out.String() != want {
		t.Fatalf("\n%s\n%s", h.out.String(), want)
	}
}

func TestEnvironmentListSurvivesMissingNamesAndAnOlderServer(t *testing.T) {
	denied := &api.HTTPError{StatusCode: 403, Code: "insufficient_scope", Message: "no"}
	h := terminal(t, fake{
		repos: func(context.Context, string) (*api.Response[api.RepositoryPage], error) { return nil, denied },
		boxes: func(context.Context, string) (*api.Response[api.BoxPage], error) { return nil, denied },
		// A server from before created_at has no age to show.
		envs: envs(api.Environment{ID: envID, Slug: "app-me-1", RepoID: repoID, BoxID: boxID, Branch: "main", DesiredState: "stopped", ObservedState: "stopped", Readiness: "not_ready"}),
	})
	h.success(t, "env", "list")
	want := "ENVIRONMENT  STATUS   REPOSITORY                            BRANCH  BOX                                   ID\n" +
		"app-me-1     stopped  " + repoID + "  main    " + boxID + "  " + envID + "\n"
	if h.out.String() != want || h.diag.Len() != 0 {
		t.Fatalf("\n%s\n%s\n%s", h.out.String(), want, h.diag.String())
	}
}

func TestStatusSaysWhereAnEnvironmentIsAndWhereItIsHeaded(t *testing.T) {
	for _, c := range []struct{ desired, observed, readiness, want string }{
		{"running", "running", "ready", "running"},
		{"running", "running", "not_ready", "running (not ready)"},
		{"running", "running", "unknown", "running (unconfirmed)"},
		{"running", "partial", "ready", "partly running"},
		{"running", "pending", "not_ready", "queued"},
		{"running", "creating", "not_ready", "creating"},
		{"running", "starting", "not_ready", "starting"},
		{"stopped", "stopping", "not_ready", "stopping"},
		{"stopped", "stopped", "not_ready", "stopped"},
		{"running", "stopped", "not_ready", "stopped → running"},
		{"stopped", "running", "ready", "running → stopped"},
		{"destroyed", "stopped", "not_ready", "stopped → destroyed"},
		{"destroyed", "destroying", "not_ready", "destroying"},
		{"running", "error", "not_ready", "error"},
		{"running", "missing", "unknown", "missing"},
		{"suspended", "suspended", "not_ready", "suspended"},
		{"running", "something-new", "not_ready", "something-new"},
	} {
		got := status(api.Environment{DesiredState: c.desired, ObservedState: c.observed, Readiness: c.readiness})
		if got.Text != c.want {
			t.Errorf("%v: %q", c, got.Text)
		}
	}
}

func TestOperationsListLeadsWithWhatHappened(t *testing.T) {
	h := terminal(t, fake{ops: func(_ context.Context, id, _ string) (*api.Response[api.OperationPage], error) {
		if id != envID {
			t.Fatal(id)
		}
		return response(api.OperationPage{Items: []api.Operation{
			{ID: opID, EnvironmentID: envID, Action: "start", Trigger: "api", Status: "succeeded"},
			{ID: otherEnvID, EnvironmentID: envID, Action: "create", Trigger: "user", Status: "failed"},
		}})
	}})
	h.success(t, "op", "list", envID)
	want := "ACTION  STATUS     TRIGGER  ID\n" +
		"start   succeeded  api      " + opID + "\n" +
		"create  failed     user     " + otherEnvID + "\n"
	if h.out.String() != want {
		t.Fatalf("\n%s\n%s", h.out.String(), want)
	}
}

func TestAnEmptyListSaysSo(t *testing.T) {
	h := terminal(t, fake{boxes: boxes(), repos: repos(), envs: envs()})
	for command, want := range map[string]string{"box": "No boxes.\n", "repo": "No repositories.\n", "env": "No environments.\n"} {
		h.success(t, command, "list")
		if h.out.String() != want {
			t.Fatalf("%q", h.out.String())
		}
	}
}

func TestEnvironmentsAreNamedBySlug(t *testing.T) {
	var shown, listed, acted string
	h := setup(t, fake{
		envs: envs(api.Environment{ID: envID, Slug: "app-me-1"}, api.Environment{ID: otherEnvID, Slug: "app-me-2"}),
		env: func(_ context.Context, id string) (*api.Response[api.Environment], error) {
			shown = id
			return response(api.Environment{ID: id, Slug: "app-me-2"})
		},
		ops: func(_ context.Context, id, _ string) (*api.Response[api.OperationPage], error) {
			listed = id
			return response(api.OperationPage{Items: []api.Operation{}})
		},
		act: func(_ context.Context, id, _ string, _ api.Action) (*api.Response[api.OperateEnvironmentResult], error) {
			acted = id
			return &api.Response[api.OperateEnvironmentResult]{StatusCode: 202, Value: api.OperateEnvironmentResult{EnvironmentID: id, OperationID: ptr(opID)}}, nil
		},
	})
	h.success(t, "env", "show", "app-me-2")
	h.success(t, "op", "list", "app-me-2")
	for _, action := range []string{"start", "stop", "restart", "destroy"} {
		acted = ""
		args := []string{"env", action, "app-me-2", "--no-wait"}
		if action == "destroy" {
			args = append(args, "--yes")
		}
		h.success(t, args...)
		if acted != otherEnvID || h.doc(t)["environment_id"] != otherEnvID {
			t.Fatal(action, acted, h.out.String())
		}
	}
	if shown != otherEnvID || listed != otherEnvID {
		t.Fatal(shown, listed)
	}
	if f := h.failure(t, "resource_not_found", "env", "show", "app-me-9"); !strings.Contains(f["message"].(string), `No visible environment matches "app-me-9"`) {
		t.Fatal(f)
	}
	// An operation has no name, and a name can't hold these characters.
	h.failure(t, "invalid_invocation", "op", "show", "app-me-2")
	h.failure(t, "invalid_invocation", "env", "show", "App Me")
}

func TestAnIDNeedsNoPermissionToListEnvironments(t *testing.T) {
	// The fake has no environment list, so asking for one fails the test.
	h := setup(t, fake{env: func(_ context.Context, id string) (*api.Response[api.Environment], error) {
		return response(api.Environment{ID: id, Slug: "app-me-1"})
	}})
	h.success(t, "env", "show", strings.ToUpper(envID))
	if h.doc(t)["slug"] != "app-me-1" {
		t.Fatal(h.out.String())
	}
}

func TestDestroyByNameAsksAboutTheEnvironmentItFound(t *testing.T) {
	h := setup(t, fake{envs: envs(api.Environment{ID: envID, Slug: "app-me-1"})})
	h.JSON = false
	h.Interactive = true
	h.In = strings.NewReader("no\n")
	if err := h.run(t, "env", "destroy", "app-me-1"); err == nil {
		t.Fatal("destroyed without confirmation")
	}
	if !strings.Contains(h.diag.String(), "Destroy environment app-me-1 ("+envID+") and remove its disk? [y/N]") {
		t.Fatal(h.diag.String())
	}
}
