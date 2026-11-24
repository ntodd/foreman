package completion

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func lookup(kind string) []string {
	return map[string][]string{
		"env":  {"app-me-1", "app-me-2", "web-me-1"},
		"repo": {"acme/app", "acme/web"},
		"box":  {"one", "two"},
	}[kind]
}

func TestCandidatesFollowTheCommandLine(t *testing.T) {
	for _, c := range []struct {
		line string
		want string
	}{
		{"", "login me logout update repo box env op secrets completion help"},
		{"e", "env"},
		{"se", "secrets"},
		{"-", "--instance --account --json --version --help"},
		{"--j", "--json"},
		{"env ", "list show create start stop restart destroy"},
		{"env s", "show start stop"},
		{"--json env s", "show start stop"},
		{"--instance https://foreman.example env d", "destroy"},
		{"op ", "list show wait logs"},
		{"repo ", "list"},
		{"secrets ", "list set unset import"},
		{"secret ", "list set unset import"},
		{"completion ", "bash zsh fish"},
		{"help ", "login me logout secrets completion"},
		{"env show ", "app-me-1 app-me-2 web-me-1"},
		{"env stop app", "app-me-1 app-me-2"},
		{"env restart w", "web-me-1"},
		{"env destroy --yes ", "app-me-1 app-me-2 web-me-1"},
		{"op list a", "app-me-1 app-me-2"},
		{"env create ", "acme/app acme/web"},
		{"env create acme/app --b", "--branch --box"},
		{"env create acme/app --box ", "one two"},
		{"env create acme/app --box=t", "--box=two"},
		{"env create acme/app --box = t", "two"},
		{"env create acme/app --box =", "one two"},
		{"secrets list --env =", "app-me-1 app-me-2 web-me-1"},
		{"env create acme/app --on-expiry ", "stop destroy"},
		{"env restart app-me-1 --", "--all --no-wait --timeout"},
		{"env destroy app-me-1 -", "--yes --no-wait --timeout"},
		{"secrets set A=1 --", "--env --repo --owner --user"},
		{"secrets list --env ", "app-me-1 app-me-2 web-me-1"},
		{"secrets list --env=web", "--env=web-me-1"},
		{"secrets set --repo acme/w", "acme/web"},
		{"login --", "--scope"},
		// Nothing to offer: a value only the caller knows, an operation ID, a second name, a file.
		{"env create acme/app --branch ", ""},
		{"--instance ", ""},
		{"op show ", ""},
		{"env show app-me-1 ", ""},
		{"secrets import ", ""},
		{"secrets set ", ""},
		{"nonsense ", ""},
		{"env nonsense ", ""},
	} {
		words := strings.Split(c.line, " ")
		got := strings.Join(Candidates(words, lookup), " ")
		if got != c.want {
			t.Errorf("%q: %q, want %q", c.line, got, c.want)
		}
	}
}

func TestNamesAreOnlyLookedUpWhereTheyBelong(t *testing.T) {
	var asked []string
	spy := func(kind string) []string {
		asked = append(asked, kind)
		return nil
	}
	for _, line := range []string{"", "env ", "env show app-me-1 --", "secrets set ", "op show "} {
		Candidates(strings.Split(line, " "), spy)
	}
	if len(asked) != 0 {
		t.Fatal(asked)
	}
	Candidates([]string{"env", "show", ""}, spy)
	if !slices.Equal(asked, []string{"env"}) {
		t.Fatal(asked)
	}
}

// A name comes from a server. One that a shell could read as syntax, or that
// would be taken for an ID, is not offered.
func TestOnlyPlainNamesAreOffered(t *testing.T) {
	hostile := func(string) []string {
		return []string{"ok-1", "acme/app.js", "two words", "$(reboot)", "a;b", "back`tick", "tab\tname", "new\nline", "star*", "", "aaaaaaaa-0000-4000-8000-111111111111", "-dash-first"}
	}
	got := strings.Join(Candidates([]string{"env", "show", ""}, hostile), " ")
	if got != "ok-1 acme/app.js" {
		t.Fatalf("%q", got)
	}
}

func TestEveryShellHasAScriptThatAsksTheCLI(t *testing.T) {
	for _, shell := range []string{"bash", "zsh", "fish"} {
		script, ok := Script(shell)
		if !ok || !strings.Contains(script, "foreman __complete") {
			t.Fatalf("%s: %q", shell, script)
		}
		path, err := exec.LookPath(shell)
		if err != nil {
			t.Logf("%s is not installed; skipping its syntax check", shell)
			continue
		}
		file := filepath.Join(t.TempDir(), "foreman."+shell)
		if err := os.WriteFile(file, []byte(script), 0o600); err != nil {
			t.Fatal(err)
		}
		if out, err := exec.Command(path, "-n", file).CombinedOutput(); err != nil {
			t.Fatalf("%s rejects its script: %v\n%s", shell, err, out)
		}
	}
	if _, ok := Script("powershell"); ok {
		t.Fatal("unexpected shell")
	}
}

// stub puts a foreman on PATH that answers with one candidate: the word being
// completed (so a shell that filters by prefix keeps it) and then every word
// it was given. Words arrive on standard input, one per line. Anything typed
// on the command line, a secret included, must stay out of its arguments.
func stub(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	body := "#!/bin/sh\nif [ \"$*\" != __complete ]; then echo \"arguments: $*\"; exit; fi\n" +
		"last=; all=\nwhile IFS= read -r word; do last=$word; all=\"$all[$word]\"; done\nprintf '%s%s\\n' \"$last\" \"$all\"\n"
	if err := os.WriteFile(filepath.Join(dir, "foreman"), []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	return dir + string(os.PathListSeparator) + os.Getenv("PATH")
}

func TestBashPassesTheWordsUpToTheCursor(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	script, _ := Script("bash")
	for _, c := range []struct{ words, cword, want string }{
		{"foreman env sh", "2", "sh[env][sh]"},
		{"foreman env show ''", "3", "[env][show][]"},
		{"foreman env show app-me-1 --all", "2", "show[env][show]"},
		// A candidate is text, not a pattern to expand.
		{"foreman env show '*'", "3", "*[env][show][*]"},
		// Readline replaces only what follows an =, so the flag is cut from
		// the candidate (bash 3.2 on macOS passes --flag=value as one word).
		{"foreman env create r --on-expiry=d", "4", "d[env][create][r][--on-expiry=d]"},
	} {
		program := script + "\nCOMP_WORDS=(" + c.words + "); COMP_CWORD=" + c.cword + "; _foreman; echo \"${COMPREPLY[*]}\"\n"
		cmd := exec.Command(bash, "--norc", "--noprofile", "-c", program)
		cmd.Env = append(os.Environ(), "PATH="+stub(t))
		out, err := cmd.CombinedOutput()
		if err != nil || strings.TrimSpace(string(out)) != c.want {
			t.Fatalf("%s: %v %q, want %q", c.words, err, out, c.want)
		}
	}
}

func TestFishPassesTheWordsUpToTheCursor(t *testing.T) {
	fish, err := exec.LookPath("fish")
	if err != nil {
		t.Skip("fish is not installed")
	}
	script, _ := Script("fish")
	file := filepath.Join(t.TempDir(), "foreman.fish")
	if err := os.WriteFile(file, []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	for line, want := range map[string]string{
		"foreman env sh":    "sh[env][sh]",
		"foreman env show ": "[env][show][]",
	} {
		cmd := exec.Command(fish, "--no-config", "-c", "source "+file+"; complete -C '"+line+"'")
		cmd.Env = append(os.Environ(), "PATH="+stub(t))
		out, err := cmd.CombinedOutput()
		if err != nil || strings.TrimSpace(string(out)) != want {
			t.Fatalf("%q: %v %q, want %q", line, err, out, want)
		}
	}
}

func TestZshPassesTheWordsUpToTheCursor(t *testing.T) {
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("zsh is not installed")
	}
	script, _ := Script("zsh")
	// Outside the line editor the completion builtins don't exist, so stand
	// in for the three the script uses.
	prelude := "compdef() { : }; compadd() { [[ $1 == -- ]] || print -r -- \"options: $*\"; shift; print -r -- \"offered: $*\" }; _files() { print files }\n"
	for _, c := range []struct{ words, current, want string }{
		{"foreman env sh", "3", "offered: sh[env][sh]"},
		{"foreman env show ''", "4", "offered: [env][show][]"},
		{"foreman env show app-me-1 --all", "3", "offered: show[env][show]"},
	} {
		program := prelude + script + "\nwords=(" + c.words + "); CURRENT=" + c.current + "; _foreman\n"
		cmd := exec.Command(zsh, "-f", "-c", program)
		cmd.Env = append(os.Environ(), "PATH="+stub(t))
		out, err := cmd.CombinedOutput()
		if err != nil || strings.TrimSpace(string(out)) != c.want {
			t.Fatalf("%s: %v %q, want %q", c.words, err, out, c.want)
		}
	}
	// With nothing offered, the shell completes file names.
	silent := t.TempDir()
	if err := os.WriteFile(filepath.Join(silent, "foreman"), []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(zsh, "-f", "-c", prelude+script+"\nwords=(foreman secrets import ''); CURRENT=4; _foreman\n")
	cmd.Env = append(os.Environ(), "PATH="+silent+string(os.PathListSeparator)+os.Getenv("PATH"))
	if out, err := cmd.CombinedOutput(); err != nil || strings.TrimSpace(string(out)) != "files" {
		t.Fatalf("%v %q", err, out)
	}
}
