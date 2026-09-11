defmodule PulseOpsWeb.MonitoringComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import PulseOpsWeb.MonitoringComponents

  alias PulseOps.Monitoring.Check

  defp check(status, ms, offset_seconds \\ 0) do
    %Check{
      status: status,
      response_time_ms: ms,
      http_status: if(status == :down, do: nil, else: 200),
      inserted_at: DateTime.add(DateTime.utc_now(), -offset_seconds, :second)
    }
  end

  defp series(values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {ms, index} -> check(:healthy, ms, length(values) - index) end)
  end

  defp chart(checks) do
    render_component(&response_time_chart/1, id: "chart", checks: checks)
  end

  describe "status_badge/1" do
    test "carries the status as shape and word, not colour alone" do
      html = render_component(&status_badge/1, status: :down)

      assert html =~ "Down"
      assert html =~ "var(--color-error)"
      # A distinct icon per status, so the badge still reads in greyscale.
      assert html =~ "lucide-circle-x"
    end

    test "gives each status its own icon" do
      icons =
        for status <- [:healthy, :degraded, :down, :unknown] do
          [_full, icon] =
            Regex.run(~r/(lucide-[a-z-]+)/, render_component(&status_badge/1, status: status))

          icon
        end

      assert length(Enum.uniq(icons)) == 4
    end

    test "falls back to unknown for an unrecognised status" do
      assert render_component(&status_badge/1, status: nil) =~ "Unknown"
    end
  end

  describe "response_time_chart/1" do
    test "says so instead of drawing a line through one point" do
      html = chart([check(:healthy, 100)])

      assert html =~ "Not enough data"
      refute html =~ "<polyline"
    end

    test "handles a series with no timings at all" do
      html = chart([check(:down, nil), check(:down, nil)])

      assert html =~ "Not enough data"
    end

    test "plots every point inside the viewBox" do
      html = chart(series([10, 250, 90, 1_000, 30]))

      assert [_full, points] = Regex.run(~r/<polyline\s+points="([^"]+)"/, html)

      coords =
        points
        |> String.split(" ", trim: true)
        |> Enum.map(fn pair ->
          [x, y] = String.split(pair, ",")
          {String.to_float(x), String.to_float(y)}
        end)

      assert length(coords) == 5

      # No NaN or infinity leaking into the markup, and nothing drawn outside
      # the plot area.
      for {x, y} <- coords do
        assert x >= 0 and x <= 720
        assert y >= 0 and y <= 220
      end
    end

    test "puts the tallest value at the top of the plot and the smallest below it" do
      html = chart(series([10, 1_000]))

      [_full, points] = Regex.run(~r/<polyline\s+points="([^"]+)"/, html)
      [first, last] = String.split(points, " ", trim: true)

      [_x1, y1] = String.split(first, ",")
      [_x2, y2] = String.split(last, ",")

      # SVG y grows downwards, so the larger value must have the smaller y.
      assert String.to_float(y2) < String.to_float(y1)
    end

    test "survives a completely flat series" do
      html = chart(series([100, 100, 100, 100]))

      assert html =~ "<polyline"
      refute html =~ "NaN"
    end

    test "labels only the latest and the worst reading" do
      html = chart(series([10, 900, 20, 30, 40]))

      # A number on every point would be unreadable; these are the two a reader
      # actually looks for. Direct labels are the bold ones — the rest of the
      # values only appear in the hover readout and the table.
      bold_labels = Regex.scan(~r/font-weight="600"[^>]*>\s*([^<]+?)\s*</, html)

      assert Enum.map(bold_labels, &List.last/1) |> Enum.sort() == ["40 ms", "900 ms"]
    end

    test "keeps the hover targets inside the plot area" do
      html = chart(series([10, 20, 30, 40]))

      rects = Regex.scan(~r/class="viz-hit" x="([-\d.]+)"[^>]*width="([\d.]+)"/, html)
      assert length(rects) == 4

      for [_full, x, width] <- rects do
        x = String.to_float(x)
        # An overhanging column would sit outside the viewBox and cover the
        # axis labels.
        assert x >= 48
        assert x + String.to_float(width) <= 704
      end
    end

    test "ships a table view so no value is hover-only" do
      html = chart(series([10, 20, 30]))

      assert html =~ "View as table"
      assert html =~ "<table"
      # Newest first in the table, matching how people read a log.
      assert html =~ "30 ms"
      assert html =~ "10 ms"
    end

    test "carries a text description for screen readers" do
      html = chart(series([10, 20, 30]))

      assert html =~ ~s(role="img")
      assert html =~ "Response time over the last 3 checks"
    end

    test "uses solid gridlines, never dashed" do
      html = chart(series([10, 20, 30]))

      refute html =~ "stroke-dasharray"
    end

    test "declares both themes rather than flipping colours automatically" do
      html = chart(series([10, 20, 30]))

      assert html =~ "prefers-color-scheme: dark"
      assert html =~ ~s([data-theme="dark"])
    end
  end

  describe "uptime_bar/1" do
    test "describes itself for screen readers" do
      html = render_component(&uptime_bar/1, checks: [check(:healthy, 10), check(:down, nil)])

      assert html =~ "2 recent checks, 1 of them failing"
    end

    test "says when there is nothing yet" do
      assert render_component(&uptime_bar/1, checks: []) =~ "No checks yet"
    end
  end

  describe "formatting" do
    test "format_percent/1" do
      assert format_percent(nil) == "—"
      assert format_percent(99.987) == "99.99%"
      assert format_percent(100.0) == "100.00%"
    end

    test "format_ms/1" do
      assert format_ms(nil) == "—"
      assert format_ms(42) == "42 ms"
    end

    test "format_duration/1" do
      assert format_duration(45) == "45s"
      assert format_duration(90) == "1m 30s"
      assert format_duration(3_700) == "1h 1m"
    end

    test "format_relative/1" do
      now = DateTime.utc_now()

      assert format_relative(nil) == "never"
      assert format_relative(now) == "just now"
      assert format_relative(DateTime.add(now, -300, :second)) == "5 min ago"
      assert format_relative(DateTime.add(now, -7_200, :second)) == "2 h ago"
    end
  end
end
