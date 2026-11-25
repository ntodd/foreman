package ghattach

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

// uploadHost is where gh sends an attached file.
const uploadHost = "uploads.github.com"

const uploadPath = "/user-attachments/assets"

// maxUpload is the most gh sends for one file (its limit for a video).
// The control plane's own limits are lower and are what a person hears
// about; this only bounds what is read into memory.
const maxUpload = 100 << 20

// handshake bounds how long setting a connection up may take: a dial, or
// a proxy's answer to CONNECT. A tunnel, once made, lasts as long as gh
// and the other end want it.
const handshake = 30 * time.Second

// Proxy is an HTTP proxy for one run of gh. It answers a connection to
// the upload host itself, as that host, and tunnels a connection to any
// other host without reading it.
//
// Answering as the upload host takes a certificate gh trusts. The proxy
// makes its own authority when it starts, good for that one name, signs
// one certificate with it and forgets the authority's key. CertDir holds
// the authority's certificate, for the gh it fronts to be told to trust
// beside the system's.
//
// It is for that gh and no one else. The proxy's port is on loopback,
// which every user in a container shares, so its URL carries a secret
// made for the run, and a request without it gets no tunnel. Uploads are
// answered on a unix socket in a directory only this user can enter,
// which the proxy alone connects to.
type Proxy struct {
	// Upload sends a file to Foreman and returns the asset's URL. An
	// *Unavailable error sends gh's own request on to GitHub instead.
	Upload func(context.Context, File) (string, error)
	// Notice is where a line for the person goes. Nil for none.
	Notice io.Writer

	// How a connection that isn't answered here leaves: the proxy already
	// configured for a host, if any, and the dial. Tests replace them.
	upstream func(hostport string) (*url.URL, error)
	dial     func(ctx context.Context, network, addr string) (net.Conn, error)
	// roots vouch for the real upload host, and for a proxy spoken to
	// over TLS. Nil is the system's.
	roots *x509.CertPool

	authority *authority
	secret    string
	dir       string
	proxy     net.Listener
	uploads   net.Listener
	servers   []*http.Server
	github    *http.Transport
	noticed   sync.Once

	mu          sync.Mutex
	tunnels     map[net.Conn]struct{} // every connection in use, being set up included
	established int                   // tunnels carrying traffic
	said        map[string]bool
	closed      bool
}

// tcpListen is the proxy's own port. A test stands in for it.
var tcpListen = func() (net.Listener, error) { return net.Listen("tcp", "127.0.0.1:0") }

// unsupportedProxy is an upstream proxy this one can't tunnel through.
type unsupportedProxy struct{ scheme string }

func (e *unsupportedProxy) Error() string {
	return fmt.Sprintf("can't send gh's connections through the %s proxy set in this environment; only HTTP and HTTPS proxies are supported", e.scheme)
}

// Start listens. Close stops it and removes what it made.
func (p *Proxy) Start() (err error) {
	if p.upstream == nil {
		p.upstream = environmentProxy
	}
	if p.dial == nil {
		p.dial = (&net.Dialer{Timeout: handshake}).DialContext
	}
	p.tunnels = map[net.Conn]struct{}{}
	p.said = map[string]bool{}
	if p.authority, err = newAuthority(uploadHost); err != nil {
		return err
	}
	secret := make([]byte, 24)
	if _, err = rand.Read(secret); err != nil {
		return err
	}
	p.secret = hex.EncodeToString(secret)

	// 0700, the user's own: the socket inside is as private as the
	// environment's API socket, which is what an upload spends.
	if p.dir, err = os.MkdirTemp("", "foreman-gh-attach-"); err != nil {
		return err
	}
	defer func() {
		if err != nil {
			p.Close()
		}
	}()
	if err = os.Mkdir(p.CertDir(), 0o700); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(p.CertDir(), "foreman-gh-attach.pem"), p.authority.pem, 0o600); err != nil {
		return err
	}
	if p.uploads, err = net.Listen("unix", filepath.Join(p.dir, "uploads.sock")); err != nil {
		return err
	}
	if p.proxy, err = tcpListen(); err != nil {
		return err
	}

	p.github = &http.Transport{
		Proxy:                 func(req *http.Request) (*url.URL, error) { return p.route(hostport(req.URL)) },
		DialContext:           p.dial,
		TLSClientConfig:       &tls.Config{RootCAs: p.roots},
		TLSHandshakeTimeout:   handshake,
		ResponseHeaderTimeout: 2 * time.Minute,
	}
	uploads := &http.Server{
		Handler: http.HandlerFunc(p.serveUpload),
		// One protocol, so nothing depends on which gh would rather speak.
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{p.authority.leaf}, NextProtos: []string{"http/1.1"}},
		ReadHeaderTimeout: handshake,
		ErrorLog:          quiet,
	}
	tunnels := &http.Server{Handler: http.HandlerFunc(p.serveTunnel), ReadHeaderTimeout: handshake, ErrorLog: quiet}
	p.servers = []*http.Server{uploads, tunnels}
	go uploads.ServeTLS(p.uploads, "", "")
	go tunnels.Serve(p.proxy)
	return nil
}

// URL is the proxy's address with the run's secret, for HTTPS_PROXY.
func (p *Proxy) URL() string {
	return (&url.URL{Scheme: "http", User: url.UserPassword("foreman", p.secret), Host: p.proxy.Addr().String()}).String()
}

// CertDir is a directory holding the proxy's authority and nothing
// else, for SSL_CERT_DIR.
func (p *Proxy) CertDir() string { return filepath.Join(p.dir, "certs") }

// CA is the proxy's authority as a PEM certificate.
func (p *Proxy) CA() []byte { return p.authority.pem }

// Close stops listening, ends the tunnels still open (a server doesn't
// know of a connection once it has been handed over) and removes the
// directory.
func (p *Proxy) Close() error {
	p.mu.Lock()
	p.closed = true
	open := p.tunnels
	p.tunnels = map[net.Conn]struct{}{}
	p.mu.Unlock()
	for conn := range open {
		conn.Close()
	}
	for _, server := range p.servers {
		server.Close()
	}
	// A listener no server was ever given, when starting failed part way.
	for _, listener := range []net.Listener{p.uploads, p.proxy} {
		if listener != nil {
			listener.Close()
		}
	}
	if p.github != nil {
		p.github.CloseIdleConnections()
	}
	if p.dir != "" {
		return os.RemoveAll(p.dir)
	}
	return nil
}

// open is how many tunnels are carrying traffic, for tests.
func (p *Proxy) open() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.established
}

// say tells the person something once, however often it happens. A
// client learns only that its proxy answered 502, so a reason it could
// act on is said here.
func (p *Proxy) say(line string) {
	if p.Notice == nil {
		return
	}
	p.mu.Lock()
	repeated := p.said[line]
	p.said[line] = true
	p.mu.Unlock()
	if !repeated {
		fmt.Fprintln(p.Notice, "foreman: "+line)
	}
}

// unreachable says why a connection gh asked for wasn't made.
func (p *Proxy) unreachable(host string, err error) {
	var unsupported *unsupportedProxy
	if errors.As(err, &unsupported) {
		p.say(err.Error())
		return
	}
	p.say(fmt.Sprintf("couldn't connect to %s for gh: %v", host, err))
}

// track notes a connection so Close can end it. False once the proxy
// has closed.
func (p *Proxy) track(conns ...net.Conn) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return false
	}
	for _, conn := range conns {
		p.tunnels[conn] = struct{}{}
	}
	return true
}

func (p *Proxy) forget(conns ...net.Conn) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, conn := range conns {
		delete(p.tunnels, conn)
	}
}

// authorized reports whether a request carries the run's secret, as the
// gh that was given the proxy's URL sends it.
func (p *Proxy) authorized(r *http.Request) bool {
	want := "Basic " + base64.StdEncoding.EncodeToString([]byte("foreman:"+p.secret))
	return subtle.ConstantTimeCompare([]byte(r.Header.Get("Proxy-Authorization")), []byte(want)) == 1
}

// serveTunnel handles CONNECT, the only thing an HTTPS client asks of
// its proxy.
func (p *Proxy) serveTunnel(w http.ResponseWriter, r *http.Request) {
	if !p.authorized(r) {
		w.Header().Set("Proxy-Authenticate", `Basic realm="foreman-gh-attach"`)
		http.Error(w, "this proxy is for the gh it was started for", http.StatusProxyAuthRequired)
		return
	}
	if r.Method != http.MethodConnect {
		http.Error(w, "this proxy only tunnels", http.StatusMethodNotAllowed)
		return
	}
	var out net.Conn
	var err error
	if r.Host == uploadHost+":443" {
		var d net.Dialer
		out, err = d.DialContext(r.Context(), "unix", p.uploads.Addr().String())
	} else {
		out, err = p.reach(r.Context(), r.Host)
	}
	if err != nil {
		p.unreachable(r.Host, err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer out.Close()
	defer p.forget(out, raw(out))
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "this connection can't be tunnelled", http.StatusInternalServerError)
		return
	}
	in, buffered, err := hijacker.Hijack()
	if err != nil {
		return
	}
	defer in.Close()
	if !p.track(in, out) {
		return
	}
	defer p.forget(in)
	p.count(1)
	defer p.count(-1)
	if _, err = io.WriteString(in, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	done := make(chan struct{}, 2)
	// What the client sent behind its CONNECT is in the buffer already.
	go func() { io.Copy(out, buffered); done <- struct{}{} }()
	go func() { io.Copy(in, out); done <- struct{}{} }()
	// Either side closing ends the tunnel, and the deferred closes end
	// the other copy.
	<-done
}

func (p *Proxy) count(by int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.established += by
}

// route is the proxy the environment already names for a host, if it is
// one this proxy can go through, or nil for a direct connection.
func (p *Proxy) route(target string) (*url.URL, error) {
	through, err := p.upstream(target)
	if err != nil || through == nil {
		return nil, err
	}
	if through.Scheme != "http" && through.Scheme != "https" {
		return nil, &unsupportedProxy{scheme: through.Scheme}
	}
	return through, nil
}

// reach connects to a host the way this process would have on its own:
// through the proxy the environment already configures for it, or
// directly.
func (p *Proxy) reach(ctx context.Context, target string) (_ net.Conn, err error) {
	through, err := p.route(target)
	if err != nil {
		return nil, err
	}
	if through == nil {
		return p.dial(ctx, "tcp", target)
	}
	conn, err := p.dial(ctx, "tcp", hostport(through))
	if err != nil {
		return nil, err
	}
	// Known from here on, so closing the proxy ends a handshake a far
	// end never answers.
	plain := conn
	if !p.track(plain) {
		plain.Close()
		return nil, errors.New("the proxy has closed")
	}
	defer func() {
		if err != nil {
			p.forget(plain)
			plain.Close()
		}
	}()
	// The proxy's answer is waited for only so long. The tunnel it makes
	// has no deadline.
	conn.SetDeadline(time.Now().Add(handshake))
	if through.Scheme == "https" {
		secure := tls.Client(conn, &tls.Config{ServerName: through.Hostname(), RootCAs: p.roots})
		if err = secure.HandshakeContext(ctx); err != nil {
			return nil, err
		}
		conn = secure
	}
	connect := &http.Request{Method: http.MethodConnect, URL: &url.URL{Opaque: target}, Host: target, Header: http.Header{}}
	if through.User != nil {
		// The name and password themselves, not the way a URL spells them.
		password, _ := through.User.Password()
		credentials := through.User.Username() + ":" + password
		connect.Header.Set("Proxy-Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(credentials)))
	}
	if err = connect.Write(conn); err != nil {
		return nil, err
	}
	reader := bufio.NewReader(conn)
	res, err := http.ReadResponse(reader, connect)
	if err != nil {
		return nil, err
	}
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("the proxy at %s refused a tunnel to %s: %s", through.Host, target, res.Status)
	}
	conn.SetDeadline(time.Time{})
	// Anything the far end sent straight after the proxy's answer was
	// read with it, and is the tunnel's.
	return &tunnel{Conn: conn, reader: reader, plain: plain}, nil
}

// tunnel is a connection through another proxy, whose first bytes may
// already have been read.
type tunnel struct {
	net.Conn
	reader *bufio.Reader
	plain  net.Conn // as it was dialled, which is what Close knows it by
}

func (t *tunnel) Read(b []byte) (int, error) { return t.reader.Read(b) }

// raw is the connection as it was dialled.
func raw(conn net.Conn) net.Conn {
	if through, ok := conn.(*tunnel); ok {
		return through.plain
	}
	return conn
}

// hostport is a URL's host with the port its scheme implies when it
// names none.
func hostport(u *url.URL) string {
	if u.Port() != "" {
		return u.Host
	}
	port := "80"
	if u.Scheme == "https" {
		port = "443"
	}
	return net.JoinHostPort(u.Hostname(), port)
}

// environmentProxy is the proxy the shell's settings name for an HTTPS
// host, or nil for none.
func environmentProxy(target string) (*url.URL, error) {
	return http.ProxyFromEnvironment(&http.Request{URL: &url.URL{Scheme: "https", Host: target}})
}

// serveUpload answers the upload host's one endpoint that gh's --attach
// uses, in the shape GitHub answers it. Anything else sent to the host,
// a release asset for one, is GitHub's to answer.
func (p *Proxy) serveUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || r.URL.Path != uploadPath {
		p.native(w, r, nil)
		return
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, maxUpload+1))
	if err != nil {
		answer(w, http.StatusBadRequest, "message", "The upload couldn't be read.")
		return
	}
	if len(data) > maxUpload {
		answer(w, http.StatusUnprocessableEntity, "message", "The file is too large to attach.")
		return
	}
	query := r.URL.Query()
	repository, _ := strconv.ParseInt(query.Get("repository_id"), 10, 64)
	asset, err := p.Upload(r.Context(), File{Name: query.Get("name"), RepositoryID: repository, Data: data})
	var unavailable *Unavailable
	switch {
	case errors.As(err, &unavailable):
		r.Body = io.NopCloser(bytes.NewReader(data))
		p.native(w, r, unavailable)
	case err != nil:
		// gh prints a 422's message beside the file's name. Any other
		// status it explains in its own words, which here would be wrong.
		answer(w, http.StatusUnprocessableEntity, "message", Message(err))
	default:
		answer(w, http.StatusCreated, "url", asset)
	}
}

func answer(w http.ResponseWriter, status int, key, value string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{key: value})
}

// native sends gh's request to GitHub as gh wrote it, and gives gh the
// whole of GitHub's answer: its status, its headers (a redirect's
// Location, the encoding of a compressed body) and its body. It is what
// would have happened without this proxy, so a deployment that hasn't
// set attachments up loses nothing by it, and the day GitHub takes an
// environment's token the upload works.
//
// `why` is the reason Foreman didn't upload an attachment itself, and
// nil for a request that was never Foreman's.
func (p *Proxy) native(w http.ResponseWriter, r *http.Request, why *Unavailable) {
	forward := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL.Scheme, pr.Out.URL.Host, pr.Out.Host = "https", uploadHost, uploadHost
		},
		Transport: p.github,
		ModifyResponse: func(res *http.Response) error {
			if why != nil && res.StatusCode == http.StatusNotFound && p.Notice != nil {
				p.noticed.Do(func() {
					fmt.Fprintf(p.Notice, "foreman: GitHub rejects attachment uploads made with a GitHub App token, which is what this environment has, and Foreman can't upload for it yet. %s\n", why.Reason)
				})
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			p.unreachable(uploadHost, err)
			answer(w, http.StatusBadGateway, "message", err.Error())
		},
		ErrorLog: quiet,
	}
	forward.ServeHTTP(w, r)
}

// authority is a certificate authority that can vouch for one host name
// and nothing else, with the one certificate it issued for that name.
// The authority's key isn't kept: nothing more is ever signed with it.
type authority struct {
	pem  []byte
	leaf tls.Certificate
}

func newAuthority(host string) (*authority, error) {
	now := time.Now()
	valid := func(c *x509.Certificate) *x509.Certificate {
		c.NotBefore, c.NotAfter = now.Add(-time.Hour), now.Add(24*time.Hour)
		return c
	}
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	ca := valid(&x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Foreman gh attachment proxy"},
		IsCA:                  true,
		BasicConstraintsValid: true,
		MaxPathLenZero:        true,
		KeyUsage:              x509.KeyUsageCertSign,
		// A client that trusts this authority trusts it for this name alone:
		// not the names under it, which permitting it would include, and
		// no address, which a name constraint leaves open unless it names
		// them.
		PermittedDNSDomainsCritical: true,
		PermittedDNSDomains:         []string{host},
		ExcludedDNSDomains:          []string{"." + host},
		ExcludedIPRanges: []*net.IPNet{
			{IP: net.IPv4zero, Mask: net.CIDRMask(0, 32)},
			{IP: net.IPv6zero, Mask: net.CIDRMask(0, 128)},
		},
	})
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &caKey.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	leaf := valid(&x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: host},
		DNSNames:     []string{host},
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	})
	leafDER, err := x509.CreateCertificate(rand.Reader, leaf, ca, &leafKey.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	return &authority{
		pem:  pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}),
		leaf: tls.Certificate{Certificate: [][]byte{leafDER}, PrivateKey: leafKey},
	}, nil
}

// quiet keeps a server's own complaints (a client that hung up, a
// handshake that failed) out of gh's output.
var quiet = log.New(io.Discard, "", 0)
