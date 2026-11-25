// Package ghattach makes gh's --attach work inside a Foreman environment.
//
// gh uploads an attached file to uploads.github.com with the token it was
// given, and GitHub rejects the GitHub App tokens an environment gets
// (cli/cli#14309). Foreman's control plane has a token GitHub does
// accept, and uploads a file for the environment that sends it one.
//
// So gh runs behind a proxy on loopback that answers for the upload host
// itself and passes every other connection through untouched. gh does
// what it always does with the flag: its own checks, its own rewriting of
// the markdown. Only the upload goes somewhere else.
package ghattach

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"

	"github.com/ntodd/foreman/cli/api"
)

// API is the subset of the generated v1 client an upload uses.
type API interface {
	StartAttachment(context.Context, string, api.AttachmentStart) (*api.Response[api.AttachmentUpload], error)
	AppendAttachment(context.Context, string, string, api.AttachmentChunk) (*api.Response[api.AttachmentProgress], error)
}

var _ API = (*api.Client)(nil)

// File is one attachment as gh sends it.
type File struct {
	Name string
	// RepositoryID is the repository's ID on GitHub, or zero for the
	// environment's own.
	RepositoryID int64
	Data         []byte
}

// Unavailable means Foreman can't attach files for this environment at
// all: its owner has no attachment token, or the control plane is older
// than the feature. gh's own upload is then the one to try.
type Unavailable struct{ Reason string }

func (e *Unavailable) Error() string { return e.Reason }

// Uploader sends files to Foreman, which uploads them to GitHub.
type Uploader struct {
	API         API
	Environment string
}

// Upload sends one file in the chunks the control plane asks for and
// returns the URL of the asset GitHub made of it.
func (u Uploader) Upload(ctx context.Context, file File) (string, error) {
	start := api.AttachmentStart{Name: file.Name, Size: int64(len(file.Data))}
	if file.RepositoryID > 0 {
		start.RepositoryID = &file.RepositoryID
	}
	opened, err := u.API.StartAttachment(ctx, u.Environment, start)
	if err != nil {
		return "", unavailable(err)
	}
	size := opened.Value.ChunkSize
	if size <= 0 {
		return "", errors.New("Foreman didn't return a chunk size for the upload")
	}
	for offset := int64(0); offset < int64(len(file.Data)); offset += size {
		end := min(offset+size, int64(len(file.Data)))
		chunk := api.AttachmentChunk{Offset: offset, Data: base64.StdEncoding.EncodeToString(file.Data[offset:end])}
		progress, err := u.API.AppendAttachment(ctx, u.Environment, opened.Value.ID, chunk)
		if err != nil {
			return "", err
		}
		if url := progress.Value.URL; url != nil && *url != "" {
			return *url, nil
		}
	}
	return "", errors.New("Foreman returned no asset URL for the upload")
}

// unavailable picks out the answers that mean Foreman can't attach here.
// The relay answers an unknown route with a plain 404, which a control
// plane from before attachments gives for this one.
func unavailable(err error) error {
	var remote *api.HTTPError
	if !errors.As(err, &remote) {
		return err
	}
	if remote.Code == "attachments_unavailable" {
		return &Unavailable{Reason: remote.Message}
	}
	if remote.StatusCode == http.StatusNotFound && remote.Code != "resource_not_found" {
		return &Unavailable{Reason: "This Foreman can't attach files yet. It needs a newer control plane."}
	}
	return err
}

// Message is what to tell the person whose upload failed: the control
// plane's own words when it refused, without the code a script reads.
func Message(err error) string {
	var remote *api.HTTPError
	if errors.As(err, &remote) && remote.Message != "" {
		return remote.Message
	}
	return fmt.Sprint(err)
}
