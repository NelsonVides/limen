defmodule Limen.Signal.Asn.ScheduleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Limen.Signal.Asn.Schedule

  @hour 3_600_000
  @day 24 * @hour
  # Noon, UTC.
  @noon 1_790_424_000_000

  defp config(overrides \\ []) do
    Map.merge(%{every: @day, jitter: 0.0, window: nil, retry: 10 * 60_000}, Map.new(overrides))
  end

  # Delays from noon, where every test starts.
  defp next_check(checked_at, config, random),
    do: Schedule.next_check(@noon, checked_at, config, random) - @noon

  defp retry_failed(failures, config, random),
    do: Schedule.retry_failed(@noon, failures, config, random) - @noon

  defp retry_postponed(config, random),
    do: Schedule.retry_postponed(@noon, config, random) - @noon

  defp time_of_day(at),
    do: Time.truncate(Time.add(~T[00:00:00], Integer.mod(at, @day), :millisecond), :second)

  describe "after a check" do
    test "waits `:every` since the last check" do
      assert next_check(@noon, config(), 0.5) == @day
      assert next_check(@noon - @hour, config(), 0.5) == @day - @hour
    end

    test "checks at once without data, whatever the window" do
      window = [{~T[01:00:00], ~T[02:00:00]}]
      assert next_check(nil, config(window: window), 0.5) == 0
    end

    test "runs an overdue check after the random delay alone" do
      assert next_check(@noon - 3 * @day, config(), 0.9) == 0

      assert next_check(@noon - 3 * @day, config(jitter: 0.1), 0.5) ==
               div(@day, 20)
    end

    property "adds up to `:jitter` of `:every` at random" do
      check all random <- float(min: 0.0, max: 0.999_999), jitter <- float(min: 0.0, max: 1.0) do
        delay = next_check(@noon, config(jitter: jitter), random)
        assert delay >= @day
        assert delay <= @day + @day * jitter
      end
    end
  end

  describe "windows" do
    property "scheduled checks always fall inside a window" do
      check all from <- integer(0..23),
                length <- integer(1..23),
                last <- integer((-3 * @day)..0),
                random <- float(min: 0.0, max: 0.999_999),
                jitter <- float(min: 0.0, max: 0.5) do
        from = Time.new!(from, 0, 0)
        window = [{from, Time.add(from, length * @hour, :millisecond)}]
        config = config(window: window, jitter: jitter)
        at = @noon + next_check(@noon + last, config, random)

        assert at >= @noon
        assert Schedule.in_window?(at, window)
      end
    end

    test "move a check outside them into the next one" do
      window = [{~T[01:00:00], ~T[05:00:00]}]
      at = @noon + next_check(@noon, config(window: window), 0.0)

      # Due tomorrow at noon, outside the window: the day after, as it opens.
      assert at - @noon == 2 * @day - 11 * @hour
      assert time_of_day(at) == ~T[01:00:00]

      at = @noon + next_check(@noon, config(window: window), 0.5)
      assert time_of_day(at) == ~T[03:00:00]
    end

    test "can run over midnight" do
      window = [{~T[22:00:00], ~T[02:00:00]}]
      assert Schedule.in_window?(@noon + 11 * @hour, window)
      assert Schedule.in_window?(@noon + 13 * @hour, window)
      refute Schedule.in_window?(@noon + 15 * @hour, window)

      at = @noon + next_check(@noon, config(window: window), 0.75)
      assert time_of_day(at) == ~T[01:00:00]
    end

    test "pick the window that opens first" do
      windows = [{~T[20:00:00], ~T[21:00:00]}, {~T[13:00:00], ~T[14:00:00]}]
      assert retry_postponed(config(window: windows), 0.0) == @hour
    end
  end

  describe "retries" do
    test "back off from `:retry`, doubling up to `:every`" do
      config = config(retry: 60_000, every: @hour)

      assert Enum.map(1..8, &retry_failed(&1, config, 0.5)) ==
               [60_000, 120_000, 240_000, 480_000, 960_000, 1_920_000, @hour, @hour]

      assert retry_failed(1_000, config, 0.5) == @hour
    end

    test "try a postponed check again after `:retry`" do
      assert retry_postponed(config(), 0.5) == 10 * 60_000
    end
  end
end
