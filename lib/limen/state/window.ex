defmodule Limen.State.Window do
  @moduledoc """
  Sliding-window request counters.

  Time is cut into epochs of the window's duration. Each window has three
  slots used round-robin: the current epoch, the previous one, and one being
  cleared by `Limen.State.Rotator`. Clearing a whole slot replaces per-entry
  TTL scans. Keys carry their epoch, so a slot that is cleared late can never
  leak counts into a newer epoch.

  The rate over the last window is estimated from the current and previous
  epochs, weighting the previous one by how much of it still overlaps the
  sliding window:

      estimate = current + previous × (duration - elapsed) / duration

  Each slot counts up to `:max_keys` keys exactly. After that, new keys are
  counted in the slot's Count-Min Sketch, whose estimates may overcount but
  never undercount.
  """

  alias Limen.Instance
  alias Limen.Sketch.CountMin
  alias Limen.State

  @type window :: State.window()

  @doc """
  Counts one event for `key` at `now` (milliseconds) and returns the sliding
  estimate including it.
  """
  @spec incr(Instance.t(), window(), term(), integer()) :: non_neg_integer()
  def incr(%Instance{} = instance, window, key, now) do
    duration = State.duration(window)
    epoch = div(now, duration)
    slots = slots(instance, window)
    current = incr_slot(instance, slots, key, epoch)
    previous = read_slot(slots, key, epoch - 1)
    current + weigh(previous, now, duration)
  end

  @doc """
  Returns the sliding estimate for `key` at `now` without counting.
  """
  @spec count(Instance.t(), window(), term(), integer()) :: non_neg_integer()
  def count(%Instance{} = instance, window, key, now) do
    duration = State.duration(window)
    epoch = div(now, duration)
    slots = slots(instance, window)
    current = read_slot(slots, key, epoch)
    previous = read_slot(slots, key, epoch - 1)
    current + weigh(previous, now, duration)
  end

  @doc """
  Returns the exact counts of the current epoch, largest first.

  Scans the slot, so it is meant for dashboards, not for the request path.
  Keys counted in the sketch are not included.
  """
  @spec top(Instance.t(), window(), (term() -> boolean()), pos_integer(), integer()) :: [
          {term(), pos_integer()}
        ]
  def top(%Instance{} = instance, window, filter, limit, now) do
    epoch = div(now, State.duration(window))
    %{tables: tables} = slots(instance, window)

    tables
    |> elem(rem(epoch, State.slots()))
    |> :ets.select([{{{:"$1", epoch}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {key, _count} -> filter.(key) end)
    |> Enum.sort_by(fn {_key, count} -> count end, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Clears the slot that the next epoch will use.

  Only entries older than `epoch` are removed, so running late (after the
  next epoch started) never drops fresh counts.
  """
  @spec rotate(Instance.t(), window(), integer()) :: non_neg_integer()
  def rotate(%Instance{} = instance, window, now) do
    epoch = div(now, State.duration(window))
    slot = rem(epoch + 1, State.slots())
    %{tables: tables, counts: counts, sketches: sketches} = slots(instance, window)
    table = elem(tables, slot)

    cleared = :ets.select_delete(table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", epoch}], [true]}])
    :atomics.put(counts, slot + 1, :ets.info(table, :size))
    CountMin.reset(elem(sketches, slot))
    cleared
  end

  defp slots(
         %Instance{state: %{windows: windows}, config: %{state: %{max_keys: max_keys}}},
         window
       ) do
    Map.put(Map.fetch!(windows, window), :max_keys, max_keys)
  end

  defp incr_slot(instance, %{max_keys: max_keys} = slots, key, epoch) do
    slot = rem(epoch, State.slots())
    table = elem(slots.tables, slot)
    entry = {key, epoch}

    if :atomics.get(slots.counts, slot + 1) < max_keys do
      case :ets.update_counter(table, entry, 1, {entry, 0}) do
        1 ->
          :atomics.add(slots.counts, slot + 1, 1)
          1

        n ->
          n
      end
    else
      incr_saturated(instance, table, entry, elem(slots.sketches, slot))
    end
  end

  defp incr_saturated(instance, table, entry, sketch) do
    if :ets.member(table, entry) do
      :ets.update_counter(table, entry, 1)
    else
      Limen.Stats.incr(instance, :saturated)
      CountMin.add(sketch, entry)
    end
  rescue
    # The entry was cleared between the membership check and the update,
    # which only happens to entries of an expired epoch.
    ArgumentError -> CountMin.add(sketch, entry)
  end

  # The sketch only holds counts once a slot has filled up, so a miss in a
  # slot that never did is an exact zero.
  defp read_slot(
         %{tables: tables, counts: counts, sketches: sketches, max_keys: max_keys},
         key,
         epoch
       ) do
    slot = rem(epoch, State.slots())

    # A stored count is at least 1, so 0 means the key is not in the slot.
    case :ets.lookup_element(elem(tables, slot), {key, epoch}, 2, 0) do
      0 ->
        if :atomics.get(counts, slot + 1) >= max_keys,
          do: CountMin.estimate(elem(sketches, slot), {key, epoch}),
          else: 0

      n when is_integer(n) ->
        n
    end
  end

  defp weigh(0, _now, _duration), do: 0

  defp weigh(previous, now, duration) do
    div(previous * (duration - rem(now, duration)), duration)
  end
end
