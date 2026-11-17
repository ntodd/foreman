defmodule ForemanAgent.Guest do
  @moduledoc """
  The agent in guest mode (`FOREMAN_AGENT_MODE=guest`): the agent inside
  an environment's VM.

  It runs the same environment code an agent ran on a shared box, against
  the VM's own Docker, and takes its commands from the agent on the box
  over `ForemanAgent.Channel` instead of from the control plane. It holds
  nothing the environment doesn't already have: its secrets, its clone
  and its containers. Commands the box handles itself (updates, reboots)
  are refused here.
  """

  alias ForemanAgent.{Config, Handler, Ports, Runner}
  alias ForemanAgent.Guest.Reclaim
  alias ForemanProtocol.Command

  require Logger

  # The host's clock is the one that matters (the agent's signed connects
  # and anything time-based in an environment). A VM's clock stops while
  # it's suspended, so the guest steps to the host's when it's this far out.
  @max_skew_ms 2_000

  @max_hosts 100

  @doc "Runs a command from the host. See `ForemanAgent.Handler`."
  @spec handle(Command.t(), (String.t(), String.t() -> any())) ::
          {:ok, map()} | {:error, String.t()} | {:error, String.t(), map()}
  def handle(%Command{type: "env." <> _} = cmd, log), do: Handler.handle(cmd, log)
  def handle(%Command{type: "box.gc"} = cmd, log), do: Handler.handle(cmd, log)

  def handle(%Command{type: type}, _log),
    do: {:error, "#{type} isn't run in an environment's VM"}

  @doc "The queries the host can make of the guest."
  def queries do
    %{
      "inventory" => fn ->
        with {:ok, envs} <- Handler.inventory(), do: {:ok, stringify(envs)}
      end,
      "ports" => fn ->
        case Ports.collect(Handler.ctx(fn _, _ -> :ok end), %{}) do
          {:error, message} -> {:error, message}
          {report, _names} -> {:ok, stringify(report)}
        end
      end,
      "reclaim" => &Reclaim.run/1
    }
  end

  @doc """
  Steps the clock to the host's time when it's more than two seconds out.
  `set` does the stepping (by default `date`, as root in the guest).
  """
  @spec sync_clock(integer(), (integer() -> any())) :: :ok | :stepped
  def sync_clock(host_now_ms, set \\ &set_clock/1) when is_integer(host_now_ms) do
    if abs(host_now_ms - System.os_time(:millisecond)) > @max_skew_ms do
      set.(host_now_ms)
      :stepped
    else
      :ok
    end
  end

  defp set_clock(ms) do
    stamp =
      "@#{div(ms, 1000)}.#{ms |> rem(1000) |> Integer.to_string() |> String.pad_leading(3, "0")}"

    case Runner.run("date", ["-u", "-s", stamp], timeout: 5_000) do
      {:ok, %{status: 0}} -> :ok
      other -> Logger.warning("couldn't set the clock: #{inspect(other)}")
    end
  end

  @doc """
  Takes the settings the host passes on (the clone hosts its box allows)
  into this agent's config. Anything malformed is left as it was.
  """
  @spec configure(map()) :: :ok
  def configure(config) when is_map(config) do
    current = Config.get()

    Config.put(%{
      current
      | allowed_git_hosts: hosts(config["allowed_git_hosts"], current.allowed_git_hosts),
        insecure_git_hosts: hosts(config["insecure_git_hosts"], current.insecure_git_hosts)
    })

    :ok
  end

  defp hosts(list, current) when is_list(list) and length(list) <= @max_hosts do
    if Enum.all?(list, &host?/1), do: list, else: current
  end

  defp hosts(_, current), do: current

  defp host?(host),
    do: is_binary(host) and byte_size(host) <= 255 and host =~ ~r/\A[A-Za-z0-9.\-:\[\]]+\z/

  defp stringify(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
