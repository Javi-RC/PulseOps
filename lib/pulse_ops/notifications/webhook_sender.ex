defmodule PulseOps.Notifications.WebhookSender do
  @moduledoc """
  Delivers an incident notification to a generic webhook endpoint as a POST of
  JSON. The body is a flat, documented shape so any receiver — Discord, Teams,
  ntfy, a Make/n8n flow, a script — can pick out what it needs without the
  receiver depending on PulseOps schemas:

      {
        "event": "opened" | "resolved",
        "incident": { "id", "title", "status", "severity", "started_at",
                      "resolved_at", "cause", "duration_seconds", "url" },
        "service": { "id", "name", "environment", "url" },
        "organization": { "id", "name", "slug" }
      }

  Returns `:ok` on a 2xx response and `{:error, reason}` otherwise, so the Oban
  job can retry a failed delivery. A receiver rejecting the payload is not fixed
  by retrying, but a couple of attempts costs nothing.
  """

  alias PulseOps.Incidents.Incident
  alias PulseOps.Notifications.Notifier

  @receive_timeout_ms 10_000

  @doc """
  Sends one notification. Returns `:ok` or `{:error, reason}`.
  """
  def deliver(%Notifier{url: url, secret_token: secret}, %Incident{} = incident, event)
      when event in ["opened", "resolved"] do
    headers = [{"user-agent", "PulseOps"}]
    headers = if secret, do: [{"authorization", "Bearer #{secret}"} | headers], else: headers

    case Req.post(url,
           json: payload(incident, event),
           headers: headers,
           receive_timeout: @receive_timeout_ms,
           retry: false,
           plug: plug()
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Tests route every webhook through the `:pulseops` Req.Test stub so nothing
  # touches the network. Everything else delivers over the wire.
  defp plug do
    case Application.get_env(:pulse_ops, :webhook_client, :http) do
      :stub -> {Req.Test, :pulseops}
      :http -> nil
    end
  end

  defp payload(%Incident{} = incident, event) do
    %{
      "event" => event,
      "incident" => incident_fields(incident),
      "service" => service_fields(incident.service),
      "organization" => organization_fields(incident.organization)
    }
  end

  defp incident_fields(incident) do
    %{
      "id" => incident.id,
      "title" => incident.title,
      "status" => to_string(incident.status),
      "severity" => to_string(incident.severity),
      "started_at" => iso(incident.started_at),
      "resolved_at" => iso(incident.resolved_at),
      "cause" => incident.cause,
      "duration_seconds" => Incident.duration_seconds(incident),
      "url" => incident_url(incident)
    }
  end

  defp service_fields(nil), do: nil

  defp service_fields(service) do
    %{
      "id" => service.id,
      "name" => service.name,
      "environment" => to_string(service.environment),
      "url" => service.url
    }
  end

  defp organization_fields(nil), do: nil

  defp organization_fields(organization) do
    %{
      "id" => organization.id,
      "name" => organization.name,
      "slug" => organization.slug
    }
  end

  defp incident_url(%Incident{organization: nil}), do: nil

  defp incident_url(%Incident{organization: %{slug: slug}} = incident) do
    PulseOpsWeb.Endpoint.url() <> "/orgs/#{slug}/incidents/#{incident.id}"
  end

  defp iso(nil), do: nil
  defp iso(datetime), do: DateTime.to_iso8601(datetime)
end
