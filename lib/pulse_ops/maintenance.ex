defmodule PulseOps.Maintenance do
  @moduledoc """
  Scheduled periods during which a service is expected to misbehave.

  Deploying and waking the whole on-call list is the failure every alerting
  system has in real use, and it is not a monitoring problem — the probes are
  right, the service really is down. What is wrong is the *consequence*, so that
  is what a window suppresses: checks are still made and recorded, the dashboard
  still tells the truth, and no incident opens.

  When a window ends with the service still broken, the next probe reconciles
  and an incident opens then (ADR-009). That falls out of work already done: the
  suppression needs no timer to undo itself.
  """

  import Ecto.Query, warn: false

  alias PulseOps.Accounts.Scope
  alias PulseOps.Maintenance.Window
  alias PulseOps.Monitoring.Service
  alias PulseOps.Organizations
  alias PulseOps.Organizations.Organization
  alias PulseOps.Repo

  @doc """
  Schedules a window for the scoped organization, optionally for one service.
  """
  @spec create_window(Scope.t(), map()) ::
          {:ok, Window.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def create_window(%Scope{} = scope, attrs) do
    with :ok <- Organizations.authorize(scope, :manage_services) do
      %Window{}
      |> Window.changeset(attrs, scope)
      |> Ecto.Changeset.put_change(:created_by_id, scope.user && scope.user.id)
      |> Repo.insert()
    end
  end

  @doc """
  Cancels a window. Cancelling one that is running ends the silence immediately.
  """
  @spec delete_window(Scope.t(), integer()) ::
          {:ok, Window.t()} | {:error, :not_found | :unauthorized}
  def delete_window(%Scope{} = scope, id) do
    with :ok <- Organizations.authorize(scope, :manage_services) do
      case Repo.get_by(Window, id: id, organization_id: scope.organization.id) do
        nil -> {:error, :not_found}
        window -> Repo.delete(window)
      end
    end
  end

  @doc """
  Windows for the scoped organization that have not finished, soonest first.
  """
  @spec list_current_windows(Scope.t()) :: [Window.t()]
  def list_current_windows(%Scope{} = scope, now \\ DateTime.utc_now()) do
    Repo.all(
      from w in Window,
        where: w.organization_id == ^scope.organization.id and w.ends_at > ^now,
        order_by: [asc: w.starts_at],
        preload: [:service, :created_by]
    )
  end

  @doc """
  Whether a service is inside a window right now.

  Monitor-facing, so it takes a `%Service{}` rather than a scope: no user is
  asking. A window with no `service_id` covers every service in the
  organization.
  """
  @spec under_maintenance?(Service.t(), DateTime.t()) :: boolean()
  def under_maintenance?(service, now \\ DateTime.utc_now())

  def under_maintenance?(%Service{id: id, organization_id: organization_id}, now) do
    Repo.exists?(
      from w in Window,
        where: w.organization_id == ^organization_id,
        where: is_nil(w.service_id) or w.service_id == ^id,
        where: w.starts_at <= ^now and w.ends_at > ^now
    )
  end

  @doc """
  Windows running right now in an organization, for the public status page.

  Takes the organization rather than a scope because the status page has no
  user (ADR-011).
  """
  @spec active_windows(Organization.t(), DateTime.t()) :: [Window.t()]
  def active_windows(organization, now \\ DateTime.utc_now())

  def active_windows(%Organization{id: organization_id}, now) do
    Repo.all(
      from w in Window,
        where: w.organization_id == ^organization_id,
        where: w.starts_at <= ^now and w.ends_at > ^now,
        order_by: [asc: w.ends_at],
        select: %{
          id: w.id,
          service_id: w.service_id,
          reason: w.reason,
          starts_at: w.starts_at,
          ends_at: w.ends_at
        }
    )
  end

  @doc """
  Changeset for maintenance window forms.
  """
  @spec change_window(Scope.t(), Window.t(), map()) :: Ecto.Changeset.t()
  def change_window(%Scope{} = scope, %Window{} = window, attrs \\ %{}) do
    Window.changeset(window, attrs, scope)
  end
end
