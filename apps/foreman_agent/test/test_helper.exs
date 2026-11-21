Mox.defmock(ForemanAgent.RunnerMock, for: ForemanAgent.Runner)
Mox.defmock(ForemanAgent.DockerMock, for: ForemanAgent.Docker)
Mox.defmock(ForemanAgent.DevcontainerMock, for: ForemanAgent.Devcontainer)

# A release loads every module as it boots, but `mix test` loads each one
# the first time something calls it. That load waits on the code server,
# which is busy loading test files while the first async tests run, so on
# a slow runner an operation's process could take over a second to send
# its first message. Load the agent's modules and its dependencies' now,
# as the release does. An optional dependency that isn't installed
# (castore, for one) is skipped.
preload = fn preload, app, seen ->
  if app not in seen and Application.ensure_loaded(app) == :ok do
    Code.ensure_all_loaded!(Application.spec(app, :modules))
    Enum.reduce(Application.spec(app, :applications), [app | seen], &preload.(preload, &1, &2))
  else
    [app | seen]
  end
end

preload.(preload, :foreman_agent, [])

ExUnit.configure(exclude: [:docker, :host_pids])
ExUnit.start(capture_log: true)
