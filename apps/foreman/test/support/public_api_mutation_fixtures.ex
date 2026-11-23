defmodule Foreman.PublicAPIMutationFixtures do
  @moduledoc false

  alias Foreman.{OAuth, Repo}

  def local_git(_) do
    previous = Application.fetch_env(:foreman, :git_base_url)
    Application.put_env(:foreman, :git_base_url, "https://git.example.test")

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, url} -> Application.put_env(:foreman, :git_base_url, url)
        :error -> Application.delete_env(:foreman, :git_base_url)
      end
    end)

    :ok
  end

  def principal(
        user,
        scopes \\ ~w(environments:create environments:start environments:stop environments:destroy)
      ) do
    grant =
      Repo.insert!(%OAuth.Grant{user_id: user.id, client_id: "foreman-cli", scopes: scopes})

    {:ok, actor} = OAuth.authorize_grant(grant.id)
    {actor, grant}
  end
end
