defmodule Mix.Tasks.ForemanAgent.Sign do
  @shortdoc "Signs an agent release tarball"
  @moduledoc """
  Signs a release tarball for self-update. Run by CI, which holds the
  private key; the control plane never sees it.

      FOREMAN_RELEASE_PRIVATE_KEY=<base64> mix foreman_agent.sign 0.2.0 linux-arm64 path/to/foreman_agent.tar.gz

  Prints the base64 signature. `mix foreman_agent.sign --keygen` prints
  a new keypair (private, then public).
  """
  use Mix.Task

  alias ForemanProtocol.Auth

  @impl true
  def run(["--keygen"]) do
    {public, private} = Auth.generate_keypair()
    Mix.shell().info("FOREMAN_RELEASE_PRIVATE_KEY=#{Base.encode64(private)}")
    Mix.shell().info("FOREMAN_RELEASE_PUBLIC_KEY=#{Base.encode64(public)}")
  end

  def run([version, target, path]) do
    private =
      System.get_env("FOREMAN_RELEASE_PRIVATE_KEY") || Mix.raise("FOREMAN_RELEASE_PRIVATE_KEY is not set")

    sha = path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    Mix.shell().info(Auth.sign_release(version, target, sha, Base.decode64!(private)))
  end

  def run(_), do: Mix.raise("usage: mix foreman_agent.sign VERSION TARGET TARBALL | --keygen")
end
