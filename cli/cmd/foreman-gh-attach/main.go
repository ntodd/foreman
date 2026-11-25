// foreman-gh-attach runs gh with its --attach uploads sent through
// Foreman. It ships in the Foreman devcontainer feature and is run by the
// feature's gh wrapper, inside an environment: it is not part of the
// foreman CLI, and means nothing anywhere else.
//
//	foreman-gh-attach GH [ARGUMENTS]
//
// See internal/ghattach for what it does and why.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/ntodd/foreman/cli/api"
	"github.com/ntodd/foreman/cli/internal/ghattach"
)

// socket is where an environment finds the API from inside itself. Its
// box relays each request as that environment, with no token involved.
const socket = "/run/foreman/api.sock"

const usage = `Usage: foreman-gh-attach GH [ARGUMENTS]

Runs the gh at GH with the files it attaches (--attach) uploaded through
Foreman. A Foreman environment's own gh runs this by itself.
`

// environment asks the control plane which environment this is.
func environment(ctx context.Context, client *api.Client) (string, error) {
	identity, err := client.GetIdentity(ctx)
	if err != nil {
		return "", fmt.Errorf("this environment's connection to Foreman isn't available (%w)", err)
	}
	if env := identity.Value.Environment; env != nil && env.ID != "" {
		return env.ID, nil
	}
	return "", errors.New("Foreman didn't say which environment this is")
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		io.WriteString(stderr, usage)
		return 2
	}
	o := ghattach.Options{GH: args[0], Args: args[1:], Stdin: os.Stdin, Stdout: stdout, Stderr: stderr}

	path := socket
	if override := os.Getenv("FOREMAN_API_SOCKET"); override != "" {
		path = override
	}
	client := api.NewSocketClient(path)
	var status int
	id, err := environment(context.Background(), client)
	if err != nil {
		// gh is still what was asked for. Its own upload is what would
		// have happened without Foreman.
		fmt.Fprintf(stderr, "foreman: %v, so gh is uploading on its own\n", err)
		status, err = ghattach.Plain(o)
	} else {
		o.Upload = ghattach.Uploader{API: client, Environment: id}.Upload
		status, err = ghattach.Run(o)
	}
	if err != nil {
		fmt.Fprintf(stderr, "foreman: couldn't run %s: %v\n", o.GH, err)
	}
	return status
}

// Signals are gh's: while it runs they are passed on to it as they came
// (ghattach), and this process ends when gh does, with gh's status.
func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}
