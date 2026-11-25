package ghattach

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"slices"
	"strings"
	"syscall"
)

// Where Go looks for certificate directories on Linux when SSL_CERT_DIR
// isn't set (crypto/x509). Setting the variable replaces the list, so a
// gh told about one more directory is told about these too.
const systemCertDirs = "/etc/ssl/certs:/etc/pki/tls/certs"

// Options is one run of gh behind the proxy.
type Options struct {
	// GH is the path of the real gh, and Args what it was asked to do.
	GH   string
	Args []string
	// Upload sends a file to Foreman (Uploader.Upload).
	Upload func(context.Context, File) (string, error)
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
	// Env is gh's environment before the proxy is added. Nil is this
	// process's own. Where the proxy sends what it passes on follows this
	// process's own proxy settings either way.
	Env []string
}

// Run runs gh with its uploads answered by a proxy of its own, and
// returns gh's exit status.
//
// gh finds the proxy through HTTPS_PROXY and trusts it through
// SSL_CERT_DIR, which Go reads on Linux: one more directory, holding
// the proxy's authority and nothing else, in front of the ones already
// in use. Both are set for this one process, and the directory is
// deleted when gh exits.
//
// A proxy that can't be started is no reason not to run gh: it runs as
// it is, and its own upload is what happens.
func Run(o Options) (int, error) {
	env := o.Env
	if env == nil {
		env = os.Environ()
	}
	proxy := &Proxy{Upload: o.Upload, Notice: o.Stderr}
	if err := proxy.Start(); err != nil {
		if o.Stderr != nil {
			fmt.Fprintf(o.Stderr, "foreman: couldn't start the upload proxy (%v), so gh is uploading on its own\n", err)
		}
		return execute(o, env)
	}
	defer proxy.Close()

	dirs := systemCertDirs
	if already := lookup(env, "SSL_CERT_DIR"); already != "" {
		dirs = already
	}
	replaced := []string{"HTTPS_PROXY", "https_proxy", "NO_PROXY", "no_proxy", "SSL_CERT_DIR"}
	// The proxy asks the environment's own settings where each HTTPS
	// connection should go, so gh loses no exemption by sending them all
	// to it. Plain HTTP doesn't come this way, and keeps the exemptions
	// that don't cover the upload host. One for every host ("*") can't be
	// kept without covering it, so the proxies it switched off go instead:
	// gh's own, and the one the git and curl it runs would use.
	exempt, everything := exemptions(lookup(env, "NO_PROXY"), lookup(env, "no_proxy"))
	off := []string{"HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"}
	if everything {
		replaced = append(replaced, off...)
	}
	env = slices.DeleteFunc(slices.Clone(env), func(entry string) bool {
		name, _, _ := strings.Cut(entry, "=")
		return slices.Contains(replaced, name)
	})
	env = append(env,
		"HTTPS_PROXY="+proxy.URL(), "https_proxy="+proxy.URL(),
		"NO_PROXY="+exempt, "no_proxy=",
		"SSL_CERT_DIR="+proxy.CertDir()+":"+dirs,
	)
	if everything {
		for _, name := range off {
			env = append(env, name+"=")
		}
	}
	return execute(o, env)
}

// exemptions is the hosts exempt from proxies (NO_PROXY, or no_proxy
// when that is all there is), without the entries that would exempt the
// upload host, and whether one of them exempted every host.
func exemptions(upper, lower string) (kept string, everything bool) {
	list := upper
	if list == "" {
		list = lower
	}
	var keep []string
	for _, entry := range strings.Split(list, ",") {
		entry = strings.TrimSpace(entry)
		switch {
		case entry == "":
		case entry == "*":
			everything = true
		case covers(entry, uploadHost, "443"):
		default:
			keep = append(keep, entry)
		}
	}
	if everything {
		return "", true
	}
	return strings.Join(keep, ","), false
}

// covers reports whether a NO_PROXY entry exempts host on port, as Go
// reads one: a name exempts itself and what is under it, one with a
// leading dot (or "*.") only what is under it, and one with a port only
// that port. An address or a range never covers a name.
func covers(entry, host, port string) bool {
	entry = strings.ToLower(entry)
	if name, only, err := net.SplitHostPort(entry); err == nil {
		if only != port {
			return false
		}
		entry = name
	}
	entry = strings.TrimPrefix(entry, "*")
	if strings.HasPrefix(entry, ".") {
		return strings.HasSuffix(host, entry)
	}
	return entry == host || strings.HasSuffix(host, "."+entry)
}

// Plain runs gh with nothing in front of it, for where Foreman can't be
// asked to upload.
func Plain(o Options) (int, error) {
	env := o.Env
	if env == nil {
		env = os.Environ()
	}
	return execute(o, env)
}

// execute runs gh and waits for it, standing where gh would have stood
// had it been run directly: a signal sent to this process reaches gh as
// the signal it was, and gh's end is reported the way a shell would
// report it.
func execute(o Options, env []string) (int, error) {
	cmd := exec.Command(o.GH, o.Args...)
	cmd.Env, cmd.Stdin, cmd.Stdout, cmd.Stderr = env, o.Stdin, o.Stdout, o.Stderr

	// Caught before gh starts, so none is lost in between, and so this
	// process outlives gh to say how it ended. (A key pressed at a
	// terminal reaches gh from the terminal too, as it does any wrapper.)
	signals := make(chan os.Signal, 8)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(signals)

	if err := cmd.Start(); err != nil {
		return 127, err
	}
	ended := make(chan error, 1)
	go func() { ended <- cmd.Wait() }()
	for {
		select {
		case sent := <-signals:
			cmd.Process.Signal(sent)
		case err := <-ended:
			return status(err)
		}
	}
}

// status is gh's exit status, and 128 plus the signal's number for a gh
// that a signal ended, as a shell reports it.
func status(err error) (int, error) {
	var exited *exec.ExitError
	switch {
	case err == nil:
		return 0, nil
	case errors.As(err, &exited):
		if wait, ok := exited.Sys().(syscall.WaitStatus); ok && wait.Signaled() {
			return 128 + int(wait.Signal()), nil
		}
		return exited.ExitCode(), nil
	default:
		return 127, err
	}
}

// lookup is the last value an environment gives a name, as a process
// started with it would see.
func lookup(env []string, name string) string {
	value := ""
	for _, entry := range env {
		if key, v, ok := strings.Cut(entry, "="); ok && key == name {
			value = v
		}
	}
	return value
}
