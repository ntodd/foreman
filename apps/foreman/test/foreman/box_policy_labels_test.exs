defmodule Foreman.BoxPolicyLabelsTest do
  use Foreman.DataCase, async: true

  alias Foreman.Boxes

  test "every rule an agent can loosen has a label, so a box page can show it" do
    for rule <- ForemanProtocol.Policy.rules() do
      box = %Boxes.Box{policy: Map.put(ForemanProtocol.Policy.defaults(), rule, "allow")}
      assert [%{rule: ^rule, label: label}] = Boxes.policy_exceptions(box)
      assert is_binary(label)
    end
  end

  test "a box that allows seccomp=unconfined says so" do
    box = %Boxes.Box{policy: Map.put(ForemanProtocol.Policy.defaults(), "seccomp", "allow")}
    assert [%{label: label}] = Boxes.policy_exceptions(box)
    assert label =~ "seccomp"
  end
end
