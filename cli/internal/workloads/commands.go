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
	Scopes                                []string // A nil grant leaves authorization to the server, including readiness reads.
	PollInterval                          time.Duration
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
	v, err := parse(localArgs)
	if err == nil {
		err = o.dispatch(ctx, v)
	}
	if err != nil {
		f := failure(err)
		if o.JSON {
			_ = json.NewEncoder(o.Err).Encode(f)
		} else {
			fmt.Fprintln(o.Err, f.Error())
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

func (o Options) dispatch(ctx context.Context, v invocation) error {
	switch v.command {
	case "repo list":
		rows, err := collect(ctx, o.repos)
		if err != nil {
			return err
		}
		return printList(o, rows, "ID\tREPOSITORY\tDEFAULT BRANCH", func(r api.Repository) string { return r.ID + "\t" + r.FullName + "\t" + r.DefaultBranch })
	case "box list":
		rows, err := collect(ctx, o.boxes)
		if err != nil {
			return err
		}
		return printList(o, rows, "ID\tBOX\tONLINE", func(b api.Box) string { return fmt.Sprintf("%s\t%s\t%t", b.ID, b.Name, b.Online) })
	case "env list":
		rows, err := collect(ctx, func(ctx context.Context, cursor string) ([]api.Environment, *string, error) {
			r, err := o.API.ListEnvironments(ctx, cursor)
			if err != nil {
				return nil, nil, err
			}
			return r.Value.Items, r.Value.NextCursor, nil
		})
		if err != nil {
			return err
		}
		return printList(o, rows, "ID\tENVIRONMENT\tBRANCH\tDESIRED\tOBSERVED\tREADINESS", func(e api.Environment) string {
			return strings.Join([]string{e.ID, e.Slug, e.Branch, e.DesiredState, e.ObservedState, e.Readiness}, "\t")
		})
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
		return printList(o, rows, "ID\tENVIRONMENT ID\tACTION\tTRIGGER\tSTATUS", func(p api.Operation) string {
			return strings.Join([]string{p.ID, p.EnvironmentID, p.Action, p.Trigger, p.Status}, "\t")
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
	case "env create", "env start", "env stop", "env destroy":
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

func printList[T any](o Options, items []T, header string, row func(T) string) error {
	if o.JSON {
		return json.NewEncoder(o.Out).Encode(map[string]any{"items": items})
	}
	if _, err := fmt.Fprintln(o.Out, header); err != nil {
		return err
	}
	for _, item := range items {
		if _, err := fmt.Fprintln(o.Out, row(item)); err != nil {
			return err
		}
	}
	return nil
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
