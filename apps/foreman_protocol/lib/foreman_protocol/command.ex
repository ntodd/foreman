defmodule ForemanProtocol.Command do
  @moduledoc """
  A command the control plane sends to an agent.

  The vocabulary is fixed (see `types/0`). There is no generic `exec`:
  every command maps to one code path on the agent, and every payload is
  validated against its spec on both sides of the socket.
  """

  alias ForemanProtocol.Schema

  @enforce_keys [:op_id, :type, :payload]
  defstruct [:op_id, :type, :payload]

  @type t :: %__MODULE__{op_id: String.t(), type: String.t(), payload: map()}

  @env [env_id: {:uuid, required: true}, slug: {:slug, required: true}]

  @registry_auth {{:list,
                   {:object,
                    host: {:hostname, required: true},
                    username: {:string, required: true},
                    token: {:string, required: true}}}, []}

  @up_spec @env ++
             [
               repo: {:repo, required: true},
               clone_url: {:git_url, required: true},
               branch: {:git_ref, required: true},
               config_path: {:relative_path, default: ".devcontainer/devcontainer.json"},
               files: {:files, default: %{}},
               compose_env: {:env_map, default: %{}},
               limits:
                 {{:object, cpus: {:positive_number, []}, memory_mb: {:integer, []}},
                  default: %{}},
               dotfiles:
                 {{:object,
                   repository: {:https_url, required: true},
                   install_command: {:string, []},
                   target_path: {:string, []}}, []},
               # Protocol 3, and absent unless the user has features.
               features: {ForemanProtocol.Feature.type(), []},
               tailscale:
                 {{:object,
                   enabled: {:boolean, default: false}, tags: {{:list, :ts_tag}, default: []}},
                  default: %{}},
               registry_auth: @registry_auth
             ]

  @specs %{
    "env.create" => @up_spec,
    # `pull`: fast-forward the clone to its branch first. Protocol 3, and
    # absent unless set.
    "env.rebuild" => @up_spec ++ [pull: {:boolean, []}],
    # `registry_auth`: devcontainer up resolves the repo's features again.
    # Protocol 4, and absent unless set.
    "env.start" => @env ++ [compose_env: {:env_map, default: %{}}, registry_auth: @registry_auth],
    "env.stop" => @env,
    "env.restart" =>
      @env ++
        [
          mode: {{:enum, ["affected", "all"]}, required: true},
          changed: {{:list, :env_name}, default: []},
          compose_env: {:env_map, default: %{}},
          # Protocol 4, and absent unless set (see env.start).
          registry_auth: @registry_auth
        ],
    "env.destroy" => @env,
    # `keep`: files to leave as they are rather than delete for being
    # missing from `files`. Protocol 2, and absent unless set: a protocol 1
    # agent refuses fields it doesn't know.
    "env.secrets.write" => [
      env_id: {:uuid, required: true},
      files: {:files, required: true},
      keep: {{:list, {:enum, Schema.secret_files()}}, []}
    ],
    "env.logs" => @env ++ [service: {:service_name, []}, tail: {:integer, default: 200}],
    "env.git_status" => @env,
    # Runs an action of a connect hook the environment reported (see
    # `ForemanProtocol.Connect`). Sent only to agents that reported hooks.
    "env.connect" =>
      @env ++ [hook: {:connect_name, required: true}, action: {:connect_name, required: true}],
    "box.inventory" => [],
    "box.stats" => [],
    "box.gc" => [],
    "op.cancel" => [target_op_id: {:uuid, required: true}],
    "agent.update" => [
      version: {:version, required: true},
      url: {:url, required: true},
      sha256: {:sha256, required: true},
      signature: {:base64, required: true}
    ]
  }

  @redacted [:files, :compose_env, :registry_auth]

  @doc "All command types."
  def types, do: Map.keys(@specs)

  @doc "The payload spec for a command type."
  def spec(type), do: Map.fetch!(@specs, type)

  @spec new(String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(type, payload, opts \\ []) do
    with {:ok, spec} <- fetch_spec(type),
         {:ok, payload} <- Schema.cast(payload, spec) do
      {:ok,
       %__MODULE__{
         op_id: Keyword.get_lazy(opts, :op_id, &ForemanProtocol.uuid/0),
         type: type,
         payload: payload
       }}
    end
  end

  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = cmd) do
    %{
      "op_id" => cmd.op_id,
      "type" => cmd.type,
      "payload" => Schema.dump(cmd.payload, spec(cmd.type))
    }
  end

  @spec from_wire(term()) :: {:ok, t()} | {:error, term()}
  def from_wire(%{"op_id" => op_id, "type" => type, "payload" => payload})
      when is_binary(op_id) do
    with {:ok, _} <- Schema.cast(%{"op_id" => op_id}, op_id: {:uuid, required: true}) do
      new(type, payload, op_id: op_id)
    end
  end

  def from_wire(_), do: {:error, :malformed}

  defp fetch_spec(type) do
    case Map.fetch(@specs, type) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unknown_type, type}}
    end
  end

  @doc false
  def redacted_keys, do: @redacted

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(cmd, opts) do
      payload =
        Enum.reduce(ForemanProtocol.Command.redacted_keys(), cmd.payload, fn key, acc ->
          if Map.has_key?(acc, key), do: Map.put(acc, key, :redacted), else: acc
        end)

      concat([
        "#ForemanProtocol.Command<",
        to_doc(cmd.type, opts),
        " ",
        to_doc(cmd.op_id, opts),
        " ",
        to_doc(payload, opts),
        ">"
      ])
    end
  end
end
