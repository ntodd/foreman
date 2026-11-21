defmodule ForemanAgent.Devcontainer.Features.Registry do
  @moduledoc """
  Pulls devcontainer features from OCI registries: a feature's manifest,
  and the one layer that holds its files.

  A registry's credentials (from a Docker config's `auths`) go to that
  registry and to nowhere it sends us:

    * a redirect to another origin is followed without them
    * a token is asked for only from the registry's own authority, or from
      the token service a registry is known to use (Docker Hub's, GitLab's,
      or a pairing the caller trusts), over HTTPS (plain HTTP on localhost)
    * a token service's own redirect isn't followed
    * a challenge that comes from anywhere but the registry gets no
      credentials

  A token is kept for the registry for as long as the client lives, in the
  process that made it.
  """

  alias ForemanAgent.Devcontainer.Features.Ref

  @manifest_type "application/vnd.oci.image.manifest.v1+json"
  @feature_config_type "application/vnd.devcontainers"

  @token_services ~w(
    registry-1.docker.io=auth.docker.io
    registry.docker.io=auth.docker.io
    docker.io=auth.docker.io
    index.docker.io=auth.docker.io
    registry.gitlab.com=gitlab.com
  )
  @docker_hub ~w(registry-1.docker.io registry.docker.io docker.io index.docker.io)

  @max_redirects 10
  @defaults [
    auths: %{},
    token_services: [],
    max_manifest_bytes: 4 * 1024 * 1024,
    max_blob_bytes: 256 * 1024 * 1024,
    receive_timeout: 60_000
  ]

  @enforce_keys [:auths, :log, :tokens, :opts]
  defstruct [:auths, :log, :tokens, :opts]

  @type t :: %__MODULE__{}

  @doc """
  A client. Options:

    * `:auths` - a Docker config's `auths`: registry host => `%{"auth" => base64}`
      (or an `"identitytoken"`)
    * `:token_services` - `registry-host=auth-host` pairings to trust besides
      the built-in ones
    * `:log` - `fn text -> any end`, for what a person debugging a pull needs
    * `:deadline` - when to stop asking, in monotonic milliseconds
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.merge(@defaults, opts)

    %__MODULE__{
      auths: opts[:auths] || %{},
      log: opts[:log] || fn _ -> :ok end,
      tokens: :ets.new(:registry_tokens, [:set, :private]),
      opts: opts
    }
  end

  @doc """
  The credentials to pull features with: a Docker config's `auths`, and
  what the environment carries the way the devcontainer CLI reads it.
  `DEVCONTAINERS_OCI_AUTH` (`registry|user|token`, comma-separated) comes
  first, then the Docker config, then a `GITHUB_TOKEN` for ghcr.io.
  """
  @spec auths(map(), %{String.t() => String.t()}) :: map()
  def auths(docker_auths, env) do
    github =
      case github_token(env) do
        nil -> %{}
        token -> %{"ghcr.io" => %{"auth" => Base.encode64("USERNAME:#{token}")}}
      end

    explicit =
      for entry <- String.split(env["DEVCONTAINERS_OCI_AUTH"] || "", ",", trim: true),
          [registry, user, token] <- [String.split(entry, "|")],
          into: %{},
          do: {registry, %{"auth" => Base.encode64("#{user}:#{token}")}}

    github |> Map.merge(docker_auths) |> Map.merge(explicit)
  end

  @doc "The environment's GitHub token, when it's one for github.com."
  @spec github_token(%{String.t() => String.t()}) :: String.t() | nil
  def github_token(env) do
    case {env["GITHUB_TOKEN"], env["GITHUB_HOST"]} do
      {token, host} when is_binary(token) and token != "" and host in [nil, "", "github.com"] ->
        token

      _ ->
        nil
    end
  end

  @doc """
  A feature's manifest, by the ref's tag or digest, or by `digest` when
  given (a lock file's). `:not_found` when the registry has no such
  feature, which is also the answer for a name that isn't a registry.
  """
  @spec manifest(t(), Ref.t(), String.t() | nil) ::
          {:ok, %{manifest: map(), digest: String.t()}} | {:error, :not_found | String.t()}
  def manifest(client, %Ref{} = ref, digest \\ nil) do
    expected = digest || ref.digest
    url = "#{ref.scheme}://#{ref.registry}/v2/#{ref.path}/manifests/#{digest || ref.version}"

    with true <- registry_host?(ref.registry) || {:error, :not_found},
         {:ok, %{status: 200} = response} <-
           get(client, ref, url, @manifest_type, client.opts[:max_manifest_bytes]),
         content = content_digest(response, expected),
         true <- (is_nil(expected) or content == expected) || {:error, mismatch(ref)},
         {:ok, %{"config" => %{"mediaType" => @feature_config_type}} = manifest} <-
           JSON.decode(response.body) do
      {:ok, %{manifest: manifest, digest: content}}
    else
      {:ok, %{status: status}} when status in 400..499 ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, "#{ref.registry} answered #{status} for #{ref.resource}"}

      {:ok, _manifest} ->
        client.log.("#{ref.resource} isn't a devcontainer feature")
        {:error, :not_found}

      {:error, %JSON.DecodeError{}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The content of a feature's layer, checked against its digest."
  @spec blob(t(), Ref.t(), String.t()) :: {:ok, binary()} | {:error, String.t()}
  def blob(client, %Ref{} = ref, digest) do
    url = "#{ref.scheme}://#{ref.registry}/v2/#{ref.path}/blobs/#{digest}"

    case get(client, ref, url, @manifest_type, client.opts[:max_blob_bytes]) do
      {:ok, %{status: 200, body: body}} ->
        if sha256(body) == digest, do: {:ok, body}, else: {:error, mismatch(ref)}

      {:ok, %{status: status}} ->
        {:error, "#{ref.registry} answered #{status} for #{ref.resource}"}

      {:error, :not_found} ->
        {:error, "couldn't download #{ref.resource}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Whether a registry at `registry_url` may send us to `realm` for a token.
  """
  @spec trusted_realm?(String.t(), String.t(), [String.t()]) :: boolean()
  def trusted_realm?(realm, registry_url, token_services) do
    with %URI{scheme: scheme, host: host} = realm when is_binary(host) <- parse(realm),
         %URI{} = registry <- parse(registry_url) do
      same_authority? = authority(realm) == authority(registry)

      (same_authority? and (scheme == "https" or (scheme == "http" and host == "localhost"))) or
        (scheme == "https" and
           "#{authority(registry)}=#{authority(realm)}" in (@token_services ++
                                                              Enum.map(
                                                                token_services,
                                                                &String.downcase/1
                                                              )))
    else
      _ -> false
    end
  end

  # -- requests ------------------------------------------------------------

  # A GET the registry may want authentication for.
  defp get(client, ref, url, accept, max_bytes) do
    headers = [{"accept", accept}]
    ours? = registry_origin?(url, ref)
    cached = if ours?, do: token(client, ref.registry)

    case request(client, :get, url, with_authorization(headers, cached), max_bytes, ref) do
      {:ok, %{status: status} = response} when status in [401, 403] ->
        challenged = ours? and registry_origin?(response.url, ref)

        with {:ok, authorization} <- authorize(client, ref, response, challenged),
             {:ok, retried} <-
               request(
                 client,
                 :get,
                 url,
                 with_authorization(headers, authorization),
                 max_bytes,
                 ref
               ) do
          if retried.status != 401 and challenged,
            do: :ets.insert(client.tokens, {ref.registry, authorization})

          {:ok, retried}
        else
          :error ->
            :ets.delete(client.tokens, ref.registry)
            {:error, "couldn't authenticate with #{ref.registry}"}

          {:error, reason} ->
            {:error, reason}
        end

      other ->
        other
    end
  end

  defp token(client, registry) do
    case :ets.lookup(client.tokens, registry) do
      [{_, authorization}] -> authorization
      [] -> nil
    end
  end

  defp with_authorization(headers, nil), do: headers

  defp with_authorization(headers, authorization),
    do: [{"authorization", authorization} | headers]

  # What to answer a 401 or 403 with: the Authorization header to retry
  # with, from the registry's challenge.
  defp authorize(client, ref, response, challenged) do
    challenge = header(response, "www-authenticate") || ""

    case challenge |> String.split(" ", parts: 2) |> hd() |> String.downcase() do
      "basic" ->
        with true <- challenged || refused(client, ref, response),
             %{basic: basic} when is_binary(basic) <- credential(client, ref.registry) do
          {:ok, "Basic " <> basic}
        else
          _ -> :error
        end

      "bearer" ->
        bearer(client, ref, response, challenge, challenged)

      _ ->
        client.log.(
          "#{authority(parse(response.url))} asked for authentication Foreman doesn't know"
        )

        :error
    end
  end

  defp refused(client, ref, response) do
    client.log.(
      "Not sending #{ref.registry}'s credentials to #{authority(parse(response.url))}, which asked for them"
    )

    false
  end

  defp bearer(client, ref, response, challenge, challenged) do
    with [_, realm] <- Regex.run(~r/realm="([^"]+)"/, challenge),
         [_, service] <- Regex.run(~r/service="([^"]+)"/, challenge),
         true <-
           trusted_realm?(realm, response.url, client.opts[:token_services]) ||
             untrusted(client, response, realm) do
      scope =
        case Regex.run(~r/scope="([^"]+)"/, challenge) do
          [_, scope] -> scope
          nil -> ""
        end

      credential = if challenged, do: credential(client, ref.registry), else: %{}

      case request_token(client, ref, realm, service, scope, credential) do
        {:ok, token} -> {:ok, "Bearer " <> token}
        :error -> :error
      end
    else
      _ -> :error
    end
  end

  defp untrusted(client, response, realm) do
    client.log.(
      "Registry #{authority(parse(response.url))} asked for authentication from the untrusted realm #{realm}"
    )

    false
  end

  defp request_token(client, ref, realm, service, scope, credential) do
    anonymous = fn ->
      token_request(client, ref, :get, token_url(realm, service, scope), [], nil)
    end

    result =
      case credential do
        %{refresh: refresh} when is_binary(refresh) ->
          body =
            URI.encode_query(%{
              "client_id" => "devcontainer",
              "grant_type" => "refresh_token",
              "service" => service,
              "scope" => scope,
              "refresh_token" => refresh
            })

          headers = [{"content-type", "application/x-www-form-urlencoded"}]
          retry_anonymously(token_request(client, ref, :post, realm, headers, body), anonymous)

        %{basic: basic} when is_binary(basic) ->
          headers = [{"authorization", "Basic " <> basic}]

          retry_anonymously(
            token_request(client, ref, :get, token_url(realm, service, scope), headers, nil),
            anonymous
          )

        _ ->
          anonymous.()
      end

    with {:ok, %{status: status, body: body}} when status in 200..299 <- result,
         {:ok, %{} = json} <- JSON.decode(body),
         token when is_binary(token) <- json["token"] || json["access_token"] do
      {:ok, token}
    else
      _ ->
        client.log.("Couldn't get a token for #{service} from #{realm}")
        :error
    end
  end

  # Credentials can have expired; what they'd pull may be public.
  defp retry_anonymously({:ok, %{status: status}}, anonymous) when status in [401, 403],
    do: anonymous.()

  defp retry_anonymously(result, _anonymous), do: result

  defp token_request(client, ref, method, url, headers, body) do
    request(client, method, url, headers, 1024 * 1024, ref, body: body, redirects: 0)
  end

  defp token_url(realm, service, scope) do
    uri = URI.parse(realm)

    query =
      uri.query
      |> Kernel.||("")
      |> URI.decode_query()
      |> Map.merge(%{"service" => service, "scope" => scope})

    URI.to_string(%{uri | query: URI.encode_query(query)})
  end

  defp credential(client, registry) do
    case client.auths[registry] do
      %{"identitytoken" => refresh} when is_binary(refresh) and refresh != "" ->
        %{refresh: refresh}

      %{"auth" => basic} when is_binary(basic) and basic != "" ->
        %{basic: basic}

      _ ->
        %{}
    end
  end

  # One request, following redirects itself: a redirect to another origin
  # goes without the Authorization header.
  defp request(client, method, url, headers, max_bytes, ref, opts \\ []) do
    redirects = Keyword.get(opts, :redirects, @max_redirects)
    do_request(client, method, url, headers, max_bytes, ref, opts[:body], redirects)
  end

  defp do_request(client, method, url, headers, max_bytes, ref, body, redirects) do
    if time_left(client) <= 0,
      do: {:error, "there was no time left to reach #{authority(parse(url))}"},
      else: send_request(client, method, url, headers, max_bytes, ref, body, redirects)
  end

  defp time_left(client) do
    case client.opts[:deadline] do
      nil ->
        client.opts[:receive_timeout]

      deadline ->
        min(client.opts[:receive_timeout], deadline - System.monotonic_time(:millisecond))
    end
  end

  defp send_request(client, method, url, headers, max_bytes, ref, body, redirects) do
    request =
      Req.new(
        method: method,
        url: url,
        headers: [{"user-agent", "devcontainer"} | headers],
        body: body,
        redirect: false,
        retry: false,
        decode_body: false,
        compressed: false,
        receive_timeout: max(time_left(client), 1),
        into: collector(client, max_bytes)
      )

    case Req.request(request) do
      {:ok, %Req.Response{private: %{too_large: true}}} ->
        {:error, "#{ref.resource} is larger than Foreman downloads (#{max_bytes} bytes)"}

      {:ok, %Req.Response{private: %{timed_out: true}}} ->
        {:error, "there was no time left to reach #{authority(parse(url))}"}

      {:ok, %Req.Response{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        case {redirects, Req.Response.get_header(response, "location")} do
          {n, [location | _]} when n > 0 ->
            next = url |> URI.merge(location) |> URI.to_string()

            headers =
              if origin(next) == origin(url), do: headers, else: without_authorization(headers)

            do_request(client, method, next, headers, max_bytes, ref, body, redirects - 1)

          _ ->
            {:ok, result(response, url)}
        end

      {:ok, response} ->
        {:ok, result(response, url)}

      {:error, exception} ->
        client.log.("Request to #{authority(parse(url))} failed: #{Exception.message(exception)}")
        {:error, "couldn't reach #{authority(parse(url))}"}
    end
  end

  defp result(response, url) do
    body = response.private |> Map.get(:chunks, []) |> Enum.reverse() |> IO.iodata_to_binary()
    %{status: response.status, headers: response.headers, body: body, url: url}
  end

  # Keeps a response's body as it arrives, up to `max_bytes`.
  # Keeps a response's body as it arrives, up to `max_bytes` and until
  # the deadline: a body that trickles in is given up on too.
  defp collector(client, max_bytes) do
    fn {:data, data}, {request, response} ->
      size = Map.get(response.private, :size, 0) + byte_size(data)

      cond do
        size > max_bytes ->
          {:halt, {request, Req.Response.put_private(response, :too_large, true)}}

        time_left(client) <= 0 ->
          {:halt, {request, Req.Response.put_private(response, :timed_out, true)}}

        true ->
          response =
            response
            |> Req.Response.put_private(:size, size)
            |> Req.Response.put_private(:chunks, [data | Map.get(response.private, :chunks, [])])

          {:cont, {request, response}}
      end
    end
  end

  defp without_authorization(headers),
    do: Enum.reject(headers, fn {name, _} -> String.downcase(name) == "authorization" end)

  defp header(response, name) do
    case response.headers[name] do
      [value | _] -> value
      _ -> nil
    end
  end

  defp content_digest(response, expected) do
    # A digest we're holding the content to is one we work out ourselves.
    if expected,
      do: sha256(response.body),
      else: header(response, "docker-content-digest") || sha256(response.body)
  end

  defp sha256(body), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)

  defp mismatch(ref), do: "the digest of #{ref.resource} doesn't match"

  # Whether `url` is the registry itself. Docker Hub goes by several names.
  defp registry_origin?(url, ref) do
    registry = "#{ref.scheme}://#{ref.registry}"

    origin(url) == origin(registry) or
      (String.starts_with?(url, "https://") and ref.scheme == "https" and
         authority(parse(url)) in @docker_hub and authority(parse(registry)) in @docker_hub)
  end

  # A name with no dot in it isn't a host worth a DNS lookup.
  defp registry_host?(registry),
    do: String.contains?(registry, ".") or String.starts_with?(registry, "localhost")

  defp parse(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        uri

      _ ->
        nil
    end
  end

  defp origin(url) do
    case parse(url) do
      nil -> nil
      uri -> {uri.scheme, authority(uri)}
    end
  end

  # host[:port], with the scheme's own port left off.
  defp authority(nil), do: nil

  defp authority(%URI{host: host, port: port, scheme: scheme}) do
    host = String.downcase(host)
    if port == URI.default_port(scheme), do: host, else: "#{host}:#{port}"
  end
end
