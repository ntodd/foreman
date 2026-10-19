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

  describe "reencrypt/0" do
    setup do
      {Foreman.Vault.Cipher, opts} =
        Application.fetch_env!(:foreman, Foreman.Vault)[:ciphers][:default]

      [current, retired | _] = opts[:keys]
      %{current: current, retired: retired}
    end

    test "re-encrypts what a retired key encrypted with the current one", keys do
      secret = secret_fixture("owner", owner_fixture(), "TOKEN", "s3cret")
      put_raw_value(secret.id, encrypt("s3cret", keys.retired))
      updated_at = Repo.get!(Foreman.Secrets.Secret, secret.id).updated_at

      output = capture_io(&Foreman.Release.reencrypt/0)

      assert output =~ ~r/^secrets: 1 re-encrypted$/m
      assert decrypt(raw_value(secret.id), keys.current) == {:ok, "s3cret"}

      reloaded = Repo.get!(Foreman.Secrets.Secret, secret.id)
      assert reloaded.value == "s3cret"
      assert reloaded.updated_at == updated_at
    end

    test "re-encrypts settings, whose key is a string" do
      Foreman.Settings.put("github_app", %{"id" => 1})

      assert capture_io(&Foreman.Release.reencrypt/0) =~ ~r/^settings: \d+ re-encrypted$/m
      assert Foreman.Settings.get("github_app") == %{"id" => 1}
    end

    # Run before the control plane has booted with the new key, it would
    # write under a key the boot check doesn't know the data needs.
    test "records the current key before writing anything", keys do
      id = &Foreman.Vault.key_id/1
      Foreman.Settings.put("encryption_key_check", %{"keys" => [id.(keys.retired)]})

      capture_io(&Foreman.Release.reencrypt/0)

      assert id.(keys.current) in Foreman.Settings.get("encryption_key_check")["keys"]
    end

    test "refuses to run when the keys can't read what's stored" do
      secret = secret_fixture("owner", owner_fixture(), "TOKEN", "s3cret")
      before = raw_value(secret.id)

      {:ok, ciphertext} =
        Cloak.Ciphers.AES.GCM.encrypt(~s({"v":1}),
          tag: "AES.GCM.V1",
          key: :crypto.strong_rand_bytes(32),
          iv_length: 12
        )

      now = NaiveDateTime.utc_now()

      Repo.insert_all("settings", [
        %{key: "github_app", value: ciphertext, inserted_at: now, updated_at: now}
      ])

      assert_raise RuntimeError, ~r/FOREMAN_ENCRYPTION_KEY/, fn ->
        capture_io(&Foreman.Release.reencrypt/0)
      end

      assert raw_value(secret.id) == before
    end

    test "doesn't start the application" do
      calls = trace_ensure_all_started(fn -> capture_io(&Foreman.Release.reencrypt/0) end)

      refute Enum.any?(calls, fn [app | _] -> app == :foreman or app == [:foreman] end),
             "started the app: #{inspect(calls)}"
    end
  end

  defp encrypt(plaintext, key) do
    {:ok, ciphertext} =
      Cloak.Ciphers.AES.GCM.encrypt(plaintext, tag: "AES.GCM.V1", key: key, iv_length: 12)

    ciphertext
  end

  defp decrypt(ciphertext, key) do
    Cloak.Ciphers.AES.GCM.decrypt(ciphertext, tag: "AES.GCM.V1", key: key, iv_length: 12)
  end

  defp raw_value(id) do
    Repo.one!(from s in "secrets", where: s.id == type(^id, :binary_id), select: s.value)
  end

  defp put_raw_value(id, ciphertext) do
    {1, _} =
      Repo.update_all(from(s in "secrets", where: s.id == type(^id, :binary_id)),
        set: [value: ciphertext]
      )
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
