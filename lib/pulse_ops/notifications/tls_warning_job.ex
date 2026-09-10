defmodule PulseOps.Notifications.TlsWarningJob do
  @moduledoc """
  Delivers one certificate-expiry warning to one notifier.

  Its own job for the same reason `NotifyJob` is: a slow receiver gets its own
  retry budget instead of holding up the nightly sweep.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.Service
  alias PulseOps.Notifications
  alias PulseOps.Notifications.Notifier
  alias PulseOps.Notifications.TlsNotifier
  alias PulseOps.Notifications.WebhookSender
  alias PulseOps.Repo

  @impl true
  def perform(%Oban.Job{
        args: %{"notifier_id" => notifier_id, "service_id" => service_id} = args
      }) do
    with %Notifier{enabled: true} = notifier <- Notifications.notifier_for_delivery(notifier_id),
         %Service{} = service <- Repo.get(Service, service_id) do
      dispatch(notifier, service, days_left(args, service))
    else
      # Deleted or paused between the sweep and the delivery.
      _else -> :ok
    end
  end

  # Recomputed rather than trusted from the args: a job that sat in a retry
  # backlog overnight would otherwise announce a number that is a day stale.
  defp days_left(args, service) do
    Monitoring.tls_days_left(service) || Map.get(args, "days_left", 0)
  end

  defp dispatch(%Notifier{type: :webhook} = notifier, service, days_left),
    do: WebhookSender.deliver_tls_warning(notifier, service, days_left)

  defp dispatch(%Notifier{type: :email} = notifier, service, days_left),
    do: TlsNotifier.deliver(notifier, service, days_left)
end
