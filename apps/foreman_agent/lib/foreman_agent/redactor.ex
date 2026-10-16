defmodule ForemanAgent.Redactor do
  @moduledoc """
  Scrubs a command's secret values out of the logs and errors the agent
  sends back.

  Secrets are write-only in the UI, but build output can echo them: the
  devcontainer CLI logs the merged compose config with interpolated
  values, and a lifecycle script can print its environment. The agent
  knows every value a command carried, so it replaces each one before
  anything leaves the box (see `ForemanProtocol.Redaction`).
  """

  alias ForemanProtocol.{Command, Redaction}

  defstruct values: []

  @type t :: %__MODULE__{values: [String.t()]}

  @spec new(Command.t()) :: t()
  def new(%Command{payload: payload}) do
    files =
      payload
      |> Map.get(:files, %{})
      |> Map.drop(["secrets.env", "gitconfig", "notices"])
      |> Map.values()

    env = payload |> Map.get(:compose_env, %{}) |> Map.values()
    registry = payload |> Map.get(:registry_auth, []) |> Kernel.||([]) |> Enum.map(& &1.token)

    %__MODULE__{values: Redaction.prepare(files ++ env ++ registry)}
  end

  @doc "Redacts `text`, and replaces any invalid UTF-8 (events are JSON)."
  @spec redact(t(), String.t()) :: String.t()
  def redact(%__MODULE__{values: values}, text),
    do: values |> Redaction.redact(text) |> ForemanAgent.Text.scrub()

  @doc "Wraps a log function so everything through it is redacted."
  def wrap_log(%__MODULE__{} = r, log), do: fn stream, data -> log.(stream, redact(r, data)) end
end
