import { client } from "./generated/client.gen";
import {
  createEnvironment, getEnvironment, getIdentity, getOAuthMetadata, getOperation,
  getOperationLogs, listBoxes, listEnvironmentOperations, listEnvironments,
  listRepos, obtainToken, operateEnvironment, revokeToken,
} from "./generated/sdk.gen";
import type { ObtainTokenData } from "./generated/types.gen";

declare const process: { env: Record<string, string> };

// These calls must fail type checking if a required grant field is missing.
type TokenBody = ObtainTokenData["body"];
// @ts-expect-error a device grant requires its device code
const incompleteDevice: TokenBody = { grant_type: "urn:ietf:params:oauth:grant-type:device_code", client_id: "cli" };
// @ts-expect-error a refresh grant requires its client ID
const incompleteRefresh: TokenBody = { grant_type: "refresh_token", refresh_token: "token" };

function expectStatus<T>(result: { response?: Response; data?: T }, status: number): T {
  if (result.response?.status !== status) {
    throw new Error(`Expected ${status} from ${result.response?.url}, got ${result.response?.status}`);
  }
  return result.data!;
}

async function run() {
  client.setConfig({ baseUrl: process.env.FOREMAN_ORIGIN });
  expectStatus(await getOAuthMetadata(), 200);
  const basic = process.env.SERVICE_CREDENTIAL;
  const token = expectStatus(await obtainToken({ auth: basic, body: { grant_type: "client_credentials" } }), 200);
  const auth = token.access_token;
  const identity = expectStatus(await getIdentity({ auth }), 200);
  if (identity.kind !== "service_account") throw new Error("Expected a service account");

  expectStatus(await listRepos({ auth }), 200);
  expectStatus(await listBoxes({ auth }), 200);
  expectStatus(await listEnvironments({ auth }), 200);
  const headers = { "Idempotency-Key": crypto.randomUUID() };
  const request = { auth, headers, body: { repo_id: process.env.REPO_ID } };
  const first = await createEnvironment(request);
  const created = expectStatus(first, 202);
  const replay = expectStatus(await createEnvironment(request), 202);
  if (replay.environment_id !== created.environment_id || replay.operation_id !== created.operation_id) {
    throw new Error("Create retry returned different IDs");
  }
  if (first.response?.headers.get("Location") !== `/api/v1/operations/${created.operation_id}`) {
    throw new Error("Create returned an unexpected operation location");
  }

  const environment = { auth, path: { id: created.environment_id } };
  const operation = { auth, path: { id: created.operation_id } };
  expectStatus(await getEnvironment(environment), 200);
  expectStatus(await listEnvironmentOperations(environment), 200);
  expectStatus(await getOperation(operation), 200);
  expectStatus(await getOperationLogs(operation), 200);
  expectStatus(await operateEnvironment({
    ...environment, headers: { "Idempotency-Key": crypto.randomUUID() }, body: { action: "start" },
  }), 202);

  expectStatus(await revokeToken({ auth: basic, body: { token: auth } }), 200);
  expectStatus(await getIdentity({ auth }), 401);
}

void run();
