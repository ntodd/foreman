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
			f := waitFailure(ctx, err, id)
			if f.Code == "insufficient_scope" {
				f.Message = "Reading operation status requires operations:read. " + f.Message + " Resume with foreman op wait " + id + " after obtaining that permission."
			}
			return nil, f
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

// Foreman serves a rolling 1 MiB tail in pages of up to 64 KiB. Bound both
// bytes and requests, even when a producer appends between every HTTP read.
const (
	maxSnapshotBytes = 1 << 20
	maxSnapshotPages = 16
)

func (o Options) logs(parent context.Context, v invocation) error {
	ctx, cancel := context.WithTimeout(parent, v.timeout)
	defer cancel()
	if v.flags["follow"] != "" {
		return o.followLogs(ctx, v.arg, v.flags["cursor"])
	}
	return o.snapshotLogs(ctx, v.arg, v.flags["cursor"])
}

func (o Options) logPage(ctx context.Context, id, cursor string) (api.LogPage, error) {
	r, err := o.API.GetOperationLogs(ctx, id, cursor)
	if err != nil {
		return api.LogPage{}, err
	}
	page := r.Value
	if page.NextCursor == "" || (page.NextCursor == cursor && page.Text != "") {
		return api.LogPage{}, &Failure{Code: "invalid_response", Message: "The log page has no usable continuation cursor."}
	}
	return page, nil
}

func logReadFailure(ctx context.Context, err error, id, cursor string) *Failure {
	f := waitFailure(ctx, err, id)
	f.Cursor = cursor
	if f.Code == "wait_timeout" || f.Code == "interrupted" {
		f.Message = "Log reading stopped. Resume with foreman op logs and the last log cursor."
	}
	return f
}

func (o Options) printLogText(page api.LogPage) error {
	if page.Truncated {
		if _, err := fmt.Fprintln(o.Err, "The operation log was truncated. Earlier output is unavailable."); err != nil {
			return err
		}
	}
	_, err := io.WriteString(o.Out, page.Text)
	return err
}

func (o Options) snapshotLogs(ctx context.Context, id, start string) error {
	var text strings.Builder
	var truncated, limited bool
	var pagesRead, bytesRead int
	var readErr error
	cursor := start
	for {
		page, err := o.logPage(ctx, id, cursor)
		if err != nil {
			readErr = logReadFailure(ctx, err, id, cursor)
			break
		}
		if len(page.Text) > maxSnapshotBytes-bytesRead {
			// A cursor identifies a whole page. Leave it for the next read.
			if pagesRead == 0 {
				return logReadFailure(ctx, &Failure{Code: "invalid_response", Message: "A log page exceeds the maximum single read size."}, id, cursor)
			}
			limited = true
			break
		}
		if o.JSON {
			text.WriteString(page.Text)
		} else if err := o.printLogText(page); err != nil {
			return logReadFailure(ctx, err, id, cursor)
		}
		pagesRead++
		bytesRead += len(page.Text)
		truncated = truncated || page.Truncated
		previous := cursor
		cursor = page.NextCursor
		if page.Text == "" && cursor == previous {
			break
		}
		if pagesRead == maxSnapshotPages || bytesRead == maxSnapshotBytes {
			limited = true
			break
		}
	}
	// Deliver the prefix even if the next GET failed. An empty page may
	// already have advanced the cursor past discarded bytes.
	if o.JSON && pagesRead > 0 {
		result := api.LogPage{Text: text.String(), NextCursor: cursor, Truncated: truncated}
		if err := json.NewEncoder(o.Out).Encode(result); err != nil {
			f := failure(err)
			if readErr != nil {
				f = failure(readErr)
				f.Message += " Could not write the partial log: " + err.Error()
			}
			f.OperationID = id
			f.Cursor = start
			return f
		}
	}
	if readErr != nil || o.JSON {
		return readErr
	}
	if limited {
		if _, err := fmt.Fprintln(o.Err, "Read limit reached. Continue with --cursor."); err != nil {
			return err
		}
	}
	_, err := fmt.Fprintln(o.Err, "Log cursor:", cursor)
	return err
}

func (o Options) followLogs(ctx context.Context, id, cursor string) error {
	var terminal bool
	var terminalErr error
	for {
		page, err := o.logPage(ctx, id, cursor)
		if err != nil {
			return logReadFailure(ctx, err, id, cursor)
		}
		if o.JSON {
			err = json.NewEncoder(o.Out).Encode(page)
		} else {
			err = o.printLogText(page)
		}
		if err != nil {
			return logReadFailure(ctx, err, id, cursor)
		}
		advanced := page.NextCursor != cursor
		cursor = page.NextCursor
		if !o.JSON && advanced {
			if _, err := fmt.Fprintln(o.Err, "Log cursor:", cursor); err != nil {
				return logReadFailure(ctx, err, id, cursor)
			}
		}
		// A writer can flush between the last empty read and the terminal
		// status check. Drain again, even if an empty page advanced the cursor.
		if page.Text != "" || (advanced && terminal) {
			continue
		}
		if terminal {
			if terminalErr != nil {
				return logReadFailure(ctx, terminalErr, id, cursor)
			}
			return nil
		}
		state, err := o.API.GetOperation(ctx, id)
		if err != nil {
			return logReadFailure(ctx, err, id, cursor)
		}
		terminal, terminalErr = outcome(state.Value)
		if terminal {
			continue
		}
		if terminalErr != nil {
			return logReadFailure(ctx, terminalErr, id, cursor)
		}
		if err := sleep(ctx, o.PollInterval); err != nil {
			return logReadFailure(ctx, err, id, cursor)
		}
	}
}
