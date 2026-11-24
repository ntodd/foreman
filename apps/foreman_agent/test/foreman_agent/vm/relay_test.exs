defmodule ForemanAgent.VM.RelayTest do
  # What the box does with a public API request an environment's VM sends:
  # checks it, signs it for that environment and forwards it.
  use ExUnit.Case, async: true

  alias ForemanAgent.VM.Relay
  alias ForemanProtocol.Auth

  @env "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @other "0b5c2f6e-1d6f-4f6b-9b7e-0c9e4f0a1b2c"
  @agent "9d2c7b1a-5e4f-4a3b-8c2d-1e0f9a8b7c6d"

  defp frame(overrides \\ %{}) do
    Map.merge(%{"t" => "api", "id" => 1, "method" => "GET", "target" => "/api/v1/me"}, overrides)
  end

  describe "request/1: what a VM may ask for" do
    test "a read, with a query" do
      assert {:ok, %{method: "GET", path: "/me", query: nil, body: "", key: nil}} =
               Relay.request(frame())

      assert {:ok, %{path: "/environments/" <> @env, query: nil}} =
               Relay.request(frame(%{"target" => "/api/v1/environments/#{@env}"}))

      assert {:ok, %{path: "/operations/x/logs", query: "cursor=abc_-DEF%3D&limit=5"}} =
               Relay.request(
                 frame(%{"target" => "/api/v1/operations/x/logs?cursor=abc_-DEF%3D&limit=5"})
               )
    end

    test "a change, with its body and idempotency key" do
      body = ~s({"action":"restart_all"})

      assert {:ok, %{method: "POST", body: ^body, key: "k-1"}} =
               Relay.request(
                 frame(%{
                   "method" => "POST",
                   "target" => "/api/v1/environments/#{@env}/operations",
                   "body" => body,
                   "idempotency_key" => "k-1"
                 })
               )

      assert {:ok, %{method: "PATCH"}} =
               Relay.request(
                 frame(%{
                   "method" => "PATCH",
                   "target" => "/api/v1/secrets/environment/#{@env}",
                   "body" => "{}"
                 })
               )
    end

    test "nothing outside the public API, however the path is written" do
      for target <- [
            "/api/agents/enroll",
            "/api/agents/relay/v1/me",
            "/api/v2/me",
            "/api/v1",
            "/api/v1/",
            "/admin/apps",
            "/oauth/token",
            "/agent/install.sh",
            "api/v1/me",
            "//api/v1/me",
            "/api/v1//me",
            "/api/v1/me/",
            "/api/v1/../agents/enroll",
            "/api/v1/environments/../../agents/enroll",
            "/api/v1/./me",
            "/api/v1/a..b",
            "/api/v1/%2e%2e/agents/enroll",
            "/api/v1/me%2f..",
            "/api/v1/me%00",
            "/api/v1/me;x=1",
            "/api/v1/me#frag",
            "/api/v1/me\\..",
            "/api/v1/me x",
            "/api/v1/me\n/api/v1/boxes",
            "/api/v1/me\r\nx-foreman-environment: #{@other}",
            "/api/v1/me?a=b#c",
            "/api/v1/me?a=b c",
            "/api/v1/me?a=%zz",
            "/api/v1/me?a=%2",
            "/api/v1/me?a=b\nc",
            "/api/v1/me?a=b?c",
            "http://example.com/api/v1/me",
            "/api/v1/" <> String.duplicate("a", 2_000),
            "/api/v1/me?" <> String.duplicate("a", 3_000),
            "",
            nil,
            42,
            ["/api/v1/me"]
          ] do
        assert Relay.request(frame(%{"target" => target})) == :error,
               "#{inspect(target)} was accepted"
      end
    end

    test "only the methods the API uses, and a body only with a change" do
      for method <- ["DELETE", "PUT", "HEAD", "OPTIONS", "CONNECT", "TRACE", "get", "", nil, 1] do
        assert Relay.request(frame(%{"method" => method})) == :error
      end

      assert Relay.request(frame(%{"body" => "{}"})) == :error
      assert Relay.request(frame(%{"idempotency_key" => "k"})) == :error
      assert {:ok, %{body: ""}} = Relay.request(frame(%{"body" => ""}))

      post = %{"method" => "POST", "target" => "/api/v1/environments"}
      assert {:ok, %{body: ""}} = Relay.request(frame(post))
      assert Relay.request(frame(Map.put(post, "body", 1))) == :error
      assert Relay.request(frame(Map.put(post, "body", %{"a" => 1}))) == :error

      big = String.duplicate("a", Relay.max_body() + 1)
      assert Relay.request(frame(Map.put(post, "body", big))) == :error
    end

    test "an idempotency key that could carry a header of its own is refused" do
      post = %{"method" => "POST", "target" => "/api/v1/environments"}

      for key <- [
            "a b",
            "a\r\nx-foreman-environment: #{@other}",
            "",
            String.duplicate("k", 256),
            7
          ] do
        assert Relay.request(frame(Map.put(post, "idempotency_key", key))) == :error
      end
    end

    test "a request id the box can't answer to is refused" do
      for id <- [-1, 1.5, "1", nil, 9_007_199_254_740_993] do
        assert Relay.request(frame(%{"id" => id})) == :error
      end
    end
  end

  describe "forward/3" do
    setup do
      {public, private} = Auth.generate_keypair()
      test = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:control_plane, conn, body})

        receive do
          {:respond, fun} -> fun.(conn)
        after
          0 -> Plug.Conn.send_resp(conn, 200, ~s({"ok":true}))
        end
      end

      opts = [
        identity: %ForemanAgent.Identity{agent_id: @agent, private_key: private},
        url: "https://foreman.example.test",
        req_options: [plug: plug]
      ]

      %{public: public, opts: opts}
    end

    defp request(overrides \\ %{}) do
      {:ok, request} = Relay.request(frame(overrides))
      request
    end

    defp verify(conn, body, public) do
      target =
        if conn.query_string == "",
          do: conn.request_path,
          else: conn.request_path <> "?" <> conn.query_string

      Auth.verify_relay_headers(Map.new(conn.req_headers), fn @agent -> {:ok, public} end, %{
        method: conn.method,
        target: target,
        body_sha256: :crypto.hash(:sha256, body),
        idempotency_key: List.first(Plug.Conn.get_req_header(conn, "idempotency-key"))
      })
    end

    test "sends it to the relay's mount of the same route, signed for the VM's environment",
         ctx do
      assert %{status: 200, body: ~s({"ok":true})} =
               Relay.forward(
                 @env,
                 request(%{"target" => "/api/v1/environments?limit=5"}),
                 ctx.opts
               )

      assert_received {:control_plane, conn, ""}
      assert conn.method == "GET"
      assert conn.host == "foreman.example.test"
      assert conn.request_path == "/api/agents/relay/v1/environments"
      assert conn.query_string == "limit=5"
      assert {:ok, %{agent_id: @agent, environment: @env}} = verify(conn, "", ctx.public)
    end

    test "the signature covers the body and the environment the box says it is", ctx do
      body = ~s({"secrets":[{"name":"A","value":"one"}]})

      Relay.forward(
        @env,
        request(%{
          "method" => "PATCH",
          "target" => "/api/v1/secrets/environment/#{@other}",
          "body" => body,
          "idempotency_key" => "k-9"
        }),
        ctx.opts
      )

      assert_received {:control_plane, conn, ^body}
      # The VM asked about another environment's secrets. The path says so,
      # and the signature still names the environment the VM is.
      assert conn.request_path == "/api/agents/relay/v1/secrets/environment/#{@other}"
      assert {:ok, %{environment: @env}} = verify(conn, body, ctx.public)
      assert {:error, :bad_signature} = verify(conn, body <> " ", ctx.public)

      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["k-9"]

      # The key is signed too: with another, or none, it's a different request.
      for other <- [[{"idempotency-key", "k-10"}], []] do
        changed = %{
          conn
          | req_headers: List.keydelete(conn.req_headers, "idempotency-key", 0) ++ other
        }

        assert {:error, :bad_signature} = verify(changed, body, ctx.public)
      end
    end

    test "only over a transport that can't be tampered with, unless the box is told to", ctx do
      sent? = fn url, extra ->
        opts = ctx.opts |> Keyword.put(:url, url) |> Keyword.merge(extra)
        reply = Relay.forward(@env, request(), opts)

        receive do
          {:control_plane, _conn, _body} -> {:sent, reply.status}
        after
          0 -> {:refused, JSON.decode!(reply.body)["code"]}
        end
      end

      for url <- [
            "https://foreman.example.test",
            "http://127.0.0.1:4000",
            "http://localhost:4000",
            "http://[::1]:4000"
          ] do
        assert sent?.(url, []) == {:sent, 200}, url
      end

      for url <- [
            "http://foreman.example.test",
            "http://10.0.0.5:4000",
            "http://127.0.0.1.example.test",
            "http://localhost.example.test:4000",
            "ftp://foreman.example.test",
            "foreman.example.test"
          ] do
        assert sent?.(url, []) == {:refused, "relay_insecure_transport"}, url
      end

      assert sent?.("http://foreman.example.test", insecure: true) == {:sent, 200}

      assert sent?.("ftp://foreman.example.test", insecure: true) ==
               {:refused, "relay_insecure_transport"}
    end

    test "a query that is there but empty is left off, as the control plane will read it",
         ctx do
      Relay.forward(@env, request(%{"target" => "/api/v1/me?"}), ctx.opts)

      assert_received {:control_plane, conn, ""}
      assert conn.query_string == ""
      assert {:ok, _} = verify(conn, "", ctx.public)
    end

    test "carries nothing else the VM might have wanted sent", ctx do
      Relay.forward(@env, request(), ctx.opts)
      assert_received {:control_plane, conn, ""}

      names = conn.req_headers |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert names -- ["accept", "accept-encoding", "user-agent", "host"] ==
               Enum.sort(Auth.relay_header_names())

      assert Plug.Conn.get_req_header(conn, "authorization") == []
    end

    test "passes the status, the body and the headers a client needs back", ctx do
      send(self(), {
        :respond,
        fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "/api/v1/operations/abc")
          |> Plug.Conn.put_resp_header("retry-after", "3")
          |> Plug.Conn.put_resp_header("set-cookie", "session=1")
          |> Plug.Conn.put_resp_header("x-request-id", "r1")
          |> Plug.Conn.send_resp(202, ~s({"operation_id":"abc"}))
        end
      })

      assert %{status: 202, body: ~s({"operation_id":"abc"}), headers: headers} =
               Relay.forward(@env, request(), ctx.opts)

      assert headers == %{"location" => "/api/v1/operations/abc", "retry-after" => "3"}
    end

    test "a refusal comes back as it is", ctx do
      send(self(), {
        :respond,
        &Plug.Conn.send_resp(&1, 403, ~s({"code":"insufficient_scope","message":"no"}))
      })

      assert %{status: 403, body: ~s({"code":"insufficient_scope","message":"no"})} =
               Relay.forward(@env, request(), ctx.opts)
    end

    test "a redirect isn't followed", ctx do
      send(self(), {
        :respond,
        fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/api/v1/me")
          |> Plug.Conn.send_resp(302, "")
        end
      })

      assert %{status: 302} = Relay.forward(@env, request(), ctx.opts)
      assert_received {:control_plane, _conn, ""}
      refute_received {:control_plane, _conn, _}
    end

    test "an answer too large or not text is an error, not passed on", ctx do
      send(self(), {
        :respond,
        &Plug.Conn.send_resp(&1, 200, String.duplicate("a", Relay.max_reply() + 1))
      })

      assert %{status: 502, body: body} = Relay.forward(@env, request(), ctx.opts)
      assert %{"code" => "relay_failed"} = JSON.decode!(body)

      send(self(), {:respond, &Plug.Conn.send_resp(&1, 200, <<255, 254, 0>>)})
      assert %{status: 502} = Relay.forward(@env, request(), ctx.opts)
    end

    test "a control plane that can't be reached is an error the client can show", ctx do
      opts =
        Keyword.put(ctx.opts, :req_options, plug: &Req.Test.transport_error(&1, :econnrefused))

      assert %{status: 502, body: body, headers: %{}} = Relay.forward(@env, request(), opts)
      assert %{"code" => "relay_failed", "message" => message} = JSON.decode!(body)
      assert message =~ "control plane"
    end

    test "a box that isn't enrolled can't relay", ctx do
      opts = Keyword.put(ctx.opts, :identity, nil)
      assert %{status: 502} = Relay.forward(@env, request(), opts)
      refute_received {:control_plane, _, _}
    end

    test "errors for what the box refuses itself read like the API's" do
      for reply <- [Relay.invalid(), Relay.busy(), Relay.timed_out()] do
        assert %{status: status, body: body, headers: %{}} = reply
        assert status in 400..599
        assert %{"code" => code, "message" => message} = JSON.decode!(body)
        assert is_binary(code) and is_binary(message)
      end
    end
  end
end
