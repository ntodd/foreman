Mox.defmock(ForemanAgent.RunnerMock, for: ForemanAgent.Runner)
Mox.defmock(ForemanAgent.DockerMock, for: ForemanAgent.Docker)

ExUnit.configure(exclude: [:docker])
ExUnit.start(capture_log: true)
