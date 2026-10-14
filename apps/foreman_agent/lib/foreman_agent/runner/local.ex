defmodule ForemanAgent.Runner.Local do
  @moduledoc """
  `ForemanAgent.Runner` on MuonTrap, so cancelling an operation (killing
  its process) takes the whole child process tree with it.
  """
  @behaviour ForemanAgent.Runner

  alias ForemanAgent.Runner.Collector

  @default_keep 65_536

  @impl true
  def run(command, args, opts) do
    case System.find_executable(command) do
      nil ->
        {:error, {:not_found, command}}

      path ->
        keep = Keyword.get(opts, :keep, @default_keep)
        on_output = Keyword.get(opts, :on_output, fn _ -> :ok end)

        cmd_opts =
          [
            env: child_env(Keyword.get(opts, :env, %{})),
            stderr_to_stdout: true,
            into: %Collector{keep: keep, on_output: on_output}
          ] ++ Keyword.take(opts, [:cd, :timeout])

        {collector, status} = MuonTrap.cmd(path, args, cmd_opts)
        {:ok, %{status: status, output: Collector.output(collector)}}
    end
  end

  @base ~w(PATH HOME LANG LC_ALL TZ DOCKER_HOST SSL_CERT_FILE SSL_CERT_DIR
           HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy)

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
