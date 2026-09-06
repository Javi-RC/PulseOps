defmodule PulseOps.Incidents do
  @moduledoc """
  Incidents open and close on their own, driven by what the monitors observe.
  People add the parts a monitor cannot know: the workflow status and the cause.

  The monitor-facing functions take a `%Service{}` rather than a scope, because
  no user is asking; the user-facing ones take a scope and filter by
  organization like every other context.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias PulseOps.Accounts.Scope
  alias PulseOps.Incidents.Incident
  alias PulseOps.Incidents.IncidentEvent
  alias PulseOps.Monitoring.Service
  alias PulseOps.Organizations
  alias PulseOps.Repo

  ## Subscriptions

  @doc """
  Subscribes to incident activity in the scoped organization.

  Messages are `{:incident_opened, incident}`, `{:incident_updated, incident}`
  and `{:incident_resolved, incident}`.
  """
  def subscribe_incidents(%Scope{} = scope) do
    Phoenix.PubSub.subscribe(PulseOps.PubSub, topic(scope.organization.id))
  end

  defp topic(organization_id), do: "organization:#{organization_id}:incidents"

  defp broadcast(organization_id, message) do
    Phoenix.PubSub.broadcast(PulseOps.PubSub, topic(organization_id), message)
  end

  ## Monitor-facing API

  @doc """
  Opens an incident for a service that has just been reported down.

  Returns `{:ok, incident}` with the existing incident if one is already open.
  The partial unique index is what actually guarantees that, so a race between
  two monitors ends with one insert and one no-op rather than a duplicate or a
  crash (ADR-004).
  """
  def open_incident(%Service{} = service, reason \\ nil) do
    attrs = %{
      service_id: service.id,
      organization_id: service.organization_id,
      title: "#{service.name} is unavailable",
      severity: severity_for(service),
      started_at: DateTime.utc_now(:second)
    }

    Multi.new()
    |> Multi.insert(:incident, Incident.open_changeset(%Incident{}, attrs))
    |> Multi.insert(:event, fn %{incident: incident} ->
      IncidentEvent.changeset(%IncidentEvent{}, %{
        incident_id: incident.id,
        type: :detected,
        description: detection_description(service, reason)
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{incident: incident}} ->
        broadcast(service.organization_id, {:incident_opened, incident})
        {:ok, incident}

      {:error, :incident, changeset, _changes} ->
        # Losing the race is the expected outcome, not a failure: somebody else
        # already opened the incident we were about to open.
        if already_open?(changeset) do
          {:ok, get_open_incident(service)}
        else
          {:error, changeset}
        end
    end
  end

  @doc """
  Resolves the open incident for a service that has recovered, if there is one.
  """
  def resolve_open_incident(%Service{} = service) do
    case get_open_incident(service) do
      nil ->
        {:ok, nil}

      incident ->
        Multi.new()
        |> Multi.update(:incident, Incident.resolve_changeset(incident, %{}))
        |> Multi.insert(:event, fn %{incident: incident} ->
          IncidentEvent.changeset(%IncidentEvent{}, %{
            incident_id: incident.id,
            type: :recovered,
            description: "#{service.name} recovered and the incident closed automatically"
          })
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{incident: incident}} ->
            broadcast(service.organization_id, {:incident_resolved, incident})
            {:ok, incident}

          {:error, :incident, changeset, _changes} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  The open incident for a service, or nil.
  """
  def get_open_incident(%Service{id: service_id}) do
    Repo.one(from i in Incident, where: i.service_id == ^service_id and is_nil(i.resolved_at))
  end

  # Production outages matter more than staging ones, and this is the only
  # signal available without alert rules, which are V2.
  defp severity_for(%Service{environment: :production}), do: :critical
  defp severity_for(%Service{environment: :staging}), do: :high
  defp severity_for(%Service{}), do: :medium

  defp detection_description(service, nil), do: "#{service.name} stopped responding"

  defp detection_description(service, reason),
    do: "#{service.name} stopped responding: #{reason}"

  defp already_open?(changeset) do
    Enum.any?(changeset.errors, fn
      {:service_id, {_message, opts}} -> opts[:constraint] == :unique
      _other -> false
    end)
  end

  ## User-facing API

  @doc """
  Incidents in the scoped organization, newest first.
  """
  def list_incidents(%Scope{} = scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    scope
    |> incidents_query()
    |> order_by([i], desc: i.started_at)
    |> limit(^limit)
    |> preload(:service)
    |> Repo.all()
  end

  @doc """
  The unresolved incidents in the scoped organization, most severe first.
  """
  def list_active_incidents(%Scope{} = scope) do
    scope
    |> incidents_query()
    |> where([i], is_nil(i.resolved_at))
    |> order_by([i], desc: i.started_at)
    |> preload(:service)
    |> Repo.all()
  end

  @doc """
  Counts unresolved incidents in the scoped organization.
  """
  def count_active_incidents(%Scope{} = scope) do
    scope
    |> incidents_query()
    |> where([i], is_nil(i.resolved_at))
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets an incident belonging to the scoped organization, with its timeline.
  """
  def get_incident!(%Scope{} = scope, id) do
    scope
    |> incidents_query()
    |> where([i], i.id == ^id)
    |> preload([:service, :resolved_by, events: :user])
    |> Repo.one!()
  end

  defp incidents_query(%Scope{} = scope) do
    from i in Incident, where: i.organization_id == ^scope.organization.id
  end

  @doc """
  Moves an incident through the workflow and optionally records the cause.
  """
  def update_incident(%Scope{} = scope, %Incident{} = incident, attrs) do
    true = incident.organization_id == scope.organization.id

    with :ok <- Organizations.authorize(scope, :respond_to_incidents),
         :ok <- ensure_open(incident) do
      Multi.new()
      |> Multi.update(:incident, Incident.workflow_changeset(incident, attrs))
      |> Multi.insert(:event, fn %{incident: updated} ->
        IncidentEvent.changeset(%IncidentEvent{}, %{
          incident_id: updated.id,
          user_id: scope.user.id,
          type: :status_changed,
          description: "Status changed to #{updated.status}"
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{incident: updated}} ->
          broadcast(scope.organization.id, {:incident_updated, updated})
          {:ok, updated}

        {:error, :incident, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Resolves an incident by hand, recording who did it.
  """
  def resolve_incident(%Scope{} = scope, %Incident{} = incident, attrs \\ %{}) do
    true = incident.organization_id == scope.organization.id

    with :ok <- Organizations.authorize(scope, :respond_to_incidents),
         :ok <- ensure_open(incident) do
      attrs = Map.put(attrs, :resolved_by_id, scope.user.id)

      Multi.new()
      |> Multi.update(:incident, Incident.resolve_changeset(incident, attrs))
      |> Multi.insert(:event, fn %{incident: updated} ->
        IncidentEvent.changeset(%IncidentEvent{}, %{
          incident_id: updated.id,
          user_id: scope.user.id,
          type: :resolved,
          description: "Incident resolved"
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{incident: updated}} ->
          broadcast(scope.organization.id, {:incident_resolved, updated})
          {:ok, updated}

        {:error, :incident, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Adds a note to an incident's timeline.
  """
  def add_note(%Scope{} = scope, %Incident{} = incident, description) do
    true = incident.organization_id == scope.organization.id

    with :ok <- Organizations.authorize(scope, :respond_to_incidents) do
      %IncidentEvent{}
      |> IncidentEvent.changeset(%{
        incident_id: incident.id,
        user_id: scope.user.id,
        type: :note,
        description: description
      })
      |> Repo.insert()
      |> case do
        {:ok, event} ->
          broadcast(scope.organization.id, {:incident_updated, incident})
          {:ok, event}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Changeset for incident workflow forms.
  """
  def change_incident(%Incident{} = incident, attrs \\ %{}) do
    Incident.workflow_changeset(incident, attrs)
  end

  defp ensure_open(%Incident{resolved_at: nil}), do: :ok
  defp ensure_open(%Incident{}), do: {:error, :already_resolved}
end
