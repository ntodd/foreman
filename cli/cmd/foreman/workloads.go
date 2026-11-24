package main

import (
	"context"
	"io"
	"os"
	"strings"

	"github.com/ntodd/foreman/cli/internal/workloads"
	"github.com/ntodd/foreman/cli/session"
	"golang.org/x/term"
)

// isTerminal is a variable so a test can stand in for a terminal.
var isTerminal = func(stream any) bool {
	file, ok := stream.(*os.File)
	return ok && term.IsTerminal(int(file.Fd()))
}

func terminal(stream any) bool { return isTerminal(stream) }

// pretty is true when a person reads standard output. A pipe, a file and
// --json keep the formats scripts depend on.
func pretty(o options, stdout io.Writer) bool { return !o.json && terminal(stdout) }

func colour(o options, stdout io.Writer) bool {
	return pretty(o, stdout) && os.Getenv("NO_COLOR") == "" && os.Getenv("TERM") != "dumb"
}

func interactive(stdout, stderr io.Writer) bool {
	return terminal(os.Stdin) && terminal(stdout) && terminal(stderr)
}

func runWorkload(ctx context.Context, args []string, o options, stdout, stderr io.Writer) int {
	s, err := session.Open(ctx, o.instance, o.account)
	if err != nil {
		return fail(stderr, o.json, err, "connection_error", 1)
	}
	err = workloads.Run(ctx, args, workloads.Options{
		API: s.Client, StateDir: s.StateDir, Instance: s.Instance, Account: s.Account,
		ClientID: session.ClientID, Scopes: strings.Fields(s.Scope),
		In: os.Stdin, Out: stdout, Err: stderr, JSON: o.json, Interactive: !o.json && interactive(stdout, stderr),
		Pretty: pretty(o, stdout), Colour: colour(o, stdout),
	})
	if err != nil {
		return 1
	}
	return 0
}
