defmodule ForemanAgent.Env.Affected do
  @moduledoc """
  Finds the compose services that interpolate a set of variables, for
  "Restart affected" after a secrets change. Works on the output of
  `docker compose config --no-interpolate --format json`, where `${NAME}`
  references are still intact.
  """

  @spec services(map(), [String.t()]) :: [String.t()]
  def services(_config, []), do: []

  def services(config, changed) do
    changed = MapSet.new(changed)

    config
    |> Map.get("services", %{})
    |> Enum.filter(fn {_name, svc} ->
      svc |> references() |> Enum.any?(&MapSet.member?(changed, &1))
    end)
    |> Enum.map(fn {name, _} -> name end)
    |> Enum.sort()
  end

  @doc "Variable names a compose fragment interpolates."
  def references(fragment) do
    text = fragment |> JSON.encode!() |> String.replace("$$", "")

    braced = for [_, name] <- Regex.scan(~r/\$\{([A-Za-z_][A-Za-z0-9_]*)/, text), do: name
    bare = for [_, name] <- Regex.scan(~r/\$([A-Za-z_][A-Za-z0-9_]*)/, text), do: name

    Enum.uniq(braced ++ bare)
  end
end
