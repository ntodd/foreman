defmodule ForemanAgent.Identity do
  @moduledoc """
  The agent's id and ed25519 private key, stored in `<data_dir>/identity.json`
  (mode 0600). Created once by enrolling with a single-use join token.
  """

  alias ForemanProtocol.Auth

  @enforce_keys [:agent_id, :private_key]
  defstruct [:agent_id, :private_key]

  @type t :: %__MODULE__{agent_id: String.t(), private_key: binary()}

  @spec load(Path.t()) :: {:ok, t()} | :none | {:error, term()}
  def load(data_dir) do
    path = path(data_dir)

    # Anything wrong with the file is an error the connection retries on,
    # not a crash: crashing here would restart-loop the whole agent.
    case File.read(path) do
      {:ok, json} ->
        with {:ok, %{"agent_id" => id, "private_key" => key}}
             when is_binary(id) and id != "" and is_binary(key) <- JSON.decode(json),
             {:ok, key} when byte_size(key) == 32 <- Base.decode64(key) do
          remember(key)
          {:ok, %__MODULE__{agent_id: id, private_key: key}}
        else
          _ -> {:error, "#{path} is damaged; re-enroll this box (install.sh --reenroll)"}
        end

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Registers this agent's new public key with the control plane, using a
  join token, and saves the identity.
  """
  @spec enroll(ForemanAgent.Config.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def enroll(config, opts \\ []) do
    {public, private} = Auth.generate_keypair()

    body = %{
      "join_token" => config.join_token,
      "public_key" => Base.encode64(public),
      "hostname" => hostname(),
      "os" => to_string(elem(:os.type(), 1)),
      "arch" => ForemanAgent.Updater.target(),
      "agent_version" => version()
    }

    url = String.trim_trailing(config.url, "/") <> "/api/agents/enroll"

    case Req.post([url: url, json: body, retry: false] ++ Keyword.get(opts, :req_options, [])) do
      {:ok, %Req.Response{status: 201, body: %{"agent_id" => agent_id}}} ->
        identity = %__MODULE__{agent_id: agent_id, private_key: private}
        :ok = save(config.data_dir, identity)
        {:ok, identity}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "enrollment refused (HTTP #{status}): #{error_message(body)}"}

      {:error, exception} ->
        {:error, "couldn't reach #{url}: #{Exception.message(exception)}"}
    end
  end

  defp error_message(%{"error" => message}), do: message
  defp error_message(_), do: "no details"

  @doc """
  The key as the identity file holds it, for `ForemanAgent.Redactor` to
  scrub from everything the agent sends: a compose error can quote any
  file the agent can read, this one included.
  """
  @spec secrets() :: [String.t()]
  def secrets, do: :persistent_term.get({__MODULE__, :secrets}, [])

  defp remember(key), do: :persistent_term.put({__MODULE__, :secrets}, [Base.encode64(key)])

  def save(data_dir, %__MODULE__{} = identity) do
    remember(identity.private_key)
    File.mkdir_p!(data_dir)
    File.chmod!(data_dir, 0o700)

    json =
      JSON.encode!(%{
        "agent_id" => identity.agent_id,
        "private_key" => Base.encode64(identity.private_key)
      })

    ForemanAgent.SafeFS.write_atomic(path(data_dir), json, 0o600)
  end

  defp path(data_dir), do: Path.join(data_dir, "identity.json")

  def hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  def version, do: :foreman_agent |> Application.spec(:vsn) |> to_string()
end
