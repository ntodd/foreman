defmodule Foreman.Boxes do
  @moduledoc """
  Boxes and their agents: enrollment with single-use join tokens, the
  public keys agents sign their connects with, and online status.

  An admin creates a join token for a named box (owned by a user). The
  agent generates its own keypair and enrolls with the token, which is
  then spent; only the public key is stored. Revoking a box deletes the
  key and drops its socket immediately.
  """
  import Ecto.Query

  alias Foreman.Boxes.{Box, JoinToken}
  alias Foreman.{Audit, Repo, Scope}

  @token_ttl 3600

  def list_boxes(%Scope{} = scope) do
    query = from b in Box, where: is_nil(b.revoked_at), order_by: b.name, preload: :owner_user

    if Scope.admin?(scope),
      do: Repo.all(query),
      else: query |> Repo.all() |> Enum.filter(&Box.usable_by?(&1, scope.user))
  end

  @doc "Boxes `scope`'s user may place environments on."
  def usable_boxes(%Scope{user: user} = scope) do
    scope |> list_boxes() |> Enum.filter(&Box.usable_by?(&1, user))
  end

  def get_box!(id), do: Box |> Repo.get!(id) |> Repo.preload(:owner_user)
  def get_box(id), do: Repo.get(Box, id)

  def get_visible_box!(%Scope{} = scope, id) do
    box = get_box!(id)

    if Scope.admin?(scope) or Box.usable_by?(box, scope.user),
      do: box,
      else: raise(Ecto.NoResultsError, queryable: Box)
  end

  # -- enrollment ----------------------------------------------------------------

  @doc """
  Creates a join token for a box. Returns the raw token, which is shown
  once; only its hash is stored.
  """
  def create_join_token(%Scope{} = scope, attrs) do
    changeset =
      {%{}, %{box_name: :string, owner_user_id: :binary_id}}
      |> Ecto.Changeset.cast(attrs, [:box_name, :owner_user_id])
      |> Ecto.Changeset.validate_required([:box_name])
      |> Ecto.Changeset.validate_format(:box_name, ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/,
        message: "must be lowercase letters, digits and dashes"
      )

    cond do
      not Scope.admin?(scope) ->
        {:error, :unauthorized}

      not changeset.valid? ->
        {:error, %{changeset | action: :insert}}

      true ->
        data = Ecto.Changeset.apply_changes(changeset)
        raw = "fj_" <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

        Repo.insert!(%JoinToken{
          token_hash: hash(raw),
          box_name: data.box_name,
          owner_user_id: data[:owner_user_id] || scope.user.id,
          created_by_id: scope.user.id,
          expires_at: DateTime.add(DateTime.utc_now(), @token_ttl)
        })

        Audit.log(scope, "box.join_token", {"Box", data.box_name})
        {:ok, raw}
    end
  end

  @doc """
  Enrolls an agent: spends the join token and records the agent's public
  key. Re-enrolling an existing box name replaces its key.
  """
  def enroll(raw_token, attrs) when is_binary(raw_token) do
    now = DateTime.utc_now()

    Repo.transact(fn ->
      with %JoinToken{} = token <- Repo.get_by(JoinToken, token_hash: hash(raw_token)),
           true <- is_nil(token.used_at) and DateTime.compare(token.expires_at, now) == :gt,
           {:ok, public_key} <- decode_key(attrs["public_key"]),
           {:ok, box} <- upsert_enrolled_box(token, public_key, attrs) do
        token |> Ecto.Changeset.change(used_at: now, box_id: box.id) |> Repo.update!()
        Audit.log(nil, "box.enroll", box, %{"hostname" => attrs["hostname"]})
        disconnect(box)
        {:ok, box}
      else
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        {:error, :bad_key} -> {:error, :bad_key}
        _ -> {:error, :invalid_token}
      end
    end)
  end

  def enroll(_, _), do: {:error, :invalid_token}

  defp upsert_enrolled_box(token, public_key, attrs) do
    box = Repo.get_by(Box, name: token.box_name) || %Box{name: token.box_name}

    if box.revoked_at do
      {:error, :revoked}
    else
      box
      |> Ecto.Changeset.change(
        public_key: public_key,
        owner_user_id: box.owner_user_id || token.owner_user_id,
        hostname: attrs["hostname"],
        os: attrs["os"],
        arch: attrs["arch"],
        agent_version: attrs["agent_version"]
      )
      |> Box.validate_name()
      |> Repo.insert_or_update()
    end
  end

  defp decode_key(key) when is_binary(key) do
    case Base.decode64(key) do
      {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
      _ -> {:error, :bad_key}
    end
  end

  defp decode_key(_), do: {:error, :bad_key}

  defp hash(raw), do: :crypto.hash(:sha256, raw)

  @doc "The public key an agent's connect headers must verify against."
  def public_key(agent_id) do
    with {:ok, _} <- Ecto.UUID.cast(agent_id),
         %Box{revoked_at: nil, public_key: key} when is_binary(key) <- Repo.get(Box, agent_id) do
      {:ok, key}
    else
      _ -> :error
    end
  end

  # -- agent presence ------------------------------------------------------------

  def online?(box_id), do: Registry.lookup(Foreman.Registry, {:agent, box_id}) != []

  def agent_joined(%Box{} = box, join) do
    box =
      box
      |> Ecto.Changeset.change(
        agent_version: join.agent_version,
        protocol_version: join.protocol_version,
        feature_version: feature_version(join),
        hostname: join.hostname,
        os: join.os,
        arch: join.arch,
        policy: if(join.policy == %{}, do: nil, else: join.policy),
        last_seen_at: DateTime.utc_now()
      )
      |> Repo.update!()

    broadcast(box, :online)
    box
  end

  @policy_labels %{
    "privileged" =>
      "privileged containers (docker-in-docker, privileged: true, SYS_ADMIN and the like)",
    "host_namespace" => "the host's network, PID or IPC namespace",
    "docker_socket" => "the Docker socket",
    "host_bind" => "bind mounts from outside the workspace",
    "host_file" => "env files, secrets and build contexts from outside the workspace",
    "devices" => "host devices",
    "gpu" =>
      "NVIDIA GPUs. Environments on this box share them, and Foreman doesn't limit or isolate GPU memory between them",
    "seccomp" => "containers with seccomp turned off (seccomp=unconfined)",
    "compose_keys" => "compose settings Foreman hasn't reviewed"
  }

  @doc """
  The rules a box's agent has opened up from the default (refuse
  everything), each with what it lets in. Empty for a box on the default
  policy, and for one whose agent hasn't reported a policy.
  """
  def policy_exceptions(%Box{policy: policy}) when is_map(policy) do
    for {rule, action} <- ForemanProtocol.Policy.relaxed(policy) do
      %{rule: rule, action: action, label: Map.fetch!(@policy_labels, rule)}
    end
    |> Enum.sort_by(&(&1.rule != "privileged"))
  end

  def policy_exceptions(%Box{}), do: []

  def agent_left(box_id) do
    if box = get_box(box_id) do
      box |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now()) |> Repo.update!()
      broadcast(box, :offline)
    end

    :ok
  end

  def record_capacity(box_id, capacity) do
    from(b in Box, where: b.id == ^box_id)
    |> Repo.update_all(set: [capacity: stringify(capacity), last_seen_at: DateTime.utc_now()])

    Phoenix.PubSub.broadcast(Foreman.PubSub, "boxes", {:box_stats, box_id})
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # -- settings ------------------------------------------------------------------

  def update_box(%Scope{} = scope, %Box{} = box, attrs) do
    with :ok <- authorize_admin(scope),
         {:ok, updated} <- box |> settings_changeset(normalize(attrs)) |> Repo.update() do
      Audit.log(scope, "box.update", updated)
      broadcast(updated, :updated)

      if updated.desired_agent_version != box.desired_agent_version and online?(updated.id),
        do: Foreman.Agents.Releases.maybe_update(updated)

      {:ok, updated}
    end
  end

  @doc """
  Sends a box the agent version that failed on it again. After two
  failures in a row a version isn't sent by itself any more.
  """
  def retry_agent_update(%Scope{} = scope, %Box{} = box) do
    with :ok <- authorize_admin(scope),
         {:ok, updated} <-
           box |> Ecto.Changeset.change(failed_agent_version: nil) |> Repo.update() do
      Foreman.Agents.Releases.forget_failures(updated)
      Audit.log(scope, "box.retry_agent_update", updated, %{version: box.failed_agent_version})
      broadcast(updated, :updated)
      if online?(updated.id), do: Foreman.Agents.Releases.maybe_update(updated)
      {:ok, updated}
    end
  end

  # Picking another version clears one that failed. A pin has to be a
  # release the box can get: a box pinned to anything else never updates.
  defp settings_changeset(box, attrs) do
    changeset = Box.settings_changeset(box, attrs)

    case Ecto.Changeset.fetch_change(changeset, :desired_agent_version) do
      {:ok, version} ->
        changeset
        |> Ecto.Changeset.put_change(:failed_agent_version, nil)
        |> validate_pin(version, box.arch)

      :error ->
        changeset
    end
  end

  defp validate_pin(changeset, version, arch) when is_binary(version) and is_binary(arch) do
    if Foreman.Agents.Releases.get(version, arch),
      do: changeset,
      else:
        Ecto.Changeset.add_error(
          changeset,
          :desired_agent_version,
          "no release #{version} for #{arch}"
        )
  end

  defp validate_pin(changeset, _version, _arch), do: changeset

  defp normalize(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    case attrs["shared_user_ids"] do
      ids when is_list(ids) -> Map.put(attrs, "shared_user_ids", Enum.reject(ids, &(&1 == "")))
      _ -> attrs
    end
  end

  def change_box(%Box{} = box, attrs \\ %{}), do: Box.settings_changeset(box, attrs)

  @doc "Revokes a box: its key is deleted and its socket dropped. Its environments stay in the database."
  def revoke(%Scope{} = scope, %Box{} = box) do
    with :ok <- authorize_admin(scope) do
      box =
        box
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(), public_key: nil)
        |> Repo.update!()

      disconnect(box)
      Audit.log(scope, "box.revoke", box)
      broadcast(box, :revoked)
      {:ok, box}
    end
  end

  # Drops the agent's socket (the agent socket's id is agent_socket:<box_id>).
  defp disconnect(%Box{id: id}),
    do: Phoenix.Channel.Server.broadcast(Foreman.PubSub, "agent_socket:#{id}", "disconnect", %{})

  # The protocol takes versions Version can't compare ("1.01.0").
  defp feature_version(join) do
    with v when is_binary(v) <- Map.get(join, :feature_version),
         {:ok, _} <- Version.parse(v),
         do: v,
         else: (_ -> nil)
  end

  defp broadcast(box, event),
    do: Phoenix.PubSub.broadcast(Foreman.PubSub, "boxes", {:box, event, box.id})

  defp authorize_admin(scope), do: if(Scope.admin?(scope), do: :ok, else: {:error, :unauthorized})
end
