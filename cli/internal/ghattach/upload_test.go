package ghattach

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"strings"
	"testing"

	"github.com/ntodd/foreman/cli/api"
)

// fakeAPI is Foreman's side of an upload: it keeps what it is sent and
// answers the way the control plane does.
type fakeAPI struct {
	chunkSize int64
	startErr  error
	appendErr error
	noURL     bool

	environment string
	started     []api.AttachmentStart
	offsets     []int64
	received    bytes.Buffer
}

func (f *fakeAPI) StartAttachment(_ context.Context, id string, body api.AttachmentStart) (*api.Response[api.AttachmentUpload], error) {
	f.environment = id
	f.started = append(f.started, body)
	if f.startErr != nil {
		return nil, f.startErr
	}
	return &api.Response[api.AttachmentUpload]{Value: api.AttachmentUpload{ID: "upload-1", ChunkSize: f.chunkSize}}, nil
}

func (f *fakeAPI) AppendAttachment(_ context.Context, id, attachment string, body api.AttachmentChunk) (*api.Response[api.AttachmentProgress], error) {
	if id != f.environment || attachment != "upload-1" {
		return nil, &api.HTTPError{StatusCode: 404, Code: "resource_not_found", Message: "Resource not found."}
	}
	if f.appendErr != nil {
		return nil, f.appendErr
	}
	data, err := base64.StdEncoding.DecodeString(body.Data)
	if err != nil {
		return nil, err
	}
	f.offsets = append(f.offsets, body.Offset)
	f.received.Write(data)
	progress := api.AttachmentProgress{Received: int64(f.received.Len())}
	if progress.Received == f.started[0].Size && !f.noURL {
		url := "https://github.com/user-attachments/assets/5b8ee541"
		progress.URL = &url
	}
	return &api.Response[api.AttachmentProgress]{Value: progress}, nil
}

func TestUploadSendsTheFileInTheServersChunks(t *testing.T) {
	data := []byte("0123456789")
	fake := &fakeAPI{chunkSize: 4}
	uploader := Uploader{API: fake, Environment: "env-1"}

	url, err := uploader.Upload(context.Background(), File{Name: "login.png", RepositoryID: 1001, Data: data})
	if err != nil {
		t.Fatal(err)
	}
	if url != "https://github.com/user-attachments/assets/5b8ee541" {
		t.Errorf("url = %q", url)
	}
	if fake.environment != "env-1" {
		t.Errorf("environment = %q", fake.environment)
	}
	start := fake.started[0]
	if start.Name != "login.png" || start.Size != 10 || start.RepositoryID == nil || *start.RepositoryID != 1001 {
		t.Errorf("start = %+v", start)
	}
	if got := fake.offsets; len(got) != 3 || got[0] != 0 || got[1] != 4 || got[2] != 8 {
		t.Errorf("offsets = %v", got)
	}
	if !bytes.Equal(fake.received.Bytes(), data) {
		t.Errorf("received %q", fake.received.Bytes())
	}
}

func TestUploadLeavesOutARepositoryItWasNotGiven(t *testing.T) {
	fake := &fakeAPI{chunkSize: 64}
	if _, err := (Uploader{API: fake, Environment: "env-1"}).Upload(context.Background(), File{Name: "a.png", Data: []byte("x")}); err != nil {
		t.Fatal(err)
	}
	if fake.started[0].RepositoryID != nil {
		t.Errorf("repository_id = %d, want none", *fake.started[0].RepositoryID)
	}
}

func TestUploadSaysWhenForemanCannotAttach(t *testing.T) {
	for name, remote := range map[string]*api.HTTPError{
		"no attachment token":             {StatusCode: 409, Code: "attachments_unavailable", Message: "Attachments aren't set up for acme."},
		"a control plane without the API": {StatusCode: 404, Code: "http_error", Message: "HTTP 404 Not Found"},
	} {
		t.Run(name, func(t *testing.T) {
			fake := &fakeAPI{chunkSize: 4, startErr: remote}
			_, err := (Uploader{API: fake, Environment: "env-1"}).Upload(context.Background(), File{Name: "a.png", Data: []byte("x")})
			var unavailable *Unavailable
			if !errors.As(err, &unavailable) {
				t.Fatalf("err = %v, want Unavailable", err)
			}
		})
	}
}

func TestUploadPassesOnWhatForemanRefused(t *testing.T) {
	refusal := &api.HTTPError{StatusCode: 422, Code: "invalid_request", Message: "Images must be at most 10 MB."}
	_, err := (Uploader{API: &fakeAPI{chunkSize: 4, startErr: refusal}, Environment: "env-1"}).Upload(context.Background(), File{Name: "a.png", Data: []byte("x")})
	var unavailable *Unavailable
	if err == nil || errors.As(err, &unavailable) {
		t.Fatalf("err = %v, want a refusal", err)
	}
	// What gh prints after "could not upload a.png: ".
	if got := Message(err); got != "Images must be at most 10 MB." {
		t.Errorf("message = %q", got)
	}

	failed := &api.HTTPError{StatusCode: 502, Code: "attachment_upload_failed", Message: "GitHub refused the upload."}
	_, err = (Uploader{API: &fakeAPI{chunkSize: 4, appendErr: failed}, Environment: "env-1"}).Upload(context.Background(), File{Name: "a.png", Data: []byte("x")})
	if got := Message(err); got != "GitHub refused the upload." {
		t.Errorf("message = %q", got)
	}
}

func TestUploadNeedsAnAssetURLAndAUsableChunkSize(t *testing.T) {
	_, err := (Uploader{API: &fakeAPI{chunkSize: 4, noURL: true}, Environment: "env-1"}).Upload(context.Background(), File{Name: "a.png", Data: []byte("x")})
	if err == nil || !strings.Contains(err.Error(), "no asset URL") {
		t.Errorf("err = %v", err)
	}
	_, err = (Uploader{API: &fakeAPI{chunkSize: 0}, Environment: "env-1"}).Upload(context.Background(), File{Name: "a.png", Data: []byte("x")})
	if err == nil {
		t.Error("a chunk size of zero was accepted")
	}
}
