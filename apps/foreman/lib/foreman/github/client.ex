defmodule Foreman.GitHub.Client do
  @moduledoc """
  The GitHub API calls Foreman makes. `Foreman.GitHub.Client.Req` is the
  real implementation; tests use a Mox mock.

  `app` is the GitHub App's credentials:
  `%{app_id:, client_id:, client_secret:, private_key:, slug:}`.
  """

  @type app :: map()
  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_in: integer() | nil,
          refresh_token_expires_in: integer() | nil
        }

  @callback exchange_code(
              app,
              code :: String.t(),
              verifier :: String.t(),
              redirect_uri :: String.t()
            ) ::
              {:ok, tokens} | {:error, term()}
  @callback refresh_user_token(app, refresh_token :: String.t()) ::
              {:ok, tokens} | {:error, :bad_refresh_token | term()}
  @callback get_user(token :: String.t()) :: {:ok, map()} | {:error, term()}
  @doc """
  Whether the token's user is an active member of `org`. `{:ok, false}`
  only when GitHub says so; anything else that goes wrong is an error.
  """
  @callback org_membership(token :: String.t(), org :: String.t()) ::
              {:ok, boolean()} | {:error, term()}
  @callback scope_user_token(
              app,
              token :: String.t(),
              target :: String.t(),
              repos :: [String.t()],
              permissions :: map()
            ) ::
              {:ok, %{token: String.t(), expires_at: DateTime.t() | nil}} | {:error, term()}
  @callback list_installations(app) :: {:ok, [map()]} | {:error, term()}
  @callback installation_token(app, installation_id :: integer()) ::
              {:ok, String.t()} | {:error, term()}
  @callback list_installation_repos(token :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get_repo(token :: String.t(), full_name :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback list_branches(token :: String.t(), full_name :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}
  @callback get_file(
              token :: String.t(),
              full_name :: String.t(),
              path :: String.t(),
              ref :: String.t() | nil
            ) ::
              {:ok, binary()} | {:error, :not_found | term()}
  @callback list_dir(token :: String.t(), full_name :: String.t(), path :: String.t()) ::
              {:ok, [map()]} | {:error, :not_found | term()}
  @callback convert_manifest(code :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback check_classic_token(token :: String.t()) ::
              {:ok, %{login: String.t(), scopes: [String.t()], expires_at: DateTime.t() | nil}}
              | {:error, term()}
  @callback check_registry_pull(
              host :: String.t(),
              username :: String.t(),
              token :: String.t(),
              ref :: String.t()
            ) ::
              :ok | {:error, term()}

  def impl, do: Application.get_env(:foreman, :github_client, Foreman.GitHub.Client.Req)
end
