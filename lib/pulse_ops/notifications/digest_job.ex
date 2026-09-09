defmodule PulseOps.Notifications.DigestJob do
  @moduledoc """
  Sends one message summarising a flapping service, instead of one per
  transition.

  Scheduled with a delay and made unique per service, so every transition that
  happens while it waits collapses into the job already queued. The delay is the
  whole mechanism: it is the window over which the storm is gathered.

  Counts are taken when the job *runs*, not when it was scheduled, so the
  message describes what actually happened rather than what had happened by the
  time the first transition was noticed.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  import Ecto.Query, warn: false

  alias PulseOps.Incidents.Incident
  alias PulseOps.Monitoring.Service
  alias PulseOps.Notifications
  alias PulseOps.Notifications.DigestNotifier
  alias PulseOps.Notifications.Notifier
  alias PulseOps.Notifications.WebhookSender
  alias PulseOps.Repo

  @impl true
  def perform(%Oban.Job{
        args: %{"service_id" => service_id, "organization_id" => organization_id}
      }) do
    case Repo.get(Service, service_id) do
      # Deleted between scheduling and running. Nothing to summarise, and
      # nothing worth logging.
      nil ->
        :ok

      service ->
        deliver(organization_id, service, summary(service))
    end
  end

  defp summary(%Service{id: service_id}) do
    since = DateTime.add(DateTime.utc_now(), -Notifications.flap_window_seconds(), :second)

    query =
      from i in Incident,
        where: i.service_id == ^service_id and i.started_at >= ^since,
        select: %{
          count: count(i.id),
          first_at: min(i.started_at),
          still_open: fragment("count(*) FILTER (WHERE ? IS NULL)", i.resolved_at)
        }

    Repo.one(query) || %{count: 0, first_at: nil, still_open: 0}
  end

  defp deliver(_organization_id, _service, %{count: 0}), do: :ok

  defp deliver(organization_id, service, summary) do
    organization_id
    |> Notifications.notifiers_for_digest(service)
    |> Enum.each(&dispatch(&1, service, summary))

    :ok
  end

  defp dispatch(%Notifier{type: :webhook} = notifier, service, summary),
    do: WebhookSender.deliver_digest(notifier, service, summary)

  defp dispatch(%Notifier{type: :email} = notifier, service, summary),
    do: DigestNotifier.deliver(notifier, service, summary)
end
