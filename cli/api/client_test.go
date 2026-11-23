package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"testing"
)

func TestContractRequests(t *testing.T) {
	ctx := context.Background()
	type expected struct {
		method, target, auth, key, body, reply string
		status                                 int
	}
	var want expected
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != want.method || r.URL.RequestURI() != want.target || r.Header.Get("Authorization") != want.auth || r.Header.Get("Idempotency-Key") != want.key {
			t.Errorf("request %s %s auth=%q key=%q; expected %+v", r.Method, r.URL.RequestURI(), r.Header.Get("Authorization"), r.Header.Get("Idempotency-Key"), want)
		}
		if r.Body != nil {
			got, _ := io.ReadAll(r.Body)
			if len(got) > 0 && got[0] != '{' {
				form, _ := url.ParseQuery(string(got))
				expectedForm, _ := url.ParseQuery(want.body)
				if !reflect.DeepEqual(form, expectedForm) || r.Header.Get("Content-Type") != "application/x-www-form-urlencoded" {
					t.Errorf("unexpected form or encoding: %q", got)
				}
			} else if string(got) != want.body {
				t.Errorf("body = %q, want %q", got, want.body)
			}
		}
		w.Header().Set("Location", "/api/v1/operations/op")
		w.WriteHeader(want.status)
		io.WriteString(w, want.reply)
	}))
	defer server.Close()
	client, err := NewClient(server.URL, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	client = client.WithBearer(func(context.Context) (string, error) { return "test-access", nil })
	bearer := "Bearer test-access"
	tests := []struct {
		expected
		call func() error
	}{
		{expected{"GET", "/.well-known/oauth-authorization-server", "", "", "", "{}", 200}, func() error { _, e := client.GetOAuthMetadata(ctx); return e }},
		{expected{"POST", "/oauth/device/code", "", "", "client_id=cli&scope=repos:list", "{}", 200}, func() error {
			_, e := client.RequestDeviceCode(ctx, RequestDeviceCodeBody{ClientID: "cli", Scope: "repos:list"})
			return e
		}},
		{expected{"POST", "/oauth/token", "", "", "grant_type=refresh_token&client_id=cli&refresh_token=old", "{}", 200}, func() error {
			_, e := client.ObtainToken(ctx, RefreshTokenGrant{GrantType: "refresh_token", ClientID: "cli", RefreshToken: "old"})
			return e
		}},
		{expected{"POST", "/oauth/revoke", "", "", "client_id=cli&token=old", "", 200}, func() error {
			_, e := client.RevokeToken(ctx, RevokeTokenBody{ClientID: new("cli"), Token: "old"})
			return e
		}},
		{expected{"GET", "/api/v1/me", bearer, "", "", "{}", 200}, func() error { _, e := client.GetIdentity(ctx); return e }},
		{expected{"GET", "/api/v1/repos?cursor=a%2Fb%2B", bearer, "", "", `{"items":[{"id":"r"}],"next_cursor":null}`, 200}, func() error {
			v, e := client.ListRepos(ctx, "a/b+")
			if e == nil && (len(v.Value.Items) != 1 || v.Value.Items[0].ID != "r" || v.Value.NextCursor != nil) {
				t.Error(v)
			}
			return e
		}},
		{expected{"GET", "/api/v1/boxes", bearer, "", "", "{}", 200}, func() error { _, e := client.ListBoxes(ctx, ""); return e }},
		{expected{"GET", "/api/v1/environments", bearer, "", "", "{}", 200}, func() error { _, e := client.ListEnvironments(ctx, ""); return e }},
		{expected{"POST", "/api/v1/environments", bearer, "retry", `{"repo_id":"r"}`, `{"operation_id":"op","environment_id":"env"}`, 202}, func() error {
			v, e := client.CreateEnvironment(ctx, "retry", Create{RepoID: "r"})
			if e == nil && (v.StatusCode != 202 || v.Header.Get("Location") == "" || v.Value.OperationID != "op") {
				t.Error(v)
			}
			return e
		}},
		{expected{"GET", "/api/v1/environments/x%2Fy", bearer, "", "", "{}", 200}, func() error { _, e := client.GetEnvironment(ctx, "x/y"); return e }},
		{expected{"GET", "/api/v1/environments/env/operations?cursor=c", bearer, "", "", "{}", 200}, func() error { _, e := client.ListEnvironmentOperations(ctx, "env", "c"); return e }},
		{expected{"POST", "/api/v1/environments/env/operations", bearer, "retry", `{"action":"start"}`, `{"environment_id":"env"}`, 200}, func() error {
			v, e := client.OperateEnvironment(ctx, "env", "retry", Action{Action: "start"})
			if e == nil && (v.Value.EnvironmentID != "env" || v.Value.OperationID != nil) {
				t.Error(v)
			}
			return e
		}},
		{expected{"GET", "/api/v1/operations/op", bearer, "", "", "{}", 200}, func() error { _, e := client.GetOperation(ctx, "op"); return e }},
		{expected{"GET", "/api/v1/operations/op/logs?cursor=c", bearer, "", "", "{}", 200}, func() error { _, e := client.GetOperationLogs(ctx, "op", "c"); return e }},
	}
	for _, tt := range tests {
		want = tt.expected
		t.Run(want.method+" "+want.target, func(t *testing.T) {
			if err := tt.call(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestOriginsRedirectsAndErrors(t *testing.T) {
	for _, s := range []string{"http://example.com", "http://127.0.0.1.evil", "https://user@example.com", "https://example.com/path", "https://example.com?", "https://example.com#", "//example.com"} {
		if _, e := NewClient(s, nil); e == nil {
			t.Errorf("accepted origin %q", s)
		}
	}
	for _, s := range []string{"https://example.com", "http://127.0.0.1:123", "http://localhost", "http://[::1]"} {
		if _, e := NewClient(s, nil); e != nil {
			t.Errorf("%s: %v", s, e)
		}
	}
	foreign := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("followed redirect") }))
	defer foreign.Close()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/me" {
			http.Redirect(w, r, foreign.URL, 307)
			return
		}
		w.WriteHeader(409)
		io.WriteString(w, `{"code":"lifecycle_conflict","message":"busy","details":{"id":"op"}}`)
	}))
	defer s.Close()
	c, _ := NewClient(s.URL, nil)
	c = c.WithBearer(func(context.Context) (string, error) { return "private", nil })
	if _, err := c.GetIdentity(context.Background()); err == nil {
		t.Fatal("accepted redirect")
	}
	_, err := c.CreateEnvironment(context.Background(), "k", Create{RepoID: "r"})
	var problem *HTTPError
	if !errors.As(err, &problem) || problem.Code != "lifecycle_conflict" || problem.Message != "busy" || problem.StatusCode != 409 || !json.Valid(problem.Body) {
		t.Fatal(err)
	}
}

func TestServiceExchangeUsesBasicAuthOnlyOnTokenEndpoints(t *testing.T) {
	mux := http.NewServeMux()
	s := httptest.NewServer(mux)
	defer s.Close()
	mux.HandleFunc("/oauth/token", func(w http.ResponseWriter, r *http.Request) {
		id, secret, ok := r.BasicAuth()
		if !ok || id != "installation" || secret != "service-secret" || r.PostFormValue("grant_type") != "client_credentials" ||
			r.PostFormValue("scope") != "logs:read" || r.PostFormValue("client_id") != "" || r.PostFormValue("client_secret") != "" {
			t.Error("incorrect service grant encoding")
		}
		io.WriteString(w, `{"access_token":"access","expires_in":900,"token_type":"Bearer","scope":"logs:read"}`)
	})
	mux.HandleFunc("/.well-known/oauth-authorization-server", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" {
			t.Error("credentials on discovery")
		}
		io.WriteString(w, "{}")
	})
	client, err := NewClient(s.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	client = client.WithBasicAuth("installation", "service-secret")
	if _, err = client.GetOAuthMetadata(context.Background()); err != nil {
		t.Fatal(err)
	}
	res, err := client.ObtainToken(context.Background(), ClientCredentialsGrant{GrantType: "client_credentials", Scope: new("logs:read")})
	if err != nil || res.Value.AccessToken != "access" || res.Value.RefreshToken != nil {
		t.Fatal(res, err)
	}
}
