package session

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/ntodd/foreman/cli/api"
)

// EnvironmentSocket is where an environment finds the API from inside
// itself. Its box relays each request as that environment, so a command
// run there needs no login and reaches nothing else of its owner's.
const EnvironmentSocket = "/run/foreman/api.sock"

func environmentSocket() string {
	if path := os.Getenv("FOREMAN_API_SOCKET"); path != "" {
		return path
	}
	return EnvironmentSocket
}

// orOwn falls back to the environment's own connection when the command
// named no instance or account and nothing is saved to connect with. A
// login made inside an environment is used in its place until logout:
// asking for more is something a person does, on purpose.
func (s *Store) orOwn(ctx context.Context, instance, account string, session *Session, err error) (*Session, error) {
	var none notConnected
	if instance != "" || account != "" || !errors.As(err, &none) || !insideEnvironment() {
		return session, err
	}
	// A login that still works is never passed over, even when it isn't the
	// one selected: that would change who the command acts as, unasked.
	if s.saved() {
		return session, fmt.Errorf("%w\nThere are saved logins, so this environment's own connection wasn't used. Choose one with --instance, or log out of them", err)
	}
	if own, ownErr := s.own(ctx); own != nil || ownErr != nil {
		return own, ownErr
	}
	return session, err
}

func insideEnvironment() bool {
	info, err := os.Stat(environmentSocket())
	return err == nil && info.Mode()&os.ModeSocket != 0
}

var stateName = regexp.MustCompile(`^[0-9a-f]{64}$`)

// saved reports whether any login is saved, for any instance. One that
// can't be read counts: better to ask than to act as someone else.
func (s *Store) saved() bool {
	instances, err := os.ReadDir(s.root)
	if err != nil {
		return !errors.Is(err, os.ErrNotExist)
	}
	for _, instance := range instances {
		if !instance.IsDir() || !stateName.MatchString(instance.Name()) {
			continue
		}
		accounts, err := os.ReadDir(filepath.Join(s.root, instance.Name()))
		if err != nil {
			return true
		}
		for _, account := range accounts {
			name, isState := strings.CutSuffix(account.Name(), ".json")
			if isState && stateName.MatchString(name) {
				return true
			}
		}
	}
	return false
}

// own is nil outside an environment.
func (s *Store) own(ctx context.Context) (*Session, error) {
	if !insideEnvironment() {
		return nil, nil
	}
	client := api.NewSocketClient(environmentSocket())
	const login = "To connect as yourself instead: foreman --instance URL login"
	reply, err := client.GetIdentity(ctx)
	if err != nil {
		return nil, fmt.Errorf("this environment's own connection to Foreman isn't available (%w)\n%s", err, login)
	}
	env := reply.Value.Environment
	if env == nil || env.ID == "" {
		return nil, errors.New("this environment's own connection to Foreman didn't say which environment it is\n" + login)
	}
	name := env.ID
	if env.Name != nil && *env.Name != "" {
		name = *env.Name
	}
	return &Session{
		Connection:  Connection{Instance: "environment " + name, Account: reply.Value.ID},
		Client:      client,
		StateDir:    s.root,
		Environment: env,
		Identity:    reply,
	}, nil
}
