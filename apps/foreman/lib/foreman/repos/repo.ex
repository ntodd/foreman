defmodule Foreman.Repos.Repo do
  @moduledoc """
  A GitHub repo. Environments are made from repos that have a devcontainer.
  Per-repo settings: how the environment's GitHub token is scoped, extra
  Tailscale tags, and default resource limits.
  """
  use Foreman.Schema

  @token_modes ~w(scoped broad)

  schema "repos" do
    belongs_to :owner, Foreman.Repos.Owner
    field :full_name, :string
    field :name, :string
    field :github_id, :integer
    field :default_branch, :string, default: "main"
    field :private, :boolean, default: true
    field :archived, :boolean, default: false
    field :manual, :boolean, default: false
    field :devcontainer_path, :string
    field :devcontainer_checked_at, :utc_datetime_usec
    field :removed_at, :utc_datetime_usec
    field :devcontainer_error, :string
    field :host_requirements, :map
    field :private_registry_refs, {:array, :string}, default: []
    field :token_mode, :string, default: "scoped"
    field :extra_repos, {:array, :string}, default: []
    field :token_permissions, :map
    field :tailscale_tags, {:array, :string}, default: []
    field :cpu_limit, :float
    field :memory_limit_mb, :integer
    timestamps()
  end

  @doc "The repo's token permission choices, filled in from the defaults."
  def permissions(%__MODULE__{token_permissions: p}),
    do: Foreman.Repos.TokenPermissions.choices(p)

  def sync_changeset(repo, attrs) do
    repo
    |> cast(attrs, [
      :full_name,
      :name,
      :github_id,
      :default_branch,
      :private,
      :archived,
      :manual,
      :devcontainer_path,
      :devcontainer_checked_at,
      :devcontainer_error,
      :host_requirements,
      :private_registry_refs,
      :removed_at
    ])
    |> validate_required([:full_name, :name])
    |> validate_format(
      :full_name,
      ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}\z/
    )
    |> unique_constraint(:full_name)
  end

  def settings_changeset(repo, attrs) do
    repo
    |> cast(attrs, [
      :token_mode,
      :extra_repos,
      :token_permissions,
      :tailscale_tags,
      :cpu_limit,
      :memory_limit_mb,
      :default_branch
    ])
    |> validate_inclusion(:token_mode, @token_modes)
    |> validate_number(:cpu_limit, greater_than: 0, less_than_or_equal_to: 512)
    |> validate_number(:memory_limit_mb, greater_than_or_equal_to: 256)
    |> validate_change(:extra_repos, fn :extra_repos, repos ->
      if Enum.all?(repos, &Regex.match?(~r/\A[A-Za-z0-9._-]{1,100}\z/, &1)),
        do: [],
        else: [extra_repos: "must be repo names under the same owner"]
    end)
    |> validate_change(:tailscale_tags, fn :tailscale_tags, tags ->
      if Enum.all?(tags, &Regex.match?(~r/\Atag:[A-Za-z0-9][A-Za-z0-9-]{0,62}\z/, &1)),
        do: [],
        else: [tailscale_tags: "must look like tag:name"]
    end)
    |> validate_change(:token_permissions, fn :token_permissions, perms ->
      Foreman.Repos.TokenPermissions.validate(perms)
    end)
    |> clear_default_permissions()
  end

  # Choices that match the defaults are stored as nil, so the repo follows
  # later defaults.
  defp clear_default_permissions(changeset) do
    perms = get_change(changeset, :token_permissions)

    if changeset.valid? and is_map(perms) and
         Foreman.Repos.TokenPermissions.choices(perms) ==
           Foreman.Repos.TokenPermissions.defaults(),
       do: force_change(changeset, :token_permissions, nil),
       else: changeset
  end

  def has_devcontainer?(%__MODULE__{devcontainer_path: path}), do: is_binary(path)
end
