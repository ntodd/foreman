defmodule ForemanProtocol do
  @moduledoc """
  The contract between the Foreman control plane and its agents.

  Both sides depend on this library, so a message one side builds is
  validated by the same code on the other.
  """

  alias ForemanProtocol.Schema

  # 2: env.secrets.write can `keep` files; the seccomp policy rule.
  # 3: the join says how the box isolates environments.
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
    in_flight: {{:list, :uuid}, default: []},
    policy:
      {{:map_of, {:enum, ForemanProtocol.Policy.rules()},
        {:enum, ForemanProtocol.Policy.actions()}}, default: %{}},
    # Containers on the box's own Docker, or each environment in its own
    # VM. Agents before protocol 3 only ran containers.
    isolation: {{:enum, ["container", "vm"]}, default: "container"}
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
