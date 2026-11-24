package main

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/ntodd/foreman/cli/internal/secrets"
	"github.com/ntodd/foreman/cli/session"
	"golang.org/x/term"
)

const secretsHelp = `Usage: foreman [--instance ORIGIN] [--account ID] [--json] secrets COMMAND

  secrets list                   List secret names at one level. Values are never shown.
  secrets set NAME=value ...     Set one or more secrets in a single request.
          NAME=@file             Read the value from a file (its final newline is dropped).
          NAME=-                 Read the value from standard input, for one secret.
                                 On a terminal it asks, like NAME alone.
          NAME                   Ask for the value without showing it.
  secrets unset NAME ...         Remove secrets. A name that isn't set is left alone.
  secrets import FILE            Set every NAME=value line of a dotenv file (- for standard input).

Choose the level with one of:
  --env ENV                      One environment of yours, by name or ID
  --repo OWNER/NAME | ID         Every environment of a repository (admins)
  --owner LOGIN                  Every environment of an owner's repositories (admins)
  --user                         All of your own environments (the default)

An environment gets owner, then repository, then your own, then its own secrets, and a
later level wins. A request changes everything it names or nothing. In a running
environment new shells pick a change up shortly; processes and services already running
keep their previous values. foreman env restart ID recreates the services whose compose
configuration uses what changed. Add --all to stop and start every container instead,
for a process that read the secrets file when it started.

A value typed as NAME=value is saved in your shell history. Use NAME=@file, NAME=- or NAME
for anything sensitive. A value that itself begins with @ has to come one of those ways.

Secrets need the secrets:list and secrets:write permissions. foreman login asks for both.
A connection narrowed with --scope, or made by an older CLI, has to log in again.
`

func runSecrets(ctx context.Context, args []string, o options, stdout, stderr io.Writer) int {
	s, err := session.Open(ctx, o.instance, o.account)
	if err != nil {
		return fail(stderr, o.json, err, "connection_error", 1)
	}
	options := secrets.Options{API: s.Client, In: os.Stdin, Out: stdout, Err: stderr, JSON: o.json, Pretty: pretty(o, stdout), Colour: colour(o, stdout)}
	if terminal(os.Stdin) {
		options.Prompt = func(name string) (string, error) {
			fmt.Fprintf(stderr, "Value for %s: ", name)
			value, err := term.ReadPassword(int(os.Stdin.Fd()))
			fmt.Fprintln(stderr)
			return string(value), err
		}
	}
	if secrets.Run(ctx, args, options) != nil {
		return 1
	}
	return 0
}
