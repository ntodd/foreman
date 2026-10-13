defmodule ForemanAgent.RedactorTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Redactor
  alias ForemanProtocol.Command

  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  defp create(overrides \\ %{}) do
    {:ok, cmd} =
      Command.new(
        "env.create",
        Map.merge(
          %{
            "env_id" => @env_id,
            "slug" => "storefront-2",
            "repo" => "ntodd/storefront",
            "clone_url" => "https://github.com/ntodd/storefront.git",
            "branch" => "main",
            "files" => %{
              "github-token" => "ghs_tokenvalue123",
              "ts-authkey" => "tskey-auth-abcdef"
            },
            "compose_env" => %{
              "NEON_API_KEY" => "neon_secret_value",
              "SHORT" => "on",
              "PORT" => "4000"
            },
            "registry_auth" => [
              %{"host" => "ghcr.io", "username" => "bot", "token" => "ghp_registrytoken"}
            ]
          },
          overrides
        )
      )

    cmd
  end

  test "redacts every secret value the command carries" do
    r = Redactor.new(create())

    text =
      "token ghs_tokenvalue123, key tskey-auth-abcdef, neon=neon_secret_value, reg ghp_registrytoken"

    redacted = Redactor.redact(r, text)

    refute redacted =~ "ghs_tokenvalue123"
    refute redacted =~ "tskey-auth-abcdef"
    refute redacted =~ "neon_secret_value"
    refute redacted =~ "ghp_registrytoken"
    assert redacted =~ "[redacted]"
  end

  test "leaves short values alone so ordinary output stays readable" do
    r = Redactor.new(create())
    assert Redactor.redact(r, "listening on 4000, flag on") == "listening on 4000, flag on"
  end

  test "redacts each line of a multi-line value" do
    key = "-----BEGIN KEY-----\nabcdefghijklmnop\n-----END KEY-----"
    r = Redactor.new(create(%{"compose_env" => %{"SSH_KEY" => key}}))
    refute Redactor.redact(r, "got abcdefghijklmnop here") =~ "abcdefghijklmnop"
  end

  test "commands without secrets redact nothing" do
    {:ok, cmd} = Command.new("box.inventory", %{})
    r = Redactor.new(cmd)
    assert Redactor.redact(r, "anything") == "anything"
  end
end
