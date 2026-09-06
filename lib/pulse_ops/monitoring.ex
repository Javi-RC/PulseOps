defmodule PulseOps.Monitoring do
  @moduledoc """
  The Monitoring context.
  """

  import Ecto.Query, warn: false

  alias PulseOps.Accounts.Scope
  alias PulseOps.Monitoring.Check
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.MonitorSupervisor
  alias PulseOps.Monitoring.Service
  alias PulseOps.Organizations
  alias PulseOps.Repo

  @doc """
  Subscribes to scoped notifications about any service changes.

  The broadcasted messages match the pattern:

    * {:created, %Service{}}
    * {:updated, %Service{}}
    * {:deleted, %Service{}}

  """
  def subscribe_services(%Scope{} = scope) do
    key = scope.organization.id

    Phoenix.PubSub.subscribe(PulseOps.PubSub, "organization:#{key}:services")
  end

  defp broadcast_service(%Scope{} = scope, message) do
    key = scope.organization.id

    Phoenix.PubSub.broadcast(PulseOps.PubSub, "organization:#{key}:services", message)
  end

  @doc """
  Returns the list of services.

  ## Examples

      iex> list_services(scope)
      [%Service{}, ...]

  """
  def list_services(%Scope{} = scope) do
    Repo.all_by(Service, organization_id: scope.organization.id)
  end

  @doc """
  Gets a single service.

  Raises `Ecto.NoResultsError` if the Service does not exist.

  ## Examples

      iex> get_service!(scope, 123)
      %Service{}

      iex> get_service!(scope, 456)
      ** (Ecto.NoResultsError)

  """
  def get_service!(%Scope{} = scope, id) do
    Repo.get_by!(Service, id: id, organization_id: scope.organization.id)
  end

  @doc """
  Creates a service.

  ## Examples

      iex> create_service(scope, %{field: value})
      {:ok, %Service{}}

      iex> create_service(scope, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_service(%Scope{} = scope, attrs) do
    with :ok <- Organizations.authorize(scope, :manage_services),
         {:ok, service = %Service{}} <-
           %Service{}
           |> Service.changeset(attrs, scope)
           |> Repo.insert() do
      MonitorSupervisor.start_monitor(service)
      broadcast_service(scope, {:created, service})
      {:ok, service}
    end
  end

  @doc """
  Updates a service.

  ## Examples

      iex> update_service(scope, service, %{field: new_value})
      {:ok, %Service{}}

      iex> update_service(scope, service, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_service(%Scope{} = scope, %Service{} = service, attrs) do
    true = service.organization_id == scope.organization.id

    with :ok <- Organizations.authorize(scope, :manage_services),
         {:ok, service = %Service{}} <-
           service
           |> Service.changeset(attrs, scope)
           |> Repo.update() do
      # Restarted rather than notified: url, interval and timeout are read once
      # when the monitor starts, and a fresh process is simpler than reconciling
      # a change mid-flight.
      MonitorSupervisor.restart_monitor(service)
      broadcast_service(scope, {:updated, service})
      {:ok, service}
    end
  end

  @doc """
  Deletes a service.

  ## Examples

      iex> delete_service(scope, service)
      {:ok, %Service{}}

      iex> delete_service(scope, service)
      {:error, %Ecto.Changeset{}}

  """
  def delete_service(%Scope{} = scope, %Service{} = service) do
    true = service.organization_id == scope.organization.id

    with :ok <- Organizations.authorize(scope, :manage_services),
         {:ok, service = %Service{}} <- Repo.delete(service) do
      MonitorSupervisor.stop_monitor(service.id)
      broadcast_service(scope, {:deleted, service})
      {:ok, service}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking service changes.

  ## Examples

      iex> change_service(scope, service)
      %Ecto.Changeset{data: %Service{}}

  """
  def change_service(%Scope{} = scope, %Service{} = service, attrs \\ %{}) do
    true = service.organization_id == scope.organization.id

    Service.changeset(service, attrs, scope)
  end

  ## Monitor-facing API
  #
  # These are called by ServiceMonitor processes, which act on behalf of the
  # system rather than a user. They take a %Service{} instead of a scope: the
  # service already carries the organization it belongs to, and there is no
  # caller whose permissions could be checked.

  @doc """
  Every enabled service across all organizations, for the bootstrapper.
  """
  def list_enabled_services do
    Repo.all(from s in Service, where: s.enabled == true)
  end

  @doc """
  Records the outcome of one probe and publishes it on the service's own topic.
  """
  def record_check(%Service{} = service, status, %Result{} = result) do
    {:ok, check} =
      %Check{}
      |> Check.changeset(%{
        service_id: service.id,
        status: status,
        http_status: result.http_status,
        response_time_ms: result.response_time_ms,
        error: result.error
      })
      |> Repo.insert()

    # Individual checks go only to the service's own topic. The dashboard would
    # be re-rendering constantly if every probe reached it (ADR-003).
    Phoenix.PubSub.broadcast(
      PulseOps.PubSub,
      "service:#{service.id}:checks",
      {:check_recorded, check}
    )

    check
  end

  @doc """
  Subscribes to the individual check results of one service.
  """
  def subscribe_checks(%Scope{} = scope, %Service{} = service) do
    true = service.organization_id == scope.organization.id

    Phoenix.PubSub.subscribe(PulseOps.PubSub, "service:#{service.id}:checks")
  end

  @doc """
  Writes a new status for the service and announces it to the organization.

  Only called when the status actually changed; see `ServiceMonitor`.
  """
  def update_service_status(%Service{} = service, status) do
    {:ok, service} =
      service
      |> Service.status_changeset(%{status: status, last_checked_at: DateTime.utc_now(:second)})
      |> Repo.update()

    Phoenix.PubSub.broadcast(
      PulseOps.PubSub,
      "organization:#{service.organization_id}:services",
      {:updated, service}
    )

    service
  end

  @doc """
  The most recent checks for a service, newest first.
  """
  def list_recent_checks(%Scope{} = scope, %Service{} = service, limit \\ 100) do
    true = service.organization_id == scope.organization.id

    Repo.all(
      from c in Check,
        where: c.service_id == ^service.id,
        order_by: [desc: c.inserted_at],
        limit: ^limit
    )
  end

  @doc """
  The most recent checks in chronological order, for plotting.
  """
  def list_checks_for_chart(%Scope{} = scope, %Service{} = service, limit \\ 60) do
    scope
    |> list_recent_checks(service, limit)
    |> Enum.reverse()
  end

  @doc """
  Availability and latency for a service over a window, aggregated in the
  database.

  Loading every check into the VM to compute a percentile would stop working at
  exactly the point the numbers start being interesting.
  """
  def service_metrics(%Scope{} = scope, %Service{} = service, opts \\ []) do
    true = service.organization_id == scope.organization.id

    since = Keyword.get_lazy(opts, :since, fn -> hours_ago(24) end)

    query =
      from c in Check,
        where: c.service_id == ^service.id and c.inserted_at >= ^since,
        select: %{
          total: count(c.id),
          up: fragment("count(*) FILTER (WHERE ? <> 'down')", c.status),
          down: fragment("count(*) FILTER (WHERE ? = 'down')", c.status),
          p50: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", c.response_time_ms),
          p95: fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", c.response_time_ms),
          p99: fragment("percentile_cont(0.99) WITHIN GROUP (ORDER BY ?)", c.response_time_ms)
        }

    query |> Repo.one() |> to_metrics()
  end

  @doc """
  The most recent checks for every service in the organization, oldest first,
  as a map of service id to its checks.

  One query with a window function rather than one query per service: the
  dashboard shows a history strip for each of them, and fanning out would make
  the page cost grow with the number of services being monitored.
  """
  def recent_checks_by_service(%Scope{} = scope, limit \\ 24) do
    ranked =
      from c in Check,
        join: s in Service,
        on: s.id == c.service_id,
        where: s.organization_id == ^scope.organization.id,
        select: %{
          service_id: c.service_id,
          status: c.status,
          response_time_ms: c.response_time_ms,
          inserted_at: c.inserted_at,
          row_number:
            over(row_number(), partition_by: c.service_id, order_by: [desc: c.inserted_at])
        }

    from(r in subquery(ranked), where: r.row_number <= ^limit)
    |> Repo.all()
    |> Enum.group_by(& &1.service_id)
    |> Map.new(fn {service_id, checks} ->
      {service_id, Enum.sort_by(checks, & &1.inserted_at, DateTime)}
    end)
  end

  @doc """
  Availability for every service in the organization over a window, as a map of
  service id to uptime percentage.

  One query rather than one per service, so the dashboard does not fan out.
  """
  def uptime_by_service(%Scope{} = scope, opts \\ []) do
    since = Keyword.get_lazy(opts, :since, fn -> hours_ago(24) end)

    from(c in Check,
      join: s in Service,
      on: s.id == c.service_id,
      where: s.organization_id == ^scope.organization.id and c.inserted_at >= ^since,
      group_by: c.service_id,
      select:
        {c.service_id,
         fragment("count(*) FILTER (WHERE ? <> 'down')::float / count(*)::float", c.status)}
    )
    |> Repo.all()
    |> Map.new(fn {service_id, ratio} -> {service_id, ratio * 100} end)
  end

  defp to_metrics(nil), do: empty_metrics()
  defp to_metrics(%{total: 0}), do: empty_metrics()

  defp to_metrics(row) do
    %{
      total: row.total,
      up: row.up,
      down: row.down,
      uptime_percent: row.up / row.total * 100,
      p50: round_ms(row.p50),
      p95: round_ms(row.p95),
      p99: round_ms(row.p99)
    }
  end

  defp empty_metrics do
    %{total: 0, up: 0, down: 0, uptime_percent: nil, p50: nil, p95: nil, p99: nil}
  end

  defp round_ms(nil), do: nil
  defp round_ms(value), do: round(value)

  defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
end
