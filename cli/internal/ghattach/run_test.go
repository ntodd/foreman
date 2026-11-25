package ghattach

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// output is what a child has written so far, read while it still runs.
type output struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (o *output) Write(p []byte) (int, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.buf.Write(p)
}

func (o *output) String() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.buf.String()
}

// The test binary stands in for gh: run with GHATTACH_FAKE_GH set, it
// does what the variable says and exits, as a child of Run.
func TestMain(m *testing.M) {
	switch os.Getenv("GHATTACH_FAKE_GH") {
	case "":
		os.Exit(m.Run())
	case "environment":
		fmt.Println(strings.Join(os.Args[1:], " "))
		for _, name := range []string{"HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "no_proxy", "SSL_CERT_DIR", "SSL_CERT_FILE", "KEPT"} {
			fmt.Printf("%s=%s\n", name, os.Getenv(name))
		}
		os.Exit(3)
	case "upload":
		os.Exit(fakeUpload())
	case "signals":
		// Says which signal it was sent, and leaves as if nothing happened.
		caught := make(chan os.Signal, 1)
		signal.Notify(caught, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
		fmt.Println("ready")
		fmt.Println("caught", <-caught)
		os.Exit(0)
	case "killed":
		// Dies of a signal it doesn't handle.
		syscall.Kill(os.Getpid(), syscall.SIGTERM)
		select {}
	}
}

// fakeUpload is gh's upload: through the proxy the environment names,
// trusting the certificates in the first directory of SSL_CERT_DIR (as
// Go does on Linux, where environments run; elsewhere it reads the
// platform's own store, so the test reads the directory itself).
func fakeUpload() int {
	dir, _, _ := strings.Cut(os.Getenv("SSL_CERT_DIR"), ":")
	roots := x509.NewCertPool()
	entries, err := os.ReadDir(dir)
	if err != nil {
		fmt.Println(err)
		return 1
	}
	for _, entry := range entries {
		if data, err := os.ReadFile(filepath.Join(dir, entry.Name())); err == nil {
			roots.AppendCertsFromPEM(data)
		}
	}
	client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyFromEnvironment, TLSClientConfig: &tls.Config{RootCAs: roots}}}
	res, err := client.Post(uploadURL, "application/octet-stream", strings.NewReader("png bytes"))
	if err != nil {
		fmt.Println(err)
		return 1
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	fmt.Printf("%d %s", res.StatusCode, body)
	return 0
}

func fakeGH(t *testing.T, mode string, env ...string) (Options, *bytes.Buffer) {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	return Options{
		GH:     self,
		Env:    append([]string{"GHATTACH_FAKE_GH=" + mode, "PATH=" + os.Getenv("PATH")}, env...),
		Stdout: &out,
		Stderr: &out,
		Upload: func(_ context.Context, file File) (string, error) {
			return "https://github.com/user-attachments/assets/" + file.Name, nil
		},
	}, &out
}

func TestRunPointsGHAtTheProxyAndKeepsTheRestOfItsEnvironment(t *testing.T) {
	o, out := fakeGH(t, "environment", "KEPT=yes", "HTTPS_PROXY=http://corporate:3128", "HTTP_PROXY=http://corporate:3128",
		"NO_PROXY=internal.corp, uploads.github.com,.github.com,10.0.0.0/8,github.com:80,.uploads.github.com,*.github.com,github.com:443", "no_proxy=github.com")
	o.Args = []string{"pr", "edit", "--attach", "login.png"}

	status, err := Run(o)
	if err != nil {
		t.Fatal(err)
	}
	if status != 3 {
		t.Errorf("status = %d, want gh's own 3", status)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if lines[0] != "pr edit --attach login.png" {
		t.Errorf("arguments = %q", lines[0])
	}
	env := map[string]string{}
	for _, line := range lines[1:] {
		name, value, _ := strings.Cut(line, "=")
		env[name] = value
	}
	if !strings.HasPrefix(env["HTTPS_PROXY"], "http://foreman:") || !strings.Contains(env["HTTPS_PROXY"], "@127.0.0.1:") || env["https_proxy"] != env["HTTPS_PROXY"] {
		t.Errorf("HTTPS_PROXY = %q, https_proxy = %q", env["HTTPS_PROXY"], env["https_proxy"])
	}
	// An exemption that covers the upload host would send gh round the
	// proxy. The others are still gh's, and its children's.
	// One for another port, or for hosts under the upload host only, never
	// covered it and stays.
	if env["NO_PROXY"] != "internal.corp,10.0.0.0/8,github.com:80,.uploads.github.com" || env["no_proxy"] != "" {
		t.Errorf("NO_PROXY = %q, no_proxy = %q", env["NO_PROXY"], env["no_proxy"])
	}
	if env["HTTP_PROXY"] != "http://corporate:3128" {
		t.Errorf("HTTP_PROXY = %q", env["HTTP_PROXY"])
	}
	dirs := strings.Split(env["SSL_CERT_DIR"], ":")
	if len(dirs) != 3 || dirs[1] != "/etc/ssl/certs" || dirs[2] != "/etc/pki/tls/certs" {
		t.Errorf("SSL_CERT_DIR = %q", env["SSL_CERT_DIR"])
	}
	if env["KEPT"] != "yes" {
		t.Errorf("KEPT = %q", env["KEPT"])
	}
	// The proxy's authority is gone with the run, and what held it.
	if _, err := os.Stat(filepath.Dir(dirs[0])); !os.IsNotExist(err) {
		t.Errorf("%s was left behind (%v)", filepath.Dir(dirs[0]), err)
	}
}

func TestRunWithEverythingExemptLeavesPlainHTTPAlone(t *testing.T) {
	// "*" exempts every host from the proxies already set, the upload
	// host with them. Without it gh must still reach nothing through them.
	o, out := fakeGH(t, "environment", "HTTP_PROXY=http://corporate:3128", "ALL_PROXY=socks5://corporate:1080", "NO_PROXY=*")

	if _, err := Run(o); err != nil {
		t.Fatal(err)
	}
	// ALL_PROXY too: gh ignores it, and the git and curl it runs don't.
	if !strings.Contains(out.String(), "\nHTTP_PROXY=\n") || !strings.Contains(out.String(), "\nALL_PROXY=\n") || !strings.Contains(out.String(), "\nNO_PROXY=\n") {
		t.Errorf("environment:\n%s", out.String())
	}
}

func TestRunWithoutAProxyRunsGHAsItIs(t *testing.T) {
	o, out := fakeGH(t, "environment", "HTTPS_PROXY=http://corporate:3128")
	// Nowhere to put the authority and the socket.
	t.Setenv("TMPDIR", filepath.Join(t.TempDir(), "missing"))

	status, err := Run(o)
	if err != nil || status != 3 {
		t.Fatalf("status %d, err %v", status, err)
	}
	if !strings.Contains(out.String(), "HTTPS_PROXY=http://corporate:3128\n") {
		t.Errorf("gh's environment was changed:\n%s", out.String())
	}
	if !strings.Contains(out.String(), "foreman: ") || !strings.Contains(out.String(), "gh is uploading on its own") {
		t.Errorf("nothing said why:\n%s", out.String())
	}
}

func TestRunKeepsTheCertificateDirectoriesAlreadyNamed(t *testing.T) {
	o, out := fakeGH(t, "environment", "SSL_CERT_DIR=/opt/certs:/etc/ssl/certs", "SSL_CERT_FILE=/opt/bundle.pem")

	if _, err := Run(o); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), ":/opt/certs:/etc/ssl/certs\n") || !strings.Contains(out.String(), "SSL_CERT_FILE=/opt/bundle.pem\n") {
		t.Errorf("environment:\n%s", out.String())
	}
}

func TestRunAnswersGHsUploadWhileItRuns(t *testing.T) {
	o, out := fakeGH(t, "upload")

	status, err := Run(o)
	if err != nil {
		t.Fatal(err)
	}
	if want := `201 {"url":"https://github.com/user-attachments/assets/login.png"}`; status != 0 || strings.TrimSpace(out.String()) != want {
		t.Errorf("status %d, output %q", status, out.String())
	}
}

func TestRunSaysWhenGHCannotBeStarted(t *testing.T) {
	o, _ := fakeGH(t, "environment")
	o.GH = filepath.Join(t.TempDir(), "no-such-gh")

	status, err := Run(o)
	if err == nil || status == 0 {
		t.Errorf("status %d, err %v", status, err)
	}
}

func TestRunPassesASignalOnAsItCame(t *testing.T) {
	for _, sent := range []syscall.Signal{syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP} {
		t.Run(sent.String(), func(t *testing.T) {
			o, _ := fakeGH(t, "signals")
			out := &output{}
			o.Stdout, o.Stderr = out, out
			type result struct {
				status int
				err    error
			}
			finished := make(chan result, 1)
			go func() {
				status, err := Run(o)
				finished <- result{status, err}
			}()
			deadline := time.After(10 * time.Second)
			for !strings.Contains(out.String(), "ready") {
				select {
				case <-deadline:
					t.Fatalf("gh never started: %q", out.String())
				case <-time.After(10 * time.Millisecond):
				}
			}

			// To this process, as a shell or a supervisor would send it to
			// the one it started. Run has it for as long as gh runs.
			if err := syscall.Kill(os.Getpid(), sent); err != nil {
				t.Fatal(err)
			}

			select {
			case got := <-finished:
				// gh handled it and left of its own accord: that is gh's
				// exit, not a failure to run it.
				if got.status != 0 || got.err != nil {
					t.Errorf("status %d, err %v", got.status, got.err)
				}
			case <-time.After(10 * time.Second):
				t.Fatal("gh never heard of the signal")
			}
			if !strings.Contains(out.String(), "caught "+sent.String()) {
				t.Errorf("gh was sent something else: %q", out.String())
			}
		})
	}
}

func TestRunReportsAGHKilledByASignalTheWayAShellDoes(t *testing.T) {
	o, _ := fakeGH(t, "killed")

	status, err := Run(o)
	if err != nil {
		t.Fatal(err)
	}
	if want := 128 + int(syscall.SIGTERM); status != want {
		t.Errorf("status = %d, want %d", status, want)
	}
}
