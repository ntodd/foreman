defmodule Foreman.Release do
  @moduledoc """
  Tasks for a running release, called with `bin/foreman eval`:

      bin/foreman eval 'Foreman.Release.migrate()'
      bin/foreman eval 'Foreman.Release.publish_agent("0.2.0", "linux-arm64", "/tmp/agent.tar.gz", "<base64 signature>")'

  Releases migrate on boot, so `migrate/0` is only needed to migrate
  before starting a new version.
  """
  @app :foreman

  def migrate do
    load_app()

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Registers a CI-built, signed agent release so boxes can update to it."
  def publish_agent(version, target, tarball_path, signature) do
    {:ok, _} = Application.ensure_all_started(@app)

    case Foreman.Agents.Releases.register(version, target, tarball_path, signature) do
      {:ok, release} ->
        IO.puts("published agent #{release.version} for #{release.target} (#{release.sha256})")

      {:error, message} ->
        raise "couldn't publish: #{inspect(message)}"
    end
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
