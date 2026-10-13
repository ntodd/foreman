defmodule Foreman.Setup do
  @moduledoc """
  First-run setup. Until a GitHub App is configured nobody can sign in,
  so the setup pages are guarded by a one-time token that's printed to
  the log at boot (like a router's default password, but random and
  only valid until setup is done).
  """
  use GenServer

  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "True while the GitHub App isn't configured."
  def needed?, do: not Foreman.GitHub.configured?()

  def verify(token) when is_binary(token) do
    case :persistent_term.get(__MODULE__, nil) do
      nil -> false
      expected -> Plug.Crypto.secure_compare(token, expected)
    end
  end

  def verify(_), do: false

  @impl true
  def init(_) do
    if needed?() do
      token = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      :persistent_term.put(__MODULE__, token)

      unless Application.get_env(:foreman, :env) == :test do
        Logger.warning("""
        Foreman isn't connected to GitHub yet. Finish setup at
            #{Foreman.Config.base_url()}/setup
        with this one-time setup token:
            #{token}
        """)
      end
    end

    {:ok, nil}
  end
end
