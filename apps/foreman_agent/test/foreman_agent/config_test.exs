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

  describe "FOREMAN_ISOLATION" do
    test "is containers unless a box asks for VMs" do
      assert Config.parse_isolation(nil) == :container
      assert Config.parse_isolation("") == :container
      assert Config.parse_isolation("container") == :container
      assert Config.parse_isolation("vm") == :vm
    end

    test "a typo stops the agent rather than quietly using containers" do
      assert_raise ArgumentError, ~r/FOREMAN_ISOLATION/, fn -> Config.parse_isolation("vms") end
    end

    test "inside a VM everything is allowed unless the box tightens it" do
      config =
        %Config{vm_policy_rules: %{privileged: :warn}}
        |> Map.update!(:vm_policy_rules, &Map.merge(Config.vm_default_rules(), &1))

      assert config.vm_policy_rules.privileged == :warn
      assert config.vm_policy_rules.host_bind == :allow
    end

    # The box's own policy checks nothing on a VM box: every compose
    # project runs inside an environment's VM.
    test "a VM box reports the policy inside its VMs, the one environments get" do
      config = %Config{
        isolation: :vm,
        policy_rules: Policy.default_rules(),
        vm_policy_rules: Map.put(Config.vm_default_rules(), :privileged, :warn)
      }

      report = Config.policy_report(config)
      assert report["privileged"] == "warn"
      assert report["host_bind"] == "allow"
    end
  end
end
