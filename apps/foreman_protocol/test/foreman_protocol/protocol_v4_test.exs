defmodule ForemanProtocol.ProtocolV4Test do
  @moduledoc """
  Protocol 4: `env.start` and `env.restart` can carry `registry_auth`,
  like `env.create` and `env.rebuild`. Both run `devcontainer up`, which
  resolves the repo's features again, and a private one needs the
  credentials.
  """
  use ExUnit.Case, async: true

  alias ForemanProtocol.Command

  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @auth %{"host" => "ghcr.io", "username" => "machine", "token" => "ghp_registry"}

  @commands %{
    "env.start" => %{"env_id" => @env_id, "slug" => "storefront-2"},
    "env.restart" => %{"env_id" => @env_id, "slug" => "storefront-2", "mode" => "all"}
  }

  test "this build speaks protocol 4 and still accepts agents on 3" do
    assert ForemanProtocol.version() == 4
    assert ForemanProtocol.compatible?(4)
    assert ForemanProtocol.compatible?(3)
    refute ForemanProtocol.compatible?(2)
  end

  for {type, payload} <- @commands do
    describe "#{type} registry_auth" do
      test "carries registry credentials" do
        payload = Map.put(unquote(Macro.escape(payload)), "registry_auth", [@auth])
        assert {:ok, cmd} = Command.new(unquote(type), payload)

        assert [%{host: "ghcr.io", username: "machine", token: "ghp_registry"}] =
                 cmd.payload.registry_auth
      end

      test "is absent unless set, so an agent on protocol 3 sees the command it knows" do
        assert {:ok, cmd} = Command.new(unquote(type), unquote(Macro.escape(payload)))
        refute Map.has_key?(cmd.payload, :registry_auth)
        refute Map.has_key?(Command.to_wire(cmd)["payload"], "registry_auth")
      end

      test "keeps the token out of inspect" do
        payload = Map.put(unquote(Macro.escape(payload)), "registry_auth", [@auth])
        assert {:ok, cmd} = Command.new(unquote(type), payload)
        refute inspect(cmd) =~ "ghp_registry"
      end
    end
  end
end
