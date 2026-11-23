defmodule Foreman.GitHubMembershipTest do
  use ExUnit.Case, async: false

  alias Foreman.GitHub.Client.Req, as: GitHubReq

  setup do
    previous = Application.get_env(:foreman, :github_req_options, [])
    Application.put_env(:foreman, :github_req_options, plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.put_env(:foreman, :github_req_options, previous) end)
  end

  test "one requested ID and name end the scan on the first page of a large installation" do
    pages(fn conn, page ->
      assert page == 1
      Req.Test.json(conn, %{"total_count" => 12_345, "repositories" => rows(1..100)})
    end)

    assert result([17]) == matches([17])
  end

  test "a full final page at 5000 is a real end even with an unmatched candidate" do
    pages(fn conn, page ->
      assert page <= 50

      Req.Test.json(conn, %{
        "total_count" => 5000,
        "repositories" => rows((page * 100 - 99)..(page * 100))
      })
    end)

    assert result([5000, 5001]) == matches([5000])
  end

  test "a match beyond page 50 is reachable and requires both the stable ID and the name" do
    pages(fn conn, page ->
      assert page <= 51

      Req.Test.json(conn, %{
        "total_count" => 7000,
        "repositories" => rows((page * 100 - 99)..(page * 100))
      })
    end)

    assert result([5001]) == matches([5001])

    pages(fn conn, _ ->
      Req.Test.json(conn, %{
        "repositories" => [
          %{"id" => 9, "full_name" => "org/different"},
          %{"id" => 19, "full_name" => "org/r9"}
        ]
      })
    end)

    assert result([9]) == matches([])
  end

  test "a next link on a short page continues only at the canonical installation endpoint" do
    pages(fn conn, page ->
      if page == 1 do
        conn
        |> Plug.Conn.put_resp_header(
          "link",
          ~s(<https://elsewhere.invalid/private?page=2>; rel="next")
        )
        |> Req.Test.json(%{"repositories" => rows(1..3)})
      else
        assert page == 2
        Req.Test.json(conn, %{"repositories" => rows(4..6)})
      end
    end)

    assert result([5]) == matches([5])
  end

  test "a repeated page fails the incomplete membership check" do
    pages(fn conn, page ->
      assert page <= 2

      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(</user/installations/42/repositories?page=#{page + 1}>; rel="next")
      )
      |> Req.Test.json(%{"repositories" => rows(1..100)})
    end)

    assert {:error, _} = result([5001])
  end

  defp rows(ids), do: Enum.map(ids, &%{"id" => &1, "full_name" => "Org/R#{&1}"})
  defp matches(ids), do: {:ok, MapSet.new(ids, &{&1, "org/r#{&1}"})}

  defp result(ids) do
    {:ok, requested} = matches(ids)
    GitHubReq.user_installation_membership("test-token", 42, requested)
  end

  defp pages(fun) do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "api.github.com"
      assert conn.request_path == "/user/installations/42/repositories"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
      params = Plug.Conn.fetch_query_params(conn).query_params
      assert params["per_page"] == "100"
      fun.(conn, String.to_integer(params["page"]))
    end)
  end
end
