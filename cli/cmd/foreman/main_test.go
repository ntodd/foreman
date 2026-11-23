package main

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestInformationAndErrorsWithoutInstance(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	for _, tc := range []struct {
		args []string
		out  string
		code int
	}{
		{[]string{"--help"}, "--account", 0}, {[]string{"--version"}, "foreman " + version, 0},
		{[]string{"login", "--help"}, "--scope", 0}, {[]string{"--json", "me"}, "", 1},
		{[]string{"--json", "me", "surprise"}, "", 2}, {[]string{"bad", "--json"}, "", 2},
	} {
		var out, stderr bytes.Buffer
		status := run(context.Background(), tc.args, &out, &stderr)
		if status != tc.code || !strings.Contains(out.String(), tc.out) {
			t.Fatalf("%v: %d %q %q", tc.args, status, out.String(), stderr.String())
		}
		if tc.code != 0 {
			var p struct{ Code, Message string }
			if out.Len() != 0 || json.Unmarshal(stderr.Bytes(), &p) != nil || p.Code == "" || p.Message == "" {
				t.Fatalf("unclean failure %v: %q %q", tc.args, out.String(), stderr.String())
			}
		}
	}
}
