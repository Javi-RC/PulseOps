defmodule PulseOps.BoundaryTest do
  @moduledoc """
  The domain does not reach into the web layer. `PulseOpsWeb` depends on
  `PulseOps`, never the other way round, so the contexts stay usable from a job,
  a release task or a console without dragging the endpoint along.

  Read from the source rather than from xref: it is cheap, it runs with the
  suite, and the failure names the file and line to fix.
  """

  use ExUnit.Case, async: true

  # The application module is the one place both layers legitimately meet: it
  # starts the endpoint and its telemetry.
  @allowed ["lib/pulse_ops/application.ex"]

  test "no domain module refers to PulseOpsWeb" do
    offenders =
      for path <- Path.wildcard("lib/pulse_ops/**/*.ex"),
          path not in @allowed,
          {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          String.contains?(line, "PulseOpsWeb"),
          do: "#{path}:#{number}: #{String.trim(line)}"

    assert offenders == [], "the domain refers to the web layer:\n" <> Enum.join(offenders, "\n")
  end
end
