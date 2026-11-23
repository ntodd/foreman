package workloads

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"github.com/ntodd/foreman/cli/api"
)

// A record contains everything required to replay a submission, even when the
// process is killed inside the HTTP call. No credentials are written here.
type record struct {
	Key             string     `json:"request_key"`
	Instance        string     `json:"instance"`
	Account         string     `json:"account"`
	ClientID        string     `json:"client_id"`
	Body            api.Create `json:"body"`
	CapacityWarning bool       `json:"capacity_warning,omitempty"`
}

func newKey() string {
	var raw [16]byte
	rand.Read(raw[:])
	return hex.EncodeToString(raw[:])
}

func keyValid(key string) bool {
	for _, b := range []byte(key) {
		if b < 0x20 || b > 0x7e {
			return false
		}
	}
	// Whitespace at the edge of a header value would be trimmed on the wire,
	// creating two local keys for the same remote key.
	return len(key) > 0 && key[0] != ' ' && key[len(key)-1] != ' '
}

type journal struct {
	path string
	lock *os.File
}

func journalError(err error) error {
	return &Failure{Code: "state_error", Message: "Cannot use the saved create request: " + err.Error()}
}

func (o Options) openJournal(ctx context.Context, key string) (*journal, error) {
	if !keyValid(key) {
		return nil, invalid("Use a nonblank HTTP header value for the request key, with no leading or trailing space.")
	}
	if o.StateDir == "" || o.Instance == "" || o.Account == "" || o.ClientID == "" {
		return nil, journalError(errors.New("the selected instance, identity, client and state directory are required"))
	}
	dir := filepath.Join(o.StateDir, "create-requests")
	if err := os.Mkdir(dir, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, journalError(err)
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return nil, journalError(err)
	}
	if !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return nil, journalError(fmt.Errorf("%s must be a private directory", dir))
	}
	if err := syncDir(o.StateDir); err != nil {
		return nil, journalError(err)
	}
	digest := sha256.Sum256([]byte(key))
	path := filepath.Join(dir, fmt.Sprintf("%x", digest))
	lock, err := openRegular(path+".lock", os.O_CREATE|os.O_RDWR)
	if err != nil {
		return nil, journalError(err)
	}
	// Keep lock files in place. Unlinking one could allow another process to
	// acquire a different inode while a waiter still has this one open.
	for {
		if err := ctx.Err(); err != nil {
			lock.Close()
			return nil, err
		}
		err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return &journal{path: path + ".json", lock: lock}, nil
		}
		if errors.Is(err, syscall.EINTR) {
			continue
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			lock.Close()
			return nil, journalError(err)
		}
		if err := sleep(ctx, 25*time.Millisecond); err != nil {
			lock.Close()
			return nil, err
		}
	}
}

func (j *journal) load() (*record, error) {
	file, err := openRegular(j.path, os.O_RDONLY)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, journalError(err)
	}
	defer file.Close()
	data, err := io.ReadAll(file)
	if err != nil {
		return nil, journalError(err)
	}
	var r record
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, journalError(err)
	}
	if r.Body.RepoID == "" || r.Key == "" || r.Account == "" || r.ClientID == "" || r.Instance == "" {
		return nil, journalError(errors.New("incomplete create record"))
	}
	return &r, nil
}

func (j *journal) save(r *record) error {
	dir := filepath.Dir(j.path)
	tmp, err := os.CreateTemp(dir, ".create-*")
	if err != nil {
		return journalError(err)
	}
	defer os.Remove(tmp.Name())
	err = json.NewEncoder(tmp).Encode(r)
	if err == nil {
		err = tmp.Sync()
	}
	closeErr := tmp.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(tmp.Name(), j.path)
	}
	if err == nil {
		err = syncDir(dir)
	}
	if err != nil {
		return journalError(err)
	}
	return nil
}

func openRegular(path string, flags int) (*os.File, error) {
	file, err := os.OpenFile(path, flags|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0600)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err == nil && !info.Mode().IsRegular() {
		err = fmt.Errorf("%s must be a regular file", path)
	}
	if err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}

func syncDir(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
