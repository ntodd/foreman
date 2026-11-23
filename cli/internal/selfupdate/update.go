package selfupdate

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

// These origins are fixed in release builds. The local release rehearsal
// substitutes its loopback fixture at link time.
var releaseFeed = "https://api.github.com/repos/ntodd/foreman/releases?per_page=100"
var releaseDownloads = "https://github.com/ntodd/foreman/releases/download"

type updater struct {
	feed, download         string
	client                 *http.Client
	state, bin, executable string
}

func defaults() (updater, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return updater{}, err
	}
	exe, err := os.Executable()
	if err != nil {
		return updater{}, err
	}
	state := os.Getenv("XDG_STATE_HOME")
	if !filepath.IsAbs(state) {
		state = filepath.Join(home, ".local", "state")
	}
	// Dedicated anonymous client, with no Foreman transport, cookie jar or
	// account state. A release asset may redirect to GitHub's HTTPS CDN.
	client := &http.Client{CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 || req.URL.Scheme != via[0].URL.Scheme || req.URL.User != nil {
			return errors.New("invalid release redirect")
		}
		return nil
	}}
	return updater{feed: releaseFeed, download: releaseDownloads, client: client,
		state: filepath.Join(state, "foreman", "cli-update"), bin: filepath.Join(home, ".local", "bin", "foreman"), executable: exe}, nil
}

func (u updater) lock(name string) (*os.File, error) {
	if err := os.MkdirAll(u.state, 0700); err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(filepath.Join(u.state, name), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, fmt.Errorf("another CLI install or check is running: %w", err)
	}
	return lock, nil // Closing releases the kernel lock, including on process exit.
}

func ownerError() error {
	return errors.New("use the package manager or installation owner to update this executable")
}

func (u updater) managedVersion() (string, error) {
	info, err := os.Lstat(u.bin)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0200 == 0 {
		return "", ownerError()
	}
	managedPath, err := filepath.EvalSymlinks(u.bin)
	if err != nil {
		return "", ownerError()
	}
	runningPath, err := filepath.EvalSymlinks(u.executable)
	if err != nil || runningPath != managedPath {
		return "", ownerError()
	}
	dir, err := os.Stat(filepath.Dir(u.bin))
	if err != nil || dir.Mode().Perm()&0200 == 0 {
		return "", ownerError()
	}
	f, err := os.Open(u.bin)
	if err != nil {
		return "", ownerError()
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return "", err
	}
	marker, err := os.ReadFile(filepath.Join(u.state, hex.EncodeToString(h.Sum(nil))+".version"))
	tag := strings.TrimSpace(string(marker))
	if err != nil || !stableTag.MatchString(tag) {
		return "", ownerError()
	}
	return tag, nil
}

// Update checks the official feed immediately and returns the installed tag
// (including "v") on success, even when the installation is already current.
func Update(ctx context.Context, installedVersion string) (string, error) {
	u, err := defaults()
	if err != nil {
		return "", err
	}
	return u.update(ctx, installedVersion)
}

func (u updater) update(ctx context.Context, installedVersion string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	lock, err := u.lock("install.lock")
	if err != nil {
		return "", fmt.Errorf("update CLI as its installation owner: %w", err)
	}
	defer lock.Close()
	current, err := u.managedVersion()
	if err != nil {
		return "", err
	}
	if !stableTag.MatchString(installedVersion) {
		return "", ownerError()
	}
	latest, _, err := u.latest(ctx, nil)
	if err != nil {
		return "", err
	}
	if !newer(latest, current) {
		return current, nil
	}
	name := archiveName(latest, runtime.GOOS+"-"+runtime.GOARCH)
	sums, err := u.asset(ctx, latest, manifestName(latest), 1<<20)
	if err != nil {
		return "", err
	}
	archive, err := u.asset(ctx, latest, name, 64<<20)
	if err != nil {
		return "", err
	}
	if err := verify(sums, name, archive); err != nil {
		return "", err
	}
	if err := u.replace(latest, archive); err != nil {
		return "", err
	}
	return latest, nil
}

func verify(manifest []byte, name string, data []byte) error {
	want := fmt.Sprintf("%x", sha256.Sum256(data))
	matches := 0
	for _, line := range strings.Split(string(manifest), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[1] == name {
			if !strings.EqualFold(fields[0], want) {
				return fmt.Errorf("SHA-256 mismatch for %s", name)
			}
			matches++
		}
	}
	if matches != 1 {
		return fmt.Errorf("expected exactly one SHA-256 checksum for %s", name)
	}
	return nil
}

func unpack(archive []byte, w io.Writer) error {
	gz, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return err
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	entry, err := tr.Next()
	if err != nil {
		return err
	}
	if entry.Name != "foreman" || entry.Typeflag != tar.TypeReg || entry.Size <= 0 || entry.Size > 128<<20 {
		return errors.New("invalid CLI archive: expected a single executable named foreman")
	}
	if _, err = io.Copy(w, tr); err != nil {
		return err
	}
	if _, err = tr.Next(); err != io.EOF {
		return errors.New("unexpected additional CLI archive member")
	}
	// tar stops at its end marker before gzip has verified its trailer.
	_, err = bounded(gz, 1<<20)
	return err
}

func (u updater) replace(tag string, archive []byte) error {
	stage, err := os.CreateTemp(filepath.Dir(u.bin), ".foreman-*")
	if err != nil {
		return fmt.Errorf("stage CLI as its installation owner: %w", err)
	}
	defer os.Remove(stage.Name())
	defer stage.Close()
	h := sha256.New()
	if err = unpack(archive, io.MultiWriter(stage, h)); err != nil {
		return err
	}
	if err = stage.Chmod(0755); err != nil {
		return err
	}
	if err = stage.Sync(); err != nil {
		return err
	}
	if err = stage.Close(); err != nil {
		return err
	}
	// The receipt is keyed by binary contents. Both old and new receipts
	// remain valid if the process exits on either side of the rename.
	receipt := filepath.Join(u.state, hex.EncodeToString(h.Sum(nil))+".version")
	if err = atomicWrite(receipt, []byte(tag+"\n")); err != nil {
		return err
	}
	return os.Rename(stage.Name(), u.bin)
}

func atomicWrite(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()
	if _, err = tmp.Write(data); err != nil {
		return err
	}
	if err = tmp.Sync(); err != nil {
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
