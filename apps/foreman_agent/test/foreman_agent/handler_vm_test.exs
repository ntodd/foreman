defmodule ForemanAgent.HandlerVmTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanAgent.{Config, DockerMock, Handler, RunnerMock, Stats}
  alias ForemanProtocol.Command

  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    previous =
      {Application.get_env(:foreman_agent, :runner), Application.get_env(:foreman_agent, :docker)}

    config = Config.get()

    Application.put_env(:foreman_agent, :runner, RunnerMock)
    Application.put_env(:foreman_agent, :docker, DockerMock)
    Config.put(%{config | isolation: :vm, vm_policy_rules: Config.vm_default_rules()})

    on_exit(fn ->
      {runner, docker} = previous
      Config.put(config)
      restore(:runner, runner)
      restore(:docker, docker)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_agent, key)
  defp restore(key, value), do: Application.put_env(:foreman_agent, key, value)

  defp incus(fun) do
    stub(RunnerMock, :run, fn
      "sh", ["-c", _, "incus" | args], _opts ->
        fun.(args)

      "df", _, _ ->
        {:ok,
         %{
           status: 0,
           output:
             "Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/vda1 1000 100 900 10% /\n"
         }}
    end)
  end

  test "environment commands go to the VM backend" do
    incus(fn ["query", "/1.0/instances/fm-" <> _] ->
      {:ok, %{status: 1, output: "Error: Instance not found\n"}}
    end)

    {:ok, cmd} = Command.new("env.stop", %{env_id: @env_id, slug: "web-1"})
    assert {:ok, %{"vm" => "stopped"}} = Handler.handle(cmd, fn _, _ -> :ok end)
  end

  test "inventory comes from the box's VMs, not its Docker" do
    vms = [
      %{
        "name" => "fm-" <> @env_id,
        "status" => "Stopped",
        "config" => %{"user.foreman.env_id" => @env_id, "user.foreman.slug" => "web-1"}
      }
    ]

    incus(fn ["query", "/1.0/instances?recursion=1"] ->
      {:ok, %{status: 0, output: JSON.encode!(vms)}}
    end)

    assert {:ok, [%{env_id: @env_id, slug: "web-1", state: "stopped"}]} = Handler.inventory()
  end

  test "stats come from the VMs, and capacity from the host" do
    incus(fn ["query", "/1.0/instances?recursion=1"] -> {:ok, %{status: 0, output: "[]"}} end)

    assert {:ok, %{capacity: %{cpus: cpus}, environments: envs}} =
             Stats.collect(Handler.ctx(fn _, _ -> :ok end))

    assert cpus > 0
    assert envs == %{}
  end
end
