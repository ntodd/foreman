package session

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"github.com/ntodd/foreman/cli/api"
)

const ClientID = "foreman-cli"
const DefaultScope = "repos:list boxes:list environments:list environments:read operations:list operations:read logs:read environments:create environments:start environments:stop"

type Connection struct {
	Instance string `json:"instance"`
	Account  string `json:"account"`
	Scope    string `json:"scope"`
}

// Session is pinned to one origin and acting account for its lifetime.
// Client checks the credential file and refreshes on every protected request.
type Session struct {
	Connection
	Client   *api.Client
	StateDir string
}

type DevicePrompt struct{ VerificationURI, UserCode string }

func discover(ctx context.Context, instance string) (*api.Client, error) {
	c, err := api.NewClient(instance, nil)
	if err != nil {
		return nil, err
	}
	meta, err := c.GetOAuthMetadata(ctx)
	if err != nil {
		return nil, err
	}
	return c.WithOAuthEndpoints(meta.Value)
}

// Open uses the default state store. Empty selectors use the saved connection.
func Open(ctx context.Context, instance, account string) (*Session, error) {
	s, err := DefaultStore()
	if err != nil {
		return nil, err
	}
	return s.Open(ctx, instance, account)
}

func (s *Store) Open(ctx context.Context, instance, account string) (*Session, error) {
	instance, account, err := s.selectConnection(instance, account, false)
	if err != nil {
		return nil, err
	}
	dir := s.directory(instance)
	path := accountPath(dir, account)
	state, err := readCredential(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, noConnection()
	}
	if err != nil {
		return nil, err
	}
	public, err := discover(ctx, instance)
	if err != nil {
		return nil, err
	}
	client := public.WithBearer(func(ctx context.Context) (string, error) { return s.accessToken(ctx, public, path) })
	return &Session{Connection: Connection{Instance: instance, Account: account, Scope: state.Scope}, StateDir: s.root, Client: client}, nil
}

func (s *Store) accessToken(ctx context.Context, public *api.Client, path string) (string, error) {
	var token string
	err := withLock(ctx, path, func() error {
		state, err := readCredential(path)
		if errors.Is(err, os.ErrNotExist) {
			return noConnection()
		}
		if err != nil {
			return err
		}
		if err = s.retire(ctx, public, path, &state); err != nil {
			return err
		}
		if state.Expires <= unixSeconds(s.now())+30 {
			reply, err := public.ObtainToken(ctx, api.RefreshTokenGrant{GrantType: "refresh_token", ClientID: ClientID, RefreshToken: state.RefreshToken})
			if err != nil {
				var p *api.HTTPError
				if errors.As(err, &p) && p.Code == "invalid_grant" {
					return fmt.Errorf("connection expired or revoked; run login to approve a new connection: %w", err)
				}
				return err
			}
			state, err = s.credentials(reply.Value, state.Account)
			if err != nil {
				return err
			}
			if err = s.save(path, state); err != nil {
				return fmt.Errorf("could not persist the rotated connection: %w", err)
			}
		}
		token = state.AccessToken
		return nil
	})
	return token, err
}

func unixSeconds(t time.Time) float64 { return float64(t.Unix()) + float64(t.Nanosecond())/1e9 }

func (s *Store) credentials(reply api.ObtainTokenResult, account string) (credential, error) {
	if reply.AccessToken == "" || reply.RefreshToken == nil || *reply.RefreshToken == "" || reply.ExpiresIn <= 0 || !strings.EqualFold(reply.TokenType, "Bearer") {
		return credential{}, errors.New("server did not return a valid personal token grant")
	}
	return credential{Account: account, AccessToken: reply.AccessToken, RefreshToken: *reply.RefreshToken, Scope: reply.Scope, Expires: unixSeconds(s.now()) + float64(reply.ExpiresIn)}, nil
}

func revoke(ctx context.Context, public *api.Client, token string) error {
	_, err := public.RevokeToken(ctx, api.RevokeTokenBody{ClientID: new(ClientID), Token: token})
	return err
}

func (s *Store) retire(ctx context.Context, public *api.Client, path string, state *credential) error {
	if len(state.PendingRevocations) == 0 {
		return nil
	}
	// A process may have stopped after rename but before the directory fsync.
	// Confirm the replacement is durable before invalidating any previous grant.
	if err := s.syncDir(filepath.Dir(path)); err != nil {
		return err
	}
	for _, prev := range state.PendingRevocations {
		if err := revoke(ctx, public, prev); err != nil {
			return fmt.Errorf("replacement credentials saved; revocation of a previous connection is pending. Run me or logout again to retry: %w", err)
		}
	}
	state.PendingRevocations = nil
	return s.save(path, state)
}

func (s *Store) Login(ctx context.Context, instance, account, scope string, prompt func(DevicePrompt) error) (Connection, error) {
	instance, account, err := s.selectConnection(instance, account, true)
	if err != nil {
		return Connection{}, err
	}
	if prompt == nil {
		return Connection{}, errors.New("device login requires an approval prompt")
	}
	if scope == "" {
		scope = DefaultScope
	}
	public, err := discover(ctx, instance)
	if err != nil {
		return Connection{}, err
	}
	if err = s.ensureDirectory(instance); err != nil {
		return Connection{}, err
	}
	requestedAt := s.now()
	reply, err := public.RequestDeviceCode(ctx, api.RequestDeviceCodeBody{ClientID: ClientID, Scope: scope})
	if err != nil {
		return Connection{}, err
	}
	d := reply.Value
	if err = public.CheckEndpoint(d.VerificationURI); err != nil {
		return Connection{}, fmt.Errorf("verification URI: %w", err)
	}
	if d.VerificationURIComplete != nil {
		if err = public.CheckEndpoint(*d.VerificationURIComplete); err != nil {
			return Connection{}, fmt.Errorf("complete verification URI: %w", err)
		}
	}
	if d.UserCode == "" || d.DeviceCode == "" || strings.IndexFunc(d.UserCode, unicode.IsControl) >= 0 {
		return Connection{}, errors.New("invalid approval code in device response")
	}
	timeout, err := seconds(d.ExpiresIn)
	if err != nil {
		return Connection{}, err
	}
	deadline := requestedAt.Add(timeout)
	interval := 5 * time.Second
	if d.Interval != 0 {
		interval, err = seconds(d.Interval)
		if err != nil {
			return Connection{}, err
		}
	}
	if err = prompt(DevicePrompt{VerificationURI: d.VerificationURI, UserCode: d.UserCode}); err != nil {
		return Connection{}, err
	}
	tokens, err := s.poll(ctx, public, d.DeviceCode, deadline, interval)
	if err != nil {
		return Connection{}, err
	}
	return s.install(ctx, public, instance, account, tokens)
}

func seconds(n int64) (time.Duration, error) {
	if n <= 0 || n > int64((1<<63-1)/time.Second) {
		return 0, errors.New("invalid lifetime or polling interval in device response")
	}
	return time.Duration(n) * time.Second, nil
}

func (s *Store) poll(ctx context.Context, public *api.Client, deviceCode string, deadline time.Time, interval time.Duration) (api.ObtainTokenResult, error) {
	expired := errors.New("device code expired; run login again")
	for {
		if interval >= deadline.Sub(s.now()) {
			return api.ObtainTokenResult{}, expired
		}
		if err := s.sleep(ctx, interval); err != nil {
			return api.ObtainTokenResult{}, err
		}
		remaining := deadline.Sub(s.now())
		if remaining <= 0 {
			return api.ObtainTokenResult{}, expired
		}
		pollCtx, cancel := context.WithTimeout(ctx, remaining)
		reply, err := public.ObtainToken(pollCtx, api.DeviceCodeGrant{ClientID: ClientID, GrantType: "urn:ietf:params:oauth:grant-type:device_code", DeviceCode: deviceCode})
		cancel()
		if err == nil {
			return reply.Value, nil
		}
		var problem *api.HTTPError
		if !errors.As(err, &problem) {
			return api.ObtainTokenResult{}, err
		}
		switch problem.Code {
		case "authorization_pending":
		case "slow_down":
			if deadline.Sub(s.now())-interval <= 5*time.Second {
				return api.ObtainTokenResult{}, expired
			}
			interval += 5 * time.Second
		case "expired_token":
			return api.ObtainTokenResult{}, fmt.Errorf("%s: %w", expired, err)
		default:
			return api.ObtainTokenResult{}, err
		}
	}
}

func (s *Store) install(ctx context.Context, public *api.Client, instance, account string, tokens api.ObtainTokenResult) (conn Connection, err error) {
	saved := false
	defer func() {
		if err == nil || saved || tokens.RefreshToken == nil || *tokens.RefreshToken == "" {
			return
		}
		// Approval has already issued this grant. Even if a signal canceled the
		// operation, make one bounded attempt to release the unsaved connection.
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 20*time.Second)
		defer cancel()
		if cleanupErr := revoke(cleanup, public, *tokens.RefreshToken); cleanupErr != nil {
			err = fmt.Errorf("could not save or revoke the new connection; revoke the new Foreman CLI connection under Connected apps: %w", err)
		}
	}()
	state, err := s.credentials(tokens, account)
	if err != nil {
		return conn, err
	}
	client := public.WithBearer(func(context.Context) (string, error) { return state.AccessToken, nil })
	identity, err := client.GetIdentity(ctx)
	if err != nil {
		return conn, err
	}
	id := identity.Value
	if id.Kind != "user" || id.ClientID != ClientID || id.ID == "" || (account != "" && id.ID != account) {
		return conn, errors.New("the approved account does not match the selected connection")
	}
	state.Account = id.ID
	path := accountPath(s.directory(instance), id.ID)
	err = withLock(ctx, path, func() error {
		old, err := readCredential(path)
		if err == nil {
			for _, token := range append(old.PendingRevocations, old.RefreshToken) {
				if token != state.RefreshToken {
					state.PendingRevocations = append(state.PendingRevocations, token)
				}
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if err = s.save(path, state); err != nil {
			var replaced *ReplacedError
			saved = errors.As(err, &replaced)
			return err
		}
		saved = true
		if err = s.retire(ctx, public, path, &state); err != nil {
			return err
		}
		return s.remember(ctx, instance, id.ID, false)
	})
	return Connection{Instance: instance, Account: id.ID, Scope: state.Scope}, err
}

func (s *Store) Logout(ctx context.Context, instance, account string) (string, error) {
	instance, account, err := s.selectConnection(instance, account, false)
	if err != nil {
		return "", err
	}
	dir := s.directory(instance)
	path := accountPath(dir, account)
	public, err := discover(ctx, instance)
	if err != nil {
		return "", err
	}
	err = withLock(ctx, path, func() error {
		state, err := readCredential(path)
		if errors.Is(err, os.ErrNotExist) {
			return noConnection()
		}
		if err != nil {
			return err
		}
		if err = s.retire(ctx, public, path, &state); err != nil {
			return err
		}
		if err = revoke(ctx, public, state.RefreshToken); err != nil {
			return err
		}
		if err = os.Remove(path); err != nil {
			return err
		}
		if err = s.syncDir(dir); err != nil {
			return err
		}
		return s.remember(ctx, instance, account, true)
	})
	return account, err
}
