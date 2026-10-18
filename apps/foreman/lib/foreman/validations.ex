defmodule Foreman.Validations do
  @moduledoc "Changeset validations shared by several schemas."
  import Ecto.Changeset

  alias ForemanProtocol.{Feature, Schema}

  @max_features 30

  @doc """
  Git name and email end up in a gitconfig file, so they can't contain
  newlines, brackets or quotes that would let a value add config of its own.
  """
  def validate_git_identity(changeset) do
    changeset
    |> validate_length(:git_name, max: 100)
    |> validate_format(:git_name, ~r/\A[^\n\r\[\]"\\]*\z/,
      message: "can't contain newlines, brackets, quotes or backslashes"
    )
    |> validate_length(:git_email, max: 254)
    |> validate_format(:git_email, ~r/\A[^\s@"\\\[\]]+@[^\s@"\\\[\]]+\z/,
      message: "must be an email address"
    )
  end

  @doc "Dotfiles must be a public https git URL; the install command is passed as one argv entry."
  def validate_dotfiles(changeset) do
    changeset
    |> validate_format(:dotfiles_repository, ~r/\Ahttps:\/\/[^\s@]+\z/,
      message: "must be an https URL"
    )
    |> validate_length(:dotfiles_install_command, max: 500)
    |> validate_format(:dotfiles_install_command, ~r/\A[^\n\r\0]*\z/, message: "must be one line")
  end

  @doc """
  A user's own devcontainer features: OCI refs (no local paths or
  tarballs), each listed once, none with the Foreman feature's id, and
  options the agent would take.
  """
  def validate_features(changeset, field) do
    validate_change(changeset, field, fn ^field, features ->
      errors =
        if map_size(features) > @max_features,
          do: ["can't list more than #{@max_features} features"],
          else: Enum.flat_map(features, &feature_errors/1) ++ duplicate_features(features)

      Enum.map(errors, &{field, &1})
    end)
  end

  defp feature_errors({ref, options}) do
    cond do
      not Feature.valid_ref?(ref) ->
        ["#{ref} isn't a feature ref like ghcr.io/owner/features/name:1"]

      Feature.id(ref) == Feature.foreman_id() ->
        ["#{ref} uses the id of Foreman's own feature"]

      true ->
        case Schema.cast(%{"options" => options},
               options: {Feature.options_type(), required: true}
             ) do
          {:ok, _} -> []
          {:error, errors} -> Enum.map(errors, fn {path, msg} -> "#{ref}: #{path} #{msg}" end)
        end
    end
  end

  defp duplicate_features(features) do
    for {base, [_, _ | _]} <- Enum.group_by(Map.keys(features), &Feature.base/1),
        do: "lists #{base} twice"
  end

  @doc "Feature refs without a tag or digest."
  def validate_feature_bases(changeset, field) do
    validate_change(changeset, field, fn ^field, bases ->
      for base <- bases,
          not (Feature.valid_ref?(base) and Feature.base(base) == base),
          do: {field, "#{base} isn't a feature ref without a version"}
    end)
  end

  @doc "Environment variable names for secrets."
  def validate_env_name(changeset, field) do
    changeset
    |> validate_format(field, ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/,
      message:
        "must start with a letter or underscore and contain only letters, digits and underscores"
    )
    |> validate_exclusion(field, ForemanProtocol.Schema.reserved_env(), message: "is reserved")
    |> validate_change(field, fn ^field, name ->
      if String.starts_with?(name, "FOREMAN_"),
        do: [{field, "uses the FOREMAN_ prefix, which Foreman reserves"}],
        else: []
    end)
  end
end
