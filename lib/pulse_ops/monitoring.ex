defmodule PulseOps.Monitoring do
  @moduledoc """
  The Monitoring context.
  """

  import Ecto.Query, warn: false

  alias PulseOps.Accounts.Scope
  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Monitoring.Check
  alias PulseOps.Monitoring.HealthCheck.Result
  alias PulseOps.Monitoring.MonitorSupervisor
  alias PulseOps.Monitoring.Rollup
  alias PulseOps.Monitoring.Service
  alias PulseOps.Monitoring.ServiceMonitor
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

  Returns `{:ok, check}` once the probe is stored. A probe that lands after the
  service row is gone — a delete racing an in-flight request, or a test sandbox
  rolling a service back — cannot be stored because the foreign key has no
  target, so this returns `{:error, :service_not_found}` instead. The caller's
  monitor stops on that, rather than crashing and getting restarted into a loop.
  """
  def record_check(%Service{} = service, status, %Result{} = result) do
    changeset =
      %Check{}
      |> Check.changeset(%{
        service_id: service.id,
        status: status,
        http_status: result.http_status,
        response_time_ms: result.response_time_ms,
        error: result.error
      })

    case Repo.insert(changeset) do
      {:ok, check} ->
        # Individual checks go only to the service's own topic. The dashboard
        # would be re-rendering constantly if every probe reached it (ADR-003).
        Phoenix.PubSub.broadcast(
          PulseOps.PubSub,
          "service:#{service.id}:checks",
          {:check_recorded, check}
        )

        {:ok, check}

      {:error, changeset} ->
        if service_gone?(changeset) do
          {:error, :service_not_found}
        else
          {:error, changeset}
        end
    end
  end

  defp service_gone?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint] == :foreign
    end)
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
  Deletes `service_checks` older than `days` days, in batches.

  Returns the number of deleted rows.

  One unbounded `DELETE` over the fastest-growing table in the schema holds row
  locks and grows the transaction for as long as it runs, and how long that is
  depends on the retention window — a config change could make the nightly job
  sit on the table for minutes. Deleting a bounded number of rows at a time
  keeps each statement short whatever the backlog looks like.
  """
  @spec prune_old_checks(pos_integer(), [{:batch_size, pos_integer()}]) :: non_neg_integer()
  def prune_old_checks(days, opts \\ []) when is_integer(days) and days > 0 do
    batch_size = Keyword.get(opts, :batch_size, 10_000)
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    delete_expired(cutoff, batch_size, 0)
  end

  defp delete_expired(cutoff, batch_size, deleted) do
    # Postgres has no LIMIT on DELETE, so the batch is chosen by a subquery.
    # Selecting ids keeps that lookup on the inserted_at index.
    batch =
      from c in Check,
        where: c.inserted_at < ^cutoff,
        select: c.id,
        limit: ^batch_size

    {count, _} = Repo.delete_all(from c in Check, where: c.id in subquery(batch))

    # A short batch means the backlog is exhausted; anything else would be one
    # more round trip to learn the same thing.
    if count < batch_size do
      deleted + count
    else
      delete_expired(cutoff, batch_size, deleted + count)
    end
  end

  @doc """
  Availability and latency for a service over a window, aggregated in the
  database.

  Loading every check into the VM to compute a percentile would stop working at
  exactly the point the numbers start being interesting.
  """
  def service_metrics(%Scope{} = scope, %Service{} = service, opts \\ []) do
    true = service.organization_id == scope.organization.id

    {since, cutover, live_from} = rollup_window(opts)

    rolled =
      from(r in Rollup,
        where: r.service_id == ^service.id,
        where: r.bucket_start >= ^since and r.bucket_start < ^cutover,
        select: %{
          total: sum(r.total),
          up: sum(r.up),
          down: sum(r.down),
          latency_count: sum(r.latency_count),
          latency_max: max(r.latency_max),
          le_25: sum(r.latency_le_25),
          le_50: sum(r.latency_le_50),
          le_100: sum(r.latency_le_100),
          le_250: sum(r.latency_le_250),
          le_500: sum(r.latency_le_500),
          le_1000: sum(r.latency_le_1000),
          le_2500: sum(r.latency_le_2500),
          le_5000: sum(r.latency_le_5000)
        }
      )
      |> Repo.one()

    live =
      from(c in Check,
        where: c.service_id == ^service.id and c.inserted_at >= ^live_from,
        select: %{
          total: count(c.id),
          up: fragment("count(*) FILTER (WHERE ? <> 'down')", c.status),
          down: fragment("count(*) FILTER (WHERE ? = 'down')", c.status),
          latency_count: fragment("count(?)", c.response_time_ms),
          latency_max: max(c.response_time_ms),
          le_25: fragment("count(*) FILTER (WHERE ? <= 25)", c.response_time_ms),
          le_50: fragment("count(*) FILTER (WHERE ? <= 50)", c.response_time_ms),
          le_100: fragment("count(*) FILTER (WHERE ? <= 100)", c.response_time_ms),
          le_250: fragment("count(*) FILTER (WHERE ? <= 250)", c.response_time_ms),
          le_500: fragment("count(*) FILTER (WHERE ? <= 500)", c.response_time_ms),
          le_1000: fragment("count(*) FILTER (WHERE ? <= 1000)", c.response_time_ms),
          le_2500: fragment("count(*) FILTER (WHERE ? <= 2500)", c.response_time_ms),
          le_5000: fragment("count(*) FILTER (WHERE ? <= 5000)", c.response_time_ms)
        }
      )
      |> Repo.one()

    rolled |> merge_metric_rows(live) |> to_metrics()
  end

  # Rollup sums come back nil when no hour matched, and the two halves are
  # simply added: every count in a rollup, the histogram included, is additive.
  # That is the property the histogram was chosen for.
  defp merge_metric_rows(rolled, live) do
    Map.new(
      [
        :total,
        :up,
        :down,
        :latency_count,
        :le_25,
        :le_50,
        :le_100,
        :le_250,
        :le_500,
        :le_1000,
        :le_2500,
        :le_5000
      ],
      fn key -> {key, value(rolled, key) + value(live, key)} end
    )
    |> Map.put(
      :latency_max,
      max_of(value(rolled, :latency_max, nil), value(live, :latency_max, nil))
    )
  end

  defp value(row, key), do: value(row, key, 0)
  defp value(nil, _key, default), do: default
  defp value(row, key, default), do: Map.get(row, key) || default

  defp max_of(nil, other), do: other
  defp max_of(one, nil), do: one
  defp max_of(one, other), do: max(one, other)

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
    {since, cutover, live_from} = rollup_window(opts)
    organization_id = scope.organization.id

    rolled =
      from(r in Rollup,
        join: s in Service,
        on: s.id == r.service_id,
        where: s.organization_id == ^organization_id,
        where: r.bucket_start >= ^since and r.bucket_start < ^cutover,
        group_by: r.service_id,
        select: {r.service_id, %{total: sum(r.total), up: sum(r.up)}}
      )
      |> Repo.all()
      |> Map.new()

    live =
      from(c in Check,
        join: s in Service,
        on: s.id == c.service_id,
        where: s.organization_id == ^organization_id,
        where: c.inserted_at >= ^live_from,
        group_by: c.service_id,
        select:
          {c.service_id,
           %{
             total: count(c.id),
             up: fragment("count(*) FILTER (WHERE ? <> 'down')", c.status)
           }}
      )
      |> Repo.all()
      |> Map.new()

    rolled
    |> Map.merge(live, fn _service_id, a, b ->
      %{total: a.total + b.total, up: a.up + b.up}
    end)
    |> Map.reject(fn {_service_id, %{total: total}} -> total == 0 end)
    |> Map.new(fn {service_id, %{total: total, up: up}} -> {service_id, up / total * 100} end)
  end

  ## Monitor health

  @doc """
  Whether anything is actually watching a service.

    * `:running` — a monitor process exists for it.
    * `:stopped` — it is enabled and nothing is watching it. In practice that is
      a monitor that crashed too often inside its supervisor's restart window
      and was given up on. Giving up is the right call for fault isolation, and
      until now it was invisible: the service went on showing its last recorded
      status as though it were current.
    * `:disabled` — monitoring was switched off on purpose.
    * `:not_applicable` — monitors do not run in this environment at all (the
      test suite, ADR-005), so their absence says nothing.

  Reads the local registry, so on a second node it would only answer for that
  node — one more reason the deployment is single-node (see "Deployment shape"
  in `ARCHITECTURE.md`).
  """
  @spec monitor_state(Service.t()) :: :running | :stopped | :disabled | :not_applicable
  def monitor_state(%Service{enabled: false}), do: :disabled

  def monitor_state(%Service{id: id}) do
    cond do
      not MonitorSupervisor.enabled?() -> :not_applicable
      MonitorSupervisor.watching?(id) -> :running
      true -> :stopped
    end
  end

  ## TLS certificates

  @doc """
  Every enabled service whose certificate is worth looking at.

  Only https ones: there is no certificate behind an http URL, and asking would
  produce an error a person would have to learn to ignore.
  """
  @spec list_services_for_tls_check() :: [Service.t()]
  def list_services_for_tls_check do
    Repo.all(
      from s in Service,
        where: s.enabled == true and ilike(s.url, "https://%"),
        order_by: [asc: s.id]
    )
  end

  @doc """
  Records what a certificate check found.

  A new expiry clears `tls_warned_for`, which is what makes a renewed
  certificate able to warn again later — the field records *which* expiry was
  warned about, not merely that a warning happened.
  """
  @spec record_tls_check(Service.t(), {:ok, map()} | {:error, String.t()}) ::
          {:ok, Service.t()} | {:error, Ecto.Changeset.t()}
  def record_tls_check(%Service{} = service, {:ok, %{expires_at: expires_at}}) do
    changes = [
      tls_expires_at: expires_at,
      tls_checked_at: DateTime.utc_now(:second),
      tls_error: nil
    ]

    changes =
      if service.tls_expires_at && DateTime.compare(service.tls_expires_at, expires_at) == :eq do
        changes
      else
        Keyword.put(changes, :tls_warned_for, nil)
      end

    service |> Ecto.Changeset.change(changes) |> Repo.update()
  end

  def record_tls_check(%Service{} = service, {:error, reason}) do
    service
    |> Ecto.Changeset.change(
      tls_checked_at: DateTime.utc_now(:second),
      tls_error: String.slice(to_string(reason), 0, 255)
    )
    |> Repo.update()
  end

  @doc """
  Marks that the service's current expiry has been warned about.
  """
  @spec mark_tls_warned(Service.t()) :: {:ok, Service.t()} | {:error, Ecto.Changeset.t()}
  def mark_tls_warned(%Service{tls_expires_at: expires_at} = service) do
    service |> Ecto.Changeset.change(tls_warned_for: expires_at) |> Repo.update()
  end

  @doc """
  How many days are left on a service's certificate, or nil.
  """
  @spec tls_days_left(Service.t(), DateTime.t()) :: integer() | nil
  def tls_days_left(service, now \\ DateTime.utc_now())

  def tls_days_left(%Service{tls_expires_at: nil}, _now), do: nil

  def tls_days_left(%Service{tls_expires_at: expires_at}, now),
    do: DateTime.diff(expires_at, now, :day)

  @doc """
  Whether a service's certificate is close enough to expiry to say so.
  """
  @spec tls_expiring?(Service.t(), DateTime.t()) :: boolean()
  def tls_expiring?(service, now \\ DateTime.utc_now())

  def tls_expiring?(%Service{tls_expires_at: nil}, _now), do: false

  def tls_expiring?(%Service{} = service, now),
    do: tls_days_left(service, now) <= tls_warn_days()

  @doc """
  How many days ahead a certificate expiry is worth warning about.
  """
  @spec tls_warn_days() :: pos_integer()
  def tls_warn_days do
    :pulse_ops |> Application.get_env(:tls, []) |> Keyword.get(:warn_days, 21)
  end

  ## Alert rules

  @doc """
  All alert rules in the scoped organization, those scoped to a specific service
  first.
  """
  def list_alert_rules(%Scope{} = scope) do
    from(r in AlertRule, where: r.organization_id == ^scope.organization.id)
    |> order_by([r], asc: is_nil(r.service_id), asc: r.id)
    |> preload(:service)
    |> Repo.all()
  end

  @doc """
  The alert rule for a given service in the scoped organization, or nil.

  Resolution prefers the service's own rule and falls back to the organization
  default. `nil` means the caller should use `AlertRule.default/0`.
  """
  def get_rule_for_service(%Scope{} = scope, %Service{id: service_id}) do
    from(r in AlertRule,
      where: r.organization_id == ^scope.organization.id,
      where: r.service_id == ^service_id or is_nil(r.service_id),
      # A service's own rule wins over the organization default. The id breaks
      # the tie so the answer cannot depend on the planner.
      order_by: [asc: is_nil(r.service_id), asc: r.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Creates an alert rule for the scoped organization, optionally bound to a single
  service. A nil `service_id` makes it the organization default.
  """
  def create_alert_rule(%Scope{} = scope, attrs \\ %{}) do
    with :ok <- Organizations.authorize(scope, :manage_organization),
         {:ok, rule = %AlertRule{}} <-
           %AlertRule{}
           |> AlertRule.changeset(attrs, scope)
           |> Repo.insert() do
      notify_rule_change(scope, rule)
      {:ok, rule}
    end
  end

  @doc """
  Updates an alert rule belonging to the scoped organization.
  """
  def update_alert_rule(%Scope{} = scope, %AlertRule{} = rule, attrs) do
    true = rule.organization_id == scope.organization.id
    previous_rule = rule

    with :ok <- Organizations.authorize(scope, :manage_organization),
         {:ok, rule = %AlertRule{}} <-
           rule
           |> AlertRule.changeset(attrs, scope)
           |> Repo.update() do
      notify_rule_change(scope, previous_rule, rule)
      {:ok, rule}
    end
  end

  @doc """
  Deletes an alert rule belonging to the scoped organization. Deleting a rule
  restores the hardcoded defaults for that service.
  """
  def delete_alert_rule(%Scope{} = scope, %AlertRule{} = rule) do
    true = rule.organization_id == scope.organization.id

    with :ok <- Organizations.authorize(scope, :manage_organization),
         {:ok, rule = %AlertRule{}} <- Repo.delete(rule) do
      notify_rule_change(scope, rule)
      {:ok, rule}
    end
  end

  @doc """
  Tells the monitors whose rule changed to re-read it.

  A monitor reads its alert rule at boot, so a change has to reach the running
  process somehow. It used to be a restart — stop, wait for the registry to
  release the name, boot a replacement — done once per affected service, in
  sequence, from whichever process saved the rule. For an organization-wide
  rule that is O(number of services) of blocking work in a LiveView, and at a
  few hundred services it is unusable.

  Each monitor is now sent a cast and re-reads its own rule in its own process,
  so nothing waits on anything else and the caller returns immediately.
  """
  def notify_rule_change(%Scope{} = scope, %AlertRule{} = rule) do
    notify_rule_change(scope, rule, rule)
  end

  # An update can move a rule between a service and the organization default, so
  # both the previous and the new binding have to be told.
  defp notify_rule_change(%Scope{} = scope, %AlertRule{} = previous, %AlertRule{} = latest) do
    [previous, latest]
    |> Enum.flat_map(&service_ids_affected_by(scope, &1))
    |> Enum.uniq()
    |> Enum.each(&ServiceMonitor.rule_changed/1)
  end

  # No service_id means the rule is the organization default and applies to every
  # service without a rule of its own, so every monitor in the org must restart.
  defp service_ids_affected_by(%Scope{} = scope, %AlertRule{service_id: nil}) do
    Enum.map(list_services(scope), & &1.id)
  end

  defp service_ids_affected_by(_scope, %AlertRule{service_id: service_id}), do: [service_id]

  @doc """
  Changeset for alert rule forms.
  """
  def change_alert_rule(%Scope{} = scope, %AlertRule{} = rule, attrs \\ %{}) do
    true = rule.organization_id == scope.organization.id

    AlertRule.changeset(rule, attrs, scope)
  end

  @doc """
  The alert rule that governs a service for monitoring and incident purposes —
  service-specific, else organization default, else the hardcoded defaults.

  This is the monitor-facing variant: it takes the service directly, since no
  user is asking (a monitor has no scope). It never returns nil.
  """
  def rule_for_monitoring(%Service{organization_id: organization_id, id: service_id}) do
    from(r in AlertRule,
      where: r.organization_id == ^organization_id,
      where: r.service_id == ^service_id or is_nil(r.service_id),
      # A service's own rule wins over the organization default. The id breaks
      # the tie so the answer cannot depend on the planner.
      order_by: [asc: is_nil(r.service_id), asc: r.id],
      limit: 1
    )
    |> Repo.one()
    |> AlertRule.for_monitoring()
  end

  defp to_metrics(%{total: 0}), do: empty_metrics()

  defp to_metrics(row) do
    histogram = Map.new(Rollup.bounds(), fn bound -> {bound, Map.fetch!(row, :"le_#{bound}")} end)
    count = row.latency_count

    %{
      total: row.total,
      up: row.up,
      down: row.down,
      uptime_percent: row.up / row.total * 100,
      p50: Rollup.percentile(histogram, count, 0.5, row.latency_max),
      p95: Rollup.percentile(histogram, count, 0.95, row.latency_max),
      p99: Rollup.percentile(histogram, count, 0.99, row.latency_max)
    }
  end

  defp empty_metrics do
    %{total: 0, up: 0, down: 0, uptime_percent: nil, p50: nil, p95: nil, p99: nil}
  end

  @doc """
  Builds, or rebuilds, the rollup rows for the hour containing `datetime`.

  Recomputes the hour from the raw checks and upserts, rather than adding to
  whatever is already there, so running it twice is harmless and a backfill and
  a scheduled run cannot double-count.
  """
  @spec roll_up_hour(DateTime.t()) :: non_neg_integer()
  def roll_up_hour(%DateTime{} = datetime) do
    bucket_start = truncate_hour(datetime)
    bucket_end = DateTime.add(bucket_start, 3600, :second)
    now = DateTime.utc_now(:second)

    rows =
      from(c in Check,
        where: c.inserted_at >= ^bucket_start and c.inserted_at < ^bucket_end,
        group_by: c.service_id,
        select: %{
          service_id: c.service_id,
          total: count(c.id),
          up: fragment("count(*) FILTER (WHERE ? <> 'down')", c.status),
          degraded: fragment("count(*) FILTER (WHERE ? = 'degraded')", c.status),
          down: fragment("count(*) FILTER (WHERE ? = 'down')", c.status),
          latency_count: fragment("count(?)", c.response_time_ms),
          latency_sum: fragment("coalesce(sum(?), 0)", c.response_time_ms),
          latency_max: max(c.response_time_ms),
          latency_le_25: fragment("count(*) FILTER (WHERE ? <= 25)", c.response_time_ms),
          latency_le_50: fragment("count(*) FILTER (WHERE ? <= 50)", c.response_time_ms),
          latency_le_100: fragment("count(*) FILTER (WHERE ? <= 100)", c.response_time_ms),
          latency_le_250: fragment("count(*) FILTER (WHERE ? <= 250)", c.response_time_ms),
          latency_le_500: fragment("count(*) FILTER (WHERE ? <= 500)", c.response_time_ms),
          latency_le_1000: fragment("count(*) FILTER (WHERE ? <= 1000)", c.response_time_ms),
          latency_le_2500: fragment("count(*) FILTER (WHERE ? <= 2500)", c.response_time_ms),
          latency_le_5000: fragment("count(*) FILTER (WHERE ? <= 5000)", c.response_time_ms)
        }
      )
      |> Repo.all()
      |> Enum.map(fn row ->
        row
        |> Map.put(:bucket_start, bucket_start)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    case rows do
      [] ->
        0

      rows ->
        {count, _} =
          Repo.insert_all(Rollup, rows,
            on_conflict: {:replace, Rollup.counter_fields() ++ [:latency_max, :updated_at]},
            conflict_target: [:service_id, :bucket_start]
          )

        count
    end
  end

  @doc """
  Rolls up every hour from `hours` ago up to the last complete one.

  Used to backfill after the rollup table is introduced, and to catch up if the
  scheduled job did not run.
  """
  @spec backfill_rollups(pos_integer()) :: non_neg_integer()
  def backfill_rollups(hours) when is_integer(hours) and hours > 0 do
    latest = truncate_hour(DateTime.utc_now())

    Enum.reduce(1..hours, 0, fn ago, acc ->
      acc + roll_up_hour(DateTime.add(latest, -ago * 3600, :second))
    end)
  end

  defp truncate_hour(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 0}})
  end

  # Rollups cover complete hours only, so the current hour is still read from
  # raw checks and the two are added together. `since` is aligned down to the
  # hour, which can widen the window by up to an hour — a "last 24 hours" figure
  # starts at the top of that hour rather than at an arbitrary minute.
  defp rollup_window(opts) do
    requested = Keyword.get_lazy(opts, :since, fn -> hours_ago(24) end)
    cutover = truncate_hour(DateTime.utc_now())
    aligned = truncate_hour(requested)

    live_from =
      if DateTime.compare(requested, cutover) == :gt, do: requested, else: cutover

    {aligned, cutover, live_from}
  end

  defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
end
