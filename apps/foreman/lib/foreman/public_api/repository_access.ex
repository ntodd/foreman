defmodule Foreman.PublicAPI.RepositoryAccess do
  @moduledoc """
  Match the repositories a caller can use to immutable GitHub IDs. Use
  installation membership for synced records. Admins can also register
  individual repositories outside an installation.
  """
  import Ecto.Query
  alias Foreman.{GitHub, Repo}
  alias Foreman.GitHub.Client
  alias Foreman.PublicAPI.Access.Unavailable

  def visible_ids(query, user) do
    candidates =
      Repo.all(
        from r in query,
          join: o in assoc(r, :owner),
          where: not is_nil(r.github_id),
          select: {r.id, r.github_id, r.full_name, r.manual, o.installation_id}
      )

    if candidates == [], do: [], else: verify(candidates, user)
  end

  defp verify(candidates, user) do
    case GitHub.user_token(user) do
      {:ok, token} ->
        candidates
        |> Enum.group_by(fn {_, _, _, manual, installation} ->
          if manual, do: :manual, else: installation
        end)
        |> Enum.flat_map(fn {installation, records} -> verified(token, installation, records) end)

      {:error, :login_expired} ->
        []

      {:error, _} ->
        raise Unavailable
    end
  end

  defp verified(token, :manual, records) do
    for {id, github_id, name, _, _} <- records, matches?(token, name, github_id), do: id
  end

  defp verified(_token, nil, _records), do: []

  defp verified(token, installation, records) do
    case Client.impl().list_user_installation_repos(token, installation) do
      {:ok, repositories} ->
        remote =
          MapSet.new(
            for %{"id" => id, "full_name" => name} <- repositories,
                is_integer(id) and is_binary(name),
                do: {id, String.downcase(name)}
          )

        for {id, github_id, name, _, _} <- records,
            MapSet.member?(remote, {github_id, String.downcase(name)}),
            do: id

      {:error, {:http, 404, _}} ->
        []

      {:error, _} ->
        raise Unavailable
    end
  end

  defp matches?(token, name, github_id) do
    case Client.impl().get_repo(token, name) do
      {:ok, %{"id" => ^github_id, "full_name" => full_name}} when is_binary(full_name) ->
        String.downcase(full_name) == String.downcase(name)

      {:ok, _} ->
        false

      {:error, :not_found} ->
        false

      {:error, _} ->
        raise Unavailable
    end
  end
end
