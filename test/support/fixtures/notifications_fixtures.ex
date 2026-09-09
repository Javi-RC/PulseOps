defmodule PulseOps.NotificationsFixtures do
  @moduledoc """
  Test fixtures for the `PulseOps.Notifications` context.
  """

  alias PulseOps.AccountsFixtures
  alias PulseOps.Notifications
  alias PulseOps.OrganizationsFixtures

  @doc """
  Valid attributes for a webhook notifier. Name is unique so fixtures do not
  collide.
  """
  def valid_notifier_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "Notifier #{System.unique_integer([:positive])}",
      type: :webhook,
      enabled: true,
      url: "https://hooks.example.com/pulseops",
      secret_token: nil
    })
  end

  @doc """
  Generate a webhook notifier for the scoped organization.
  """
  def notifier_fixture(scope, attrs \\ %{}) do
    {:ok, notifier} = Notifications.create_notifier(scope, valid_notifier_attributes(attrs))
    notifier
  end

  @doc """
  The user id of a fresh user who is also a member of the scope's organization.
  """
  def assignee_id_fixture(scope) do
    user = AccountsFixtures.user_fixture()
    OrganizationsFixtures.membership_fixture(scope.organization, user, :member)
    user.id
  end
end
