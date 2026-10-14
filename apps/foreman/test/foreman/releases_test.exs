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
end
