// Package workloads implements authenticated Foreman environment and operation commands.
package workloads

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"
	"time"

	"github.com/ntodd/foreman/cli/api"
	"github.com/ntodd/foreman/cli/internal/render"
)

// API is the subset of the generated v1 client used by workload commands.
type API interface {
	ListRepos(context.Context, string) (*api.Response[api.RepositoryPage], error)
	ListBoxes(context.Context, string) (*api.Response[api.BoxPage], error)
	ListEnvironments(context.Context, string) (*api.Response[api.EnvironmentPage], error)
	GetEnvironment(context.Context, string) (*api.Response[api.Environment], error)
	ListEnvironmentOperations(context.Context, string, string) (*api.Response[api.OperationPage], error)
	GetOperation(context.Context, string) (*api.Response[api.Operation], error)
	GetOperationLogs(context.Context, string, string) (*api.Response[api.LogPage], error)
	CreateEnvironment(context.Context, string, api.Create) (*api.Response[api.Accepted], error)
	OperateEnvironment(context.Context, string, string, api.Action) (*api.Response[api.OperateEnvironmentResult], error)
}

var _ API = (*api.Client)(nil)

type Options struct {
	API API
	// StateDir is the private Foreman state root. Account is the acting user ID.
	StateDir, Instance, Account, ClientID string
	In                                    io.Reader
	Out, Err                              io.Writer
	JSON, Interactive                     bool
	// Pretty lays lists out for a person: standard output is a terminal and
	// --json is off. Anything else gets the tab-separated lines scripts read.
	Pretty, Colour bool
	Now            func() time.Time // Defaults to time.Now.
	Scopes         []string         // A nil grant leaves authorization to the server, including readiness reads.
	PollInterval   time.Duration
	// Environment is the ID of the environment the command runs inside, on
	// that environment's own connection. A command that takes an
	// environment and is given none means this one. Never destroy.
	Environment string
}

// Failure is the final stderr document in JSON mode. Accepted IDs and the last
// delivered log cursor let callers recover without repeating a mutation.
type Failure struct {
	Code          string `json:"code"`
	Message       string `json:"message"`
	HTTPStatus    int    `json:"http_status,omitempty"`
	RemoteCode    string `json:"remote_code,omitempty"`
	EnvironmentID string `json:"environment_id,omitempty"`
	OperationID   string `json:"operation_id,omitempty"`
	RequestKey    string `json:"request_key,omitempty"`
	Cursor        string `json:"cursor,omitempty"`
}

func (f *Failure) Error() string { return f.Code + ": " + f.Message }

func failure(err error) *Failure {
	var f *Failure
	if errors.As(err, &f) {
		copy := *f
		return &copy
	}
	var remote *api.HTTPError
	switch {
	case errors.As(err, &remote):
		code := remote.Code
		if code == "" {
			code = "http_error"
		}
		message := remote.Message
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

// Run accepts arguments starting with the resource name. It writes both the
// result and diagnostics. The dispatcher need only translate its error to an exit status.
func Run(ctx context.Context, args []string, o Options) error {
	localArgs := make([]string, 0, len(args))
	endFlags := false
	for _, arg := range args {
		if arg == "--" {
			endFlags = true
		}
		if !endFlags && arg == "--json" {
			o.JSON = true
			continue
		}
		localArgs = append(localArgs, arg)
	}
	if o.PollInterval <= 0 {
		o.PollInterval = time.Second
	}
	v, err := parse(localArgs, o.Environment)
	if err == nil {
		err = o.dispatch(ctx, v)
	}
	if err != nil {
		f := failure(err)
		if o.JSON {
			_ = json.NewEncoder(o.Err).Encode(f)
		} else {
			fmt.Fprintln(o.Err, f.Error())
			if o.Environment != "" && (f.HTTPStatus == 403 || f.Code == "forbidden") {
				fmt.Fprintln(o.Err, insideOnly)
			}
			if f.EnvironmentID != "" {
				fmt.Fprintln(o.Err, "Environment:", f.EnvironmentID)
			}
			if f.OperationID != "" {
				fmt.Fprintln(o.Err, "Operation:", f.OperationID)
			}
			if f.RequestKey != "" {
				fmt.Fprintln(o.Err, "Request key:", f.RequestKey)
			}
			if f.Cursor != "" {
				fmt.Fprintln(o.Err, "Log cursor:", f.Cursor)
			}
		}
		return f
	}
	return nil
}

// An environment's own connection reaches that environment alone.
const insideOnly = "Inside an environment, foreman reaches that environment alone.\nTo act as yourself: foreman --instance URL login"

func (o Options) dispatch(ctx context.Context, v invocation) error {
	// Refused here rather than by the control plane: a create first saves
	// its request, and there is nowhere in an environment it belongs.
	if o.Environment != "" && v.command == "env create" {
		return &Failure{Code: "forbidden", Message: "An environment's own connection can't create environments."}
	}
	if takesEnvironment(v.command) && !uuidPattern.MatchString(v.arg) {
		id, err := resolve(ctx, "environment", v.arg, o.environments, func(e api.Environment) (string, string) { return e.Slug, e.ID })
		if err != nil {
			return err
		}
		v.name, v.arg = v.arg, id
	}
	switch v.command {
	case "repo list":
		rows, err := collect(ctx, o.repos)
		if err != nil {
			return err
		}
		return list(o, rows, view[api.Repository]{
			tabs: "ID\tREPOSITORY\tDEFAULT BRANCH", line: func(r api.Repository) string { return r.ID + "\t" + r.FullName + "\t" + r.DefaultBranch },
			header: []string{"REPOSITORY", "DEFAULT BRANCH", "ID"}, empty: "No repositories.",
			row: func(r api.Repository) []render.Cell {
				return []render.Cell{{Text: r.FullName}, {Text: r.DefaultBranch}, {Text: r.ID, Tone: render.Dim}}
			},
		})
	case "box list":
		rows, err := collect(ctx, o.boxes)
		if err != nil {
			return err
		}
		return list(o, rows, view[api.Box]{
			tabs: "ID\tBOX\tONLINE", line: func(b api.Box) string { return fmt.Sprintf("%s\t%s\t%t", b.ID, b.Name, b.Online) },
			header: []string{"BOX", "STATUS", "ID"}, empty: "No boxes.",
			row: func(b api.Box) []render.Cell {
				online := render.Cell{Text: "offline", Tone: render.Bad}
				if b.Online {
					online = render.Cell{Text: "online", Tone: render.Good}
				}
				return []render.Cell{{Text: b.Name}, online, {Text: b.ID, Tone: render.Dim}}
			},
		})
	case "env list":
		rows, err := collect(ctx, o.environments)
		if err != nil {
			return err
		}
		return o.listEnvironments(ctx, rows)
	case "op list":
		rows, err := collect(ctx, func(ctx context.Context, cursor string) ([]api.Operation, *string, error) {
			r, err := o.API.ListEnvironmentOperations(ctx, v.arg, cursor)
			if err != nil {
				return nil, nil, err
			}
			return r.Value.Items, r.Value.NextCursor, nil
		})
		if err != nil {
			return err
		}
		return list(o, rows, view[api.Operation]{
			tabs: "ID\tENVIRONMENT ID\tACTION\tTRIGGER\tSTATUS",
			line: func(p api.Operation) string {
				return strings.Join([]string{p.ID, p.EnvironmentID, p.Action, p.Trigger, p.Status}, "\t")
			},
			header: []string{"ACTION", "STATUS", "TRIGGER", "ID"}, empty: "No operations.",
			row: func(p api.Operation) []render.Cell {
				tone := render.Plain
				switch p.Status {
				case "succeeded":
					tone = render.Good
				case "failed":
					tone = render.Bad
				case "cancelled":
					tone = render.Warn
				}
				return []render.Cell{{Text: p.Action}, {Text: p.Status, Tone: tone}, {Text: p.Trigger}, {Text: p.ID, Tone: render.Dim}}
			},
		})
	case "env show":
		r, err := o.API.GetEnvironment(ctx, v.arg)
		if err != nil {
			return err
		}
		return o.show(r.Value)
	case "op show":
		r, err := o.API.GetOperation(ctx, v.arg)
		if err != nil {
			return err
		}
		if err := o.show(r.Value); err != nil {
			return err
		}
		_, err = outcome(r.Value)
		return err
	case "env create", "env start", "env stop", "env restart", "env destroy":
		return o.lifecycle(ctx, v)
	case "op wait":
		ctx, cancel := context.WithTimeout(ctx, v.timeout)
		defer cancel()
		op, err := o.wait(ctx, v.arg)
		if err != nil {
			return err
		}
		return o.show(*op)
	case "op logs":
		return o.logs(ctx, v)
	}
	return invalid("Unknown command.")
}

func (o Options) repos(ctx context.Context, cursor string) ([]api.Repository, *string, error) {
	r, err := o.API.ListRepos(ctx, cursor)
	if err != nil {
		return nil, nil, err
	}
	return r.Value.Items, r.Value.NextCursor, nil
}
func (o Options) boxes(ctx context.Context, cursor string) ([]api.Box, *string, error) {
	r, err := o.API.ListBoxes(ctx, cursor)
	if err != nil {
		return nil, nil, err
	}
	return r.Value.Items, r.Value.NextCursor, nil
}

func (o Options) environments(ctx context.Context, cursor string) ([]api.Environment, *string, error) {
	r, err := o.API.ListEnvironments(ctx, cursor)
	if err != nil {
		return nil, nil, err
	}
	return r.Value.Items, r.Value.NextCursor, nil
}

// Names lists what a shell can complete: the names of the environments
// ("env"), repositories ("repo") or boxes ("box") the caller can see.
func Names(ctx context.Context, a API, kind string) ([]string, error) {
	o := Options{API: a}
	var found map[string]string
	var err error
	switch kind {
	case "env":
		found, err = named(ctx, o.environments, func(e api.Environment) (string, string) { return e.Slug, e.ID })
	case "repo":
		found, err = named(ctx, o.repos, func(r api.Repository) (string, string) { return r.FullName, r.ID })
	case "box":
		found, err = named(ctx, o.boxes, func(b api.Box) (string, string) { return b.Name, b.ID })
	}
	if err != nil {
		return nil, err
	}
	list := make([]string, 0, len(found))
	for _, name := range found {
		list = append(list, name)
	}
	slices.Sort(list)
	return list, nil
}

func collect[T any](ctx context.Context, page func(context.Context, string) ([]T, *string, error)) ([]T, error) {
	items := []T{}
	cursor := ""
	seen := map[string]bool{"": true}
	for {
		rows, next, err := page(ctx, cursor)
		if err != nil {
			return nil, err
		}
		items = append(items, rows...)
		if next == nil {
			return items, nil
		}
		cursor = *next
		if seen[cursor] {
			return nil, &Failure{Code: "invalid_response", Message: "The server repeated a collection cursor."}
		}
		seen[cursor] = true
	}
}

func resolve[T any](ctx context.Context, kind, name string, page func(context.Context, string) ([]T, *string, error), fields func(T) (string, string)) (string, error) {
	if uuidPattern.MatchString(name) {
		return strings.ToLower(name), nil
	}
	rows, err := collect(ctx, page)
	if err != nil {
		return "", err
	}
	var match string
	for _, row := range rows {
		n, id := fields(row)
		if n != name {
			continue
		}
		if match != "" && match != id {
			return "", &Failure{Code: "ambiguous_name", Message: fmt.Sprintf("Multiple visible %s entries match %q. Supply a UUID.", kind, name)}
		}
		match = id
	}
	if match == "" {
		return "", &Failure{Code: "resource_not_found", Message: fmt.Sprintf("No visible %s matches %q.", kind, name)}
	}
	return match, nil
}

// view is one list three ways: JSON, the tab-separated lines a script reads
// from a pipe (tabs and line, which stay as they are), and a table for a
// person at a terminal.
type view[T any] struct {
	tabs   string
	line   func(T) string
	header []string
	row    func(T) []render.Cell
	empty  string
}

func list[T any](o Options, items []T, v view[T]) error {
	switch {
	case o.JSON:
		return json.NewEncoder(o.Out).Encode(map[string]any{"items": items})
	case !o.Pretty:
		if _, err := fmt.Fprintln(o.Out, v.tabs); err != nil {
			return err
		}
		for _, item := range items {
			if _, err := fmt.Fprintln(o.Out, v.line(item)); err != nil {
				return err
			}
		}
		return nil
	case len(items) == 0:
		_, err := fmt.Fprintln(o.Out, v.empty)
		return err
	}
	rows := make([][]render.Cell, len(items))
	for i, item := range items {
		rows[i] = v.row(item)
	}
	return render.Table(o.Out, o.Colour, v.header, rows)
}

func (o Options) now() time.Time {
	if o.Now != nil {
		return o.Now()
	}
	return time.Now()
}

// names maps IDs to what people call them. The list is decoration, so a
// connection that may not read it gets the IDs instead of an error.
func names[T any](ctx context.Context, page func(context.Context, string) ([]T, *string, error), fields func(T) (string, string)) (map[string]string, error) {
	found, err := named(ctx, page, fields)
	if err != nil && ctx.Err() != nil {
		return nil, ctx.Err()
	}
	return found, nil
}

// named maps the IDs in a collection to their names.
func named[T any](ctx context.Context, page func(context.Context, string) ([]T, *string, error), fields func(T) (string, string)) (map[string]string, error) {
	rows, err := collect(ctx, page)
	if err != nil {
		return nil, err
	}
	found := make(map[string]string, len(rows))
	for _, row := range rows {
		name, id := fields(row)
		found[id] = name
	}
	return found, nil
}

func (o Options) listEnvironments(ctx context.Context, rows []api.Environment) error {
	v := view[api.Environment]{
		tabs: "ID\tENVIRONMENT\tBRANCH\tDESIRED\tOBSERVED\tREADINESS",
		line: func(e api.Environment) string {
			return strings.Join([]string{e.ID, e.Slug, e.Branch, e.DesiredState, e.ObservedState, e.Readiness}, "\t")
		},
		empty: "No environments.",
	}
	if o.JSON || !o.Pretty || len(rows) == 0 {
		return list(o, rows, v)
	}
	repos, err := names(ctx, o.repos, func(r api.Repository) (string, string) { return r.FullName, r.ID })
	if err != nil {
		return err
	}
	boxes, err := names(ctx, o.boxes, func(b api.Box) (string, string) { return b.Name, b.ID })
	if err != nil {
		return err
	}
	named := func(known map[string]string, id string) string {
		if name := known[id]; name != "" {
			return name
		}
		return id
	}
	// A server older than created_at has no ages, and an empty column says nothing.
	aged := slices.ContainsFunc(rows, func(e api.Environment) bool { return e.CreatedAt != nil })
	v.header = []string{"ENVIRONMENT", "STATUS", "REPOSITORY", "BRANCH", "BOX"}
	if aged {
		v.header = append(v.header, "AGE")
	}
	v.header = append(v.header, "ID")
	now := o.now()
	v.row = func(e api.Environment) []render.Cell {
		cells := []render.Cell{{Text: e.Slug}, status(e), {Text: named(repos, e.RepoID)}, {Text: e.Branch}, {Text: named(boxes, e.BoxID)}}
		if aged {
			age := ""
			if e.CreatedAt != nil {
				age = render.Age(now, *e.CreatedAt)
			}
			cells = append(cells, render.Cell{Text: age})
		}
		return append(cells, render.Cell{Text: e.ID, Tone: render.Dim})
	}
	return list(o, rows, v)
}

// status is the one thing to read about an environment: what its box last
// reported, and where it is headed when that differs from what was asked for.
func status(e api.Environment) render.Cell {
	settled := func(text string, tone render.Tone) render.Cell {
		if e.DesiredState != "" && e.DesiredState != e.ObservedState {
			return render.Cell{Text: e.ObservedState + " → " + e.DesiredState, Tone: render.Warn}
		}
		return render.Cell{Text: text, Tone: tone}
	}
	switch e.ObservedState {
	case "running":
		switch e.Readiness {
		case "ready":
			return settled("running", render.Good)
		case "not_ready":
			return settled("running (not ready)", render.Warn)
		default:
			return settled("running (unconfirmed)", render.Warn)
		}
	case "stopped", "suspended":
		return settled(e.ObservedState, render.Plain)
	case "partial":
		return render.Cell{Text: "partly running", Tone: render.Warn}
	case "pending":
		return render.Cell{Text: "queued"}
	case "error", "missing":
		return render.Cell{Text: e.ObservedState, Tone: render.Bad}
	default:
		return render.Cell{Text: e.ObservedState}
	}
}

func (o Options) show(value any) error {
	if o.JSON {
		return json.NewEncoder(o.Out).Encode(value)
	}
	switch v := value.(type) {
	case api.Environment:
		_, err := fmt.Fprintf(o.Out, "Environment: %s (%s)\nRepository: %s\nBranch: %s\nBox: %s\nDesired state: %s\nObserved state: %s\nReadiness: %s\n", v.ID, v.Slug, v.RepoID, v.Branch, v.BoxID, v.DesiredState, v.ObservedState, v.Readiness)
		if err != nil {
			return err
		}
		if v.Expiry != nil {
			if _, err := fmt.Fprintf(o.Out, "Expiry: %s at %s\n", v.Expiry.Action, v.Expiry.At); err != nil {
				return err
			}
		}
		for _, field := range []struct {
			name  string
			value *string
		}{{"Hostname", v.Hostname}, {"SSH user", v.SSHUser}, {"Workspace folder", v.WorkspaceFolder}} {
			if field.value != nil {
				if _, err := fmt.Fprintf(o.Out, "%s: %s\n", field.name, *field.value); err != nil {
					return err
				}
			}
		}
	case api.Operation:
		_, err := fmt.Fprintf(o.Out, "Operation: %s\nEnvironment: %s\nAction: %s\nTrigger: %s\nStatus: %s\n", v.ID, v.EnvironmentID, v.Action, v.Trigger, v.Status)
		if err != nil {
			return err
		}
		if v.Error != nil {
			_, err = fmt.Fprintf(o.Out, "Error: %s: %s\n", v.Error.Code, v.Error.Message)
			return err
		}
	}
	return nil
}

func (o Options) mayReadEnvironment() bool {
	return o.Scopes == nil || slices.Contains(o.Scopes, "environments:read")
}

func (o Options) confirm(ctx context.Context, prompt string) (bool, error) {
	if !o.Interactive || o.JSON || o.In == nil {
		return false, nil
	}
	if _, err := fmt.Fprintf(o.Err, "%s [y/N] ", prompt); err != nil {
		return false, err
	}
	// A terminal read can outlive SIGINT. Let the single-command process exit
	// without closing the caller's stdin or waiting for another newline.
	answer := make(chan bool, 1)
	go func() {
		line, err := bufio.NewReader(o.In).ReadString('\n')
		line = strings.TrimSpace(line)
		answer <- (err == nil || errors.Is(err, io.EOF)) &&
			(strings.EqualFold(line, "yes") || strings.EqualFold(line, "y"))
	}()
	select {
	case <-ctx.Done():
		return false, ctx.Err()
	case confirmed := <-answer:
		return confirmed, ctx.Err()
	}
}
