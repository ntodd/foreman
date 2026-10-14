defmodule ForemanWeb.SetupController do
  @moduledoc """
  First-run setup: create the GitHub App from a manifest (one click on
  GitHub), then install it. Guarded by the one-time setup token from the
  boot log until the app exists.
  """
  use ForemanWeb, :controller

  alias Foreman.{GitHub, Setup}

  plug :require_setup when action in [:show, :verify, :github, :created]

  def show(conn, _params) do
    render(conn, :show,
      page_title: "Set up Foreman",
      verified: get_session(conn, :setup_ok) == true,
      base_url: Foreman.Config.base_url()
    )
  end

  def verify(conn, %{"token" => token}) do
    with {:allow, _} <- Foreman.RateLimit.hit("setup:#{remote_ip(conn)}", 60_000, 10),
         true <- Setup.verify(String.trim(token)) do
      conn |> put_session(:setup_ok, true) |> redirect(to: ~p"/setup")
    else
      _ ->
        conn
        |> put_flash(:error, "That setup token isn't right. It's in the control plane's log.")
        |> redirect(to: ~p"/setup")
    end
  end

  def github(conn, params) do
    if get_session(conn, :setup_ok) do
      state = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      org = params["org"] |> to_string() |> String.trim()

      action =
        if org != "" and Regex.match?(~r/\A[A-Za-z0-9-]{1,39}\z/, org),
          do: "https://github.com/organizations/#{org}/settings/apps/new?state=#{state}",
          else: "https://github.com/settings/apps/new?state=#{state}"

      name =
        params["name"]
        |> to_string()
        |> String.trim()
        |> then(&if(&1 == "", do: "Foreman", else: &1))

      manifest = GitHub.manifest(Foreman.Config.base_url(), String.slice(name, 0, 34))

      conn
      |> put_session(:manifest_state, state)
      |> render(:github,
        page_title: "Create the GitHub App",
        action: action,
        manifest: JSON.encode!(manifest)
      )
    else
      redirect(conn, to: ~p"/setup")
    end
  end

  def created(conn, %{"code" => code, "state" => state}) do
    expected = get_session(conn, :manifest_state)

    with true <- get_session(conn, :setup_ok) == true,
         true <- is_binary(expected) and Plug.Crypto.secure_compare(state, expected),
         {:ok, app} <- GitHub.complete_manifest(code) do
      conn
      |> delete_session(:manifest_state)
      |> put_flash(
        :info,
        "Created the GitHub App. Now install it on the accounts whose repos Foreman should see."
      )
      |> redirect(external: "#{app["html_url"]}/installations/new")
    else
      _ ->
        conn
        |> put_flash(:error, "Couldn't finish creating the GitHub App. Try again.")
        |> redirect(to: ~p"/setup")
    end
  end

  def created(conn, _params), do: redirect(conn, to: ~p"/setup")

  # GitHub sends people here after installing the app.
  def installed(conn, _params) do
    Oban.insert(Foreman.Jobs.SyncRepos.new(%{}))

    conn
    |> put_flash(:info, "Installed. Foreman is syncing your repos; sign in to continue.")
    |> redirect(to: ~p"/sign-in")
  end

  defp require_setup(conn, _opts) do
    if Setup.needed?(), do: conn, else: conn |> redirect(to: ~p"/sign-in") |> halt()
  end

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
