defmodule Limen.State.GcraTest do
  use Limen.Case, async: true
  use ExUnitProperties

  alias Limen.State.Gcra

  # A reference GCRA: admits a request when max(tat, now) + T - now <= tolerance.
  defp model(times, interval, tolerance) do
    {decisions, _tat} =
      Enum.map_reduce(times, nil, fn now, tat ->
        candidate = max(tat || now, now) + interval

        if candidate - now <= tolerance do
          {:ok, candidate}
        else
          {:error, tat}
        end
      end)

    decisions
  end

  defp arrivals do
    gen all gaps <- list_of(integer(0..400_000), min_length: 1, max_length: 60) do
      Enum.scan(gaps, 1_000_000_000, &(&1 + &2))
    end
  end

  property "matches a reference GCRA for sequential requests", %{instance: instance} do
    check all rate <- integer(1..20),
              period <- member_of([1_000, 10_000, 60_000]),
              burst <- integer(0..5),
              times <- arrivals() do
      key = make_ref()
      interval = div(period * 1_000, rate)
      tolerance = interval * (burst + 1)

      results = Enum.map(times, &(Gcra.check(instance, key, rate, period, burst, &1) == :ok))
      expected = Enum.map(model(times, interval, tolerance), &(&1 == :ok))
      assert results == expected
    end
  end

  property "never admits more than Δ/T + burst + 1 requests in any interval", %{
    instance: instance
  } do
    check all rate <- integer(1..10), burst <- integer(0..3), times <- arrivals() do
      key = make_ref()
      interval = div(1_000_000, rate)
      admitted = Enum.filter(times, &(Gcra.check(instance, key, rate, 1_000, burst, &1) == :ok))

      for {first, i} <- Enum.with_index(admitted), last <- Enum.drop(admitted, i) do
        count = Enum.count(admitted, &(&1 >= first and &1 <= last))
        assert count <= div(last - first, interval) + burst + 1
      end
    end
  end

  test "a steady stream at the limit is always admitted", %{instance: instance} do
    key = make_ref()
    for n <- 0..99, do: assert(Gcra.check(instance, key, 10, 1_000, 0, n * 100_000) == :ok)
  end

  test "rejections report when the next request would be admitted", %{instance: instance} do
    key = make_ref()
    assert Gcra.check(instance, key, 1, 1_000, 0, 0) == :ok
    assert {:error, retry_after} = Gcra.check(instance, key, 1, 1_000, 0, 1_000)
    assert retry_after == 999
    assert Gcra.check(instance, key, 1, 1_000, 0, 1_000 + retry_after * 1_000) == :ok
  end

  test "rejected requests do not push the key further into the future", %{instance: instance} do
    key = make_ref()
    assert Gcra.check(instance, key, 1, 1_000, 0, 0) == :ok
    for _attempt <- 1..50, do: assert({:error, _ms} = Gcra.check(instance, key, 1, 1_000, 0, 10))
    assert Gcra.check(instance, key, 1, 1_000, 0, 1_000_000) == :ok
  end

  test "sweep drops keys whose arrival time has passed", %{instance: instance} do
    Gcra.check(instance, :idle, 1, 1_000, 0, 0)
    Gcra.check(instance, :busy, 1, 1_000, 0, 0)
    Gcra.check(instance, :busy, 1, 1_000, 5, 1_500_000)

    assert Gcra.sweep(instance, 2_000_000) == 1
    assert :ets.member(instance.state.gcra.table, :busy)
  end

  @tag config: [state: [gcra_max_keys: 10]]
  test "untracked keys are not limited once the table is full", %{instance: instance} do
    for n <- 1..10, do: Gcra.check(instance, {:k, n}, 1, 1_000, 0, 0)

    assert Gcra.check(instance, :late, 1, 1_000, 0, 0) == :ok
    assert Gcra.check(instance, :late, 1, 1_000, 0, 0) == :ok
    assert :ets.info(instance.state.gcra.table, :size) == 10
  end

  test "reset forgets a key", %{instance: instance} do
    Gcra.check(instance, :k, 1, 1_000, 0, 0)
    assert {:error, _ms} = Gcra.check(instance, :k, 1, 1_000, 0, 0)
    Gcra.reset(instance, :k)
    assert Gcra.check(instance, :k, 1, 1_000, 0, 0) == :ok
  end
end
