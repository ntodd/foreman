defmodule ForemanAgent.Runner do
  @moduledoc """
  Runs external commands (git, docker, the devcontainer CLI).

  Commands get an argv, never a shell string, and a clean environment:
  only what the caller passes plus a small base, so nothing from the
  agent's own environment (its join token, release variables) leaks into
  a child. Output (stdout and stderr merged) streams to `:on_output` as it
  arrives; the result keeps the tail.

  Options:
    * `:env` - map of variables for the child
    * `:cd` - working directory
    * `:on_output` - `fn binary -> any end`, called per chunk
    * `:keep` - bytes of output to keep in the result (default 64 KiB)
    * `:timeout` - milliseconds (default: none)
  """

  @type result :: %{status: non_neg_integer() | :timeout, output: binary()}

  @callback run(command :: String.t(), args :: [String.t()], opts :: keyword()) ::
              {:ok, result()} | {:error, term()}

  def impl, do: Application.get_env(:foreman_agent, :runner, ForemanAgent.Runner.Local)

  def run(command, args, opts \\ []), do: impl().run(command, args, opts)
end
