defmodule ForemanWeb.AgentController do
  @moduledoc """
  What agents fetch over plain HTTP: enrollment, the install script and
  release tarballs, and for Flatcar boxes the launchers (`mac.sh`,
  `vm.sh`) and their first-boot config. Enrollment and the config need a
  join token; tarballs are signed, and agents verify the signature
  themselves.
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

  def install_script(conn, _params), do: send_script(conn, "install.sh")
  def mac_script(conn, _params), do: send_script(conn, "mac.sh")
  def vm_script(conn, _params), do: send_script(conn, "vm.sh")

  # sobelow_skip ["Traversal.FileModule"]
  # A fixed path inside the release, one of the three above.
  defp send_script(conn, name) when name in ["install.sh", "mac.sh", "vm.sh"] do
    script =
      Application.app_dir(:foreman, Path.join("priv/agent", name))
      |> File.read!()
      |> String.replace("__FOREMAN_URL__", Foreman.Config.base_url())

    conn
    |> put_resp_content_type("text/x-shellscript")
    |> send_resp(200, script)
  end

  @doc """
  A Flatcar box's first-boot config for a join token (see
  `Foreman.Boxes.flatcar_ignition/2`). It carries the token, so a bad one
  counts against the client like a failed enrollment.
  """
  def flatcar_ignition(conn, params) do
    key = "enroll-failed:#{ForemanWeb.ClientIP.from_conn(conn)}"

    with false <- RateLimit.exhausted?(key, @window, @max_failures),
         {:ok, config, box_name} <- Boxes.flatcar_ignition(params["join_token"], params) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-foreman-box", box_name)
      |> json(config)
    else
      true ->
        conn |> put_status(:too_many_requests) |> json(%{error: "too many attempts"})

      {:error, :invalid_token} ->
        RateLimit.failed(key, @window, @max_failures)

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "join token is invalid, expired or used"})

      {:error, :bad_arch} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "arch must be one of: #{Enum.join(Foreman.Boxes.Flatcar.arches(), ", ")}"
        })

      {:error, :bad_ssh_key} ->
        conn |> put_status(:bad_request) |> json(%{error: "ssh_keys must be SSH public keys"})

      {:error, {:tailscale, reason}} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Tailscale wouldn't mint the box a key: #{inspect(reason)}"})
    end
  end

  # sobelow_skip ["Traversal.SendFile"]
  # The path comes from the release's database row, which only an admin
  # creates (Releases.register/4); the params are matched for equality.
  def release(conn, %{"version" => version, "target" => target}) do
    version = if version == "latest", do: latest_version(target), else: version

    # A row whose tarball is gone (kept in a temp dir a recreate cleared)
    # is as good as no release.
    with v when is_binary(v) <- version,
         %{path: path} = release <- Releases.get(v, target),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type("application/gzip")
      |> put_resp_header("x-foreman-version", release.version)
      |> put_resp_header("x-foreman-sha256", release.sha256)
      |> put_resp_header("x-foreman-signature", release.signature)
      |> send_file(200, path)
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such release"})
    end
  end

  defp count_failure({:ok, _} = ok, _key), do: ok

  defp count_failure(error, key) do
    RateLimit.failed(key, @window, @max_failures)
    error
  end

  # What boxes that aren't pinned follow, so a new box doesn't install one
  # version only to be sent another.
  defp latest_version(target), do: Releases.fleet_version(target)
end
