package ghattach

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ntodd/foreman/cli/api"
)

const uploadURL = "https://uploads.github.com/user-attachments/assets?content_type=image%2Fpng&name=login.png&repository_id=1001"

// start runs a proxy for the test and returns a client that reaches the
// world through it, trusting what gh would be told to trust: the proxy's
// own authority, and `also` for a test server's certificate.
func start(t *testing.T, p *Proxy, also ...*x509.Certificate) *http.Client {
	t.Helper()
	if p.upstream == nil {
		// Not whatever proxy the shell running the tests names.
		p.upstream = func(string) (*url.URL, error) { return nil, nil }
	}
	if err := p.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.Close() })
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(p.CA()) {
		t.Fatal("the proxy's authority isn't a certificate")
	}
	for _, cert := range also {
		roots.AddCert(cert)
	}
	through, err := url.Parse(p.URL())
	if err != nil {
		t.Fatal(err)
	}
	transport := &http.Transport{Proxy: http.ProxyURL(through), TLSClientConfig: &tls.Config{RootCAs: roots}}
	t.Cleanup(transport.CloseIdleConnections)
	return &http.Client{Transport: transport}
}

func post(t *testing.T, client *http.Client, target string, body []byte) (int, map[string]string) {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, target, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "token ghu_environment")
	req.Header.Set("Content-Type", "application/octet-stream")
	res, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var reply map[string]string
	if err := json.NewDecoder(res.Body).Decode(&reply); err != nil {
		t.Fatalf("the reply isn't JSON: %v", err)
	}
	return res.StatusCode, reply
}

func TestProxyUploadsThroughForemanAndAnswersAsGitHubWould(t *testing.T) {
	var got File
	client := start(t, &Proxy{Upload: func(_ context.Context, file File) (string, error) {
		got = file
		return "https://github.com/user-attachments/assets/5b8ee541", nil
	}})

	status, reply := post(t, client, uploadURL, []byte("png bytes"))

	if status != http.StatusCreated || reply["url"] != "https://github.com/user-attachments/assets/5b8ee541" {
		t.Errorf("status %d, reply %v", status, reply)
	}
	if got.Name != "login.png" || got.RepositoryID != 1001 || string(got.Data) != "png bytes" {
		t.Errorf("uploaded %+v", got)
	}
}

func TestProxyTellsGHWhatForemanRefused(t *testing.T) {
	client := start(t, &Proxy{Upload: func(context.Context, File) (string, error) {
		return "", &api.HTTPError{StatusCode: 422, Code: "invalid_request", Message: "Images must be at most 10 MB."}
	}})

	status, reply := post(t, client, uploadURL, []byte("x"))

	// gh prints a 422's message after the file's name, and nothing else's.
	if status != http.StatusUnprocessableEntity || reply["message"] != "Images must be at most 10 MB." {
		t.Errorf("status %d, reply %v", status, reply)
	}
}

func TestProxySendsAnythingElseOnTheUploadHostToGitHub(t *testing.T) {
	var seen []string
	addr, roots := github(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		seen = append(seen, r.Method+" "+r.URL.RequestURI()+" "+string(body))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		io.WriteString(w, `{"message":"from GitHub"}`)
	})
	var notice bytes.Buffer
	client := start(t, &Proxy{
		Notice: &notice,
		Upload: func(context.Context, File) (string, error) {
			t.Error("something that isn't an attachment was uploaded through Foreman")
			return "", nil
		},
		roots: roots,
		dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, network, addr)
		},
	})

	// A release asset goes to the same host, and is none of Foreman's.
	release := "https://uploads.github.com/repos/acme/storefront/releases/1/assets?name=a.zip"
	if status, reply := post(t, client, release, []byte("zip bytes")); status != http.StatusAccepted || reply["message"] != "from GitHub" {
		t.Errorf("status %d, reply %v", status, reply)
	}
	res, err := client.Get(uploadURL)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusAccepted {
		t.Errorf("GET: status %d", res.StatusCode)
	}
	want := []string{"POST /repos/acme/storefront/releases/1/assets?name=a.zip zip bytes", "GET " + strings.TrimPrefix(uploadURL, "https://uploads.github.com") + " "}
	if strings.Join(seen, "\n") != strings.Join(want, "\n") {
		t.Errorf("GitHub got %q", seen)
	}
	if notice.Len() != 0 {
		t.Errorf("notice = %q", notice.String())
	}
}

func TestProxyPassesEveryOtherHostThroughUntouched(t *testing.T) {
	elsewhere := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "from "+r.Header.Get("Authorization"))
	}))
	defer elsewhere.Close()
	client := start(t, &Proxy{Upload: func(context.Context, File) (string, error) {
		t.Error("another host's request was uploaded")
		return "", nil
	}}, elsewhere.Certificate())

	req, _ := http.NewRequest(http.MethodGet, elsewhere.URL+"/graphql", nil)
	req.Header.Set("Authorization", "token ghu_environment")
	res, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	// The server's own certificate was the one presented: the proxy's
	// authority can't vouch for it.
	if string(body) != "from token ghu_environment" {
		t.Errorf("body = %q", body)
	}
}

func TestProxyAuthorityVouchesForTheUploadHostAlone(t *testing.T) {
	p := &Proxy{Upload: func(context.Context, File) (string, error) { return "", nil }}
	start(t, p)
	block, _ := pem.Decode(p.CA())
	ca, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	if !ca.IsCA || !ca.PermittedDNSDomainsCritical || len(ca.PermittedDNSDomains) != 1 || ca.PermittedDNSDomains[0] != "uploads.github.com" {
		t.Errorf("authority permits %v (critical %v)", ca.PermittedDNSDomains, ca.PermittedDNSDomainsCritical)
	}
	if !ca.MaxPathLenZero {
		t.Error("the authority could sign another authority")
	}
	// Permitting a name permits the names under it, unless they are
	// excluded.
	if len(ca.ExcludedDNSDomains) != 1 || ca.ExcludedDNSDomains[0] != ".uploads.github.com" {
		t.Errorf("the authority excludes %v", ca.ExcludedDNSDomains)
	}
	// A name constraint says nothing of addresses unless it names them.
	for _, address := range []string{"127.0.0.1", "140.82.112.3", "::1", "2606:50c0:8000::154"} {
		excluded := false
		for _, network := range ca.ExcludedIPRanges {
			excluded = excluded || network.Contains(net.ParseIP(address))
		}
		if !excluded {
			t.Errorf("the authority could vouch for %s", address)
		}
	}
}

// connect asks the proxy for a tunnel the way a client would, with the
// credentials given, and returns the proxy's answer.
func connect(t *testing.T, p *Proxy, target, authorization string) *http.Response {
	t.Helper()
	through, _ := url.Parse(p.URL())
	conn, err := net.Dial("tcp", through.Host)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	req := &http.Request{Method: http.MethodConnect, URL: &url.URL{Opaque: target}, Host: target, Header: http.Header{}}
	if authorization != "" {
		req.Header.Set("Proxy-Authorization", authorization)
	}
	if err := req.Write(conn); err != nil {
		t.Fatal(err)
	}
	res, err := http.ReadResponse(bufio.NewReader(conn), req)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func TestProxyTunnelsOnlyForTheGHItWasStartedFor(t *testing.T) {
	p := &Proxy{Upload: func(context.Context, File) (string, error) {
		t.Error("someone else's upload was sent through Foreman")
		return "", nil
	}}
	start(t, p)
	through, _ := url.Parse(p.URL())
	if password, set := through.User.Password(); !set || len(password) < 32 {
		t.Fatalf("the proxy's URL carries no secret: %s", p.URL())
	}

	// Anything on loopback can find the port. Only the gh that was given
	// the URL has what goes with it.
	wrong := "Basic " + base64.StdEncoding.EncodeToString([]byte("foreman:guess"))
	for _, authorization := range []string{"", wrong} {
		for _, target := range []string{uploadHost + ":443", "example.com:443"} {
			if res := connect(t, p, target, authorization); res.StatusCode != http.StatusProxyAuthRequired {
				t.Errorf("%s with %q: status %d", target, authorization, res.StatusCode)
			}
		}
	}
}

func TestProxyAnswersUploadsWhereOnlyItsOwnUserCanConnect(t *testing.T) {
	p := &Proxy{Upload: func(context.Context, File) (string, error) { return "", nil }}
	start(t, p)

	// Not a port on loopback, which every user in the container shares.
	if network := p.uploads.Addr().Network(); network != "unix" {
		t.Fatalf("uploads are answered on a %s listener", network)
	}
	info, err := os.Stat(filepath.Dir(p.uploads.Addr().String()))
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0o700 {
		t.Errorf("the socket's directory is %o", mode)
	}
}

func TestProxyCloseEndsTunnelsStillOpen(t *testing.T) {
	held := make(chan struct{})
	elsewhere := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { <-held }))
	defer elsewhere.Close()
	defer close(held)
	p := &Proxy{Upload: func(context.Context, File) (string, error) { return "", nil }}
	client := start(t, p, elsewhere.Certificate())

	failed := make(chan error, 1)
	go func() {
		_, err := client.Get(elsewhere.URL)
		failed <- err
	}()
	// The request is in flight once the server holds it.
	deadline := time.After(5 * time.Second)
	for p.open() == 0 {
		select {
		case <-deadline:
			t.Fatal("no tunnel was opened")
		case <-time.After(10 * time.Millisecond):
		}
	}
	p.Close()

	select {
	case err := <-failed:
		if err == nil {
			t.Error("the request finished through a closed proxy")
		}
	case <-time.After(5 * time.Second):
		t.Error("the tunnel outlived the proxy")
	}
}

func TestProxyReachesOtherHostsThroughAnHTTPSProxyToo(t *testing.T) {
	elsewhere := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "ok") }))
	defer elsewhere.Close()

	// A proxy that is itself spoken to over TLS.
	authority, err := newAuthority("proxy.test")
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(authority.pem)
	upstream, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{authority.leaf}})
	if err != nil {
		t.Fatal(err)
	}
	defer upstream.Close()
	go func() {
		for {
			conn, err := upstream.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				reader := bufio.NewReader(conn)
				req, err := http.ReadRequest(reader)
				if err != nil || req.Method != http.MethodConnect {
					return
				}
				out, err := net.Dial("tcp", req.Host)
				if err != nil {
					return
				}
				defer out.Close()
				io.WriteString(conn, "HTTP/1.1 200 Connection Established\r\n\r\n")
				go io.Copy(out, reader)
				io.Copy(conn, out)
			}()
		}
	}()

	var dialled []string
	p := &Proxy{
		Upload:   func(context.Context, File) (string, error) { return "", nil },
		roots:    roots,
		upstream: func(string) (*url.URL, error) { return url.Parse("https://proxy.test") },
		dial: func(ctx context.Context, network, addr string) (net.Conn, error) {
			dialled = append(dialled, addr)
			var d net.Dialer
			return d.DialContext(ctx, network, upstream.Addr().String())
		},
	}
	client := start(t, p, elsewhere.Certificate())

	res, err := client.Get(elsewhere.URL)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if string(body) != "ok" {
		t.Errorf("body = %q", body)
	}
	// With no port of its own, the port its scheme implies.
	if len(dialled) != 1 || dialled[0] != "proxy.test:443" {
		t.Errorf("dialled %v", dialled)
	}
}

func TestProxyGivesGHTheWholeOfGitHubsAnswer(t *testing.T) {
	addr, roots := github(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("name") == "moved.png" {
			w.Header().Set("Location", "https://uploads.github.com/elsewhere")
			w.WriteHeader(http.StatusTemporaryRedirect)
			return
		}
		// GitHub compresses when asked to, and says that it did.
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
			t.Error("the client's Accept-Encoding didn't reach GitHub")
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Encoding", "gzip")
		w.WriteHeader(http.StatusCreated)
		compressed := gzip.NewWriter(w)
		io.WriteString(compressed, `{"url":"https://github.com/user-attachments/assets/native"}`)
		compressed.Close()
	})
	p := &Proxy{
		Upload: func(context.Context, File) (string, error) { return "", &Unavailable{Reason: "no token"} },
		roots:  roots,
		dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, network, addr)
		},
	}
	client := start(t, p)
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

	// The client undoes the compression only if it is told of it.
	if status, reply := post(t, client, uploadURL, []byte("png bytes")); status != http.StatusCreated || reply["url"] != "https://github.com/user-attachments/assets/native" {
		t.Errorf("status %d, reply %v", status, reply)
	}

	res, err := client.Post(strings.Replace(uploadURL, "login.png", "moved.png", 1), "application/octet-stream", strings.NewReader("x"))
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusTemporaryRedirect || res.Header.Get("Location") != "https://uploads.github.com/elsewhere" {
		t.Errorf("status %d, Location %q", res.StatusCode, res.Header.Get("Location"))
	}
}

// github stands in for the real upload host: a TLS server whose
// certificate is good for its name, signed by an authority of the test's.
func github(t *testing.T, handler http.HandlerFunc) (addr string, roots *x509.CertPool) {
	t.Helper()
	authority, err := newAuthority(uploadHost)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(handler)
	server.TLS = &tls.Config{Certificates: []tls.Certificate{authority.leaf}}
	server.StartTLS()
	t.Cleanup(server.Close)
	roots = x509.NewCertPool()
	roots.AppendCertsFromPEM(authority.pem)
	return server.Listener.Addr().String(), roots
}

func TestProxyLeavesTheUploadToGHWhenForemanCannotAttach(t *testing.T) {
	for name, c := range map[string]struct {
		status int
		body   string
		notice bool
	}{
		"and GitHub takes it":   {http.StatusCreated, `{"url":"https://github.com/user-attachments/assets/native"}`, false},
		"and GitHub refuses it": {http.StatusNotFound, `{"message":"Not Found"}`, true},
	} {
		t.Run(name, func(t *testing.T) {
			var seen *http.Request
			var sent []byte
			addr, roots := github(t, func(w http.ResponseWriter, r *http.Request) {
				seen = r
				sent, _ = io.ReadAll(r.Body)
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(c.status)
				io.WriteString(w, c.body)
			})
			var notice bytes.Buffer
			p := &Proxy{
				Notice: &notice,
				Upload: func(context.Context, File) (string, error) {
					return "", &Unavailable{Reason: "Attachments aren't set up for acme."}
				},
				roots: roots,
				dial: func(ctx context.Context, network, target string) (net.Conn, error) {
					if target != uploadHost+":443" {
						return nil, errors.New("dialled " + target)
					}
					var d net.Dialer
					return d.DialContext(ctx, network, addr)
				},
			}
			client := start(t, p)

			status, reply := post(t, client, uploadURL, []byte("png bytes"))

			if status != c.status {
				t.Errorf("status = %d, want GitHub's %d", status, c.status)
			}
			if c.status == http.StatusCreated && reply["url"] != "https://github.com/user-attachments/assets/native" {
				t.Errorf("reply = %v", reply)
			}
			if seen == nil {
				t.Fatal("GitHub was never asked")
			}
			if seen.Method != http.MethodPost || seen.URL.RequestURI() != strings.TrimPrefix(uploadURL, "https://uploads.github.com") {
				t.Errorf("GitHub got %s %s", seen.Method, seen.URL.RequestURI())
			}
			if seen.Header.Get("Authorization") != "token ghu_environment" || seen.Header.Get("Content-Type") != "application/octet-stream" || string(sent) != "png bytes" {
				t.Errorf("GitHub got headers %v and body %q", seen.Header, sent)
			}
			if said := strings.Contains(notice.String(), "Attachments aren't set up for acme."); said != c.notice {
				t.Errorf("notice = %q", notice.String())
			}
		})
	}
}

func TestProxyReachesOtherHostsThroughTheProxyAlreadyConfigured(t *testing.T) {
	elsewhere := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "ok") }))
	defer elsewhere.Close()

	// The proxy the environment was already told to use: it tunnels, and
	// notes where to.
	var mu sync.Mutex
	var tunnelled []string
	var credentials string
	upstream, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer upstream.Close()
	go func() {
		for {
			conn, err := upstream.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				reader := bufio.NewReader(conn)
				req, err := http.ReadRequest(reader)
				if err != nil || req.Method != http.MethodConnect {
					return
				}
				mu.Lock()
				tunnelled = append(tunnelled, req.Host)
				credentials = req.Header.Get("Proxy-Authorization")
				mu.Unlock()
				out, err := net.Dial("tcp", req.Host)
				if err != nil {
					return
				}
				defer out.Close()
				io.WriteString(conn, "HTTP/1.1 200 Connection Established\r\n\r\n")
				go io.Copy(out, reader)
				io.Copy(conn, out)
			}()
		}
	}()

	uploaded := false
	p := &Proxy{
		Upload: func(context.Context, File) (string, error) {
			uploaded = true
			return "https://github.com/user-attachments/assets/5b8ee541", nil
		},
		upstream: func(string) (*url.URL, error) {
			return &url.URL{Scheme: "http", User: url.UserPassword("user", "p@ss word"), Host: upstream.Addr().String()}, nil
		},
	}
	client := start(t, p, elsewhere.Certificate())

	res, err := client.Get(elsewhere.URL)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if status, _ := post(t, client, uploadURL, []byte("x")); status != http.StatusCreated || !uploaded {
		t.Errorf("the upload wasn't answered here: status %d", status)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(tunnelled) != 1 || tunnelled[0] != strings.TrimPrefix(elsewhere.URL, "https://") {
		t.Errorf("the configured proxy tunnelled %v", tunnelled)
	}
	// The password as it is, not as a URL spells it.
	if credentials != "Basic "+base64.StdEncoding.EncodeToString([]byte("user:p@ss word")) {
		t.Errorf("credentials = %q", credentials)
	}
}

func TestProxyRefusesAnythingButATunnel(t *testing.T) {
	p := &Proxy{Upload: func(context.Context, File) (string, error) { return "", nil }}
	start(t, p)
	through, _ := url.Parse(p.URL())
	req, _ := http.NewRequest(http.MethodGet, "http://"+through.Host+"/", nil)
	password, _ := through.User.Password()
	req.Header.Set("Proxy-Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(through.User.Username()+":"+password)))
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("status = %d", res.StatusCode)
	}
}

func TestProxySaysWhyAConnectionCouldNotBeMade(t *testing.T) {
	// A client is told only that its proxy answered 502, so the reason is
	// said where the person will see it: once, and without the password.
	var notice bytes.Buffer
	p := &Proxy{
		Notice: &notice,
		Upload: func(context.Context, File) (string, error) { return "", &Unavailable{Reason: "no token"} },
		upstream: func(string) (*url.URL, error) {
			return url.Parse("socks5://user:hunter2@corporate:1080")
		},
	}
	client := start(t, p)

	for range 2 {
		if _, err := client.Get("https://api.github.com/"); err == nil {
			t.Error("a tunnel was made through a proxy this can't speak to")
		}
	}
	// The upload host's own requests go the same way, and are refused the
	// same way.
	if status, _ := post(t, client, uploadURL, []byte("x")); status != http.StatusBadGateway {
		t.Errorf("status = %d", status)
	}

	said := notice.String()
	if strings.Count(said, "socks5 proxy") != 1 || !strings.HasPrefix(said, "foreman: ") {
		t.Errorf("notice = %q", said)
	}
	if strings.Contains(said, "hunter2") {
		t.Errorf("the proxy's password was printed: %q", said)
	}
}

func TestProxyLeavesNothingListeningWhenItCannotStart(t *testing.T) {
	// The socket is made first, and the port then can't be had.
	listen := tcpListen
	tcpListen = func() (net.Listener, error) { return nil, errors.New("no ports") }
	defer func() { tcpListen = listen }()

	p := &Proxy{Upload: func(context.Context, File) (string, error) { return "", nil }}
	if err := p.Start(); err == nil {
		t.Fatal("started without a port")
	}
	if p.uploads != nil {
		if _, err := p.uploads.Accept(); err == nil {
			t.Error("the upload socket is still listening")
		}
	}
	if _, err := os.Stat(p.dir); !os.IsNotExist(err) {
		t.Errorf("%s was left behind", p.dir)
	}
}

func TestProxyCloseEndsAConnectionStillBeingSetUp(t *testing.T) {
	// A proxy that takes the connection and never answers.
	silent, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer silent.Close()
	held := make(chan net.Conn, 1)
	go func() {
		if conn, err := silent.Accept(); err == nil {
			held <- conn
		}
	}()
	p := &Proxy{
		Upload:   func(context.Context, File) (string, error) { return "", nil },
		upstream: func(string) (*url.URL, error) { return url.Parse("http://" + silent.Addr().String()) },
	}
	client := start(t, p)

	failed := make(chan error, 1)
	go func() {
		_, err := client.Get("https://api.github.com/")
		failed <- err
	}()
	conn := <-held
	defer conn.Close()
	p.Close()

	// Well inside the half minute the handshake would otherwise wait.
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	io.Copy(io.Discard, conn)
	select {
	case <-failed:
	case <-time.After(5 * time.Second):
		t.Error("the connection outlived the proxy")
	}
}
