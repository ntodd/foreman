defmodule ForemanAgent.Runner.Local do
  @moduledoc """
  `ForemanAgent.Runner` on MuonTrap.

  Cancelling an operation, or a command running past its `:timeout`, kills
  the command's whole process tree (`ForemanAgent.Runner.Tree`).
  """
  @behaviour ForemanAgent.Runner

  alias ForemanAgent.Runner.{Collector, TimedCommand}

  @default_keep 65_536
  # muontrap leaves the command its own stdin, which carries the acks that
  # let it forward more output. A command that reads stdin (the devcontainer
  # CLI does, during lifecycle commands) swallows them; muontrap then stops
  # forwarding, and drops what's left once the command exits.
  @empty_stdin ~s(exec "$0" "$@" </dev/null)

  @impl true
  def run(command, args, opts) do
    case System.find_executable(command) do
      nil ->
        {:error, {:not_found, command}}

      path ->
        keep = Keyword.get(opts, :keep, @default_keep)
        on_output = Keyword.get(opts, :on_output, fn _ -> :ok end)

        collector = %Collector{keep: keep, on_output: on_output}

        cmd_opts =
          [
            env: child_env(Keyword.get(opts, :env, %{})),
            stderr_to_stdout: true
          ] ++ Keyword.take(opts, [:cd])

        args = ["-c", @empty_stdin, path | args]

        {collector, status} =
          case opts[:timeout] do
            timeout when timeout in [nil, :infinity] ->
              MuonTrap.cmd("/bin/sh", args, [{:into, collector} | cmd_opts])

            timeout ->
              port = TimedCommand.open("/bin/sh", args, cmd_opts)
              TimedCommand.await(port, collector, timeout)
          end

        {:ok, %{status: status, output: Collector.output(collector)}}
    end
  end

  @base ~w(PATH HOME LANG LC_ALL TZ DOCKER_HOST SSL_CERT_FILE SSL_CERT_DIR
           HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy)

  @doc """
  The environment a command given `env` runs with: `env` over the small
  base that's inherited.
  """
  @spec visible_env(map()) :: %{String.t() => String.t()}
  def visible_env(env) do
    inherited = System.get_env() |> Map.take(@base)
    given = for {name, value} <- child_env(env), is_binary(value), into: %{}, do: {name, value}
    Map.merge(inherited, given)
  end

  @doc false
  # Unsets everything inherited except a small base, then applies `env`.
  def child_env(env) do
    inherited = System.get_env()
    unset = for {k, _} <- inherited, k not in @base, not Map.has_key?(env, k), do: {k, nil}

    base = %{
      "LANG" => inherited["LANG"] || "C.UTF-8",
      "NO_COLOR" => "1",
      "GIT_TERMINAL_PROMPT" => "0"
    }

    unset ++ Enum.to_list(Map.merge(base, env))
  end
end
