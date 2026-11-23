// Package session manages personal OAuth connections shared with bin/foreman.
package session

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/ntodd/foreman/cli/api"
)

// Store holds the Foreman state root, normally $XDG_STATE_HOME/foreman.
type Store struct {
	root    string
	now     func() time.Time
	sleep   func(context.Context, time.Duration) error
	rename  func(string, string) error
	syncDir func(string) error
}

func NewStore(root string) *Store {
	return &Store{root: root, now: time.Now, sleep: wait, rename: os.Rename, syncDir: syncDirectory}
}

func DefaultStore() (*Store, error) {
	root := os.Getenv("XDG_STATE_HOME")
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		root = filepath.Join(home, ".local", "state")
	}
	return NewStore(filepath.Join(root, "foreman")), nil
}

func wait(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-timer.C:
		return ctx.Err()
	case <-ctx.Done():
		return ctx.Err()
	}
}

type credential struct {
	Account            string   `json:"account"`
	AccessToken        string   `json:"access_token"`
	RefreshToken       string   `json:"refresh_token"`
	Expires            float64  `json:"expires"`
	Scope              string   `json:"scope"`
	PendingRevocations []string `json:"pending_revocations,omitempty"`
	RefreshPending     bool     `json:"refresh_pending,omitempty"`
	VerifyRotation     bool     `json:"verify_rotation,omitempty"`
}

type selections struct {
	Instance string            `json:"instance"`
	Accounts map[string]string `json:"accounts"`
}

func hash(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func (s *Store) directory(instance string) string { return filepath.Join(s.root, hash(instance)) }
func accountPath(directory, account string) string {
	return filepath.Join(directory, hash(account)+".json")
}

func (s *Store) ensureDirectory(instance string) error {
	if err := os.MkdirAll(s.root, 0700); err != nil {
		return err
	}
	path := s.directory(instance)
	err := os.Mkdir(path, 0700)
	if err == nil {
		return s.syncDir(s.root)
	}
	if !errors.Is(err, os.ErrExist) {
		return err
	}
	return checkDirectory(path)
}

func checkDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("%s must be an instance directory", path)
	}
	return nil
}

func syncDirectory(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

// ReplacedError means rename succeeded. The file is already visible and
// callers must keep the new grant until a subsequent directory sync succeeds.
type ReplacedError struct{ cause error }

func (e *ReplacedError) Error() string {
	return "state was replaced but its directory could not be synced; retry before retiring the previous connection: " + e.cause.Error()
}
func (e *ReplacedError) Unwrap() error { return e.cause }

func (s *Store) save(path string, value any) error {
	dir := filepath.Dir(path)
	file, err := os.CreateTemp(dir, ".foreman-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	err = json.NewEncoder(file).Encode(value)
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = s.rename(file.Name(), path); err != nil {
		return err
	}
	if err = s.syncDir(dir); err != nil {
		return &ReplacedError{cause: err}
	}
	return nil
}

func readState(path string, value any) error {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("%s must be a regular state file", path)
	}
	data, err := io.ReadAll(file)
	if err != nil {
		return err
	}
	if err = json.Unmarshal(data, value); err != nil {
		return fmt.Errorf("invalid state in %s: %w", path, err)
	}
	return nil
}

func readCredential(path string) (credential, error) {
	var c credential
	if err := readState(path, &c); err != nil {
		return c, err
	}
	if c.Account == "" || accountPath(filepath.Dir(path), c.Account) != path || c.RefreshToken == "" || c.AccessToken == "" {
		return c, errors.New("invalid saved connection; check the selected account file")
	}
	for _, token := range c.PendingRevocations {
		if token == "" || token == c.RefreshToken {
			return c, errors.New("invalid pending revocation in saved connection")
		}
	}
	return c, nil
}

// bin/foreman uses flock on this same stable .lock inode, independent of
// credential renames. Never delete lock files, including at logout.
func withLock(ctx context.Context, path string, action func() error) error {
	lockPath := strings.TrimSuffix(path, ".json") + ".lock"
	file, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("invalid connection lock")
	}
	for {
		if err = ctx.Err(); err != nil {
			return err
		}
		err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return action()
		}
		if err == syscall.EINTR {
			continue
		}
		if err != syscall.EWOULDBLOCK {
			return err
		}
		if err = wait(ctx, 20*time.Millisecond); err != nil {
			return err
		}
	}
}

func (s *Store) preferences() (selections, error) {
	p := selections{Accounts: make(map[string]string)}
	err := readState(filepath.Join(s.root, "selection.json"), &p)
	if errors.Is(err, os.ErrNotExist) {
		err = nil
	}
	if p.Accounts == nil {
		p.Accounts = make(map[string]string)
	}
	return p, err
}

// Call while holding the account lock; no path takes these two locks in reverse.
func (s *Store) remember(ctx context.Context, instance, account string, pinLogout bool) error {
	path := filepath.Join(s.root, "selection.json")
	return withLock(ctx, path, func() error {
		p, err := s.preferences()
		if err != nil {
			return err
		}
		if pinLogout {
			if saved := p.Accounts[instance]; saved != "" {
				if saved != account {
					return errors.New("the selected account changed; specify --account to log out")
				}
				// A previous pin can be visible after its directory sync failed.
				return s.syncDir(s.root)
			}
		} else {
			p.Instance = instance
		}
		p.Accounts[instance] = account
		return s.save(path, p)
	})
}

func (s *Store) selectConnection(instance, account, command string) (string, string, error) {
	var p selections
	if instance == "" || account == "" {
		var err error
		p, err = s.preferences()
		if err != nil {
			return "", "", err
		}
	}
	if instance == "" {
		instance = p.Instance
	}
	if instance == "" {
		return "", "", errors.New("select --instance to connect to Foreman")
	}
	origin, err := api.Origin(instance)
	if err != nil {
		return "", "", err
	}
	dir := s.directory(origin)
	if err = checkDirectory(dir); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			if command == "login" {
				return origin, account, nil
			}
			return "", "", noConnection()
		}
		return "", "", err
	}
	if account != "" {
		return origin, account, nil
	}
	// The checkout CLI may have removed a selected account. Reads can still
	// discover the origin's remaining connections.
	if saved := p.Accounts[origin]; saved != "" {
		// A destructive retry stays pinned even if an earlier logout already
		// unlinked the file. Only an explicit selection may move it elsewhere.
		if command == "logout" {
			return origin, saved, nil
		}
		_, err = os.Lstat(accountPath(dir, saved))
		if err == nil {
			if command == "login" {
				// The browser may approve a new account on this origin.
				return origin, "", nil
			}
			return origin, saved, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return "", "", err
		}
	}
	accounts, err := accountsIn(dir)
	if err != nil {
		return "", "", err
	}
	if len(accounts) > 1 {
		return "", "", fmt.Errorf("select --account from %s", strings.Join(accounts, ", "))
	}
	if command == "login" {
		return origin, "", nil
	}
	if len(accounts) == 1 {
		return origin, accounts[0], nil
	}
	return "", "", noConnection()
}

func accountsIn(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var accounts []string
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		c, err := readCredential(filepath.Join(dir, entry.Name()))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		accounts = append(accounts, c.Account)
	}
	slices.Sort(accounts)
	return accounts, nil
}

func noConnection() error { return errors.New("no connection for this account; run login first") }
