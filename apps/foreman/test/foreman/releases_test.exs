defmodule Foreman.Agents.ReleasesTest do
  use Foreman.DataCase

  alias Foreman.Agents.Releases
  alias ForemanProtocol.Auth

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    {public, private} = Auth.generate_keypair()
    Application.put_env(:foreman, :agent_release_public_key, Base.encode64(public))
    Application.put_env(:foreman, :agent_release_dir, Path.join(tmp, "releases"))

    on_exit(fn ->
      Application.delete_env(:foreman, :agent_release_public_key)
      Application.delete_env(:foreman, :agent_release_dir)
    end)

    tarball = Path.join(tmp, "agent.tar.gz")
    File.write!(tarball, "release bytes")
    sha = :crypto.hash(:sha256, "release bytes") |> Base.encode16(case: :lower)
    %{private: private, tarball: tarball, sha: sha}
  end

  test "registers a release signed with the release key", %{
    private: private,
    tarball: tarball,
    sha: sha
  } do
    sig = Auth.sign_release("0.2.0", "linux-arm64", sha, private)
    assert {:ok, release} = Releases.register("0.2.0", "linux-arm64", tarball, sig)
    assert release.sha256 == sha
    assert File.read!(release.path) == "release bytes"
  end

  test "refuses a bad signature, a bad version and a bad target", %{
    private: private,
    tarball: tarball,
    sha: sha
  } do
    {_, other} = Auth.generate_keypair()

    assert {:error, _} =
             Releases.register(
               "0.2.0",
               "linux-arm64",
               tarball,
               Auth.sign_release("0.2.0", "linux-arm64", sha, other)
             )

    assert {:error, "invalid version"} =
             Releases.register("../../x", "linux-arm64", tarball, "sig")

    assert {:error, "invalid target"} =
             Releases.register("0.2.0", "linux-arm64/../../x", tarball, "sig")

    assert Releases.list() == []
    _ = private
  end

  test "registering the same tarball again leaves the release as it was", ctx do
    first = register!(ctx, "0.2.0", "linux-arm64")
    again = register!(ctx, "0.2.0", "linux-arm64")

    assert again.id == first.id
    assert again.inserted_at == first.inserted_at
  end

  test "registering the same tarball again doesn't copy it again", ctx do
    release = register!(ctx, "0.2.0", "linux-arm64")
    File.touch!(release.path, {{2020, 1, 1}, {0, 0, 0}})

    register!(ctx, "0.2.0", "linux-arm64")
    assert File.stat!(release.path).mtime == {{2020, 1, 1}, {0, 0, 0}}
  end

  test "registering again puts back a tarball that went missing or doesn't match", ctx do
    release = register!(ctx, "0.2.0", "linux-arm64")
    File.rm!(release.path)
    register!(ctx, "0.2.0", "linux-arm64")
    assert File.read!(release.path) == "release bytes"

    # A copy cut short, say.
    File.write!(release.path, "release")
    register!(ctx, "0.2.0", "linux-arm64")
    assert File.read!(release.path) == "release bytes"
  end

  test "registering with a rotated key keeps the release and takes the new signature", ctx do
    first = register!(ctx, "0.2.0", "linux-arm64")
    {public, private} = Auth.generate_keypair()
    Application.put_env(:foreman, :agent_release_public_key, Base.encode64(public))
    ctx = %{ctx | private: private}

    again = register!(ctx, "0.2.0", "linux-arm64")
    assert {again.id, again.inserted_at} == {first.id, first.inserted_at}
    assert again.signature == sign(ctx, "0.2.0", "linux-arm64")
    assert [_] = Releases.list()
  end

  test "registering a rebuilt tarball for a version replaces the file and keeps the release",
       ctx do
    first = register!(ctx, "0.2.0", "linux-arm64")
    File.write!(ctx.tarball, "rebuilt release bytes")
    sha = :crypto.hash(:sha256, "rebuilt release bytes") |> Base.encode16(case: :lower)

    again = register!(%{ctx | sha: sha}, "0.2.0", "linux-arm64")
    assert {again.id, again.inserted_at} == {first.id, first.inserted_at}
    assert {again.sha256, again.size} == {sha, byte_size("rebuilt release bytes")}
    assert File.read!(again.path) == "rebuilt release bytes"
  end

  test "a release key that isn't base64 is an error, not a crash", ctx do
    Application.put_env(:foreman, :agent_release_public_key, "not a key!")

    assert {:error, "the agent release key " <> _} =
             Releases.register(
               "0.2.0",
               "linux-arm64",
               ctx.tarball,
               sign(ctx, "0.2.0", "linux-arm64")
             )
  end

  test "keeps tarballs in the temp dir when no release dir is set", %{tmp_dir: tmp} = ctx do
    # Not the real temp dir, which a dev control plane uses too.
    previous = System.get_env("TMPDIR")
    System.put_env("TMPDIR", tmp)

    on_exit(fn ->
      if previous, do: System.put_env("TMPDIR", previous), else: System.delete_env("TMPDIR")
    end)

    # runtime.exs sets the key to nil when FOREMAN_AGENT_RELEASE_DIR is
    # unset, and an env file can set it to "".
    for {dir, version} <- [{nil, "0.2.0"}, {"", "0.2.1"}] do
      Application.put_env(:foreman, :agent_release_dir, dir)
      release = register!(ctx, version, "linux-arm64")
      assert Path.dirname(release.path) == Path.join(tmp, "foreman-agent-releases")
    end
  end

  describe "latest/1" do
    test "is the target's highest version, not the one registered last", ctx do
      register!(ctx, "0.10.0", "linux-arm64")
      register!(ctx, "0.9.0", "linux-arm64")
      register!(ctx, "0.11.0", "linux-amd64")

      assert Releases.latest("linux-arm64").version == "0.10.0"
      assert Releases.latest("darwin-arm64") == nil
    end

    test "passes over a release whose tarball is gone", ctx do
      register!(ctx, "0.2.0", "linux-arm64")
      newer = register!(ctx, "0.3.0", "linux-arm64")
      File.rm!(newer.path)

      assert Releases.latest("linux-arm64").version == "0.2.0"
    end

    test "passes over prereleases unless there's nothing else", ctx do
      register!(ctx, "0.3.0-rc.1", "linux-arm64")
      assert Releases.latest("linux-arm64").version == "0.3.0-rc.1"

      register!(ctx, "0.2.1", "linux-arm64")
      assert Releases.latest("linux-arm64").version == "0.2.1"
    end
  end

  describe "register_bundled/1" do
    test "registers each signed tarball in the directory, and only once", ctx do
      dir = bundle(ctx, [{"0.3.0", "linux-amd64"}, {"0.3.0", "linux-arm64"}])

      assert [
               {"foreman_agent-0.3.0-linux-amd64.tar.gz", {:ok, _}},
               {"foreman_agent-0.3.0-linux-arm64.tar.gz", {:ok, _}}
             ] = Releases.register_bundled(dir)

      ids = release_ids()
      Releases.register_bundled(dir)
      assert release_ids() == ids
    end

    test "leaves releases that aren't in the bundle alone", ctx do
      register!(ctx, "0.2.1", "linux-arm64")
      Releases.register_bundled(bundle(ctx, [{"0.3.0", "linux-arm64"}]))

      assert Releases.list() |> Enum.map(& &1.version) |> Enum.sort() == ["0.2.1", "0.3.0"]
    end

    test "skips a tarball without a good signature and registers the rest", ctx do
      dir = bundle(ctx, [{"0.3.0", "linux-amd64"}, {"0.3.0", "linux-arm64"}])
      File.write!(Path.join(dir, "foreman_agent-0.3.0-linux-amd64.tar.gz.sig"), "bm9wZQ==")
      File.write!(Path.join(dir, "foreman_agent-0.3.1-linux-arm64.tar.gz"), "release bytes")

      assert [
               {"foreman_agent-0.3.0-linux-amd64.tar.gz", {:error, _}},
               {"foreman_agent-0.3.0-linux-arm64.tar.gz", {:ok, _}},
               {"foreman_agent-0.3.1-linux-arm64.tar.gz", {:error, "no signature" <> _}}
             ] = Releases.register_bundled(dir)

      assert [%{version: "0.3.0", target: "linux-arm64"}] = Releases.list()
    end

    test "an entry that can't be read is skipped and the rest still register", ctx do
      dir = bundle(ctx, [{"0.3.0", "linux-arm64"}])
      File.mkdir_p!(Path.join(dir, "foreman_agent-0.3.0-linux-amd64.tar.gz"))
      File.write!(Path.join(dir, "foreman_agent-0.3.0-linux-amd64.tar.gz.sig"), "bm9wZQ==")

      assert [
               {"foreman_agent-0.3.0-linux-amd64.tar.gz", {:error, _}},
               {"foreman_agent-0.3.0-linux-arm64.tar.gz", {:ok, _}}
             ] = Releases.register_bundled(dir)
    end

    test "at boot, registers before returning and stays out of the supervision tree", ctx do
      dir = bundle(ctx, [{"0.3.0", "linux-arm64"}])
      Application.put_env(:foreman, :bundled_agent_dir, dir)
      on_exit(fn -> Application.delete_env(:foreman, :bundled_agent_dir) end)

      assert Releases.start_registering_bundled() == :ignore
      assert [%{version: "0.3.0"}] = Releases.list()
    end

    test "does nothing without a bundle", %{tmp_dir: tmp} do
      assert Releases.register_bundled(nil) == []
      assert Releases.register_bundled(Path.join(tmp, "missing")) == []
    end

    test "with no argument, reads the configured directory and logs what it skipped", ctx do
      dir = bundle(ctx, [{"0.3.0", "linux-arm64"}])
      File.write!(Path.join(dir, "foreman_agent-0.3.0-linux-arm64.tar.gz.sig"), "bm9wZQ==")
      Application.put_env(:foreman, :bundled_agent_dir, dir)
      on_exit(fn -> Application.delete_env(:foreman, :bundled_agent_dir) end)

      log = ExUnit.CaptureLog.capture_log(fn -> Releases.register_bundled() end)

      assert log =~ "bundled agent 0.3.0 for linux-arm64 wasn't registered"
      assert Releases.list() == []
    end
  end

  defp register!(ctx, version, target) do
    {:ok, release} = Releases.register(version, target, ctx.tarball, sign(ctx, version, target))
    release
  end

  defp sign(ctx, version, target), do: Auth.sign_release(version, target, ctx.sha, ctx.private)

  # A directory laid out the way the control plane image carries agents.
  defp bundle(%{tmp_dir: tmp} = ctx, releases) do
    dir = Path.join(tmp, "bundle")
    File.mkdir_p!(dir)

    for {version, target} <- releases do
      tarball = Path.join(dir, "foreman_agent-#{version}-#{target}.tar.gz")
      File.write!(tarball, "release bytes")
      File.write!(tarball <> ".sig", sign(ctx, version, target) <> "\n")
    end

    dir
  end

  defp release_ids, do: Releases.list() |> Enum.map(& &1.id) |> Enum.sort()
end
