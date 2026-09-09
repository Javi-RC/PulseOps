ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(PulseOps.Repo, :manual)

Mox.defmock(PulseOps.Monitoring.HealthCheckMock, for: PulseOps.Monitoring.HealthCheck)
Mox.defmock(PulseOps.Monitoring.TlsCheckMock, for: PulseOps.Monitoring.TlsCheck)
