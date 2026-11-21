defmodule Foreman.RedactionsRegistryTokensTest do
  @moduledoc """
  The agent reads registry credentials out of `DEVCONTAINERS_OCI_AUTH` a
  token at a time, so one token on its own in a log has to be masked, for
  commands that carry the secret and for ones that don't (`env.logs`).
  """
  use Foreman.DataCase

  alias Foreman.Operations
  alias Foreman.Operations.Redactions
  alias ForemanProtocol.Command

  @token "ghp_0123456789abcdefTOKEN"

  setup do
    user = user_fixture()
    env = environment_fixture(user: user)

    {:ok, _} =
      Foreman.Secrets.put_secret(Foreman.Scope.for_user(user), "user", user, %{
        "name" => "DEVCONTAINERS_OCI_AUTH",
        "value" => "ghcr.io|machine|#{@token},registry.example.com|other|another-token-value"
      })

    op = fn ->
      Operations.create!(%{
        id: Ecto.UUID.generate(),
        environment_id: env.id,
        box_id: env.box_id,
        user_id: user.id,
        action: "logs",
        command: "env.logs",
        args: %{},
        status: "running"
      })
    end

    %{env: env, op: op}
  end

  test "a token alone is masked in the logs of a command that doesn't carry it", %{
    env: env,
    op: op
  } do
    op = op.()
    {:ok, cmd} = Command.new("env.logs", %{env_id: env.id, slug: env.slug}, op_id: op.id)
    :ok = Redactions.put(op.id, cmd, env)

    assert Redactions.redact(op.id, "auth failed for #{@token}\n") ==
             "auth failed for [redacted]\n"

    assert Redactions.redact(op.id, "another-token-value") == "[redacted]"
  end

  test "and when the mask is worked out again from the environment", %{op: op} do
    op = op.()

    assert Redactions.redact(op.id, "auth failed for #{@token}\n") ==
             "auth failed for [redacted]\n"
  end
end
