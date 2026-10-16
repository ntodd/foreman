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

  describe "FOREMAN_POLICY" do
    test "accepts every rule the protocol knows, seccomp included" do
      assert Config.parse_policy(["seccomp=allow", "host_bind=warn"]) == %{
               seccomp: :allow,
               host_bind: :warn
             }

      for rule <- ForemanProtocol.Policy.rules() do
        assert Config.parse_policy(["#{rule}=allow"]) == %{String.to_atom(rule) => :allow}
      end
    end

    test "refuses rules and actions it doesn't know, so a typo can't pass silently" do
      assert_raise ArgumentError, ~r/seccom=allow/, fn ->
        Config.parse_policy(["seccom=allow"])
      end

      assert_raise ArgumentError, ~r/maybe/, fn -> Config.parse_policy(["seccomp=maybe"]) end
    end

    test "a seccomp loosening is reported to the control plane" do
      config = %Config{policy_rules: Map.merge(Policy.default_rules(), %{seccomp: :allow})}
      assert Config.policy_report(config)["seccomp"] == "allow"
    end
  end
end
