// Package completion answers a shell's request for what could come next on a
// foreman command line. The shell scripts only pass the words along, so the
// rules live here, in one place, for every shell.
package completion

import (
	"regexp"
	"slices"
	"strings"

	"github.com/ntodd/foreman/cli/internal/workloads"
)

// Lookup returns the names of one kind of thing the caller can see: "env",
// "repo" or "box". It returns nothing when they can't be read.
type Lookup func(kind string) []string

var (
	commands    = []string{"login", "me", "logout", "update", "repo", "box", "env", "op", "secrets", "completion", "help"}
	global      = []string{"--instance", "--account", "--json", "--version", "--help"}
	subcommands = map[string][]string{
		"repo": {"list"}, "box": {"list"},
		"env":        {"list", "show", "create", "start", "stop", "restart", "destroy"},
		"op":         {"list", "show", "wait", "logs"},
		"secrets":    {"list", "set", "unset", "import"},
		"completion": {"bash", "zsh", "fish"},
		"help":       {"login", "me", "logout", "secrets", "completion"},
	}
	secretFlags = []string{"--env", "--repo", "--owner", "--user"}
	// What follows a flag: a kind of name to look up, fixed choices, or
	// (empty) a value only the caller knows.
	values = map[string]string{
		"--env": "env", "--repo": "repo", "--box": "box", "--on-expiry": "stop destroy",
		"--instance": "", "--account": "", "--scope": "", "--owner": "", "--branch": "", "--expires-at": "",
		"--resume": "", "--request-key": "", "--timeout": "", "--cursor": "",
	}
)

// Candidates returns what could complete the last of words, which are the
// arguments after "foreman" up to the cursor. The last word may be empty.
func Candidates(words []string, lookup Lookup) []string {
	if len(words) == 0 {
		words = []string{""}
	}
	current, before := words[len(words)-1], words[:len(words)-1]

	// The value of a flag, written --flag value, --flag=value, or (as bash
	// splits it) --flag = value.
	if len(before) > 1 && before[len(before)-1] == "=" {
		before = before[:len(before)-1]
	} else if current == "=" && len(before) > 0 {
		if _, takesValue := values[before[len(before)-1]]; takesValue {
			current = ""
		}
	}
	if len(before) > 0 {
		if kind, ok := values[before[len(before)-1]]; ok {
			return matching(choices(kind, lookup), current)
		}
	}
	if flag, partial, attached := strings.Cut(current, "="); attached && strings.HasPrefix(flag, "--") {
		kind, ok := values[flag]
		if !ok {
			return nil
		}
		found := matching(choices(kind, lookup), partial)
		for i := range found {
			found[i] = flag + "=" + found[i]
		}
		return found
	}

	var positional []string
	for i := 0; i < len(before); i++ {
		word := before[i]
		if !strings.HasPrefix(word, "-") {
			positional = append(positional, word)
		} else if _, takesValue := values[word]; takesValue {
			i++
		}
	}
	if len(positional) > 0 && positional[0] == "secret" {
		positional[0] = "secrets"
	}
	flag := strings.HasPrefix(current, "-")
	switch {
	case len(positional) == 0 && flag:
		return matching(global, current)
	case len(positional) == 0:
		return matching(commands, current)
	case len(positional) == 1 && flag && positional[0] == "login":
		return matching([]string{"--scope"}, current)
	case len(positional) == 1 && !flag:
		return matching(subcommands[positional[0]], current)
	case len(positional) == 1:
		return nil
	}
	command := positional[0] + " " + positional[1]
	if positional[0] == "secrets" {
		if flag && slices.Contains(subcommands["secrets"], positional[1]) {
			return matching(secretFlags, current)
		}
		return nil
	}
	if flag {
		return matching(workloads.Flags(command), current)
	}
	if len(positional) != 2 {
		return nil
	}
	switch command {
	case "env show", "env start", "env stop", "env restart", "env destroy", "op list":
		return matching(choices("env", lookup), current)
	case "env create":
		return matching(choices("repo", lookup), current)
	}
	return nil
}

func choices(kind string, lookup Lookup) []string {
	switch kind {
	case "":
		return nil
	case "env", "repo", "box":
		return plain(lookup(kind))
	}
	return strings.Fields(kind)
}

var (
	plainName = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9._/-]*$`)
	uuidName  = regexp.MustCompile(`^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$`)
)

// plain keeps the names that are safe to put on a command line. They come
// from a server, so one a shell could read as syntax is left out, and so is
// one shaped like an ID: the command would take it for a different thing.
func plain(names []string) []string {
	var kept []string
	for _, name := range names {
		if plainName.MatchString(name) && !uuidName.MatchString(name) {
			kept = append(kept, name)
		}
	}
	return kept
}

func matching(candidates []string, prefix string) []string {
	var found []string
	for _, candidate := range candidates {
		if strings.HasPrefix(candidate, prefix) {
			found = append(found, candidate)
		}
	}
	return found
}

// Script returns the completion script for a shell. Each one writes the words
// before the cursor to "foreman __complete", one per line on standard input,
// and offers what it prints. The words never become arguments: a secret
// typed as NAME=value would otherwise show in the process list the moment
// Tab is pressed. With nothing printed, the shell falls back to file names.
func Script(shell string) (string, bool) {
	script, ok := map[string]string{"bash": bash, "zsh": zsh, "fish": fish}[shell]
	return script, ok
}

const bash = `# bash completion for foreman
_foreman() {
    local word current="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=()
    # Each candidate is read as text, so nothing in one is expanded.
    while IFS= read -r word; do
        # Readline replaces only what follows an =, when = breaks words.
        if [[ "$current" == --*=* && "$COMP_WORDBREAKS" == *=* ]]; then
            word="${word#"${current%%=*}="}"
        fi
        COMPREPLY+=("$word")
    done < <(printf '%s\n' "${COMP_WORDS[@]:1:COMP_CWORD}" | foreman __complete 2>/dev/null)
}
complete -o default -F _foreman foreman
`

const zsh = `#compdef foreman
# zsh completion for foreman
_foreman() {
    local -a candidates
    candidates=("${(@f)$(print -rl -- "${(@)words[2,CURRENT]}" | foreman __complete 2>/dev/null)}")
    if [[ -n "${candidates[1]}" ]]; then
        compadd -- "${candidates[@]}"
    else
        _files
    fi
}
if [[ "${funcstack[1]}" = "_foreman" ]]; then
    _foreman "$@"
else
    compdef _foreman foreman
fi
`

const fish = `# fish completion for foreman
function __foreman_complete
    set -l words (commandline -opc)
    set -l current (commandline -ct)
    set -g __foreman_candidates (printf '%s\n' $words[2..-1] "$current" | foreman __complete 2>/dev/null)
    test (count $__foreman_candidates) -gt 0
end
complete -c foreman -f -n __foreman_complete -a '$__foreman_candidates'
`
