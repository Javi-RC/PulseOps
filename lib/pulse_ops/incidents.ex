defmodule PulseOps.Incidents do
  @moduledoc """
  Incidents open and close on their own, driven by what the monitors observe.
  People add the parts a monitor cannot know: the workflow status and the cause.

  The monitor-facing functions take a `%Service{}` rather than a scope, because
  no user is asking; the user-facing ones take a scope and filter by
  organization like every other context.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ecto.Multi
  alias PulseOps.Accounts.Scope
  alias PulseOps.Incidents.Incident
  alias PulseOps.Incidents.IncidentEvent
  alias PulseOps.Maintenance
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Monitoring.Service
  alias PulseOps.Notifications
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

  The alert rule decides the severity. Returns `{:ok, incident}` with the
  existing incident if one is already open. The partial unique index is what
  actually guarantees that, so a race between two monitors ends with one insert
  and one no-op rather than a duplicate or a crash (ADR-004).

  Returns `{:ok, :suppressed}` when the service is inside a maintenance window:
  the probe still happened and was still recorded, but nobody is paged for a
  deploy somebody scheduled.
  """
  def open_incident(%Service{} = service, %AlertRule{} = rule, reason \\ nil) do
    insert_incident(service, rule, :detected, detection_description(service, reason))
  end

  @doc """
  Brings the incident state back in line with the status the monitor is
  currently observing, when no transition has fired.

  Incidents open and close on a status *transition*, which leaves a hole: a
  service that is already `:down` never transitions again, so if its incident
  disappears — most obviously because a person resolved it by hand — the outage
  carries on with nothing attached to it and nobody told. Monitors reconciled
  only at boot (ADR-008), so in production that hole did not close until a
  redeploy. Reconciling after every probe closes it continuously (ADR-009).

  Resolving an open incident on a service that has not recovered is read as
  "snooze this outage": for `:incident_reopen_grace_seconds` afterwards this
  returns `{:ok, :suppressed}` rather than immediately undoing what the person
  did. Only this path is suppressed — a genuine transition back to `:down`
  always opens an incident.
  """
  @spec reconcile_incident(Service.t(), atom(), AlertRule.t()) ::
          {:ok, :unchanged | :suppressed | Incident.t() | nil} | {:error, term()}
  # `:suppressed` covers both reasons an incident may not open: a manual
  # resolution still inside its grace period, and a maintenance window.
  def reconcile_incident(service, status, rule)

  def reconcile_incident(%Service{} = service, :down, %AlertRule{} = rule) do
    cond do
      get_open_incident(service) ->
        {:ok, :unchanged}

      recently_resolved_by_hand?(service) ->
        {:ok, :suppressed}

      true ->
        insert_incident(service, rule, :reopened, reopen_description(service))
    end
  end

  def reconcile_incident(%Service{} = service, status, %AlertRule{})
      when status in [:healthy, :degraded] do
    resolve_open_incident(service)
  end

  # Nothing has been observed yet, so there is nothing to reconcile against.
  def reconcile_incident(%Service{}, :unknown, %AlertRule{}), do: {:ok, :unchanged}

  defp insert_incident(%Service{} = service, %AlertRule{} = rule, event_type, description) do
    if Maintenance.under_maintenance?(service) do
      # Both paths into an incident come through here — the transition hook and
      # reconciliation — so this is the one place suppression has to live. The
      # check is only made when an incident is about to open, which is rare;
      # a probe that changes nothing never asks.
      #
      # Nothing schedules the un-suppression: when the window ends with the
      # service still down, the next probe reconciles and opens an incident
      # then (ADR-009).
      {:ok, :suppressed}
    else
      do_insert_incident(service, rule, event_type, description)
    end
  end

  defp do_insert_incident(%Service{} = service, %AlertRule{} = rule, event_type, description) do
    attrs = %{
      service_id: service.id,
      organization_id: service.organization_id,
      title: "#{service.name} is unavailable",
      severity: rule.severity,
      started_at: DateTime.utc_now(:second)
    }

    Multi.new()
    |> Multi.insert(:incident, Incident.open_changeset(%Incident{}, attrs))
    |> Multi.insert(:event, fn %{incident: incident} ->
      IncidentEvent.changeset(%IncidentEvent{}, %{
        incident_id: incident.id,
        type: event_type,
        description: description
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{incident: incident}} ->
        Logger.info("incident opened",
          incident_id: incident.id,
          service_id: service.id,
          organization_id: service.organization_id
        )

        broadcast(service.organization_id, {:incident_opened, incident})
        Notifications.enqueue_incident_notifications(service.organization_id, incident, :opened)
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

  # A person resolved an incident for this service moments ago. `resolved_by_id`
  # is what separates that from the monitor closing one itself, which must never
  # suppress anything.
  defp recently_resolved_by_hand?(%Service{id: service_id}) do
    case grace_seconds() do
      grace when grace <= 0 ->
        false

      grace ->
        cutoff = DateTime.add(DateTime.utc_now(:second), -grace, :second)

        Repo.exists?(
          from i in Incident,
            where: i.service_id == ^service_id,
            where: not is_nil(i.resolved_by_id),
            where: i.resolved_at > ^cutoff
        )
    end
  end

  defp grace_seconds do
    Application.get_env(:pulse_ops, :incident_reopen_grace_seconds, 300)
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
            Logger.info("incident resolved automatically",
              incident_id: incident.id,
              service_id: service.id,
              organization_id: service.organization_id
            )

            broadcast(service.organization_id, {:incident_resolved, incident})

            Notifications.enqueue_incident_notifications(
              service.organization_id,
              incident,
              :resolved
            )

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

  defp detection_description(service, nil), do: "#{service.name} stopped responding"

  defp detection_description(service, reason),
    do: "#{service.name} stopped responding: #{reason}"

  defp reopen_description(service),
    do: "#{service.name} is still down, so a new incident was opened"

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
    |> preload([:service, :resolved_by, :acknowledged_by, events: :user])
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
      changeset =
        incident
        |> Incident.resolve_changeset(attrs)
        |> Incident.put_resolver(scope.user.id)

      Multi.new()
      |> Multi.update(:incident, changeset)
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
          Notifications.enqueue_incident_notifications(scope.organization.id, updated, :resolved)
          {:ok, updated}

        {:error, :incident, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Whether a service is oscillating rather than simply broken.

  Counts the incidents it has opened inside the flap window. A service that
  crosses its threshold repeatedly opens and closes an incident each time, so
  the count of *openings* is the flap signal — no extra bookkeeping, and it
  measures the thing people actually receive.
  """
  @spec flapping?(Service.t(), DateTime.t()) :: boolean()
  def flapping?(service, now \\ DateTime.utc_now())

  def flapping?(%Service{id: service_id}, now) do
    threshold = Notifications.flap_threshold()
    since = DateTime.add(now, -Notifications.flap_window_seconds(), :second)

    count =
      Repo.aggregate(
        from(i in Incident, where: i.service_id == ^service_id and i.started_at >= ^since),
        :count
      )

    count >= threshold
  end

  @doc """
  Marks an incident as being looked at, which stops it escalating.

  Deliberately not a workflow status. Moving an incident to `:investigating`
  says something about the incident; acknowledging says something about the
  people — somebody has this. In the first minute of an outage both are true and
  neither implies the other.
  """
  @spec acknowledge_incident(Scope.t(), Incident.t()) ::
          {:ok, Incident.t()} | {:error, :unauthorized | :already_resolved | Ecto.Changeset.t()}
  def acknowledge_incident(%Scope{} = scope, %Incident{} = incident) do
    true = incident.organization_id == scope.organization.id

    with :ok <- Organizations.authorize(scope, :respond_to_incidents),
         :ok <- ensure_open(incident) do
      Multi.new()
      |> Multi.update(
        :incident,
        Ecto.Changeset.change(incident,
          acknowledged_at: DateTime.utc_now(:second),
          acknowledged_by_id: scope.user.id
        )
      )
      |> Multi.insert(:event, fn %{incident: updated} ->
        IncidentEvent.changeset(%IncidentEvent{}, %{
          incident_id: updated.id,
          user_id: scope.user.id,
          type: :acknowledged,
          description: "Acknowledged"
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
  Whether an incident is still waiting for somebody to pick it up.
  """
  @spec unacknowledged?(Incident.t()) :: boolean()
  def unacknowledged?(%Incident{acknowledged_at: nil, resolved_at: nil}), do: true
  def unacknowledged?(%Incident{}), do: false

  @doc """
  Writes an escalation onto the timeline, so the record shows that nobody picked
  the incident up rather than only that somebody eventually did.
  """
  @spec record_escalation(Incident.t()) :: :ok
  def record_escalation(%Incident{} = incident) do
    %IncidentEvent{}
    |> IncidentEvent.changeset(%{
      incident_id: incident.id,
      type: :escalated,
      description: "No acknowledgement, so the escalation channels were told"
    })
    |> Repo.insert()

    broadcast(incident.organization_id, {:incident_updated, incident})
    :ok
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
