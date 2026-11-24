package workloads

import (
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"
)

const defaultTimeout = 30 * time.Minute

var uuidPattern = regexp.MustCompile(`^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$`)

// Flag sets are intentionally command-specific. In particular, --yes never
// acknowledges a placement warning and --confirm-capacity-warning never destroys.
var commandFlags = map[string]string{
	"repo list": "", "box list": "", "env list": "", "env show": "",
	"env create": "branch box expires-at on-expiry resume request-key confirm-capacity-warning no-wait timeout",
	"env start":  "confirm-capacity-warning no-wait timeout", "env stop": "no-wait timeout", "env restart": "all no-wait timeout", "env destroy": "yes no-wait timeout",
	"op list": "", "op show": "", "op wait": "timeout", "op logs": "cursor follow timeout",
}

// A name is an environment's slug.
var namePattern = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)

// takesEnvironment is true for commands whose argument is an environment,
// given by name or ID. An operation only has an ID.
func takesEnvironment(command string) bool {
	switch command {
	case "env show", "env start", "env stop", "env restart", "env destroy", "op list":
		return true
	}
	return false
}

// Flags lists the options a command takes, as a shell completes them.
func Flags(command string) []string {
	var flags []string
	for _, name := range strings.Fields(commandFlags[command]) {
		flags = append(flags, "--"+name)
	}
	return flags
}

type invocation struct {
	command, arg string
	name         string // The environment name arg was resolved from, if it was one.
	flags        map[string]string
	timeout      time.Duration
}

func invalid(format string, args ...any) error {
	return &Failure{Code: "invalid_invocation", Message: fmt.Sprintf(format, args...)}
}

func parse(args []string) (invocation, error) {
	v := invocation{flags: map[string]string{}, timeout: defaultTimeout}
	if len(args) < 2 {
		return v, invalid("Specify a resource and command. See foreman --help.")
	}
	v.command = strings.Join(args[:2], " ")
	allowed, ok := commandFlags[v.command]
	if !ok {
		return v, invalid("Unknown command %q. See foreman --help.", v.command)
	}
	var positional []string
	flags := true
	for i := 2; i < len(args); i++ {
		word := args[i]
		switch {
		case flags && word == "--":
			flags = false
		case flags && strings.HasPrefix(word, "-"):
			key, value, attached := strings.Cut(strings.TrimPrefix(word, "--"), "=")
			if !strings.HasPrefix(word, "--") || key == "" || !slices.Contains(strings.Fields(allowed), key) {
				return v, invalid("Unknown option %q for %s.", word, v.command)
			}
			if _, duplicate := v.flags[key]; duplicate {
				return v, invalid("--%s was supplied more than once.", key)
			}
			switch key {
			case "no-wait", "follow", "yes", "all", "confirm-capacity-warning":
				if attached {
					return v, invalid("--%s takes no value.", key)
				}
				value = "true"
			default:
				if !attached {
					i++
					if i >= len(args) || strings.HasPrefix(args[i], "--") {
						return v, invalid("--%s requires a value.", key)
					}
					value = args[i]
				}
				if strings.TrimSpace(value) == "" {
					return v, invalid("--%s requires a non-empty value.", key)
				}
			}
			v.flags[key] = value
		default:
			positional = append(positional, word)
		}
	}
	want := 1
	switch v.command {
	case "repo list", "box list", "env list":
		want = 0
	case "env create":
		if v.flags["resume"] != "" {
			want = 0
			for _, name := range []string{"branch", "box", "expires-at", "on-expiry", "request-key"} {
				if v.flags[name] != "" {
					return v, invalid("--resume uses the saved request and cannot take --%s.", name)
				}
			}
		}
		if (v.flags["expires-at"] == "") != (v.flags["on-expiry"] == "") {
			return v, invalid("Supply --expires-at and --on-expiry together.")
		}
	}
	if len(positional) != want {
		return v, invalid("%s expects %d positional argument(s). See foreman --help.", v.command, want)
	}
	if want == 1 {
		v.arg = positional[0]
		switch {
		case v.command == "env create":
			if strings.TrimSpace(v.arg) == "" {
				return v, invalid("Supply a repository for %s.", v.command)
			}
		case uuidPattern.MatchString(v.arg):
		case !takesEnvironment(v.command):
			return v, invalid("Supply a valid resource ID for %s.", v.command)
		case !namePattern.MatchString(v.arg):
			return v, invalid("Supply an environment name or ID for %s.", v.command)
		}
	}
	if duration := v.flags["timeout"]; duration != "" {
		d, err := time.ParseDuration(duration)
		if err != nil || d <= 0 {
			return v, invalid("--timeout requires a positive duration such as 30s.")
		}
		v.timeout = d
	}
	return v, nil
}
