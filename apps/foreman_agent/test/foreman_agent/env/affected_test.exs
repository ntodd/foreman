defmodule ForemanAgent.Env.AffectedTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Env.Affected

  # `docker compose config --no-interpolate --format json` output.
  @config %{
    "services" => %{
      "app" => %{"environment" => %{"MIX_ENV" => "dev"}, "image" => "app"},
      "neon" => %{
        "environment" => %{
          "NEON_API_KEY" => "${NEON_API_KEY}",
          "NEON_PROJECT_ID" => "${NEON_PROJECT_ID:-default}",
          "BRANCH" => "$${NOT_A_VAR}"
        }
      },
      "proxy" => %{"command" => ["--token", "$PROXY_TOKEN", "--x", "${OTHER?required}"]},
      "db" => %{"image" => "postgres:18"}
    }
  }

  test "finds services that interpolate a changed variable" do
    assert Affected.services(@config, ["NEON_API_KEY"]) == ["neon"]
    assert Affected.services(@config, ["NEON_PROJECT_ID", "PROXY_TOKEN"]) == ["neon", "proxy"]
    assert Affected.services(@config, ["OTHER"]) == ["proxy"]
  end

  test "ignores escaped dollars" do
    assert Affected.services(@config, ["NOT_A_VAR"]) == []
  end

  test "returns nothing when no service references the variables" do
    assert Affected.services(@config, ["DATABASE_URL"]) == []
    assert Affected.services(@config, []) == []
  end

  test "does not match variable names that are prefixes of others" do
    assert Affected.services(@config, ["NEON"]) == []
  end
end
