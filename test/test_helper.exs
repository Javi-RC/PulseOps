ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(PulseOps.Repo, :manual)

Mox.defmock(PulseOps.Monitoring.HealthCheckMock, for: PulseOps.Monitoring.HealthCheck)
