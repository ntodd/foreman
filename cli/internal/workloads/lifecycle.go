package workloads

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"time"

	"github.com/ntodd/foreman/cli/api"
)

type submission struct {
	EnvironmentID           string `json:"environment_id,omitempty"`
	OperationID             string `json:"operation_id,omitempty"`
	OperationHistoryExpired bool   `json:"operation_history_expired,omitempty"`
	AlreadyReached          bool   `json:"already_reached,omitempty"`
	// nothingToRestart words an already-reached restart for a person.
	nothingToRestart bool
	RequestKey       string           `json:"request_key,omitempty"`
	Operation        *api.Operation   `json:"operation,omitempty"`
	Environment      *api.Environment `json:"environment,omitempty"`
}

const capacityWarningCode = "capacity_confirmation_required"

func (o Options) lifecycle(ctx context.Context, v invocation) error {
	action := strings.TrimPrefix(v.command, "env ")
	var result submission
	var err error
	if action == "create" {
		result, err = o.create(ctx, v)
	} else {
		result, err = o.operate(ctx, v, action)
		result.nothingToRestart = action == "restart" && result.AlreadyReached
	}
	if err != nil {
		return err
	}
	if result.EnvironmentID == "" || (!result.AlreadyReached && result.OperationID == "") {
		err := mutationFailure(errors.New("Submission response omitted an expected ID."), action, result.RequestKey, v.arg)
		return attach(err, result)
	}
	readReadiness := (action == "create" || action == "start") && o.mayReadEnvironment()
	if v.flags["no-wait"] != "" || (result.AlreadyReached && !readReadiness) {
		if err := o.result(result); err != nil {
			return attach(err, result)
		}
		return nil
	}
	event := "accepted"
	message := fmt.Sprintf("Environment: %s\nOperation: %s", result.EnvironmentID, result.OperationID)
	if result.AlreadyReached {
		event = "already_reached"
		message = "Environment " + result.EnvironmentID + " is already in the requested state."
		if result.nothingToRestart {
			message = "No services in environment " + result.EnvironmentID + " are waiting on a restart."
		}
	}
	if err := o.progress(event, result, message); err != nil {
		return attach(err, result)
	}

	if !result.AlreadyReached && !result.OperationHistoryExpired {
		waitCtx, cancel := context.WithTimeout(ctx, v.timeout)
		result.Operation, err = o.wait(waitCtx, result.OperationID)
		cancel()
	}
	if err == nil && readReadiness {
		r, e := o.API.GetEnvironment(ctx, result.EnvironmentID)
		if e != nil {
			f := failure(e)
			f.Message = "Reading current environment readiness: " + f.Message + " Retry with foreman env show " + result.EnvironmentID + "."
			err = f
		} else {
			result.Environment = &r.Value
		}
	}
	// Even when the wait or readiness request failed, stdout can identify the
	// accepted server work. The separate diagnostic explains which step failed.
	if e := o.result(result); e != nil {
		return attach(e, result)
	}
	if err != nil {
		return attach(err, result)
	}
	return nil
}

func attach(err error, r submission) *Failure {
	f := failure(err)
	f.EnvironmentID = r.EnvironmentID
	f.OperationID = r.OperationID
	f.RequestKey = r.RequestKey
	return f
}

func (o Options) result(r submission) error {
	if o.JSON {
		return json.NewEncoder(o.Out).Encode(r)
	}
	if _, err := fmt.Fprintln(o.Out, "Environment:", r.EnvironmentID); err != nil {
		return err
	}
	if r.AlreadyReached {
		message := "The environment is already in the requested state."
		if r.nothingToRestart {
			message = "No services are waiting on a restart. Use --all to restart every service."
		}
		if _, err := fmt.Fprintln(o.Out, message); err != nil {
			return err
		}
	}
	if r.OperationHistoryExpired {
		if _, err := fmt.Fprintln(o.Out, "The original operation history has expired."); err != nil {
			return err
		}
	}
	if r.OperationID != "" {
		if _, err := fmt.Fprintln(o.Out, "Operation:", r.OperationID); err != nil {
			return err
		}
	}
	if r.Operation != nil {
		if _, err := fmt.Fprintln(o.Out, "Operation status:", r.Operation.Status); err != nil {
			return err
		}
	}
	if r.Environment != nil {
		_, err := fmt.Fprintln(o.Out, "Current readiness:", r.Environment.Readiness)
		return err
	}
	return nil
}

func (o Options) progress(event string, r submission, human string) error {
	if !o.JSON {
		_, err := fmt.Fprintln(o.Err, human)
		return err
	}
	return json.NewEncoder(o.Err).Encode(struct {
		Event string `json:"event"`
		submission
	}{event, r})
}

func (o Options) createBody(ctx context.Context, v invocation) (api.Create, error) {
	var b api.Create
	if at := v.flags["expires-at"]; at != "" {
		when, err := time.Parse(time.RFC3339Nano, at)
		if err != nil {
			return b, invalid("--expires-at must be an absolute RFC 3339 timestamp.")
		}
		action := v.flags["on-expiry"]
		if action != "stop" && action != "destroy" {
			return b, invalid("--on-expiry requires stop or destroy.")
		}
		b.Expiry = &api.Expiry{Action: action, At: when.UTC().Format(time.RFC3339Nano)}
	}
	id, err := resolve(ctx, "repository", v.arg, o.repos, func(r api.Repository) (string, string) { return r.FullName, r.ID })
	if err != nil {
		return b, err
	}
	b.RepoID = id
	if box := v.flags["box"]; box != "" {
		id, err := resolve(ctx, "box", box, o.boxes, func(b api.Box) (string, string) { return b.Name, b.ID })
		if err != nil {
			return b, err
		}
		b.BoxID = &id
	}
	if branch := v.flags["branch"]; branch != "" {
		b.Branch = &branch
	}
	if v.flags["confirm-capacity-warning"] != "" {
		b.ConfirmCapacityWarning = new(true)
	}
	return b, nil
}

func (o Options) create(ctx context.Context, v invocation) (submission, error) {
	key := v.flags["resume"]
	resume := key != ""
	if !resume {
		key = v.flags["request-key"]
		if key == "" {
			key = newKey()
		}
	}
	result := submission{RequestKey: key}
	j, err := o.openJournal(ctx, key)
	if err != nil {
		return result, err
	}
	defer j.lock.Close() // The lock ends at submission, before any operation wait.
	saved, err := j.load(o, key)
	if err != nil {
		return result, attach(err, result)
	}
	if resume && saved == nil {
		return result, attach(j.missingRecord(), result)
	}
	var body api.Create
	if resume {
		body = saved.Body
		if v.flags["confirm-capacity-warning"] != "" {
			body.ConfirmCapacityWarning = new(true)
		}
	} else {
		body, err = o.createBody(ctx, v)
		if err != nil {
			return result, err
		}
	}
	allRejected := saved == nil || correctableStatus(saved.Rejection) != 0
	if saved == nil {
		saved = &record{Key: key, Instance: o.Instance, Account: o.Account, ClientID: o.ClientID}
	} else if !reflect.DeepEqual(body, saved.Body) {
		canChange := allRejected && (!resume || saved.Rejection == capacityWarningCode)
		if !canChange {
			return result, attach(&Failure{Code: "idempotency_conflict", Message: "This key has different saved inputs. Use foreman env create --resume with the original key."}, result)
		}
	}
	saved.Body = body
	if err := o.submitSaved(ctx, j, saved, &result, allRejected); err != nil {
		return result, attach(err, result)
	}
	return result, nil
}

func (o Options) submitSaved(ctx context.Context, j *journal, r *record, result *submission, allRejected bool) error {
	for {
		// A crash from this point on must leave an exact-replay-only record.
		r.Rejection = ""
		if err := j.save(r); err != nil {
			return err
		}
		if err := o.progress("request_saved", *result, "Create request key: "+r.Key); err != nil {
			return err
		}
		reply, err := o.API.CreateEnvironment(ctx, r.Key, r.Body)
		if err == nil {
			result.EnvironmentID = reply.Value.EnvironmentID
			result.OperationID = reply.Value.OperationID
			result.OperationHistoryExpired = reply.Value.OperationHistoryExpired != nil && *reply.Value.OperationHistoryExpired
			return nil
		}
		var remote *api.HTTPError
		if errors.As(err, &remote) && remote.StatusCode >= 400 && remote.StatusCode == correctableStatus(remote.Code) {
			if !allRejected {
				f := failure(err)
				f.Code = "outcome_unknown"
				f.RemoteCode = remote.Code
				f.Message += " An earlier submission may have been accepted. Replay the saved inputs with foreman env create --resume KEY."
				return f
			}
			r.Rejection = remote.Code
			if e := j.save(r); e != nil {
				return e
			}
		}
		if r.Rejection == capacityWarningCode && r.Body.ConfirmCapacityWarning == nil {
			confirmed, confirmErr := o.confirm(ctx, failure(err).Message+" Continue despite this capacity warning?")
			if confirmErr != nil {
				return confirmErr
			}
			if confirmed {
				r.Body.ConfirmCapacityWarning = new(true)
				continue
			}
		}
		return mutationFailure(err, "create", r.Key, "")
	}
}

func (o Options) operate(ctx context.Context, v invocation, action string) (submission, error) {
	result := submission{EnvironmentID: v.arg}
	if action == "destroy" && v.flags["yes"] == "" {
		confirmed, err := o.confirm(ctx, "Destroy environment "+v.arg+" and remove its disk?")
		if err != nil {
			return result, attach(err, result)
		}
		if !confirmed {
			return result, &Failure{Code: "confirmation_required", Message: "Destroy requires confirmation. Use --yes to confirm destruction.", EnvironmentID: v.arg}
		}
	}
	body := api.Action{Action: action}
	if action == "restart" {
		// Only the services whose secrets changed, unless asked for all.
		body.Action = "restart_affected"
		if v.flags["all"] != "" {
			body.Action = "restart_all"
		}
	}
	if v.flags["confirm-capacity-warning"] != "" {
		body.ConfirmCapacityWarning = new(true)
	}
	key := newKey()
	for {
		r, err := o.API.OperateEnvironment(ctx, v.arg, key, body)
		if err == nil {
			if !strings.EqualFold(r.Value.EnvironmentID, v.arg) {
				return result, attach(mutationFailure(errors.New("Submission response did not identify the requested environment."), action, key, v.arg), result)
			}
			result.AlreadyReached = r.StatusCode == 200
			if r.Value.OperationID != nil {
				result.OperationID = *r.Value.OperationID
			}
			return result, nil
		}
		if action == "start" && body.ConfirmCapacityWarning == nil && isCapacityWarning(err) {
			confirmed, confirmErr := o.confirm(ctx, failure(err).Message+" Continue despite this capacity warning?")
			if confirmErr != nil {
				return result, attach(confirmErr, result)
			}
			if confirmed {
				body.ConfirmCapacityWarning = new(true)
				continue
			}
		}
		f := mutationFailure(err, action, key, v.arg)
		f.EnvironmentID = v.arg
		return result, f
	}
}

func mutationFailure(err error, action, key, id string) *Failure {
	var remote *api.HTTPError
	if errors.As(err, &remote) && remote.StatusCode >= 400 && remote.StatusCode < 500 && remote.StatusCode != 408 {
		f := failure(err)
		switch f.Code {
		case "original_environment_gone":
			f.Message = "The original environment was destroyed."
		case capacityWarningCode:
			f.Message += " Use --confirm-capacity-warning to acknowledge this warning."
		}
		return f
	}
	f := failure(err)
	f.Code = "outcome_unknown"
	if remote != nil {
		f.RemoteCode = remote.Code
	}
	if action == "create" {
		f.RequestKey = key
		f.Message += " The submission outcome is uncertain. Use foreman env create --resume KEY with the saved request key."
	} else {
		f.Message += fmt.Sprintf(" The %s outcome is uncertain. Run foreman env show %s and foreman op list %s before deciding whether to resubmit.", action, id, id)
	}
	return f
}

// Foreman reserves no receipt for these validation and admission failures.
// Authorization and visibility errors can also occur on an existing receipt.
func correctableStatus(code string) int {
	switch code {
	case "invalid_request":
		return 422
	case capacityWarningCode, "capacity_exceeded", "no_provisionable_boxes", "box_vm_unavailable", "box_offline":
		return 409
	default:
		return 0
	}
}

func isCapacityWarning(err error) bool {
	var remote *api.HTTPError
	return errors.As(err, &remote) && remote.StatusCode == 409 && remote.Code == capacityWarningCode
}
