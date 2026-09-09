defmodule PulseOps.Monitoring.AlertRule do
  @moduledoc """
  A per-service (or per-organization default) override of how a service is
  monitored and how its incidents are classified.

  The defaults match the original hardcoded behaviour, so a service with no rule
  keeps behaving exactly as before:
    * `failure_threshold` — consecutive failures before the service goes `:down`
      (default 3)
    * `success_threshold` — consecutive successes before a `:down` service
      recovers (default 2)
    * `degraded_ratio` — response time at or above this fraction of the timeout
      is reported `:degraded` (default 0.5)
    * `severity` — severity assigned to incidents for this service (default
      `:medium`)

  A row with a nil `service_id` is the organization-wide default; a row with one
  belongs to a single service and overrides it.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias PulseOps.Accounts.Scope
  alias PulseOps.Monitoring.Service
  alias PulseOps.Organizations.Organization
  alias PulseOps.Repo

  @severities [:low, :medium, :high, :critical]

  @type t :: %__MODULE__{}

  schema "alert_rules" do
    field :failure_threshold, :integer, default: 3
    field :success_threshold, :integer, default: 2
    field :degraded_ratio, :float, default: 0.5
    field :severity, Ecto.Enum, values: @severities, default: :medium

    belongs_to :organization, Organization
    belongs_to :service, Service

    timestamps(type: :utc_datetime)
  end

  def severities, do: @severities

  @doc """
  Returns a bare rule carrying the original hardcoded defaults. Used by the
  monitoring hot path when a service has neither its own rule nor an
  organization default — it is never persisted.
  """
  def default do
    %__MODULE__{
      failure_threshold: 3,
      success_threshold: 2,
      degraded_ratio: 0.5,
      severity: :medium
    }
  end

  @doc """
  Falls back to the bare default when no persisted rule was found for a service.
  """
  def for_monitoring(nil), do: default()
  def for_monitoring(%__MODULE__{} = rule), do: rule

  @doc """
  Changeset for user-supplied rule attributes. A rule is scoped to an
  organization; if `service_id` is present it applies to that service only.
  """
  def changeset(rule, attrs, %Scope{} = organization_scope) do
    rule
    |> cast(attrs, [
      :failure_threshold,
      :success_threshold,
      :degraded_ratio,
      :severity,
      :service_id
    ])
    |> validate_required([:failure_threshold, :success_threshold, :degraded_ratio, :severity])
    |> validate_inclusion(:severity, @severities)
    |> validate_number(:failure_threshold,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100
    )
    |> validate_number(:success_threshold,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100
    )
    |> validate_number(:degraded_ratio, greater_than: 0.0, less_than_or_equal_to: 1.0)
    |> put_change(:organization_id, organization_scope.organization.id)
    |> validate_service_scope()
    |> unique_constraint(:service_id, message: "this service already has an alert rule")
    # The database, not the form, is what guarantees a single organization
    # default. Reported against :service_id because that is the field the user
    # can actually change — the select whose empty value means "default".
    |> unique_constraint(:service_id,
      name: :alert_rules_one_default_per_organization,
      message: "this organization already has a default rule"
    )
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:service_id)
  end

  # A rule bound to a service must be bound to one of this organization's own.
  # The foreign key alone only says the service exists somewhere, so without
  # this an admin could point a rule at another tenant's service_id. That reads
  # nothing — `rule_for_monitoring/1` filters by organization — but it takes the
  # victim's slot in the unique index and stops them ever creating their own
  # rule for that service. Cross-tenant denial of service through an unvalidated
  # field, which is why the check belongs here and not in the form.
  defp validate_service_scope(changeset) do
    service_id = get_field(changeset, :service_id)

    cond do
      is_nil(service_id) ->
        changeset

      service_in_organization?(service_id, get_field(changeset, :organization_id)) ->
        changeset

      true ->
        add_error(changeset, :service_id, "must belong to the organization")
    end
  end

  defp service_in_organization?(service_id, organization_id) do
    Repo.exists?(
      from s in Service,
        where: s.id == ^service_id and s.organization_id == ^organization_id
    )
  end
end
