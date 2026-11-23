// Code generated from docs/design/public-api.openapi.yaml by go generate. DO NOT EDIT.

package api

import (
	"context"
	"net/url"
)

type DeviceCodeGrant struct {
	GrantType  string `json:"grant_type"`
	ClientID   string `json:"client_id"`
	DeviceCode string `json:"device_code"`
}

type RefreshTokenGrant struct {
	GrantType    string       `json:"grant_type"`
	ClientID     string       `json:"client_id"`
	RefreshToken string       `json:"refresh_token"`
	Scope        *ScopeString `json:"scope,omitempty"`
}

type ClientCredentialsGrant struct {
	GrantType string       `json:"grant_type"`
	Scope     *ScopeString `json:"scope,omitempty"`
}

type ScopeString = string

type ID = string

type Identity struct {
	ID       ID     `json:"id"`
	Kind     string `json:"kind"`
	ClientID string `json:"client_id"`
}

type Repository struct {
	ID            ID     `json:"id"`
	FullName      string `json:"full_name"`
	DefaultBranch string `json:"default_branch"`
}

type Box struct {
	ID     ID     `json:"id"`
	Name   string `json:"name"`
	Online bool   `json:"online"`
}

type Expiry struct {
	At     string `json:"at"`
	Action string `json:"action"`
}

type Create struct {
	RepoID                 ID      `json:"repo_id"`
	BoxID                  *ID     `json:"box_id,omitempty"`
	Branch                 *string `json:"branch,omitempty"`
	Expiry                 *Expiry `json:"expiry,omitempty"`
	ConfirmCapacityWarning *bool   `json:"confirm_capacity_warning,omitempty"`
}

type Action struct {
	Action                 string `json:"action"`
	ConfirmCapacityWarning *bool  `json:"confirm_capacity_warning,omitempty"`
}

type Accepted struct {
	EnvironmentID           ID    `json:"environment_id"`
	OperationID             ID    `json:"operation_id"`
	OperationHistoryExpired *bool `json:"operation_history_expired,omitempty"`
}

type Environment struct {
	ID              ID      `json:"id"`
	Slug            string  `json:"slug"`
	RepoID          ID      `json:"repo_id"`
	Branch          string  `json:"branch"`
	BoxID           ID      `json:"box_id"`
	DesiredState    string  `json:"desired_state"`
	ObservedState   string  `json:"observed_state"`
	Readiness       string  `json:"readiness"`
	Expiry          *Expiry `json:"expiry,omitempty"`
	Hostname        *string `json:"hostname,omitempty"`
	SSHUser         *string `json:"ssh_user,omitempty"`
	WorkspaceFolder *string `json:"workspace_folder,omitempty"`
}

type Operation struct {
	ID            ID     `json:"id"`
	EnvironmentID ID     `json:"environment_id"`
	Action        string `json:"action"`
	Trigger       string `json:"trigger"`
	Status        string `json:"status"`
	Error         *Error `json:"error,omitempty"`
}

type OperationPage struct {
	Items      []Operation `json:"items"`
	NextCursor *string     `json:"next_cursor"`
}

type LogPage struct {
	Text       string `json:"text"`
	NextCursor string `json:"next_cursor"`
	Truncated  bool   `json:"truncated"`
}

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type Secret struct {
	Name      string `json:"name"`
	UpdatedAt string `json:"updated_at"`
}

type SecretPage struct {
	Items      []Secret `json:"items"`
	NextCursor *string  `json:"next_cursor"`
}

type SecretValue struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type SecretChanges struct {
	Secrets *[]SecretValue `json:"secrets,omitempty"`
	Unset   *[]string      `json:"unset,omitempty"`
}

type EnvironmentRef struct {
	ID   ID     `json:"id"`
	Slug string `json:"slug"`
}

type SecretChangeResult struct {
	Set            []string         `json:"set"`
	Unset          []string         `json:"unset"`
	Affected       []EnvironmentRef `json:"affected"`
	OthersAffected int64            `json:"others_affected"`
}

type EnvironmentPage struct {
	Items      []Environment `json:"items"`
	NextCursor *string       `json:"next_cursor"`
}

type RepositoryPage struct {
	Items      []Repository `json:"items"`
	NextCursor *string      `json:"next_cursor"`
}

type BoxPage struct {
	Items      []Box   `json:"items"`
	NextCursor *string `json:"next_cursor"`
}

type GetOAuthMetadataResult struct {
	Issuer                                 string    `json:"issuer"`
	DeviceAuthorizationEndpoint            string    `json:"device_authorization_endpoint"`
	TokenEndpoint                          string    `json:"token_endpoint"`
	RevocationEndpoint                     string    `json:"revocation_endpoint"`
	ScopesSupported                        []string  `json:"scopes_supported"`
	GrantTypesSupported                    []string  `json:"grant_types_supported"`
	ResponseTypesSupported                 []string  `json:"response_types_supported"`
	TokenEndpointAuthMethodsSupported      []string  `json:"token_endpoint_auth_methods_supported"`
	RevocationEndpointAuthMethodsSupported *[]string `json:"revocation_endpoint_auth_methods_supported,omitempty"`
}

type RequestDeviceCodeBody struct {
	ClientID string      `json:"client_id"`
	Scope    ScopeString `json:"scope"`
}

type RequestDeviceCodeResult struct {
	DeviceCode              string  `json:"device_code"`
	UserCode                string  `json:"user_code"`
	VerificationURI         string  `json:"verification_uri"`
	VerificationURIComplete *string `json:"verification_uri_complete,omitempty"`
	ExpiresIn               int64   `json:"expires_in"`
	Interval                int64   `json:"interval"`
}

type ObtainTokenResult struct {
	AccessToken  string      `json:"access_token"`
	TokenType    string      `json:"token_type"`
	ExpiresIn    int64       `json:"expires_in"`
	Scope        ScopeString `json:"scope"`
	RefreshToken *string     `json:"refresh_token,omitempty"`
}

type RevokeTokenBody struct {
	Token         string  `json:"token"`
	TokenTypeHint *string `json:"token_type_hint,omitempty"`
	ClientID      *string `json:"client_id,omitempty"`
}

type OperateEnvironmentResult struct {
	EnvironmentID           ID    `json:"environment_id"`
	OperationID             *ID   `json:"operation_id,omitempty"`
	OperationHistoryExpired *bool `json:"operation_history_expired,omitempty"`
}

type TokenGrant interface {
	form() url.Values
	tokenGrant()
}

func (DeviceCodeGrant) tokenGrant() {}

func (RefreshTokenGrant) tokenGrant() {}

func (ClientCredentialsGrant) tokenGrant() {}

func (v RequestDeviceCodeBody) form() url.Values {
	values := url.Values{}
	values.Set("client_id", v.ClientID)
	values.Set("scope", v.Scope)
	return values
}

func (v DeviceCodeGrant) form() url.Values {
	values := url.Values{}
	values.Set("grant_type", v.GrantType)
	values.Set("client_id", v.ClientID)
	values.Set("device_code", v.DeviceCode)
	return values
}

func (v RefreshTokenGrant) form() url.Values {
	values := url.Values{}
	values.Set("grant_type", v.GrantType)
	values.Set("client_id", v.ClientID)
	values.Set("refresh_token", v.RefreshToken)
	if v.Scope != nil {
		values.Set("scope", *v.Scope)
	}
	return values
}

func (v ClientCredentialsGrant) form() url.Values {
	values := url.Values{}
	values.Set("grant_type", v.GrantType)
	if v.Scope != nil {
		values.Set("scope", *v.Scope)
	}
	return values
}

func (v RevokeTokenBody) form() url.Values {
	values := url.Values{}
	values.Set("token", v.Token)
	if v.TokenTypeHint != nil {
		values.Set("token_type_hint", *v.TokenTypeHint)
	}
	if v.ClientID != nil {
		values.Set("client_id", *v.ClientID)
	}
	return values
}

// GetOAuthMetadata — Discover the instance issuer, endpoints, grants and scopes.
func (c *Client) GetOAuthMetadata(ctx context.Context) (*Response[GetOAuthMetadataResult], error) {
	return call[GetOAuthMetadataResult](ctx, c, request{method: "GET", path: "/.well-known/oauth-authorization-server", success: []int{200}})
}

// RequestDeviceCode — Begin personal approval on another device.
func (c *Client) RequestDeviceCode(ctx context.Context, body RequestDeviceCodeBody) (*Response[RequestDeviceCodeResult], error) {
	return call[RequestDeviceCodeResult](ctx, c, request{method: "POST", path: "/oauth/device/code", form: body.form(), oauthOperation: "RequestDeviceCode", success: []int{200}})
}

// ObtainToken — Exchange a device code, rotate a refresh token, or obtain a service token.
func (c *Client) ObtainToken(ctx context.Context, body TokenGrant) (*Response[ObtainTokenResult], error) {
	return call[ObtainTokenResult](ctx, c, request{method: "POST", basic: true, path: "/oauth/token", form: body.form(), oauthOperation: "ObtainToken", success: []int{200}})
}

// RevokeToken — Revoke the personal connection on logout or invalidate a service access token.
func (c *Client) RevokeToken(ctx context.Context, body RevokeTokenBody) (*Response[struct{}], error) {
	return call[struct{}](ctx, c, request{method: "POST", basic: true, path: "/oauth/revoke", form: body.form(), oauthOperation: "RevokeToken", emptyResponse: true, success: []int{200}})
}

// GetIdentity — Show the acting identity and connected client.
func (c *Client) GetIdentity(ctx context.Context) (*Response[Identity], error) {
	return call[Identity](ctx, c, request{method: "GET", bearer: true, path: "/api/v1/me", success: []int{200}})
}

// ListRepos — List repositories available to this connection.
func (c *Client) ListRepos(ctx context.Context, cursor string) (*Response[RepositoryPage], error) {
	return call[RepositoryPage](ctx, c, request{method: "GET", bearer: true, cursor: cursor, path: "/api/v1/repos", success: []int{200}})
}

// ListBoxes — List boxes available to this connection.
func (c *Client) ListBoxes(ctx context.Context, cursor string) (*Response[BoxPage], error) {
	return call[BoxPage](ctx, c, request{method: "GET", bearer: true, cursor: cursor, path: "/api/v1/boxes", success: []int{200}})
}

// ListEnvironments — List visible environments.
func (c *Client) ListEnvironments(ctx context.Context, cursor string) (*Response[EnvironmentPage], error) {
	return call[EnvironmentPage](ctx, c, request{method: "GET", bearer: true, cursor: cursor, path: "/api/v1/environments", success: []int{200}})
}

// CreateEnvironment — Reserve an environment and queue provisioning.
func (c *Client) CreateEnvironment(ctx context.Context, key string, body Create) (*Response[Accepted], error) {
	return call[Accepted](ctx, c, request{method: "POST", bearer: true, key: key, path: "/api/v1/environments", body: body, success: []int{202}})
}

// GetEnvironment — Read current environment state and connection details.
func (c *Client) GetEnvironment(ctx context.Context, id string) (*Response[Environment], error) {
	return call[Environment](ctx, c, request{method: "GET", bearer: true, path: "/api/v1/environments/" + url.PathEscape(id), success: []int{200}})
}

// ListEnvironmentOperations — Read authorized operation history through its retention period, including after destroy.
func (c *Client) ListEnvironmentOperations(ctx context.Context, id string, cursor string) (*Response[OperationPage], error) {
	return call[OperationPage](ctx, c, request{method: "GET", bearer: true, cursor: cursor, path: "/api/v1/environments/" + url.PathEscape(id) + "/operations", success: []int{200}})
}

// OperateEnvironment — Queue a lifecycle action.
func (c *Client) OperateEnvironment(ctx context.Context, id string, key string, body Action) (*Response[OperateEnvironmentResult], error) {
	return call[OperateEnvironmentResult](ctx, c, request{method: "POST", bearer: true, key: key, path: "/api/v1/environments/" + url.PathEscape(id) + "/operations", body: body, success: []int{200, 202}})
}

// GetOperation — Read a lifecycle operation and its outcome.
func (c *Client) GetOperation(ctx context.Context, id string) (*Response[Operation], error) {
	return call[Operation](ctx, c, request{method: "GET", bearer: true, path: "/api/v1/operations/" + url.PathEscape(id), success: []int{200}})
}

// GetOperationLogs — Read the next portion of the operation log.
func (c *Client) GetOperationLogs(ctx context.Context, id string, cursor string) (*Response[LogPage], error) {
	return call[LogPage](ctx, c, request{method: "GET", bearer: true, cursor: cursor, path: "/api/v1/operations/" + url.PathEscape(id) + "/logs", success: []int{200}})
}

// ListSecrets — List the names of the secrets set at one scope.
func (c *Client) ListSecrets(ctx context.Context, scope string, subject string, cursor string) (*Response[SecretPage], error) {
	return call[SecretPage](ctx, c, request{method: "GET", bearer: true, cursor: cursor, path: "/api/v1/secrets/" + url.PathEscape(scope) + "/" + url.PathEscape(subject), success: []int{200}})
}

// ChangeSecrets — Set and remove secrets at one scope together.
func (c *Client) ChangeSecrets(ctx context.Context, scope string, subject string, body SecretChanges) (*Response[SecretChangeResult], error) {
	return call[SecretChangeResult](ctx, c, request{method: "PATCH", bearer: true, path: "/api/v1/secrets/" + url.PathEscape(scope) + "/" + url.PathEscape(subject), body: body, success: []int{200}})
}
