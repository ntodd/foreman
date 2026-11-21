defmodule ForemanAgent.Test.FakeRegistry do
  @moduledoc """
  An OCI registry holding devcontainer features, with the token or basic
  authentication a real one asks for. It listens on 127.0.0.1 and is
  addressed as `localhost:<port>`, which features refs reach over plain
  HTTP. Every request it gets is kept for a test to look at.
  """

  @behaviour Plug

  import Plug.Conn

  @empty_config "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"

  @doc """
  Starts a registry. Options:

    * `:auth` - `:none` (default), `{:bearer, user, password}` (pulls need a
      token, which the token service gives to those credentials or, with
      `:anonymous`, to anyone), or `{:basic, user, password}`
    * `:realm` - where a bearer challenge sends clients for a token (default:
      this registry's `/token`)
    * `:blob_redirect` - a base URL blob requests are redirected to
    * `:digest_header` - whether manifests come with `docker-content-digest`
    * `:delay` - milliseconds to wait before answering
  """
  def start(opts \\ []) do
    {:ok, state} =
      Agent.start_link(fn -> %{opts: Map.new(opts), manifests: %{}, blobs: %{}, requests: []} end)

    {:ok, pid} =
      Bandit.start_link(
        plug: {__MODULE__, state},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{state: state, port: port, host: "localhost:#{port}", url: "http://localhost:#{port}"}
  end

  @doc """
  Publishes a feature at `path` (`org/features/hello`) under `tag`, from its
  devcontainer-feature.json (a map) and any other files (name => content).
  Returns the manifest's digest.
  """
  def put_feature(registry, path, tag, metadata, files \\ %{}, opts \\ []) do
    files = Map.merge(%{"install.sh" => "#!/bin/sh\necho installed\n"}, files)
    # `:archive` is the layer itself; `:layer` is served in place of the one the manifest names.
    layer =
      opts[:archive] ||
        tar(
          Map.put(
            files,
            "devcontainer-feature.json",
            opts[:feature_json] || JSON.encode!(metadata)
          )
        )

    layer_digest = digest(layer)

    annotations =
      if Keyword.get(opts, :annotation, true),
        do: %{"dev.containers.metadata" => JSON.encode!(metadata)},
        else: %{}

    manifest =
      JSON.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "config" => %{
          "mediaType" => Keyword.get(opts, :config_media_type, "application/vnd.devcontainers"),
          "digest" => @empty_config,
          "size" => 0
        },
        "layers" => [
          %{
            "mediaType" => "application/vnd.devcontainers.layer.v1+tar",
            "digest" => layer_digest,
            "size" => byte_size(layer),
            "annotations" => %{
              "org.opencontainers.image.title" => "devcontainer-feature-#{metadata["id"]}.tgz"
            }
          }
        ],
        "annotations" => annotations
      })

    manifest_digest = digest(manifest)

    Agent.update(registry.state, fn state ->
      state
      |> put_in([:manifests, {path, tag}], manifest)
      |> put_in([:manifests, {path, manifest_digest}], manifest)
      |> put_in([:blobs, layer_digest], Keyword.get(opts, :layer, layer))
    end)

    manifest_digest
  end

  @doc "The requests so far, oldest first: `%{method, path, query, authorization}`."
  def requests(registry), do: registry.state |> Agent.get(& &1.requests) |> Enum.reverse()

  def digest(binary), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, binary), case: :lower)

  @doc "A tar archive of `files` (name => content), each at `./name`."
  def tar(files, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "fake-registry-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "layer.tar")

    entries =
      for {name, content} <- files do
        {~c"./" ++ String.to_charlist(name), content}
      end

    :ok = :erl_tar.create(String.to_charlist(path), entries, opts)
    binary = File.read!(path)
    File.rm_rf!(dir)
    binary
  end

  @impl Plug
  def init(state), do: state

  @impl Plug
  def call(conn, state) do
    conn = fetch_query_params(conn)
    authorization = conn |> get_req_header("authorization") |> List.first()

    request = %{
      method: conn.method,
      path: conn.request_path,
      host: conn.host,
      query: conn.query_params,
      authorization: authorization,
      body: read_all(conn)
    }

    Agent.update(state, fn s -> %{s | requests: [request | s.requests]} end)

    %{opts: opts} = snapshot = Agent.get(state, & &1)
    if opts[:delay], do: Process.sleep(opts[:delay])
    route(conn, conn.path_info, authorization, opts, snapshot)
  end

  defp read_all(conn) do
    case read_body(conn) do
      {:ok, body, _conn} -> body
      _ -> ""
    end
  end

  defp route(conn, ["token"], authorization, opts, _snapshot) do
    cond do
      opts[:token_redirect] ->
        conn |> put_resp_header("location", opts[:token_redirect]) |> send_resp(302, "")

      token_allowed?(authorization, opts) ->
        key = Map.get(opts, :token_key, "token")
        json(conn, 200, %{key => "tok-" <> (conn.query_params["scope"] || "")})

      true ->
        json(conn, 401, %{"errors" => [%{"code" => "UNAUTHORIZED"}]})
    end
  end

  defp route(conn, ["v2" | rest], authorization, opts, snapshot) do
    if authorized?(authorization, opts) do
      serve(conn, rest, opts, snapshot)
    else
      conn
      |> put_resp_header("www-authenticate", challenge(conn, rest, opts))
      |> send_resp(401, "")
    end
  end

  defp route(conn, _path, _authorization, _opts, _snapshot), do: send_resp(conn, 404, "")

  defp serve(conn, rest, opts, snapshot) do
    case Enum.split(rest, -2) do
      {path, ["manifests", reference]} ->
        manifest(conn, snapshot.manifests[{Enum.join(path, "/"), reference}], opts)

      {_path, ["blobs", blob_digest]} ->
        blob(conn, snapshot.blobs[blob_digest], opts)

      _ ->
        send_resp(conn, 404, "")
    end
  end

  defp manifest(conn, nil, _opts),
    do: send_resp(conn, 404, ~s({"errors":[{"code":"MANIFEST_UNKNOWN"}]}))

  defp manifest(conn, manifest, opts) do
    conn =
      if Map.get(opts, :digest_header, true),
        do: put_resp_header(conn, "docker-content-digest", digest(manifest)),
        else: conn

    conn
    |> put_resp_content_type("application/vnd.oci.image.manifest.v1+json")
    |> send_resp(200, manifest)
  end

  # Redirected to storage elsewhere, when there is some and this is the registry itself.
  defp blob(%{host: "localhost"} = conn, _blob, %{blob_redirect: storage}) do
    conn |> put_resp_header("location", storage <> conn.request_path) |> send_resp(307, "")
  end

  defp blob(conn, nil, _opts), do: send_resp(conn, 404, "")
  defp blob(conn, blob, _opts), do: send_resp(conn, 200, blob)

  defp authorized?(authorization, opts) do
    case Map.get(opts, :auth, :none) do
      :none ->
        true

      {:bearer, _, _} ->
        match?("Bearer tok-" <> _, authorization)

      {:basic, user, password} ->
        authorization == "Basic " <> Base.encode64("#{user}:#{password}")
    end
  end

  defp token_allowed?(authorization, opts) do
    {:bearer, user, password} = Map.fetch!(opts, :auth)

    cond do
      authorization == "Basic " <> Base.encode64("#{user}:#{password}") -> true
      is_nil(authorization) -> Map.get(opts, :anonymous, false)
      true -> false
    end
  end

  defp challenge(conn, rest, opts) do
    case Map.fetch!(opts, :auth) do
      {:basic, _, _} ->
        ~s(Basic realm="registry")

      {:bearer, _, _} ->
        repository = rest |> Enum.split(-2) |> elem(0) |> Enum.join("/")
        realm = Map.get(opts, :realm, "http://localhost:#{conn.port}/token")
        ~s(Bearer realm="#{realm}",service="registry.test",scope="repository:#{repository}:pull")
    end
  end

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
  end
end
