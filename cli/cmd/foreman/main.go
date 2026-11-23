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

	"github.com/ntodd/foreman/cli/api"
	"github.com/ntodd/foreman/cli/internal/selfupdate"
	"github.com/ntodd/foreman/cli/session"
)

// Release builds set -X main.version=vX.Y.Z.
var version = "dev"

const help = `Usage: foreman [--instance ORIGIN] [--account ID] [--json] COMMAND

  login [--scope 'PERMISSIONS']  Connect through browser approval on any device
  me                             Show the acting identity as JSON
  logout                         Revoke the selected personal connection

  update                         Install the latest stable CLI release
  repo list | box list | env list
  env show ID                    Show environment state and SSH details
  env create REPO                Create from an owner/name or repository UUID
    [--branch NAME] [--box BOX] [--expires-at TIME --on-expiry stop|destroy]
    [--request-key KEY] [--confirm-capacity-warning]
  env create --resume KEY        Replay a saved submission
  env start|stop|destroy ID      Change the environment state (--yes confirms destroy)
  env restart ID [--all]         Recreate the services whose secrets changed, or all of them
  op list ENV_ID | op show OP_ID
  op wait OP_ID                  Wait for completion
  op logs OP_ID [--follow] [--cursor CURSOR]

  secrets list                   List secret names at one level (never values)
  secrets set NAME=value ...     Set several at once; NAME=@file reads a file, NAME asks
  secrets unset NAME ...         Remove secrets
  secrets import FILE            Set everything in a dotenv file (- for standard input)
    [--env ID | --repo REPO | --owner LOGIN | --user]   Default: your own secrets

Lifecycle commands wait by default. Use --no-wait for submission only
or --timeout 30s to bound a wait.

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

func run(ctx context.Context, args []string, stdout, stderr io.Writer) int {
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
				usage = "Usage: foreman [--instance ORIGIN] [--account ID] [--json] login [--scope 'PERMISSIONS']\n\nApprove on any device using the printed verification URL and code.\nDefault permissions: " + session.DefaultScope + "\n"
			case "me":
				usage = "Usage: foreman [--instance ORIGIN] [--account ID] me\n\nPrint the selected connection's acting identity as JSON.\n"
			case "logout":
				usage = "Usage: foreman [--instance ORIGIN] [--account ID] [--json] logout\n\nRevoke the selected personal connection.\n"
			case "secrets", "secret":
				usage = secretsHelp
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
			if o.json {
				err = json.NewEncoder(stdout).Encode(conn)
			} else {
				_, err = fmt.Fprintf(stdout, "Connected %s with permissions %s\n", conn.Account, conn.Scope)
			}
		}
	case "me":
		var s *session.Session
		if s, err = store.Open(ctx, o.instance, o.account); err == nil {
			var reply *api.Response[api.Identity]
			if reply, err = s.Client.GetIdentity(ctx); err == nil {
				err = json.NewEncoder(stdout).Encode(reply.Body)
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

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	status := run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	stop()
	os.Exit(status)
}
