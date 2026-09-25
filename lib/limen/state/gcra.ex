defmodule Limen.State.Gcra do
  @moduledoc """
  Lock-free GCRA (generic cell rate algorithm) rate limiting on ETS.

  A limit of `rate` requests per `period` with a `burst` allowance admits a
  request when the key's theoretical arrival time (TAT) is no further ahead
  of now than the burst tolerance allows. Over any interval of length `Δ`,
  at most `Δ / T + burst + 1` requests are admitted, where
  `T = period / rate` is the emission interval.

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
    :atomics.put(size, 1, :ets.info(table, :size))
    swept
  end
end
