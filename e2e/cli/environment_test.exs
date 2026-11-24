Code.require_file("support.exs", __DIR__)

defmodule Foreman.CLIEnvironmentBox do
  @moduledoc false
  # A stand-in for the box and the VM between a container and the control
  # plane: plain HTTP on a unix socket in, the same request out to the
  # relay's mount, signed with the box's key for one environment. What the
  # real ones add (the checks on what a VM may ask) is theirs to test; this
  # is the CLI and the control plane meeting through the real wire format.
  alias ForemanProtocol.Auth

  def start(socket, origin, box, env_id) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, socket}},
        active: false,
        packet: :http_bin
      ])

    pid = spawn_link(fn -> accept(listen, {origin, box, env_id}) end)
    {listen, pid}
  end

  defp accept(listen, relay) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        serve(socket, relay)
        :gen_tcp.close(socket)
        accept(listen, relay)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket, {origin, box, env_id}) do
    {:ok, {:http_request, method, {:abs_path, target}, _}} = :gen_tcp.recv(socket, 0, 5_000)
    headers = headers(socket, %{})
    length = String.to_integer(Map.get(headers, "content-length", "0"))
    :ok = :inet.setopts(socket, packet: :raw)
    body = if length > 0, do: elem(:gen_tcp.recv(socket, length, 5_000), 1), else: ""

    method = method |> to_string() |> String.upcase()
    "/api/v1" <> rest = target
    relayed = "/api/agents/relay/v1" <> rest
    key = headers["idempotency-key"]

    signed =
      Auth.relay_headers(box.id, box.__private_key__, %{
        environment: env_id,
        method: method,
        target: relayed,
        body: body,
        idempotency_key: key
      })

    response =
      Req.request!(
        method: method,
        url: origin <> relayed,
        body: body,
        headers:
          Map.to_list(signed) ++
            if(body == "", do: [], else: [{"content-type", "application/json"}]) ++
            if(key, do: [{"idempotency-key", key}], else: []),
        decode_body: false,
        retry: false,
        redirect: false
      )

    location =
      for value <- Req.Response.get_header(response, "location"), do: "location: #{value}\r\n"

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{response.status} Status\r\ncontent-type: application/json\r\n",
      "content-length: #{byte_size(response.body)}\r\nconnection: close\r\n",
      location,
      "\r\n",
      response.body
    ])
  end

  defp headers(socket, seen) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        headers(socket, Map.put(seen, name |> to_string() |> String.downcase(), value))

      {:ok, :http_eoh} ->
        seen
    end
  end
end

defmodule Foreman.CLIEnvironmentTest do
  @moduledoc "The installed CLI inside an environment, with no login."
  use Foreman.DataCase

  import Foreman.CLITestSupport
  import Foreman.PublicAPIMutationFixtures, only: [local_git: 1]

  alias Foreman.{Agents, Secrets}
  alias Foreman.Environments.Environment
  alias Foreman.Operations.Operation

  @moduletag :tmp_dir
  setup :local_git
  setup :listener

  setup ctx do
    user = user_fixture(role: "admin")
    repo = repo_fixture() |> change(private: false) |> Repo.update!()
    box = box_fixture(owner_user_id: user.id, vm: %{"ready" => true})
    :ok = Agents.register(box.id)
    env = environment_fixture(user: user, repo: repo, box: box)
    other = environment_fixture(user: user, repo: repo, box: box)

    # Unix socket paths are short on macOS; the test's own directory isn't.
    dir = Path.join("/tmp", "fme2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    socket = Path.join(dir, "api.sock")
    {listen, _pid} = Foreman.CLIEnvironmentBox.start(socket, ctx.origin, box, env.id)
    on_exit(fn -> :gen_tcp.close(listen) end)

    %{
      user: user,
      repo: repo,
      box: box,
      env: env,
      other: other,
      extra_env: [{"FOREMAN_API_SOCKET", socket}]
    }
  end

  test "acts as the environment's owner, for that environment alone", ctx do
    env_id = ctx.env.id
    slug = ctx.env.slug

    assert %{
             "id" => user_id,
             "name" => name,
             "client_id" => "foreman-environment",
             "environment" => %{"id" => ^env_id, "name" => ^slug}
           } = json(ctx, ["me"])

    assert {user_id, name} == {ctx.user.id, ctx.user.login}

    # The environment is the one meant when none is named, and the only one seen.
    assert %{"id" => ^env_id} = json(ctx, ["env", "show"])
    assert [%{"id" => ^env_id}] = json(ctx, ["env", "list"]) |> items()
    assert {%{"code" => "resource_not_found"}, _, _} = failure(ctx, ["env", "show", ctx.other.id])

    # Its secrets are the default, and the only ones it reaches, whoever owns it.
    json(ctx, ["secrets", "set", "TOKEN=from inside"])
    assert Secrets.resolve(Repo.reload!(ctx.env)) == %{"TOKEN" => "from inside"}
    assert [%{"name" => "TOKEN"}] = json(ctx, ["secrets", "list"]) |> items()

    for level <- [["--user"], ["--repo", ctx.repo.id], ["--owner", ctx.repo.owner.login]] do
      {error, _, _} = failure(ctx, ["secrets", "set"] ++ level ++ ["X=1"])
      assert error["http_status"] == 403
      assert error["message"] =~ "manages that environment's secrets only"
    end

    {error, _, _} = failure(ctx, ["secrets", "set", "--env", ctx.other.id, "X=1"])
    assert error["http_status"] == 404
    assert Secrets.resolve(Repo.reload!(ctx.other)) == %{}

    # It lists nothing else of its owner's, and can't make or destroy anything.
    assert {%{"code" => _}, _, _} = failure(ctx, ["repo", "list"])
    assert {%{"code" => _}, _, _} = failure(ctx, ["box", "list"])

    assert {%{"code" => "forbidden"}, _, _} =
             failure(ctx, ["env", "create", ctx.repo.full_name, "--no-wait"])

    assert {%{"code" => "insufficient_scope"}, _, _} =
             failure(ctx, ["env", "destroy", env_id, "--yes", "--no-wait"])

    assert {%{"code" => "invalid_invocation"}, _, _} = failure(ctx, ["env", "destroy", "--yes"])
    assert Repo.get!(Environment, env_id).destroyed_at == nil

    # It can stop itself.
    assert %{"environment_id" => ^env_id, "operation_id" => op} =
             json(ctx, ["env", "stop", "--no-wait"])

    assert %Operation{action: "stop", environment_id: ^env_id} = Repo.get!(Operation, op)
    assert %{"id" => ^op} = json(ctx, ["op", "show", op])
    assert [%{"id" => ^op} | _] = json(ctx, ["op", "list"]) |> items()
  end

  test "a login made inside is used instead, and logging out goes back", ctx do
    env_id = ctx.env.id
    assert %{"environment" => %{"id" => ^env_id}} = json(ctx, ["me"])

    login(ctx, ctx.user)
    me = json(ctx, ["me"])
    assert me["client_id"] == "foreman-cli"
    refute Map.has_key?(me, "environment")
    assert length(json(ctx, ["env", "list"]) |> items()) == 2

    ctx |> launch(["logout"]) |> finish() |> success()
    assert %{"environment" => %{"id" => ^env_id}} = json(ctx, ["me"])
  end
end
