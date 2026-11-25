defmodule Foreman.Attachments do
  @moduledoc """
  Images and video an environment attaches to its repository's issues and
  pull requests.

  GitHub's attachment upload takes a personal access token and refuses a
  GitHub App's, and every token an environment holds is a GitHub App's
  ([cli/cli#14309](https://github.com/cli/cli/issues/14309)). So the
  control plane uploads for it, with a machine user's fine-grained token
  kept on the repository's owner (`Foreman.Repos.update_attachment_token/3`).
  The token never goes to a box, and here it does one thing: put a file
  of an accepted kind in the attachments of the environment's own
  repository.

  A file arrives in chunks, because a box relays at most 900 kB a request
  (`ForemanAgent.VM.Relay`). `start/3` opens an upload and `append/4`
  takes the chunks in order: full ones, then the one that completes the
  file. That one sends the whole file to GitHub and answers with the
  asset's URL. Chunks are kept encrypted and out of the query log, and
  an upload is deleted when its file has been sent, whether or not
  GitHub took it, or when nothing has been sent to it for ten minutes.

  The caller checks the connection's action scope. Two things are
  checked here, when an upload opens and again before the file goes to
  GitHub: that the environment is the connection's to reach
  (`Foreman.PublicAPI.Access`), and that the person acting can write to
  the repository themselves. The token is the machine user's, and
  uploading with it must not give anyone a role GitHub hasn't.
  """
  import Ecto.Query

  alias Foreman.Attachments.{Chunk, Upload}
  alias Foreman.{Audit, GitHub, Repo}
  alias Foreman.OAuth.Principal
  alias Foreman.PublicAPI.Access

  # A relayed request carries 900 kB of JSON, and base64 is a third
  # larger than the bytes it holds.
  @chunk_bytes 512 * 1024
  # GitHub's own limit for an image. Its limit for video depends on the
  # owner's plan and reaches 100 MB; Foreman holds the file while it
  # arrives, so it stops sooner.
  @max_image_bytes 10 * 1024 * 1024
  @max_video_bytes 25 * 1024 * 1024
  # What one environment's open uploads may add up to, and how many
  # there may be: each is a row however small its file.
  @max_pending_bytes 2 * @max_video_bytes
  @max_open 16
  @stale_seconds 600

  # The extensions `gh --attach` accepts, with the content types the
  # endpoint expects.
  @types [
    {".png", "image/png"},
    {".jpg", "image/jpeg"},
    {".jpeg", "image/jpeg"},
    {".gif", "image/gif"},
    {".webp", "image/webp"},
    {".svg", "image/svg+xml"},
    {".mp4", "video/mp4"},
    {".mov", "video/quicktime"},
    {".webm", "video/webm"}
  ]

  # A file's own name: no directory, no control characters.
  @name ~r/\A[^\/\\\x00-\x1f\x7f]{1,255}\z/u
  @max_id 9_007_199_254_740_991

  @missing {:error, :resource_not_found, "Resource not found."}
  @invalid_start {:error, :invalid_request,
                  "Send the file's name and its size in bytes, and at most the " <>
                    "repository_id of the environment's repository."}
  @invalid_chunk {:error, :invalid_request,
                  "Send the chunk's offset and its bytes as base64 data: " <>
                    "#{@chunk_bytes} bytes a chunk, and what is left in the last one."}

  def chunk_size, do: @chunk_bytes
  def max_image_bytes, do: @max_image_bytes
  def max_video_bytes, do: @max_video_bytes
  def max_pending_bytes, do: @max_pending_bytes
  def max_open, do: @max_open

  @doc """
  Opens an upload of one file to the attachments of the environment's
  repository. Answers with the upload's id and the most bytes a chunk
  may hold.
  """
  def start(%Principal{} = principal, env_id, params) do
    with {:ok, env} <- environment(principal, env_id),
         {:ok, name, size, repository_id} <- start_input(params),
         {:ok, content_type} <- content_type(name),
         {:ok, _token} <- token(env),
         :ok <- repository(env, repository_id),
         :ok <- within_limit(content_type, size),
         :ok <- writer(principal, env),
         {:ok, upload} <- open(env, name, content_type, size) do
      {:ok, %{id: upload.id, chunk_size: @chunk_bytes, received: 0}}
    end
  end

  @doc """
  Adds the chunk that starts at `offset`. The chunk that completes the
  file uploads it and answers with the asset's `url`; one before that
  answers with the bytes `received` so far.

  Only one request can complete a file, so only one sends it. The
  upload is gone afterwards either way: a file GitHub didn't take is
  sent again as a new upload.
  """
  def append(%Principal{} = principal, env_id, upload_id, params) do
    with {:ok, upload} <- upload(principal, env_id, upload_id),
         {:ok, offset, data} <- chunk_input(params),
         {:ok, received} <- store(upload, offset, data) do
      if received == upload.size,
        do: finish(principal, upload),
        else: {:ok, %{received: received}}
    end
  end

  @doc "Deletes uploads nothing has been sent to for ten minutes."
  def prune(now \\ DateTime.utc_now()) do
    Repo.delete_all(from u in Upload, where: u.updated_at < ^stale_before(now))
    :ok
  end

  defp stale_before(now), do: DateTime.add(now, -@stale_seconds)

  # -- opening ---------------------------------------------------------------

  # The environment, when it is the connection's to reach, with the
  # repository and owner an upload is made for.
  defp environment(principal, id) do
    with {:ok, id} <- uuid(id),
         %{} = env <- Repo.one(Access.live_environments(principal, id)) do
      {:ok, Repo.preload(env, repo: :owner)}
    else
      _ -> @missing
    end
  end

  defp start_input(%{"name" => name, "size" => size} = params)
       when is_binary(name) and is_integer(size) do
    repository_id = Map.get(params, "repository_id")

    with [] <- Map.keys(params) -- ["name", "size", "repository_id"],
         true <- String.valid?(name) and Regex.match?(@name, name),
         true <- is_nil(repository_id) or (is_integer(repository_id) and repository_id > 0) do
      {:ok, name, size, repository_id}
    else
      _ -> @invalid_start
    end
  end

  defp start_input(_params), do: @invalid_start

  defp content_type(name) do
    extension = name |> Path.extname() |> String.downcase()

    case List.keyfind(@types, extension, 0) do
      {_, type} ->
        {:ok, type}

      nil ->
        supported = Enum.map_join(@types, ", ", fn {ext, _} -> String.trim_leading(ext, ".") end)
        {:error, :invalid_request, "That is not a supported file type (supported: #{supported})."}
    end
  end

  defp token(%{repo: %{owner: %{attachment_token: token}}}) when is_binary(token) and token != "",
    do: {:ok, token}

  defp token(%{repo: %{owner: owner}}) do
    {:error, :attachments_unavailable,
     "Attachments aren't set up for #{owner.login}. " <>
       "An admin adds an attachment token for it under Deployment."}
  end

  # An upload names the repository by its id on GitHub, and reaches the
  # environment's own and no other.
  defp repository(%{repo: %{github_id: nil} = repo}, _requested) do
    {:error, :attachments_unavailable,
     "Foreman doesn't know #{repo.full_name}'s id on GitHub yet, so it can't attach files to it."}
  end

  defp repository(%{repo: %{github_id: id}}, requested) when requested in [nil, id], do: :ok

  defp repository(%{repo: repo}, _requested),
    do: {:error, :invalid_request, "This environment attaches files to #{repo.full_name} only."}

  defp within_limit(_type, size) when size < 1,
    do: {:error, :invalid_request, "An empty file can't be attached."}

  defp within_limit("video/" <> _, size) when size > @max_video_bytes do
    {:error, :invalid_request,
     "Videos must be at most #{megabytes(@max_video_bytes)} to attach through Foreman."}
  end

  defp within_limit("image/" <> _, size) when size > @max_image_bytes,
    do: {:error, :invalid_request, "Images must be at most #{megabytes(@max_image_bytes)}."}

  defp within_limit(_type, _size), do: :ok

  defp megabytes(bytes), do: "#{div(bytes, 1024 * 1024)} MB"

  defp open(env, name, content_type, size) do
    Repo.transaction(fn ->
      # One at a time for an environment, or two that each saw room for
      # themselves would both be let in. SQLite's transactions already
      # take turns.
      unless Repo.sqlite?() do
        Repo.one!(
          from e in Foreman.Environments.Environment,
            where: e.id == ^env.id,
            select: e.id,
            lock: "FOR UPDATE"
        )
      end

      mine = from u in Upload, where: u.environment_id == ^env.id
      # What a client that went away left behind doesn't count against
      # the one asking now.
      Repo.delete_all(where(mine, [u], u.updated_at < ^stale_before(DateTime.utc_now())))
      # Cast, because Postgres sums a bigint column to a numeric.
      pending = Repo.one(from u in mine, select: type(coalesce(sum(u.size), 0), :integer))

      if pending + size > @max_pending_bytes or Repo.aggregate(mine, :count) >= @max_open do
        Repo.rollback(
          {:too_many_attachments,
           "Too many uploads are in progress for this environment. Try again in a few minutes."}
        )
      else
        Repo.insert!(%Upload{
          environment_id: env.id,
          repository_id: env.repo.github_id,
          name: name,
          content_type: content_type,
          size: size
        })
      end
    end)
    |> case do
      {:ok, upload} -> {:ok, upload}
      {:error, {code, message}} -> {:error, code, message}
    end
  end

  # -- chunks ----------------------------------------------------------------

  # A chunk comes several times a file, so this asks the database alone
  # and leaves GitHub out of it: the upload is the environment's and
  # hasn't sat too long, the environment is still its owner's, on a box
  # they may still use, not destroyed, its repository still Foreman's,
  # and the connection's grant is live. What GitHub has to say (who may
  # see the repository, and write to it) is asked again before the file
  # goes anywhere (`finish/2`).
  defp upload(principal, env_id, upload_id) do
    boxes = from b in Access.boxes(principal), select: b.id

    with {:ok, env_id} <- uuid(env_id),
         {:ok, upload_id} <- uuid(upload_id),
         true <- principal.environment_id in [nil, env_id],
         %Upload{} = upload <-
           from(u in Upload,
             join: e in assoc(u, :environment),
             join: r in assoc(e, :repo),
             where: u.id == ^upload_id and e.id == ^env_id,
             where: e.user_id == ^principal.user.id and is_nil(e.destroyed_at),
             where: e.box_id in subquery(boxes) and is_nil(r.removed_at),
             # Abandoned, whether or not housekeeping has been by.
             where: u.updated_at >= ^stale_before(DateTime.utc_now())
           )
           |> Access.while_connected(principal)
           |> Repo.one() do
      {:ok, upload}
    else
      _ -> @missing
    end
  end

  defp chunk_input(%{"offset" => offset, "data" => data} = params)
       when is_integer(offset) and offset <= @max_id and is_binary(data) and map_size(params) == 2 do
    # Base64 of the largest chunk, so nothing bigger is decoded to find
    # out that it is too big.
    with true <- byte_size(data) <= div(@chunk_bytes + 2, 3) * 4,
         {:ok, bytes} <- Base.decode64(data),
         true <- byte_size(bytes) <= @chunk_bytes do
      {:ok, offset, bytes}
    else
      _ -> @invalid_chunk
    end
  end

  defp chunk_input(_params), do: @invalid_chunk

  defp store(_upload, _offset, ""), do: @invalid_chunk

  defp store(%Upload{} = upload, offset, bytes) do
    received = offset + byte_size(bytes)

    cond do
      offset != upload.received ->
        mismatch(upload.received)

      received > upload.size ->
        {:error, :invalid_request,
         "That is more than the #{upload.size} bytes the upload was opened with."}

      # A file a byte at a time would be a row a byte, kept alive by
      # each one.
      received < upload.size and byte_size(bytes) != @chunk_bytes ->
        @invalid_chunk

      true ->
        write(upload, offset, bytes, received)
    end
  end

  # Only the request whose offset is where the upload stands moves it
  # on, so two sending the same chunk can't both be kept.
  defp write(upload, offset, bytes, received) do
    Repo.transaction(fn ->
      at = from u in Upload, where: u.id == ^upload.id and u.received == ^offset

      case Repo.update_all(at, set: [received: received, updated_at: DateTime.utc_now()]) do
        # Encrypted here (`Foreman.Attachments.Chunk` says why), and
        # unlogged: half a megabyte a statement is no use in a log.
        {1, _} ->
          Repo.insert!(
            %Chunk{upload_id: upload.id, position: offset, data: Foreman.Vault.encrypt!(bytes)},
            log: false
          )

        {0, _} ->
          Repo.rollback(:moved)
      end
    end)
    |> case do
      {:ok, _chunk} ->
        {:ok, received}

      {:error, :moved} ->
        case Repo.get(Upload, upload.id) do
          %Upload{received: now} -> mismatch(now)
          nil -> @missing
        end
    end
  end

  defp mismatch(received),
    do:
      {:error, :attachment_offset_mismatch,
       "The next chunk for this upload is at offset #{received}."}

  # -- uploading ---------------------------------------------------------------

  # Reached by the one request whose chunk completed the file (`write/4`
  # lets a single request move an upload on), so the file is sent once.
  # The upload is dropped whatever happens: there is nothing to finish
  # twice, and nothing left counting against the environment.
  defp finish(principal, %Upload{} = upload) do
    with {:ok, env} <- environment(principal, upload.environment_id),
         {:ok, token} <- token(env),
         :ok <- repository(env, upload.repository_id),
         :ok <- writer(principal, env, "Send the file again."),
         {:ok, body} <- assemble(upload) do
      send_file(principal, upload, env, token, body)
    end
  rescue
    # GitHub couldn't be asked who may see the repository. An answer of
    # its own, since "try again" would be wrong: the upload is gone.
    Access.Unavailable ->
      {:error, :repository_access_unavailable,
       "GitHub couldn't be asked about your access to the repository, so the file wasn't " <>
         "uploaded. Send the file again."}
  after
    # Whatever happened, anything raised included.
    Repo.delete_all(from u in Upload, where: u.id == ^upload.id)
  end

  # Every byte that was counted, or nothing is sent: a file short of its
  # size would upload as a broken image that can't be taken back.
  defp assemble(%Upload{} = upload) do
    body =
      from(c in Chunk, where: c.upload_id == ^upload.id, order_by: c.position, select: c.data)
      |> Repo.all(log: false)
      |> Enum.map(&decrypted/1)
      |> IO.iodata_to_binary()

    if byte_size(body) == upload.size,
      do: {:ok, body},
      else:
        {:error, :attachment_upload_failed,
         "Foreman lost part of the file before it could be uploaded. Send the file again."}
  end

  # Nothing for a chunk the keys can't read (they changed under it),
  # which leaves the file short and unsent.
  defp decrypted(data) do
    case Foreman.Vault.decrypt(data) do
      {:ok, bytes} when is_binary(bytes) -> bytes
      _ -> ""
    end
  rescue
    # The vault raises for bytes too few to say which key wrote them.
    _ -> ""
  end

  defp send_file(principal, upload, env, token, body) do
    result =
      GitHub.Client.impl().upload_attachment(
        token,
        upload.repository_id,
        upload.name,
        upload.content_type,
        body
      )

    case result do
      {:ok, url} when is_binary(url) ->
        Audit.log(
          principal.user,
          "environment.attachment",
          env,
          audit(principal, upload, env, url)
        )

        {:ok, %{received: upload.size, url: url}}

      {:error, reason} ->
        {:error, :attachment_upload_failed, refusal(reason, env)}
    end
  end

  # The token is a machine user's, with write access wherever
  # attachments go. GitHub takes an upload only from someone who can
  # write to the repository, and gh checks that before it uploads, but
  # this API can be called without gh. So GitHub is asked, as the person
  # acting, whether the repository is theirs to push to.
  defp writer(%Principal{user: user}, %{repo: repo}, then \\ "Try again.") do
    with {:ok, token} <- GitHub.user_token(user),
         {:ok, remote} <- GitHub.Client.impl().get_repo(token, repo.full_name) do
      if remote["id"] == repo.github_id and get_in(remote, ["permissions", "push"]) == true,
        do: :ok,
        else: not_a_writer(repo)
    else
      {:error, :not_found} ->
        not_a_writer(repo)

      {:error, :login_expired} ->
        {:error, :forbidden,
         "Your GitHub sign-in has expired, so Foreman can't check your access to " <>
           "#{repo.full_name}. Sign in to Foreman again."}

      {:error, _} ->
        {:error, :repository_access_unavailable,
         "GitHub couldn't be asked about your access to #{repo.full_name}. #{then}"}
    end
  end

  defp not_a_writer(repo) do
    {:error, :forbidden,
     "Attaching files takes write access to #{repo.full_name}, which your GitHub account " <>
       "doesn't have."}
  end

  defp audit(principal, upload, env, url) do
    %{
      "name" => upload.name,
      "content_type" => upload.content_type,
      "size" => upload.size,
      "repository" => env.repo.full_name,
      "url" => url,
      "client_id" => principal.client_id,
      "grant_id" => principal.grant_id,
      "actor_kind" => to_string(principal.kind)
    }
  end

  # GitHub answers 404 for a token it won't take an upload from: one
  # whose account can't write to the repository, or that doesn't include
  # it.
  defp refusal({:http, 404, _}, env) do
    owner = env.repo.owner
    account = if owner.attachment_login, do: " (#{owner.attachment_login})", else: ""

    "GitHub refused the upload. The attachment token's account#{account} needs write access to " <>
      "#{env.repo.full_name}, and the token has to include that repository."
  end

  defp refusal({:http, 401, _}, env) do
    "GitHub rejected the attachment token for #{env.repo.owner.login}. " <>
      "An admin replaces it under Deployment."
  end

  defp refusal({:http, 422, message}, _env) when is_binary(message),
    do: "GitHub refused the file: #{message}"

  # Any other refusal of the request itself.
  defp refusal({:http, status, _}, _env) when status in 400..499,
    do: "GitHub refused the upload (it answered #{status})."

  # GitHub has the file and gave nothing to reference it by.
  defp refusal(:no_asset_url, _env),
    do: "GitHub took the upload and named no asset for it. Send the file again."

  # Everything else leaves it unknown whether GitHub has the file: a
  # server's failure, which something in front of GitHub can answer
  # after passing the file on, a timeout, a connection that dropped.
  defp refusal(_reason, _env) do
    "GitHub gave no clear answer, so the file may or may not have been uploaded. " <>
      "Sending it again is safe: an asset nothing references is never shown."
  end

  defp uuid(value) when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  defp uuid(_value), do: :error
end
