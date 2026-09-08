defmodule PulseOps.NotificationsFixtures do
  @moduledoc """
  Test fixtures for the `PulseOps.Notifications` context.
  """

  alias PulseOps.Notifications

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
      secret_token: nil,
      recipient: nil
    })
  end

  @doc """
  Generate a webhook notifier for the scoped organization.
  """
  def notifier_fixture(scope, attrs \\ %{}) do
    {:ok, notifier} = Notifications.create_notifier(scope, valid_notifier_attributes(attrs))
    notifier
  end
end
