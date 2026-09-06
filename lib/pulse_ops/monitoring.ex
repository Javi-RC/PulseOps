defmodule PulseOps.Monitoring do
  @moduledoc """
  The Monitoring context.
  """

  import Ecto.Query, warn: false

  alias PulseOps.Accounts.Scope
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
end
