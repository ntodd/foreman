defmodule ForemanProtocol.ProtocolV2Test do
  @moduledoc """
  Protocol 2: `env.secrets.write` can name files the agent should leave
  as they are (a GitHub token the control plane couldn't renew just now),
  and seccomp had its own policy rule (gone with the policy in protocol 6).
  """
  use ExUnit.Case, async: true

  alias ForemanProtocol.Command

  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  describe "env.secrets.write keep" do
    test "names secret files the agent should leave alone" do
      assert {:ok, cmd} =
               Command.new("env.secrets.write", %{
                 "env_id" => @env_id,
                 "files" => %{"secrets.env" => ""},
                 "keep" => ["github-token"]
               })

      assert cmd.payload.keep == ["github-token"]
    end

    test "is absent unless set, so a protocol 1 agent sees the command it knows" do
      assert {:ok, cmd} =
               Command.new("env.secrets.write", %{"env_id" => @env_id, "files" => %{}})

      refute Map.has_key?(cmd.payload, :keep)
      assert Map.keys(Command.to_wire(cmd)["payload"]) |> Enum.sort() == ["env_id", "files"]
    end

    test "only names files from the allowlist" do
      assert {:error, errors} =
               Command.new("env.secrets.write", %{
                 "env_id" => @env_id,
                 "files" => %{},
                 "keep" => ["../identity.json"]
               })

      assert [{"keep" <> _, _} | _] = errors
    end
  end
end
