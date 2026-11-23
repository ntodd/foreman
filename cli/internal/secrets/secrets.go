// Package secrets implements the commands that list and change Foreman secrets.
package secrets

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"slices"
	"strings"

	"github.com/ntodd/foreman/cli/api"
)

// API is the subset of the generated v1 client used by secrets commands.
type API interface {
	ListRepos(context.Context, string) (*api.Response[api.RepositoryPage], error)
	ListSecrets(context.Context, string, string, string) (*api.Response[api.SecretPage], error)
	ChangeSecrets(context.Context, string, string, api.SecretChanges) (*api.Response[api.SecretChangeResult], error)
}

var _ API = (*api.Client)(nil)

// maxChanges is the server's limit on one request. A request is all or
// nothing, so a larger import is refused instead of being split.
const maxChanges = 100

type Options struct {
	API      API
	In       io.Reader
	Out, Err io.Writer
	JSON     bool
	// Prompt reads one value without echoing it. Nil when there is no terminal to ask.
	Prompt func(name string) (string, error)
	// ReadFile defaults to os.ReadFile.
	ReadFile func(string) ([]byte, error)
	// LoginScope is the permission list to suggest when the connection lacks one.
	LoginScope string
}

// Failure is the final stderr document in JSON mode.
type Failure struct {
	Code       string `json:"code"`
	Message    string `json:"message"`
	HTTPStatus int    `json:"http_status,omitempty"`
}

func (f *Failure) Error() string { return f.Code + ": " + f.Message }

func invalid(format string, args ...any) error {
	return &Failure{Code: "invalid_invocation", Message: fmt.Sprintf(format, args...)}
}

func failure(err error) *Failure {
	var f *Failure
	if errors.As(err, &f) {
		return f
	}
	var remote *api.HTTPError
	switch {
	case errors.As(err, &remote):
		code, message := remote.Code, remote.Message
		if code == "" {
			code = "http_error"
		}
		if message == "" {
			message = remote.Error()
		}
		return &Failure{Code: code, Message: message, HTTPStatus: remote.StatusCode}
	case errors.Is(err, context.Canceled):
		return &Failure{Code: "interrupted", Message: "Command interrupted."}
	case errors.Is(err, context.DeadlineExceeded):
		return &Failure{Code: "request_timeout", Message: "The request timed out."}
	default:
		return &Failure{Code: "request_failed", Message: err.Error()}
	}
}

const usage = "Use foreman secrets list, set, unset or import. See foreman help secrets."

var (
	uuidPattern = regexp.MustCompile(`^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$`)
	// Looser than the server's rule on purpose: this only tells a name from
	// a typo. The server owns which names are allowed.
	namePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
)

type target struct{ scope, subject, label string }

type invocation struct {
	command string
	flags   map[string]string
	args    []string
}

// Run accepts arguments starting with the resource name. It writes the
// result and any diagnostics, and returns the failure for the exit status.
func Run(ctx context.Context, args []string, o Options) error {
	if o.ReadFile == nil {
		o.ReadFile = os.ReadFile
	}
	err := o.run(ctx, args)
	if err == nil {
		return nil
	}
	f := failure(err)
	if o.JSON {
		_ = json.NewEncoder(o.Err).Encode(f)
		return f
	}
	fmt.Fprintln(o.Err, f.Error())
	if f.Code == "insufficient_scope" && o.LoginScope != "" {
		fmt.Fprintf(o.Err, "Connect with the permission: foreman login --scope %q\n", o.LoginScope)
	}
	return f
}

func (o Options) run(ctx context.Context, args []string) error {
	v, err := parse(args)
	if err != nil {
		return err
	}
	switch v.command {
	case "list":
		if len(v.args) != 0 {
			return invalid("secrets list takes no names.")
		}
		return o.list(ctx, v)
	case "set":
		set, err := o.pairs(v.args)
		if err != nil {
			return err
		}
		return o.change(ctx, v, set, nil)
	case "unset":
		if len(v.args) == 0 {
			return invalid("Name at least one secret to remove.")
		}
		for _, name := range v.args {
			if !namePattern.MatchString(name) {
				return invalid("%q is not a secret name.", name)
			}
		}
		if err := unique(v.args); err != nil {
			return err
		}
		return o.change(ctx, v, nil, v.args)
	default: // import
		if len(v.args) != 1 {
			return invalid("secrets import takes one file, or - for standard input.")
		}
		set, err := o.dotenv(v.args[0])
		if err != nil {
			return err
		}
		return o.change(ctx, v, set, nil)
	}
}

func parse(args []string) (invocation, error) {
	v := invocation{flags: map[string]string{}}
	if len(args) < 2 || !slices.Contains([]string{"list", "set", "unset", "import"}, args[1]) {
		return v, invalid("%s", usage)
	}
	v.command = args[1]
	flags := true
	for i := 2; i < len(args); i++ {
		word := args[i]
		switch {
		case flags && word == "--":
			flags = false
		case flags && word == "-" && v.command == "import":
			v.args = append(v.args, word)
		case flags && strings.HasPrefix(word, "-"):
			key, value, attached := strings.Cut(strings.TrimPrefix(word, "--"), "=")
			if !strings.HasPrefix(word, "--") || !slices.Contains([]string{"env", "repo", "owner", "user"}, key) {
				return v, invalid("Unknown option %q for secrets %s.", word, v.command)
			}
			if _, duplicate := v.flags[key]; duplicate {
				return v, invalid("--%s was supplied more than once.", key)
			}
			if key == "user" {
				if attached {
					return v, invalid("--user takes no value.")
				}
				value = "me"
			} else if !attached {
				i++
				if i >= len(args) || strings.HasPrefix(args[i], "--") {
					return v, invalid("--%s requires a value.", key)
				}
				value = args[i]
			}
			if strings.TrimSpace(value) == "" {
				return v, invalid("--%s requires a non-empty value.", key)
			}
			v.flags[key] = value
		default:
			v.args = append(v.args, word)
		}
	}
	if len(v.flags) > 1 {
		return v, invalid("Choose one of --env, --repo, --owner and --user.")
	}
	return v, nil
}

// target resolves the scope flag. With none, the secrets are the caller's own.
func (o Options) target(ctx context.Context, v invocation) (target, error) {
	if id, ok := v.flags["env"]; ok {
		return target{"environment", id, "environment " + id}, nil
	}
	if owner, ok := v.flags["owner"]; ok {
		return target{"owner", owner, "owner " + owner}, nil
	}
	name, ok := v.flags["repo"]
	if !ok {
		return target{"user", "me", "your own secrets"}, nil
	}
	if uuidPattern.MatchString(name) {
		return target{"repo", strings.ToLower(name), "repository " + name}, nil
	}
	cursor, seen := "", map[string]bool{"": true}
	for {
		page, err := o.API.ListRepos(ctx, cursor)
		if err != nil {
			return target{}, err
		}
		for _, repo := range page.Value.Items {
			if repo.FullName == name {
				return target{"repo", repo.ID, "repository " + name}, nil
			}
		}
		if page.Value.NextCursor == nil {
			return target{}, &Failure{Code: "resource_not_found", Message: fmt.Sprintf("No visible repository is named %q.", name)}
		}
		cursor = *page.Value.NextCursor
		if seen[cursor] {
			return target{}, &Failure{Code: "invalid_response", Message: "The repository list repeated a page."}
		}
		seen[cursor] = true
	}
}

func (o Options) list(ctx context.Context, v invocation) error {
	t, err := o.target(ctx, v)
	if err != nil {
		return err
	}
	items := []api.Secret{}
	cursor, seen := "", map[string]bool{"": true}
	for {
		page, err := o.API.ListSecrets(ctx, t.scope, t.subject, cursor)
		if err != nil {
			return err
		}
		items = append(items, page.Value.Items...)
		if page.Value.NextCursor == nil {
			break
		}
		cursor = *page.Value.NextCursor
		if seen[cursor] {
			return &Failure{Code: "invalid_response", Message: "The secret list repeated a page."}
		}
		seen[cursor] = true
	}
	if o.JSON {
		return json.NewEncoder(o.Out).Encode(map[string]any{"items": items})
	}
	if _, err := fmt.Fprintln(o.Out, "NAME\tUPDATED"); err != nil {
		return err
	}
	for _, item := range items {
		if _, err := fmt.Fprintln(o.Out, item.Name+"\t"+item.UpdatedAt); err != nil {
			return err
		}
	}
	return nil
}

// pairs turns NAME=value, NAME=@file and NAME (asked for) into values.
// Nothing is sent unless every value could be read.
func (o Options) pairs(args []string) ([]api.SecretValue, error) {
	if len(args) == 0 {
		return nil, invalid("Give at least one NAME=value, NAME=@file or NAME.")
	}
	set := make([]api.SecretValue, 0, len(args))
	names := make([]string, 0, len(args))
	for _, arg := range args {
		name, value, assigned := strings.Cut(arg, "=")
		if !namePattern.MatchString(name) {
			return nil, invalid("%q is not a secret name.", name)
		}
		switch {
		case !assigned && o.Prompt == nil:
			return nil, invalid("%s has no value and there is no terminal to ask on. Use %s=value or %s=@file.", name, name, name)
		case !assigned:
			typed, err := o.Prompt(name)
			if err != nil {
				return nil, invalid("Could not read a value for %s: %v", name, err)
			}
			value = typed
		case strings.HasPrefix(value, "@"):
			body, err := o.ReadFile(value[1:])
			if err != nil {
				return nil, invalid("Could not read the file for %s: %v", name, err)
			}
			value = trimNewline(string(body))
		}
		set = append(set, api.SecretValue{Name: name, Value: value})
		names = append(names, name)
	}
	return set, unique(names)
}

// A file's last line ending is the editor's, not the secret's.
func trimNewline(s string) string {
	return strings.TrimSuffix(strings.TrimSuffix(s, "\n"), "\r")
}

func unique(names []string) error {
	seen := map[string]bool{}
	for _, name := range names {
		if seen[name] {
			return invalid("%s is given more than once.", name)
		}
		seen[name] = true
	}
	return nil
}

func (o Options) change(ctx context.Context, v invocation, set []api.SecretValue, unset []string) error {
	if len(set)+len(unset) > maxChanges {
		return invalid("That is %d changes, and one request takes at most %d. Split it up.", len(set)+len(unset), maxChanges)
	}
	t, err := o.target(ctx, v)
	if err != nil {
		return err
	}
	body := api.SecretChanges{}
	if len(set) > 0 {
		body.Secrets = &set
	}
	if len(unset) > 0 {
		body.Unset = &unset
	}
	reply, err := o.API.ChangeSecrets(ctx, t.scope, t.subject, body)
	if err != nil {
		return err
	}
	result := reply.Value
	if o.JSON {
		return json.NewEncoder(o.Out).Encode(result)
	}
	w := o.Out
	if len(result.Set) > 0 {
		fmt.Fprintf(w, "Set %s on %s.\n", strings.Join(result.Set, ", "), t.label)
	}
	if len(result.Unset) > 0 {
		fmt.Fprintf(w, "Removed %s from %s.\n", strings.Join(result.Unset, ", "), t.label)
	}
	var skipped []string
	for _, name := range unset {
		if !slices.Contains(result.Unset, name) {
			skipped = append(skipped, name)
		}
	}
	if len(skipped) > 0 {
		fmt.Fprintf(w, "Not set there, so left alone: %s.\n", strings.Join(skipped, ", "))
	}
	if len(result.PendingRestart) > 0 {
		fmt.Fprintln(w, "New shells in these running environments see the change now. Their running processes and services keep the previous values until a restart:")
		for _, env := range result.PendingRestart {
			fmt.Fprintf(w, "  %s  %s\n", env.Slug, env.ID)
		}
		id := result.PendingRestart[0].ID
		fmt.Fprintf(w, "Restart one with: foreman env stop %s && foreman env start %s\n", id, id)
	}
	if n := result.OthersPendingRestart; n > 0 {
		_, err = fmt.Fprintf(w, "%d running environment(s) of other people are waiting on a restart too.\n", n)
	}
	return err
}

// dotenv reads KEY=value lines: blank lines and # comments are skipped,
// a leading "export " is allowed, single quotes are literal, double
// quotes take \n, \r, \t, \" and \\, and an unquoted value ends at a
// trailing " #comment". Errors name the line, never its value.
func (o Options) dotenv(path string) ([]api.SecretValue, error) {
	var body []byte
	var err error
	if path == "-" {
		body, err = io.ReadAll(o.In)
	} else {
		body, err = o.ReadFile(path)
	}
	if err != nil {
		return nil, invalid("Could not read %s: %v", path, err)
	}
	var set []api.SecretValue
	var names []string
	for i, line := range strings.Split(strings.ReplaceAll(string(body), "\r\n", "\n"), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimSpace(strings.TrimPrefix(line, "export "))
		name, raw, assigned := strings.Cut(line, "=")
		name = strings.TrimSpace(name)
		if !assigned || !namePattern.MatchString(name) {
			return nil, invalid("Line %d of %s is not NAME=value.", i+1, path)
		}
		value, ok := dotenvValue(strings.TrimSpace(raw))
		if !ok {
			return nil, invalid("Line %d of %s (%s) has a quote that is not closed, or text after the closing quote.", i+1, path, name)
		}
		set = append(set, api.SecretValue{Name: name, Value: value})
		names = append(names, name)
	}
	if len(set) == 0 {
		return nil, invalid("%s sets nothing.", path)
	}
	if len(set) > maxChanges {
		return nil, invalid("%s sets %d secrets, and one request takes at most %d. Split it up.", path, len(set), maxChanges)
	}
	return set, unique(names)
}

func dotenvValue(raw string) (string, bool) {
	switch {
	case strings.HasPrefix(raw, "'"):
		end := strings.Index(raw[1:], "'")
		if end < 0 {
			return "", false
		}
		return raw[1 : 1+end], afterQuote(raw[2+end:])
	case strings.HasPrefix(raw, `"`):
		var b strings.Builder
		for i := 1; i < len(raw); i++ {
			switch c := raw[i]; {
			case c == '"':
				return b.String(), afterQuote(raw[i+1:])
			case c == '\\' && i+1 < len(raw):
				i++
				switch raw[i] {
				case 'n':
					b.WriteByte('\n')
				case 'r':
					b.WriteByte('\r')
				case 't':
					b.WriteByte('\t')
				default:
					b.WriteByte(raw[i])
				}
			default:
				b.WriteByte(c)
			}
		}
		return "", false
	default:
		if at := strings.Index(raw, " #"); at >= 0 {
			raw = raw[:at]
		}
		return strings.TrimSpace(raw), true
	}
}

// Only a comment may follow a closing quote.
func afterQuote(rest string) bool {
	rest = strings.TrimSpace(rest)
	return rest == "" || strings.HasPrefix(rest, "#")
}
