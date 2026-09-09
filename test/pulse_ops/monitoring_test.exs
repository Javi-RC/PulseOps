defmodule PulseOps.MonitoringTest do
  use PulseOps.DataCase, async: true

  import PulseOps.MonitoringFixtures
  import PulseOps.OrganizationsFixtures

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.Rollup
  alias PulseOps.Monitoring.Service

  @invalid_attrs %{
    name: nil,
    url: nil,
    environment: nil,
    check_interval_ms: nil,
    timeout_ms: nil
  }

  describe "list_services/1" do
    test "returns only the services of the scoped organization" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()

      service = service_fixture(scope)
      other_service = service_fixture(other_scope)

      assert Monitoring.list_services(scope) == [service]
      assert Monitoring.list_services(other_scope) == [other_service]
    end
  end

  describe "get_service!/2" do
    test "returns the service with the given id" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert Monitoring.get_service!(scope, service.id) == service
    end

    test "hides a service belonging to another organization" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert_raise Ecto.NoResultsError, fn ->
        Monitoring.get_service!(other_scope, service.id)
      end
    end
  end

  describe "create_service/2" do
    test "creates a service owned by the scoped organization" do
      scope = organization_scope_fixture()

      attrs =
        valid_service_attributes(%{
          name: "Payments API",
          environment: :staging,
          url: "https://payments.example.com/health",
          check_interval_ms: 30_000,
          timeout_ms: 5_000
        })

      assert {:ok, %Service{} = service} = Monitoring.create_service(scope, attrs)
      assert service.name == "Payments API"
      assert service.environment == :staging
      assert service.url == "https://payments.example.com/health"
      assert service.check_interval_ms == 30_000
      assert service.timeout_ms == 5_000
      assert service.organization_id == scope.organization.id
    end

    test "starts out unknown and unchecked" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      # Status belongs to the monitor, not to the form.
      assert service.status == :unknown
      assert service.last_checked_at == nil
    end

    test "ignores a status supplied through the form" do
      scope = organization_scope_fixture()
      service = service_fixture(scope, %{status: :healthy})

      assert service.status == :unknown
    end

    test "returns an error changeset for invalid data" do
      scope = organization_scope_fixture()

      assert {:error, %Ecto.Changeset{}} = Monitoring.create_service(scope, @invalid_attrs)
    end

    test "rejects a url that is not http or https" do
      scope = organization_scope_fixture()

      for url <- ["not a url", "ftp://example.com", "example.com", "https://"] do
        assert {:error, changeset} =
                 Monitoring.create_service(scope, valid_service_attributes(%{url: url}))

        assert "must be a valid http or https URL" in errors_on(changeset).url
      end
    end

    test "rejects a timeout that does not fit inside the interval" do
      scope = organization_scope_fixture()

      assert {:error, changeset} =
               Monitoring.create_service(
                 scope,
                 valid_service_attributes(%{check_interval_ms: 10_000, timeout_ms: 10_000})
               )

      assert "must be shorter than the check interval" in errors_on(changeset).timeout_ms
    end

    test "rejects intervals outside the supported range" do
      scope = organization_scope_fixture()

      assert {:error, changeset} =
               Monitoring.create_service(
                 scope,
                 valid_service_attributes(%{check_interval_ms: 500})
               )

      assert errors_on(changeset)[:check_interval_ms]
    end

    test "rejects a duplicate name within the same organization" do
      scope = organization_scope_fixture()
      service_fixture(scope, %{name: "Payments API"})

      assert {:error, changeset} =
               Monitoring.create_service(scope, valid_service_attributes(%{name: "Payments API"}))

      assert "a service with this name already exists" in errors_on(changeset).name
    end

    test "allows the same name in a different organization" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()

      service_fixture(scope, %{name: "Payments API"})

      assert {:ok, %Service{}} =
               Monitoring.create_service(
                 other_scope,
                 valid_service_attributes(%{name: "Payments API"})
               )
    end
  end

  describe "update_service/3" do
    test "updates the service" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert {:ok, %Service{} = service} =
               Monitoring.update_service(scope, service, %{
                 name: "Renamed",
                 enabled: false,
                 check_interval_ms: 120_000
               })

      assert service.name == "Renamed"
      assert service.enabled == false
      assert service.check_interval_ms == 120_000
    end

    test "returns an error changeset for invalid data and leaves the record alone" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert {:error, %Ecto.Changeset{}} =
               Monitoring.update_service(scope, service, @invalid_attrs)

      assert service == Monitoring.get_service!(scope, service.id)
    end

    test "raises when the scope does not own the service" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert_raise MatchError, fn ->
        Monitoring.update_service(other_scope, service, %{})
      end
    end
  end

  describe "delete_service/2" do
    test "deletes the service" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert {:ok, %Service{}} = Monitoring.delete_service(scope, service)
      assert_raise Ecto.NoResultsError, fn -> Monitoring.get_service!(scope, service.id) end
    end

    test "raises when the scope does not own the service" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert_raise MatchError, fn -> Monitoring.delete_service(other_scope, service) end
    end
  end

  describe "authorization" do
    test "a viewer may not create a service" do
      scope = organization_scope_fixture(:viewer)

      assert Monitoring.create_service(scope, valid_service_attributes()) ==
               {:error, :unauthorized}
    end

    test "a viewer may not update or delete a service" do
      owner_scope = organization_scope_fixture()
      service = service_fixture(owner_scope)

      viewer_scope = %{owner_scope | role: :viewer}

      assert Monitoring.update_service(viewer_scope, service, %{name: "Nope"}) ==
               {:error, :unauthorized}

      assert Monitoring.delete_service(viewer_scope, service) == {:error, :unauthorized}
      assert Monitoring.get_service!(owner_scope, service.id).name == service.name
    end

    test "a member may not manage services either" do
      scope = organization_scope_fixture(:member)

      assert Monitoring.create_service(scope, valid_service_attributes()) ==
               {:error, :unauthorized}
    end

    test "an admin may manage services" do
      scope = organization_scope_fixture(:admin)

      assert {:ok, %Service{}} = Monitoring.create_service(scope, valid_service_attributes())
    end
  end

  describe "subscribe_services/1" do
    test "delivers create, update and delete messages for the organization" do
      scope = organization_scope_fixture()
      Monitoring.subscribe_services(scope)

      service = service_fixture(scope)
      assert_receive {:created, %Service{id: id}} when id == service.id

      {:ok, updated} = Monitoring.update_service(scope, service, %{name: "Renamed"})
      assert_receive {:updated, %Service{name: "Renamed"}}

      {:ok, _deleted} = Monitoring.delete_service(scope, updated)
      assert_receive {:deleted, %Service{}}
    end

    test "does not deliver messages from another organization" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()

      Monitoring.subscribe_services(scope)
      service_fixture(other_scope)

      refute_receive {:created, _service}
    end
  end

  describe "service_metrics/3" do
    test "reports nothing for a service with no checks" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert %{total: 0, uptime_percent: nil, p50: nil, p95: nil, p99: nil} =
               Monitoring.service_metrics(scope, service)
    end

    test "computes uptime from the recorded checks" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      record(service, :healthy, 100)
      record(service, :healthy, 100)
      record(service, :degraded, 100)
      record(service, :down, nil)

      metrics = Monitoring.service_metrics(scope, service)

      assert metrics.total == 4
      # Degraded still counts as up: the service answered.
      assert metrics.up == 3
      assert metrics.down == 1
      assert_in_delta metrics.uptime_percent, 75.0, 0.001
    end

    test "computes percentiles in the database" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      for ms <- 1..100, do: record(service, :healthy, ms)

      metrics = Monitoring.service_metrics(scope, service)

      assert_in_delta metrics.p50, 50, 2
      assert_in_delta metrics.p95, 95, 2
      assert_in_delta metrics.p99, 99, 2
    end

    test "ignores checks outside the window" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      record(service, :healthy, 100)

      assert Monitoring.service_metrics(scope, service, since: minutes_from_now(5)).total == 0
    end

    test "raises for a service in another organization" do
      scope = organization_scope_fixture()
      other_scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert_raise MatchError, fn -> Monitoring.service_metrics(other_scope, service) end
    end
  end

  describe "uptime_by_service/2" do
    test "returns one entry per service, scoped to the organization" do
      scope = organization_scope_fixture()
      good = service_fixture(scope, %{name: "Good"})
      bad = service_fixture(scope, %{name: "Bad"})

      other_scope = organization_scope_fixture()
      theirs = service_fixture(other_scope)
      record(theirs, :healthy, 10)

      record(good, :healthy, 10)
      record(good, :healthy, 10)
      record(bad, :healthy, 10)
      record(bad, :down, nil)

      uptime = Monitoring.uptime_by_service(scope)

      assert_in_delta uptime[good.id], 100.0, 0.001
      assert_in_delta uptime[bad.id], 50.0, 0.001
      refute Map.has_key?(uptime, theirs.id)
    end
  end

  describe "list_checks_for_chart/3" do
    test "returns checks oldest first, so a plot reads left to right" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      record(service, :healthy, 10)
      record(service, :healthy, 20)
      record(service, :healthy, 30)

      assert [10, 20, 30] =
               scope
               |> Monitoring.list_checks_for_chart(service)
               |> Enum.map(& &1.response_time_ms)
    end
  end

  defp record(service, status, response_time_ms) do
    Monitoring.record_check(service, status, %Result{
      http_status: if(status == :down, do: nil, else: 200),
      response_time_ms: response_time_ms,
      error: if(status == :down, do: "connection refused")
    })
  end

  defp minutes_from_now(minutes), do: DateTime.add(DateTime.utc_now(), minutes * 60, :second)

  describe "rollups" do
    setup do
      scope = organization_scope_fixture()
      %{scope: scope, service: service_fixture(scope)}
    end

    # Backdates checks into a finished hour, which is the only way to exercise
    # the rollup half: the current hour is always read from raw rows.
    defp backdate(checks, hours_ago) do
      at = DateTime.add(DateTime.utc_now(), -hours_ago * 3600, :second)
      ids = Enum.map(checks, & &1.id)

      Repo.update_all(
        from(c in PulseOps.Monitoring.Check, where: c.id in ^ids),
        set: [inserted_at: at]
      )

      at
    end

    defp record_many(service, entries) do
      Enum.map(entries, fn {status, ms} ->
        {:ok, check} = record(service, status, ms)
        check
      end)
    end

    test "roll_up_hour/1 aggregates an hour into one row per service", %{service: service} do
      checks =
        record_many(service, [{:healthy, 20}, {:healthy, 80}, {:degraded, 400}, {:down, nil}])

      at = backdate(checks, 2)

      assert Monitoring.roll_up_hour(at) == 1

      rollup = Repo.one!(from r in Rollup, where: r.service_id == ^service.id)

      assert rollup.total == 4
      assert rollup.up == 3
      assert rollup.degraded == 1
      assert rollup.down == 1
      # The failed check recorded no response time, so it is not in the latency
      # figures at all.
      assert rollup.latency_count == 3
      assert rollup.latency_sum == 500
      assert rollup.latency_max == 400
      assert rollup.latency_le_25 == 1
      assert rollup.latency_le_100 == 2
      assert rollup.latency_le_500 == 3
    end

    test "roll_up_hour/1 recomputes rather than accumulating", %{service: service} do
      checks = record_many(service, [{:healthy, 20}, {:down, nil}])
      at = backdate(checks, 2)

      Monitoring.roll_up_hour(at)
      Monitoring.roll_up_hour(at)
      Monitoring.roll_up_hour(at)

      rollup = Repo.one!(from r in Rollup, where: r.service_id == ^service.id)

      assert rollup.total == 2, "a rerun must upsert, not add to what is there"
      assert Repo.aggregate(Rollup, :count) == 1
    end

    test "uptime_by_service/2 agrees with counting the raw checks", %{
      scope: scope,
      service: service
    } do
      old = record_many(service, [{:healthy, 10}, {:healthy, 10}, {:down, nil}])
      backdate(old, 3) |> Monitoring.roll_up_hour()

      # One more in the current hour, which no rollup covers yet.
      record_many(service, [{:healthy, 10}])

      # 3 up out of 4 overall.
      assert_in_delta Monitoring.uptime_by_service(scope)[service.id], 75.0, 0.001
    end

    test "uptime_by_service/2 adds the current hour to the rolled-up ones", %{
      scope: scope,
      service: service
    } do
      old = record_many(service, [{:healthy, 10}, {:healthy, 10}])
      backdate(old, 2) |> Monitoring.roll_up_hour()

      assert Monitoring.uptime_by_service(scope)[service.id] == 100.0

      # A failure now must move the figure even though it is in no rollup.
      record_many(service, [{:down, nil}, {:down, nil}])

      assert_in_delta Monitoring.uptime_by_service(scope)[service.id], 50.0, 0.001
    end

    test "service_metrics/3 merges the rolled-up histogram with the current hour", %{
      scope: scope,
      service: service
    } do
      old = record_many(service, [{:healthy, 20}, {:healthy, 30}, {:healthy, 40}])
      backdate(old, 2) |> Monitoring.roll_up_hour()

      record_many(service, [{:healthy, 20}, {:down, nil}])

      metrics = Monitoring.service_metrics(scope, service)

      assert metrics.total == 5
      assert metrics.up == 4
      assert metrics.down == 1
      assert_in_delta metrics.uptime_percent, 80.0, 0.001
      # Four measured responses, all between 20 and 40 ms, so every percentile
      # has to land inside the bucket that contains them.
      assert metrics.p50 <= 50
      assert metrics.p95 <= 50
    end

    test "service_metrics/3 is empty when nothing was recorded", %{
      scope: scope,
      service: service
    } do
      assert Monitoring.service_metrics(scope, service) == %{
               total: 0,
               up: 0,
               down: 0,
               uptime_percent: nil,
               p50: nil,
               p95: nil,
               p99: nil
             }
    end

    test "backfill_rollups/1 covers every finished hour in the range", %{service: service} do
      for hours_ago <- 1..3 do
        service |> record_many([{:healthy, 10}]) |> backdate(hours_ago)
      end

      assert Monitoring.backfill_rollups(3) == 3
      assert Repo.aggregate(Rollup, :count) == 3
    end

    test "a rollup belonging to another organization is not counted", %{
      scope: scope,
      service: service
    } do
      other = organization_scope_fixture()
      their_service = service_fixture(other)

      service |> record_many([{:healthy, 10}]) |> backdate(2)
      their_service |> record_many([{:down, nil}]) |> backdate(2)
      Monitoring.backfill_rollups(3)

      uptime = Monitoring.uptime_by_service(scope)

      assert Map.has_key?(uptime, service.id)
      refute Map.has_key?(uptime, their_service.id)
    end
  end

  describe "check request options" do
    setup do
      %{scope: organization_scope_fixture()}
    end

    defp create(scope, attrs) do
      Monitoring.create_service(scope, valid_service_attributes(attrs))
    end

    test "defaults keep an existing service probed exactly as before", %{scope: scope} do
      assert {:ok, service} = create(scope, %{})

      assert service.http_method == :get
      assert service.request_headers == %{}
      assert service.expected_status == nil
      assert service.body_assertion == nil
    end

    test "accepts a method, headers, an expected status and a body assertion", %{scope: scope} do
      assert {:ok, service} =
               create(scope, %{
                 http_method: :post,
                 request_headers: %{"authorization" => "Bearer token"},
                 request_body: ~s({"ping":true}),
                 expected_status: 204,
                 body_assertion: ~s("status":"ok")
               })

      assert service.http_method == :post
      assert service.request_headers == %{"authorization" => "Bearer token"}
      assert service.expected_status == 204
    end

    test "rejects a header carrying a line break", %{scope: scope} do
      # Header injection: a newline in either half lets a tenant append headers
      # of their own to a request PulseOps makes on their behalf.
      assert {:error, changeset} =
               create(scope, %{
                 request_headers: %{"x-probe" => "ok\r\nX-Injected: yes"}
               })

      assert "a header cannot contain a line break" in errors_on(changeset).request_headers

      assert {:error, changeset} =
               create(scope, %{request_headers: %{"x-probe\nX-Injected" => "yes"}})

      assert "a header cannot contain a line break" in errors_on(changeset).request_headers
    end

    test "rejects a header with no name", %{scope: scope} do
      assert {:error, changeset} = create(scope, %{request_headers: %{"" => "orphan"}})
      assert "every header needs a name" in errors_on(changeset).request_headers
    end

    test "drops a row where both halves are blank", %{scope: scope} do
      # An empty pair is what a form row the user never filled in looks like.
      assert {:ok, service} =
               create(scope, %{request_headers: %{"x-probe" => "yes", "" => ""}})

      assert service.request_headers == %{"x-probe" => "yes"}
    end

    test "refuses to be used as storage", %{scope: scope} do
      too_many = Map.new(1..11, fn n -> {"x-#{n}", "value"} end)

      assert {:error, changeset} = create(scope, %{request_headers: too_many})
      assert "cannot have more than 10 headers" in errors_on(changeset).request_headers

      assert {:error, changeset} =
               create(scope, %{request_headers: %{"x-probe" => String.duplicate("a", 201)}})

      assert Enum.any?(errors_on(changeset).request_headers, &(&1 =~ "under 200 characters"))
    end

    test "rejects a status outside the HTTP range", %{scope: scope} do
      assert {:error, changeset} = create(scope, %{expected_status: 99})
      assert errors_on(changeset).expected_status != []

      assert {:error, changeset} = create(scope, %{expected_status: 600})
      assert errors_on(changeset).expected_status != []
    end

    test "rejects a body assertion on a HEAD request", %{scope: scope} do
      # A HEAD response has no body by definition, so this would fail every
      # probe for a reason the form can explain now instead.
      assert {:error, changeset} =
               create(scope, %{http_method: :head, body_assertion: "ok"})

      assert Enum.any?(errors_on(changeset).body_assertion, &(&1 =~ "HEAD"))
    end

    test "allows HEAD with no body assertion", %{scope: scope} do
      assert {:ok, service} = create(scope, %{http_method: :head})
      assert service.http_method == :head
    end

    test "rejects a method that changes state on the far side", %{scope: scope} do
      assert {:error, changeset} = create(scope, %{http_method: :delete})
      assert errors_on(changeset).http_method != []
    end
  end

  describe "change_service/3" do
    test "returns a changeset" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      assert %Ecto.Changeset{} = Monitoring.change_service(scope, service)
    end
  end

  describe "prune_old_checks/1" do
    test "deletes checks older than the window and keeps recent ones" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      {:ok, recent} = record(service, :healthy, 10)
      {:ok, old} = record(service, :down, nil)

      {1, nil} =
        Repo.update_all(
          from(c in PulseOps.Monitoring.Check, where: c.id == ^old.id),
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -31, :day)]
        )

      assert Monitoring.prune_old_checks(30) == 1
      assert Repo.get(PulseOps.Monitoring.Check, old.id) == nil

      assert %PulseOps.Monitoring.Check{} =
               Repo.get(PulseOps.Monitoring.Check, recent.id)
    end

    test "deletes in bounded batches rather than one unbounded statement" do
      scope = organization_scope_fixture()
      service = service_fixture(scope)

      expired =
        for _ <- 1..25 do
          {:ok, check} = record(service, :down, nil)
          check.id
        end

      {25, nil} =
        Repo.update_all(
          from(c in PulseOps.Monitoring.Check, where: c.id in ^expired),
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -31, :day)]
        )

      {:ok, fresh} = record(service, :healthy, 10)

      {deleted, statements} =
        count_deletes(fn -> Monitoring.prune_old_checks(30, batch_size: 10) end)

      assert deleted == 25
      # 10, 10, then a short batch of 5 that says the backlog is exhausted.
      assert statements == 3

      assert %PulseOps.Monitoring.Check{} = Repo.get(PulseOps.Monitoring.Check, fresh.id)
    end
  end

  # Counts the DELETE statements issued while running fun, so "in batches" is
  # actually asserted rather than inferred from the row count.
  defp count_deletes(fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = {:retention_delete_counter, ref}

    :telemetry.attach(
      handler_id,
      [:pulse_ops, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid and String.starts_with?(metadata.query, "DELETE") do
          send(test_pid, {ref, :delete})
        end
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {result, drain_deletes(ref, 0)}
  end

  defp drain_deletes(ref, count) do
    receive do
      {^ref, :delete} -> drain_deletes(ref, count + 1)
    after
      0 -> count
    end
  end
end
