package selfupdate

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
)

func assetNames(tag string) []string {
	return []string{
		"foreman-cli-" + tag + "-darwin-amd64.tar.gz", "foreman-cli-" + tag + "-darwin-arm64.tar.gz",
		"foreman-cli-" + tag + "-linux-amd64.tar.gz", "foreman-cli-" + tag + "-linux-arm64.tar.gz",
		"foreman-cli-" + tag + "-SHA256SUMS",
	}
}

func releaseRow(tag string, names []string, draft, pre bool) map[string]any {
	var assets []map[string]string
	for _, name := range names {
		assets = append(assets, map[string]string{"name": name, "state": "uploaded"})
	}
	return map[string]any{"tag_name": tag, "draft": draft, "prerelease": pre, "published_at": "2026-01-01T00:00:00Z", "assets": assets}
}

func archive(t *testing.T, name, content string) []byte {
	t.Helper()
	var data bytes.Buffer
	gz := gzip.NewWriter(&data)
	w := tar.NewWriter(gz)
	if err := w.WriteHeader(&tar.Header{Name: name, Mode: 0755, Size: int64(len(content)), Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write([]byte(content)); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return data.Bytes()
}

type fixture struct {
	t          *testing.T
	server     *httptest.Server
	tag        string
	content    string
	entry      string
	corrupt    bool
	status     int
	requests   atomic.Int64
	validators atomic.Int64
	binary     string
	artifacts  string
	onArchive  func()
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_STATE_HOME", filepath.Join(home, "state"))
	t.Setenv("GH_TOKEN", "must-never-send")
	f := &fixture{t: t, tag: "v1.9.0", entry: "foreman", content: "#!/bin/sh\necho v1.9.0\n", binary: filepath.Join(home, ".local", "bin", "foreman")}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fixture) serve(w http.ResponseWriter, r *http.Request) {
	f.requests.Add(1)
	if r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" {
		f.t.Error("credentials sent to release server")
	}
	if f.status != 0 {
		http.Error(w, "unavailable", f.status)
		return
	}
	if r.URL.Path == "/stable" {
		fmt.Fprintln(w, f.tag)
		return
	}
	if r.URL.Path == "/releases" {
		page := r.URL.Query().Get("page")
		tag := f.tag
		var rows []map[string]any
		if page == "2" {
			rows = []map[string]any{releaseRow(tag, assetNames(tag), false, false)}
		} else {
			w.Header().Set("Link", "<"+f.server.URL+"/repositories/123/releases?page=2>; rel=\"next\"")
			rows = []map[string]any{releaseRow("v1.8.9", assetNames("v1.8.9"), false, false), releaseRow("v5.0.0", assetNames("v5.0.0")[:4], false, false), releaseRow("v5.0.1", assetNames("v5.0.1")[1:], false, false), releaseRow("v6.0.0", assetNames("v6.0.0"), true, false), releaseRow("v7.0.0", assetNames("v7.0.0"), false, true), releaseRow("v08.0.0", assetNames("v08.0.0"), false, false)}
		}
		etag := `"first-page"`
		if page == "2" {
			etag = fmt.Sprintf("%q", page+tag)
		}
		w.Header().Set("ETag", etag)
		if r.Header.Get("If-None-Match") == etag {
			f.validators.Add(1)
			w.WriteHeader(304)
			return
		}
		json.NewEncoder(w).Encode(rows)
		return
	}
	filename := "foreman-cli-" + f.tag + "-" + runtime.GOOS + "-" + runtime.GOARCH + ".tar.gz"
	if f.artifacts != "" {
		http.StripPrefix("/download/", http.FileServer(http.Dir(f.artifacts))).ServeHTTP(w, r)
		return
	}
	data := archive(f.t, f.entry, f.content)
	switch r.URL.Path {
	case "/download/" + f.tag + "/foreman-cli-" + f.tag + "-SHA256SUMS":
		fmt.Fprintf(w, "%x  %s\n", sha256.Sum256(data), filename)
	case "/download/" + f.tag + "/" + filename:
		if f.onArchive != nil {
			f.onArchive()
		}
		if f.corrupt {
			data = append(data, '!')
		}
		w.Write(data)
	default:
		http.NotFound(w, r)
	}
}

func (f *fixture) options() updater {
	u, err := defaults()
	if err != nil {
		f.t.Fatal(err)
	}
	u.feed = f.server.URL + "/releases"
	u.download = f.server.URL + "/download"
	u.executable = f.binary
	return u
}

// Execute the shipped shell script as curl | sh would. Only the two release
// origins are replaced, so no test feed can be selected by an installed CLI.
func (f *fixture) install() (string, error) {
	script, err := os.ReadFile("../../../apps/foreman/priv/cli/install.sh")
	if err != nil {
		f.t.Fatal(err)
	}
	body := strings.ReplaceAll(string(script), "__FOREMAN_CLI_RELEASE_URL__", f.server.URL+"/stable")
	body = strings.ReplaceAll(body, "https://github.com/ntodd/foreman/releases/download", f.server.URL+"/download")
	// A fresh target has these ordinary tools, but no Python, jq, Go or
	// developer toolchain. GNU tar invokes gzip through the child's PATH.
	path := f.t.TempDir()
	for _, name := range strings.Fields("sh uname id stat mkdir curl cat grep awk tar gzip chmod mktemp mv ln rm shasum sha256sum") {
		src, err := exec.LookPath(name)
		if err != nil && (name == "sha256sum" || name == "shasum") {
			continue
		}
		if err != nil {
			f.t.Fatal(err)
		}
		if err := os.Symlink(src, filepath.Join(path, name)); err != nil {
			f.t.Fatal(err)
		}
	}
	cmd := exec.Command("sh")
	cmd.Env = append(os.Environ(), "PATH="+path)
	cmd.Stdin = strings.NewReader(body)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func (f *fixture) installed(want string) {
	f.t.Helper()
	out, err := exec.Command(f.binary, "--version").Output()
	if err != nil || strings.TrimSpace(string(out)) != want {
		f.t.Fatalf("installed version %q, %v; want %q", out, err, want)
	}
}

func TestInstallerAndUpdate(t *testing.T) {
	f := newFixture(t)
	u := f.options()
	if out, err := f.install(); err != nil || !strings.Contains(out, `export PATH="$HOME/.local/bin:$PATH"`) {
		t.Fatalf("install: %q %v", out, err)
	}
	f.installed("v1.9.0")
	protected := filepath.Join(os.Getenv("XDG_STATE_HOME"), "foreman", "pending-create-test")
	if err := os.WriteFile(protected, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	f.tag, f.content = "v1.10.0", "#!/bin/sh\necho v1.10.0\n"
	for _, broken := range []string{"corrupt", "malformed", "entry", "readonly", "offline"} {
		switch broken {
		case "corrupt":
			f.corrupt = true
		case "malformed":
			f.content = ""
		case "entry":
			f.entry = "../foreman"
		case "readonly":
			if err := os.Chmod(f.binary, 0555); err != nil {
				t.Fatal(err)
			}
		case "offline":
			f.status = 429
		}
		if _, err := u.update(context.Background(), "v1.9.0"); err == nil {
			t.Fatalf("%s update succeeded", broken)
		}
		f.installed("v1.9.0")
		f.corrupt = false
		f.status = 0
		f.entry = "foreman"
		f.content = "#!/bin/sh\necho v1.10.0\n"
		if err := os.Chmod(f.binary, 0755); err != nil {
			t.Fatal(err)
		}
	}
	got, err := u.update(context.Background(), "v1.9.0")
	if err != nil || got != f.tag {
		t.Fatalf("update: %q %v", got, err)
	}
	f.installed(f.tag)
	prior := f.requests.Load()
	got, err = u.update(context.Background(), f.tag)
	if err != nil || got != f.tag || prior == f.requests.Load() {
		t.Fatalf("explicit recheck: %q %v", got, err)
	}
	if b, err := os.ReadFile(protected); err != nil || string(b) != "keep" {
		t.Fatalf("lost state: %q %v", b, err)
	}
	if got := u.notice(context.Background(), f.tag, true, false); got != "" {
		t.Fatalf("post-update notice: %q", got)
	}
}

func TestBootstrapRejectsBadDownloads(t *testing.T) {
	for _, broken := range []string{"checksum", "empty", "unexpected file", "offline"} {
		t.Run(broken, func(t *testing.T) {
			f := newFixture(t)
			switch broken {
			case "checksum":
				f.corrupt = true
			case "empty":
				f.content = ""
			case "unexpected file":
				f.entry = "../foreman"
			case "offline":
				f.status = 429
			}
			if out, err := f.install(); err == nil {
				t.Fatalf("install succeeded: %s", out)
			}
			if _, err := os.Lstat(f.binary); !os.IsNotExist(err) {
				t.Fatalf("partial executable: %v", err)
			}
		})
	}
}

func TestUnmanagedAndSymlinkInstall(t *testing.T) {
	f := newFixture(t)
	if err := os.MkdirAll(filepath.Dir(f.binary), 0755); err != nil {
		t.Fatal(err)
	}
	owned := filepath.Join(t.TempDir(), "brew-foreman")
	if err := os.WriteFile(owned, []byte("from package"), 0755); err != nil {
		t.Fatal(err)
	}
	for _, symlink := range []bool{true, false} {
		if symlink {
			if err := os.Symlink(owned, f.binary); err != nil {
				t.Fatal(err)
			}
		} else if err := os.WriteFile(f.binary, []byte("from package"), 0755); err != nil {
			t.Fatal(err)
		}
		if out, err := f.install(); err == nil || !strings.Contains(out, "package manager") {
			t.Fatalf("unmanaged install: %q %v", out, err)
		}
		if _, err := f.options().update(context.Background(), "v1.0.0"); err == nil || !strings.Contains(err.Error(), "package manager") {
			t.Fatalf("unmanaged update: %v", err)
		}
		if err := os.Remove(f.binary); err != nil {
			t.Fatal(err)
		}
	}
	if b, err := os.ReadFile(owned); err != nil || string(b) != "from package" {
		t.Fatalf("package changed: %q %v", b, err)
	}
}

func TestReplacementDuringDownload(t *testing.T) {
	f := newFixture(t)
	if out, err := f.install(); err != nil {
		t.Fatalf("install: %s %v", out, err)
	}
	f.tag = "v1.10.0"
	f.onArchive = func() {
		if err := os.WriteFile(f.binary, []byte("installed by another tool"), 0755); err != nil {
			t.Error(err)
		}
	}
	if _, err := f.options().update(context.Background(), "v1.9.0"); err == nil || !strings.Contains(err.Error(), "package manager") {
		t.Fatalf("expected ownership error, got %v", err)
	}
	if data, err := os.ReadFile(f.binary); err != nil || string(data) != "installed by another tool" {
		t.Fatalf("unmanaged binary changed: %q %v", data, err)
	}
}

// Run this case with CAP_CHOWN in an isolated Linux container. The receipt
// still matches and the parent is writable after a package owner takes over.
func TestTransferredInstallation(t *testing.T) {
	for _, part := range []string{"executable", "directory"} {
		t.Run(part, func(t *testing.T) {
			f := newFixture(t)
			if out, err := f.install(); err != nil {
				t.Fatalf("install: %s %v", out, err)
			}
			path := f.binary
			if part == "directory" {
				path = filepath.Dir(f.binary)
			}
			if err := os.Chmod(path, 0777); err != nil {
				t.Fatal(err)
			}
			if err := os.Chown(path, os.Geteuid()+1, -1); err != nil {
				if os.IsPermission(err) {
					t.Skip("needs permission to transfer file ownership")
				}
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.Chown(path, os.Geteuid(), -1) })
			f.tag = "v1.10.0"
			if out, err := f.install(); err == nil || !strings.Contains(out, "package manager") {
				t.Fatalf("installer accepted transferred %s: %q %v", part, out, err)
			}
			if _, err := f.options().update(context.Background(), "v1.9.0"); err == nil || !strings.Contains(err.Error(), "package manager") {
				t.Fatalf("updater accepted transferred %s: %v", part, err)
			}
			f.installed("v1.9.0")
		})
	}
}

func TestNewPageOnNotModified(t *testing.T) {
	f := newFixture(t)
	u := f.options()
	pages := map[string]page{u.feed: {ETag: `"first-page"`, Newest: "v1.8.9"}}
	got, _, err := u.latest(context.Background(), pages)
	if err != nil || got != f.tag {
		t.Fatalf("new page after HTTP 304: %q %v", got, err)
	}
}

func TestNotice(t *testing.T) {
	f := newFixture(t)
	u := f.options()
	ctx := context.Background()
	for _, flags := range [][2]bool{{false, false}, {true, true}} {
		if got := u.notice(ctx, "v1.0.0", flags[0], flags[1]); got != "" || f.requests.Load() != 0 {
			t.Fatal("noninteractive check")
		}
	}
	var announced atomic.Int64
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if u.notice(ctx, "v1.0.0", true, false) != "" {
				announced.Add(1)
			}
		}()
	}
	wg.Wait()
	if announced.Load() != 1 {
		t.Fatalf("announced %d times", announced.Load())
	}
	before := f.validators.Load()
	if got := u.notice(ctx, "v1.0.0", true, false); got != "" || f.validators.Load()-before != 2 {
		t.Fatalf("repeat notice=%q conditional requests=%d", got, f.validators.Load())
	}
	f.tag = "v1.10.0"
	if got := u.notice(ctx, "v1.9.0", true, false); got != "Foreman CLI 1.10.0 is available (installed 1.9.0). Run foreman update." {
		t.Fatalf("unexpected notice %q", got)
	}
	f.status = 403
	if got := u.notice(ctx, "v1.0.0", true, false); got != "" {
		t.Fatalf("rate limited notice %q", got)
	}
}

func TestInteractive(t *testing.T) {
	// /dev/null is a character device, but scripts redirecting any stream
	// there must remain quiet. Check the same combinations inside a PTY.
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer devnull.Close()
	if os.Getenv("FOREMAN_TTY_PROBE") == "1" {
		if !Interactive(os.Stdin, os.Stdout, os.Stderr) {
			t.Fatal("PTY rejected")
		}
		if Interactive(devnull, os.Stdout, os.Stderr) || Interactive(os.Stdin, devnull, os.Stderr) || Interactive(os.Stdin, os.Stdout, devnull) {
			t.Fatal("accepted a redirected stream")
		}
		fmt.Println("foreman-tty-verified")
		return
	}
	if Interactive(devnull, devnull, devnull) {
		t.Fatal("accepted /dev/null")
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	var cmd *exec.Cmd
	if runtime.GOOS == "darwin" {
		cmd = exec.Command("script", "-q", "/dev/null", exe, "-test.run", "^TestInteractive$")
	} else {
		cmd = exec.Command("script", "-qec", `"$FOREMAN_TEST_BINARY" -test.run '^TestInteractive$'`, "/dev/null")
	}
	cmd.Env = append(os.Environ(), "FOREMAN_TTY_PROBE=1", "FOREMAN_TEST_BINARY="+exe)
	if out, err := cmd.CombinedOutput(); err != nil || !strings.Contains(string(out), "foreman-tty-verified") {
		t.Fatalf("terminal probe: %s: %v", out, err)
	}
}

// This optional Linux fixture is a read-only bind mount of a caller-owned
// directory containing an executable foreman, both with mode 0755.
func TestReadOnlyMount(t *testing.T) {
	parent := os.Getenv("FOREMAN_TEST_READONLY_BIN_DIR")
	if parent == "" {
		t.Skip("needs a caller-owned read-only bind mount")
	}
	f := newFixture(t)
	u := f.options()
	if err := os.MkdirAll(filepath.Dir(filepath.Dir(f.binary)), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(parent, filepath.Dir(f.binary)); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{parent, f.binary} {
		st, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if int(st.Sys().(*syscall.Stat_t).Uid) != os.Geteuid() || st.Mode().Perm()&0200 == 0 {
			t.Fatalf("fixture must have owner-write mode and belong to caller: %s", path)
		}
	}
	body, err := os.ReadFile(f.binary)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.MkdirAll(u.state, 0700); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(u.state, fmt.Sprintf("%x.version", sha256.Sum256(body))), []byte("v1.0.0\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if out, err := f.install(); err == nil || !strings.Contains(out, "package manager") {
		t.Fatalf("installer accepted a read-only mount: %s %v", out, err)
	}
	if _, err := u.update(context.Background(), "v1.0.0"); err == nil || !strings.Contains(err.Error(), "package manager") {
		t.Fatalf("updater accepted a read-only mount: %v", err)
	}
	if f.requests.Load() != 0 {
		t.Fatal("downloaded releases for an unwritable installation")
	}
}
