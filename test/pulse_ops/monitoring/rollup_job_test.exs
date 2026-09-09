defmodule PulseOps.Monitoring.RollupJobTest do
  use PulseOps.DataCase, async: true
  use Oban.Testing, repo: PulseOps.Repo

  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.Check
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.Rollup
  alias PulseOps.Monitoring.RollupJob

  setup do
    scope = organization_scope_fixture()
    %{service: service_fixture(scope)}
  end

  defp recorded_hours_ago(service, hours) do
    {:ok, check} =
      Monitoring.record_check(service, :healthy, %Result{http_status: 200, response_time_ms: 15})

    {1, nil} =
      Repo.update_all(
        from(c in Check, where: c.id == ^check.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -hours * 3600, :second)]
      )

    check
  end

  test "rolls up the hour that has just finished", %{service: service} do
    recorded_hours_ago(service, 1)

    assert {:ok, 1} = perform_job(RollupJob, %{})

    rollup = Repo.one!(from r in Rollup, where: r.service_id == ^service.id)
    assert rollup.total == 1
  end

  test "leaves the current hour alone", %{service: service} do
    # Still being written to; rolling it up would produce a row that goes stale
    # the moment the next probe lands. Reads cover it from the raw checks.
    {:ok, _check} =
      Monitoring.record_check(service, :healthy, %Result{http_status: 200, response_time_ms: 15})

    assert {:ok, 0} = perform_job(RollupJob, %{})
    assert Repo.aggregate(Rollup, :count) == 0
  end

  test "rolls up a specific hour on request", %{service: service} do
    recorded_hours_ago(service, 5)

    assert {:ok, 0} = perform_job(RollupJob, %{"hours_ago" => 1})
    assert {:ok, 1} = perform_job(RollupJob, %{"hours_ago" => 5})
  end

  test "backfills a range of hours", %{service: service} do
    for hours <- 1..4, do: recorded_hours_ago(service, hours)

    assert {:ok, 4} = perform_job(RollupJob, %{"backfill" => 4})
    assert Repo.aggregate(Rollup, :count) == 4
  end

  test "a retried job converges instead of double-counting", %{service: service} do
    recorded_hours_ago(service, 1)

    assert {:ok, 1} = perform_job(RollupJob, %{})
    assert {:ok, 1} = perform_job(RollupJob, %{})

    rollup = Repo.one!(from r in Rollup, where: r.service_id == ^service.id)
    assert rollup.total == 1
  end
end
