defmodule Foreman.CLIListener do
  @moduledoc false
  # Observe requests at the actual HTTP boundary. One test holds the first committed
  # create response here so it can kill the originating process before delivery.
  def init(opts), do: opts

  def call(conn, {owner, hold}) do
    conn
    |> Plug.Conn.register_before_send(fn conn ->
      case {conn.method, conn.path_info, conn.status} do
        {"POST", ["api", "v1", "environments"], 202} ->
          if hold && :atomics.compare_exchange(hold, 1, 0, 1) == :ok do
            [key] = Plug.Conn.get_req_header(conn, "idempotency-key")
            send(owner, {:accepted, self(), key, Jason.decode!(conn.resp_body)})

            receive do
              :release_response -> :ok
            after
              10_000 -> raise "CLI test never released the held response"
            end
          end

        {"GET", ["api", "v1", "operations", id], 200} ->
          send(owner, {:read_operation, id})

        {"GET", ["api", "v1", "operations", id, "logs"], 200} ->
          page = Jason.decode!(conn.resp_body)
          send(owner, {:read_log, id, page["text"] == "", page["next_cursor"]})

        _ ->
          :ok
      end

      conn
    end)
    |> ForemanWeb.Endpoint.call(ForemanWeb.Endpoint.init([]))
  end
end

defmodule Foreman.CLITestSupport do
  @moduledoc false
  import ExUnit.Assertions
  alias ForemanWeb.Endpoint

  def listener(ctx) do
    File.chmod!(ctx.tmp_dir, 0o700)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(ctx.tmp_dir) end)
    hold = if ctx[:hold_create], do: :atomics.new(1, [])
    plug = {Foreman.CLIListener, {self(), hold}}
    pid = ExUnit.Callbacks.start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    origin = "http://127.0.0.1:#{port}"
    previous = Application.fetch_env(:foreman, :base_url)
    Application.put_env(:foreman, :base_url, origin)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, url} -> Application.put_env(:foreman, :base_url, url)
        :error -> Application.delete_env(:foreman, :base_url)
      end
    end)

    %{origin: origin, cli: System.fetch_env!("FOREMAN_CLI")}
  end

  def launch(ctx, args) do
    # exec gives us the CLI's actual pid. Keep stdio non-interactive and separate,
    # including when several invocations are sharing the same state directory.
    out = Path.join(ctx.tmp_dir, Integer.to_string(System.unique_integer([:positive])))
    err = out <> ".err"
    File.touch!(out)
    File.touch!(err)
    script = ~S(out=$1; err=$2; shift 2; exec "$@" </dev/null >"$out" 2>"$err")

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        args: ["-c", script, "cli-test", out, err, ctx.cli | args],
        cd: ctx.tmp_dir,
        env: [
          {~c"HOME", String.to_charlist(ctx.tmp_dir)},
          {~c"XDG_STATE_HOME", String.to_charlist(Path.join(ctx.tmp_dir, "state"))},
          {~c"PYTHONUNBUFFERED", ~c"1"},
          # A stale release origin in a fixture must fail locally. The loopback
          # control plane cannot proxy a request to GitHub.
          {~c"HTTPS_PROXY", String.to_charlist(ctx.origin)},
          {~c"https_proxy", String.to_charlist(ctx.origin)},
          {~c"NO_PROXY", ~c"127.0.0.1,localhost,::1"},
          {~c"no_proxy", ~c"127.0.0.1,localhost,::1"}
          | for(
              {name, value} <- Map.get(ctx, :extra_env, []),
              do: {String.to_charlist(name), String.to_charlist(value)}
            )
        ]
      ])

    %{port: port, out: out, err: err}
  end

  def interrupt(%{port: port}, signal) do
    {:os_pid, pid} = Port.info(port, :os_pid)
    {_, 0} = System.cmd("kill", ["-" <> signal, Integer.to_string(pid)])
  end

  def finish(%{port: port} = child) do
    receive do
      {^port, {:exit_status, status}} ->
        {status, File.read!(child.out), File.read!(child.err)}
    after
      35_000 ->
        interrupt(child, "KILL")
        flunk("Timed out waiting for CLI output: #{File.read!(child.err)}")
    end
  end

  def success({status, stdout, stderr}) do
    assert status == 0, stderr
    stdout
  end

  def json(ctx, args),
    do: ctx |> launch(["--json" | args]) |> finish() |> success() |> Jason.decode!()

  def items(%{"items" => collection}) when is_list(collection), do: collection
  def items(collection) when is_list(collection), do: collection

  def failure(ctx, args) do
    {status, stdout, stderr} = ctx |> launch(["--json" | args]) |> finish()
    assert status != 0

    error =
      stderr
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case Jason.decode(line) do
          {:ok, %{"code" => _, "message" => _} = error} -> error
          {:ok, %{"error" => %{"code" => _, "message" => _} = error}} -> error
          _ -> nil
        end
      end)

    assert error, "Missing JSON error: #{stderr}"
    {error, stdout, stderr}
  end

  def login(ctx, user, scopes \\ nil) do
    args = ["--instance", ctx.origin, "login"] ++ if(scopes, do: ["--scope", scopes], else: [])
    device_login(ctx, user, args)
  end

  def device_login(ctx, user, args) do
    child = launch(ctx, args)

    try do
      {url, code} = prompt(child, ctx.origin, 200)
      approve(url, code, user)
      child |> finish() |> success()
    after
      if Port.info(child.port, :os_pid), do: interrupt(child, "KILL")
    end
  end

  defp prompt(child, origin, attempts) do
    output = File.read!(child.out) <> "\n" <> File.read!(child.err)
    url = origin <> "/oauth/device"

    case {String.contains?(output, url), Regex.run(~r/\b[A-Z2-9]{4}-[A-Z2-9]{4}\b/, output)} do
      {true, [code]} ->
        {url, code}

      _ when attempts == 0 ->
        flunk("CLI did not print its verification URL and code: " <> output)

      _ ->
        if Port.info(child.port) == nil,
          do: flunk("CLI exited before device approval: " <> output)

        Process.sleep(25)
        prompt(child, origin, attempts - 1)
    end
  end

  # An independent HTTP client submits the real signed-in, CSRF-protected consent
  # form. The CLI subprocess only sees its code, instance, and private state.
  def browser_cookie(user) do
    session = Foreman.Accounts.create_session(user, "second device")

    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:secret_key_base, Endpoint.config(:secret_key_base))
      |> Plug.Session.call(Plug.Session.init(Endpoint.session_options()))
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.put_session(:session_token, session)
      |> Plug.Conn.send_resp(200, "")

    [cookie] = Plug.Conn.get_resp_header(conn, "set-cookie")
    cookie_value(cookie)
  end

  defp approve(url, code, user) do
    page =
      Req.get!(url,
        params: [user_code: code],
        headers: [cookie: browser_cookie(user)],
        redirect: false
      )

    assert page.status == 200
    consent = page.body |> LazyHTML.from_document() |> LazyHTML.query("#device-consent")
    assert LazyHTML.attribute(LazyHTML.query(consent, "input[name=user_code]"), "value") == [code]
    [csrf] = LazyHTML.attribute(LazyHTML.query(consent, "input[name=_csrf_token]"), "value")
    [updated] = Req.Response.get_header(page, "set-cookie")

    result =
      Req.post!(url,
        form: [_csrf_token: csrf, user_code: code, decision: "approve"],
        headers: [cookie: cookie_value(updated)],
        redirect: false
      )

    assert result.status == 200
  end

  defp cookie_value(header), do: header |> String.split(";", parts: 2) |> hd()
end
