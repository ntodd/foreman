package session

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ntodd/foreman/cli/api"
)

type rotation struct {
	Previous string     `json:"previous"`
	Next     credential `json:"next"`
}

func accountCommand(instance, account, command string) string {
	quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'" }
	return "foreman --instance " + quote(instance) + " --account " + quote(account) + " " + command
}

func rotationUncertain(instance, account string, cause error) error {
	return fmt.Errorf("cannot safely retry this refresh; run login again using %s. If the previous connection remains active, revoke it under Connected apps: %w", accountCommand(instance, account, "login"), cause)
}

func removeRotation(path string) error {
	err := os.Remove(path + ".rotation")
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// Caller holds the Python-compatible account lock. Both the intent and the
// successor must survive a restart without allowing the predecessor to be spent twice.
func (s *Store) rotate(ctx context.Context, public *api.Client, instance, path string, old credential) (credential, error) {
	pending := old
	pending.RefreshPending = true
	// The checkout CLI doesn't know refresh_pending. Its only automatic
	// refresh trigger is expires. Disable that trigger in the transitional
	// file while retaining the real token for explicit logout/replacement.
	pending.Expires = 253402300799 // 9999-12-31T23:59:59Z
	if err := s.save(path, pending); err != nil {
		var replaced *ReplacedError
		if errors.As(err, &replaced) {
			// The server has not seen the token. Restore ordinary operation if
			// the intent rename succeeded but the directory sync failed.
			return credential{}, errors.Join(err, s.save(path, old))
		}
		return credential{}, err
	}
	if err := ctx.Err(); err != nil {
		return credential{}, errors.Join(err, s.save(path, old))
	}

	reply, err := public.ObtainToken(ctx, api.RefreshTokenGrant{GrantType: "refresh_token", ClientID: ClientID, RefreshToken: old.RefreshToken})
	if err != nil {
		if errors.Is(err, api.ErrRefreshTokenNotSent) {
			return credential{}, errors.Join(err, s.save(path, old))
		}
		return credential{}, rotationUncertain(instance, old.Account, err)
	}
	next, err := s.credentials(reply.Value, old.Account)
	if err != nil {
		return credential{}, rotationUncertain(instance, old.Account, err)
	}

	// Keep a private, durable second copy until publishing AND syncing the
	// Python credential file succeed. Its predecessor binds it to this grant.
	staged := rotation{Previous: hash(old.RefreshToken), Next: next}
	stageErr := s.save(path+".rotation", staged)
	if stageErr != nil {
		// The primary write may still succeed. A reader must confirm its
		// directory sync even if the recovery file was never created.
		next.VerifyRotation = true
	}
	if err := s.save(path, next); err != nil {
		var replaced *ReplacedError
		if stageErr != nil && !errors.As(stageErr, &replaced) && !errors.As(err, &replaced) {
			// Neither write installed the received successor. Revoke it while
			// it is still available, even if a signal interrupted this command.
			cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 20*time.Second)
			defer cancel()
			saveErr := errors.Join(stageErr, err)
			if revokeErr := revoke(cleanup, public, next.RefreshToken); revokeErr != nil {
				return credential{}, rotationUncertain(instance, old.Account, errors.Join(saveErr, revokeErr))
			}
			return credential{}, fmt.Errorf("could not save the rotated credentials and revoked the unsaved connection; reconnect using %s: %w", accountCommand(instance, old.Account, "login"), saveErr)
		}
		return credential{}, fmt.Errorf("rotated credentials await local recovery; retry with %s: %w", accountCommand(instance, old.Account, "me"), err)
	}
	return next, removeRotation(path)
}

// Called under the account lock. A checkout logout or a new login may have
// replaced the primary file since a failed publication. The primary wins
// unless it contains the exact predecessor that initiated this rotation.
func (s *Store) recoverRotation(path string, state credential) (credential, error) {
	var staged rotation
	err := readState(path+".rotation", &staged)
	exists := err == nil
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return state, err
	}
	if exists && state.RefreshPending && staged.Previous == hash(state.RefreshToken) {
		next := staged.Next
		if next.Account != state.Account || next.AccessToken == "" || next.RefreshToken == "" || next.RefreshPending {
			return state, errors.New("invalid staged refresh credentials")
		}
		if err := s.save(path, next); err != nil {
			return state, err
		}
		state = next
	} else if exists || state.VerifyRotation {
		// This includes rename succeeding before the publishing process died
		// or failed its directory sync. Keep the backup until confirmed.
		if err := s.syncDir(filepath.Dir(path)); err != nil {
			return state, err
		}
		if state.VerifyRotation {
			state.VerifyRotation = false
			if err := s.save(path, state); err != nil {
				return state, err
			}
		}
	}
	if exists {
		return state, removeRotation(path)
	}
	return state, nil
}
