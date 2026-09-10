defmodule PulseOps.NotificationsFixtures do
  @moduledoc """
  Test fixtures for the `PulseOps.Notifications` context.
  """

  alias PulseOps.AccountsFixtures
  alias PulseOps.Incidents.EventJob
  alias PulseOps.Notifications
  alias PulseOps.OrganizationsFixtures
  alias PulseOps.Repo

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

  @doc """
  Runs the incident announcements queued so far, as Oban would, and removes
  them.

  Opening or resolving an incident only queues its announcement
  (`PulseOps.Incidents.EventJob`); the deliveries, the flapping digest and the
  escalation are decided when that job runs. A test asserting on those runs the
  announcements first — and promptly, the way the queue would, because flap
  detection counts what has happened by the time it runs.
  """
  def announce_incident_events do
    worker = inspect(EventJob)

    Oban.Job
    |> Repo.all()
    |> Enum.filter(&(&1.worker == worker and &1.state in ["available", "scheduled"]))
    |> Enum.sort_by(& &1.id)
    |> Enum.each(fn job ->
      :ok = EventJob.perform(job)
      Repo.delete!(job)
    end)
  end
end
