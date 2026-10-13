defmodule Foreman.GitHub.Client.Req do
  @moduledoc "`Foreman.GitHub.Client` over HTTPS with Req."
  @behaviour Foreman.GitHub.Client

  alias Foreman.GitHub.JWT

  @api "https://api.github.com"
  @web "https://github.com"

  defp api(opts) do
    Req.new(
      base_url: @api,
      headers: [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", "foreman"}
      ],
      retry: :transient,
      max_retries: 2
    )
    |> Req.merge(opts)
    |> Req.merge(Application.get_env(:foreman, :github_req_options, []))
  end

  defp bearer(token), do: [auth: {:bearer, token}]

  @impl true
  def exchange_code(app, code, verifier, redirect_uri) do
    oauth_token(%{
      client_id: app.client_id,
      client_secret: app.client_secret,
      code: code,
      code_verifier: verifier,
      redirect_uri: redirect_uri
    })
  end

  @impl true
  def refresh_user_token(app, refresh_token) do
    case oauth_token(%{
           client_id: app.client_id,
           client_secret: app.client_secret,
           grant_type: "refresh_token",
           refresh_token: refresh_token
         }) do
      {:error, {:oauth, "bad_refresh_token"}} -> {:error, :bad_refresh_token}
      other -> other
    end
  end

  defp oauth_token(form) do
    req = api(base_url: @web, headers: [{"accept", "application/json"}])

    case Req.post(req, url: "/login/oauth/access_token", form: form) do
      {:ok, %{status: 200, body: %{"access_token" => token} = body}} ->
        {:ok,
         %{
           access_token: token,
           refresh_token: body["refresh_token"],
           expires_in: body["expires_in"],
           refresh_token_expires_in: body["refresh_token_expires_in"]
         }}

      {:ok, %{body: %{"error" => error}}} ->
        {:error, {:oauth, error}}

      other ->
        unexpected(other)
    end
  end

  @impl true
  def get_user(token) do
    case Req.get(api(bearer(token)), url: "/user") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      other -> unexpected(other)
    end
  end

  @impl true
  def org_member?(token, org) do
    case Req.get(api(bearer(token)), url: "/user/memberships/orgs/#{URI.encode_www_form(org)}") do
      {:ok, %{status: 200, body: %{"state" => "active"}}} -> true
      _ -> false
    end
  end

  @impl true
  def scope_user_token(app, token, target, repos, permissions) do
    req = api(auth: {:basic, "#{app.client_id}:#{app.client_secret}"})

    body = %{access_token: token, target: target, repositories: repos, permissions: permissions}

    case Req.post(req, url: "/applications/#{app.client_id}/token/scoped", json: body) do
      {:ok, %{status: 200, body: %{"token" => scoped} = body}} ->
        {:ok, %{token: scoped, expires_at: parse_time(body["expires_at"])}}

      other ->
        unexpected(other)
    end
  end

  @impl true
  def list_installations(app) do
    paginate(api(bearer(app_jwt(app))), "/app/installations", & &1)
  end

  @impl true
  def installation_token(app, installation_id) do
    case Req.post(api(bearer(app_jwt(app))),
           url: "/app/installations/#{installation_id}/access_tokens"
         ) do
      {:ok, %{status: 201, body: %{"token" => token}}} -> {:ok, token}
      other -> unexpected(other)
    end
  end

  @impl true
  def list_installation_repos(token) do
    paginate(api(bearer(token)), "/installation/repositories", & &1["repositories"])
  end

  @impl true
  def get_repo(token, full_name) do
    case Req.get(api(bearer(token)), url: "/repos/#{full_name}") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      other -> unexpected(other)
    end
  end

  @impl true
  def list_branches(token, full_name) do
    with {:ok, branches} <- paginate(api(bearer(token)), "/repos/#{full_name}/branches", & &1, 3) do
      {:ok, Enum.map(branches, & &1["name"])}
    end
  end

  @impl true
  def get_file(token, full_name, path, ref) do
    req =
      api(
        bearer(token) ++
          [headers: [{"accept", "application/vnd.github.raw+json"}], decode_body: false]
      )

    params = if ref, do: [ref: ref], else: []

    case Req.get(req, url: "/repos/#{full_name}/contents/#{encode_path(path)}", params: params) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      other -> unexpected(other)
    end
  end

  @impl true
  def list_dir(token, full_name, path) do
    case Req.get(api(bearer(token)), url: "/repos/#{full_name}/contents/#{encode_path(path)}") do
      {:ok, %{status: 200, body: entries}} when is_list(entries) -> {:ok, entries}
      {:ok, %{status: 200}} -> {:error, :not_found}
      {:ok, %{status: 404}} -> {:error, :not_found}
      other -> unexpected(other)
    end
  end

  @impl true
  def convert_manifest(code) do
    case Req.post(api([]), url: "/app-manifests/#{URI.encode_www_form(code)}/conversions") do
      {:ok, %{status: 201, body: body}} -> {:ok, body}
      other -> unexpected(other)
    end
  end

  @impl true
  def check_classic_token(token) do
    case Req.get(api(headers: [{"authorization", "token " <> token}]), url: "/user") do
      {:ok, %{status: 200, body: body} = resp} ->
        scopes =
          resp
          |> Req.Response.get_header("x-oauth-scopes")
          |> Enum.flat_map(&String.split(&1, ","))
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        expires =
          case Req.Response.get_header(resp, "github-authentication-token-expiration") do
            [value | _] -> parse_expiration(value)
            [] -> nil
          end

        {:ok, %{login: body["login"], scopes: scopes, expires_at: expires}}

      {:ok, %{status: 401}} ->
        {:error, :invalid_token}

      other ->
        unexpected(other)
    end
  end

  @impl true
  def check_registry_pull(host, username, token, ref) do
    {name, tag} = split_ref(ref, host)

    with {:ok, %{status: 200, body: %{"token" => bearer}}} <-
           Req.get("https://#{host}/token",
             params: [service: host, scope: "repository:#{name}:pull"],
             auth: {:basic, "#{username}:#{token}"},
             retry: false
           ),
         {:ok, %{status: 200}} <-
           Req.head("https://#{host}/v2/#{name}/manifests/#{tag}",
             auth: {:bearer, bearer},
             headers: [
               {"accept",
                "application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json"}
             ],
             retry: false
           ) do
      :ok
    else
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, exception}
      other -> {:error, other}
    end
  end

  defp split_ref(ref, host) do
    path = String.replace_prefix(ref, host <> "/", "")

    case Regex.run(
           ~r/\A(.+?)(?::([A-Za-z0-9_][A-Za-z0-9._-]{0,127}))?(?:@sha256:[0-9a-f]{64})?\z/,
           path
         ) do
      [_, name, tag] -> {name, tag}
      [_, name] -> {name, "latest"}
      _ -> {path, "latest"}
    end
  end

  defp paginate(req, url, extract, max_pages \\ 20) do
    Enum.reduce_while(1..max_pages, {:ok, []}, fn page, {:ok, acc} ->
      case Req.get(req, url: url, params: [per_page: 100, page: page]) do
        {:ok, %{status: 200, body: body}} ->
          items = extract.(body) || []
          acc = acc ++ items
          if length(items) < 100, do: {:halt, {:ok, acc}}, else: {:cont, {:ok, acc}}

        other ->
          {:halt, unexpected(other)}
      end
    end)
  end

  defp app_jwt(app), do: JWT.app_token(app.client_id || app.app_id, app.private_key)

  defp encode_path(path),
    do:
      path
      |> String.split("/")
      |> Enum.map_join("/", fn part -> URI.encode(part, &URI.char_unreserved?/1) end)

  defp parse_time(nil), do: nil

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  # "2026-11-01 00:00:00 UTC"
  defp parse_expiration(value) do
    case String.split(value, " ") do
      [date, time | _] -> parse_time("#{date}T#{time}Z")
      _ -> nil
    end
  end

  defp unexpected({:ok, %Req.Response{status: status, body: body}}) do
    message = if is_map(body), do: body["message"], else: nil
    {:error, {:http, status, message}}
  end

  defp unexpected({:error, exception}), do: {:error, exception}
end
