defmodule Limen.Sketch.HyperLogLogTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Limen.Sketch.HyperLogLog

  property "estimates within four standard errors" do
    check all n <- integer(0..30_000), salt <- integer(), max_runs: 25 do
      sketch = HyperLogLog.new(12)
      for i <- 1..n//1, do: HyperLogLog.add(sketch, {salt, i})

      error = 4 * 1.04 / :math.sqrt(4096)
      assert abs(HyperLogLog.cardinality(sketch) - n) <= max(n * error, 2)
    end
  end

  # Where the original estimator hands over to counting empty registers, its
  # error doubled. The keys are fixed, so the result is too.
  test "holds the standard error around 2.5 × 2^precision keys" do
    errors =
      for run <- 1..20 do
        sketch = HyperLogLog.new(12)
        for i <- 1..10_000, do: HyperLogLog.add(sketch, {run, i})
        HyperLogLog.cardinality(sketch) / 10_000 - 1
      end

    rmse = :math.sqrt(Enum.sum(Enum.map(errors, &(&1 * &1))) / 20)
    assert rmse < 1.04 / :math.sqrt(4096) * 1.25
  end

  test "duplicates do not count" do
    sketch = HyperLogLog.new(10)
    for _round <- 1..5, i <- 1..1_000, do: HyperLogLog.add(sketch, i)
    assert_in_delta HyperLogLog.cardinality(sketch), 1_000, 1_000 * 0.15
  end

  test "estimates unions" do
    a = HyperLogLog.new(12)
    b = HyperLogLog.new(12)
    for i <- 1..5_000, do: HyperLogLog.add(a, i)
    for i <- 2_501..7_500, do: HyperLogLog.add(b, i)

    assert_in_delta HyperLogLog.cardinality([a, b]), 7_500, 7_500 * 0.1
  end

  test "is small and resettable" do
    sketch = HyperLogLog.new(12)
    assert HyperLogLog.memory(sketch) >= 4_096
    HyperLogLog.add(sketch, :x)
    HyperLogLog.reset(sketch)
    assert HyperLogLog.cardinality(sketch) == 0
  end

  test "concurrent writers leave the same registers as a single one" do
    sequential = HyperLogLog.new(10)
    concurrent = HyperLogLog.new(10)
    for i <- 1..40_000, do: HyperLogLog.add(sequential, i)

    1..40_000
    |> Enum.chunk_every(5_000)
    |> Task.async_stream(fn keys -> Enum.each(keys, &HyperLogLog.add(concurrent, &1)) end)
    |> Stream.run()

    assert registers(concurrent) == registers(sequential)
  end

  property "the union of sketches equals one sketch of every key" do
    check all a <- list_of(integer(), max_length: 3_000),
              b <- list_of(integer(), max_length: 3_000),
              max_runs: 25 do
      [sa, sb, both] = for _sketch <- 1..3, do: HyperLogLog.new(8)
      Enum.each(a, &HyperLogLog.add(sa, &1))
      Enum.each(b, &HyperLogLog.add(sb, &1))
      Enum.each(a ++ b, &HyperLogLog.add(both, &1))

      assert HyperLogLog.cardinality([sa, sb]) == HyperLogLog.cardinality(both)
    end
  end

  defp registers(%HyperLogLog{ref: ref}),
    do: for(i <- 1..:atomics.info(ref).size, do: :atomics.get(ref, i))
end
