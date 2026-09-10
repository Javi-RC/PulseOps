defmodule PulseOpsWeb.RateLimiterTest do
  use ExUnit.Case, async: true

  alias PulseOpsWeb.RateLimiter

  # The table is shared by the whole suite, so every test uses a key of its own.
  defp key, do: {:test, make_ref()}

  test "allows hits up to the limit and refuses the next one" do
    key = key()

    assert :ok = RateLimiter.hit(key, 3, 60_000)
    assert :ok = RateLimiter.hit(key, 3, 60_000)
    assert :ok = RateLimiter.hit(key, 3, 60_000)

    assert {:deny, retry_after_ms} = RateLimiter.hit(key, 3, 60_000)
    assert retry_after_ms > 0 and retry_after_ms <= 60_000
  end

  test "check says whether a hit would be refused without counting one" do
    key = key()

    assert :ok = RateLimiter.check(key, 2, 60_000)
    assert :ok = RateLimiter.check(key, 2, 60_000)
    assert :ok = RateLimiter.hit(key, 2, 60_000)
    assert :ok = RateLimiter.check(key, 2, 60_000)
    assert :ok = RateLimiter.hit(key, 2, 60_000)

    assert {:deny, _} = RateLimiter.check(key, 2, 60_000)
  end

  test "keys are counted separately" do
    busy = key()
    quiet = key()

    assert :ok = RateLimiter.hit(busy, 1, 60_000)
    assert {:deny, _} = RateLimiter.hit(busy, 1, 60_000)

    assert :ok = RateLimiter.hit(quiet, 1, 60_000)
  end

  test "a new window starts counting from zero" do
    key = key()

    assert :ok = RateLimiter.hit(key, 1, 1)
    # A one-millisecond window has certainly rolled over after a short sleep.
    Process.sleep(5)
    assert :ok = RateLimiter.hit(key, 1, 1)
  end

  test "sweeping drops windows that have ended and keeps the rest" do
    ended = key()
    current = key()

    assert :ok = RateLimiter.hit(ended, 1, 1)
    assert :ok = RateLimiter.hit(current, 1, 3_600_000)
    Process.sleep(5)

    RateLimiter.sweep()

    refute RateLimiter.tracked?(ended)
    assert RateLimiter.tracked?(current)
  end
end
