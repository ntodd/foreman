defmodule ForemanWeb.AgentController do
  @moduledoc """
  What agents fetch over plain HTTP: enrollment, the install script and
  release tarballs. Enrollment needs a join token; tarballs are signed,
  and agents verify the signature themselves.
  """
  use ForemanWeb, :controller

  alias Foreman.Agents.Releases
  alias Foreman.{Boxes, RateLimit}

  # Failed enrollments count per client (see Foreman.RateLimit).
  @max_failures 10
  @window 60_000

  def enroll(conn, params) do
    key = "enroll-failed:#{ForemanWeb.ClientIP.from_conn(conn)}"

    with false <- RateLimit.exhausted?(key, @window, @max_failures),
         {:ok, box} <- count_failure(Boxes.enroll(params["join_token"], params), key) do
      conn |> put_status(:created) |> json(%{agent_id: box.id, box: box.name})
    else
      true ->
        conn |> put_status(:too_many_requests) |> json(%{error: "too many attempts"})

      {:error, :bad_key} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "public_key must be a base64 ed25519 key"})

      {:error, :revoked} ->
        conn |> put_status(:forbidden) |> json(%{error: "this box has been revoked"})

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "join token is invalid, expired or used"})
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # A fixed path inside the release.
  def install_script(conn, _params) do
    script =
      Application.app_dir(:foreman, "priv/agent/install.sh")
      |> File.read!()
      |> String.replace("__FOREMAN_URL__", Foreman.Config.base_url())

    conn
    |> put_resp_content_type("text/x-shellscript")
    |> send_resp(200, script)
  end

  # sobelow_skip ["Traversal.SendFile"]
  # The path comes from the release's database row, which only an admin
  # creates (Releases.register/4); the params are matched for equality.
  def release(conn, %{"version" => version, "target" => target}) do
    version = if version == "latest", do: latest_version(target), else: version

    case version && Releases.get(version, target) do
      %{path: path, sha256: sha, signature: sig, version: v} ->
        conn
        |> put_resp_content_type("application/gzip")
        |> put_resp_header("x-foreman-version", v)
        |> put_resp_header("x-foreman-sha256", sha)
        |> put_resp_header("x-foreman-signature", sig)
        |> send_file(200, path)

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "no such release"})
    end
  end

  defp count_failure({:ok, _} = ok, _key), do: ok

  defp count_failure(error, key) do
    RateLimit.failed(key, @window, @max_failures)
    error
  end

  defp latest_version(target) do
    Releases.list() |> Enum.find(&(&1.target == target)) |> then(&(&1 && &1.version))
  end
end
