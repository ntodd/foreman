defmodule ForemanProtocol.Connect do
  @moduledoc """
  Connect hooks: executables a devcontainer feature installs at
  `/usr/local/share/foreman/connect.d/<name>` to put actions on the
  environment's page, such as pairing a client with a server running in
  the environment.

  `<hook> describe` prints `{"label", "actions": [{"id", "label",
  "confirm"}]}`. The agent runs it when the environment comes up and
  reports the hooks it found. `<hook> run <action>` prints the result as
  JSON on the last line of its output: `{"value", "qr", "note"}`. The value
  is usually a secret (a pairing code): it's shown once to the person who
  asked and never stored.

  Both outputs come from the environment, which the repo controls, so
  they're held to a few short fields here, on both sides of the socket.
  Fields this doesn't know are dropped rather than refused, so hooks can
  grow.
  """

  @dir "/usr/local/share/foreman/connect.d"
  @name ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/
  @max_hooks 8
  @max_actions 4
  @max_label 60
  @max_confirm 300
  @max_note 300
  # Bytes, well under what a QR code holds (2953 at its lowest correction).
  @max_value_bytes 2048
  @max_error 300

  @doc "Where hooks live in the devcontainer."
  def dir, do: @dir

  @doc "The most hooks an environment shows."
  def max_hooks, do: @max_hooks

  @doc "Whether `name` can name a hook or an action: it becomes a path and an argument."
  def name?(name) when is_binary(name), do: Regex.match?(@name, name)
  def name?(_), do: false

  @doc "A hook's `describe` output, checked: `{:ok, hook}` with its name, label and actions."
  def cast_hook(name, describe) when is_map(describe) do
    with :ok <- check(name?(name), "the hook's name isn't one Foreman takes"),
         {:ok, label} <- text(describe["label"], @max_label, "label"),
         {:ok, actions} <- actions(describe["actions"]) do
      {:ok, %{"name" => name, "label" => label, "actions" => actions}}
    end
  end

  def cast_hook(_name, _describe), do: {:error, "describe didn't print a JSON object"}

  defp actions(list) when is_list(list) and list != [] and length(list) <= @max_actions do
    with {:ok, actions} <- map_ok(list, &action/1) do
      ids = Enum.map(actions, & &1["id"])
      if ids == Enum.uniq(ids), do: {:ok, actions}, else: {:error, "action ids repeat"}
    end
  end

  defp actions(_), do: {:error, "actions must be a list of 1 to #{@max_actions}"}

  defp action(%{} = action) do
    with :ok <- check(name?(action["id"]), "an action's id isn't a short lowercase name"),
         {:ok, label} <- text(action["label"], @max_label, "an action's label"),
         {:ok, confirm} <- optional_text(action["confirm"], @max_confirm, "confirm") do
      {:ok, %{"id" => action["id"], "label" => label, "confirm" => confirm}}
    end
  end

  defp action(_), do: {:error, "an action isn't an object"}

  @doc """
  The hooks an agent reported, or stored ones, checked again: the valid
  ones, sorted by name, at most #{@max_hooks}. Anything that isn't a list
  is none.
  """
  def cast_hooks(hooks) when is_list(hooks) do
    hooks
    |> Enum.flat_map(fn
      %{"name" => name} = hook ->
        case cast_hook(name, hook) do
          {:ok, hook} -> [hook]
          {:error, _} -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1["name"])
    |> Enum.sort_by(& &1["name"])
    |> Enum.take(@max_hooks)
  end

  def cast_hooks(_), do: []

  @doc "Whether one of `hooks` offers `action`."
  def action?(hooks, name, action) do
    Enum.any?(hooks, fn hook ->
      hook["name"] == name and Enum.any?(hook["actions"], &(&1["id"] == action))
    end)
  end

  @doc ~s(A hook's `run` output, checked: `{:ok, %{"value", "qr", "note"}}`.)
  def cast_offer(%{} = offer) do
    with {:ok, value} <- text(offer["value"], @max_value_bytes, "value"),
         :ok <-
           check(
             byte_size(value) <= @max_value_bytes,
             "value is longer than #{@max_value_bytes} bytes"
           ),
         {:ok, qr} <- boolean(offer["qr"]),
         {:ok, note} <- optional_text(offer["note"], @max_note, "note") do
      {:ok, %{"value" => value, "qr" => qr, "note" => note}}
    end
  end

  def cast_offer(_), do: {:error, "it didn't print a JSON object"}

  @doc """
  A failed `run`'s own explanation: `{"error": "..."}` as its last line.
  Nothing else a failed run printed is shown, since it could hold the
  secret the run was making.
  """
  def cast_error(%{"error" => error}) do
    case text(error, @max_error, "error") do
      {:ok, error} -> {:ok, error}
      {:error, _} -> :error
    end
  end

  def cast_error(_), do: :error

  defp boolean(nil), do: {:ok, false}
  defp boolean(v) when is_boolean(v), do: {:ok, v}
  defp boolean(_), do: {:error, "qr must be true or false"}

  defp optional_text(nil, _max, _what), do: {:ok, nil}
  defp optional_text(v, max, what), do: text(v, max, what)

  # One line of printable text: it's shown as is, and never as HTML.
  defp text(v, max, what) when is_binary(v) do
    cond do
      v == "" -> {:error, "#{what} is empty"}
      not String.valid?(v) -> {:error, "#{what} isn't UTF-8"}
      String.length(v) > max -> {:error, "#{what} is longer than #{max} characters"}
      Regex.match?(~r/[\p{Cc}\p{Cf}]/u, v) -> {:error, "#{what} has control characters"}
      true -> {:ok, v}
    end
  end

  defp text(_v, _max, what), do: {:error, "#{what} must be a string"}

  defp check(true, _message), do: :ok
  defp check(false, message), do: {:error, message}

  defp map_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
