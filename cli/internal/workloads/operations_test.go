package workloads

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/ntodd/foreman/cli/api"
)

func TestFollowReusesEmptyCursorAndDrainsAfterTerminal(t *testing.T) {
	for _, status := range []string{"succeeded", "failed"} {
		t.Run(status, func(t *testing.T) {
			type read struct {
				cursor, text, next string
				truncated          bool
			}
			reads := []read{{"resume", "a", "A", true}, {"A", "", "A", false}, {"A", "", "B", false}, {"B", "z", "C", false}, {"C", "", "C", false}}
			i, states := 0, 0
			f := fake{logs: func(_ context.Context, id, cursor string) (*api.Response[api.LogPage], error) {
				if id != opID || i >= len(reads) || cursor != reads[i].cursor {
					t.Fatalf("read %d: %q", i, cursor)
				}
				r := reads[i]
				i++
				return response(api.LogPage{Text: r.text, NextCursor: r.next, Truncated: r.truncated})
			}, op: func(context.Context, string) (*api.Response[api.Operation], error) {
				states++
				state := "running"
				if states == 2 {
					state = status
				}
				return response(api.Operation{ID: opID, Status: state})
			}}
			h := setup(t, f)
			args := []string{"op", "logs", opID, "--follow", "--cursor", "resume"}
			if status == "failed" {
				info := h.failure(t, "operation_failed", args...)
				if info["cursor"] != "C" {
					t.Fatal(info)
				}
			} else {
				h.success(t, args...)
			}
			var pages []api.LogPage
			for _, line := range strings.Split(strings.TrimSpace(h.out.String()), "\n") {
				var page api.LogPage
				if err := json.Unmarshal([]byte(line), &page); err != nil {
					t.Fatal(err)
				}
				pages = append(pages, page)
			}
			if len(pages) != 5 || !pages[0].Truncated || pages[3].Text != "z" || pages[4].NextCursor != "C" || states != 2 {
				t.Fatal(pages, states)
			}
		})
	}
}

func TestSnapshotLogsAndPartialRead(t *testing.T) {
	for _, dropped := range []bool{false, true} {
		h := setup(t, fake{logs: func(_ context.Context, id, cursor string) (*api.Response[api.LogPage], error) {
			switch cursor {
			case "":
				return response(api.LogPage{Text: "first\n", Truncated: true, NextCursor: "p/1"})
			case "p/1":
				if dropped {
					return nil, errors.New("disconnected")
				}
				return response(api.LogPage{Text: "last\n", NextCursor: "p/2"})
			case "p/2":
				return response(api.LogPage{NextCursor: "p/2"})
			}
			t.Fatalf("unexpected cursor %s", cursor)
			return nil, nil
		}})
		if dropped {
			info := h.failure(t, "request_failed", "op", "logs", opID)
			if info["cursor"] != "p/1" || h.doc(t)["text"] != "first\n" {
				t.Fatal(info)
			}
		} else {
			h.success(t, "op", "logs", opID)
			doc := h.doc(t)
			if doc["text"] != "first\nlast\n" || doc["truncated"] != true || doc["next_cursor"] != "p/2" {
				t.Fatal(doc)
			}
			h.JSON = false
			h.success(t, "op", "logs", opID)
			if h.out.String() != "first\nlast\n" || !strings.Contains(h.diag.String(), "truncated") || !strings.Contains(h.diag.String(), "p/2") {
				t.Fatal(h.out.String(), h.diag.String())
			}
		}
	}
}

func TestShowAndHistoryAfterDestroy(t *testing.T) {
	f := fake{env: func(_ context.Context, id string) (*api.Response[api.Environment], error) {
		return response(api.Environment{ID: id, Slug: "dev", Branch: "topic", DesiredState: "running", ObservedState: "stopped", Readiness: "unknown", Expiry: &api.Expiry{At: "2035-01-01T00:00:00Z", Action: "destroy"}, Hostname: ptr("dev.example"), SSHUser: ptr("deploy"), WorkspaceFolder: ptr("/work")})
	}}
	h := setup(t, f)
	h.JSON = false
	h.success(t, "env", "show", envID)
	for _, field := range []string{envID, "dev.example", "deploy", "/work", "unknown", "running", "stopped", "destroy", "2035-01-01"} {
		if !strings.Contains(h.out.String(), field) {
			t.Errorf("missing %s: %s", field, h.out.String())
		}
	}

	var cursors []string
	h.API = fake{ops: func(_ context.Context, id, cursor string) (*api.Response[api.OperationPage], error) {
		if id != envID {
			t.Fatal(id)
		}
		cursors = append(cursors, cursor)
		switch cursor {
		case "":
			return response(api.OperationPage{Items: []api.Operation{{ID: opID, Trigger: "expiry", Action: "destroy"}}, NextCursor: ptr("opaque")})
		case "opaque":
			return response(api.OperationPage{Items: []api.Operation{{ID: boxID, Trigger: "request", Action: "create"}}})
		}
		t.Fatal(cursor)
		return nil, nil
	}}
	h.JSON = true
	h.success(t, "op", "list", envID)
	items := h.doc(t)["items"].([]any)
	if len(items) != 2 || !reflect.DeepEqual(cursors, []string{"", "opaque"}) {
		t.Fatal(items, cursors)
	}
}

func TestScopeAndPaginatedListErrors(t *testing.T) {
	h := setup(t, fake{envs: func(_ context.Context, c string) (*api.Response[api.EnvironmentPage], error) {
		if c == "" {
			return response(api.EnvironmentPage{Items: []api.Environment{{ID: envID}}, NextCursor: ptr("2")})
		}
		return nil, &api.HTTPError{StatusCode: 403, Code: "insufficient_scope", Message: "Grant revoked"}
	}})
	h.failure(t, "insufficient_scope", "env", "list")
	if h.out.Len() != 0 {
		t.Fatal(h.out.String())
	}
	h.API = fake{boxes: func(context.Context, string) (*api.Response[api.BoxPage], error) {
		return response(api.BoxPage{NextCursor: ptr("loop")})
	}}
	h.failure(t, "invalid_response", "box", "list")
	h.API = fake{repos: func(context.Context, string) (*api.Response[api.RepositoryPage], error) {
		return response(api.RepositoryPage{})
	}}
	h.success(t, "repo", "list")
	if len(h.doc(t)["items"].([]any)) != 0 {
		t.Fatal(h.out.String())
	}
}

func TestLogSnapshotReadsPastAnAdvancingEmptyPage(t *testing.T) {
	h := setup(t, fake{logs: func(_ context.Context, _ string, cursor string) (*api.Response[api.LogPage], error) {
		switch cursor {
		case "":
			return response(api.LogPage{NextCursor: "gap", Truncated: true})
		case "gap":
			return response(api.LogPage{Text: "final", NextCursor: "end"})
		case "end":
			return response(api.LogPage{NextCursor: "end"})
		default:
			t.Fatalf("cursor %q", cursor)
			return nil, nil
		}
	}})
	h.success(t, "op", "logs", opID)
	doc := h.doc(t)
	if doc["text"] != "final" || doc["truncated"] != true || doc["next_cursor"] != "end" {
		t.Fatal(doc)
	}
}

func TestFinalDrainReadsPastAdvancingEmptyPage(t *testing.T) {
	requests := 0
	h := setup(t, fake{
		op: func(context.Context, string) (*api.Response[api.Operation], error) {
			return response(api.Operation{ID: opID, Status: "succeeded"})
		},
		logs: func(_ context.Context, _ string, cursor string) (*api.Response[api.LogPage], error) {
			requests++
			switch requests {
			case 1:
				return response(api.LogPage{NextCursor: "first"})
			case 2:
				return response(api.LogPage{NextCursor: "last"})
			case 3:
				if cursor != "last" {
					t.Fatal(cursor)
				}
				return response(api.LogPage{Text: "drained", NextCursor: "end"})
			case 4:
				return response(api.LogPage{NextCursor: "end"})
			default:
				t.Fatal("extra read")
				return nil, nil
			}
		},
	})
	h.success(t, "op", "logs", opID, "--follow")
	if requests != 4 || !strings.Contains(h.out.String(), "drained") {
		t.Fatal(h.out.String())
	}
}
