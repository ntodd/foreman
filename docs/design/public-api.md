# Foreman public API

Draft for review, 2026-11-22. The CLI and development apps use the same versioned JSON API on each self-hosted Foreman instance. Foreman provisions environments, reports their condition, and manages their lifecycle. The caller chooses how to connect and run work. [Draft OpenAPI contract](./public-api.openapi.yaml)

## Agreed behavior

| Decision | Contract |
|---|---|
| Identity | People can connect a CLI or app to their own account. An admin can also install a service account for team automation. Both work unattended after setup. |
| Revision | Create accepts a branch name. Omitting it selects the repository’s default branch. Multiple environments can use the same branch. |
| Placement | Honor an explicit box ID. When it is omitted, prefer a provisionable box owned by the acting user, then any other provisionable box the caller may use. If none qualifies, return `no_provisionable_boxes`. |
| Ready | Devcontainer setup has succeeded and the workspace container is running. Apps decide when their own workloads are ready. |
| Recovery | Repeating a create request with its original request key returns the original environment and operation. An intentional second create uses a fresh key. |
| Lifetime | Environments persist by default. The caller may supply an expiry and explicitly choose stop, which preserves the disk, or destroy, which removes it. |

The following sections propose the wire format and acceptance criteria. The final section identifies policy decisions to settle before implementation.

## Connect once

The official CLI ships with a recognized public client ID. An instance admin registers each third-party app once, then each developer approves a personal connection. Both personal and service grants can authorize actions individually, including listing environments, reading logs, creating, starting, stopping and destroying environments. Creating an environment with expiry requires permission for the expiry action as well as create.

**Discovery.** For an instance at an HTTPS origin, fetch `/.well-known/oauth-authorization-server` and verify that its `issuer` matches the selected instance before using the advertised endpoints. Metadata lists the device authorization, token and revocation URLs, grant types, client authentication methods and individual scopes. [Authorization server metadata](https://www.rfc-editor.org/rfc/rfc8414.html)

**Scope names.** Use the resource-first form `resource:action`. Any authenticated connection can call `/me`. Request scopes as space-separated values. Use `repos:list`, `boxes:list`, `environments:list`, `environments:read`, `operations:list`, `operations:read` and `logs:read` for the corresponding reads. Mutations use `environments:create`, `environments:start`, `environments:stop` and `environments:destroy`. The scope for an expiry action is also required when setting it. The client must inspect the granted scope.

**Personal connection.** The client selects an instance URL and identifies itself to `POST /oauth/device/code` with its registered client ID. It displays the returned verification URI and user code. The user signs in to that instance using Foreman’s existing browser login, confirms the code, and approves the named client and requested permissions. The client polls `POST /oauth/token` at the advertised interval, handles pending approval, slowdown, denial, and expiry, and exchanges the device code once. This requires only outbound HTTPS from the client. Device codes expire after 10 minutes. A distributed CLI is a public client. [OAuth device authorization grant](https://www.rfc-editor.org/rfc/rfc8628.html)

**Ongoing personal access.** Issue a 15-minute bearer access token and rotating refresh token. Personal grants expire after 90 days without a successful refresh, measured from issuance until the first refresh and from the most recent refresh thereafter. Active grants continue until revocation or loss of eligibility. The client stores credentials per instance and account, persists replacements securely across restarts, and serializes refresh for each connection. Logout revokes that connection server-side. Users can also revoke an individual app from Foreman. Each API request applies the intersection of the app grant and the user’s current access. Every hour, recheck GitHub membership for users whose eligibility depends on org membership and who have a live session or an active API grant. A local disable or confirmed loss of eligibility invalidates existing access and refresh tokens. [OAuth security best current practice](https://www.rfc-editor.org/rfc/rfc9700.html)

**Team installation.** An admin provisions a distinct service identity, chooses its repos, boxes, actions and approved workload secrets, and supplies its credential to the app’s backend. The backend authenticates to the token endpoint with its installation client ID and rotatable secret using HTTP Basic over HTTPS (`client_secret_basic`). The client credentials grant issues a 15-minute access token. Admins can inspect, rotate, or revoke the installation credential. Departure of the installer preserves team automation. A developer’s interactive actions use their own connection. The app must enforce access to any results it stores or displays. [OAuth client credentials](https://www.rfc-editor.org/rfc/rfc6749.html#section-4.4)

Enforce authorization on discovery, creation, individual environments, operations, logs and connection metadata. Service accounts manage their own environments within their grants. Mint workload GitHub credentials only for approved repositories, including any secondary repos, with approved permissions. Service environments receive explicitly granted secrets and their own network access policy. Audit the client and the verified acting user or service identity. At dispatch, recheck authorization for queued user or service actions after access changes. Expiry cleanup is system work authorized when the policy is set.

**Repository visibility.** Personal connections discover synced repositories through the GitHub App installation using the developer’s GitHub token. For a repository an admin adds manually, Foreman verifies its full name and numeric GitHub ID with that developer’s token. An admin can submit an existing manual repository through Add repository again to bind its GitHub ID. Workspaces created before Foreman established that identity stay outside the public API. An archived repository leaves the launch catalog. Its owner can still manage and read history for existing workspaces while their repository and box access holds.

An outage while listing repositories or verifying an already-owned workspace returns `503 repository_access_unavailable`. A repository ID supplied on its own must pass visibility checks before a client can learn that it exists. On an instance using a local Git origin without GitHub, personal connections can discover repositories marked public. Service installations use their explicit repository and box grants.

**Offboarding.** Once Foreman confirms loss of access or an admin disables the acting identity, reject API access and prevent its queued work from dispatching. Leave running VMs and active sessions for admin review and shutdown. Where the deployment supports it, deny new SSH connections by the disabled identity while preserving existing sessions and authorized admin access. If the deployment cannot enforce this selectively, immediately block API access and flag the outstanding SSH removal for the tailnet admin. In this case the identity may still open new SSH sessions until the admin updates tailnet access. Stop issuing and refreshing workload GitHub credentials immediately. Credentials already delivered can be used until their existing expiry. Previously scheduled system expiry still applies. An installation has its own identity, so removing its installer alone leaves it active.

## Provision and recover

1. Call `GET /api/v1/me` to verify the instance, connection and acting identity. List accessible repos and boxes for selection.
2. Send `POST /api/v1/environments` with a new `Idempotency-Key`, a repo ID, and optional branch, box ID and expiry. Use a new key for each intended environment. A capacity warning requires explicit confirmation. A hard limit is enforced even with confirmation.
3. A successful submission returns `202 Accepted`, an environment ID, an operation ID and a `Location` header pointing to the operation. Poll that URL and read its logs while the agent provisions. If the response is lost, resubmit the same request with the same key.
4. Read the environment for its current readiness and, when available, hostname, SSH user and workspace folder. A completed create operation remains historical evidence after a workspace stops or its box goes offline. Report unknown readiness when Foreman can no longer establish the current condition.
5. Submit start, stop or destroy through the environment’s operations collection. Wait on the resulting operation exactly as for create. A successful stop preserves the workspace for a later start.

**Automatic placement.** Consider online, VM-capable boxes within the connection’s grants that admit this environment under their capacity policy and the request’s confirmation setting. Prefer user-owned candidates within that set. Service accounts select from their installation’s box grants. As a tie-breaker, use ascending box name within each group, matching Foreman’s box list. Recheck eligibility when reserving the environment. If the candidate has become unavailable, continue through the eligible boxes. Once accepted, retries recover the original placement. An explicit `box_id` pins the request to that box and preserves its specific access or placement error.

Example create body (the expiry is an absolute UTC instant):

```json
{
  "repo_id": "4e5e8a21-7689-4d4e-b95d-7364a37c551f",
  "branch": "feature/search",
  "expiry": {"at": "2026-12-01T18:00:00Z", "action": "stop"}
}
```

**Retry semantics.** Scope the key to the instance, acting identity, client and endpoint. Atomically commit the key, normalized request, environment reservation and operation before dispatch. Concurrent identical submissions converge on the same IDs, including across server restarts. Compare caller inputs before applying mutable defaults. Reusing an accepted key with changed input returns `409 idempotency_conflict`. Validation and capacity failures before acceptance reserve nothing. A replay rechecks visibility. Keep a compact record of each accepted create key for the life of the instance. After destruction, an authorized replay of the original create returns `410 original_environment_gone`, including after operation history has expired.

**Lifecycle responses.** After checking for a replay, return `200` with the environment ID if the target state is already reached and stable. If an active operation is already moving toward it, return `202` with that operation’s ID and location. An opposing action during an active transition returns `409 lifecycle_conflict`. For example, stop during create conflicts, while start during create follows the existing operation.

**Expiry.** Both fields are required when expiry is supplied. Reject a deadline already in the past. Persist the policy with the environment, show it on reads, and execute it once even after a control-plane restart. If the box is offline when due, record the pending action and reconcile it when possible. Once expiry is due, finish the in-flight operation and then apply expiry. Reject new actions that conflict with the due expiry. Expose the cleanup operation through `GET /api/v1/environments/{id}/operations`, including the action, trigger and outcome. Authorized callers can read this history by environment ID after destroy. Keep history for 90 days and logs for 30 days from the completion of each operation, independent of environment destruction. A completed stop policy is consumed so a later manual start can succeed.

**Client behavior.** Collection responses use opaque cursors; logs expose a cursor and indicate truncation. Clients can reconnect using the last cursor. API errors carry a stable code and a human-readable message. Use 401 for an expired or invalid credential, 403 for an unauthorized action on a visible resource, and 404 for an absent or invisible resource. A failed asynchronous build is a terminal operation result available by GET. Clients should tolerate additional response fields within v1.

**Read responses.** Collections return up to 50 items. Repository and box lists use ascending names, environments use ascending IDs, and operation history uses newest creation time first with the operation ID as the tie-breaker. Cursors belong to the same grant and collection. Log pages contain up to 64 KiB of durable, redacted output. An empty page can be polled again after the agent flushes more output. If the 1 MiB rolling tail overtakes the reader, the next page starts at the retained text and sets `truncated` to true.

A ready workspace has a successful devcontainer setup result for the same container ID that its box currently sees running. A failed sidecar can leave the environment partially running while its workspace is ready. A disconnected box, an unreachable guest, or a box without a fresh workspace report yields unknown readiness. Environment connection fields require `environments:read`, including on a collection response.

The v1 operation history includes create, start, stop and destroy. When Foreman times out an operation it reports a terminal `failed` with error code `operation_timeout`. A late agent result can correct the environment's observed state when that operation still controls it. The public operation keeps its timeout outcome.

Proposed create errors:

| HTTP | Code | Caller action |
|---|---|---|
| 409 | `no_provisionable_boxes` | “You have no provisionable boxes.” Check box access, availability and capacity before retrying. |
| 404 | `resource_not_found` | Refresh the visible repo or box list and select again. |
| 409 | `capacity_confirmation_required` | Present the warning. An authorized caller may resubmit with `confirm_capacity_warning: true`. |
| 409 | `capacity_exceeded` | Choose a different box or free capacity. |
| 409 | `idempotency_conflict` | Recover the original submission or use a fresh key for a distinct request. |
| 410 | `original_environment_gone` | The original create succeeded and its environment was destroyed. Use a fresh key for an intentional replacement. |
| 422 | `invalid_request` | Correct the invalid input, such as an expiry without an action. |

## Acceptance scenarios

- From a headless shell, approve on a second device, restart the client, list repos, create a default-branch workspace, observe readiness, stop it, and start it again with the same data.
- Verify device-code and access-token expiry, the 90-day personal refresh inactivity boundary, and hourly eligibility checks for API-only users. After a disable, verify that API access and workload credential renewal stop immediately. On a deployment with selective SSH enforcement, verify that a fresh login fails for that identity while existing sessions and authorized admin access continue. On a deployment without that capability, verify that the tailnet admin sees the pending SSH removal.
- After environment destruction, test log expiry at 30 days and history expiry at 90 days from operation completion. Replay the original create key after both expire.
- Simulate loss of the create response and simultaneous retries. Recover one environment and one operation. A different key creates a second environment on the same branch.
- Omit the box with both an owned and a shared box available. Verify the owned box wins. Take it offline or make its capacity policy refuse placement and verify the shared box wins. Remove the final eligible box and expect `409 no_provisionable_boxes` with no environment created.
- Supply an inaccessible box ID while a shared box is available. Expect the explicit selection to fail. Repeat with a service grant and verify that ownership by the installer gives the service no additional candidates. Test setup failure and box disconnection before reporting ready.
- Disable a developer with an active API token and no browser session. Deny their API access. Removing the installer leaves the independent team job working. Revoke the installation separately and deny its tokens and pending launches.
- Attempt to enumerate, read logs for, or obtain connection details for another owner’s workspace. Check secondary repos, injected secrets and actual SSH access for a service workspace as well as the HTTP responses.
- Exercise both expiry actions across control-plane restart and box outage. Verify the workspace disk survives stop and is removed after successful destroy. Verify an environment with no deadline persists.

## Open implementation choices

- Define the admin workflow for service credentials, runtime secrets and SSH grants. Verify which supported Tailscale configurations allow selective SSH enforcement and how Foreman surfaces pending manual removals.
- Define cursor expiry and expiry editing.
- Confirm whether launch, observe, start, stop and destroy cover the first release. Rebuild, suspend, event streaming and broader dashboard operations can be specified individually.
