defmodule ForemanWeb.CLIInstallerController do
  use ForemanWeb, :controller

  @path Path.expand("../../../priv/cli/install.sh", __DIR__)
  @external_resource @path
  @script File.read!(@path)

  def show(conn, _params) do
    # Only this shell-quoted public URL varies per instance.
    url = String.replace(Foreman.Config.base_url(), "'", "'\\''") <> "/cli/release"

    script = String.replace(@script, "__FOREMAN_CLI_RELEASE_URL__", url)

    conn
    |> put_resp_content_type("text/x-shellscript")
    |> send_resp(200, script)
  end

  def release(conn, _params) do
    case Foreman.CLIReleases.latest() do
      {:ok, tag} ->
        text(conn, tag <> "\n")

      :error ->
        conn |> put_status(503) |> text("Cannot discover a stable CLI release; try again.")
    end
  end
end
