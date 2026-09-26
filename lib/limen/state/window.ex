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

  A key holds one count (`incr/4`, `count/4`) or a row of several (`add/5`,
  `read/5`). A row keeps counts about the same subject together: updating
  any of them costs one table update and one lookup of the previous epoch,
  and returns all of them.

  Each slot counts up to `:max_keys` keys exactly, a row being one key. After
  that, new keys are counted in the slot's Count-Min Sketch
  (`Limen.Sketch.CountMin`), whose estimates may overcount but never
  undercount.
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
  Adds `increments` to the row of counts of `key` at `now` (milliseconds)
  and returns the sliding estimate of every count, including them.

  `increments` has one non-negative integer per count, at least one of them
  positive. A key's rows always have the same number of counts.
  """
  @spec add(Instance.t(), window(), term(), tuple(), integer()) :: tuple()
  def add(%Instance{} = instance, window, key, increments, now) do
    duration = State.duration(window)
    epoch = div(now, duration)
    slots = slots(instance, window)
    current = add_row(instance, slots, key, Tuple.to_list(increments), epoch)
    previous = read_row(slots, key, tuple_size(increments), epoch - 1)
    slide(current, previous, now, duration)
  end

  @doc """
  Returns the sliding estimates of the `width` counts in the row of `key` at
  `now` without counting.
  """
  @spec read(Instance.t(), window(), term(), pos_integer(), integer()) :: tuple()
  def read(%Instance{} = instance, window, key, width, now) do
    duration = State.duration(window)
    epoch = div(now, duration)
    slots = slots(instance, window)
    current = read_row(slots, key, width, epoch)
    previous = read_row(slots, key, width, epoch - 1)
    slide(current, previous, now, duration)
  end

  @doc """
  Returns the exact counts of the current epoch, largest first.

  Keys for which `filter` returns `true` are ranked by their count, and rows
  by their count in `column`, from 1.

  Scans the slot, so it is meant for dashboards, not for the request path.
  Keys counted in the sketch are not included.
  """
  @spec top(
          Instance.t(),
          window(),
          (term() -> boolean()),
          pos_integer(),
          integer(),
          pos_integer()
        ) ::
          [{term(), non_neg_integer()}]
  def top(%Instance{} = instance, window, filter, limit, now, column \\ 1) do
    epoch = div(now, State.duration(window))
    %{tables: tables} = slots(instance, window)
    entry = {:element, 1, :"$1"}
    guards = [{:==, {:element, 2, entry}, epoch}, {:>, {:tuple_size, :"$1"}, column}]

    tables
    |> elem(rem(epoch, State.slots()))
    |> :ets.select([{:"$1", guards, [{{{:element, 1, entry}, {:element, column + 1, :"$1"}}}]}])
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

    # Matches entries of any width by the epoch in their key.
    older = [{:"$1", [{:<, {:element, 2, {:element, 1, :"$1"}}, epoch}], [true]}]
    cleared = :ets.select_delete(table, older)
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

  defp add_row(instance, %{max_keys: max_keys} = slots, key, increments, epoch) do
    slot = rem(epoch, State.slots())
    table = elem(slots.tables, slot)
    entry = {key, epoch}
    # An increment of zero reads a count without changing it, so the update
    # returns the whole row.
    ops = Enum.with_index(increments, fn increment, n -> {n + 2, increment} end)

    if :atomics.get(slots.counts, slot + 1) < max_keys do
      default = List.to_tuple([entry | Enum.map(increments, fn _increment -> 0 end)])
      counts = :ets.update_counter(table, entry, ops, default)
      # A row that existed already held a positive count, so only a new row
      # comes back equal to the increments.
      if counts == increments, do: :atomics.add(slots.counts, slot + 1, 1)
      counts
    else
      add_saturated(instance, table, entry, ops, increments, elem(slots.sketches, slot))
    end
  end

  defp add_saturated(instance, table, entry, ops, increments, sketch) do
    if :ets.member(table, entry) do
      :ets.update_counter(table, entry, ops)
    else
      Limen.Stats.incr(instance, :saturated)
      add_sketch(sketch, entry, increments)
    end
  rescue
    # The entry was cleared between the membership check and the update,
    # which only happens to entries of an expired epoch.
    ArgumentError -> add_sketch(sketch, entry, increments)
  end

  defp add_sketch(sketch, entry, increments) do
    increments
    |> Enum.with_index(1)
    |> Enum.map(fn
      {0, n} -> CountMin.estimate(sketch, {entry, n})
      {increment, n} -> CountMin.add(sketch, {entry, n}, increment)
    end)
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

  defp read_row(
         %{tables: tables, counts: counts, sketches: sketches, max_keys: max_keys},
         key,
         width,
         epoch
       ) do
    slot = rem(epoch, State.slots())
    entry = {key, epoch}

    case :ets.lookup(elem(tables, slot), entry) do
      [row] ->
        tl(Tuple.to_list(row))

      [] ->
        if :atomics.get(counts, slot + 1) >= max_keys,
          do: estimate_row(elem(sketches, slot), entry, width),
          else: List.duplicate(0, width)
    end
  end

  defp estimate_row(sketch, entry, width),
    do: for(n <- 1..width, do: CountMin.estimate(sketch, {entry, n}))

  defp slide(current, previous, now, duration) do
    current
    |> Enum.zip_with(previous, fn count, previous -> count + weigh(previous, now, duration) end)
    |> List.to_tuple()
  end

  defp weigh(0, _now, _duration), do: 0

  defp weigh(previous, now, duration) do
    div(previous * (duration - rem(now, duration)), duration)
  end
end
