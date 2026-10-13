defmodule Foreman.Validations do
  @moduledoc "Changeset validations shared by several schemas."
  import Ecto.Changeset

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
