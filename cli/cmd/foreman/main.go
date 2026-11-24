package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/ntodd/foreman/cli/api"
	"github.com/ntodd/foreman/cli/internal/completion"
	"github.com/ntodd/foreman/cli/internal/selfupdate"
	"github.com/ntodd/foreman/cli/internal/workloads"
	"github.com/ntodd/foreman/cli/session"
)

// Release builds set -X main.version=vX.Y.Z.
var version = "dev"

const help = `Usage: foreman [--instance ORIGIN] [--account ID] [--json] COMMAND

  login [--scope 'PERMISSIONS']  Connect through browser approval on any device
  me                             Show who this connection acts as
  logout                         Revoke the selected personal connection

  update                         Install the latest stable CLI release
  completion bash|zsh|fish       Print a shell completion script (see help completion)
  repo list | box list | env list
  env show ENV                   Show environment state and SSH details
  env create REPO                Create from an owner/name or repository UUID
    [--branch NAME] [--box BOX] [--expires-at TIME --on-expiry stop|destroy]
    [--request-key KEY] [--confirm-capacity-warning]
  env create --resume KEY        Replay a saved submission
  env start|stop|destroy ENV     Change the environment state (destroy asks, or takes
                                 --yes with an ID)
  env restart ENV [--all]        Recreate the services that use a changed secret
                                 (--all: stop and start every container instead)
  op list ENV | op show OP_ID
  op wait OP_ID                  Wait for completion
  op logs OP_ID [--follow] [--cursor CURSOR]

  secrets list                   List secret names at one level (never values)
  secrets set NAME=value ...     Set several at once; NAME=@file reads a file, NAME asks
  secrets unset NAME ...         Remove secrets
  secrets import FILE            Set everything in a dotenv file (- for standard input)
    [--env ENV | --repo REPO | --owner LOGIN | --user]  Default: your own secrets

ENV is an environment's name, as env list shows it, or its ID. A name can pass
to a newer environment after a destroy, so scripts should use IDs.
Lifecycle commands wait by default. Use --no-wait for submission only
or --timeout 30s to bound a wait.

At a terminal, lists are aligned tables. Piped or redirected, they stay
tab-separated with their original columns. Scripts should use --json.

  --instance ORIGIN              Foreman HTTPS origin (loopback HTTP for development)
  --account ID                   Select an account on this instance
  --json                         Emit machine-readable output
  --version                      Print the CLI version
  --help                         Show command help

Login saves the instance and account for subsequent commands.
`

type options struct {
	instance, account   string
	json, help, version bool
}

// Global selectors may appear before or after the subcommand. Leave all
// command-specific arguments intact for the selected handler.
func parse(args []string) (options, []string, error) {
	o := options{json: slices.Contains(args, "--json")}
	var rest []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "--json":
			continue
		case "--help", "-h":
			o.help = true
			continue
		case "--version":
			o.version = true
			continue
		case "--":
			// Preserve the boundary for the subcommand's own option parser.
			if len(rest) == 0 {
				i++
			}
			rest = append(rest, args[i:]...)
			return o, rest, nil
		}
		name, value, assigned := strings.Cut(arg, "=")
		if name != "--instance" && name != "--account" {
			rest = append(rest, arg)
			continue
		}
		if !assigned {
			if i+1 >= len(args) || strings.HasPrefix(args[i+1], "-") {
				return o, nil, fmt.Errorf("%s requires a value", name)
			}
			i++
			value = args[i]
		}
		if value == "" {
			return o, nil, fmt.Errorf("%s requires a value", name)
		}
		if name == "--instance" {
			o.instance = value
		} else {
			o.account = value
		}
	}
	return o, rest, nil
}

type failure struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func fail(stderr io.Writer, machine bool, err error, code string, status int) int {
	var remote *api.HTTPError
	if errors.As(err, &remote) {
		code = remote.Code
	}
	if errors.Is(err, context.Canceled) {
		code = "interrupted"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		code = "timeout"
	}
	if machine {
		_ = json.NewEncoder(stderr).Encode(failure{Code: code, Message: err.Error()})
	} else {
		fmt.Fprintln(stderr, err)
	}
	return status
}

const completionHelp = `Usage: foreman completion bash|zsh|fish

Print a completion script for your shell. It completes commands, options and
the names of your environments, repositories and boxes. Completion only reads
and leaves refreshing the connection to the commands you run, so names are
offered while the access token is fresh: up to fifteen minutes after you log
in or a command refreshes it.

  bash   foreman completion bash > ~/.local/share/bash-completion/completions/foreman
  zsh    foreman completion zsh > ~/.zfunc/_foreman
         with fpath+=(~/.zfunc) before compinit in ~/.zshrc
  fish   foreman completion fish > ~/.config/fish/completions/foreman.fish

To try it in the shell you have open: source <(foreman completion zsh)
`

// stdin is a variable so a test can supply the words to complete.
var stdin io.Reader = os.Stdin

// completionDeadline bounds everything a press of Tab waits for.
var completionDeadline = 3 * time.Second

// complete answers a completion script. The words after "foreman" up to the
// cursor come in on standard input, each ended by a NUL: as arguments, a
// secret typed as NAME=value would show in the process list as soon as Tab
// was pressed. What could finish the last word goes out, one per line. It
// never fails and never writes diagnostics into the middle of a prompt.
func complete(ctx context.Context, in io.Reader, stdout io.Writer) {
	if terminal(in) {
		return // Run by hand: there is nothing to read.
	}
	ctx, cancel := context.WithTimeout(ctx, completionDeadline)
	defer cancel()
	read := make(chan []byte, 1)
	go func() {
		raw, _ := io.ReadAll(io.LimitReader(in, 1<<20))
		read <- raw
	}()
	var raw []byte
	select {
	case raw = <-read:
	case <-ctx.Done():
		return
	}
	words := strings.Split(strings.TrimSuffix(string(raw), "\x00"), "\x00")
	instance, account := completion.Selectors(words)
	lookup := func(kind string) []string {
		// Tab can be cut off at any moment, so it only ever reads: a refresh
		// interrupted here could spend the refresh token and lose the reply.
		// Names are offered while the saved access token is still good.
		s, err := session.OpenReadOnly(ctx, instance, account)
		if err != nil {
			return nil
		}
		names, _ := workloads.Names(ctx, s.Client, kind)
		return names
	}
	for _, candidate := range completion.Candidates(words, lookup) {
		fmt.Fprintln(stdout, candidate)
	}
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	// The words being completed are not this invocation's own options.
	if len(args) > 0 && args[0] == "__complete" {
		complete(ctx, stdin, stdout)
		return 0
	}
	o, args, err := parse(args)
	if err != nil {
		return fail(stderr, o.json, err, "invalid_invocation", 2)
	}
	if o.version {
		if len(args) != 0 {
			return fail(stderr, o.json, errors.New("--version does not take a command"), "invalid_invocation", 2)
		}
		if o.json {
			err = json.NewEncoder(stdout).Encode(map[string]string{"version": version})
		} else {
			_, err = fmt.Fprintln(stdout, "foreman", version)
		}
		if err != nil {
			return fail(stderr, o.json, err, "output_error", 1)
		}
		return 0
	}
	if len(args) > 0 && args[0] == "help" {
		o.help = true
		args = args[1:]
	}
	if o.help {
		usage := help
		if len(args) > 0 {
			switch args[0] {
			case "login":
				usage = "Usage: foreman [--instance ORIGIN] [--account ID] [--json] login [--scope 'PERMISSIONS']\n\nApprove on any device using the printed verification URL and code.\nA login asks for every permission by default: " + session.DefaultScope + "\nPass --scope to connect with fewer.\n"
			case "me":
				usage = "Usage: foreman [--instance ORIGIN] [--account ID] [--json] me\n\nShow who the selected connection acts as, on which instance and with which permissions.\nPiped or with --json, print the identity as JSON.\n"
			case "logout":
				usage = "Usage: foreman [--instance ORIGIN] [--account ID] [--json] logout\n\nRevoke the selected personal connection.\n"
			case "secrets", "secret":
				usage = secretsHelp
			case "completion":
				usage = completionHelp
			default:
				return fail(stderr, o.json, fmt.Errorf("unknown command %q", args[0]), "invalid_invocation", 2)
			}
		}
		_, err = io.WriteString(stdout, usage)
		if err != nil {
			return fail(stderr, o.json, err, "output_error", 1)
		}
		return 0
	}
	if len(args) == 0 {
		return fail(stderr, o.json, errors.New("a command is required; use foreman --help"), "invalid_invocation", 2)
	}
	command := args[0]
	if command == "update" {
		if len(args) != 1 {
			return fail(stderr, o.json, errors.New("update takes no arguments"), "invalid_invocation", 2)
		}
		installed, err := selfupdate.Update(ctx, version)
		if err != nil {
			return fail(stderr, o.json, err, "update_failed", 1)
		}
		if o.json {
			err = json.NewEncoder(stdout).Encode(map[string]string{"version": installed})
		} else {
			_, err = fmt.Fprintln(stdout, "foreman", installed)
		}
		if err != nil {
			return fail(stderr, o.json, err, "output_error", 1)
		}
		return 0
	}
	if command == "completion" {
		script, ok := "", false
		if len(args) == 2 {
			script, ok = completion.Script(args[1])
		}
		if !ok {
			return fail(stderr, o.json, errors.New("completion takes one shell: bash, zsh or fish"), "invalid_invocation", 2)
		}
		if _, err = io.WriteString(stdout, script); err != nil {
			return fail(stderr, o.json, err, "output_error", 1)
		}
		return 0
	}
	if notice := selfupdate.Notice(ctx, version, interactive(stdout, stderr), o.json); notice != "" {
		fmt.Fprintln(stderr, notice)
	}
	switch command {
	case "repo", "box", "env", "op":
		return runWorkload(ctx, args, o, stdout, stderr)
	case "secrets", "secret":
		return runSecrets(ctx, args, o, stdout, stderr)
	}
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	var scope string
	switch command {
	case "login":
		flags.StringVar(&scope, "scope", session.DefaultScope, "space-separated permissions")
	case "me", "logout":
	default:
		return fail(stderr, o.json, fmt.Errorf("unknown command %q; use foreman --help", command), "invalid_invocation", 2)
	}
	if err = flags.Parse(args[1:]); err != nil {
		return fail(stderr, o.json, err, "invalid_invocation", 2)
	}
	if flags.NArg() != 0 {
		return fail(stderr, o.json, fmt.Errorf("unexpected argument %q for %s", flags.Arg(0), command), "invalid_invocation", 2)
	}
	if command == "login" && strings.TrimSpace(scope) == "" {
		return fail(stderr, o.json, errors.New("--scope requires at least one permission"), "invalid_invocation", 2)
	}
	store, err := session.DefaultStore()
	if err != nil {
		return fail(stderr, o.json, err, "state_error", 1)
	}
	switch command {
	case "login":
		var conn session.Connection
		conn, err = store.Login(ctx, o.instance, o.account, scope, func(p session.DevicePrompt) error {
			_, e := fmt.Fprintf(stderr, "Open %s and enter %s\n", p.VerificationURI, p.UserCode)
			return e
		})
		if err == nil {
			switch {
			case o.json:
				err = json.NewEncoder(stdout).Encode(conn)
			case pretty(o, stdout):
				// The name is a courtesy. The login itself has already succeeded.
				who := conn.Account
				if s, e := store.Open(ctx, conn.Instance, conn.Account); e == nil {
					if reply, e := s.Client.GetIdentity(ctx); e == nil {
						who = named(reply.Value)
					}
				}
				_, err = fmt.Fprintf(stdout, "Connected to %s as %s.\nPermissions: %s.\n", conn.Instance, who, permissions(conn.Scope))
			default:
				_, err = fmt.Fprintf(stdout, "Connected %s with permissions %s\n", conn.Account, conn.Scope)
			}
		}
	case "me":
		var s *session.Session
		if s, err = store.Open(ctx, o.instance, o.account); err == nil {
			var reply *api.Response[api.Identity]
			if reply, err = s.Client.GetIdentity(ctx); err == nil {
				if pretty(o, stdout) {
					_, err = fmt.Fprintf(stdout, "%s on %s\nAccount:      %s\nClient:       %s\nPermissions:  %s\n", named(reply.Value), s.Instance, reply.Value.ID, reply.Value.ClientID, permissions(s.Scope))
				} else {
					err = json.NewEncoder(stdout).Encode(reply.Body)
				}
			}
		}
	case "logout":
		var account string
		if account, err = store.Logout(ctx, o.instance, o.account); err == nil {
			if o.json {
				err = json.NewEncoder(stdout).Encode(map[string]string{"account": account})
			} else {
				_, err = fmt.Fprintln(stdout, "Disconnected", account)
			}
		}
	}
	if err != nil {
		return fail(stderr, o.json, err, "connection_error", 1)
	}
	return 0
}

// named is what an identity is called: a name when the server gives one
// (0.8.3 on), otherwise its ID.
func named(identity api.Identity) string {
	if identity.Name != nil && *identity.Name != "" {
		return *identity.Name
	}
	return identity.ID
}

// permissions describes a grant. One that holds every default permission is
// the usual case and doesn't need thirteen names to say so.
func permissions(scope string) string {
	granted := strings.Fields(scope)
	for _, wanted := range strings.Fields(session.DefaultScope) {
		if !slices.Contains(granted, wanted) {
			return scope
		}
	}
	return "everything the CLI can do"
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	status := run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	stop()
	os.Exit(status)
}
