defmodule ForemanProtocol.PolicyTest do
  use ExUnit.Case, async: true

  alias ForemanProtocol.Policy

  test "every rule refuses by default" do
    assert Map.keys(Policy.defaults()) |> Enum.sort() == Enum.sort(Policy.rules())
    assert Enum.all?(Policy.defaults(), fn {_rule, action} -> action == "refuse" end)
  end

  test "relaxed lists the rules a policy loosens, in rule order" do
    assert Policy.relaxed(Policy.defaults()) == []

    policy = Map.merge(Policy.defaults(), %{"privileged" => "allow", "host_bind" => "warn"})
    assert Policy.relaxed(policy) == [{"host_bind", "warn"}, {"privileged", "allow"}]
  end

  describe "the join payload" do
    @join %{
      "agent_version" => "0.1.0",
      "protocol_version" => 1,
      "hostname" => "box-a",
      "os" => "linux",
      "arch" => "x86_64"
    }

    test "carries the agent's policy" do
      assert {:ok, join} = ForemanProtocol.cast_join(Map.put(@join, "policy", Policy.defaults()))
      assert join.policy == Policy.defaults()
      assert ForemanProtocol.dump_join(join)["policy"] == Policy.defaults()
    end

    test "an agent that doesn't send one joins with an empty policy" do
      assert {:ok, %{policy: policy}} = ForemanProtocol.cast_join(@join)
      assert policy == %{}
    end

    test "unknown rules and actions are rejected" do
      assert {:error, _} =
               ForemanProtocol.cast_join(Map.put(@join, "policy", %{"root" => "allow"}))

      assert {:error, _} =
               ForemanProtocol.cast_join(Map.put(@join, "policy", %{"privileged" => "sure"}))
    end
  end
end
