// Package render lays out what the CLI prints for a person at a terminal.
// Output that goes to a pipe or a file keeps its tab-separated form.
package render

import (
	"fmt"
	"io"
	"strings"
	"time"
	"unicode/utf8"
)

// Tone is what a value means, which a terminal shows as a colour.
type Tone int

const (
	Plain Tone = iota
	Dim
	Good
	Warn
	Bad
)

var codes = map[Tone]string{Dim: "2", Good: "32", Warn: "33", Bad: "31"}

type Cell struct {
	Text string
	Tone Tone
}

func paint(colour bool, tone Tone, text string) string {
	code := codes[tone]
	if !colour || code == "" || text == "" {
		return text
	}
	return "\x1b[" + code + "m" + text + "\x1b[0m"
}

// Table writes a header and rows with two spaces between columns, each as
// wide as its widest value. Colour goes around the text and not its padding,
// so the columns line up the same with and without it.
func Table(w io.Writer, colour bool, header []string, rows [][]Cell) error {
	widths := make([]int, len(header))
	for i, name := range header {
		widths[i] = utf8.RuneCountInString(name)
	}
	for _, row := range rows {
		for i, cell := range row {
			if i < len(widths) {
				widths[i] = max(widths[i], utf8.RuneCountInString(cell.Text))
			}
		}
	}
	var b strings.Builder
	line := make([]Cell, len(header))
	for i, name := range header {
		line[i] = Cell{Text: name}
	}
	b.WriteString(paint(colour, Dim, strings.TrimRight(layout(false, widths, line), " ")) + "\n")
	for _, row := range rows {
		b.WriteString(strings.TrimRight(layout(colour, widths, row), " ") + "\n")
	}
	_, err := io.WriteString(w, b.String())
	return err
}

func layout(colour bool, widths []int, row []Cell) string {
	var b strings.Builder
	for i, cell := range row {
		if i >= len(widths) {
			break
		}
		b.WriteString(paint(colour, cell.Tone, cell.Text))
		if i < len(row)-1 && i < len(widths)-1 {
			b.WriteString(strings.Repeat(" ", widths[i]-utf8.RuneCountInString(cell.Text)+2))
		}
	}
	return b.String()
}

func since(now time.Time, stamp string) (time.Duration, time.Time, bool) {
	at, err := time.Parse(time.RFC3339Nano, stamp)
	if err != nil {
		return 0, at, false
	}
	return now.Sub(at), at, true
}

func span(d time.Duration) string {
	switch {
	case d < time.Minute:
		return ""
	case d < time.Hour:
		return fmt.Sprintf("%dm", d/time.Minute)
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", d/time.Hour)
	default:
		return fmt.Sprintf("%dd", d/(24*time.Hour))
	}
}

// Ago turns an API timestamp into "7h ago". Past a month the date says more.
// A value that isn't a timestamp is returned as it came.
func Ago(now time.Time, stamp string) string {
	d, at, ok := since(now, stamp)
	switch {
	case !ok:
		return stamp
	case d >= 30*24*time.Hour:
		return at.UTC().Format("2006-01-02")
	case span(d) == "":
		return "just now"
	default:
		return span(d) + " ago"
	}
}

// Age turns an API timestamp into how long ago it was, as "3d".
func Age(now time.Time, stamp string) string {
	d, _, ok := since(now, stamp)
	switch {
	case !ok:
		return stamp
	case span(d) == "":
		return "now"
	default:
		return span(d)
	}
}
