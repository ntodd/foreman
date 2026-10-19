defmodule ForemanProtocol do
  @moduledoc """
  The contract between the Foreman control plane and its agents.

  Both sides depend on this library, so a message one side builds is
  validated by the same code on the other.
  """

  alias ForemanProtocol.Schema

  # 2: env.secrets.write can `keep` files; the seccomp policy rule.
  # 3: env.create and env.rebuild can carry a user's own `features`;
  # env.rebuild can `pull` (fast-forward the clone) first; the gpu
  # policy rule; the join reports the box's firewall (`firewall`,
  # `firewall_default_bridge`), and box.firewall when it changes.
  @version 3

  @doc "The protocol version this build speaks."
  def version, do: @version

  @doc "The control plane accepts the current protocol and the one before it."
  def compatible?(version) when is_integer(version), do: version in [@version, @version - 1]
  def compatible?(_), do: false

  @join_spec [
    agent_version: {:version, required: true},
    protocol_version: {:integer, required: true},
    hostname: {:string, required: true},
    os: {:string, required: true},
    arch: {:string, required: true},
    # The Foreman feature the agent installs. Agents before it reported
    # this leave it out.
    feature_version: {:version, []},
    in_flight: {{:list, :uuid}, default: []},
    policy:
      {{:map_of, {:enum, ForemanProtocol.Policy.rules()},
        {:enum, ForemanProtocol.Policy.actions()}}, default: %{}},
    # Whether the box's firewall, which keeps environments off the tailnet
    # as the box, is loaded and the one this agent ships with; and whether
    # it leaves Docker's default bridge, where image builds run, out.
    firewall: {{:enum, ~w(active outdated missing)}, []},
    firewall_default_bridge: {{:enum, ~w(filtered reaches_tailnet)}, []}
  ]

  @doc "Validates the payload an agent sends when it joins its topic."
  def cast_join(payload), do: Schema.cast(payload, @join_spec)

  def dump_join(join), do: Schema.dump(join, @join_spec)

  @doc "A random (v4) UUID."
  def uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = <<a::48, 4::4, b::12, 2::2, c::62>>

    [u0, u1, u2, u3, u4]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {v, n} ->
      v |> Integer.to_string(16) |> String.pad_leading(n, "0")
    end)
    |> String.downcase()
  end
end
