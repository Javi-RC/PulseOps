defmodule PulseOps.Monitoring.TlsJob do
  @moduledoc """
  Daily check of every enabled https service's certificate.

  Daily, not per probe: a certificate changes at most once in its lifetime, and
  a TLS handshake per check would be a handshake every thirty seconds per
  service to learn a date that moves once a quarter.

  A service whose certificate is inside the warning window is announced through
  the ordinary notifier channels, once per expiry. Renewing the certificate
  moves the expiry, which clears the mark and lets the next one be announced in
  its turn — a boolean "warned" flag would either repeat daily or go quiet for
  ever after the first time.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias PulseOps.Monitoring
  alias PulseOps.Monitoring.Service
  alias PulseOps.Monitoring.TlsCheck
  alias PulseOps.Notifications

  @impl true
  def perform(%Oban.Job{args: args}) do
    services =
      case args do
        %{"service_id" => id} ->
          Enum.filter(Monitoring.list_services_for_tls_check(), &(&1.id == id))

        _all ->
          Monitoring.list_services_for_tls_check()
      end

    Enum.each(services, &check/1)

    {:ok, length(services)}
  end

  defp check(%Service{} = service) do
    client = TlsCheck.client()
    result = client.certificate(service.url, timeout_ms: service.timeout_ms)

    case Monitoring.record_tls_check(service, result) do
      {:ok, updated} -> maybe_warn(updated)
      {:error, _changeset} -> :ok
    end
  end

  # Nothing to say when the expiry is comfortably away, and nothing to say twice
  # about the same expiry.
  defp maybe_warn(%Service{tls_expires_at: nil}), do: :ok

  defp maybe_warn(%Service{} = service) do
    already_warned? =
      service.tls_warned_for &&
        DateTime.compare(service.tls_warned_for, service.tls_expires_at) == :eq

    cond do
      not Monitoring.tls_expiring?(service) ->
        :ok

      already_warned? ->
        :ok

      true ->
        warn(service)
    end
  end

  defp warn(%Service{} = service) do
    days = Monitoring.tls_days_left(service)

    Logger.info("tls certificate expiring",
      service_id: service.id,
      organization_id: service.organization_id
    )

    Notifications.enqueue_tls_warning(service, days)
    Monitoring.mark_tls_warned(service)

    :ok
  end
end
