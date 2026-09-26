defmodule Limen.Signal.Asn.Schedule do
  @moduledoc """
  When the ASN loader checks for new data, as pure functions of the time.

  A check is due `:every` milliseconds after the last successful one, plus a
  random delay of up to `:jitter` times `:every`, so nodes that started
  together do not check together. The last successful check is the time the
  data file was last confirmed current, so restarting a node does not
  postpone its next check. A check that is already overdue runs after the
  random delay alone.

  With `:window`, checks only run inside the given times of day (UTC): a
  check due outside them moves to a random time inside the next window, so
  nodes spread over it rather than all starting as it opens.

  A failed check is retried after `:retry` milliseconds, doubling with every
  consecutive failure up to `:every`; a postponed one after `:retry`. Both
  also respect the window.

  Every function returns the time of the next check, in milliseconds since
  the epoch. `random` arguments are floats in `[0, 1)`, drawn by the caller,
  so these functions are deterministic.
  """

  @day 86_400_000

  @typedoc """
  The `:refresh` options of the `:asn` configuration, see `Limen.Config`.
  """
  @type config :: %{
          required(:every) => pos_integer(),
          required(:jitter) => number(),
          required(:window) => [{Time.t(), Time.t()}] | nil,
          required(:retry) => pos_integer(),
          optional(:max_utilization) => number() | nil,
          optional(:max_memory) => pos_integer() | nil,
          optional(:timeout) => pos_integer()
        }

  @doc """
  When to check after a successful check at `checked_at`.

  With no successful check yet (`nil`), there is no data to wait with, so the
  check is due `now`, whatever the window.
  """
  @spec next_check(integer(), integer() | nil, config(), float()) :: integer()
  def next_check(now, nil, _config, _random) when is_integer(now), do: now

  def next_check(now, checked_at, config, random)
      when is_integer(now) and is_integer(checked_at) do
    due = max(checked_at + config.every, now) + trunc(config.every * config.jitter * random)
    within_window(due, config.window, random)
  end

  @doc """
  When to retry after `failures` consecutive failed checks.
  """
  @spec retry_failed(integer(), pos_integer(), config(), float()) :: integer()
  def retry_failed(now, failures, config, random) when is_integer(now) do
    delay = min(config.retry * Integer.pow(2, min(failures - 1, 30)), config.every)
    within_window(now + delay, config.window, random)
  end

  @doc """
  When to try a postponed check again.
  """
  @spec retry_postponed(integer(), config(), float()) :: integer()
  def retry_postponed(now, config, random) when is_integer(now),
    do: within_window(now + config.retry, config.window, random)

  @doc """
  Whether the time `at` (milliseconds since the epoch) is inside one of
  `windows`. Always true without windows.
  """
  @spec in_window?(integer(), [{Time.t(), Time.t()}] | nil) :: boolean()
  def in_window?(_at, nil), do: true
  def in_window?(at, windows), do: Enum.any?(windows, &inside?(time_of_day(at), &1))

  # `at` itself when inside a window, otherwise a random time in the window
  # that opens next.
  defp within_window(at, windows, random) do
    if in_window?(at, windows) do
      at
    else
      windows
      |> Enum.map(&next_opening(at, &1))
      |> Enum.min()
      |> within(random)
    end
  end

  defp within({opens, length}, random) when is_integer(opens) and is_integer(length),
    do: opens + trunc(length * random)

  defp next_opening(at, {from, to}) do
    from = milliseconds(from)
    day_start = at - time_of_day(at)
    opens = if day_start + from > at, do: day_start + from, else: day_start + @day + from
    {opens, Integer.mod(milliseconds(to) - from, @day)}
  end

  # A window whose end is before its start runs over midnight.
  defp inside?(time, {from, to}) do
    {from, to} = {milliseconds(from), milliseconds(to)}
    if from < to, do: time >= from and time < to, else: time >= from or time < to
  end

  defp time_of_day(at), do: Integer.mod(at, @day)

  defp milliseconds(%Time{} = time), do: div(Time.diff(time, ~T[00:00:00], :microsecond), 1_000)
end
