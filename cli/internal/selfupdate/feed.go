// Package selfupdate installs official stable Foreman CLI releases.
package selfupdate

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

var stableTag = regexp.MustCompile(`^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)
var nextLink = regexp.MustCompile(`<([^>]+)>;\s*rel="next"`)

// Validated numeric fields have no leading zeros. Comparing length first
// handles all SemVer components without a machine-integer limit.
func newer(a, b string) bool {
	if a == "" || a == b {
		return false
	}
	if b == "" {
		return true
	}
	left := strings.Split(a[1:], ".")
	right := strings.Split(b[1:], ".")
	for i, part := range left {
		if len(part) != len(right[i]) {
			return len(part) > len(right[i])
		}
		if part != right[i] {
			return part > right[i]
		}
	}
	return false
}

type release struct {
	Tag        string `json:"tag_name"`
	Draft      bool   `json:"draft"`
	Prerelease bool   `json:"prerelease"`
	Published  string `json:"published_at"`
	Assets     []struct {
		Name  string `json:"name"`
		State string `json:"state"`
	} `json:"assets"`
}

func archiveName(tag, target string) string { return "foreman-cli-" + tag + "-" + target + ".tar.gz" }
func manifestName(tag string) string        { return "foreman-cli-" + tag + "-SHA256SUMS" }

func (r release) complete() bool {
	if r.Draft || r.Prerelease || r.Published == "" || !stableTag.MatchString(r.Tag) {
		return false
	}
	available := make(map[string]bool)
	for _, a := range r.Assets {
		available[a.Name] = a.State == "uploaded"
	}
	for _, target := range []string{"linux-amd64", "linux-arm64", "darwin-amd64", "darwin-arm64"} {
		if !available[archiveName(r.Tag, target)] {
			return false
		}
	}
	return available[manifestName(r.Tag)]
}

type page struct {
	ETag   string
	Newest string
	Next   string
}

func (u updater) get(ctx context.Context, address, etag string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	if etag != "" {
		req.Header.Set("If-None-Match", etag)
	}
	return u.client.Do(req)
}

func bounded(r io.Reader, limit int64) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(r, limit+1))
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("release data exceeds %d bytes", limit)
	}
	return data, err
}

func (u updater) readPage(ctx context.Context, address string, previous page) (page, error) {
	res, err := u.get(ctx, address, previous.ETag)
	if err != nil {
		return page{}, err
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusNotModified && previous.ETag != "" {
		// A formerly final page can acquire a next link without changing
		// its release rows. A 304 may omit unchanged response metadata.
		if res.Header.Get("Link") != "" {
			previous.Next = nextPage(res.Header)
		}
		return previous, nil
	}
	if res.StatusCode != http.StatusOK {
		return page{}, fmt.Errorf("list CLI releases: HTTP %s", res.Status)
	}
	body, err := bounded(res.Body, 32<<20)
	if err != nil {
		return page{}, err
	}
	var rows []release
	if err := json.Unmarshal(body, &rows); err != nil {
		return page{}, err
	}
	p := page{ETag: res.Header.Get("ETag"), Next: nextPage(res.Header)}
	for _, row := range rows {
		if row.complete() && newer(row.Tag, p.Newest) {
			p.Newest = row.Tag
		}
	}
	return p, nil
}

func nextPage(header http.Header) string {
	if match := nextLink.FindStringSubmatch(header.Get("Link")); match != nil {
		return match[1]
	}
	return ""
}

func (u updater) latest(ctx context.Context, cached map[string]page) (string, map[string]page, error) {
	feed, err := url.Parse(u.feed)
	if err != nil {
		return "", nil, err
	}
	seen := make(map[string]page)
	var newest string
	for address := u.feed; address != ""; {
		next, err := url.Parse(address)
		if err != nil || next.User != nil || next.Scheme != feed.Scheme || next.Host != feed.Host {
			return "", nil, fmt.Errorf("invalid releases pagination link")
		}
		// GitHub may use a numeric repository ID in its Link header. Keep
		// using the official feed path and take only the new query string.
		feed.RawQuery = next.RawQuery
		address = feed.String()
		if _, ok := seen[address]; ok {
			return "", nil, fmt.Errorf("repeated releases pagination link")
		}
		p, err := u.readPage(ctx, address, cached[address])
		if err != nil {
			return "", nil, err
		}
		seen[address] = p
		if p.Newest != "" && !stableTag.MatchString(p.Newest) {
			return "", nil, fmt.Errorf("invalid cached release tag")
		}
		if newer(p.Newest, newest) {
			newest = p.Newest
		}
		address = p.Next
	}
	if newest == "" {
		return "", nil, fmt.Errorf("no published stable Foreman CLI release has all four archives and checksums")
	}
	return newest, seen, nil
}

func (u updater) asset(ctx context.Context, tag, name string, limit int64) ([]byte, error) {
	res, err := u.get(ctx, u.download+"/"+tag+"/"+name, "")
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("download %s: HTTP %s", name, res.Status)
	}
	return bounded(res.Body, limit)
}
