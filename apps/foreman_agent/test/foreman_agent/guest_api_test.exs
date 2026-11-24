defmodule ForemanAgent.GuestAPITest do
  # The socket an environment's containers reach the public API on: plain
  # HTTP in, one request the box is asked to relay out.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ForemanAgent.Guest.API

  @env "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  setup do
    # Unix socket paths are short on macOS; System.tmp_dir/0 is long there.
    root = Path.join("/tmp", "fma-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, socket: Path.join([root, @env, "api.sock"])}
  end

  defp start_api(ctx, relay, opts \\ []) do
    test = self()

    relay =
      relay ||
        fn request ->
          send(test, {:asked, request})
          {:ok, %{status: 200, body: ~s({"ok":true}), headers: %{}}}
        end

    api =
      start_supervised!(
        {API, [name: nil, root: ctx.root, relay: relay] ++ opts},
        id: make_ref()
      )

    :ok = API.ensure(api, @env)
    api
  end

  defp get(ctx, target, opts \\ []),
    do:
      Req.request(
        [url: "http://foreman" <> target, unix_socket: ctx.socket, retry: false] ++ opts
      )

  # A client that says exactly what it's given, and reads until the close.
  defp raw(ctx, payload) do
    {:ok, socket} =
      :gen_tcp.connect({:local, ctx.socket}, 0, [:binary, active: false, packet: :raw], 2_000)

    # A client the listener has already hung up on can't send at all.
    _ = :gen_tcp.send(socket, payload)
    read_all(socket, "")
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, _} -> acc
    end
  end

  defp status(response), do: response |> String.split(" ", parts: 3) |> Enum.at(1)

  describe "ensure/2" do
    test "listens in the environment's directory, for its owner alone", ctx do
      start_api(ctx, nil)

      assert %File.Stat{type: :other, mode: mode} = File.stat!(ctx.socket)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert Bitwise.band(File.stat!(Path.dirname(ctx.socket)).mode, 0o777) == 0o700
    end

    test "again is no second listener, and a socket that went missing comes back", ctx do
      api = start_api(ctx, nil)
      assert :ok = API.ensure(api, @env)
      assert {:ok, %{status: 200}} = get(ctx, "/api/v1/me")

      File.rm!(ctx.socket)
      assert :ok = API.ensure(api, @env)
      assert {:ok, %{status: 200}} = get(ctx, "/api/v1/me")
    end

    test "takes an environment id and nothing that could be a path", ctx do
      api = start_api(ctx, nil)

      for bad <- ["../escape", "a/b", "", "not-a-uuid", nil, @env <> "/x"] do
        assert API.ensure(api, bad) == :error
      end

      assert File.ls!(ctx.root) == [@env]
    end

    test "listens again when whatever was accepting for it has gone", ctx do
      api = start_api(ctx, nil)
      assert {:ok, %{status: 200}} = get(ctx, "/api/v1/me")

      {_socket, acceptor, _monitor} = :sys.get_state(api).listeners[@env]
      Process.exit(acceptor, :kill)
      refute Process.alive?(acceptor)

      # With nothing asking it to: an idle environment gets no command.
      wait_until(fn ->
        case :sys.get_state(api).listeners[@env] do
          {_socket, pid, _monitor} -> pid != acceptor and Process.alive?(pid)
          nil -> false
        end
      end)

      assert {:ok, %{status: 200}} = get(ctx, "/api/v1/me")
    end

    test "only in a real directory of its own, and only over a socket it left", ctx do
      api =
        start_supervised!({API, name: nil, root: ctx.root, relay: fn _ -> :error end}, id: :own)

      other = "0b5c2f6e-1d6f-4f6b-9b7e-0c9e4f0a1b2c"

      # A link where the environment's directory should be goes nowhere.
      elsewhere = Path.join(ctx.root, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.chmod!(elsewhere, 0o755)
      File.ln_s!(elsewhere, Path.join(ctx.root, other))

      capture_log(fn -> assert API.ensure(api, other) == :error end)
      assert File.ls!(elsewhere) == []
      assert Bitwise.band(File.stat!(elsewhere).mode, 0o777) == 0o755

      # Something that isn't a socket where the socket goes is left alone.
      dir = Path.join(ctx.root, @env)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "api.sock"), "not a socket")

      capture_log(fn -> assert API.ensure(api, @env) == :error end)
      assert File.read!(Path.join(dir, "api.sock")) == "not a socket"

      # Nor a FIFO, which looks the same until its mode is read.
      File.rm!(Path.join(dir, "api.sock"))
      {_, 0} = System.cmd("mkfifo", [Path.join(dir, "api.sock")])
      capture_log(fn -> assert API.ensure(api, @env) == :error end)
      assert File.lstat!(Path.join(dir, "api.sock")).type == :other
    end

    test "at its start, listens for the environments the VM already has", ctx do
      other = "0b5c2f6e-1d6f-4f6b-9b7e-0c9e4f0a1b2c"
      File.mkdir_p!(Path.join(ctx.root, other))
      File.mkdir_p!(Path.join(ctx.root, "not-an-environment"))
      File.write!(Path.join(ctx.root, "a-file"), "")
      File.mkdir_p!(Path.join(ctx.root, "linked-elsewhere"))

      File.ln_s!(
        Path.join(ctx.root, "linked-elsewhere"),
        Path.join(ctx.root, "9d2c7b1a-5e4f-4a3b-8c2d-1e0f9a8b7c6d")
      )

      start_supervised!({API, name: nil, root: ctx.root, relay: fn _ -> :error end}, id: :boot)

      assert File.exists?(Path.join([ctx.root, other, "api.sock"]))
      refute File.exists?(Path.join([ctx.root, "not-an-environment", "api.sock"]))
      refute File.exists?(Path.join([ctx.root, "linked-elsewhere", "api.sock"]))
    end
  end

  describe "a request" do
    test "is handed on as it came, and the answer handed back", ctx do
      test = self()

      start_api(ctx, fn request ->
        send(test, {:asked, request})

        {:ok,
         %{
           status: 202,
           body: ~s({"operation_id":"abc"}),
           headers: %{"location" => "/api/v1/operations/abc", "retry-after" => "2"}
         }}
      end)

      body = ~s({"action":"restart_all"})

      assert {:ok, response} =
               get(ctx, "/api/v1/environments/#{@env}/operations?x=1",
                 method: :post,
                 body: body,
                 headers: [
                   {"content-type", "application/json"},
                   {"idempotency-key", "k-1"},
                   {"authorization", "Bearer ignored"},
                   {"x-foreman-environment", "0b5c2f6e-1d6f-4f6b-9b7e-0c9e4f0a1b2c"}
                 ]
               )

      assert response.status == 202
      assert response.body == %{"operation_id" => "abc"}
      assert Req.Response.get_header(response, "location") == ["/api/v1/operations/abc"]
      assert Req.Response.get_header(response, "retry-after") == ["2"]
      assert Req.Response.get_header(response, "content-type") == ["application/json"]

      assert_received {:asked, request}

      # Nothing of the client's headers but the key is passed on.
      assert request == %{
               "method" => "POST",
               "target" => "/api/v1/environments/#{@env}/operations?x=1",
               "body" => body,
               "idempotency_key" => "k-1"
             }
    end

    test "with no body or key carries neither", ctx do
      start_api(ctx, nil)
      assert {:ok, %{status: 200}} = get(ctx, "/api/v1/me")
      assert_received {:asked, request}
      assert request == %{"method" => "GET", "target" => "/api/v1/me"}
    end

    test "a PATCH, and a client that waits to be told to continue", ctx do
      start_api(ctx, nil)
      body = ~s({"unset":["A"]})

      response =
        raw(
          ctx,
          "PATCH /api/v1/secrets/environment/#{@env} HTTP/1.1\r\nHost: foreman\r\n" <>
            "Content-Length: #{byte_size(body)}\r\nExpect: 100-continue\r\n\r\n" <> body
        )

      assert response =~ "HTTP/1.1 100 Continue\r\n\r\n"
      assert response =~ "HTTP/1.1 200 OK\r\n"
      assert response =~ "connection: close\r\n"
      assert String.ends_with?(response, ~s({"ok":true}))

      assert_received {:asked, %{"method" => "PATCH", "body" => ^body}}
    end

    test "what the box can't be asked just now is an error the client can show", ctx do
      for {reason, expected} <- [
            {:not_connected, 503},
            {:busy, 429},
            {:timeout, 504},
            {:too_large, 413},
            {:anything_else, 502}
          ] do
        File.rm_rf!(Path.dirname(ctx.socket))
        start_api(ctx, fn _request -> {:error, reason} end)

        assert {:ok, %{status: ^expected, body: %{"code" => code, "message" => message}}} =
                 get(ctx, "/api/v1/me")

        assert is_binary(code) and is_binary(message)
      end
    end

    test "a relay that crashes is an error, and the next request is still served", ctx do
      test = self()

      start_api(ctx, fn request ->
        send(test, :asked)
        if request["target"] == "/api/v1/boom", do: raise("boom")
        {:ok, %{status: 200, body: "{}", headers: %{}}}
      end)

      capture_log(fn ->
        assert {:ok, %{status: 502}} = get(ctx, "/api/v1/boom")
      end)

      assert {:ok, %{status: 200}} = get(ctx, "/api/v1/me")
    end
  end

  describe "a request that isn't one" do
    test "is refused without being handed on", ctx do
      start_api(ctx, nil)
      big = API.max_body() + 1

      for {payload, expected} <- [
            {"nonsense\r\n\r\n", "400"},
            {"GET http://elsewhere/api/v1/me HTTP/1.1\r\n\r\n", "400"},
            {"GET * HTTP/1.1\r\n\r\n", "400"},
            {"GET /api/v1/me HTTP/1.1\r\nContent-Length: nope\r\n\r\n", "400"},
            {"GET /api/v1/me HTTP/1.1\r\nContent-Length: -1\r\n\r\n", "400"},
            {"GET /api/v1/me HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab",
             "400"},
            {"POST /api/v1/environments HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
             "411"},
            {"POST /api/v1/environments HTTP/1.1\r\nContent-Length: #{big}\r\n\r\n", "413"},
            {"GET /api/v1/me HTTP/1.1\r\n" <>
               String.duplicate("X-Filler: 1\r\n", API.max_headers() + 1) <> "\r\n", "400"},
            {"GET /api/v1/me HTTP/1.1\r\nIdempotency-Key: a\r\nIdempotency-Key: b\r\n\r\n", "400"}
          ] do
        response = raw(ctx, payload)
        assert status(response) == expected, "#{inspect(payload, printable_limit: 60)}"
        assert response =~ ~s("code":)
      end

      # A line longer than a request's can be closes the connection where
      # it is read, before there is anything to answer.
      assert raw(ctx, "GET /" <> String.duplicate("a", 10_000) <> " HTTP/1.1\r\n\r\n") == ""
      assert {:ok, %{status: 200}} = get(ctx, "/api/v1/me")
      assert_received {:asked, %{"target" => "/api/v1/me"}}
      refute_received {:asked, _}
    end

    test "text that isn't text is refused here, before it can reach the box", ctx do
      start_api(ctx, nil)

      for payload <- [
            "GET /api/v1/\xff\xfe HTTP/1.1\r\n\r\n",
            "GET /api/v1/me?x=\xc3\x28 HTTP/1.1\r\n\r\n",
            "POST /api/v1/environments HTTP/1.1\r\nIdempotency-Key: \xff\r\n\r\n",
            "POST /api/v1/environments HTTP/1.1\r\nContent-Length: 2\r\n\r\n\xff\xfe"
          ] do
        assert status(raw(ctx, payload)) == "400"
      end

      refute_received {:asked, _}
    end

    test "a method is passed on as it was written, for the box to refuse", ctx do
      start_api(ctx, nil)
      raw(ctx, "get /api/v1/me HTTP/1.1\r\n\r\n")
      assert_received {:asked, %{"method" => "get"}}
    end

    test "a client that keeps sending after its answer is hung up on all the same", ctx do
      start_api(ctx, nil)

      {:ok, socket} = :gen_tcp.connect({:local, ctx.socket}, 0, [:binary, active: false], 2_000)
      :ok = :gen_tcp.send(socket, "GET /api/v1/me HTTP/1.1\r\nContent-Length: nope\r\n\r\n")

      dripper =
        spawn(fn ->
          for _ <- 1..100 do
            :gen_tcp.send(socket, "x")
            Process.sleep(100)
          end
        end)

      started = System.monotonic_time(:millisecond)
      assert {:error, :closed} = drain(socket)
      assert System.monotonic_time(:millisecond) - started < 3_000
      Process.exit(dripper, :kill)
    end

    test "a client that stops partway is hung up on, and doesn't hold a place", ctx do
      api = start_api(ctx, nil, read_timeout: 100, max_connections: 2)

      stalled =
        for _ <- 1..2 do
          {:ok, socket} =
            :gen_tcp.connect({:local, ctx.socket}, 0, [:binary, active: false], 2_000)

          :ok =
            :gen_tcp.send(
              socket,
              "POST /api/v1/environments HTTP/1.1\r\nContent-Length: 5\r\n\r\nab"
            )

          socket
        end

      for socket <- stalled, do: assert({:error, :closed} = drain(socket))
      wait_until(fn -> map_size(:sys.get_state(api).clients) == 0 end)
      assert {:ok, %{status: 200}} = get(ctx, "/api/v1/me")
    end

    test "more clients at once than it serves are turned away, then served again", ctx do
      test = self()

      api =
        start_api(
          ctx,
          fn _request ->
            send(test, {:held, self()})

            receive do
              :go -> {:ok, %{status: 200, body: "{}", headers: %{}}}
            end
          end,
          max_connections: 2
        )

      tasks = for _ <- 1..2, do: Task.async(fn -> get(ctx, "/api/v1/me") end)

      held =
        for _ <- 1..2 do
          assert_receive {:held, pid}, 5_000
          pid
        end

      # Past the limit a client is hung up on, with no process or socket
      # of its own kept for it.
      handlers = fn -> map_size(:sys.get_state(api).clients) end
      assert handlers.() == 2

      for _ <- 1..50 do
        assert raw(ctx, "GET /api/v1/me HTTP/1.1\r\n\r\n") == ""
      end

      assert handlers.() == 2

      Enum.each(held, &send(&1, :go))
      for task <- tasks, do: assert({:ok, %{status: 200}} = Task.await(task))

      # A place is held until its client has hung up, which is a moment
      # after the client has its answer.
      wait_until(fn -> handlers.() == 0 end)

      again = Task.async(fn -> get(ctx, "/api/v1/me") end)
      assert_receive {:held, pid}, 5_000
      send(pid, :go)
      assert {:ok, %{status: 200}} = Task.await(again)
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out waiting")
      true -> Process.sleep(50) && wait_until(fun, tries - 1)
    end
  end

  defp drain(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, _} -> drain(socket)
      error -> error
    end
  end
end
