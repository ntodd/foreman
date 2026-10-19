defmodule Foreman.ReleaseTest do
  # Traces calls, which is global to the VM.
  use Foreman.DataCase, async: false

  import ExUnit.CaptureIO

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

  describe "publish_agent/4" do
    test "registers a signed release", %{private: private, tarball: tarball, sha: sha} do
      sig = Auth.sign_release("0.2.0", "linux-arm64", sha, private)

      assert publish_agent("0.2.0", tarball, sig) =~
               "published agent 0.2.0 for linux-arm64 (#{sha})"

      assert %{sha256: ^sha} = Releases.get("0.2.0", "linux-arm64")
    end

    test "raises on a bad signature", %{tarball: tarball, sha: sha} do
      {_, other} = Auth.generate_keypair()
      sig = Auth.sign_release("0.2.0", "linux-arm64", sha, other)

      assert_raise RuntimeError, ~r/couldn't publish/, fn ->
        publish_agent("0.2.0", tarball, sig)
      end

      assert Releases.list() == []
    end

    # Under `bin/foreman eval` that would start Oban's queues and Cron
    # beside the running control plane's.
    test "doesn't start the application", %{private: private, tarball: tarball, sha: sha} do
      sig = Auth.sign_release("0.2.0", "linux-arm64", sha, private)

      calls = trace_ensure_all_started(fn -> publish_agent("0.2.0", tarball, sig) end)

      refute Enum.any?(calls, fn [app | _] -> app == :foreman or app == [:foreman] end),
             "started the app: #{inspect(calls)}"
    end
  end

  defp publish_agent(version, tarball, sig) do
    capture_io(fn -> Foreman.Release.publish_agent(version, "linux-arm64", tarball, sig) end)
  end

  # The arguments of every Application.ensure_all_started call fun makes.
  # A process can't trace itself, so a separate one collects them.
  defp trace_ensure_all_started(fun) do
    collector =
      spawn_link(fn ->
        collect = fn collect, calls ->
          receive do
            {:trace, _, :call, {Application, :ensure_all_started, args}} ->
              collect.(collect, [args | calls])

            {:done, from} ->
              send(from, {:calls, Enum.reverse(calls)})
          end
        end

        collect.(collect, [])
      end)

    :erlang.trace_pattern({Application, :ensure_all_started, :_}, true, [:local])

    try do
      :erlang.trace(self(), true, [:call, {:tracer, collector}])
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Application, :ensure_all_started, :_}, false, [:local])
    end

    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _, ^ref}
    send(collector, {:done, self()})
    assert_receive {:calls, calls}
    calls
  end
end
