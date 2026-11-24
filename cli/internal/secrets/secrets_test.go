package secrets

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/ntodd/foreman/cli/api"
)

const (
	envID  = "eeeeeeee-0000-4000-8000-111111111111"
	repoID = "aaaaaaaa-0000-4000-8000-111111111111"
)

type change struct {
	scope, subject string
	set            map[string]string
	order, unset   []string
}

// An unset function panics, so an unexpected request fails the test.
type fake struct {
	repos   func(string) (api.RepositoryPage, error)
	list    func(scope, subject, cursor string) (api.SecretPage, error)
	result  api.SecretChangeResult
	err     error
	changes []change
}

func (f *fake) ListRepos(_ context.Context, cursor string) (*api.Response[api.RepositoryPage], error) {
	page, err := f.repos(cursor)
	return &api.Response[api.RepositoryPage]{Value: page}, err
}

func (f *fake) ListSecrets(_ context.Context, scope, subject, cursor string) (*api.Response[api.SecretPage], error) {
	page, err := f.list(scope, subject, cursor)
	return &api.Response[api.SecretPage]{Value: page}, err
}

func (f *fake) ChangeSecrets(_ context.Context, scope, subject string, body api.SecretChanges) (*api.Response[api.SecretChangeResult], error) {
	c := change{scope: scope, subject: subject, set: map[string]string{}}
	if body.Secrets != nil {
		for _, s := range *body.Secrets {
			c.set[s.Name] = s.Value
			c.order = append(c.order, s.Name)
		}
	}
	if body.Unset != nil {
		c.unset = *body.Unset
	}
	f.changes = append(f.changes, c)
	if f.err != nil {
		return nil, f.err
	}
	result := f.result
	if result.Set == nil {
		result.Set = c.order
	}
	if result.Unset == nil {
		result.Unset = c.unset
	}
	return &api.Response[api.SecretChangeResult]{Value: result}, nil
}

type run struct {
	out, err bytes.Buffer
	failure  error
}

func invoke(t *testing.T, f *fake, o Options, args ...string) *run {
	t.Helper()
	r := &run{}
	o.API, o.Out, o.Err = f, &r.out, &r.err
	if o.In == nil {
		o.In = strings.NewReader("")
	}
	r.failure = Run(context.Background(), append([]string{"secrets"}, args...), o)
	return r
}

func code(err error) string {
	var f *Failure
	if errors.As(err, &f) {
		return f.Code
	}
	return fmt.Sprint(err)
}

func TestSetSendsEveryPairInOneRequestToTheChosenScope(t *testing.T) {
	cases := []struct {
		flags          []string
		scope, subject string
	}{
		{nil, "user", "me"},
		{[]string{"--user"}, "user", "me"},
		{[]string{"--env", envID}, "environment", envID},
		{[]string{"--env=" + envID}, "environment", envID},
		{[]string{"--repo", repoID}, "repo", repoID},
		{[]string{"--owner", "acme"}, "owner", "acme"},
	}
	for _, c := range cases {
		f := &fake{}
		r := invoke(t, f, Options{}, append([]string{"set", "A=1", "B=two words", "C=a=b"}, c.flags...)...)
		if r.failure != nil {
			t.Fatalf("%v: %v", c.flags, r.failure)
		}
		want := []change{{scope: c.scope, subject: c.subject, set: map[string]string{"A": "1", "B": "two words", "C": "a=b"}, order: []string{"A", "B", "C"}}}
		if !reflect.DeepEqual(f.changes, want) {
			t.Fatalf("%v: sent %+v", c.flags, f.changes)
		}
		if strings.Contains(r.out.String()+r.err.String(), "two words") {
			t.Fatal("a value was printed")
		}
	}
}

func TestRepoNameResolvesThroughEveryPage(t *testing.T) {
	next := "p2"
	f := &fake{repos: func(cursor string) (api.RepositoryPage, error) {
		if cursor == "" {
			return api.RepositoryPage{Items: []api.Repository{{ID: "other", FullName: "acme/other"}}, NextCursor: &next}, nil
		}
		return api.RepositoryPage{Items: []api.Repository{{ID: repoID, FullName: "acme/storefront"}}}, nil
	}}
	r := invoke(t, f, Options{}, "set", "A=1", "--repo", "acme/storefront")
	if r.failure != nil || len(f.changes) != 1 || f.changes[0].subject != repoID || f.changes[0].scope != "repo" {
		t.Fatalf("%v %+v", r.failure, f.changes)
	}

	r = invoke(t, f, Options{}, "set", "A=1", "--repo", "acme/missing")
	if code(r.failure) != "resource_not_found" || len(f.changes) != 1 {
		t.Fatalf("%v %+v", r.failure, f.changes)
	}
}

func TestInvalidInvocationsSendNothing(t *testing.T) {
	for _, args := range [][]string{
		{},
		{"frobnicate"},
		{"set"},
		{"unset"},
		{"import"},
		{"import", "a.env", "b.env"},
		{"set", "A=1", "--env", envID, "--user"},
		{"set", "A=1", "--repo", "x", "--owner", "y"},
		{"set", "A=1", "--env"},
		{"set", "A=1", "--bogus"},
		{"set", "=1"},
		{"set", "A=1", "A=2"},
		{"unset", "A", "A"},
		{"unset", "A=1"},
		{"list", "extra"},
	} {
		f := &fake{}
		r := invoke(t, f, Options{}, args...)
		if code(r.failure) != "invalid_invocation" || len(f.changes) != 0 {
			t.Fatalf("%v: %v %+v", args, r.failure, f.changes)
		}
	}
}

func TestValuesComeFromFilesAndPrompts(t *testing.T) {
	files := map[string]string{"key.pem": "line1\nline2\n", "crlf.txt": "v\r\n", "bare": "v"}
	read := func(path string) ([]byte, error) {
		if body, ok := files[path]; ok {
			return []byte(body), nil
		}
		return nil, errors.New("no such file")
	}
	prompted := []string{}
	prompt := func(name string) (string, error) {
		prompted = append(prompted, name)
		return "typed " + name, nil
	}
	f := &fake{}
	r := invoke(t, f, Options{ReadFile: read, Prompt: prompt}, "set", "PEM=@key.pem", "CRLF=@crlf.txt", "BARE=@bare", "ASKED", "PLAIN=x")
	if r.failure != nil {
		t.Fatal(r.failure)
	}
	want := map[string]string{"PEM": "line1\nline2", "CRLF": "v", "BARE": "v", "ASKED": "typed ASKED", "PLAIN": "x"}
	if !reflect.DeepEqual(f.changes[0].set, want) || !reflect.DeepEqual(prompted, []string{"ASKED"}) {
		t.Fatalf("%+v %v", f.changes[0].set, prompted)
	}

	f = &fake{}
	r = invoke(t, f, Options{ReadFile: read, Prompt: prompt}, "set", "A=@missing")
	if code(r.failure) != "invalid_invocation" || len(f.changes) != 0 {
		t.Fatalf("%v %+v", r.failure, f.changes)
	}

	// Without a terminal there is nobody to ask.
	f = &fake{}
	r = invoke(t, f, Options{ReadFile: read}, "set", "ASKED")
	if code(r.failure) != "invalid_invocation" || len(f.changes) != 0 || !strings.Contains(r.err.String(), "ASKED=") {
		t.Fatalf("%v %q", r.failure, r.err.String())
	}
}

func TestUnsetReportsNamesThatWereNotSet(t *testing.T) {
	f := &fake{result: api.SecretChangeResult{Set: []string{}, Unset: []string{"OLD"}}}
	r := invoke(t, f, Options{}, "unset", "OLD", "NEVER", "--env", envID)
	if r.failure != nil || !reflect.DeepEqual(f.changes[0].unset, []string{"OLD", "NEVER"}) || len(f.changes[0].set) != 0 {
		t.Fatalf("%v %+v", r.failure, f.changes)
	}
	out := r.out.String()
	if !strings.Contains(out, "Removed OLD") || !strings.Contains(out, "NEVER") {
		t.Fatal(out)
	}
}

func TestImportReadsADotenvFile(t *testing.T) {
	body := strings.Join([]string{
		"# a comment",
		"",
		"PLAIN=value",
		"export EXPORTED=yes",
		"SPACED = padded value  ",
		`DOUBLE="two words # kept\nnext \"quoted\" \\ done"`,
		`ODD="a\qb \$HOME"`,
		`SINGLE='raw $HOME \n # kept'`,
		"INLINE=value # trailing comment",
		"HASH=abc#def",
		"TABBED=value\t# a comment after a tab",
		"EQUALS=a=b=c",
	}, "\n")
	read := func(string) ([]byte, error) { return []byte(body), nil }
	f := &fake{}
	r := invoke(t, f, Options{ReadFile: read}, "import", "prod.env", "--repo", repoID)
	if r.failure != nil {
		t.Fatal(r.failure, r.err.String())
	}
	want := map[string]string{
		"PLAIN": "value", "EXPORTED": "yes", "SPACED": "padded value",
		"DOUBLE": "two words # kept\nnext \"quoted\" \\ done", "SINGLE": `raw $HOME \n # kept`,
		"INLINE": "value", "HASH": "abc#def", "TABBED": "value", "EQUALS": "a=b=c", "ODD": `a\qb \$HOME`,
	}
	if !reflect.DeepEqual(f.changes[0].set, want) || f.changes[0].scope != "repo" {
		t.Fatalf("%+v", f.changes[0].set)
	}

	// Standard input, when the file is "-".
	f = &fake{}
	r = invoke(t, f, Options{In: strings.NewReader("A=1\n")}, "import", "-")
	if r.failure != nil || f.changes[0].set["A"] != "1" {
		t.Fatalf("%v %+v", r.failure, f.changes)
	}
}

func TestImportRefusesWhatItCannotRead(t *testing.T) {
	many := &strings.Builder{}
	for i := 0; i < 101; i++ {
		fmt.Fprintf(many, "N%d=v\n", i)
	}
	for name, body := range map[string]string{
		"no equals":      "JUSTAWORD\n",
		"open quote":     "A=\"unterminated\n",
		"junk after":     "A=\"x\" y\n",
		"duplicate":      "A=1\nA=2\n",
		"nothing to set": "# only a comment\n",
		"empty quoted":   "A=\"\"\n",
		"only a comment": "A=   # nothing before this\n",
		"empty":          "A=\n",
		"not utf-8":      "A=caf\xe9\n",
		"too many":       many.String(),
	} {
		f := &fake{}
		r := invoke(t, f, Options{ReadFile: func(string) ([]byte, error) { return []byte(body), nil }}, "import", "x.env")
		if code(r.failure) != "invalid_invocation" || len(f.changes) != 0 {
			t.Fatalf("%s: %v %+v", name, r.failure, f.changes)
		}
		if strings.Contains(r.err.String(), "unterminated") {
			t.Fatalf("%s: a value was printed: %s", name, r.err.String())
		}
	}
}

func TestListFollowsPagesAndPrintsNamesOnly(t *testing.T) {
	next := "p2"
	f := &fake{list: func(scope, subject, cursor string) (api.SecretPage, error) {
		if scope != "environment" || subject != envID {
			t.Fatalf("%s %s", scope, subject)
		}
		if cursor == "" {
			return api.SecretPage{Items: []api.Secret{{Name: "A", UpdatedAt: "2026-11-23T10:00:00Z"}}, NextCursor: &next}, nil
		}
		return api.SecretPage{Items: []api.Secret{{Name: "B", UpdatedAt: "2026-11-23T11:00:00Z"}}}, nil
	}}
	r := invoke(t, f, Options{}, "list", "--env", envID)
	if r.failure != nil || r.out.String() != "NAME\tUPDATED\nA\t2026-11-23T10:00:00Z\nB\t2026-11-23T11:00:00Z\n" {
		t.Fatalf("%v %q", r.failure, r.out.String())
	}

	r = invoke(t, f, Options{JSON: true}, "list", "--env", envID)
	var doc struct{ Items []api.Secret }
	if err := json.Unmarshal(r.out.Bytes(), &doc); err != nil || len(doc.Items) != 2 || doc.Items[1].Name != "B" {
		t.Fatalf("%v %s", err, r.out.String())
	}
}

func TestOutputSaysWhatNeedsARestart(t *testing.T) {
	f := &fake{result: api.SecretChangeResult{
		Affected:       []api.EnvironmentRef{{ID: envID, Slug: "storefront-alice-1"}},
		OthersAffected: 2,
	}}
	r := invoke(t, f, Options{}, "set", "A=1", "B=2", "--repo", repoID)
	out := r.out.String()
	for _, want := range []string{"Set A, B", "storefront-alice-1", envID, "foreman env restart " + envID, "2 running"} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q in:\n%s", want, out)
		}
	}

	r = invoke(t, f, Options{JSON: true}, "set", "A=1", "--repo", repoID)
	var doc api.SecretChangeResult
	if err := json.Unmarshal(r.out.Bytes(), &doc); err != nil || doc.OthersAffected != 2 || doc.Affected[0].ID != envID || r.err.Len() != 0 {
		t.Fatalf("%v %s %s", err, r.out.String(), r.err.String())
	}
}

func TestRemoteErrorsKeepTheirCodeAndAMissingPermissionSaysHowToGetIt(t *testing.T) {
	f := &fake{err: &api.HTTPError{Code: "insufficient_scope", Message: "This connection lacks permission to change secrets.", StatusCode: 403}}
	r := invoke(t, f, Options{LoginScope: "repos:list secrets:list secrets:write"}, "set", "A=1")
	if code(r.failure) != "insufficient_scope" || !strings.Contains(r.err.String(), `foreman login --scope "repos:list secrets:list secrets:write"`) {
		t.Fatalf("%v %q", r.failure, r.err.String())
	}

	f = &fake{err: &api.HTTPError{Code: "invalid_request", Message: "9LIVES: name must start with a letter", StatusCode: 422}}
	r = invoke(t, f, Options{JSON: true}, "set", "A=1")
	var doc Failure
	if err := json.Unmarshal(r.err.Bytes(), &doc); err != nil || doc.Code != "invalid_request" || doc.HTTPStatus != 422 || r.out.Len() != 0 {
		t.Fatalf("%v %s", err, r.err.String())
	}
}

func TestNothingTheCallerTypedIsRepeatedBack(t *testing.T) {
	read := func(string) ([]byte, error) { return nil, errors.New("open sk-live-4242: no such file") }
	for _, args := range [][]string{
		{"unset", "TOKEN=sk-live-4242"},
		{"set", "A=1", "--token=sk-live-4242"},
		{"set", "A=1", "--env", "TOKEN=sk-live-4242"},
		{"set", "A=1", "--owner", "TOKEN=sk-live-4242"},
		{"set", "A=1", "--repo", "TOKEN=sk-live-4242"},
		{"set", "TOKEN=@sk-live-4242"},
		{"set", "sk-live-4242"},
		{"list", "sk-live-4242"},
		{"import", "TOKEN=sk-live-4242"},
	} {
		f := &fake{}
		r := invoke(t, f, Options{ReadFile: read}, args...)
		if code(r.failure) != "invalid_invocation" || len(f.changes) != 0 {
			t.Fatalf("%v: %v %+v", args, r.failure, f.changes)
		}
		if strings.Contains(r.out.String()+r.err.String(), "4242") {
			t.Fatalf("%v repeated its operand: %s", args, r.err.String())
		}
	}
}

func TestLevelSelectorsMustLookLikeWhatTheyName(t *testing.T) {
	for _, flags := range [][]string{
		{"--env", "not-a-uuid"}, {"--env", "acme/storefront"},
		{"--repo", "justaname"}, {"--repo", "acme/store front"}, {"--repo", "a/b/c"},
		{"--owner", "acme/storefront"}, {"--owner", "-acme"}, {"--owner", "ac me"},
	} {
		f := &fake{}
		r := invoke(t, f, Options{}, append([]string{"set", "A=1"}, flags...)...)
		if code(r.failure) != "invalid_invocation" || len(f.changes) != 0 {
			t.Fatalf("%v: %v %+v", flags, r.failure, f.changes)
		}
	}
}

func TestOneValueCanComeFromStandardInput(t *testing.T) {
	f := &fake{}
	r := invoke(t, f, Options{In: strings.NewReader("@starts with at\nsecond line\n")}, "set", "PIPED=-", "OTHER=x")
	if r.failure != nil || f.changes[0].set["PIPED"] != "@starts with at\nsecond line" || f.changes[0].set["OTHER"] != "x" {
		t.Fatalf("%v %+v", r.failure, f.changes)
	}

	// On a terminal, - asks without echo instead of reading what is typed in the clear.
	f = &fake{}
	asked := func(name string) (string, error) { return "typed " + name, nil }
	r = invoke(t, f, Options{In: strings.NewReader("echoed"), Prompt: asked}, "set", "A=-")
	if r.failure != nil || f.changes[0].set["A"] != "typed A" {
		t.Fatalf("%v %+v", r.failure, f.changes)
	}

	f = &fake{}
	r = invoke(t, f, Options{In: strings.NewReader("v")}, "set", "A=-", "B=-")
	if code(r.failure) != "invalid_invocation" || len(f.changes) != 0 {
		t.Fatalf("%v %+v", r.failure, f.changes)
	}
}

func TestEmptyAndUnencodableValuesAreRefusedBeforeSending(t *testing.T) {
	files := map[string]string{"empty": "", "newline": "\n", "latin1": "caf\xe9"}
	read := func(path string) ([]byte, error) { return []byte(files[path]), nil }
	for _, args := range [][]string{
		{"set", "A="}, {"set", "A=@empty"}, {"set", "A=@newline"}, {"set", "A=@latin1"}, {"set", "A=caf\xe9"},
	} {
		f := &fake{}
		r := invoke(t, f, Options{ReadFile: read, Prompt: func(string) (string, error) { return "", nil }}, args...)
		if code(r.failure) != "invalid_invocation" || len(f.changes) != 0 {
			t.Fatalf("%v: %v %+v", args, r.failure, f.changes)
		}
	}
	f := &fake{}
	r := invoke(t, f, Options{Prompt: func(string) (string, error) { return "", nil }}, "set", "ASKED")
	if code(r.failure) != "invalid_invocation" || len(f.changes) != 0 {
		t.Fatalf("%v %+v", r.failure, f.changes)
	}
}
