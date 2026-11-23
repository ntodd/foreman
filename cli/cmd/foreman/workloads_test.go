package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

func TestWorkloadCommandsInBinary(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	var out, diagnostics bytes.Buffer
	if run(context.Background(), []string{"--help"}, &out, &diagnostics) != 0 {
		t.Fatal(diagnostics.String())
	}
	for _, option := range []string{"env create", "--resume", "--confirm-capacity-warning", "op logs", "--timeout"} {
		if !strings.Contains(out.String(), option) {
			t.Errorf("help omits %q", option)
		}
	}
	for _, command := range []string{"repo list", "box list", "env list", "op list"} {
		diagnostics.Reset()
		args := append([]string{"--json"}, strings.Fields(command)...)
		status := run(context.Background(), args, &out, &diagnostics)
		if status == 0 || !strings.Contains(diagnostics.String(), "connection_error") {
			t.Fatalf("%s was not routed to a connected command: %s", command, diagnostics.String())
		}
	}
}
