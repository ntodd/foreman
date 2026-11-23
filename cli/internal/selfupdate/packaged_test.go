package selfupdate

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// Run with scripts/rehearse-cli-release.sh. This deliberately builds the
// actual command twice; ordinary package tests use the smaller fixture.
func TestPackagedRelease(t *testing.T) {
	if os.Getenv("FOREMAN_RELEASE_REHEARSAL") != "1" {
		t.Skip("run scripts/rehearse-cli-release.sh for the packaged CLI rehearsal")
	}
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	f := newFixture(t)
	f.artifacts = t.TempDir()
	// Use the production build and packaging scripts. Go's overlay changes
	// only the fixture binaries' release origins, without editing the checkout.
	source := filepath.Join(root, "cli/internal/selfupdate/update.go")
	code, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	local := strings.NewReplacer(releaseFeed, f.server.URL+"/releases", releaseDownloads, f.server.URL+"/download").Replace(string(code))
	if local == string(code) {
		t.Fatal("release fixture overlay failed")
	}
	tmp := t.TempDir()
	replacement := filepath.Join(tmp, "update.go")
	if err := os.WriteFile(replacement, []byte(local), 0600); err != nil {
		t.Fatal(err)
	}
	overlay, err := json.Marshal(map[string]any{"Replace": map[string]string{source: replacement}})
	if err != nil {
		t.Fatal(err)
	}
	overlayPath := filepath.Join(tmp, "overlay.json")
	if err := os.WriteFile(overlayPath, overlay, 0600); err != nil {
		t.Fatal(err)
	}
	// go accepts quoted flags for a TMPDIR containing spaces.
	t.Setenv("GOFLAGS", fmt.Sprintf("%s %q", os.Getenv("GOFLAGS"), "-overlay="+overlayPath))
	run := func(name string, args ...string) string {
		t.Helper()
		cmd := exec.Command(name, args...)
		cmd.Dir = root
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%s %v: %s: %v", name, args, out, err)
		}
		return string(out)
	}
	build := func(tag string) string {
		t.Helper()
		dir := filepath.Join(f.artifacts, tag)
		for _, osName := range []string{"linux", "darwin"} {
			for _, arch := range []string{"amd64", "arm64"} {
				run("scripts/package-cli.sh", tag, osName, arch, dir)
			}
		}
		run("scripts/checksum-cli.sh", tag, dir)
		archive := filepath.Join(dir, archiveName(tag, runtime.GOOS+"-"+runtime.GOARCH))
		run("scripts/smoke-cli.sh", tag, archive)
		return archive
	}
	build(f.tag)
	if out, err := f.install(); err != nil {
		t.Fatalf("install: %v: %s", err, out)
	}
	if out := run(f.binary, "--version"); !strings.Contains(out, f.tag) {
		t.Fatalf("installed version: %s", out)
	}
	old := f.tag
	f.tag = "v1.10.0"
	next := build(f.tag)
	if err := os.Chmod(f.binary, 0555); err != nil {
		t.Fatal(err)
	}
	if out, err := f.install(); err == nil || !strings.Contains(out, "owner") {
		t.Fatalf("read-only reinstall: %s: %v", out, err)
	}
	if out := run(f.binary, "--version"); !strings.Contains(out, old) {
		t.Fatalf("read-only executable changed: %s", out)
	}
	if err := os.Chmod(f.binary, 0755); err != nil {
		t.Fatal(err)
	}
	checkpoint, err := os.ReadFile(next)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(next, []byte("incomplete download"), 0600); err != nil {
		t.Fatal(err)
	}
	if out, err := f.install(); err == nil || !strings.Contains(out, "SHA-256") {
		t.Fatalf("corrupt reinstall: %s: %v", out, err)
	}
	if out, err := exec.Command(f.binary, "update").CombinedOutput(); err == nil || !strings.Contains(string(out), "SHA-256") {
		t.Fatalf("corrupt update: %s: %v", out, err)
	}
	if out := run(f.binary, "--version"); !strings.Contains(out, old) {
		t.Fatalf("lost prior executable: %s", out)
	}
	if err = os.WriteFile(next, checkpoint, 0600); err != nil {
		t.Fatal(err)
	}
	if out := run(f.binary, "update"); !strings.Contains(out, f.tag) {
		t.Fatalf("update: %s", out)
	}
	if out := run(f.binary, "--version"); !strings.Contains(out, f.tag) {
		t.Fatalf("updated version: %s", out)
	}
}
