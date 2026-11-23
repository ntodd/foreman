Code.require_file("support.exs", __DIR__)

defmodule Foreman.CLIInstallTest do
  use Foreman.DataCase

  import Foreman.CLITestSupport

  @moduletag :tmp_dir
  @moduletag timeout: 180_000
  @release_feed "https://api.github.com/repos/ntodd/foreman/releases"
  @downloads "https://github.com/ntodd/foreman/releases/download"
  setup :listener

  test "a member installs from Connected apps, updates from the shell and reuses the login",
       ctx do
    member = user_fixture(role: "member")

    page =
      Req.get!(ctx.origin <> "/settings/connections", headers: [cookie: browser_cookie(member)])

    assert page.status == 200
    html = LazyHTML.from_document(page.body)

    copy = fn id ->
      html |> LazyHTML.query("##{id}-copy") |> LazyHTML.attribute("data-copy") |> List.first()
    end

    assert copy.("cli-install") == "curl -fsSL #{ctx.origin}/cli/install.sh | sh"
    assert copy.("cli-login") == "foreman --instance #{ctx.origin} login"
    ["curl", flags, url, "|", shell] = String.split(copy.("cli-install"))
    ["foreman" | login_args] = String.split(copy.("cli-login"))

    # Both the control plane and the CLI query the same local release feed.
    dir = Path.join(ctx.tmp_dir, "releases")
    File.mkdir!(dir)
    plug = {Plug.Static, at: "/", from: dir}

    pid =
      start_supervised!(
        Supervisor.child_spec({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0},
          id: :release_feed
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    feed = "http://127.0.0.1:#{port}"
    feed_url = feed <> "/feed.json"
    previous = Application.fetch_env(:foreman, :cli_release_req_options)
    Application.put_env(:foreman, :cli_release_req_options, url: feed_url)
    Foreman.CLIReleases.reset_cache()

    on_exit(fn ->
      case previous do
        {:ok, opts} -> Application.put_env(:foreman, :cli_release_req_options, opts)
        :error -> Application.delete_env(:foreman, :cli_release_req_options)
      end

      Foreman.CLIReleases.reset_cache()
    end)

    root = Path.expand("../..", __DIR__)
    source = Path.join(root, "cli/internal/selfupdate/update.go")
    local = Path.join(ctx.tmp_dir, "update.go")

    release_client =
      source
      |> File.read!()
      |> fixture_url(@release_feed, feed_url)
      |> fixture_url(@downloads, feed <> "/assets")

    File.write!(local, release_client)
    overlay = Path.join(ctx.tmp_dir, "overlay.json")
    File.write!(overlay, Jason.encode!(%{Replace: %{source => local}}))
    fixture = %{root: root, dir: dir, overlay: overlay}
    publish(fixture, "v1.2.3")

    {installer, 0} = System.cmd("curl", [flags, url])
    script = Path.join(ctx.tmp_dir, "install.sh")
    assert installer =~ ctx.origin <> "/cli/release"
    File.write!(script, fixture_url(installer, @downloads, feed <> "/assets"))

    output =
      %{ctx | cli: System.find_executable("env")}
      |> launch(["PATH=" <> fresh_path(ctx.tmp_dir), shell, script])
      |> finish()
      |> success()

    assert output =~ ~S(export PATH="$HOME/.local/bin:$PATH")
    binary = Path.join(ctx.tmp_dir, ".local/bin/foreman")
    installed = %{ctx | cli: binary}
    assert version(installed) == "foreman v1.2.3"
    device_login(installed, member, login_args)
    assert json(installed, ["me"])["id"] == member.id

    # Publish the same binary with a newer embedded version. Both were built from this checkout.
    archive = publish(fixture, "v1.2.4")
    {0, identity, ""} = installed |> launch(["--json", "me"]) |> finish()
    assert Jason.decode!(identity)["id"] == member.id
    notice = "Foreman CLI 1.2.4 is available (installed 1.2.3). Run foreman update."
    assert interactive_notice(installed, member) == notice
    assert interactive_notice(installed, member) == ""

    bytes = File.read!(archive)
    File.write!(archive, "corrupt archive")
    {rejected, _, error} = installed |> launch(["update"]) |> finish()
    assert rejected != 0 and error =~ "SHA-256"
    assert version(installed) == "foreman v1.2.3"
    assert json(installed, ["me"])["id"] == member.id

    File.write!(archive, bytes)
    assert installed |> launch(["update"]) |> finish() |> success() =~ "1.2.4"
    assert version(installed) == "foreman v1.2.4"
    assert interactive_notice(installed, member) == ""
    assert json(installed, ["me"])["id"] == member.id
  end

  defp version(ctx), do: ctx |> launch(["--version"]) |> finish() |> success() |> String.trim()

  defp interactive_notice(ctx, member) do
    {status, out, err} =
      %{ctx | cli: System.find_executable("python3")}
      |> launch([Path.join(__DIR__, "interactive.py"), ctx.cli, "me"])
      |> finish()

    assert status == 0, err
    assert Jason.decode!(out)["id"] == member.id
    String.trim(err)
  end

  defp fixture_url(source, official, local) do
    assert source =~ official
    String.replace(source, official, local)
  end

  # Only the installation shell has this PATH. The test runner still needs Go
  # to publish fixtures and Python to provide a terminal for notice checks.
  defp fresh_path(tmp_dir) do
    path = Path.join(tmp_dir, "system-bin")
    File.mkdir!(path)
    hash = if System.find_executable("sha256sum"), do: "sha256sum", else: "shasum"

    for name <- [
          hash | ~w(awk cat chmod curl grep gzip id ln mkdir mktemp mv rm sh stat tar uname)
        ] do
      File.ln_s!(System.find_executable(name), Path.join(path, name))
    end

    path
  end

  defp publish(f, tag) do
    target_dir = Path.join([f.dir, "assets", tag])

    {target, 0} =
      System.cmd("go", ["env", "GOHOSTOS", "GOHOSTARCH"], cd: Path.join(f.root, "cli"))

    [os, arch] = String.split(target)

    {out, status} =
      System.cmd(Path.join(f.root, "scripts/package-cli.sh"), [tag, os, arch, target_dir],
        env: [{"GOFLAGS", "-overlay=#{f.overlay}"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    prefix = "foreman-cli-#{tag}-"
    name = "#{prefix}#{os}-#{arch}.tar.gz"
    archive = Path.join(target_dir, name)
    sha = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
    manifest = prefix <> "SHA256SUMS"
    File.write!(Path.join(target_dir, manifest), "#{sha}  #{name}\n")

    names =
      for os <- ~w(linux darwin), arch <- ~w(amd64 arm64), do: "#{prefix}#{os}-#{arch}.tar.gz"

    assets = Enum.map([manifest | names], &%{name: &1, state: "uploaded"})

    row = %{
      tag_name: tag,
      published_at: "2026-01-01T00:00:00Z",
      draft: false,
      prerelease: false,
      assets: assets
    }

    File.write!(Path.join(f.dir, "feed.json"), Jason.encode!([row]))
    archive
  end
end
