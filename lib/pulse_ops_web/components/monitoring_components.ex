defmodule PulseOpsWeb.MonitoringComponents do
  @moduledoc """
  The shared pieces of the monitoring UI: status indicators, stat tiles and the
  response-time chart.

  Status colours come from a reserved palette and are never the only thing
  carrying the meaning — every status ships as a shape plus a written label, so
  it survives colour-blindness, greyscale printing and forced-colors mode.
  """

  use Phoenix.Component

  import PulseOpsWeb.CoreComponents, only: [icon: 1]

  alias PulseOps.Incidents.Incident
  alias PulseOps.Monitoring.Check

  @doc """
  A service status as a coloured dot plus its name.
  """
  attr :status, :atom, required: true
  attr :class, :string, default: nil

  def status_badge(assigns) do
    assigns = assign(assigns, :meta, status_meta(assigns.status))

    ~H"""
    <span class={["inline-flex items-center gap-1.5 whitespace-nowrap", @class]}>
      <%!-- Shape and word both carry the status, so it survives colour-blindness,
            greyscale printing and forced-colors mode. --%>
      <span style={"color: #{@meta.color}"} class="inline-flex shrink-0">
        <.icon name={@meta.icon} class="size-4" />
      </span>
      <span class="font-medium">{@meta.label}</span>
    </span>
    """
  end

  @doc """
  An incident severity.
  """
  attr :severity, :atom, required: true

  def severity_tag(assigns) do
    assigns = assign(assigns, :meta, severity_meta(assigns.severity))

    ~H"""
    <span
      class="inline-flex items-center gap-1.5 rounded px-2 py-0.5 text-xs font-semibold uppercase tracking-wide"
      style={"color: #{@meta.color}; background: #{@meta.color}1a"}
    >
      <.icon name={@meta.icon} class="size-3.5" />
      {@meta.label}
    </span>
    """
  end

  @doc """
  A single figure with its label. The number is the chart — a one-bar bar chart
  would say less.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil

  def stat_tile(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 px-4 py-3">
      <div class="text-xs font-medium uppercase tracking-wide text-base-content/60">{@label}</div>
      <%!-- Proportional figures: tabular-nums makes a large standalone number look loose. --%>
      <div class="mt-1 text-2xl font-semibold leading-none">{@value}</div>
      <div :if={@hint} class="mt-1 text-xs text-base-content/50">{@hint}</div>
    </div>
    """
  end

  @doc """
  A compact history strip: one thin bar per check, oldest to newest.

  Shows the shape of an outage at a glance without competing with the latency
  chart for attention.
  """
  attr :checks, :list, required: true

  def uptime_bar(assigns) do
    ~H"""
    <div class="flex items-end gap-px" role="img" aria-label={uptime_bar_label(@checks)}>
      <span
        :for={check <- @checks}
        class="h-6 w-1 shrink-0 rounded-sm"
        style={"background: #{status_meta(check.status).color}"}
        title={"#{status_meta(check.status).label} · #{format_time(check.inserted_at)}"}
      ></span>
      <span :if={@checks == []} class="text-xs text-base-content/50">No checks yet</span>
    </div>
    """
  end

  @doc """
  Response time over the recent checks.

  One series, so no legend: the heading names it. Only the latest and the slowest
  points are labelled directly; everything else is reachable through the hover
  readout or the table underneath, which is the accessible twin of the plot.
  """
  attr :checks, :list, required: true
  attr :id, :string, required: true

  def response_time_chart(assigns) do
    assigns = assign(assigns, :plot, build_plot(assigns.checks))

    ~H"""
    <figure class="viz-root" id={@id}>
      <style>
        .viz-root {
          --viz-series: #2a78d6;
          --viz-grid: #e1e0d9;
          --viz-axis: #c3c2b7;
          --viz-muted: #898781;
          --viz-ink: #0b0b0b;
          --viz-surface: #fcfcfb;
        }
        @media (prefers-color-scheme: dark) {
          :root:where(:not([data-theme="light"])) .viz-root {
            --viz-series: #3987e5;
            --viz-grid: #2c2c2a;
            --viz-axis: #383835;
            --viz-muted: #898781;
            --viz-ink: #ffffff;
            --viz-surface: #1a1a19;
          }
        }
        :root[data-theme="dark"] .viz-root {
          --viz-series: #3987e5;
          --viz-grid: #2c2c2a;
          --viz-axis: #383835;
          --viz-muted: #898781;
          --viz-ink: #ffffff;
          --viz-surface: #1a1a19;
        }
        .viz-hit { fill: transparent; }
        .viz-readout { opacity: 0; pointer-events: none; }
        .viz-slice:hover .viz-readout,
        .viz-slice:focus-within .viz-readout { opacity: 1; }
      </style>

      <figcaption class="mb-2 text-sm font-medium text-base-content/70">
        Response time, last {length(@checks)} checks (ms)
      </figcaption>

      <p :if={@plot == nil} class="py-8 text-center text-sm text-base-content/50">
        Not enough data to plot yet.
      </p>

      <svg
        :if={@plot}
        viewBox={"0 0 #{@plot.width} #{@plot.height}"}
        class="h-56 w-full overflow-visible"
        role="img"
        aria-label={"Response time over the last #{length(@checks)} checks, between #{@plot.min_value} and #{@plot.max_value} milliseconds"}
      >
        <%!-- Solid hairline grid, one shade off the surface. Never dashed. --%>
        <g>
          <line
            :for={tick <- @plot.ticks}
            x1={@plot.pad_left}
            x2={@plot.width - @plot.pad_right}
            y1={tick.y}
            y2={tick.y}
            stroke="var(--viz-grid)"
            stroke-width="1"
          />
          <text
            :for={tick <- @plot.ticks}
            x={@plot.pad_left - 8}
            y={tick.y + 4}
            text-anchor="end"
            font-size="11"
            style="font-variant-numeric: tabular-nums"
            fill="var(--viz-muted)"
          >
            {tick.label}
          </text>
        </g>

        <line
          x1={@plot.pad_left}
          x2={@plot.width - @plot.pad_right}
          y1={@plot.baseline}
          y2={@plot.baseline}
          stroke="var(--viz-axis)"
          stroke-width="1"
        />

        <polyline
          points={@plot.points}
          fill="none"
          stroke="var(--viz-series)"
          stroke-width="2"
          stroke-linejoin="round"
          stroke-linecap="round"
        />

        <%!-- Selective direct labels: the newest reading and the worst one. --%>
        <g :for={point <- @plot.labelled}>
          <circle
            cx={point.x}
            cy={point.y}
            r="4"
            fill="var(--viz-series)"
            stroke="var(--viz-surface)"
            stroke-width="2"
          />
          <text
            x={point.x}
            y={point.y - 10}
            text-anchor={point.anchor}
            font-size="11"
            font-weight="600"
            style="font-variant-numeric: tabular-nums"
            fill="var(--viz-ink)"
          >
            {point.label}
          </text>
        </g>

        <%!-- Hover layer: a full-height slice per point, so the target is the
             column rather than the dot. --%>
        <g :for={point <- @plot.slices} class="viz-slice" tabindex="0">
          <rect
            class="viz-hit"
            x={point.slice_x}
            y={@plot.pad_top}
            width={point.slice_width}
            height={@plot.baseline - @plot.pad_top}
          />
          <g class="viz-readout">
            <line
              x1={point.x}
              x2={point.x}
              y1={@plot.pad_top}
              y2={@plot.baseline}
              stroke="var(--viz-axis)"
              stroke-width="1"
            />
            <circle
              cx={point.x}
              cy={point.y}
              r="4"
              fill="var(--viz-series)"
              stroke="var(--viz-surface)"
              stroke-width="2"
            />
            <text
              x={point.x}
              y={@plot.pad_top - 4}
              text-anchor={point.anchor}
              font-size="11"
              style="font-variant-numeric: tabular-nums"
              fill="var(--viz-ink)"
            >
              {point.readout}
            </text>
          </g>
        </g>
      </svg>

      <%!-- The accessible twin: every plotted value is readable without hovering. --%>
      <details :if={@plot} class="mt-3">
        <summary class="cursor-pointer text-xs text-base-content/60">View as table</summary>
        <div class="mt-2 max-h-64 overflow-auto">
          <table class="table table-xs">
            <thead>
              <tr>
                <th>Time</th>
                <th>Status</th>
                <th class="text-right">Response</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={check <- Enum.reverse(@checks)}>
                <td class="tabular-nums">{format_time(check.inserted_at)}</td>
                <td><.status_badge status={check.status} /></td>
                <td class="text-right tabular-nums">{format_ms(check.response_time_ms)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>
    </figure>
    """
  end

  @doc """
  A timestamp rendered as how long ago it was.
  """
  attr :at, :any, required: true
  attr :class, :string, default: nil

  def relative_time(assigns) do
    ~H"""
    <span class={@class} title={@at && to_string(@at)}>{format_relative(@at)}</span>
    """
  end

  ## Formatting helpers

  @doc """
  Human-readable "3 min ago".
  """
  def format_relative(nil), do: "never"

  def format_relative(at) do
    case DateTime.diff(DateTime.utc_now(), at) do
      seconds when seconds < 60 -> "just now"
      seconds when seconds < 3_600 -> "#{div(seconds, 60)} min ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3_600)} h ago"
      seconds -> "#{div(seconds, 86_400)} d ago"
    end
  end

  @doc """
  A duration in seconds as a compact human string.
  """
  def format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  def format_duration(seconds) when seconds < 3_600 do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  def format_duration(seconds) do
    "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
  end

  @doc """
  A response time, or a dash when there was none.
  """
  def format_ms(nil), do: "—"
  def format_ms(ms), do: "#{ms} ms"

  @doc """
  A percentage to two decimal places, or a dash when there is no data.
  """
  def format_percent(nil), do: "—"
  def format_percent(value), do: "#{:erlang.float_to_binary(value * 1.0, decimals: 2)}%"

  def format_time(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M:%S")
  def format_time(_other), do: "—"

  @doc """
  Colour and label for a service or check status.
  """
  # Reserved status palette. Warning and serious sit below 3:1 on a light
  # surface by design, which is why every use pairs the colour with a label.
  def status_meta(:healthy),
    do: %{color: "#0ca30c", label: "Healthy", icon: "lucide-circle-check"}

  def status_meta(:degraded),
    do: %{color: "#fab219", label: "Degraded", icon: "lucide-triangle-alert"}

  def status_meta(:down), do: %{color: "#d03b3b", label: "Down", icon: "lucide-circle-x"}

  def status_meta(_unknown),
    do: %{color: "#898781", label: "Unknown", icon: "lucide-circle-question-mark"}

  @doc """
  Colour and label for an incident severity.
  """
  def severity_meta(:critical), do: %{color: "#d03b3b", label: "Critical", icon: "lucide-siren"}

  def severity_meta(:high),
    do: %{color: "#ec835a", label: "High", icon: "lucide-triangle-alert"}

  def severity_meta(:medium),
    do: %{color: "#fab219", label: "Medium", icon: "lucide-circle-alert"}

  def severity_meta(_low), do: %{color: "#898781", label: "Low", icon: "lucide-info"}

  @doc """
  Label for an incident workflow status.
  """
  def incident_status_label(status) do
    status |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  @doc """
  The statuses a person can move an incident to.
  """
  def workflow_statuses, do: Incident.workflow_statuses()

  ## Plot geometry

  @width 720
  @height 220
  @pad_left 48
  @pad_right 16
  @pad_top 24
  @pad_bottom 28

  defp build_plot(checks) do
    values = Enum.map(checks, & &1.response_time_ms)
    plottable = Enum.reject(values, &is_nil/1)

    if length(plottable) < 2 do
      nil
    else
      do_build_plot(checks, plottable)
    end
  end

  defp do_build_plot(checks, plottable) do
    max_value = Enum.max(plottable)
    min_value = Enum.min(plottable)
    # A flat series would divide by zero and, worse, exaggerate noise into a
    # mountain range; give it a floor to sit on instead.
    scale_max = max(max_value, 1)

    baseline = @height - @pad_bottom
    plot_width = @width - @pad_left - @pad_right
    plot_height = baseline - @pad_top

    count = length(checks)
    step = if count > 1, do: plot_width / (count - 1), else: plot_width

    coords =
      checks
      |> Enum.with_index()
      |> Enum.map(fn {check, index} ->
        value = check.response_time_ms || 0
        x = @pad_left + index * step
        y = baseline - value / scale_max * plot_height

        %{
          x: round2(x),
          y: round2(y),
          value: value,
          check: check,
          index: index,
          anchor: anchor_for(index, count)
        }
      end)

    %{
      width: @width,
      height: @height,
      pad_left: @pad_left,
      pad_right: @pad_right,
      pad_top: @pad_top,
      baseline: baseline,
      min_value: min_value,
      max_value: max_value,
      points: Enum.map_join(coords, " ", &"#{&1.x},#{&1.y}"),
      ticks: build_ticks(scale_max, baseline, plot_height),
      labelled: labelled_points(coords),
      slices: Enum.map(coords, &to_slice(&1, step))
    }
  end

  # Labelling every point would be unreadable; the current value and the worst
  # one are the two a reader actually looks for.
  defp labelled_points(coords) do
    latest = List.last(coords)
    worst = Enum.max_by(coords, & &1.value)

    [latest, worst]
    |> Enum.uniq_by(& &1.index)
    |> Enum.map(&Map.put(&1, :label, "#{&1.value} ms"))
  end

  # The hover target is the column around the point, but the end columns are
  # clamped to the plot: an overhanging rect would sit outside the viewBox and
  # swallow clicks on the axis labels.
  defp to_slice(coord, step) do
    left = max(coord.x - step / 2, @pad_left)
    right = min(coord.x + step / 2, @width - @pad_right)

    coord
    |> Map.put(:slice_x, round2(left))
    |> Map.put(:slice_width, round2(right - left))
    |> Map.put(:readout, "#{coord.value} ms · #{format_time(coord.check.inserted_at)}")
  end

  defp build_ticks(scale_max, baseline, plot_height) do
    for fraction <- [0.0, 0.5, 1.0] do
      %{
        y: round2(baseline - fraction * plot_height),
        label: round(scale_max * fraction)
      }
    end
  end

  # Float.round/2 rejects integers, and plenty of these coordinates land on
  # whole numbers, so coerce before rounding.
  defp round2(value), do: Float.round(value * 1.0, 2)

  # Keeps the first and last labels inside the plot instead of hanging off it.
  defp anchor_for(0, _count), do: "start"
  defp anchor_for(index, count) when index == count - 1, do: "end"
  defp anchor_for(_index, _count), do: "middle"

  defp uptime_bar_label([]), do: "No checks yet"

  defp uptime_bar_label(checks) do
    down = Enum.count(checks, &(&1.status == :down))
    "#{length(checks)} recent checks, #{down} of them failing"
  end

  @doc """
  Whether a check represents a failure, for the history strip.
  """
  def failed?(%Check{status: :down}), do: true
  def failed?(%Check{}), do: false
end
