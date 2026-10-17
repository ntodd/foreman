defmodule ForemanAgent.GuestTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.{Config, DockerMock, Guest, RunnerMock}
  alias ForemanAgent.Guest.Wire

  @moduletag :tmp_dir
  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  setup %{tmp_dir: tmp} do
    config = %Config{envs_root: Path.join(tmp, "envs"), secrets_root: Path.join(tmp, "run")}
    test_pid = self()
    emit = fn data -> send(test_pid, {:out, IO.iodata_to_binary(data)}) end
    %{config: config, ctx: %{config: config, runner: RunnerMock, docker: DockerMock}, emit: emit}
  end

  defp events do
    out = receive_out("")
    {events, ""} = Wire.feed(Wire.decoder(), out)
    events
  end

  defp receive_out(acc) do
    receive do
      {:out, data} -> receive_out(acc <> data)
    after
      0 -> acc
    end
  end

  test "runs the request as an environment operation and prints its result",
       %{ctx: ctx, config: config, emit: emit} do
    request =
      Wire.request("env.secrets.write", %{
        env_id: @env_id,
        files: %{"secrets.env" => "A=1\n"},
        keep: []
      })

    assert :ok = Guest.run_request(request, ctx, emit)
    assert File.read!(Path.join([config.secrets_root, @env_id, "secrets.env"])) == "A=1\n"
    assert [{:result, {:ok, %{"files" => ["secrets.env"]}}}] = events()
  end

  test "an unreadable request is an error result", %{ctx: ctx, emit: emit} do
    assert :ok = Guest.run_request("nonsense", ctx, emit)
    assert [{:result, {:error, "the host's request couldn't be read"}}] = events()
  end

  test "a crash is reported by its type only", %{ctx: ctx, emit: emit} do
    request =
      Wire.request("env.start", %{env_id: @env_id, slug: "x-1", compose_env: %{"K" => "secret"}})

    # No saved spec: Env.start answers with an error, it doesn't crash.
    assert :ok = Guest.run_request(request, ctx, emit)
    assert [{:result, {:error, message}}] = events()
    assert message =~ "no record"

    Mox.stub(RunnerMock, :run, fn _, _, _ -> raise "couldn't use sk_live_secret" end)
    crash = Wire.request("env.stop", %{env_id: @env_id, slug: "x-1"})
    assert :ok = Guest.run_request(crash, ctx, emit)
    assert [{:result, {:error, "operation crashed: RuntimeError"}}] = events()
  end

  test "logs go out as they happen", %{emit: emit} do
    log = Guest.log_fun(emit)
    log.("stdout", "line\n")
    assert [{:log, "stdout", "line\n"}] = events()
  end
end
