defmodule ForemanAgent.UpdaterTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.{Config, Updater}
  alias ForemanProtocol.Auth

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    {public, private} = Auth.generate_keypair()

    # A release tarball shaped like `mix release`'s.
    src = Path.join(tmp, "src")
    File.mkdir_p!(Path.join(src, "bin"))
    File.write!(Path.join(src, "bin/foreman_agent"), "#!/bin/sh\necho new\n")
    tarball = Path.join(tmp, "release.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(tarball),
        [{~c"bin/foreman_agent", String.to_charlist(Path.join(src, "bin/foreman_agent"))}],
        [:compressed]
      )

    body = File.read!(tarball)
    sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    config = %Config{release_root: Path.join(tmp, "opt"), release_public_key: public}
    File.mkdir_p!(Path.join(config.release_root, "releases/0.1.0"))
    File.ln_s!("releases/0.1.0", Path.join(config.release_root, "current"))

    Req.Test.stub(Updater, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)

    %{config: config, private: private, sha: sha, body: body}
  end

  defp payload(version, sha, private, target \\ Updater.target()) do
    %{
      version: version,
      url: "https://foreman.example/agent/releases/#{version}/#{target}",
      sha256: sha,
      signature: Auth.sign_release(version, target, sha, private)
    }
  end

  defp run(payload, config),
    do: Updater.run(payload, config, fn _, _ -> :ok end, req_options: [plug: {Req.Test, Updater}])

  test "installs a signed release and switches the current symlink", %{
    config: config,
    private: private,
    sha: sha
  } do
    assert {:ok, %{"version" => "0.2.0"}} = run(payload("0.2.0", sha, private), config)

    root = config.release_root
    assert File.read!(Path.join(root, "releases/0.2.0/bin/foreman_agent")) =~ "echo new"

    assert {:ok, ~c"releases/0.2.0"} =
             :file.read_link(String.to_charlist(Path.join(root, "current")))

    assert {:ok, ~c"releases/0.1.0"} =
             :file.read_link(String.to_charlist(Path.join(root, "previous")))
  end

  test "refuses a signature for another version or target", %{
    config: config,
    private: private,
    sha: sha
  } do
    bad = %{payload("0.2.0", sha, private) | version: "0.3.0"}
    assert {:error, message} = run(bad, config)
    assert message =~ "signature"

    other_target = payload("0.2.0", sha, private, "linux-other")
    assert {:error, _} = run(other_target, config)
    refute File.exists?(Path.join(config.release_root, "releases/0.2.0"))
  end

  test "refuses a download that doesn't match the signed digest", %{
    config: config,
    private: private
  } do
    wrong = String.duplicate("0", 64)
    assert {:error, message} = run(payload("0.2.0", wrong, private), config)
    assert message =~ "SHA-256"

    assert {:ok, ~c"releases/0.1.0"} =
             :file.read_link(String.to_charlist(Path.join(config.release_root, "current")))
  end

  test "is disabled without a release key", %{config: config, private: private, sha: sha} do
    assert {:error, message} =
             run(payload("0.2.0", sha, private), %{config | release_public_key: nil})

    assert message =~ "release key"
  end

  describe "download origin" do
    setup %{body: body} do
      test = self()

      Req.Test.stub(Updater, fn conn ->
        send(
          test,
          {:fetched, conn.scheme, conn.host, conn.port, conn.request_path, conn.query_string}
        )

        Plug.Conn.send_resp(conn, 200, body)
      end)

      :ok
    end

    defp with_query(payload), do: %{payload | url: payload.url <> "?sig=abc"}

    test "comes from the agent's FOREMAN_URL, keeping the path and query", %{
      config: config,
      private: private,
      sha: sha
    } do
      config = %{config | url: "http://127.0.0.1:4000"}
      assert {:ok, _} = run(with_query(payload("0.2.0", sha, private)), config)

      path = "/agent/releases/0.2.0/#{Updater.target()}"
      assert_received {:fetched, :http, "127.0.0.1", 4000, ^path, "sig=abc"}
    end

    test "is unchanged when FOREMAN_URL has the payload's origin", %{
      config: config,
      private: private,
      sha: sha
    } do
      config = %{config | url: "https://foreman.example"}
      assert {:ok, _} = run(with_query(payload("0.2.0", sha, private)), config)

      path = "/agent/releases/0.2.0/#{Updater.target()}"
      assert_received {:fetched, :https, "foreman.example", 443, ^path, "sig=abc"}
    end

    test "is the payload's when there's no FOREMAN_URL", %{
      config: config,
      private: private,
      sha: sha
    } do
      assert {:ok, _} = run(payload("0.2.0", sha, private), %{config | url: nil})

      path = "/agent/releases/0.2.0/#{Updater.target()}"
      assert_received {:fetched, :https, "foreman.example", 443, ^path, ""}
    end
  end

  test "refuses tarballs with paths that escape the release directory", %{
    config: config,
    private: private,
    tmp_dir: tmp
  } do
    evil = Path.join(tmp, "evil.tar.gz")
    File.write!(Path.join(tmp, "x"), "x")

    :ok =
      :erl_tar.create(
        String.to_charlist(evil),
        [{~c"../../escaped", String.to_charlist(Path.join(tmp, "x"))}],
        [:compressed]
      )

    body = File.read!(evil)
    sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    Req.Test.stub(Updater, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)

    assert {:error, message} = run(payload("0.2.0", sha, private), config)
    assert message =~ "unsafe"
    refute File.exists?(Path.join(config.release_root, "../escaped"))
  end
end
