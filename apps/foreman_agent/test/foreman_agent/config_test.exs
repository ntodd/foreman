defmodule ForemanAgent.ConfigTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Config
  alias ForemanAgent.Env.Policy

  test "a box refuses everything unless it opts out" do
    assert Enum.all?(Policy.default_rules(), fn {_rule, action} -> action == :refuse end)
  end

  test "reports the box's policy in the form the join payload carries" do
    config = %Config{policy_rules: Map.merge(Policy.default_rules(), %{privileged: :allow})}

    report = Config.policy_report(config)
    assert report == Map.put(ForemanProtocol.Policy.defaults(), "privileged", "allow")

    assert {:ok, %{policy: ^report}} =
             ForemanProtocol.cast_join(%{
               "agent_version" => "0.1.0",
               "protocol_version" => ForemanProtocol.version(),
               "hostname" => "box-a",
               "os" => "linux",
               "arch" => "x86_64",
               "policy" => report
             })
  end
end
