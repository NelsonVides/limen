defmodule Limen.State.Gcra do
  @moduledoc """
  Lock-free [GCRA] (generic cell rate algorithm) rate limiting on ETS.

  GCRA was specified for ATM networks, to police the rate of cells on each
  connection. It is equivalent to a leaky bucket, but needs a single
  timestamp per key instead of a level and the time it was last updated.

  ## How it works

  A limit of `rate` requests per `period` spaces requests
  `T = period / rate` apart, the emission interval. Each key stores its
  theoretical arrival time (TAT): when it would next be due, had it sent at
  exactly that pace. A request moves the TAT to `max(TAT, now) + T`, and is
  admitted if that is at most `T * (burst + 1)` ahead of now, the burst
  tolerance. A client sending faster than the rate pushes its TAT further
  ahead until it is refused; one that pauses finds its TAT in the past and
  starts afresh.

  With 10 requests per second (`T` = 100 ms) and `burst: 2` (a tolerance of
  300 ms):

  | now | new TAT | ahead | result |
  |---|---|---|---|
  | 0 | 100 | 100 | admitted |
  | 0 | 200 | 200 | admitted |
  | 0 | 300 | 300 | admitted |
  | 0 | 400 | 400 | refused, retry in 100 ms |
  | 150 | 400 | 250 | admitted |
  | 2000 | 2100 | 100 | admitted, as a new key |

  Over any interval of length `Δ`, at most `Δ / T + burst + 1` requests are
  admitted. For more, see [Wikipedia][wiki], and [Rate limiting, cells, and
  GCRA][brandur], which compares it with other rate limiting algorithms.

  ## Implementation

  Each key stores a single integer, its TAT in microseconds of monotonic time,
  and is updated with one `:ets.update_counter/3` call that applies
  `TAT' = max(TAT, now) + T` atomically:

    1. `{2, -1, now, now - 1}` yields `max(TAT, now) - 1`: decrement, and if
       the result fell below `now`, reset it to `now - 1`;
    2. `{2, T + 1}` then yields `max(TAT, now) + T`.

  A rejected request rolls its increment back, so rejected traffic does not
  push the key further into the future.

  Keys whose TAT is in the past carry no information (a fresh key behaves the
  same), so `sweep/1` removes them. New keys are refused once the table holds
  `:gcra_max_keys` entries; they are then not limited.

  [GCRA]: https://www.itu.int/rec/T-REC-I.371
  [wiki]: https://en.wikipedia.org/wiki/Generic_cell_rate_algorithm
  [brandur]: https://brandur.org/rate-limiting
  """

  alias Limen.Instance

  @type result :: :ok | {:error, retry_after_ms :: pos_integer()}

  @doc """
  Checks and records one request for `key` against a limit of `rate` requests
  per `period` milliseconds with `burst` extra requests allowed at once.
  """
  @spec check(Instance.t(), term(), pos_integer(), pos_integer(), non_neg_integer(), integer()) ::
          result()
  def check(
        %Instance{} = instance,
        key,
        rate,
        period,
        burst,
        now \\ System.monotonic_time(:microsecond)
      )
      when rate > 0 and period > 0 and burst >= 0 do
    interval = max(div(period * 1_000, rate), 1)
    tolerance = interval * (burst + 1)
    %{table: table, size: size} = instance.state.gcra

    if :atomics.get(size, 1) < instance.config.state.gcra_max_keys and
         :ets.insert_new(table, {key, now + interval}) do
      :atomics.add(size, 1, 1)
      :ok
    else
      advance(instance, table, key, interval, tolerance, now)
    end
  end

  defp advance(instance, table, key, interval, tolerance, now) do
    [_clamped, tat] = :ets.update_counter(table, key, [{2, -1, now, now - 1}, {2, interval + 1}])

    if tat - now <= tolerance do
      :ok
    else
      _tat = :ets.update_counter(table, key, {2, -interval})
      {:error, max(div(tat - now - tolerance + 999, 1_000), 1)}
    end
  rescue
    # The table is full and does not track this key.
    ArgumentError ->
      Limen.Stats.incr(instance, :saturated)
      :ok
  end

  @doc """
  Forgets `key`.
  """
  @spec reset(Instance.t(), term()) :: :ok
  def reset(%Instance{state: %{gcra: %{table: table, size: size}}}, key) do
    if :ets.take(table, key) != [], do: :atomics.sub(size, 1, 1)
    :ok
  end

  @doc """
  Removes keys whose theoretical arrival time has passed and returns how many
  were removed.
  """
  @spec sweep(Instance.t(), integer()) :: non_neg_integer()
  def sweep(
        %Instance{state: %{gcra: %{table: table, size: size}}},
        now \\ System.monotonic_time(:microsecond)
      ) do
    swept = :ets.select_delete(table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    # Subtracted, not reset to the table's size, which would lose the keys
    # inserted meanwhile: every inserted key adds one.
    :atomics.sub(size, 1, swept)
    swept
  end
end
