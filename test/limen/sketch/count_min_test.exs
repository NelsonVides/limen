defmodule Limen.Sketch.CountMinTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Limen.Sketch.CountMin

  property "never undercounts" do
    check all counts <- list_of(integer(1..20), max_length: 300) do
      counts = Enum.with_index(counts, fn count, key -> {{:key, key}, count} end)
      sketch = CountMin.new(64, 4)

      for {key, count} <- counts, _time <- 1..count do
        CountMin.add(sketch, key)
      end

      for {key, count} <- counts do
        assert CountMin.estimate(sketch, key) >= count
      end
    end
  end

  test "overcounts within the error bound for almost every key" do
    epsilon = 0.001
    sketch = CountMin.new_with_error(epsilon, 0.01)
    keys = for n <- 1..20_000, do: {:key, n}
    Enum.each(keys, &CountMin.add(sketch, &1, 3))
    total = 3 * length(keys)

    within = Enum.count(keys, fn key -> CountMin.estimate(sketch, key) - 3 <= epsilon * total end)
    assert within / length(keys) >= 0.99
  end

  test "add returns the new estimate and reset clears it" do
    sketch = CountMin.new(1024, 3)
    assert CountMin.add(sketch, :a) == 1
    assert CountMin.add(sketch, :a, 4) == 5
    assert CountMin.estimate(sketch, :a) == 5
    assert CountMin.reset(sketch) == :ok
    assert CountMin.estimate(sketch, :a) == 0
  end

  test "memory is fixed by the dimensions" do
    assert CountMin.memory(CountMin.new(1024, 4)) >= 1024 * 4 * 8
  end

  test "concurrent writers lose no increment" do
    sketch = CountMin.new(1024, 4)

    1..8
    |> Task.async_stream(fn _writer -> for _add <- 1..10_000, do: CountMin.add(sketch, :hot) end)
    |> Stream.run()

    assert CountMin.estimate(sketch, :hot) == 80_000
  end
end
