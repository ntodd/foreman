# Foreman public API

The CLI and development apps use the same versioned JSON API on each self-hosted Foreman instance. Foreman provisions environments, reports their condition, and manages their lifecycle. The caller chooses how to connect and run work. [OpenAPI contract](./public-api.openapi.yaml)

## Agreed behavior

| Decision | Contract |
|---|---|
| Identity | People can connect a CLI or app to their own account. An admin can also install a service account for team automation. Both work unattended after setup. |
| Revision | Create accepts a branch name. Omitting it selects the repository’s default branch. Multiple environments can use the same branch. |
| Placement | Honor an explicit box ID. When it is omitted, prefer a provisionable box owned by the acting user, then any other provisionable box the caller may use. If none qualifies, return `no_provisionable_boxes`. |
| Ready | Devcontainer setup has succeeded and the workspace container is running. Apps decide when their own workloads are ready. |
| Recovery | Repeating a create request with its original request key returns the original environment and operation. An intentional second create uses a fresh key. |
| Lifetime | Environments persist by default. The caller may supply an expiry and explicitly choose stop, which preserves the disk, or destroy, which removes it. |

See the [connection guide](../setup/api-clients.md) for CLI login, third-party client registration, service credential rotation and TLS configuration.

## Connect once

The official CLI ships with a recognized public client ID. An instance admin registers each third-party app once, then each developer approves a personal connection. Both personal and service grants can authorize actions individually, including listing environments, reading logs, creating, starting, stopping and destroying environments. Creating an environment with expiry requires permission for the expiry action as well as create.

**Discovery.** For an instance at an HTTPS origin, fetch `/.well-known/oauth-authorization-server` and verify that its `issuer` matches the selected instance before using the advertised endpoints. Metadata lists the device authorization, token and revocation URLs, grant types, client authentication methods and individual scopes. [Authorization server metadata](https://www.rfc-editor.org/rfc/rfc8414.html)

**Scope names.** Use the resource-first form `resource:action`. Any authenticated connection can call `/me`. Request scopes as space-separated values. Use `repos:list`, `boxes:list`, `environments:list`, `environments:read`, `operations:list`, `operations:read` and `logs:read` for the corresponding reads. Mutations use `environments:create`, `environments:start`, `environments:stop` and `environments:destroy`. The scope for an expiry action is also required when setting it. `secrets:list` and `secrets:write` cover secrets and belong to personal connections alone: an admin cannot grant them to a service account. `attachments:create` allows uploading a file to an environment's repository. Like the secrets scopes, it can't be granted to a service account. An environment's own connection has it, and the CLI's login doesn't request it. The client must inspect the granted scope.

**Personal connection.** The client selects an instance URL and identifies itself to `POST /oauth/device/code` with its registered client ID. It displays the returned verification URI and user code. The user signs in to that instance using Foreman’s existing browser login, confirms the code, and approves the named client and requested permissions. The client polls `POST /oauth/token` at the advertised interval, handles pending approval, slowdown, denial, and expiry, and exchanges the device code once. This requires only outbound HTTPS from the client. Device codes expire after 10 minutes. A distributed CLI is a public client. [OAuth device authorization grant](https://www.rfc-editor.org/rfc/rfc8628.html)

**Ongoing personal access.** Issue a 15-minute bearer access token and rotating refresh token. Personal grants expire after 90 days without a successful refresh, measured from issuance until the first refresh and from the most recent refresh thereafter. Active grants continue until revocation or loss of eligibility. The client stores credentials per instance and account, persists replacements securely across restarts, and serializes refresh for each connection. Logout revokes that connection server-side. Users can also revoke an individual app from Foreman. Each API request applies the intersection of the app grant and the user’s current access. Every hour, recheck GitHub membership for users whose eligibility depends on org membership and who have a live session or an active API grant. A local disable or confirmed loss of eligibility invalidates existing access and refresh tokens. [OAuth security best current practice](https://www.rfc-editor.org/rfc/rfc9700.html)

**Team installation.** An admin provisions a distinct service identity, chooses its repos, boxes, actions and approved workload secrets, and supplies its credential to the app’s backend. The backend authenticates to the token endpoint with its installation client ID and rotatable secret using HTTP Basic over HTTPS (`client_secret_basic`). The client credentials grant issues a 15-minute access token. Admins can inspect, rotate, or revoke the installation credential. Departure of the installer preserves team automation. A developer’s interactive actions use their own connection. The app must enforce access to any results it stores or displays. [OAuth client credentials](https://www.rfc-editor.org/rfc/rfc6749.html#section-4.4)

Enforce authorization on discovery, creation, individual environments, operations, logs and connection metadata. Service accounts manage their own environments within their grants. Mint workload GitHub credentials only for approved repositories, including any secondary repos, with approved permissions. Service environments receive explicitly granted secrets and their own network access policy. Audit the client and the verified acting user or service identity. At dispatch, recheck authorization for queued user or service actions after access changes. Expiry cleanup is system work authorized when the policy is set.

**Repository visibility.** Personal connections discover synced repositories through the GitHub App installation using the developer’s GitHub token. For a repository an admin adds manually, Foreman verifies its full name and numeric GitHub ID with that developer’s token. An admin can submit an existing manual repository through Add repository again to bind its GitHub ID. Workspaces created before Foreman established that identity stay outside the public API. An archived repository leaves the launch catalog. Its owner can still manage and read history for existing workspaces while their repository and box access holds.

For a manual GitHub repository, Foreman records archive and unarchive changes when an admin adds or rechecks it, when a personal API request verifies it, or when the installation sync observes it. Each observation must match the repository’s identity. Service launches and workload credentials use the last recorded status. For a repository outside the installation, an external change takes effect on the next successful admin or personal check. An unavailable repository or a failed check preserves the recorded status.

Foreman records the GitHub repository ID observed when a workspace or service approval is created. Binding a formerly name-only row does not grant access to earlier workspaces or installations. During an upgrade, existing synced IDs can be carried forward. A manual repository whose historical identity cannot be established requires a new service approval or a new workspace for API access. An existing service workspace can renew its read credential for its approved archived primary repository; archived secondary repositories are excluded.

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

**Retry semantics.** Scope the key to the instance, acting identity, client and endpoint. Atomically commit the key, normalized request, environment reservation and operation before dispatch. Concurrent identical submissions converge on the same IDs, including across server restarts. Compare caller inputs before applying mutable defaults. Reusing an accepted key with changed input returns `409 idempotency_conflict`. Validation and capacity failures before acceptance reserve nothing. A replay rechecks visibility. Keep a compact record of each accepted create key for the life of the instance. If the original environment still exists after the operation history expires, a replay returns the original IDs and `operation_history_expired: true`. Read the environment directly at that point. After destruction, an authorized replay of the original create returns `410 original_environment_gone`, including after operation history has expired.

**Restarts.** `restart_affected` recreates the services whose compose configuration uses a secret that has changed since they last came up, and restarts the workspace container. `restart_all` stops and starts every container without recreating any: each process starts again and reads the current `/run/foreman/secrets.env`, and each container keeps the environment it was created with. Both go through the environment's operations collection like start and stop, and need permission for both. They apply to an environment the box has confirmed is running. Anything else returns `409 lifecycle_conflict`, and a start is what it needs. A restart is always queued, `restart_affected` with nothing known to have changed included: whether one happens must not say whether a secret just sent matched the one already applied. A restart follows only the same restart already in flight and conflicts with any other transition, a start included. At dispatch it is authorized like a start: the workspace's owner can restart it through a newer connection than the one that launched it. The current secret files are written to the box under the same authority before the restart runs. Once the restart has been authorized for sending, that connection becomes the one the workspace runs on, so later secret changes are written under it. A restart that is cancelled or refused before then changes nothing.

**What a restart does not see.** `restart_affected` finds its services by the `$NAME` and `${NAME}` references in the compose configuration. A service that takes a secret another way, such as a bare name in an `environment:` list, is not recreated. `restart_all` and a stop and start both mark the current values as applied, though a container that was not recreated still has the environment it was created with. A rebuild in the browser recreates everything.

**Lifecycle responses.** After checking for a replay, return `200` with the environment ID if the target state is already reached and stable. If an active operation is already moving toward it, return `202` with that operation’s ID and location. An opposing action during an active transition returns `409 lifecycle_conflict`. For example, stop during create conflicts, while start during create follows the existing operation.

**Expiry.** Both fields are required when expiry is supplied. Reject a deadline already in the past. Persist the policy with the environment, show it on reads, and execute it once even after a control-plane restart. If the box is offline when due, record the pending action and reconcile it when possible. Once expiry is due, finish the in-flight operation and then apply expiry. Reject new actions that conflict with the due expiry. Expose the cleanup operation through `GET /api/v1/environments/{id}/operations`, including the action, trigger and outcome. Authorized callers can read this history by environment ID after destroy. Keep history for 90 days and logs for 30 days from the completion of each operation, independent of environment destruction. A completed stop policy is consumed so a later manual start can succeed.

**Client behavior.** Collection responses use opaque cursors; logs expose a cursor and indicate truncation. Clients can reconnect using the last cursor. API errors carry a stable code and a human-readable message. Use 401 for an expired or invalid credential, 403 for an unauthorized action on a visible resource, and 404 for an absent or invisible resource. A failed asynchronous build is a terminal operation result available by GET. Clients should tolerate additional response fields within v1.

**Read responses.** Collections return up to 50 items. Repository and box lists use ascending names, environments use ascending IDs, and operation history uses newest creation time first with the operation ID as the tie-breaker. Cursors belong to the same grant and collection and have no independent deadline. Authorization and retention are checked on every page. Log pages contain up to 64 KiB of durable, redacted output. An empty page can be polled again after the agent flushes more output. If the 1 MiB rolling tail overtakes the reader, the next page starts at the retained text and sets `truncated` to true.

A ready workspace has a successful devcontainer setup result for the same container ID that its box currently sees running. A failed sidecar can leave the environment partially running while its workspace is ready. A disconnected box, an unreachable guest, or a box without a fresh workspace report yields unknown readiness. Environment connection fields require `environments:read`, including on a collection response.

The v1 operation history includes create, start, stop, destroy and the two restarts. When Foreman times out an operation it reports a terminal `failed` with error code `operation_timeout`. A late agent result can correct the environment's observed state when that operation still controls it. The public operation keeps its timeout outcome. If workload authorization is withdrawn before dispatch or reconnect, the operation reports a terminal `failed` with `workload_unauthorized`. A late result for an earlier delivery may still reconcile the environment while that public outcome stays final.

## Secrets

A personal connection can manage secrets at the four levels the browser offers: an owner's, a repository's, the caller's own, and one environment's. An environment receives them in that order and a later level wins.

`GET /api/v1/secrets/{scope}/{subject}` lists the names set at one level, with when each last changed. `PATCH` on the same path sets and removes several together. The scope is `owner`, `repo`, `user` or `environment`. The subject is the environment or repository ID, the owner's ID or login, or `me`.

```json
{
  "secrets": [{"name": "DATABASE_URL", "value": "postgres://…"}, {"name": "LOG_LEVEL", "value": "debug"}],
  "unset": ["OLD_TOKEN"]
}
```

**Values go in and never come out.** No response carries a value, including the response to the request that set it. The request log filters the `secrets` field.

**One request, all or nothing.** Every change in a request is saved, or none is. A refused name fails the request with `422 invalid_request` and a message naming it. Removing a name that isn't set is skipped and left out of the response's `unset`. A request holds between one and 100 changes and names each secret once. Repeating a request leaves the same secrets in place, so it needs no idempotency key.

**Who may change what.** The caller's own secrets and the secrets of the caller's own environments need no role. A repository's or an owner's take an admin, as in the browser, and an admin's reach is the same as there: every owner, and any repository their GitHub identity can see. The connection's scope is checked first, so a connection without it gets `403 insufficient_scope` whatever it names. The role and the grant are checked again inside the transaction that writes. A member asking for either gets `403 forbidden` before anything is looked up, so the answer is the same whether or not the repository or owner exists. Another person's environment is `404 resource_not_found`, for an admin too. Service accounts cannot hold the two scopes; they receive the secrets an admin approved for them.

**Running environments.** A change is queued for a running environment's `/run/foreman/secrets.env`, where new shells read it. Processes and compose services already running keep the values they started with. The response lists the caller's running environments the scope reaches under `affected`, for a connection that also holds `environments:list`, and counts other people's in `others_affected`. The `restart_affected` action applies the change, as **Restart affected** does in the browser. A stop and a start is not enough: a start reuses the existing containers, and a container keeps the environment it was created with. A stopped environment picks the new values up when its services are next created.

**Nothing in a response depends on a value.** A restart is queued whatever changed. `affected` lists every environment the scope reaches that is both asked to run and observed running, whether or not what was sent differs from what was there, and a secret's `updated_at` moves on every set. A connection that can write but not read learns nothing about the values already stored.

**Concurrent writers.** Changes to one scope are applied one request at a time, and the last request to finish wins. Nothing detects that a value changed between a client's read and its write. The request is checked again once its turn comes: the connection's grant is still live, an admin is still one, and the environment or repository is still the caller's to reach. Anything that needs GitHub is asked before the write begins, so an outage there fails the request with nothing changed.

Each change is audited with the client and the acting user.

## Attachments

`gh --attach` in an environment uploads through these two requests ([setup guide](../setup/attachments.md)). GitHub rejects attachment uploads made with a GitHub App token, which is the only kind an environment has, so Foreman uploads with an attachment token that an admin set for the repository's owner.

`POST /api/v1/environments/{id}/attachments` opens an upload. Send the file's `name` and `size`. The file type comes from the name's extension: png, jpg, jpeg, gif, webp, svg, mp4, mov or webm. Images can be up to 10 MB and video up to 25 MB. `repository_id` is optional. If sent, it has to be the GitHub ID of the environment's own repository, which is also the default. The response contains the upload's `id` and `chunk_size`.

`PATCH /api/v1/environments/{id}/attachments/{attachment}` sends the next chunk: its `offset`, and its bytes as base64 in `data`. Chunks are sent in order, and every chunk except the last is exactly `chunk_size` bytes. The chunk that completes the file uploads it to GitHub and returns the asset's `url`. Earlier chunks return the number of bytes `received`. Only one request can complete a file, so it's uploaded once.

**The caller needs their own write access.** The attachment token belongs to a machine user. Before opening an upload, and again before sending the file, Foreman asks GitHub (using the acting user's token) whether that user can push to the repository. GitHub applies the same rule to uploads made with a personal token.

| HTTP | Code | What to do |
|---|---|---|
| 409 | `attachments_unavailable` | The owner has no attachment token. An admin needs to add one. |
| 403 | `forbidden` | The acting user doesn't have write access to the repository on GitHub. |
| 503 | `repository_access_unavailable` | Foreman couldn't reach GitHub to check the user's access. When opening an upload, try again. On the final chunk, the upload has been discarded, so send the file again. |
| 404 | `resource_not_found` | The caller can't access the environment or the upload, as elsewhere in the API. This includes an upload that has been idle for ten minutes. On an instance with a GitHub App, it also includes an environment whose owner's GitHub sign-in has expired, or whose repository Foreman can't identify on GitHub. Without a GitHub App, an unidentified repository returns `409 attachments_unavailable`. |
| 422 | `invalid_request` | The message says what's wrong: the file type or size, a different repository, or a malformed chunk. |
| 409 | `attachment_offset_mismatch` | Send the chunk at the offset given in the message. |
| 429 | `too_many_attachments` | The environment has 50 MB or 16 uploads open. Finish one or wait. An upload that's idle for ten minutes stops accepting chunks and no longer counts. |
| 502 | `attachment_upload_failed` | Either GitHub rejected the file (the message says why), or it didn't give a clear answer (a server error or timeout), in which case the message says the file may have been uploaded. In both cases the upload has been discarded, so send the file again as a new upload. |

Once Foreman has accepted the chunk that completes a file, the upload is finished regardless of the response. A request rejected before that point (by a rate limit, for example) leaves the upload unchanged and can be retried. An upload can't be undone on GitHub. If the response was lost, the file may already be there, and sending it again creates a second asset. That's harmless, because an asset isn't visible until something links to it. Every upload GitHub confirmed is audited with the client and the acting user. An upload whose response was lost isn't audited, because Foreman never received its URL.

### Create errors

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

## V1 boundaries

The lifecycle API supports create, start, stop, destroy and the two restarts. Set any expiry when creating the environment. Rebuild, pull and suspend remain browser actions. The administrator registers service credentials, selects workload grants and manages rotation from **Admin → API clients**. Each installation has its own tailnet tag. Tailnet administrators control SSH authorization in deployments that delegate SSH to Tailscale.
