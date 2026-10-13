defmodule Foreman.Agents.Releases do
  @moduledoc """
  Agent releases the control plane serves for self-update.

  CI builds and signs each release (the signing key never touches the
  control plane) and an admin registers the tarball here. When a box's
  desired agent version differs from what it runs, the box gets an
  `agent.update` command on its next connect.
  """
  import Ecto.Query

  alias Foreman.Agents.Release
  alias Foreman.{Operations, Repo}
  alias ForemanProtocol.{Auth, Command}

  def list, do: Release |> order_by(desc: :inserted_at) |> Repo.all()

  def get(version, target), do: Repo.get_by(Release, version: version, target: target)

  def storage_dir do
    Application.get_env(
      :foreman,
      :agent_release_dir,
      Path.join(System.tmp_dir!(), "foreman-agent-releases")
    )
  end

  @doc """
  Registers a release tarball. The signature must verify against the
  configured release public key, so the control plane can't be used to
  hand out a build CI didn't sign.
  """
  # sobelow_skip ["Traversal.FileModule"]
  # version and target are checked against strict patterns before they
  # reach a path; tarball_path is the admin's own upload.
  def register(version, target, tarball_path, signature) do
    with :ok <- check_name(version, ~r/\A\d{1,4}\.\d{1,4}\.\d{1,4}(-[0-9A-Za-z.]{1,32})?\z/, "version"),
         :ok <- check_name(target, ~r/\A(linux|darwin)-(amd64|arm64)\z/, "target") do
      do_register(version, target, tarball_path, signature)
    end
  end

  defp check_name(value, pattern, label) do
    if is_binary(value) and Regex.match?(pattern, value), do: :ok, else: {:error, "invalid #{label}"}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp do_register(version, target, tarball_path, signature) do
    sha =
      tarball_path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    with {:ok, key} <- public_key(),
         :ok <- Auth.verify_release(version, target, sha, signature, key) do
      dest = Path.join(storage_dir(), "foreman_agent-#{version}-#{target}.tar.gz")
      File.mkdir_p!(storage_dir())
      File.cp!(tarball_path, dest)

      %Release{
        version: version,
        target: target,
        sha256: sha,
        signature: signature,
        size: File.stat!(dest).size,
        path: dest
      }
      |> Repo.insert(on_conflict: :replace_all, conflict_target: [:version, :target])
    else
      {:error, :bad_signature} -> {:error, "the signature doesn't verify against the release key"}
      error -> error
    end
  end

  defp public_key do
    case Application.get_env(:foreman, :agent_release_public_key) do
      key when is_binary(key) and key != "" -> {:ok, Base.decode64!(key)}
      _ -> {:error, "no agent release key configured (FOREMAN_AGENT_RELEASE_PUBLIC_KEY)"}
    end
  end

  @doc "Sends agent.update to a box whose desired version differs from what it runs."
  def maybe_update(box) do
    with version when is_binary(version) <- box.desired_agent_version,
         true <- version != box.agent_version,
         target when is_binary(target) <- box.arch,
         %Release{} = release <- get(version, target) do
      url = "#{Foreman.Config.base_url()}/agent/releases/#{version}/#{target}"

      {:ok, cmd} =
        Command.new("agent.update", %{
          version: version,
          url: url,
          sha256: release.sha256,
          signature: release.signature
        })

      Operations.create!(%{
        id: cmd.op_id,
        box_id: box.id,
        action: "agent.update",
        command: "agent.update",
        status: "dispatched",
        dispatched_at: DateTime.utc_now(),
        args: %{"version" => version}
      })

      Foreman.Agents.dispatch(box.id, cmd)
    else
      _ -> :ok
    end
  end
end
