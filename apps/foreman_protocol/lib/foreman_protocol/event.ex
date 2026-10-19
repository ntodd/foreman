defmodule ForemanProtocol.Event do
  @moduledoc """
  An event an agent sends to the control plane: operation progress and
  results, box inventory, stats and metrics, and observed environment state.
  """

  alias ForemanProtocol.Schema

  @enforce_keys [:type, :payload]
  defstruct [:type, :payload]

  @type t :: %__MODULE__{type: String.t(), payload: map()}

  @env_states ["running", "stopped", "partial", "missing"]

  @specs %{
    "op.accepted" => [op_id: {:uuid, required: true}],
    "op.log" => [
      op_id: {:uuid, required: true},
      stream: {{:enum, ["stdout", "stderr", "info"]}, required: true},
      data: {:text, required: true}
    ],
    "op.result" => [
      op_id: {:uuid, required: true},
      status: {{:enum, ["ok", "error"]}, required: true},
      result: {:json, default: %{}},
      error: {:text, []}
    ],
    "box.inventory" => [
      environments:
        {{:list,
          {:object,
           env_id: {:uuid, required: true},
           slug: {:slug, required: true},
           state: {{:enum, @env_states}, required: true},
           containers:
             {{:list,
               {:object,
                id: {:string, required: true},
                service: {:string, required: true},
                state: {:string, required: true}}}, default: []}}}, required: true}
    ],
    # The box's firewall, when it changes between joins (see the join's
    # fields of the same names).
    "box.firewall" => [
      firewall: {{:enum, ~w(active outdated missing)}, required: true},
      firewall_default_bridge: {{:enum, ~w(filtered reaches_tailnet)}, []}
    ],
    "box.stats" => [
      capacity:
        {{:object,
          cpus: {:number, required: true},
          memory_mb: {:number, required: true},
          disk_mb: {:number, default: 0},
          disk_free_mb: {:number, default: 0}}, required: true},
      environments:
        {{:map_of, :uuid,
          {:object, cpu_percent: {:number, default: 0}, memory_mb: {:number, default: 0}}},
         default: %{}}
    ],
    # Host-wide usage, sampled every few seconds. `at` is the agent's
    # Unix time in seconds; cpu_percent is of the whole box (0-100).
    "box.metrics" => [
      at: {:integer, required: true},
      cpu_percent: {:number, required: true},
      load1: {:number, default: 0},
      memory_total_mb: {:integer, required: true},
      memory_used_mb: {:integer, required: true},
      swap_total_mb: {:integer, default: 0},
      swap_used_mb: {:integer, default: 0},
      disk_total_mb: {:integer, required: true},
      disk_used_mb: {:integer, required: true}
    ],
    "env.state" => [
      env_id: {:uuid, required: true},
      state: {{:enum, @env_states}, required: true}
    ]
  }

  def types, do: Map.keys(@specs)
  def env_states, do: @env_states

  @spec new(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def new(type, payload) do
    case Map.fetch(@specs, type) do
      {:ok, spec} ->
        with {:ok, payload} <- Schema.cast(payload, spec) do
          {:ok, %__MODULE__{type: type, payload: payload}}
        end

      :error ->
        {:error, {:unknown_type, type}}
    end
  end

  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{type: type, payload: payload}) do
    %{"type" => type, "payload" => Schema.dump(payload, Map.fetch!(@specs, type))}
  end

  @spec from_wire(term()) :: {:ok, t()} | {:error, term()}
  def from_wire(%{"type" => type, "payload" => payload}) when is_binary(type),
    do: new(type, payload)

  def from_wire(_), do: {:error, :malformed}
end
