defmodule Limen.State.WindowTest do
  use Limen.Case, async: true
  use ExUnitProperties

  alias Limen.State
  alias Limen.State.Window

  # Aligned to the start of an epoch of every window, and centuries ahead of
  # the clock the rotator runs on, so it never clears these epochs.
  @t0 3_600_000 * 5_000_000

  property "counts exactly below the cap", %{instance: instance} do
    check all events <- list_of(member_of([:a, :b, :c, :d]), max_length: 200) do
      State.reset(instance)
      Enum.each(events, &Window.incr(instance, :minute, &1, @t0 + 10))
      frequencies = Enum.frequencies(events)

      for key <- [:a, :b, :c, :d] do
        assert Window.count(instance, :minute, key, @t0 + 20) == Map.get(frequencies, key, 0)
      end
    end
  end

  test "incr returns the sliding estimate including the new event", %{instance: instance} do
    assert Window.incr(instance, :second, :k, @t0) == 1
    assert Window.incr(instance, :second, :k, @t0 + 1) == 2
  end

  test "the previous epoch is weighted by its overlap with the sliding window", %{
    instance: instance
  } do
    for _event <- 1..100, do: Window.incr(instance, :second, :k, @t0 + 500)

    assert Window.count(instance, :second, :k, @t0 + 999) == 100
    assert Window.count(instance, :second, :k, @t0 + 1_000) == 100
    assert Window.count(instance, :second, :k, @t0 + 1_250) == 75
    assert Window.count(instance, :second, :k, @t0 + 1_900) == 10
    assert Window.count(instance, :second, :k, @t0 + 2_000) == 0
  end

  test "rotation clears only epochs older than the current one", %{instance: instance} do
    Window.incr(instance, :second, :old, @t0)
    Window.incr(instance, :second, :fresh, @t0 + 3_000)

    # At epoch 3 the slot for epoch 4 holds epoch 1 data; rotate from epoch 3.
    Window.incr(instance, :second, :stale, @t0 + 1_000)
    assert Window.rotate(instance, :second, @t0 + 3_000) == 1

    assert Window.count(instance, :second, :fresh, @t0 + 3_000) == 1
    assert Window.count(instance, :second, :stale, @t0 + 1_000) == 0
  end

  test "rotation running late never drops counts of the new epoch", %{instance: instance} do
    # Epoch 4 starts; the rotator still thinks it is epoch 3 and targets the
    # slot epoch 4 now writes to.
    Window.incr(instance, :second, :k, @t0 + 4_000)
    Window.rotate(instance, :second, @t0 + 3_999)
    assert Window.count(instance, :second, :k, @t0 + 4_000) == 1
  end

  test "a row keeps several counts under one key", %{instance: instance} do
    assert Window.add(instance, :minute, :row, {1, 1, 0}, @t0) == {1, 1, 0}
    assert Window.add(instance, :minute, :row, {1, 0, 2}, @t0 + 1) == {2, 1, 2}
    assert Window.read(instance, :minute, :row, 3, @t0 + 2) == {2, 1, 2}
    assert Window.read(instance, :minute, :other, 3, @t0 + 2) == {0, 0, 0}
    assert :ets.info(State.table(instance, :minute, 0), :size) == 1
  end

  test "add_first tells when a row's first count turns positive in an epoch", %{
    instance: instance
  } do
    assert {{1, 0}, true} = Window.add_first(instance, :minute, :row, {1, 0}, @t0)
    assert {{2, 1}, false} = Window.add_first(instance, :minute, :row, {1, 1}, @t0 + 1)
    assert {_counts, true} = Window.add_first(instance, :minute, :row, {1, 0}, @t0 + 60_000)

    # A row opened by another count is not a first until its first count is.
    assert {{0, 1}, false} = Window.add_first(instance, :minute, :other, {0, 1}, @t0)
    assert {{1, 1}, true} = Window.add_first(instance, :minute, :other, {1, 0}, @t0)
  end

  @tag config: [state: [max_keys: 1]]
  test "add_first reports rows counted in the sketch as first", %{instance: instance} do
    Window.add(instance, :minute, :row, {1}, @t0)

    for _event <- 1..3 do
      assert {_counts, true} = Window.add_first(instance, :minute, :sketched, {1}, @t0)
    end
  end

  test "each count of a row slides on its own", %{instance: instance} do
    Window.add(instance, :second, :row, {100, 0, 40}, @t0 + 500)
    Window.add(instance, :second, :row, {1, 1, 0}, @t0 + 1_250)

    assert Window.read(instance, :second, :row, 3, @t0 + 1_250) == {76, 1, 30}
  end

  test "rotation clears rows", %{instance: instance} do
    Window.add(instance, :second, :stale, {1, 1}, @t0 + 1_000)
    Window.add(instance, :second, :fresh, {1, 1}, @t0 + 3_000)

    assert Window.rotate(instance, :second, @t0 + 3_000) == 1
    assert Window.read(instance, :second, :stale, 2, @t0 + 1_000) == {0, 0}
    assert Window.read(instance, :second, :fresh, 2, @t0 + 3_000) == {1, 1}
  end

  @tag config: [state: [max_keys: 3]]
  test "a row is one key towards the cap, and new rows of a full slot go to the sketch", %{
    instance: instance
  } do
    for n <- 1..3, _event <- 1..5, do: Window.add(instance, :minute, {:row, n}, {1, 0}, @t0)
    assert Window.add(instance, :minute, {:row, 1}, {1, 1}, @t0) == {6, 1}

    assert {count, 0} = Window.add(instance, :minute, {:row, 4}, {2, 0}, @t0)
    assert count >= 2
    assert {^count, 0} = Window.read(instance, :minute, {:row, 4}, 2, @t0)

    assert :ets.info(State.table(instance, :minute, 0), :size) == 3
    assert Limen.Stats.snapshot(instance).saturated == 1
  end

  @tag config: [state: [max_keys: 100]]
  test "a full slot counts new keys in the sketch and keeps existing ones exact", %{
    instance: instance
  } do
    for n <- 1..100, do: Window.incr(instance, :minute, {:k, n}, @t0)
    for n <- 101..5_000, do: Window.incr(instance, :minute, {:k, n}, @t0)
    for _event <- 1..9, do: Window.incr(instance, :minute, {:k, 1}, @t0)

    assert :ets.info(State.table(instance, :minute, 0), :size) == 100
    assert Window.count(instance, :minute, {:k, 1}, @t0) == 10
    assert Window.count(instance, :minute, {:k, 4_000}, @t0) >= 1
    assert Limen.Stats.snapshot(instance).saturated > 0
  end

  @tag config: [state: [max_keys: 1_000]]
  test "memory stays bounded under a flood of unique keys", %{instance: instance} do
    before = State.memory(instance)

    for n <- 1..50_000 do
      Window.incr(instance, :second, {:prefix, {6, n, 64}}, @t0)
    end

    after_flood = State.memory(instance)

    assert :ets.info(State.table(instance, :second, 0), :size) <=
             1_000 + System.schedulers_online()

    assert after_flood.sketches == before.sketches
  end

  test "top lists the heaviest exact keys of the current epoch", %{instance: instance} do
    for {key, count} <- [a: 3, b: 5, c: 1], _event <- 1..count do
      Window.incr(instance, :minute, {:test, key}, @t0)
    end

    Window.incr(instance, :minute, {:other, :z}, @t0)

    assert Window.top(instance, :minute, &match?({:test, _key}, &1), 2, @t0) == [
             {{:test, :b}, 5},
             {{:test, :a}, 3}
           ]
  end

  test "top ranks rows by one of their counts", %{instance: instance} do
    for {key, row} <- [a: {3, 1}, b: {1, 5}, c: {2, 2}] do
      Window.add(instance, :minute, {:test, key}, row, @t0)
    end

    for _event <- 1..4, do: Window.incr(instance, :minute, {:test, :d}, @t0)
    test? = &match?({:test, _key}, &1)

    assert Window.top(instance, :minute, test?, 3, @t0) == [
             {{:test, :d}, 4},
             {{:test, :a}, 3},
             {{:test, :c}, 2}
           ]

    assert Window.top(instance, :minute, test?, 1, @t0, 2) == [{{:test, :b}, 5}]
  end
end
