defmodule Foreman.Release do
  @moduledoc """
  Tasks for a running release, called with `bin/foreman eval`:

      bin/foreman eval 'Foreman.Release.migrate()'
      bin/foreman eval 'Foreman.Release.publish_agent("0.2.0", "linux-arm64", "/tmp/agent.tar.gz", "<base64 signature>")'
      bin/foreman eval 'Foreman.Release.reencrypt()'

  Releases migrate on boot, so `migrate/0` is only needed to migrate
  before starting a new version.
  """
  import Ecto.Query

  alias Ecto.Changeset

  @app :foreman

  def migrate do
    load_app()

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Registers a CI-built, signed agent release so boxes can update to it.

  Starts only the repo: the whole app would start Oban's queues and Cron
  in the eval VM, beside the running control plane's.
  """
  def publish_agent(version, target, tarball_path, signature) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Foreman.Repo, fn _repo ->
        Foreman.Agents.Releases.register(version, target, tarball_path, signature)
      end)

    case result do
      {:ok, release} ->
        IO.puts("published agent #{release.version} for #{release.target} (#{release.sha256})")

      {:error, message} ->
        raise "couldn't publish: #{inspect(message)}"
    end
  end

  @doc """
  Re-encrypts everything encrypted at rest with the current
  FOREMAN_ENCRYPTION_KEY, so the keys in FOREMAN_ENCRYPTION_KEYS_RETIRED
  can be dropped (docs/setup/upgrading.md). Safe beside the running
  control plane: each row is re-read and written in a transaction that
  holds it. Refuses to start if the keys can't read what's stored.

  Starts only the repo and the vault, like `publish_agent/4`.
  """
  def reencrypt do
    load_app()

    {:ok, counts, _} =
      Ecto.Migrator.with_repo(Foreman.Repo, fn repo ->
        start_vault()

        # Records the current key as one the data needs before anything is
        # written with it, as booting with it would have.
        with {:error, message} <- Foreman.Settings.check_encryption_key(), do: raise(message)

        for {schema, fields} <- Foreman.Vault.encrypted_schemas(),
            do: {schema, reencrypt(repo, schema, fields)}
      end)

    for {schema, count} <- counts do
      IO.puts("#{schema.__schema__(:source)}: #{count} re-encrypted")
    end
  end

  defp start_vault do
    case Foreman.Vault.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp reencrypt(repo, schema, fields) do
    [key] = schema.__schema__(:primary_key)
    # Writing the row would bump updated_at; it hasn't changed.
    kept = for {autoupdated, _} <- schema.__schema__(:autoupdate), field <- autoupdated, do: field

    from(s in schema, select: field(s, ^key))
    |> repo.all()
    |> Enum.count(fn id ->
      query = lock_row(from(s in schema, where: field(s, ^key) == ^id))
      {:ok, written?} = repo.transaction(fn -> reencrypt_row(repo, query, fields ++ kept) end)
      written?
    end)
  end

  # The row may have gone since the ids were read.
  defp reencrypt_row(repo, query, fields) do
    if row = repo.one(query) do
      fields
      |> Enum.reduce(Changeset.change(row), fn field, changeset ->
        Changeset.force_change(changeset, field, Map.fetch!(row, field))
      end)
      |> repo.update!()

      true
    else
      false
    end
  end

  # SQLite transactions are :immediate (config.exs), which takes the write
  # lock up front; it has no row locks.
  defp lock_row(query) do
    if Foreman.Repo.database() == "postgres", do: lock(query, "FOR UPDATE"), else: query
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
