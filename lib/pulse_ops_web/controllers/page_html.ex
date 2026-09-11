defmodule PulseOpsWeb.PageHTML do
  @moduledoc """
  The landing page.

  It speaks to two readers: somebody deciding whether PulseOps would help them,
  and somebody reviewing how it is built. So it shows the product first, then
  what it does, then how it works inside.

  The previews are drawn with the same components the dashboard and the status
  page use, so they cannot drift from the real thing. Their figures are made up,
  which is why they are marked as decoration and described in words. Every claim
  in the copy is something the application actually does.
  """
  use PulseOpsWeb, :html

  import PulseOpsWeb.MonitoringComponents, only: [severity_tag: 1, status_badge: 1, uptime_bar: 1]

  embed_templates "page_html/*"

  @github_url "https://github.com/Javi-RC/PulseOps"

  @doc """
  The dashboard as a picture: four services, one of them down with its incident
  open. Hidden from assistive technology and described in words instead.
  """
  def product_preview(assigns) do
    assigns = assign(assigns, :services, preview_services())

    ~H"""
    <figure id="product-preview" class="relative">
      <figcaption class="sr-only">
        A preview of the PulseOps dashboard: four services, one of them down with a critical
        incident open, updating live.
      </figcaption>

      <div
        aria-hidden="true"
        class="absolute -inset-4 -z-10 rounded-[2rem] bg-primary/10 blur-2xl"
      >
      </div>

      <div
        aria-hidden="true"
        class="overflow-hidden rounded-box border border-base-300 bg-base-100 text-left shadow-xl shadow-base-content/5"
      >
        <div class="flex items-center gap-2 border-b border-base-300 bg-base-200/60 px-4 py-2.5">
          <span class="size-2.5 rounded-full bg-base-300"></span>
          <span class="size-2.5 rounded-full bg-base-300"></span>
          <span class="size-2.5 rounded-full bg-base-300"></span>
          <span class="ml-2 truncate text-xs text-base-content/50">Acme · Dashboard</span>
          <span class="ml-auto inline-flex items-center gap-1.5 text-xs font-medium text-success">
            <span class="relative flex size-2">
              <span class="absolute inline-flex size-full rounded-full bg-success opacity-60 motion-safe:animate-ping"></span>
              <span class="relative inline-flex size-2 rounded-full bg-success"></span>
            </span>
            Live
          </span>
        </div>

        <div class="space-y-4 p-4 sm:p-5">
          <div class="grid grid-cols-4 gap-2">
            <div
              :for={{label, value} <- [{"Services", 4}, {"Healthy", 2}, {"Degraded", 1}, {"Down", 1}]}
              class="rounded-lg border border-base-300 px-2.5 py-2"
            >
              <p class="truncate text-[10px] font-medium uppercase tracking-wide text-base-content/50">
                {label}
              </p>
              <p class="mt-0.5 text-lg font-semibold leading-none">{value}</p>
            </div>
          </div>

          <ul class="divide-y divide-base-300 rounded-lg border border-base-300">
            <li
              :for={service <- @services}
              class={[
                "flex items-center gap-3 px-3 py-2.5",
                service.status == :down && "bg-error/5"
              ]}
            >
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm font-medium">{service.name}</p>
                <p class="text-xs text-base-content/50">
                  {service.environment} · {service.uptime}
                </p>
              </div>
              <div class="max-sm:hidden"><.uptime_bar checks={service.checks} /></div>
              <.status_badge status={service.status} class="w-24 justify-end text-sm" />
            </li>
          </ul>

          <div class="flex items-center gap-3 rounded-lg border border-error/30 bg-error/5 px-3 py-2.5">
            <.severity_tag severity={:critical} />
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-medium">Payments API is unavailable</p>
              <p class="text-xs text-base-content/50">Started 3 min ago · Investigating</p>
            </div>
          </div>
        </div>
      </div>
    </figure>
    """
  end

  @doc """
  The check cycle as numbered steps: the text equivalent of the diagram, and what
  a phone shows instead of it.
  """
  attr :class, :string, default: nil

  def check_steps(assigns) do
    ~H"""
    <ol class={["list-decimal space-y-1 pl-5 text-sm text-base-content/70", @class]}>
      <li>A timer fires, spread by up to 10% so monitors never probe in lockstep.</li>
      <li>The probe runs in a supervised task, off the monitor's own callback.</li>
      <li>Your endpoint answers, times out, or refuses the connection.</li>
      <li>The outcome reaches the monitor as an ordinary message.</li>
      <li>Every check is recorded, whatever it said, and pushed to that service's own page.</li>
      <li>
        The monitor compares the new status with the last one. By default, three failures in a row
        mean down and two successes mean recovered.
      </li>
      <li>
        Only if the status changed is it saved and broadcast to the dashboard and the status page.
      </li>
      <li>
        Only going down opens an incident, and only recovering resolves it; slowing down to degraded
        does neither.
      </li>
    </ol>
    """
  end

  defp github_url, do: @github_url

  defp facts do
    [
      %{
        icon: "lucide-radio",
        title: "No polling",
        body: "Every change arrives over a WebSocket."
      },
      %{
        icon: "lucide-network",
        title: "One process per service",
        body: "Supervised, isolated, and restarted if it crashes."
      },
      %{
        icon: "lucide-activity",
        title: "Every check kept",
        body: "Uptime and p50, p95 and p99 over 24 h, 7 d or 30 d."
      },
      %{
        icon: "lucide-code",
        title: "Source on GitHub",
        body: "Every line, test and design decision is there to read."
      }
    ]
  end

  defp features do
    [
      %{
        icon: "lucide-plug-zap",
        title: "Checks shaped like your endpoint",
        body:
          "GET, HEAD or POST with headers and a body. Expect an exact status, require text in the response, and test the connection before saving."
      },
      %{
        icon: "lucide-sliders-horizontal",
        title: "Alert rules, not guesswork",
        body:
          "Decide how many failed checks open an incident, how many good ones close it, and how severe it is — for the organization or a single service."
      },
      %{
        icon: "lucide-siren",
        title: "Incidents that run themselves",
        body:
          "Opened with the reason attached and resolved on recovery, with a timeline that separates what a monitor saw from what a person did."
      },
      %{
        icon: "lucide-bell",
        title: "Notifications that stay signal",
        body:
          "Webhooks for Discord, Teams or ntfy, and email. A flapping service sends one digest, and an unacknowledged critical incident escalates."
      },
      %{
        icon: "lucide-calendar-clock",
        title: "Maintenance windows",
        body:
          "Plan a deploy and nobody is paged for it. Checks keep running and the history stays honest."
      },
      %{
        icon: "lucide-globe",
        title: "A public status page",
        body:
          "Live status and uptime for your customers, with URLs, causes and timelines kept off it."
      },
      %{
        icon: "lucide-users",
        title: "Built for a team",
        body:
          "Owners, admins, members and viewers, enforced in the domain layer rather than by hiding buttons."
      },
      %{
        icon: "lucide-braces",
        title: "A JSON API",
        body:
          "Read and change services and incidents with tokens that act as the person who created them."
      },
      %{
        icon: "lucide-shield-check",
        title: "Certificate expiry, in advance",
        body:
          "Every HTTPS certificate is read daily, and you are told before it expires — without an incident."
      }
    ]
  end

  defp decisions do
    [
      %{
        title: "The probe never blocks the monitor",
        body:
          "Each request runs in a supervised task and reports back as a message, so a slow endpoint cannot freeze the process watching it, and a crash cannot take it down."
      },
      %{
        title: "One open incident, guaranteed by the database",
        body:
          "A partial unique index makes it impossible for two racing monitors to open the same incident twice."
      },
      %{
        title: "Broadcast on change, not on every check",
        body:
          "One topic per organization, and only a change of status is pushed: a service that stays healthy re-renders nobody's dashboard."
      }
    ]
  end

  defp status_page_services do
    [
      %{name: "API", status: :healthy, uptime: "99.99%"},
      %{name: "Dashboard", status: :healthy, uptime: "100.00%"},
      %{name: "Webhooks", status: :healthy, uptime: "99.95%"}
    ]
  end

  defp preview_services do
    [
      %{
        name: "Payments API",
        environment: "production",
        status: :down,
        uptime: "98.61%",
        checks: preview_checks("hhhhhhhhhhhhhhhhhhhhdxxx")
      },
      %{
        name: "Checkout",
        environment: "production",
        status: :degraded,
        uptime: "99.72%",
        checks: preview_checks("hhhhhhhhhdhhhhhhhhhhhhdd")
      },
      %{
        name: "Search",
        environment: "production",
        status: :healthy,
        uptime: "100.00%",
        checks: preview_checks("hhhhhhhhhhhhhhhhhhhhhhhh")
      },
      %{
        name: "Auth",
        environment: "staging",
        status: :healthy,
        uptime: "99.96%",
        checks: preview_checks("hhhhhhhhhhhhhxhhhhhhhhhh")
      }
    ]
  end

  # One letter per check, oldest first: h healthy, d degraded, x down.
  defp preview_checks(pattern) do
    pattern
    |> String.graphemes()
    |> Enum.map(fn letter -> %{status: check_status(letter), inserted_at: nil} end)
  end

  defp check_status("h"), do: :healthy
  defp check_status("d"), do: :degraded
  defp check_status("x"), do: :down
end
