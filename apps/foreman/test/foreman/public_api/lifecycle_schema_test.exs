defmodule Foreman.PublicAPI.LifecycleSchemaTest do
  use Foreman.DataCase

  alias Foreman.Environments.Environment
  alias Foreman.Operations.Operation

  test "expiry and originating grant persist independently of operation history" do
    env = environment_fixture()
    at = DateTime.utc_now()
    grant = Ecto.UUID.generate()
    env |> change(expiry_action: "destroy", expiry_at: at, api_grant_id: grant) |> Repo.update!()

    assert %{
             expiry_action: "destroy",
             expiry_at: ^at,
             api_grant_id: ^grant,
             expiry_consumed_at: nil
           } = Repo.get!(Environment, env.id)

    op =
      Foreman.Operations.create!(%{
        environment_id: env.id,
        box_id: env.box_id,
        action: "stop",
        command: "env.stop"
      })

    assert %{trigger: "request", api_grant_id: nil} = Repo.get!(Operation, op.id)
  end
end
