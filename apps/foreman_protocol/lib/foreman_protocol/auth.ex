defmodule ForemanProtocol.Auth do
  @moduledoc """
  Agent authentication and release signatures, both ed25519.

  An agent proves who it is on every socket connect by signing its id, the
  current time and a random nonce. The control plane checks the signature
  against the public key it stored at enrollment, rejects clocks more than
  `@max_skew` seconds off, and remembers nonces for twice that long so a
  captured header can't be replayed.

  Release signatures cover the version, the target and the tarball's
  SHA-256, so a valid signature for one build can't be reused for another.

  A box also relays public API requests for its environments
  (`relay_headers/4`). Each is signed on its own, over the environment it
  is for, the method, the request target and the body's SHA-256, so the
  signature is good for that one request and no other. The three kinds of
  message start with different words, so none passes for another.
  """

  @max_skew 60

  @header_id "x-foreman-agent-id"
  @header_ts "x-foreman-agent-ts"
  @header_nonce "x-foreman-agent-nonce"
  @header_sig "x-foreman-agent-sig"
  @header_env "x-foreman-environment"

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @methods ~w(GET POST PATCH PUT DELETE)

  def max_skew, do: @max_skew
  def header_names, do: [@header_id, @header_ts, @header_nonce, @header_sig]
  def relay_header_names, do: header_names() ++ [@header_env]

  @spec generate_keypair() :: {public :: binary(), private :: binary()}
  def generate_keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  @doc "Derives the public key from a private key."
  def public_key(private) do
    {public, ^private} = :crypto.generate_key(:eddsa, :ed25519, private)
    public
  end

  @spec connect_headers(String.t(), binary(), keyword()) :: %{String.t() => String.t()}
  def connect_headers(agent_id, private, opts \\ []) do
    ts = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    sig = :crypto.sign(:eddsa, :none, connect_message(agent_id, ts, nonce), [private, :ed25519])

    %{
      @header_id => agent_id,
      @header_ts => Integer.to_string(ts),
      @header_nonce => nonce,
      @header_sig => Base.encode64(sig)
    }
  end

  @doc """
  Verifies connect headers. `lookup` takes an agent id and returns
  `{:ok, public_key}` or `:error`. Nonce replay is the caller's job: the
  returned nonce must be checked against a short-lived seen-set.
  """
  @spec verify_connect_headers(map(), (String.t() -> {:ok, binary()} | :error), keyword()) ::
          {:ok, %{agent_id: String.t(), nonce: String.t(), ts: integer(), public_key: binary()}}
          | {:error, :malformed | :clock_skew | :unknown_agent | :bad_signature}
  def verify_connect_headers(headers, lookup, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with {:ok, agent_id, ts, nonce, sig} <- parse(headers),
         :ok <- check_skew(ts, now),
         {:ok, public} <- lookup_key(lookup, agent_id),
         :ok <- verify(connect_message(agent_id, ts, nonce), sig, public) do
      {:ok, %{agent_id: agent_id, nonce: nonce, ts: ts, public_key: public}}
    end
  end

  defp parse(headers) when is_map(headers) do
    with id when is_binary(id) and byte_size(id) in 1..64 <- headers[@header_id],
         ts when is_binary(ts) <- headers[@header_ts],
         {ts, ""} <- Integer.parse(ts),
         nonce when is_binary(nonce) and byte_size(nonce) in 16..64 <- headers[@header_nonce],
         sig when is_binary(sig) <- headers[@header_sig],
         {:ok, sig} <- Base.decode64(sig) do
      {:ok, id, ts, nonce, sig}
    else
      _ -> {:error, :malformed}
    end
  end

  defp parse(_), do: {:error, :malformed}

  defp check_skew(ts, now) when abs(now - ts) <= @max_skew, do: :ok
  defp check_skew(_ts, _now), do: {:error, :clock_skew}

  defp lookup_key(lookup, agent_id) do
    case lookup.(agent_id) do
      {:ok, public} when is_binary(public) -> {:ok, public}
      _ -> {:error, :unknown_agent}
    end
  end

  defp connect_message(agent_id, ts, nonce), do: "foreman-agent-v1\n#{agent_id}\n#{ts}\n#{nonce}"

  @type relay_request :: %{
          required(:environment) => String.t(),
          required(:method) => String.t(),
          required(:target) => String.t(),
          required(:body) => binary(),
          optional(:idempotency_key) => String.t() | nil
        }

  @doc """
  Headers for one public API request a box sends for `environment`.
  `target` is the path and query exactly as sent. Raises on a field that
  could be read as another once the fields are joined.
  """
  @spec relay_headers(String.t(), binary(), relay_request(), keyword()) ::
          %{String.t() => String.t()}
  def relay_headers(agent_id, private, %{environment: env} = request, opts \\ []) do
    ts = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    digest = :crypto.hash(:sha256, request.body)

    signed = %{
      environment: env,
      method: request.method,
      target: request.target,
      body_sha256: digest,
      idempotency_key: request[:idempotency_key]
    }

    message =
      case relay_message(agent_id, ts, nonce, signed) do
        {:ok, message} -> message
        :error -> raise ArgumentError, "a relayed request has a field that can't be signed"
      end

    sig = :crypto.sign(:eddsa, :none, message, [private, :ed25519])

    %{
      @header_id => agent_id,
      @header_ts => Integer.to_string(ts),
      @header_nonce => nonce,
      @header_env => env,
      @header_sig => Base.encode64(sig)
    }
  end

  @doc """
  Verifies a relayed request's headers against the request that arrived:
  its method, its target, the SHA-256 of the body that was read and its
  idempotency key (`nil` for none). Nonce replay is the caller's job, as
  with a connect.
  """
  @spec verify_relay_headers(
          map(),
          (String.t() -> {:ok, binary()} | :error),
          %{
            required(:method) => String.t(),
            required(:target) => String.t(),
            required(:body_sha256) => binary(),
            optional(:idempotency_key) => String.t() | nil
          },
          keyword()
        ) ::
          {:ok,
           %{agent_id: String.t(), environment: String.t(), nonce: String.t(), ts: integer()}}
          | {:error, :malformed | :clock_skew | :unknown_agent | :bad_signature}
  def verify_relay_headers(headers, lookup, seen, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with {:ok, agent_id, ts, nonce, sig} <- parse(headers),
         env when is_binary(env) <- headers[@header_env],
         {:ok, message} <- relay_message(agent_id, ts, nonce, Map.put(seen, :environment, env)),
         :ok <- check_skew(ts, now),
         {:ok, public} <- lookup_key(lookup, agent_id),
         :ok <- verify(message, sig, public) do
      {:ok, %{agent_id: agent_id, environment: env, nonce: nonce, ts: ts}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  # Newlines separate the fields, so none may hold one. The agent id and
  # the nonce come from headers, which can't, and are checked all the same.
  # A request with no idempotency key signs an empty field, which no key is.
  defp relay_message(agent_id, ts, nonce, signed) do
    with %{environment: env, method: method, target: target, body_sha256: digest} <- signed,
         key = Map.get(signed, :idempotency_key),
         true <- signable?(agent_id <> nonce) and environment?(env) and method in @methods,
         true <- target?(target) and digest?(digest) and key?(key) do
      fields = [agent_id, ts, nonce, env, method, target, Base.encode16(digest, case: :lower)]
      {:ok, Enum.join(["foreman-relay-v1" | fields] ++ [key || ""], "\n")}
    else
      _ -> :error
    end
  end

  defp key?(nil), do: true
  defp key?(key), do: is_binary(key) and Regex.match?(~r/\A[\x21-\x7E]{1,255}\z/, key)

  defp environment?(env), do: is_binary(env) and Regex.match?(@uuid, env)
  defp digest?(digest), do: is_binary(digest) and byte_size(digest) == 32

  defp target?(target) do
    is_binary(target) and String.starts_with?(target, "/") and byte_size(target) <= 4096 and
      signable?(target) and not String.contains?(target, " ")
  end

  defp signable?(value), do: not String.contains?(value, ["\n", "\r"])

  @spec sign_release(String.t(), String.t(), String.t(), binary()) :: String.t()
  def sign_release(version, target, sha256, private) do
    :eddsa
    |> :crypto.sign(:none, release_message(version, target, sha256), [private, :ed25519])
    |> Base.encode64()
  end

  @spec verify_release(String.t(), String.t(), String.t(), String.t(), binary()) ::
          :ok | {:error, :bad_signature}
  def verify_release(version, target, sha256, signature, public) do
    case Base.decode64(signature) do
      {:ok, sig} -> verify(release_message(version, target, sha256), sig, public)
      :error -> {:error, :bad_signature}
    end
  end

  defp release_message(version, target, sha256),
    do: "foreman-release-v1\n#{version}\n#{target}\n#{sha256}"

  defp verify(message, sig, public) do
    if byte_size(sig) == 64 and byte_size(public) == 32 and
         :crypto.verify(:eddsa, :none, message, sig, [public, :ed25519]) do
      :ok
    else
      {:error, :bad_signature}
    end
  end
end
