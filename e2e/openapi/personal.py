"""Use only generated requests and models for a headless personal connection."""

import os

from pyclient import AuthenticatedClient, Client
from pyclient.api.default import (
    get_identity,
    get_o_auth_metadata,
    obtain_token,
    request_device_code,
    revoke_token,
)
from pyclient.models import (
    DeviceCodeGrant,
    RefreshTokenGrant,
    RequestDeviceCodeBody,
    RevokeTokenBody,
)


origin = os.environ["FOREMAN_ORIGIN"]
public = Client(base_url=origin)
cli = "foreman-cli"
grant_type = "urn:ietf:params:oauth:grant-type:device_code"


def exchange(body, status):
    response = obtain_token.sync_detailed(client=public, body=body)
    assert response.status_code == status, response.status_code
    return response.parsed


assert get_o_auth_metadata.sync_detailed(client=public).status_code == 200
device = request_device_code.sync(
    client=public, body=RequestDeviceCodeBody(client_id=cli, scope="repos:list")
)
pending = exchange(
    DeviceCodeGrant(
        grant_type=grant_type, client_id=cli, device_code=device.device_code
    ),
    400,
)
assert pending.error == "authorization_pending"

approved = DeviceCodeGrant(
    grant_type=grant_type, client_id=cli, device_code=os.environ["APPROVED_DEVICE_CODE"]
)
tokens = exchange(approved, 200)
rotated = exchange(
    RefreshTokenGrant(
        grant_type="refresh_token", client_id=cli, refresh_token=tokens.refresh_token
    ),
    200,
)
assert rotated.refresh_token and rotated.refresh_token != tokens.refresh_token

user = AuthenticatedClient(base_url=origin, token=rotated.access_token)
assert get_identity.sync(client=user).kind.value == "user"
logout = RevokeTokenBody(token=rotated.refresh_token, client_id=cli)
assert revoke_token.sync_detailed(client=public, body=logout).status_code == 200
assert get_identity.sync_detailed(client=user).status_code == 401
