#!/bin/sh
# Publish two complete releases to a temporary loopback fixture. Install the
# first one, reject a corrupt upgrade, then upgrade using the packaged CLI.
set -eu
cd "$(dirname "$0")/../cli"
# Keep the Go compiler cache available when the test isolates the CLI's HOME.
GOCACHE=$(go env GOCACHE)
GOPATH=$(go env GOPATH)
export GOCACHE GOPATH FOREMAN_RELEASE_REHEARSAL=1
go test -count=1 -timeout 10m ./internal/selfupdate
