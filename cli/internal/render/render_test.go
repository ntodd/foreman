package render

import (
	"bytes"
	"testing"
	"time"
)

func TestTableAlignsColumnsToTheirWidestValue(t *testing.T) {
	var out bytes.Buffer
	err := Table(&out, false, []string{"BOX", "STATUS", "ID"}, [][]Cell{
		{{Text: "a"}, {Text: "online", Tone: Good}, {Text: "1", Tone: Dim}},
		{{Text: "longer-name"}, {Text: "offline", Tone: Bad}, {Text: "2", Tone: Dim}},
	})
	want := "BOX          STATUS   ID\n" +
		"a            online   1\n" +
		"longer-name  offline  2\n"
	if err != nil || out.String() != want {
		t.Fatalf("%v\n%q\n%q", err, out.String(), want)
	}
}

func TestTableColoursWithoutDisturbingTheAlignment(t *testing.T) {
	var out bytes.Buffer
	if err := Table(&out, true, []string{"BOX", "STATUS"}, [][]Cell{
		{{Text: "a"}, {Text: "online", Tone: Good}},
		{{Text: "bb"}, {Text: "offline", Tone: Bad}},
	}); err != nil {
		t.Fatal(err)
	}
	want := "\x1b[2mBOX  STATUS\x1b[0m\n" +
		"a    \x1b[32monline\x1b[0m\n" +
		"bb   \x1b[31moffline\x1b[0m\n"
	if out.String() != want {
		t.Fatalf("%q\n%q", out.String(), want)
	}
}

func TestTableCountsCharactersNotBytes(t *testing.T) {
	var out bytes.Buffer
	if err := Table(&out, false, []string{"STATUS", "X"}, [][]Cell{
		{{Text: "stopped → running"}, {Text: "1"}},
		{{Text: "running"}, {Text: "2"}},
	}); err != nil {
		t.Fatal(err)
	}
	want := "STATUS             X\n" +
		"stopped → running  1\n" +
		"running            2\n"
	if out.String() != want {
		t.Fatalf("%q\n%q", out.String(), want)
	}
}

func TestAgoReadsLikeAPersonWouldSayIt(t *testing.T) {
	now := time.Date(2026, 11, 24, 12, 0, 0, 0, time.UTC)
	for stamp, want := range map[string]string{
		"2026-11-24T11:59:40Z":        "just now",
		"2026-11-24T11:57:59.5Z":      "2m ago",
		"2026-11-24T05:00:00Z":        "7h ago",
		"2026-11-21T11:59:59.628073Z": "3d ago",
		"2026-08-01T12:00:00Z":        "2026-08-01",
		"2026-11-24T12:00:30Z":        "just now",
		"not a time":                  "not a time",
		"":                            "",
	} {
		if got := Ago(now, stamp); got != want {
			t.Errorf("%q: %q, want %q", stamp, got, want)
		}
	}
}

func TestAgeDropsTheSuffix(t *testing.T) {
	now := time.Date(2026, 11, 24, 12, 0, 0, 0, time.UTC)
	for stamp, want := range map[string]string{
		"2026-11-24T11:59:40Z": "now",
		"2026-11-24T11:58:00Z": "2m",
		"2026-11-21T12:00:00Z": "3d",
		"2026-08-01T12:00:00Z": "115d",
		"":                     "",
	} {
		if got := Age(now, stamp); got != want {
			t.Errorf("%q: %q, want %q", stamp, got, want)
		}
	}
}
