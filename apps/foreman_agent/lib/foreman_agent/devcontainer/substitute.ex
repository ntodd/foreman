defmodule ForemanAgent.Devcontainer.Substitute do
  @moduledoc """
  The `${...}` variables of a devcontainer.json, in the three passes the
  spec has: what's known outside the container (`local/2`), the
  devcontainer's id (`devcontainer_id/2`), and the container's own
  environment once it runs (`container_env/2`). Each pass leaves the
  variables that aren't its own as they are, for the next one.

  A value is whatever JSON decodes to; strings are substituted wherever
  they sit in it.
  """

  @variable ~r/\$\{(.*?)\}/

  @type context :: %{
          optional(:local_workspace_folder) => String.t() | nil,
          optional(:container_workspace_folder) => String.t() | nil,
          env: %{String.t() => String.t()}
        }

  @doc """
  Replaces `${localEnv:NAME[:default]}` (and `${env:...}`), the workspace
  folders and their basenames.
  """
  @spec local(term(), context()) :: {:ok, term()} | {:error, String.t()}
  def local(value, context) do
    replace = &local_variable(&1, &2, &3, context)

    context =
      case context[:container_workspace_folder] do
        nil -> context
        folder -> %{context | container_workspace_folder: string(folder, replace)}
      end

    walk(value, &local_variable(&1, &2, &3, context))
  catch
    {:unresolved, message} -> {:error, message}
  end

  @doc "Replaces `${containerEnv:NAME[:default]}` from the container's environment."
  @spec container_env(term(), %{String.t() => String.t()}) :: {:ok, term()} | {:error, String.t()}
  def container_env(value, env) do
    walk(value, fn
      match, "containerEnv", args -> lookup(env, args, match)
      match, _variable, _args -> match
    end)
  catch
    {:unresolved, message} -> {:error, message}
  end

  @doc "Replaces `${devcontainerId}` with the id of the container's id labels."
  @spec devcontainer_id(term(), [String.t()]) :: term()
  def devcontainer_id(value, id_labels) do
    id = id_for_labels(id_labels)

    {:ok, value} =
      walk(value, fn
        _match, "devcontainerId", _args -> id
        match, _variable, _args -> match
      end)

    value
  end

  @doc """
  The id the devcontainer CLI derives from a container's id labels
  (`name=value`): the SHA-256 of them as a JSON object with sorted keys, in
  base 32. Volumes named with `${devcontainerId}` depend on it staying the
  same.
  """
  @spec id_for_labels([String.t()]) :: String.t()
  def id_for_labels(id_labels) do
    json =
      id_labels
      |> Enum.flat_map(fn label ->
        case String.split(label, "=", parts: 2) do
          [name, value] -> [{name, value}]
          _ -> []
        end
      end)
      |> Map.new()
      |> Enum.sort()
      |> Enum.map_join(",", fn {name, value} ->
        JSON.encode!(name) <> ":" <> JSON.encode!(value)
      end)

    <<number::unsigned-integer-size(256)>> = :crypto.hash(:sha256, "{" <> json <> "}")

    number
    |> Integer.to_string(32)
    |> String.downcase()
    |> String.pad_leading(52, "0")
  end

  defp local_variable(match, variable, args, context) when variable in ["env", "localEnv"],
    do: lookup(context.env, args, match)

  defp local_variable(match, "localWorkspaceFolder", _args, context),
    do: context[:local_workspace_folder] || match

  defp local_variable(match, "localWorkspaceFolderBasename", _args, context),
    do: basename(context[:local_workspace_folder]) || match

  defp local_variable(match, "containerWorkspaceFolder", _args, context),
    do: context[:container_workspace_folder] || match

  defp local_variable(match, "containerWorkspaceFolderBasename", _args, context),
    do: basename(context[:container_workspace_folder]) || match

  defp local_variable(match, _variable, _args, _context), do: match

  defp basename(nil), do: nil
  defp basename(folder), do: Path.basename(folder)

  defp lookup(env, [name | rest], _match) do
    case {env[name], rest} do
      {value, _} when is_binary(value) -> value
      {_, [default | _]} -> default
      # A shell gives an unset variable as empty too.
      {_, []} -> ""
    end
  end

  defp lookup(_env, [], match) do
    throw(
      {:unresolved,
       "'#{match}' can not be resolved because no environment variable name is given."}
    )
  end

  defp walk(value, replace), do: {:ok, walk_value(value, replace)}

  defp walk_value(value, replace) when is_binary(value), do: string(value, replace)

  defp walk_value(value, replace) when is_list(value),
    do: Enum.map(value, &walk_value(&1, replace))

  defp walk_value(value, replace) when is_map(value),
    do: Map.new(value, fn {key, inner} -> {key, walk_value(inner, replace)} end)

  defp walk_value(value, _replace), do: value

  defp string(value, replace) do
    Regex.replace(@variable, value, fn match, inner ->
      [variable | args] = String.split(inner, ":")
      replace.(match, variable, args)
    end)
  end
end
