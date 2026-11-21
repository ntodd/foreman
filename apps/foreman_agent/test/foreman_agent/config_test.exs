defmodule ForemanAgent.ConfigTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Config

  test "the agent has no Node or devcontainer CLI of its own to find" do
    refute Map.has_key?(%Config{}, :node)
    refute Map.has_key?(%Config{}, :devcontainer)
    refute function_exported?(Config, :tools, 2)
  end
end
