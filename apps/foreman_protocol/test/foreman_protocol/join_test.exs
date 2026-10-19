defmodule ForemanProtocol.JoinTest do
  use ExUnit.Case, async: true

  @join %{
    "agent_version" => "0.4.0",
    "protocol_version" => ForemanProtocol.version(),
    "hostname" => "box-a",
    "os" => "linux",
    "arch" => "x86_64"
  }

  describe "feature_version" do
    test "is the version of the Foreman feature the agent installs" do
      assert {:ok, %{feature_version: "1.1.0"}} =
               ForemanProtocol.cast_join(Map.put(@join, "feature_version", "1.1.0"))
    end

    test "is absent from an agent that doesn't report it" do
      assert {:ok, join} = ForemanProtocol.cast_join(@join)
      refute Map.has_key?(join, :feature_version)
    end

    test "must be a version" do
      assert {:error, [{"feature_version", _}]} =
               ForemanProtocol.cast_join(Map.put(@join, "feature_version", "latest"))
    end
  end
end
