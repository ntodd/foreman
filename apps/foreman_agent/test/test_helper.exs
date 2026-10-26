Mox.defmock(ForemanAgent.RunnerMock, for: ForemanAgent.Runner)
Mox.defmock(ForemanAgent.DockerMock, for: ForemanAgent.Docker)

ExUnit.configure(exclude: [:docker, :host_pids])
ExUnit.start(capture_log: true)
