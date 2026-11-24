defmodule Foreman.GeneratedClientsTest do
  use Foreman.DataCase

  import Foreman.PublicAPIMutationFixtures, only: [local_git: 1]
  alias Foreman.{Accounts, Scope}
  alias Foreman.OAuth.{Client, DeviceFlow, Scopes, ServiceAccounts}

  setup :local_git

  test "generated clients can use the public API over HTTP" do
    listener = start_supervised!({Bandit, plug: ForemanWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(listener)
    origin = "http://127.0.0.1:#{port}"
    work = System.fetch_env!("OPENAPI_CLIENT_DIR")
    admin = user_fixture(role: "admin")

    # Supply the outcome of the human approval step to the headless client.
    client = Repo.get!(Client, "foreman-cli")
    {:ok, device} = DeviceFlow.start(client, "repos:list")
    session = Accounts.create_session(admin, "browser")
    {:ok, "approve"} = DeviceFlow.decide(device.user_code, "approve", admin, session)

    run_client("python", ["-B", Path.join(__DIR__, "personal.py")], [
      {"PYTHONPATH", work},
      {"FOREMAN_ORIGIN", origin},
      {"APPROVED_DEVICE_CODE", device.device_code}
    ])

    repo = repo_fixture() |> change(private: false, github_id: unique()) |> Repo.update!()
    box = box_fixture(owner_user_id: admin.id, vm: %{"ready" => true})
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)

    {:ok, installation} =
      ServiceAccounts.register(Scope.for_user(admin), "service", %{
        "name" => "Generated client",
        "scopes" => Scopes.service(),
        "repo_ids" => [repo.id],
        "box_ids" => [box.id]
      })

    run_client("node", [Path.join(work, "dist/service.js")], [
      {"FOREMAN_ORIGIN", origin},
      {"SERVICE_CREDENTIAL", installation.client.id <> ":" <> installation.secret},
      {"REPO_ID", repo.id}
    ])
  end

  defp run_client(executable, args, env) do
    {output, status} = System.cmd(executable, args, env: env, stderr_to_stdout: true)
    assert status == 0, output
  end
end
