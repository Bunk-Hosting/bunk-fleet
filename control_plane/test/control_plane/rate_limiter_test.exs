defmodule ControlPlane.RateLimiterTest do
  # The RateLimiter's ETS table is owned by the app-supervised GenServer, which is
  # running in the test env. Each test uses a unique key so counters don't collide.
  # async: false — ConnCase's per-test RateLimiter.reset() clears the shared ETS
  # table, which would wipe this test's in-flight counters; running in the sync
  # phase keeps it isolated from those resets.
  use ExUnit.Case, async: false

  alias ControlPlane.RateLimiter

  defp unique_key, do: "test-#{System.unique_integer([:positive])}"

  test "allows up to max hits in a window, then rate-limits" do
    key = unique_key()

    # max = 3: the first three are allowed, the fourth is limited.
    assert RateLimiter.hit(key, 3, 60_000) == :ok
    assert RateLimiter.hit(key, 3, 60_000) == :ok
    assert RateLimiter.hit(key, 3, 60_000) == :ok
    assert RateLimiter.hit(key, 3, 60_000) == {:error, :rate_limited}
    assert RateLimiter.hit(key, 3, 60_000) == {:error, :rate_limited}
  end

  test "counts each key independently" do
    a = unique_key()
    b = unique_key()

    assert RateLimiter.hit(a, 1, 60_000) == :ok
    assert RateLimiter.hit(a, 1, 60_000) == {:error, :rate_limited}
    # b has its own budget, untouched by a.
    assert RateLimiter.hit(b, 1, 60_000) == :ok
  end

  test "a new window resets the counter" do
    key = unique_key()

    # A 1ms window means consecutive calls almost always land in fresh windows, so
    # the limit effectively never trips across distinct windows.
    assert RateLimiter.hit(key, 1, 1) == :ok
    Process.sleep(2)
    assert RateLimiter.hit(key, 1, 1) == :ok
  end
end
