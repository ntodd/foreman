defmodule ForemanProtocol.Redaction do
  @moduledoc """
  Replaces known secret values in text. Shared by the agent (which
  redacts what a command carried before output leaves the box) and the
  control plane (which redacts an environment's secrets from everything
  it stores or shows, including container logs the agent can't know to
  scrub).

  Values shorter than #{6} characters are left alone; redacting "on" or
  "4000" would mangle ordinary output. Multi-line values are matched
  line by line as well as whole.
  """

  @min_length 6
  @mask "[redacted]"

  @doc "Prepares a list of values for `redact/2`."
  @spec prepare([String.t()]) :: [String.t()]
  def prepare(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&[&1 | String.split(&1, "\n")])
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(String.length(&1) >= @min_length))
    |> Enum.uniq()
    # Longest first, so a value containing another is replaced whole.
    |> Enum.sort_by(&(-byte_size(&1)))
  end

  @spec redact([String.t()], String.t()) :: String.t()
  def redact([], text), do: text
  def redact(prepared, text) when is_binary(text), do: String.replace(text, prepared, @mask)
  def redact(_prepared, other), do: other
end
