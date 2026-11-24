// Package completion answers a shell's request for what could come next on a
// foreman command line. The shell scripts only pass the words along, so the
// rules live here, in one place, for every shell.
package completion

import (
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
		return matching(lookup("env"), current)
	case "env create":
		return matching(lookup("repo"), current)
	}
	return nil
}

func choices(kind string, lookup Lookup) []string {
	switch kind {
	case "":
		return nil
	case "env", "repo", "box":
		return lookup(kind)
	}
	return strings.Fields(kind)
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

// Script returns the completion script for a shell. Each one hands the words
// before the cursor to "foreman __complete" and offers what it prints. With
// nothing printed, the shell falls back to file names.
func Script(shell string) (string, bool) {
	script, ok := map[string]string{"bash": bash, "zsh": zsh, "fish": fish}[shell]
	return script, ok
}

const bash = `# bash completion for foreman
_foreman() {
    # Slice before changing IFS: bash 3.2 (macOS) joins a quoted slice into
    # one word when IFS has no space.
    local words=("${COMP_WORDS[@]:1:COMP_CWORD}")
    local IFS=$'\n'
    COMPREPLY=($(foreman __complete "${words[@]}" 2>/dev/null))
}
complete -o default -F _foreman foreman
`

const zsh = `#compdef foreman
# zsh completion for foreman
_foreman() {
    local -a candidates
    candidates=("${(@f)$(foreman __complete "${(@)words[2,CURRENT]}" 2>/dev/null)}")
    if [[ -n "${candidates[1]}" ]]; then
        compadd -Q -- "${candidates[@]}"
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
    set -g __foreman_candidates (foreman __complete $words[2..-1] "$current" 2>/dev/null)
    test (count $__foreman_candidates) -gt 0
end
complete -c foreman -f -n __foreman_complete -a '$__foreman_candidates'
`
