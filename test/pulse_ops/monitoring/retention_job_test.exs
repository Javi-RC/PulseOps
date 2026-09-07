defmodule PulseOps.Monitoring.RetentionJobTest do
  use PulseOps.DataCase, async: true
  use Oban.Testing, repo: PulseOps.Repo

  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.RetentionJob

  setup do
    scope = organization_scope_fixture()
    service = service_fixture(scope)
    %{service: service}
  end

  test "prunes checks older than the given days", %{service: service} do
    recent =
      Monitoring.record_check(service, :healthy, %Result{
        http_status: 200,
        response_time_ms: 10
      })

    old =
      Monitoring.record_check(service, :down, %Result{
        error: "down"
      })

    {1, nil} =
      Repo.update_all(
        from(c in PulseOps.Monitoring.Check, where: c.id == ^old.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -31, :day)]
      )

    assert {:ok, 1} = perform_job(RetentionJob, %{"days" => 30})
    assert Repo.get(PulseOps.Monitoring.Check, old.id) == nil
    assert %PulseOps.Monitoring.Check{} = Repo.get(PulseOps.Monitoring.Check, recent.id)
  end

  test "falls back to the configured retention window", %{service: service} do
    old =
      Monitoring.record_check(service, :down, %Result{
        error: "down"
      })

    {1, nil} =
      Repo.update_all(
        from(c in PulseOps.Monitoring.Check, where: c.id == ^old.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -31, :day)]
      )

    assert {:ok, 1} = perform_job(RetentionJob, %{})
    assert Repo.get(PulseOps.Monitoring.Check, old.id) == nil
  end
end
