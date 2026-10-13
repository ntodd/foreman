defmodule ForemanAgent.Test.GitServer do
  @moduledoc """
  Serves fixture repos over git's "dumb" HTTP protocol, so integration
  tests clone over the network the way the agent does in production.
  """

  @fixtures Path.expand("../fixtures/repos", __DIR__)

  @doc "Creates a bare copy of fixture `name` under `root` and serves `root`. Returns the base URL."
  def start(root, names) do
    for name <- List.wrap(names), do: bare_repo(root, name)

    plug = {Plug.Static, at: "/", from: root, gzip: false}
    {:ok, pid} = Bandit.start_link(plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  defp bare_repo(root, name) do
    work = Path.join(root, "#{name}-work")
    bare = Path.join(root, "#{name}.git")
    File.rm_rf!(work)
    File.rm_rf!(bare)
    File.mkdir_p!(root)
    File.cp_r!(Path.join(@fixtures, name), work)

    git = fn args, dir -> {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true) end
    git.(["init", "-q", "-b", "main"], work)
    git.(["add", "-A"], work)

    git.(
      ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "init"],
      work
    )

    git.(["clone", "-q", "--bare", work, bare], root)
    git.(["update-server-info"], bare)
    bare
  end
end
