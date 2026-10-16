defmodule ForemanProtocol.Policy do
  @moduledoc """
  What an agent accepts from a repo's compose files and devcontainer
  config before it starts an environment.

  Every rule refuses by default. A box loosens a rule with
  `FOREMAN_POLICY` on its agent, the agent reports its policy when it
  joins, and the control plane flags any box that has loosened one.
  """

  @rules ~w(host_bind host_file docker_socket devices privileged host_namespace seccomp compose_keys)
  @actions ~w(refuse warn allow)

  def rules, do: @rules
  def actions, do: @actions

  @doc "The policy a box has unless it says otherwise: every rule refuses."
  def defaults, do: Map.new(@rules, &{&1, "refuse"})

  @doc "The rules a policy loosens from the default, in rule order."
  def relaxed(policy) when is_map(policy) do
    for rule <- @rules, (action = policy[rule]) in ["warn", "allow"], do: {rule, action}
  end
end
