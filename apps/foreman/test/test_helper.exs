Mox.defmock(Foreman.GitHub.ClientMock, for: Foreman.GitHub.Client)
Mox.defmock(Foreman.Tailscale.ClientMock, for: Foreman.Tailscale.Client)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Foreman.Repo, :manual)
