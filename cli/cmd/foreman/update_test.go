package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

func TestUpdateValidatesArgumentsBeforeSelectingAccount(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	var out, diagnostics bytes.Buffer
	if status := run(context.Background(), []string{"--json", "update", "extra"}, &out, &diagnostics); status != 2 ||
		!strings.Contains(diagnostics.String(), "update takes no arguments") || out.Len() != 0 {
		t.Fatalf("invalid update invocation returned %d, stdout %q, stderr %q", status, &out, &diagnostics)
	}
}
