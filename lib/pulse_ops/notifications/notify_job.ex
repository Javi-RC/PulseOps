defmodule PulseOps.Notifications.NotifyJob do
  @moduledoc """
  Delivers one incident notification for one notifier.

  Enqueued by `PulseOps.Notifications.enqueue_incident_notifications/3` when an
  incident opens or resolves, giving a slow or unreachable receiver its own job
  and retry budget instead of blocking the monitor that spotted the incident.

  Deliberately quiet when the notifier or incident is gone: a notifier deleted
  between enqueue and run should not spam the error log.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  # "escalated" is the same delivery as "opened" with a different word on it:
  # the incident has not changed, the fact that nobody picked it up has.
  @events ["opened", "resolved", "escalated"]

  alias PulseOps.Incidents.Incident
  alias PulseOps.Notifications
  alias PulseOps.Notifications.IncidentNotifier
  alias PulseOps.Notifications.Notifier
  alias PulseOps.Notifications.WebhookSender

  @impl true
  def perform(%Oban.Job{
        args: %{"incident_id" => incident_id, "notifier_id" => notifier_id} = args
      }) do
    with %Notifier{enabled: true} = notifier <- Notifications.notifier_for_delivery(notifier_id),
         %Incident{} = incident <- Notifications.incident_for_delivery(incident_id) do
      dispatch(notifier, incident, event(args))
    else
      # The notifier or incident disappeared (or the notifier was paused) before
      # the job ran; nothing to deliver.
      _else -> :ok
    end
  end

  defp dispatch(%Notifier{type: :webhook} = notifier, incident, event),
    do: WebhookSender.deliver(notifier, incident, event)

  defp dispatch(%Notifier{type: :email} = notifier, incident, event),
    do: IncidentNotifier.deliver(notifier, incident, event)

  defp event(%{"event" => event}) when event in @events, do: event
end
