defmodule PulseOps.Monitoring.StatusMachineTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PulseOps.Monitoring.AlertRule
  alias PulseOps.Monitoring.StatusMachine

  defp rule(attrs \\ %{}) do
    struct!(AlertRule.default(), attrs)
  end

  defp run(machine, verdicts, rule) do
    Enum.reduce(verdicts, machine, &StatusMachine.advance(&2, &1, rule))
  end

  describe "classify/4" do
    test "a failed probe is down whatever it measured" do
      assert StatusMachine.classify(false, nil, 5_000, rule()) == :down
      assert StatusMachine.classify(false, 10, 5_000, rule()) == :down
    end

    test "a slow success is degraded, not down" do
      # degraded_ratio 0.5 of a 5s timeout: 2500ms and up.
      assert StatusMachine.classify(true, 2_499, 5_000, rule()) == :healthy
      assert StatusMachine.classify(true, 2_500, 5_000, rule()) == :degraded
    end

    test "a success with no measurement is healthy" do
      assert StatusMachine.classify(true, nil, 5_000, rule()) == :healthy
    end
  end

  describe "hysteresis" do
    test "going down needs the threshold met, not one bad probe" do
      r = rule(%{failure_threshold: 3})

      assert run(StatusMachine.new(:healthy), [:down], r).status == :healthy
      assert run(StatusMachine.new(:healthy), [:down, :down], r).status == :healthy
      assert run(StatusMachine.new(:healthy), [:down, :down, :down], r).status == :down
    end

    test "one success in the middle restarts the count" do
      r = rule(%{failure_threshold: 3})
      machine = run(StatusMachine.new(:healthy), [:down, :down, :healthy, :down, :down], r)

      assert machine.status == :healthy
      assert machine.consecutive_failures == 2
    end

    test "recovering needs the success threshold met" do
      r = rule(%{failure_threshold: 1, success_threshold: 2})
      down = run(StatusMachine.new(:healthy), [:down], r)

      assert down.status == :down
      assert run(down, [:healthy], r).status == :down
      assert run(down, [:healthy, :healthy], r).status == :healthy
    end

    test "degraded is reported immediately from healthy" do
      assert run(StatusMachine.new(:healthy), [:degraded], rule()).status == :degraded
    end
  end

  describe "reapply/3" do
    test "a lowered threshold takes effect on what was already counted" do
      lenient = rule(%{failure_threshold: 5})
      machine = run(StatusMachine.new(:healthy), [:down, :down], lenient)
      assert machine.status == :healthy

      assert StatusMachine.reapply(machine, :down, rule(%{failure_threshold: 2})).status == :down
    end

    test "does nothing when nothing has been observed" do
      machine = StatusMachine.new(:unknown)
      assert StatusMachine.reapply(machine, nil, rule(%{failure_threshold: 1})) == machine
    end
  end

  describe "properties" do
    defp verdicts, do: list_of(member_of(StatusMachine.check_statuses()), max_length: 60)

    defp rules do
      gen all(
            failure <- integer(1..5),
            success <- integer(1..5)
          ) do
        rule(%{failure_threshold: failure, success_threshold: success})
      end
    end

    property "the status is always one the system knows about" do
      check all(verdicts <- verdicts(), r <- rules()) do
        assert run(StatusMachine.new(:unknown), verdicts, r).status in StatusMachine.statuses()
      end
    end

    property "the two consecutive counters are never both running" do
      check all(verdicts <- verdicts(), r <- rules()) do
        machine = run(StatusMachine.new(:unknown), verdicts, r)
        assert machine.consecutive_failures == 0 or machine.consecutive_successes == 0
      end
    end

    # The invariant worth protecting is "a service never has two open incidents".
    # It is not asserted directly here, and deliberately so: an incident opens on
    # *entering* :down and closes on *leaving* it, so deriving entries and exits
    # from status changes makes them alternate by construction — a property
    # written that way passes no matter what the machine does. The database
    # holds that invariant for real (ADR-004).
    #
    # What is worth checking is the thing the invariant rests on: that the
    # machine only crosses the :down boundary when the thresholds say so. If
    # either of these can be violated, incidents open or close on a blip.

    property "entering :down always took failure_threshold consecutive failures" do
      check all(verdicts <- verdicts(), r <- rules()) do
        for {previous, machine} <- steps(verdicts, r),
            previous.status != :down and machine.status == :down do
          assert machine.consecutive_failures >= r.failure_threshold,
                 "went down on #{machine.consecutive_failures} failures, " <>
                   "threshold was #{r.failure_threshold}"
        end
      end
    end

    property "leaving :down always took success_threshold consecutive successes" do
      check all(verdicts <- verdicts(), r <- rules()) do
        for {previous, machine} <- steps(verdicts, r),
            previous.status == :down and machine.status != :down do
          assert machine.consecutive_successes >= r.success_threshold,
                 "recovered on #{machine.consecutive_successes} successes, " <>
                   "threshold was #{r.success_threshold}"
        end
      end
    end

    property "a run of failures shorter than the threshold never changes the status" do
      # The threshold is drawn first and the run length from it, rather than
      # generating both and filtering: filtering here throws away most of the
      # space and StreamData gives up before it finds enough cases.
      check all(
              status <- member_of([:healthy, :degraded]),
              failure <- integer(1..5),
              success <- integer(1..5),
              count <- integer(0..(failure - 1))
            ) do
        r = rule(%{failure_threshold: failure, success_threshold: success})
        machine = run(StatusMachine.new(status), List.duplicate(:down, count), r)

        assert machine.status == status,
               "#{count} failures moved a #{status} service with threshold #{failure}"
      end
    end
  end

  # Each step paired with the machine it came from, so a property can talk about
  # the moment a boundary was crossed rather than the end state.
  defp steps(verdicts, rule) do
    verdicts
    |> Enum.scan({StatusMachine.new(:unknown), StatusMachine.new(:unknown)}, fn verdict,
                                                                                {_prev, machine} ->
      {machine, StatusMachine.advance(machine, verdict, rule)}
    end)
  end
end
