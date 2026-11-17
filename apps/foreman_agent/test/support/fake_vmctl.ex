defmodule ForemanAgent.Test.FakeVmctl do
  @moduledoc """
  Stands in for foreman-vmctl, the VM helper, on a unix socket: answers
  each request line from a table keyed by the request's first word
  (`"error unknown request"` for the rest) and sends the test process
  `{:vmctl, line}` for each one.
  """

  @doc "Listens on `path`; returns a config that points the agent at it."
  def start(path, answers) do
    test = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, path}}, packet: :line, active: false])

    pid = spawn_link(fn -> serve(listen, answers, test) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    %ForemanAgent.Config{vmctl_socket: path}
  end

  defp serve(listen, answers, test) do
    {:ok, client} = :gen_tcp.accept(listen)
    {:ok, line} = :gen_tcp.recv(client, 0)
    line = String.trim_trailing(line)
    send(test, {:vmctl, line})
    request = line |> String.split() |> hd()
    :ok = :gen_tcp.send(client, Map.get(answers, request, "error unknown request") <> "\n")
    :gen_tcp.close(client)
    serve(listen, answers, test)
  end
end
