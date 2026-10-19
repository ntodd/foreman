defmodule Foreman.Settings do
  @moduledoc """
  Deployment settings kept in the database, encrypted: the GitHub App's
  credentials (when created through the manifest flow), Tailscale's OAuth
  client, and similar. Environment variables take precedence where both
  exist.
  """
  import Ecto.Query

  require Logger

  alias Foreman.Repo
  alias Foreman.Settings.Setting

  @check_key "encryption_key_check"

  def get(key, default \\ nil) do
    case Repo.get(Setting, key) do
      %Setting{value: %{"v" => value}} -> value
      _ -> default
    end
  end

  def put(key, value) do
    %Setting{key: key}
    |> Ecto.Changeset.change(value: %{"v" => value})
    |> Repo.insert!(on_conflict: {:replace, [:value, :updated_at]}, conflict_target: :key)

    :ok
  end

  def delete(key) do
    case Repo.get(Setting, key) do
      nil -> :ok
      setting -> Repo.delete!(setting) && :ok
    end
  end

  @doc """
  Checks FOREMAN_ENCRYPTION_KEY against what's stored, and stops the boot
  if it can't read it. A boot step, before anything decrypts: otherwise
  Foreman.Setup reads the GitHub App and crashes with a stack trace that
  doesn't mention the key, on every restart.
  """
  def start_checking_encryption_key do
    case check_encryption_key() do
      :ok ->
        :ignore

      {:error, message} ->
        Logger.error(message)
        {:error, :wrong_encryption_key}
    end
  end

  @doc """
  `:ok` if the vault's keys decrypt what's stored.

  A setting records the IDs of the keys the data may be under. While all
  of them are configured, the settings are all that's checked, and the
  current key is added, since it's what's written with from now on. A
  recorded key that isn't configured (a retired key dropped before
  re-encrypting finished, or going back to the old key after the new
  one wrote something), or nothing recorded yet, means checking every
  encrypted value, then recording the keys that are still needed.
  """
  def check_encryption_key do
    rows = Repo.all(from s in "settings", select: {s.key, s.value})

    case for {key, value} <- rows,
             Foreman.Vault.which_key(value) == :none,
             do: "the #{key} setting" do
      [] -> check_recorded_keys(Foreman.Vault.key_ids())
      unreadable -> {:error, wrong_key_message(unreadable)}
    end
  end

  defp check_recorded_keys([current | _] = configured) do
    recorded =
      case get(@check_key) do
        %{"keys" => ids} when is_list(ids) -> ids
        _ -> nil
      end

    if recorded && recorded -- configured == [] do
      record_keys(recorded, Enum.uniq(recorded ++ [current]))
    else
      keys = value_keys()

      case for({name, :none} <- keys, uniq: true, do: name) do
        [] ->
          needed = if Enum.all?(keys, &match?({_, :current}, &1)), do: [current], else: configured
          record_keys(recorded, needed)

        unreadable ->
          {:error, wrong_key_message(unreadable)}
      end
    end
  end

  defp record_keys(ids, ids), do: :ok
  defp record_keys(_, ids), do: put(@check_key, %{"keys" => ids})

  # {"users.access_token", :current | :retired | :none} for every
  # encrypted value.
  defp value_keys do
    for {schema, fields} <- Foreman.Vault.encrypted_schemas(),
        source = schema.__schema__(:source),
        field <- fields,
        value <-
          Repo.all(
            from s in source, where: not is_nil(field(s, ^field)), select: field(s, ^field)
          ),
        do: {"#{source}.#{field}", Foreman.Vault.which_key(value)}
  end

  defp wrong_key_message(unreadable) do
    """
    FOREMAN_ENCRYPTION_KEY isn't the key this database was encrypted with: \
    it can't decrypt #{Enum.join(unreadable, ", ")}. \
    Put the original key back. If you're changing it, the old one goes in \
    FOREMAN_ENCRYPTION_KEYS_RETIRED until Foreman.Release.reencrypt() has run \
    (docs/setup/upgrading.md).\
    """
  end
end
