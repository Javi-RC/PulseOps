defmodule PulseOps.Monitoring.RollupTest do
  use ExUnit.Case, async: true

  alias PulseOps.Monitoring.Rollup

  # Cumulative counts: 10 checks at or under 25ms, 20 at or under 50ms, and so
  # on, for 100 measured checks in total.
  defp histogram do
    %{25 => 10, 50 => 20, 100 => 60, 250 => 90, 500 => 98, 1000 => 100, 2500 => 100, 5000 => 100}
  end

  describe "percentile/4" do
    test "interpolates inside the bucket the rank lands in" do
      # Rank 50 lands in the 50–100ms bucket, which holds 40 observations
      # (20 → 60). It is 30 of those in, so 75% across: 50 + 0.75 * 50.
      assert Rollup.percentile(histogram(), 100, 0.5, 900) == 88
    end

    test "estimates a high percentile from the sparse tail" do
      # Rank 95 lands in the 250–500ms bucket, 5 of its 8 observations in:
      # 250 + 0.625 * 250.
      assert Rollup.percentile(histogram(), 100, 0.95, 900) == 406
    end

    test "never reports more than the largest response actually seen" do
      assert Rollup.percentile(histogram(), 100, 0.99, 260) == 260
    end

    test "falls back to the maximum when the rank is above the last bound" do
      # Everything measured was slower than 5s, so the histogram says nothing
      # about the shape and the maximum is the only honest answer.
      above = Map.new(Rollup.bounds(), &{&1, 0})

      assert Rollup.percentile(above, 10, 0.95, 9_000) == 9_000
    end

    test "is nil when nothing was measured" do
      assert Rollup.percentile(histogram(), 0, 0.5, nil) == nil
      assert Rollup.percentile(histogram(), 10, 0.5, nil) == nil
    end
  end

  describe "bounds/0" do
    test "are ascending, which the interpolation relies on" do
      assert Rollup.bounds() == Enum.sort(Rollup.bounds())
    end
  end
end
