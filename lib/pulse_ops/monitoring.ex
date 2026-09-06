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
end
