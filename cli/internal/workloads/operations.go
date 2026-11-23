package workloads

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/ntodd/foreman/cli/api"
)

func sleep(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func waitFailure(ctx context.Context, err error, id string) *Failure {
	if ctx.Err() != nil {
		err = ctx.Err()
	}
	f := failure(err)
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		f = &Failure{Code: "wait_timeout", Message: "Timed out waiting for the operation."}
	}
	f.OperationID = id
	if f.Code == "interrupted" || f.Code == "wait_timeout" {
		f.Message += " Check its outcome with foreman op wait " + id + "."
	}
	return f
}

func outcome(op api.Operation) (done bool, err error) {
	switch op.Status {
	case "queued", "dispatched", "running":
		return false, nil
	case "succeeded":
		return true, nil
	case "cancelled", "failed":
		f := &Failure{Code: "operation_" + op.Status, Message: "Operation " + op.Status + ".", EnvironmentID: op.EnvironmentID, OperationID: op.ID}
		if op.Error != nil && op.Error.Code != "" {
			f.Code = op.Error.Code
		}
		if op.Error != nil && op.Error.Message != "" {
			f.Message = op.Error.Message
		}
		return true, f
	default:
		return false, &Failure{Code: "invalid_response", Message: fmt.Sprintf("Unrecognized operation status %q.", op.Status)}
	}
}

func (o Options) wait(ctx context.Context, id string) (*api.Operation, error) {
	for {
		r, err := o.API.GetOperation(ctx, id)
		if err != nil {
			return nil, waitFailure(ctx, err, id)
		}
		done, err := outcome(r.Value)
		if err != nil {
			return &r.Value, waitFailure(ctx, err, id)
		}
		if done {
			return &r.Value, nil
		}
		if err := sleep(ctx, o.PollInterval); err != nil {
			return nil, waitFailure(ctx, err, id)
		}
	}
}

func (o Options) logs(parent context.Context, v invocation) error {
	ctx, cancel := context.WithTimeout(parent, v.timeout)
	defer cancel()
	cursor := v.flags["cursor"]
	follow := v.flags["follow"] != ""
	var collected strings.Builder
	var truncated, terminal bool
	var terminalErr error
	fail := func(err error) error {
		f := waitFailure(ctx, err, v.arg)
		f.Cursor = cursor
		if f.Code == "wait_timeout" || f.Code == "interrupted" {
			f.Message = "Log reading stopped. Resume with foreman op logs and the last log cursor."
		}
		// A snapshot reader must receive the prefix before resuming at its end.
		if o.JSON && !follow && collected.Len() > 0 {
			page := api.LogPage{Text: collected.String(), NextCursor: cursor, Truncated: truncated}
			if writeErr := json.NewEncoder(o.Out).Encode(page); writeErr != nil {
				f.Cursor = v.flags["cursor"]
				f.Message += " Could not write the partial log: " + writeErr.Error()
			}
		}
		return f
	}
	for {
		r, err := o.API.GetOperationLogs(ctx, v.arg, cursor)
		if err != nil {
			return fail(err)
		}
		page := r.Value
		if page.NextCursor == "" || (page.NextCursor == cursor && page.Text != "") {
			return fail(&Failure{Code: "invalid_response", Message: "The log page has no usable continuation cursor."})
		}
		if page.Truncated {
			truncated = true
			if !o.JSON {
				fmt.Fprintln(o.Err, "The operation log was truncated. Earlier output is unavailable.")
			}
		}
		switch {
		case o.JSON && follow:
			err = json.NewEncoder(o.Out).Encode(page)
		case o.JSON:
			_, err = collected.WriteString(page.Text)
		default:
			_, err = io.WriteString(o.Out, page.Text)
		}
		if err != nil {
			return fail(err)
		}
		if follow && !o.JSON && page.NextCursor != cursor {
			fmt.Fprintln(o.Err, "Log cursor:", page.NextCursor)
		}
		advanced := page.NextCursor != cursor
		cursor = page.NextCursor
		// An empty page can advance past discarded bytes. Drain until an empty
		// read leaves the cursor unchanged, including after a terminal status.
		if page.Text != "" || (advanced && (!follow || terminal)) {
			continue
		}
		if !follow {
			if o.JSON {
				return json.NewEncoder(o.Out).Encode(api.LogPage{Text: collected.String(), NextCursor: cursor, Truncated: truncated})
			}
			fmt.Fprintln(o.Err, "Log cursor:", cursor)
			return nil
		}
		if terminal {
			if terminalErr != nil {
				return fail(terminalErr)
			}
			return nil
		}
		state, err := o.API.GetOperation(ctx, v.arg)
		if err != nil {
			return fail(err)
		}
		terminal, terminalErr = outcome(state.Value)
		// A writer can flush after the empty read and before this status check.
		if terminal {
			continue
		}
		if terminalErr != nil {
			return fail(terminalErr)
		}
		if err := sleep(ctx, o.PollInterval); err != nil {
			return fail(err)
		}
	}
}
