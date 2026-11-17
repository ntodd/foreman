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
  # 4: env.start and env.restart can carry `registry_auth`.
  # 5: box.restart reboots the box; box.reboot says whether the agent can
  # (`can_restart`) and which boot it's on (`boot_id`), which the command
  # names.
  # 6: every environment runs in a VM of its own; the join reports whether
  # the box can run them (`vm`), and no longer a compose policy (`policy`);
  # env.suspend, and environments reported suspended; box.prebuild and
  # box.prebuild.delete, and env.create's `prebuild_id`.
  @version 6

  # Usually the protocol before this one is accepted too. Protocol 5
  # agents run environments on the box's shared Docker, which protocol 6
  # removed, so they're refused until the install script is run again.
  @oldest 6

  @doc "The protocol version this build speaks."
  def version, do: @version

  @doc "Whether the control plane accepts an agent speaking `version`."
  def compatible?(version) when is_integer(version), do: version in @oldest..@version//1
  def compatible?(_), do: false

  @doc "The oldest protocol the control plane accepts."
  def oldest, do: @oldest

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
    # Whether the box's firewall, which keeps environments off the tailnet
    # as the box, is loaded and the one this agent ships with; and whether
    # it leaves Docker's default bridge, where image builds run, out.
    firewall: {{:enum, ~w(active outdated missing)}, []},
    firewall_default_bridge: {{:enum, ~w(filtered reaches_tailnet)}, []},
    # Protocol 6. Whether the box can run environment VMs, and why not when
    # it can't; whether they run nested (the box is a VM itself); whether
    # new environments' disks are reflinks or full copies.
    vm:
      {{:object,
        ready: {:boolean, required: true},
        reason: {:text, []},
        nested: {:boolean, default: false},
        reflink: {:boolean, default: false}}, []}
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
