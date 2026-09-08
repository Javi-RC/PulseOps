defmodule PulseOps.Notifications.IncidentNotifier do
  @moduledoc """
  The incident notification emails, sent through `PulseOps.Mailer` (Swoosh).

  The body is plain text on purpose: incident mail is read on a phone or from a
  pager, and a wall of markup helps nobody. The email provider is chosen by
  environment config — Local in dev, Test in test, Brevo in dev/prod when
  `BREVO_API_KEY` is set.
  """

  import Swoosh.Email

  alias PulseOps.Incidents.Incident
  alias PulseOps.Mailer
  alias PulseOps.Notifications.Notifier

  @doc """
  Sends one notification email. Returns `{:ok, metadata}` or `{:error, reason}`,
  letting the Oban job retry a failed delivery.
  """
  def deliver(%Notifier{recipient: recipient}, %Incident{} = incident, event)
      when event in ["opened", "resolved"] do
    email =
      new()
      |> to(recipient)
      |> from(Mailer.from_default())
      |> subject(mail_subject(incident, event))
      |> text_body(mail_body(incident, event))

    Mailer.deliver(email)
  end

  defp mail_subject(%Incident{title: title}, "opened"),
    do: "[PulseOps] Incident opened: #{title}"

  defp mail_subject(%Incident{title: title}, "resolved"),
    do: "[PulseOps] Incident resolved: #{title}"

  defp mail_body(%Incident{} = incident, event) do
    """
    #{service_line(incident)}

    #{event_headline(event)} — #{incident.title}
    Severity: #{incident.severity}
    Status: #{incident.status}
    Started: #{format(incident.started_at)}
    #{append_resolved(incident)}
    Duration: #{Incident.duration_seconds(incident)}s
    #{append_cause(incident)}
    #{append_url(incident)}
    """
  end

  defp service_line(%Incident{service: %{name: name}}), do: "Service: #{name}"
  defp service_line(_incident), do: "Service: unknown"

  defp event_headline("opened"), do: "An incident opened"
  defp event_headline("resolved"), do: "An incident resolved"

  defp append_resolved(%Incident{resolved_at: nil}), do: ""

  defp append_resolved(%Incident{resolved_at: resolved_at}),
    do: "Resolved: #{format(resolved_at)}"

  defp append_cause(%Incident{cause: nil}), do: ""
  defp append_cause(%Incident{cause: cause}), do: "Cause: #{cause}"

  defp append_url(%Incident{organization: nil}), do: ""

  defp append_url(%Incident{organization: %{slug: slug}} = incident) do
    "Link: " <> PulseOpsWeb.Endpoint.url() <> "/orgs/#{slug}/incidents/#{incident.id}"
  end

  defp format(datetime), do: DateTime.to_iso8601(datetime)
end
