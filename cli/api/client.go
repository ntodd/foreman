// Package api is the typed HTTP client for the Foreman OpenAPI contract.
package api

//go:generate ruby generate.rb

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"
)

// Response includes the unmodified JSON so callers can forward additional
// fields, plus the typed view, status and headers for control flow.
type Response[T any] struct {
	Value      T
	StatusCode int
	Header     http.Header
	Body       json.RawMessage
}

// HTTPError carries the API code or OAuth error and the original error body.
type HTTPError struct {
	Code, Message string
	StatusCode    int
	Body          json.RawMessage
}

func (e *HTTPError) Error() string {
	if e.Code == e.Message {
		return e.Code
	}
	return e.Code + ": " + e.Message
}

type Client struct {
	origin               string
	http                 *http.Client
	discovered           map[string]string
	token                func(context.Context) (string, error)
	basicID, basicSecret string
}

func validURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || u.User != nil || u.Opaque != "" || strings.Contains(raw, "#") {
		return nil, errors.New("select an HTTPS instance URL (local development may use loopback HTTP)")
	}
	local := strings.ToLower(u.Hostname()) == "localhost" || u.Hostname() == "127.0.0.1" || u.Hostname() == "::1"
	if u.Scheme != "https" && !(local && u.Scheme == "http") {
		return nil, errors.New("select an HTTPS instance URL (local development may use loopback HTTP)")
	}
	return u, nil
}

// Origin validates a selected origin. Its spelling matches the Python CLI's
// state directory key, including an explicit default port.
func Origin(raw string) (string, error) {
	u, err := validURL(raw)
	if err != nil {
		return "", err
	}
	if strings.Trim(u.EscapedPath(), "/") != "" || u.RawQuery != "" || u.ForceQuery {
		return "", errors.New("select an instance origin without a path, query, or fragment")
	}
	return u.Scheme + "://" + u.Host, nil
}

func NewClient(instance string, h *http.Client) (*Client, error) {
	origin, err := Origin(instance)
	if err != nil {
		return nil, err
	}
	if h == nil {
		h = http.DefaultClient
	}
	client := *h
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	if client.Timeout == 0 {
		client.Timeout = 20 * time.Second
	}
	return &Client{origin: origin, http: &client}, nil
}

// CheckEndpoint checks even endpoints that are only displayed to the user.
func (c *Client) CheckEndpoint(endpoint string) error {
	u, err := validURL(endpoint)
	if err != nil || u.Scheme+"://"+u.Host != c.origin {
		return errors.New("advertised URL is outside the selected instance")
	}
	return nil
}

func (c Client) WithOAuthEndpoints(meta GetOAuthMetadataResult) (*Client, error) {
	if meta.Issuer != c.origin {
		return nil, errors.New("advertised issuer does not match the selected instance")
	}
	c.discovered = map[string]string{"RequestDeviceCode": meta.DeviceAuthorizationEndpoint, "ObtainToken": meta.TokenEndpoint, "RevokeToken": meta.RevocationEndpoint}
	for op, endpoint := range c.discovered {
		if err := c.CheckEndpoint(endpoint); err != nil {
			return nil, fmt.Errorf("%s: %w", op, err)
		}
	}
	return &c, nil
}

// WithBearer obtains a current access token before each protected request.
func (c Client) WithBearer(source func(context.Context) (string, error)) *Client {
	c.token = source
	return &c
}

// WithBasicAuth authenticates service-client token exchange and revocation.
func (c Client) WithBasicAuth(id, secret string) *Client {
	c.basicID = id
	c.basicSecret = secret
	return &c
}

type request struct {
	method, path, oauthOperation, cursor, key string
	form                                      url.Values
	body                                      any
	bearer, basic, emptyResponse              bool
	success                                   []int
}

func call[T any](ctx context.Context, c *Client, s request) (*Response[T], error) {
	target := c.origin + s.path
	if endpoint, ok := c.discovered[s.oauthOperation]; ok {
		target = endpoint
	}
	if s.cursor != "" {
		target += "?" + url.Values{"cursor": {s.cursor}}.Encode()
	}
	if err := c.CheckEndpoint(target); err != nil {
		return nil, err
	}
	var body io.Reader
	var contentType string
	switch {
	case s.form != nil:
		body = strings.NewReader(s.form.Encode())
		contentType = "application/x-www-form-urlencoded"
	case s.body != nil:
		b, err := json.Marshal(s.body)
		if err != nil {
			return nil, err
		}
		body = bytes.NewReader(b)
		contentType = "application/json"
	}
	req, err := http.NewRequestWithContext(ctx, s.method, target, body)
	if err != nil {
		return nil, err
	}
	if req.URL.Scheme == "http" {
		// Go's environment proxy exemption compares the literal name "localhost".
		// Keep the legacy origin spelling on disk, and use lowercase on the wire.
		req.URL.Host = strings.ToLower(req.URL.Host)
	}
	// Mutations and single-use refresh grants must never be replayed by the transport.
	req.GetBody = nil
	req.Header.Set("Accept", "application/json")
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if s.key != "" {
		req.Header.Set("Idempotency-Key", s.key)
	}
	if s.bearer && c.token != nil {
		token, err := c.token(ctx)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if s.basic && c.basicID != "" {
		req.SetBasicAuth(c.basicID, c.basicSecret)
	}
	res, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	const maxBody = 32 << 20
	data, err := io.ReadAll(io.LimitReader(res.Body, maxBody+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxBody {
		return nil, errors.New("response exceeds 32 MiB")
	}
	if !slices.Contains(s.success, res.StatusCode) {
		var problem struct {
			Code, Message, Error string
			Description          string `json:"error_description"`
		}
		_ = json.Unmarshal(data, &problem)
		if problem.Code == "" {
			problem.Code = problem.Error
		}
		if problem.Code == "" {
			problem.Code = "http_error"
		}
		if problem.Message == "" {
			problem.Message = problem.Description
		}
		if problem.Message == "" {
			problem.Message = fmt.Sprintf("HTTP %d %s", res.StatusCode, http.StatusText(res.StatusCode))
		}
		return nil, &HTTPError{StatusCode: res.StatusCode, Code: problem.Code, Message: problem.Message, Body: data}
	}
	reply := &Response[T]{StatusCode: res.StatusCode, Header: res.Header, Body: data}
	if !s.emptyResponse {
		if err = json.Unmarshal(data, &reply.Value); err != nil {
			return nil, fmt.Errorf("invalid JSON response: %w", err)
		}
	}
	return reply, nil
}
