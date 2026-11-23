package workloads

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/ntodd/foreman/cli/api"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (f transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// Exercise the real generated methods using a private in-memory transport. With
// a create-only grant, any discovery, polling, or readiness read is a regression.
func TestGeneratedClientCreateOnlyAndReplay(t *testing.T) {
	var keys []string
	roundTrip := transportFunc(func(req *http.Request) (*http.Response, error) {
		if req.Method != "POST" || req.URL.Path != "/api/v1/environments" || req.Header.Get("Authorization") != "Bearer fixture" {
			t.Fatal(req.Method, req.URL.Path)
		}
		keys = append(keys, req.Header.Get("Idempotency-Key"))
		var body map[string]any
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil || len(body) != 1 || body["repo_id"] != repoID {
			t.Fatal(body, err)
		}
		if len(keys) == 1 {
			return nil, io.ErrUnexpectedEOF
		}
		return &http.Response{StatusCode: 202, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(fmt.Sprintf(`{"environment_id":%q,"operation_id":%q}`, envID, opID)))}, nil
	})
	client, err := api.NewClient("https://fixture.invalid", &http.Client{Transport: roundTrip})
	if err != nil {
		t.Fatal(err)
	}
	h := setup(t, fake{})
	h.API = client.WithBearer(func(context.Context) (string, error) { return "fixture", nil })
	h.Scopes = []string{"environments:create"}
	f := h.failure(t, "outcome_unknown", "env", "create", repoID, "--no-wait")
	key := f["request_key"].(string)
	h.success(t, "env", "create", "--resume", key, "--no-wait")
	if len(keys) != 2 || keys[0] == "" || keys[0] != key || keys[1] != key || h.doc(t)["environment_id"] != envID {
		t.Fatal(keys, h.out.String())
	}
}

func TestExpiredReplayNoWaitOnlySubmits(t *testing.T) {
	h := setup(t, fake{create: func(context.Context, string, api.Create) (*api.Response[api.Accepted], error) {
		r, _ := accepted()
		r.Value.OperationHistoryExpired = ptr(true)
		return r, nil
	}})
	h.success(t, "env", "create", repoID, "--request-key", "expired", "--no-wait")
	doc := h.doc(t)
	if doc["operation_history_expired"] != true || doc["operation_id"] != opID {
		t.Fatal(doc)
	}
}

func TestWaitFailureWritesOnlyError(t *testing.T) {
	h := setup(t, fake{op: func(context.Context, string) (*api.Response[api.Operation], error) {
		return response(api.Operation{Status: "cancelled", ID: opID, EnvironmentID: envID})
	}})
	f := h.failure(t, "operation_cancelled", "op", "wait", opID)
	if h.out.Len() != 0 || f["environment_id"] != envID {
		t.Fatal(f, h.out.String())
	}
}
