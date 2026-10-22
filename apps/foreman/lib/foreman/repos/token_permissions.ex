defmodule Foreman.Repos.TokenPermissions do
  @moduledoc """
  What an environment's scoped GitHub token may do. The catalog follows
  the permissions a Codespaces devcontainer can ask for; a repo picks a
  level for each (or keeps the defaults), and the token never gets more
  than the GitHub App's installation was granted.
  """

  # {name, label, levels it can be set to besides "none"}. GitHub only
  # has write for workflows.
  @catalog [
    {"contents", "Contents", ~w(read write)},
    {"pull_requests", "Pull requests", ~w(read write)},
    {"issues", "Issues", ~w(read write)},
    {"workflows", "Workflows", ~w(write)},
    {"actions", "Actions", ~w(read write)},
    {"checks", "Checks", ~w(read write)},
    {"statuses", "Commit statuses", ~w(read write)},
    {"deployments", "Deployments", ~w(read write)},
    {"discussions", "Discussions", ~w(read write)},
    {"pages", "Pages", ~w(read write)}
  ]

  # Development and CI. Checks and statuses stay read-only so code in an
  # environment can't mark a required check as passed.
  @defaults %{
    "contents" => "write",
    "pull_requests" => "write",
    "issues" => "write",
    "workflows" => "write",
    "actions" => "write",
    "checks" => "read",
    "statuses" => "read",
    "deployments" => "none",
    "discussions" => "none",
    "pages" => "none"
  }

  # What every Foreman GitHub App has been created with, assumed for an
  # installation that hasn't been synced since Foreman started recording
  # its permissions.
  @legacy_grant %{
    "contents" => "write",
    "pull_requests" => "write",
    "issues" => "write",
    "workflows" => "write",
    "metadata" => "read"
  }

  def catalog, do: @catalog
  def defaults, do: @defaults

  @doc "The levels `name` can be set to, `\"none\"` first; nil for a name outside the catalog."
  def levels(name) do
    Enum.find_value(@catalog, fn {n, _label, levels} -> n == name && ["none" | levels] end)
  end

  @doc "A repo's choices (nil for the defaults), filled in from the defaults."
  def choices(nil), do: @defaults
  def choices(perms) when is_map(perms), do: Map.merge(@defaults, perms)

  @doc "Errors for a map of choices: only catalog names, at levels GitHub has for them."
  def validate(perms) when is_map(perms) do
    if Enum.all?(perms, fn {k, v} -> v in (levels(k) || []) end),
      do: [],
      else: [token_permissions: "must set catalog permissions to a level GitHub has for them"]
  end

  def validate(_), do: [token_permissions: "must be a map"]

  @doc """
  The permissions to ask GitHub for: the repo's choices without the ones
  turned off, plus metadata, capped by what the installation was granted
  (nil until the first sync that records it).
  """
  def request(choices, granted) do
    granted = granted || @legacy_grant

    choices
    |> Map.reject(fn {_k, v} -> v == "none" end)
    |> Map.put("metadata", "read")
    |> Enum.flat_map(fn {name, level} ->
      case cap(level, granted[name]) do
        nil -> []
        level -> [{name, level}]
      end
    end)
    |> Map.new()
  end

  @doc "Whether the installation lacks `name` (or only has read where write is chosen)."
  def short?(name, level, granted) do
    level != "none" and cap(level, (granted || @legacy_grant)[name]) != level
  end

  defp cap(_wanted, nil), do: nil
  defp cap("write", "read"), do: "read"
  defp cap(wanted, _granted), do: wanted
end
